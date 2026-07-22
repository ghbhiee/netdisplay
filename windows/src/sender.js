// NetDisplay Windows Sender（WS-1 整屏 MVP）
// 采集：desktopCapturer(底层 Windows.Graphics.Capture) → MediaStreamTrackProcessor
// 编码：WebCodecs VideoEncoder（Media Foundation 硬编）H.264 Annex-B
// 协议：与 mac/Sources/netdisplay-sender/Session.swift 行为对齐（SOT: docs/02-protocol.md）
"use strict";
const net = require("net");
const os = require("os");
const nodeCrypto = require("crypto");
const { ipcRenderer } = require("electron");
const { T, buildFrame, FrameParser, buildVideoPayload } = require("./protocol");

const DEVICE_ID_KEY = "sender.deviceId";
const deviceId = () => {
  let id = localStorage.getItem(DEVICE_ID_KEY);
  if (!id) { id = nodeCrypto.randomUUID(); localStorage.setItem(DEVICE_ID_KEY, id); }
  return id;
};

let server = null;
let active = null; // 当前会话 {sock, stop()}
let onStatus = () => {};
let stats = null; // 最近一次会话的发送统计（会话结束后保留，供互调对账）
const dbg = (...a) => console.log("[sender]", ...a); // --enable-logging 时可见

// ---------- Annex-B 工具 ----------
function nalTypesAnnexB(u8, max = 8) {
  const types = [];
  for (let i = 0; i + 3 < u8.length && types.length < max; i++) {
    let sc = 0;
    if (u8[i] === 0 && u8[i + 1] === 0 && u8[i + 2] === 1) sc = 3;
    else if (u8[i] === 0 && u8[i + 1] === 0 && u8[i + 2] === 0 && u8[i + 3] === 1) sc = 4;
    if (!sc) continue;
    types.push(u8[i + sc] & 0x1f);
    i += sc;
  }
  return types;
}

// avcC (VideoDecoderConfig.description) → Annex-B 形式的 SPS+PPS（备用：关键帧缺参数集时前置）
function paramSetsFromAvcC(desc) {
  const d = new Uint8Array(desc.buffer || desc, desc.byteOffset || 0, desc.byteLength);
  const parts = [];
  let i = 5;
  let n = d[i++] & 0x1f; // numOfSPS
  for (let s = 0; s < n; s++) {
    const len = (d[i] << 8) | d[i + 1]; i += 2;
    parts.push(d.subarray(i, i + len)); i += len;
  }
  n = d[i++]; // numOfPPS
  for (let p = 0; p < n; p++) {
    const len = (d[i] << 8) | d[i + 1]; i += 2;
    parts.push(d.subarray(i, i + len)); i += len;
  }
  const out = new Uint8Array(parts.reduce((a, c) => a + 4 + c.length, 0));
  let o = 0;
  for (const c of parts) { out.set([0, 0, 0, 1], o); o += 4; out.set(c, o); o += c.length; }
  return out;
}

// ---------- codec 协商（v1.3/v1.6，Sender 侧） ----------
// 能力名 → WebCodecs 编码配置片段。注意 HEVC 用 hevc.format，H.264 用 avc.format。
const ENC_CODEC = {
  h264: { codec: "avc1.640033", annexb: (c) => ({ ...c, avc: { format: "annexb" } }) },
  hevc: { codec: "hev1.1.6.L120.B0", annexb: (c) => ({ ...c, hevc: { format: "annexb" } }) },
  hevc422: { codec: "hev1.4.10.L120.B0", annexb: (c) => ({ ...c, hevc: { format: "annexb" } }) },
};
let encodable = null; // 本机可编能力，首次探测后缓存

async function detectEncodable() {
  if (encodable) return encodable;
  const out = [];
  for (const name of ["hevc422", "hevc", "h264"]) {
    const e = ENC_CODEC[name];
    for (const hw of ["prefer-hardware", "no-preference"]) {
      try {
        const cfg = e.annexb({
          codec: e.codec, width: 1280, height: 720, bitrate: 10e6,
          framerate: 30, latencyMode: "realtime", hardwareAcceleration: hw,
        });
        const r = await VideoEncoder.isConfigSupported(cfg);
        if (r.supported) { out.push(name); break; }
      } catch {}
    }
  }
  encodable = out;
  dbg("encodable codecs:", out.join(",") || "(none)");
  return out;
}

// 从 Receiver 的偏好序里挑第一个本机能编的（对齐 Mac Session.swift 的 negotiateCodec）
function negotiateCodec(receiverCodecs) {
  const want = Array.isArray(receiverCodecs) && receiverCodecs.length ? receiverCodecs : ["h264"];
  for (const name of want) if (encodable.includes(name)) return name;
  return null;
}

