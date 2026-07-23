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
const { probeHQ } = require("./ffmpeg-probe");
const { startCapture, parseSpsSize } = require("./ffmpeg-capture");

const DEVICE_ID_KEY = "sender.deviceId";
const deviceId = () => {
  let id = localStorage.getItem(DEVICE_ID_KEY);
  if (!id) { id = nodeCrypto.randomUUID(); localStorage.setItem(DEVICE_ID_KEY, id); }
  return id;
};

let server = null;
let active = null; // 当前会话 {sock, stop()}
let onStatus = () => {};
let onPeerHello = null; // A 位时把对端 HELLO 抛给上层（配对完成要靠它拿对方名字）
let stats = null; // 最近一次会话的发送统计（会话结束后保留，供互调对账）
let sessionOpts = {}; // 启动时传入的选项（HQ 开关、ffmpeg 路径等）
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
let hqInfo = null; // WS-5：ffmpeg HQ 路径探测结果（null=尚未探测）
let webCodecsCaps = []; // WebCodecs 单独能编的（用于判断某 codec 是否只能靠 HQ）

async function detectEncodable(hqEnabled, ffmpegPath) {
  if (encodable) return encodable;
  const out = [];

  // WS-5：HQ（ffmpeg + 硬件 HEVC 4:2:2）优先——它是 WebCodecs 编不出来的能力。
  // 探测里已包含「真编真验色度」，所以这里拿到 available 就意味着能出真 4:2:2。
  if (hqEnabled !== false) {
    try {
      hqInfo = await probeHQ(ffmpegPath || null, dbg);
      if (hqInfo.available && hqInfo.codec) out.push(hqInfo.codec);
    } catch (e) {
      dbg("HQ 探测异常，忽略并回退基线:", e.message);
      hqInfo = null;
    }
  }

  // WebCodecs 基线：零依赖、支持窗口模式，永远保留（边界①）
  webCodecsCaps = [];
  for (const name of ["hevc422", "hevc", "h264"]) {
    const e = ENC_CODEC[name];
    for (const hw of ["prefer-hardware", "no-preference"]) {
      try {
        const cfg = e.annexb({
          codec: e.codec, width: 1280, height: 720, bitrate: 10e6,
          framerate: 30, latencyMode: "realtime", hardwareAcceleration: hw,
        });
        const r = await VideoEncoder.isConfigSupported(cfg);
        if (r.supported) { webCodecsCaps.push(name); break; }
      } catch {}
    }
  }
  for (const name of webCodecsCaps) if (!out.includes(name)) out.push(name);

  encodable = out;
  dbg("encodable codecs:", out.join(",") || "(none)",
    `| WebCodecs: ${webCodecsCaps.join(",") || "无"}`,
    `| HQ: ${hqInfo && hqInfo.available ? hqInfo.encoder : "不可用"}`);
  return out;
}

// 这次协商出的 codec 是否**只有** HQ 路径能编 → 决定走 ffmpeg 还是 WebCodecs。
// 注意判据是「WebCodecs 编不了」而非「HQ 可用」：两者都能编时优先用零依赖的基线，
// 保持行为稳定（边界①：HQ 是增强，不是默认替换）。
const needsHQ = (codecName) =>
  !!(hqInfo && hqInfo.available && hqInfo.codec === codecName && !webCodecsCaps.includes(codecName));

// 从 Receiver 的偏好序里挑第一个本机能编的（对齐 Mac Session.swift 的 negotiateCodec）
function negotiateCodec(receiverCodecs) {
  const want = Array.isArray(receiverCodecs) && receiverCodecs.length ? receiverCodecs : ["h264"];
  for (const name of want) if (encodable.includes(name)) return name;
  return null;
}

// ---------- 采集 ----------
// 当前投射源（null = 主屏）。WS-3：可选单个窗口。
let source = null; // {id, name, kind}
let requiredWindow = null; // 用户明确要求投的窗口名；设了就不允许退回整屏
const listSources = () => ipcRenderer.invoke("capture-sources");
function setSource(s) { source = s || null; }
function requireWindow(name) { requiredWindow = name || null; }

