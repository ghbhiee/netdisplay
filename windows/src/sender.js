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

// ---------- 采集 ----------
async function captureScreenTrack(fps) {
  const sourceId = await ipcRenderer.invoke("screen-source");
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: false,
    video: {
      mandatory: {
        chromeMediaSource: "desktop",
        chromeMediaSourceId: sourceId,
        maxWidth: 4096,
        maxHeight: 4096,
        maxFrameRate: fps,
      },
    },
  });
  return stream.getVideoTracks()[0];
}

// ---------- 会话 ----------
async function startSession(sock, receiverHello, relayMode) {
  const fps = Math.min(60, Math.max(30, receiverHello?.screen?.fps || 60));
  const bitrate = (receiverHello?.screen?.bitrateMbps || 40) * 1e6; // v1.2：采纳 Receiver 期望码率
  const track = await captureScreenTrack(fps);
  // getSettings() 会把约束上限当尺寸（实测返回 4096×4096），不可信。
  // 先读第一帧拿真实 codedWidth/Height，再回 ACK、再配编码器。
  const processor = new MediaStreamTrackProcessor({ track });
  const reader = processor.readable.getReader();
  const first = await reader.read();
  if (first.done || !first.value) throw new Error("capture produced no frames");
  const width = first.value.codedWidth & ~1;
  const height = first.value.codedHeight & ~1;

  // MVP：display = 实际抓取尺寸（忽略 screen 请求的宽高，已在 91 与 Mac 确认）
  const ack = {
    version: 1,
    accepted: true,
    display: { width, height, fps },
    codec: "h264", // MVP 固定 h264；codec 协商随 hevc422 一起做（91 已确认）
  };
  if (relayMode) ack.pairSecret = getPairSecret(); // v1.4 持久配对下发（中转模式）
  sock.write(buildFrame(T.HELLO_ACK, ack));
  sock.write(buildFrame(T.PROJECTION_STATE, { active: true, label: `${os.hostname()} 屏幕`, sourceKind: "desktop" }));

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
      if (meta && meta.decoderConfig && meta.decoderConfig.description && !spsCache) {
        spsCache = paramSetsFromAvcC(meta.decoderConfig.description);
      }
      let data = new Uint8Array(chunk.byteLength);
      chunk.copyTo(data);
      const key = chunk.type === "key";
      if (key && !nalTypesAnnexB(data).includes(7) && spsCache) {
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
  const base = {
    codec: "avc1.640033",
    width,
    height,
    bitrate,
    framerate: fps,
    latencyMode: "realtime",
    avc: { format: "annexb" },
  };
  let cfg = null;
  for (const hw of ["prefer-hardware", "no-preference"]) {
    try {
      const r = await VideoEncoder.isConfigSupported({ ...base, hardwareAcceleration: hw });
      if (r.supported) { cfg = { ...base, hardwareAcceleration: hw }; break; }
    } catch {}
  }
  if (!cfg) throw new Error("no supported H.264 encoder config");
  st.encoderAccel = cfg.hardwareAcceleration;
  dbg("configure encoder", width, "x", height, "fps", fps, "bitrate", bitrate, "hw", cfg.hardwareAcceleration);
  encoder.configure(cfg);

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
      if (encoder.state === "configured" && encoder.encodeQueueSize <= 2) {
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
function getPairSecret() {
  let s = localStorage.getItem("sender.pairSecret");
  if (!s) {
    s = nodeCrypto.randomBytes(32).toString("base64");
    localStorage.setItem("sender.pairSecret", s);
  }
  return s;
}
const pairHashOfSecret = () =>
  nodeCrypto.createHash("sha256").update(Buffer.from(getPairSecret(), "base64")).digest("hex");

let relayActive = false; // 中转模式开着（含等待配对/会话中/重连间隙）
let relayCurSock = null;
let relayTimer = null;

async function startSenderRelay(statusCb, opts = {}) {
  if (relayActive || server) return;
  onStatus = statusCb || (() => {});
  relayActive = true;
  const [host, portStr] = (opts.server || "15.tokencv.com:47700").split(":");
  const port = +portStr || 47700;

  const registerOnce = () => {
    if (!relayActive) return;
    const paired = localStorage.getItem("sender.everPaired") === "1" && !opts.forceCode;
    const code = opts.fixedCode || String(100000 + (nodeCrypto.randomBytes(4).readUInt32BE(0) % 900000));
    const sock = net.createConnection(port, host, () => {
      sock.setNoDelay(true);
      const reg = { v: 1, role: "sender", code: paired ? "" : code };
      if (paired) reg.pairHash = pairHashOfSecret();
      if (opts.token) reg.token = opts.token;
      sock.write(buildFrame(T.RELAY_REGISTER, reg));
      onStatus(paired ? "已持久配对 · 待命中（免码）" : `等待配对 · 配对码 ${code}`);
      dbg("relay registered", paired ? "pairHash" : "code " + code);
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
        onStatus("中转注册失败: " + r);
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
  isSending: () => !!server || relayActive,
};