// ---------- 采集 ----------
// 当前投射源（null = 主屏）。WS-3：可选单个窗口。
let source = null; // {id, name, kind}
const listSources = () => ipcRenderer.invoke("capture-sources");
function setSource(s) { source = s || null; }

async function captureTrack(fps) {
  let src = source;
  if (!src) {
    const all = await listSources();
    src = all.find((s) => s.kind === "desktop") || all[0];
  }
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: false,
    video: {
      mandatory: {
        chromeMediaSource: "desktop",
        chromeMediaSourceId: src.id,
        maxWidth: 4096,
        maxHeight: 4096,
        maxFrameRate: fps,
      },
    },
  });
  return { track: stream.getVideoTracks()[0], src };
}

// ---------- 会话 ----------
async function startSession(sock, receiverHello, relayMode) {
  const fps = Math.min(60, Math.max(30, receiverHello?.screen?.fps || 60));
  const bitrate = (receiverHello?.screen?.bitrateMbps || 40) * 1e6; // v1.2：采纳 Receiver 期望码率
  // v1.3/v1.6：按 Receiver 的 codecs 偏好序挑本机能编的
  await detectEncodable();
  const codecName = negotiateCodec(receiverHello?.codecs);
  if (!codecName) {
    sock.write(buildFrame(T.HELLO_ACK, {
      version: 1, accepted: false,
      reason: "no common codec (sender can encode: " + (encodable.join(",") || "none") + ")",
    }));
    sock.write(buildFrame(T.BYE, { reason: "no common codec" }));
    throw new Error("no common codec with receiver");
  }

  const { track, src } = await captureTrack(fps);
  // getSettings() 会把约束上限当尺寸（实测返回 4096×4096），不可信。
  // 先读第一帧拿真实 codedWidth/Height，再回 ACK、再配编码器。
  const processor = new MediaStreamTrackProcessor({ track });
  const reader = processor.readable.getReader();
  const first = await reader.read();
  if (first.done || !first.value) throw new Error("capture produced no frames");
  let width = first.value.codedWidth & ~1;
  let height = first.value.codedHeight & ~1;

  // MVP：display = 实际抓取尺寸（忽略 screen 请求的宽高，已在 91 与 Mac 确认）
  const ack = {
    version: 1,
    accepted: true,
    display: { width, height, fps },
    codec: codecName, // v1.3/v1.6 协商结果
  };
  // v1.4 持久配对下发。注意：只指定了 --pairhash（无 secret）时不能下发本机 secret——
  // 对端存下它后算出的 hash 与当前房间不符，下次就连不上了。
  if (relayMode && !(overrideHash && !overrideSecret)) ack.pairSecret = getPairSecret();
  sock.write(buildFrame(T.HELLO_ACK, ack));
  sock.write(
    buildFrame(T.PROJECTION_STATE, {
      active: true,
      label: src.kind === "window" ? src.name : `${os.hostname()} 屏幕`,
      sourceKind: src.kind,
    })
  );

  let forceKey = true; // 首帧必须关键帧（02 §3.1）
  let basePts = null;
  let spsCache = null; // 从 decoderConfig.description 提取，关键帧缺 SPS 时前置
  let stopped = false;

  // 发送侧统计（互调时与对端计数对账用，for-windows「请你也从 Windows 侧确认发送计数」）
  stats = {
    startedAt: Date.now(),
    width, height, fps, codec: ack.codec, relayMode: !!relayMode,
    encoderAccel: null,
    captured: 0, // 采集到的帧
    dropped: 0, // 背压丢弃（未送编码器）
    sent: 0, // 已发出的 VIDEO_FRAME
    keyframes: 0,
    bytes: 0, // VIDEO_FRAME 载荷累计
    encodeErrors: 0,
    keyframeRequests: 0,
    pings: 0,
    lastSecond: { at: Date.now(), sent: 0, bytes: 0, fps: 0, mbps: 0 },
  };
  const st = stats;

  const encoder = new VideoEncoder({
    output: (chunk, meta) => {
      if (stopped || sock.destroyed) return;
      // 参数集兜底仅 H.264（avcC 解析）；HEVC 是 hvcC 格式，结构不同，实测 annexb 自带 VPS/SPS/PPS
      if (codecName === "h264" && meta?.decoderConfig?.description && !spsCache) {
        spsCache = paramSetsFromAvcC(meta.decoderConfig.description);
      }
      let data = new Uint8Array(chunk.byteLength);
      chunk.copyTo(data);
      const key = chunk.type === "key";
      if (key && codecName === "h264" && !nalTypesAnnexB(data).includes(7) && spsCache) {
        const merged = new Uint8Array(spsCache.length + data.length);
        merged.set(spsCache, 0);
        merged.set(data, spsCache.length);
        data = merged; // annexb 模式一般自带 SPS/PPS；这里兜底（for-windows review 注意点①）
      }
      if (st.sent === 0) dbg("first chunk:", chunk.type, chunk.byteLength, "bytes, nals", nalTypesAnnexB(data));
      if (basePts == null) basePts = chunk.timestamp;
      const ptsUs = Math.max(0, chunk.timestamp - basePts); // 起点归 0，对齐 Mac 实测行为
      sock.write(buildFrame(T.VIDEO_FRAME, buildVideoPayload(ptsUs, key, Buffer.from(data.buffer, data.byteOffset, data.byteLength))));
      st.sent++;
      st.bytes += data.length;
      if (key) st.keyframes++;
    },
    error: (e) => { st.encodeErrors++; dbg("encoder error:", e.message); onStatus("编码错误: " + e.message); },
  });
  // 硬编优先，不可用则退 no-preference（Chromium/Electron 的 MF 硬编开关随版本环境而异）
  const encoderCfg = async (w, h) => {
    const e = ENC_CODEC[codecName];
    const base = e.annexb({
      codec: e.codec,
      width: w,
      height: h,
      bitrate,
      framerate: fps,
      latencyMode: "realtime",
    });
    for (const hw of ["prefer-hardware", "no-preference"]) {
      try {
        const r = await VideoEncoder.isConfigSupported({ ...base, hardwareAcceleration: hw });
        if (r.supported) return { ...base, hardwareAcceleration: hw };
      } catch {}
    }
    return null;
  };
  const cfg = await encoderCfg(width, height);
  if (!cfg) throw new Error("no supported H.264 encoder config");
  st.encoderAccel = cfg.hardwareAcceleration;
  dbg("configure encoder", width, "x", height, "fps", fps, "bitrate", bitrate, "hw", cfg.hardwareAcceleration);
  encoder.configure(cfg);

  // WS-3：投射窗口 resize → 重配编码器 + 发 VIDEO_CONFIG + 强制关键帧（02 §5、§10.1-4）
  let reconfiguring = false;
  async function onSizeChanged(w, h) {
    if (reconfiguring || stopped) return;
    reconfiguring = true;
    try {
      const next = await encoderCfg(w, h);
      if (!next || stopped) return;
      try { await encoder.flush(); } catch {}
      encoder.configure(next);
      spsCache = null; // 新尺寸的参数集会随下一个关键帧重新给出
      width = w; height = h;
      st.width = w; st.height = h; st.resizes = (st.resizes || 0) + 1;
      sock.write(buildFrame(T.VIDEO_CONFIG, { codec: ack.codec, width: w, height: h, fps }));
      forceKey = true; // Receiver 收到 VIDEO_CONFIG 会重置解码器，必须给关键帧
      dbg("resize ->", w, "x", h);
    } finally {
      reconfiguring = false;
    }
  }

  // 首帧（用于测尺寸的那帧）直接作为第一个关键帧编码
  if (encoder.state === "configured") {
    encoder.encode(first.value, { keyFrame: true });
    st.captured++;
    forceKey = false;
  }
  first.value.close();

  // 采集循环：编码队列积压则丢帧（背压，对齐 Mac StreamPipeline）
  (async () => {
    while (!stopped) {
      const { value: frame, done } = await reader.read();
      if (done || stopped) { frame && frame.close(); break; }
      st.captured++;
      const fw = frame.codedWidth & ~1;
      const fh = frame.codedHeight & ~1;
      if ((fw !== width || fh !== height) && fw > 0 && fh > 0) {
        // 窗口被 resize：本帧丢弃，重配后从下一帧的关键帧开始
        st.dropped++;
        frame.close();
        onSizeChanged(fw, fh);
        continue;
      }
      if (!reconfiguring && encoder.state === "configured" && encoder.encodeQueueSize <= 2) {
        encoder.encode(frame, { keyFrame: forceKey });
        forceKey = false;
      } else {
        st.dropped++;
      }
      frame.close();
    }
  })().catch((e) => onStatus("采集中断: " + e.message));

  const statTimer = setInterval(() => {
    if (stopped) return;
    const now = Date.now();
    const dt = (now - st.lastSecond.at) / 1000;
    if (dt > 0) {
      st.lastSecond.fps = +((st.sent - st.lastSecond.sent) / dt).toFixed(1);
      st.lastSecond.mbps = +(((st.bytes - st.lastSecond.bytes) * 8) / dt / 1e6).toFixed(2);
    }
    st.lastSecond.at = now;
    st.lastSecond.sent = st.sent;
    st.lastSecond.bytes = st.bytes;
    onStatus(
      `发送中 ${width}x${height}@${fps} ${st.codec} · ${st.lastSecond.fps}fps ${st.lastSecond.mbps}Mbps · ` +
      `已发 ${st.sent} 帧(关键 ${st.keyframes}) 丢 ${st.dropped}`
    );
  }, 1000);

  return {
    sock,
    requestKeyframe() { forceKey = true; },
    projectionStop() {
      // CONTROL stop/bounceBack：停采集转空闲，连接保持（Windows 侧 bounceBack 语义=stop）
      if (stopped) return;
      stopped = true;
      clearInterval(statTimer);
      try { reader.cancel(); } catch {}
      try { track.stop(); } catch {}
      try { encoder.close(); } catch {}
      if (!sock.destroyed) sock.write(buildFrame(T.PROJECTION_STATE, { active: false }));
      onStatus("已停止投射（连接保持）");
    },
    stop() {
      this.projectionStop();
      try { sock.destroy(); } catch {}
    },
  };
}