async function captureTrack(fps) {
  let src = source;
  if (!src) {
    if (requiredWindow) {
      // 明确指定了要投的窗口却拿不到，绝不能悄悄投整屏——对端只会看到「尺寸是整屏」，
      // 无从反推原因。最常见的成因是窗口被最小化：desktopCapturer 不枚举最小化窗口。
      throw new Error(
        `找不到指定窗口「${requiredWindow}」——若它已最小化请先还原（最小化的窗口无法被捕获）`
      );
    }
    const all = await listSources();
    src = all.find((s) => s.kind === "desktop") || all[0];
  } else if (requiredWindow) {
    // 会话开始时再确认一次：窗口可能在待命期间被关掉或最小化了
    const all = await listSources();
    if (!all.some((s) => s.id === src.id)) {
      throw new Error(
        `窗口「${src.name}」已不可捕获（被关闭或最小化）——还原后对端重连即可`
      );
    }
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

// ---------- HQ 会话（WS-5：ffmpeg + 硬件 HEVC 4:2:2）----------
// socket 待发字节超过此值即判定网络跟不上，开始丢帧（约 2 个 2560x1600 关键帧的量）
const BACKPRESSURE_BYTES = 2 * 1024 * 1024;
const MAX_HQ_RESTARTS = 5; // 连续崩溃重启上限，超过则放弃并断会话

// 与 WebCodecs 会话并列，协议行为完全一致，只是帧的来源换成 ffmpeg 子进程。
async function startHQSession(sock, { fps, bitrate, codecName, relayMode }) {
  const src = source || { kind: "desktop", name: os.hostname() + " 屏幕" };
  // ffmpeg 路径下尺寸由采集器决定，首帧到达前不知道——拿到 SPS 才发 ACK
  let announced = false;
  let stopped = false;
  let waitingKeyAfterDrop = false; // 背压丢帧后等下一个关键帧再恢复
  let restartTimer = null;

  stats = {
    startedAt: Date.now(), width: 0, height: 0, fps, codec: codecName,
    relayMode: !!relayMode, encoderAccel: `ffmpeg:${hqInfo.encoder}`, path: "hq",
    captured: 0, dropped: 0, sent: 0, keyframes: 0, bytes: 0,
    encodeErrors: 0, keyframeRequests: 0, pings: 0,
    lastSecond: { at: Date.now(), sent: 0, bytes: 0, fps: 0, mbps: 0 },
  };
  const st = stats;

  const spawnCapture = () => startCapture({
    ffmpeg: hqInfo.ffmpeg, encoder: hqInfo.encoder, pixFmt: hqInfo.pixFmt,
    source: src, fps, bitrateMbps: Math.round(bitrate / 1e6), gopSeconds: 2,
    onFrame(au, isKey, ptsUs) {
      if (stopped || sock.destroyed) return;
      // 首帧必须是关键帧（协议 §3.1）；ffmpeg 首个 AU 就是 IDR，非关键帧一律丢弃直到关键帧
      if (!announced) {
        if (!isKey) { st.dropped++; return; }
        // 尺寸只能从流里的 SPS 拿：ffmpeg 抓到多大取决于屏幕/窗口，事先不知道。
        // 解析失败就没法给对端正确的 display，宁可失败也不要发错尺寸让对端黑屏。
        const size = parseSpsSize(au);
        if (!size) {
          st.encodeErrors++;
          if (!sock.destroyed) sock.write(buildFrame(T.BYE, { reason: "hq: cannot parse SPS size" }));
          try { sock.destroy(); } catch {}
          return;
        }
        st.width = size.width; st.height = size.height;
        announced = true;
        const ack = {
          version: 1, accepted: true,
          display: { width: size.width, height: size.height, fps },
          codec: codecName,
        };
        if (relayMode) ack.pairSecret = getPairSecret();
        sock.write(buildFrame(T.HELLO_ACK, ack));
        sock.write(buildFrame(T.PROJECTION_STATE, {
          active: true,
          label: src.kind === "window" ? src.name : `${os.hostname()} 屏幕`,
          sourceKind: src.kind,
        }));
      }
      st.captured++;

      // 背压（边界⑥）：ffmpeg 按帧率恒定产出，不会像 WebCodecs 那样自己等待。
      // socket 积压时必须主动丢帧，否则内存无限涨、延迟越拖越大。丢到下个关键帧为止，
      // 避免对端拿到依赖已丢帧的 P 帧而花屏。
      if (waitingKeyAfterDrop && !isKey) { st.dropped++; return; }
      if (sock.writableLength > BACKPRESSURE_BYTES && !isKey) {
        st.dropped++;
        waitingKeyAfterDrop = true;
        dbg(`背压丢帧：socket 积压 ${Math.round(sock.writableLength / 1024)}KB，等下一个关键帧`);
        return;
      }
      waitingKeyAfterDrop = false;

      sock.write(buildFrame(T.VIDEO_FRAME, buildVideoPayload(ptsUs, isKey, au)));
      st.sent++; st.bytes += au.length;
      if (isKey) st.keyframes++;
    },
    // 产出过帧后崩溃：多半是瞬时故障（设备被抢、驱动重置），退避重启而不是断会话
    onCrash(msg, tail) {
      if (stopped || sock.destroyed) return;
      st.encodeErrors++;
      st.restarts = (st.restarts || 0) + 1;
      if (st.restarts > MAX_HQ_RESTARTS) {
        dbg(`HQ 重启已达上限 ${MAX_HQ_RESTARTS} 次，放弃：${msg}`);
        onStatus(`HQ 采集反复失败（${st.restarts} 次），已停止`);
        if (!sock.destroyed) sock.write(buildFrame(T.BYE, { reason: "hq capture repeatedly failed" }));
        try { sock.destroy(); } catch {}
        return;
      }
      const delay = Math.min(8000, 500 * 2 ** (st.restarts - 1)); // 指数退避
      dbg(`${msg} → ${delay}ms 后第 ${st.restarts} 次重启\n${tail}`);
      onStatus(`采集中断，${Math.round(delay / 1000)}s 后重连…（第 ${st.restarts} 次）`);
      restartTimer = setTimeout(() => {
        if (stopped || sock.destroyed) return;
        waitingKeyAfterDrop = false;
        cap = spawnCapture(); // 重启后首帧仍是关键帧，对端能自然恢复
      }, delay);
    },
    onError(msg) {
      st.encodeErrors++;
      dbg("HQ 采集失败:", msg);
      onStatus("HQ 采集失败: " + String(msg).split("\n")[0]);
      if (!sock.destroyed) sock.write(buildFrame(T.BYE, { reason: "hq capture failed: " + String(msg).split("\n")[0] }));
      try { sock.destroy(); } catch {}
    },
    onLog: dbg,
  });
  let cap = spawnCapture();

  const statTimer = setInterval(() => {
    if (stopped) return;
    const now = Date.now();
    const dt = (now - st.lastSecond.at) / 1000;
    if (dt > 0) {
      st.lastSecond.fps = +((st.sent - st.lastSecond.sent) / dt).toFixed(1);
      st.lastSecond.mbps = +(((st.bytes - st.lastSecond.bytes) * 8) / dt / 1e6).toFixed(2);
    }
    st.lastSecond.at = now; st.lastSecond.sent = st.sent; st.lastSecond.bytes = st.bytes;
    const extra = st.restarts ? ` · 重启 ${st.restarts}` : "";
    const drop = st.dropped ? ` 丢 ${st.dropped}` : "";
    onStatus(`发送中 [HQ ${hqInfo.encoder}] ${codecName} · ${st.lastSecond.fps}fps ${st.lastSecond.mbps}Mbps · 已发 ${st.sent} 帧(关键 ${st.keyframes})${drop}${extra}`);
  }, 1000);

  return {
    sock,
    requestKeyframe() { st.keyframeRequests++; cap.requestKeyframe(); },
    projectionStop() {
      if (stopped) return;
      stopped = true;
      clearInterval(statTimer);
      clearTimeout(restartTimer); // 停止时可能正好在等重启，别让它之后又拉起来
      cap.stop();
      if (!sock.destroyed) sock.write(buildFrame(T.PROJECTION_STATE, { active: false }));
      onStatus("已停止投射（连接保持）");
    },
    stop() { this.projectionStop(); try { sock.destroy(); } catch {} },
  };
}

// ---------- 会话 ----------
async function startSession(sock, receiverHello, relayMode) {
  const fps = Math.min(60, Math.max(30, receiverHello?.screen?.fps || 60));
  const bitrate = (receiverHello?.screen?.bitrateMbps || 40) * 1e6; // v1.2：采纳 Receiver 期望码率
  // v1.3/v1.6：按 Receiver 的 codecs 偏好序挑本机能编的（含 WS-5 的 ffmpeg HQ 路径）
  await detectEncodable(sessionOpts.hq !== false, sessionOpts.ffmpegPath);
  const codecName = negotiateCodec(receiverHello?.codecs);
  if (!codecName) {
    sock.write(buildFrame(T.HELLO_ACK, {
      version: 1, accepted: false,
      reason: "no common codec (sender can encode: " + (encodable.join(",") || "none") + ")",
    }));
    sock.write(buildFrame(T.BYE, { reason: "no common codec" }));
    throw new Error("no common codec with receiver");
  }

  // WS-5：协商出的 codec 只有 ffmpeg 能编（如 hevc422）→ 走 HQ 管线
  dbg(`协商结果 codec=${codecName}，路径=${needsHQ(codecName) ? "HQ(ffmpeg)" : "基线(WebCodecs)"}`);
  if (needsHQ(codecName)) {
    return startHQSession(sock, { fps, bitrate, codecName, relayMode });
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
      // 带上 bitrateMbps：协议 §5 的示例含此字段，对端若按示例声明为必需字段，
      // 少发会导致整条 JSON 解码失败（Mac 端实测就是这样静默吞掉了每条 VIDEO_CONFIG）。
      // 发全字段对双方都更安全。
      sock.write(buildFrame(T.VIDEO_CONFIG, {
        codec: ack.codec, width: w, height: h, fps,
        bitrateMbps: Math.round(bitrate / 1e6),
      }));
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
    // lanAddrs 直接向主进程要，不依赖调用方传参——有 5 处入口调用 startSender*，
    // 靠每处都记得传，漏一处就表现为「升级永远不触发」且没有任何报错。
    ipcRenderer.invoke("config").then((cfg) => {
      if (sock.destroyed) return;
      sock.write(buildFrame(T.HELLO, {
        version: 1, role: "sender", name: os.hostname(), deviceId: deviceId(),
        lanAddrs: (cfg && cfg.lanAddrs) || [], // v1.9：供对端做中转→直连升级
      }));
    }).catch(() => {
      if (!sock.destroyed) sock.write(buildFrame(T.HELLO, {
        version: 1, role: "sender", name: os.hostname(), deviceId: deviceId(), lanAddrs: [],
      }));
    });
    const parser = new FrameParser(async (type, payload) => {
      switch (type) {
        case T.HELLO: {
          // 同一条连接上重复收到 HELLO 不能再起一个会话——会造成多个会话并存、
          // 帧发到没人收的那条上（连接升级时实测出现三个会话）。
          if (active && active.sock === sock) {
            dbg("忽略重复 HELLO（该连接已有会话）");
            break;
          }
          // 换了一条连接才顶替：此刻对端确实要用这条了（HELLO 是它的意图声明），
          // 比「一连上就顶替」安全——探测连接不会误杀正在用的会话。
          if (active) {
            dbg("新连接发来 HELLO，顶替旧会话（多为中转→直连升级）");
            try { active.stop(); } catch {}
            active = null;
          }
          const hello = JSON.parse(payload.toString());
          if (hello.version !== 1) {
            sock.write(buildFrame(T.BYE, { reason: "version mismatch" }));
            sock.destroy();
            return;
          }
          // 我在 A 位时，对端的 HELLO 只经过这里——renderer 的 onFrame 看不到它。
          // 不往上抛的话，「配对完成、显示对方名字」在 A 位这一侧永远不会发生。
          if (onPeerHello) { try { onPeerHello(hello); } catch (e) { dbg("onPeerHello 抛错: " + e.message); } }
          try {
            active = await startSession(sock, hello, relayMode);
          } catch (e) {
            // 把真实原因带给对端：只回 "capture failed" 时对方无从判断是权限、
            // 窗口失效还是编码器问题，只能来回猜（跨机联调实际踩过）。
            const why = e && e.message ? e.message : String(e);
            dbg("startSession failed:", why);
            onStatus("启动采集失败: " + why);
            sock.write(buildFrame(T.BYE, { reason: "capture failed: " + why }));
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
  // 顶替旧会话的时机放在收到 HELLO 之后（见 attachReceiverHandler），不能放在这里：
  // 连接升级时对端只是**探测**，一连上就杀掉中转会话的话，对端还没切过来就先断了，
  // 表现为「升级成功但 recv=0」。
  server = net.createServer((sock) => attachReceiverHandler(sock, false));
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
  sessionOpts = { ...sessionOpts, ...opts };
  relayActive = true;

  // v1.9：直连监听口常开——中转模式下也要开，否则对端拿到我们的 lanAddrs 也无处可连，
  // 连接升级永远不会成功。失败（如端口被占）不影响中转，只是升级不可用。
  if (!server && opts.listenForUpgrade !== false) {
    try {
      await startSender(statusCb);
      dbg("直连口 47800 已开（供连接升级）");
    } catch (e) { dbg("直连口未能开启，连接升级不可用:", e.message); }
  }
  // 共享固定配对（联调用）：给了 secret/pairhash 就直接按 pairHash 待命，零配对码、零点击
  overrideSecret = opts.secret || null;
  overrideHash = opts.pairHash || null;
  const sharedPairing = !!(overrideSecret || overrideHash);
  const [host, portStr] = (opts.server || "15.tokencv.com:47700").split(":");
  const port = +portStr || 47700;

  const registerOnce = () => {
    if (!relayActive) return;
    const paired = sharedPairing || (localStorage.getItem("sender.everPaired") === "1" && !opts.forceCode);
    // 配对码长期有效：优先用 UI 持久保存的那个。每次重启换新码会让对方反复来问。
    const code = opts.fixedCode || localStorage.getItem("my.pairCode")
      || String(100000 + (nodeCrypto.randomBytes(4).readUInt32BE(0) % 900000));
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
  requireWindow, // WS-3：声明必须投某窗口，找不到就报错而非退回整屏
  isSending: () => !!server || relayActive,
  setPeerHelloHandler: (fn) => { onPeerHello = fn; }, // A 位时对端 HELLO 的出口
};