// ---------- Receiver 连接处理（直连/中转共用） ----------
function attachReceiverHandler(sock, relayMode) {
    sock.setNoDelay(true);
    onStatus("Receiver 已连入，握手中…");
    sock.write(
      buildFrame(T.HELLO, { version: 1, role: "sender", name: os.hostname(), deviceId: deviceId() })
    );
    const parser = new FrameParser(async (type, payload) => {
      switch (type) {
        case T.HELLO: {
          const hello = JSON.parse(payload.toString());
          if (hello.version !== 1) {
            sock.write(buildFrame(T.BYE, { reason: "version mismatch" }));
            sock.destroy();
            return;
          }
          try {
            active = await startSession(sock, hello, relayMode);
          } catch (e) {
            onStatus("启动采集失败: " + e.message);
            sock.write(buildFrame(T.BYE, { reason: "capture failed" }));
            sock.destroy();
          }
          break;
        }
        case T.REQUEST_KEYFRAME:
          if (stats) stats.keyframeRequests++;
          active && active.requestKeyframe();
          break;
        case T.PING:
          if (stats) stats.pings++;
          sock.write(buildFrame(T.PONG, Buffer.from(payload)));
          break;
        case T.CONTROL: {
          const c = JSON.parse(payload.toString());
          if (c.action === "stop" || c.action === "bounceBack") active && active.projectionStop();
          break;
        }
        case T.BYE:
          sock.destroy();
          break;
        default:
          break; // 未知帧跳过（02 §2）
      }
    });
    sock.on("data", (d) => {
      try { parser.feed(d); } catch (e) { sock.destroy(); }
    });
    sock.on("close", () => {
      if (active && active.sock === sock) { active.projectionStop(); active = null; }
      onStatus(relayMode ? "Receiver 已断开" : "Receiver 已断开，继续监听…");
    });
    sock.on("error", () => {});
}

// ---------- 对外：直连模式（监听 47800） ----------
async function startSender(statusCb) {
  if (server) return;
  onStatus = statusCb || (() => {});
  server = net.createServer((sock) => {
    if (active) { sock.destroy(); return; } // 单连接：拒绝并发（MVP）
    attachReceiverHandler(sock, false);
  });
  server.listen(47800, () => onStatus("发送端就绪：监听 :47800，等待 Receiver 连入"));
  server.on("error", (e) => { onStatus("监听失败: " + e.message); server = null; });
}

// ---------- 中转模式（WS-2）：REGISTER → PAIRED → 同一会话逻辑 ----------
// 持久配对（02 §10.1）：Windows 作为 Sender 时生成并持久保存 pairSecret，
// 中转会话的 HELLO_ACK 下发给 Receiver；首次配对成功后改用 pairHash 免码注册。
let overrideSecret = null; // --secret：联调用的共享固定密钥（优先于本机生成的）
let overrideHash = null; // --pairhash：直接指定房间 hash（不下发 secret）

function getPairSecret() {
  if (overrideSecret) return overrideSecret;
  let s = localStorage.getItem("sender.pairSecret");
  if (!s) {
    s = nodeCrypto.randomBytes(32).toString("base64");
    localStorage.setItem("sender.pairSecret", s);
  }
  return s;
}
const hashOf = (b64) =>
  nodeCrypto.createHash("sha256").update(Buffer.from(b64, "base64")).digest("hex");
const pairHashOfSecret = () => overrideHash || hashOf(getPairSecret());

let relayActive = false; // 中转模式开着（含等待配对/会话中/重连间隙）
let relayCurSock = null;
let relayTimer = null;

async function startSenderRelay(statusCb, opts = {}) {
  if (relayActive || server) return;
  onStatus = statusCb || (() => {});
  relayActive = true;
  // 共享固定配对（联调用）：给了 secret/pairhash 就直接按 pairHash 待命，零配对码、零点击
  overrideSecret = opts.secret || null;
  overrideHash = opts.pairHash || null;
  const sharedPairing = !!(overrideSecret || overrideHash);
  const [host, portStr] = (opts.server || "15.tokencv.com:47700").split(":");
  const port = +portStr || 47700;

  const registerOnce = () => {
    if (!relayActive) return;
    const paired = sharedPairing || (localStorage.getItem("sender.everPaired") === "1" && !opts.forceCode);
    const code = opts.fixedCode || String(100000 + (nodeCrypto.randomBytes(4).readUInt32BE(0) % 900000));
    const sock = net.createConnection(port, host, () => {
      sock.setNoDelay(true);
      const reg = { v: 1, role: "sender", code: paired ? "" : code };
      if (paired) reg.pairHash = pairHashOfSecret();
      if (opts.token) reg.token = opts.token;
      sock.write(buildFrame(T.RELAY_REGISTER, reg));
      onStatus(paired ? "已持久配对 · 待命中（免码）" : `等待配对 · 配对码 ${code}`);
      dbg(
        "relay registered",
        paired ? "pairHash " + pairHashOfSecret().slice(0, 16) + "…" : "code " + code,
        sharedPairing ? "(shared)" : ""
      );
    });
    relayCurSock = sock;
    const preParser = new FrameParser((type, payload) => {
      if (type === T.RELAY_PAIRED) {
        localStorage.setItem("sender.everPaired", "1");
        opts.forceCode = false; // 固定码只用于首次注册；之后走 pairHash 免码
        // 残留字节交接（RELAY_PAIRED 和对端 HELLO 可能同 chunk 到达）
        const remnant = preParser.buf;
        preParser.buf = Buffer.alloc(0);
        sock.removeAllListeners("data");
        attachReceiverHandler(sock, true);
        if (remnant.length) process.nextTick(() => sock.emit("data", remnant));
      } else if (type === T.RELAY_ERROR) {
        const r = JSON.parse(payload.toString()).reason;
        dbg("RELAY_ERROR:", r);
        if (r === "room_occupied") {
          // 房间已有活跃发送端。继续自动重连只会和对方互踢（relay 因此拒绝我们），
          // 所以停下来并说清楚，等人工介入。
          relayActive = false;
          onStatus("该房间已有另一个发送端在待命 —— 已停止重试，请先停掉它再重来");
          dbg("room_occupied: another sender holds this pairHash; giving up (no auto-retry)");
        } else {
          onStatus("中转注册失败: " + r);
        }
        sock.destroy();
      }
    });
    sock.on("data", (d) => { try { preParser.feed(d); } catch { sock.destroy(); } });
    sock.on("error", () => {});
    sock.on("close", () => {
      if (active && active.sock === sock) { active.projectionStop(); active = null; }
      if (relayActive) {
        // 会话结束/断线 → 3s 后重新注册待命（pairHash 房间可替换注册，自愈）
        onStatus("中转连接断开，3s 后重新注册…");
        relayTimer = setTimeout(registerOnce, 3000);
      }
    });
  };
  registerOnce();
}

function stopSender() {
  relayActive = false;
  clearTimeout(relayTimer);
  if (relayCurSock) { try { relayCurSock.destroy(); } catch {} relayCurSock = null; }
  if (active) { active.stop(); active = null; }
  if (server) { try { server.close(); } catch {} server = null; }
  onStatus("发送端已停止");
}

// 互调对账用：返回本次/最近一次发送会话的统计快照
function getSenderStats() {
  if (!stats) return null;
  const s = { ...stats, lastSecond: undefined };
  s.elapsedSec = +((Date.now() - stats.startedAt) / 1000).toFixed(1);
  s.avgFps = +(stats.sent / Math.max(1, s.elapsedSec)).toFixed(1);
  s.avgMbps = +((stats.bytes * 8) / Math.max(1, s.elapsedSec) / 1e6).toFixed(2);
  return s;
}

module.exports = {
  startSender,
  startSenderRelay,
  stopSender,
  getSenderStats,
  listSources, // WS-3：可投射的屏幕/窗口列表
  setSource, // WS-3：选择投射源（null = 主屏），下次会话生效
  isSending: () => !!server || relayActive,
};
