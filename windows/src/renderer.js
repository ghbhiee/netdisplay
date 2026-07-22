// NetDisplay Receiver — renderer：设置、连接（直连/中转）、协议、WebCodecs 解码、渲染、统计
"use strict";
const net = require("net");
const os = require("os");
const nodeCrypto = require("crypto");
const { ipcRenderer } = require("electron");
const { T, buildFrame, FrameParser, parseVideoPayload } = require("../src/protocol");
const sender = require("../src/sender");

const $ = (id) => document.getElementById(id);
const panel = $("panel"), stage = $("stage"), overlay = $("overlay"), hint = $("hint");
const statusEl = $("status");
const canvas = $("video");
const ctx = canvas.getContext("2d", { alpha: false, desynchronized: true });

let config = null; // 主进程下发：screen 物理像素 + 启动参数
let sock = null;
let decoder = null;
let waitingKey = false;
let disconnectReason = null;
let display = null; // HELLO_ACK.display（唯一权威尺寸，含可选 scale）
let streaming = false;

// ===== v1.4 连接与投射解耦 =====
let projActive = true; // 老 Sender 不发 PROJECTION_STATE → 视为一直投射
let projEvents = 0; // 测试统计
let manualDisconnect = false; // 用户主动断开 → 不自动重连
let reconnectTimer = null;
let reconnectDelay = 1000;

function pairSecret() {
  return localStorage.getItem("pairSecret") || null;
}
function pairHashHex() {
  const s = pairSecret();
  if (!s) return null;
  return nodeCrypto.createHash("sha256").update(Buffer.from(s, "base64")).digest("hex"); // 小写 hex，与 Mac 端约定一致
}
function updatePairInfo() {
  $("pairInfo").classList.toggle("hidden", !pairSecret());
}

function setIdleUI(idle, label) {
  $("idle").style.display = idle ? "flex" : "none";
  canvas.classList.toggle("dimmed", idle);
  const sl = $("srcLabel");
  if (!idle && label) { sl.textContent = label; sl.style.display = "block"; }
  else sl.style.display = "none";
}

function sendControl(action) {
  if (sock && !sock.destroyed) sock.write(buildFrame(T.CONTROL, { action }));
}

function scheduleReconnect(why) {
  if (manualDisconnect || reconnectTimer) return;
  // 自动重连仅中转+已持久配对（93 §4：配一次之后自动就绪）
  if (mode !== "relay" || !pairSecret()) return;
  setStatus(`${why || "连接断开"} — ${Math.round(reconnectDelay / 1000)}s 后自动重连…`);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    reconnectDelay = Math.min(30000, reconnectDelay * 2);
    connect();
  }, reconnectDelay);
}

// 协议 v1.3/v1.6 codec 协商：能力名 → WebCodecs codec string
const CODEC_MAP = {
  h264: "avc1.640033",
  hevc: "hev1.1.6.L153.B0",
  hevc422: "hev1.4.10.L153.B0", // v1.6：HEVC Rext Main 4:2:2 10-bit（真流实测硬解通过）
  hevc444: "hev1.4.10.L153.B0", // 保留解码映射备用；上报按 02 v1.6 建议序，不含 444
};
let supportedCodecs = ["h264"]; // 启动时探测，按偏好排序
let sessionCodec = "h264"; // 本次会话协商结果（HELLO_ACK.codec）

async function detectCodecs() {
  const out = [];
  for (const name of ["hevc422", "hevc"]) {
    try {
      const r = await VideoDecoder.isConfigSupported({
        codec: CODEC_MAP[name],
        hardwareAcceleration: "prefer-hardware", // 硬解才有低延迟意义
        optimizeForLatency: true,
      });
      if (r.supported) out.push(name);
    } catch {}
  }
  out.push("h264");
  supportedCodecs = out;
}

const deviceId =
  localStorage.getItem("deviceId") ||
  (() => {
    const id = nodeCrypto.randomUUID();
    localStorage.setItem("deviceId", id);
    return id;
  })();

// ================= 设置（全部持久化） =================
const FIELDS = ["ip", "code", "relayServer", "token", "res", "scale", "fps", "bitrate", "customW", "customH"];
const CHECKS = ["windowed", "overlayOn"];
let mode = localStorage.getItem("pref.mode") || "direct";

function loadPrefs() {
  for (const id of FIELDS) {
    const v = localStorage.getItem("pref." + id);
    if (v != null && v !== "") $(id).value = v;
    $(id).onchange = () => localStorage.setItem("pref." + id, $(id).value);
  }
  for (const id of CHECKS) {
    const v = localStorage.getItem("pref." + id);
    if (v != null) $(id).checked = v === "1";
    $(id).onchange = () => localStorage.setItem("pref." + id, $(id).checked ? "1" : "0");
  }
  applyMode(mode);
  $("res").addEventListener("change", syncCustomVisibility);
  syncCustomVisibility();
}

function applyMode(m) {
  mode = m;
  localStorage.setItem("pref.mode", m);
  for (const b of $("modeSeg").children) b.classList.toggle("on", b.dataset.mode === m);
  $("grpDirect").classList.toggle("hidden", m !== "direct");
  $("grpRelay").classList.toggle("hidden", m !== "relay");
}
$("modeSeg").addEventListener("click", (e) => {
  if (e.target.dataset.mode) applyMode(e.target.dataset.mode);
});

function syncCustomVisibility() {
  $("grpCustom").classList.toggle("hidden", $("res").value !== "custom");
}

// HELLO.screen：期望分辨率/scale/fps/码率（协议 v1.2 §3.3）
function desiredScreen() {
  const res = $("res").value;
  const scale = +$("scale").value || 1;
  let width, height;
  if (res === "auto") ({ width, height } = config.screen);
  else if (res === "custom") {
    width = (+$("customW").value || config.screen.width) & ~1;
    height = (+$("customH").value || config.screen.height) & ~1;
  } else [width, height] = res.split("x").map(Number);
  width &= ~1; // scaleFactor 换算可能出奇数（如 1707.33×1.5→2561），编码尺寸必须为偶
  height &= ~1;
  const out = { width, height, scale, fps: +$("fps").value || 60 };
  const br = Math.round(+$("bitrate").value);
  if (br > 0) out.bitrateMbps = br;
  return out;
}

function setStatus(msg, isErr) {
  statusEl.textContent = msg || "";
  statusEl.className = isErr ? "err" : "";
}

// ================= 面板状态 =================
function showPanel(overStream) {
  panel.style.display = "flex";
  panel.classList.toggle("over-stream", !!overStream);
  $("btnConnect").textContent = overStream ? "应用并重连" : "连接";
  $("btnDisconnect").style.display = overStream ? "block" : "none";
  $("btnClose").style.display = overStream ? "block" : "none";
}
function hidePanel() {
  panel.style.display = "none";
}

// ================= 连接 =================
function connect() {
  // 运行中「应用并重连」：先静默断开，再按当前设置重连
  if (sock) teardown(null, true);
  if (mode === "direct") {
    const ip = $("ip").value.trim();
    const port = +((config.args && config.args.port) || 47800);
    setStatus(`连接 ${ip}:${port} …`);
    sock = net.createConnection(port, ip, () => {
      sock.setNoDelay(true);
      setStatus("已连接，握手中…");
      sendHello();
    });
  } else {
    const code = $("code").value.trim();
    const hash = pairHashHex();
    // v1.4：输了码用码；没输码但有持久配对 → pairHash 免码撮合
    if (!/^\d{6}$/.test(code) && !hash) return setStatus("请输入 6 位数字配对码（首次配对）", true);
    const [host, portStr] = $("relayServer").value.trim().split(":");
    setStatus(`连接中转 ${host} …`);
    sock = net.createConnection(+portStr || 47700, host, () => {
      sock.setNoDelay(true);
      const join = { v: 1, role: "receiver", code: "" };
      const tok = $("token").value.trim();
      if (tok) join.token = tok; // v1.5：公网 relay 鉴权
      if (/^\d{6}$/.test(code)) {
        setStatus(`配对中（码 ${code}）…`);
        join.code = code;
      } else {
        setStatus("已持久配对，撮合中…");
        join.pairHash = hash;
      }
      sock.write(buildFrame(T.RELAY_JOIN, join));
    });
  }
  wireSocket();
}

function sendHello() {
  sock.write(
    buildFrame(T.HELLO, {
      version: 1,
      role: "receiver",
      name: os.hostname(),
      deviceId,
      screen: desiredScreen(),
      codecs: supportedCodecs, // v1.3：解码能力（偏好序），老 Sender 忽略
    })
  );
}

let lastDataTs = 0;
function wireSocket() {
  const parser = new FrameParser(onFrame);
  const mySock = sock;
  mySock.on("data", (d) => {
    lastDataTs = performance.now();
    try {
      parser.feed(d);
    } catch (e) {
      teardown("协议错误: " + e.message);
    }
  });
  mySock.on("error", (e) => { if (mySock === sock) teardown("连接错误: " + e.message); });
  mySock.on("close", () => { if (mySock === sock) teardown(disconnectReason || "连接已断开"); });
}

// ================= 协议分发 =================
const pings = new Map();
let pingTimer = null, watchdogTimer = null, overlayTimer = null;

function onFrame(type, payload) {
  switch (type) {
    case T.HELLO:
      break;
    case T.HELLO_ACK: {
      const ack = JSON.parse(payload.toString());
      if (!ack.accepted) return teardown("对端拒绝: " + (ack.reason || "unknown"));
      sessionCodec = CODEC_MAP[ack.codec] ? ack.codec : "h264"; // v1.3 协商结果
      if (ack.pairSecret) { // v1.4 持久配对：保存，之后免输码
        localStorage.setItem("pairSecret", ack.pairSecret);
        $("code").value = "";
        localStorage.setItem("pref.code", "");
        updatePairInfo();
      }
      reconnectDelay = 1000; // 连接成功，重置退避
      startStreaming(ack.display);
      break;
    }
    case T.VIDEO_FRAME:
      if (!projActive) { // 收到帧即视为投射恢复（93 §4）
        projActive = true;
        setIdleUI(false);
        ipcRenderer.send("win-show");
      }
      handleVideo(payload);
      break;
    case T.PROJECTION_STATE: {
      // v1.4：投射开/关，连接与窗口都保持
      const st = JSON.parse(payload.toString());
      projEvents++;
      projActive = !!st.active;
      if (projActive) {
        setIdleUI(false, st.label || "");
        ipcRenderer.send("win-show"); // 投射来了自动显示到前台
      } else {
        setIdleUI(true);
        waitingKey = true; // 下次恢复必从关键帧开始
      }
      break;
    }
    case T.VIDEO_CONFIG: {
      // 中途流参数变化（如 Mac 端单窗口投射 resize）：更新尺寸 + 重置解码器等关键帧（协议 §5）
      const c = JSON.parse(payload.toString());
      if (c.codec && CODEC_MAP[c.codec]) sessionCodec = c.codec;
      if (c.width && c.height && display) {
        display.width = c.width;
        display.height = c.height;
        if (c.scale) display.scale = c.scale;
        canvas.width = c.width;
        canvas.height = c.height;
        layoutCanvas();
      }
      resetDecoder();
      requestKeyframe();
      break;
    }
    case T.PONG: {
      const t0 = pings.get(payload.toString("hex"));
      if (t0 != null) {
        stats.rtt = performance.now() - t0;
        stats.total.rtts.push(stats.rtt);
        pings.delete(payload.toString("hex"));
      }
      break;
    }
    case T.RELAY_PAIRED:
      setStatus("配对成功，握手中…");
      sendHello();
      break;
    case T.RELAY_ERROR: {
      const r = JSON.parse(payload.toString()).reason;
      const msg = {
        code_not_found: "配对码不存在或已过期",
        rate_limited: "尝试过于频繁，稍后再试",
        unauthorized: "token 不正确（在设置里填写中转服务器的访问令牌）",
      }[r] || r;
      teardown("中转失败: " + msg);
      break;
    }
    case T.BYE:
      disconnectReason = "对端结束会话";
      break;
    default:
      break; // 未知帧：按协议跳过
  }
}

// ================= 统计 =================
const stats = {
  reset() {
    this.recv = 0; this.decoded = 0; this.dropped = 0; this.bytes = 0;
    this.rtt = null; this.t0 = performance.now();
    this.total = { recv: 0, decoded: 0, dropped: 0, bytes: 0, keyframes: 0, decodeErrors: 0, rtts: [] };
  },
};
stats.reset();

// ================= 解码与渲染 =================
function makeDecoder() {
  const d = new VideoDecoder({
    output: (frame) => {
      stats.decoded++; stats.total.decoded++;
      ctx.drawImage(frame, 0, 0, canvas.width, canvas.height);
      frame.close();
    },
    error: () => {
      stats.total.decodeErrors++;
      resetDecoder();
      requestKeyframe();
    },
  });
  d.configure({ codec: CODEC_MAP[sessionCodec], optimizeForLatency: true }); // Annex-B：不设 description
  return d;
}

function resetDecoder() {
  try { decoder && decoder.state !== "closed" && decoder.close(); } catch {}
  decoder = makeDecoder();
  waitingKey = true;
}

function requestKeyframe() {
  if (sock && !sock.destroyed) sock.write(buildFrame(T.REQUEST_KEYFRAME));
}

function handleVideo(payload) {
  const v = parseVideoPayload(payload);
  stats.recv++; stats.total.recv++; stats.bytes += payload.length; stats.total.bytes += payload.length;
  if (v.keyframe) stats.total.keyframes++;

  if (!decoder || decoder.state === "closed") return;
  if (waitingKey && !v.keyframe) { stats.dropped++; stats.total.dropped++; return; }
  waitingKey = false;

  // 背压：解码队列积压则丢到下一个关键帧（低延迟优先，协议 §4）
  if (decoder.decodeQueueSize > 8 && !v.keyframe) {
    stats.dropped++; stats.total.dropped++;
    waitingKey = true;
    return;
  }
  try {
    decoder.decode(
      new EncodedVideoChunk({
        type: v.keyframe ? "key" : "delta",
        timestamp: Number(v.ptsUs),
        data: v.data,
      })
    );
  } catch (e) {
    stats.total.decodeErrors++;
    resetDecoder();
    requestKeyframe();
  }
}

// 防糊核心：canvas 设备像素严格 = display.width×height，CSS 尺寸按 devicePixelRatio 折算，
// 保证 1 canvas 像素 : 1 屏幕物理像素（放不下时才等比缩小）。
function layoutCanvas() {
  if (!display) return;
  const dpr = window.devicePixelRatio || 1;
  const cssW = display.width / dpr;
  const cssH = display.height / dpr;
  const fit = Math.min(1, window.innerWidth / cssW, window.innerHeight / cssH);
  canvas.style.width = cssW * fit + "px";
  canvas.style.height = cssH * fit + "px";
}
window.addEventListener("resize", layoutCanvas);

function startStreaming(d) {
  display = { scale: 1, ...d };
  streaming = true;
  projActive = true; // 老 Sender 默认视为投射中；v1.4 Sender 会立刻发 PROJECTION_STATE 校正
  setIdleUI(false);
  canvas.width = display.width;
  canvas.height = display.height;
  resetDecoder();

  hidePanel();
  setStatus("");
  stage.style.display = "flex";
  $("toolbar").style.display = "flex";
  hint.style.display = "block";
  overlay.style.display = $("overlayOn").checked ? "block" : "none";
  if ($("windowed").checked) {
    ipcRenderer.send("set-fullscreen", false);
    const dpr = window.devicePixelRatio || 1;
    ipcRenderer.send("set-content-size", Math.round(display.width / dpr), Math.round(display.height / dpr));
  } else {
    ipcRenderer.send("set-fullscreen", true);
  }
  layoutCanvas();
  stats.reset();

  pingTimer = setInterval(() => {
    const p = nodeCrypto.randomBytes(8);
    pings.set(p.toString("hex"), performance.now());
    if (sock && !sock.destroyed) sock.write(buildFrame(T.PING, p));
  }, 3000);
  lastDataTs = performance.now();
  watchdogTimer = setInterval(() => {
    if (performance.now() - lastDataTs > 10000) teardown("超过 10 秒未收到数据");
  }, 2000);
  overlayTimer = setInterval(updateOverlay, 1000);
}

function updateOverlay() {
  const dt = (performance.now() - stats.t0) / 1000;
  if (dt < 0.5) return;
  overlay.textContent =
    `${canvas.width}x${canvas.height}${display && display.scale > 1 ? `@${display.scale}x` : ""} ${sessionCodec}  ` +
    `recv ${(stats.recv / dt).toFixed(0)}fps  dec ${(stats.decoded / dt).toFixed(0)}fps  ` +
    `${((stats.bytes * 8) / dt / 1e6).toFixed(1)}Mbps  ` +
    `rtt ${stats.rtt == null ? "--" : stats.rtt.toFixed(1)}ms  drop ${stats.dropped}`;
  stats.recv = 0; stats.decoded = 0; stats.bytes = 0; stats.t0 = performance.now();
}

// ================= 断开与清理 =================
function teardown(reason, silent) {
  [pingTimer, watchdogTimer, overlayTimer].forEach((t) => t && clearInterval(t));
  pingTimer = watchdogTimer = overlayTimer = null;
  pings.clear();
  disconnectReason = null;
  streaming = false;
  if (sock) {
    const s = sock;
    sock = null;
    try { s.write(buildFrame(T.BYE, {})); } catch {}
    s.destroy();
  }
  try { decoder && decoder.state !== "closed" && decoder.close(); } catch {}
  decoder = null;
  display = null;
  if (!silent) {
    stage.style.display = "none";
    overlay.style.display = "none";
    hint.style.display = "none";
    $("toolbar").style.display = "none";
    setIdleUI(false);
    showPanel(false);
    ipcRenderer.send("set-fullscreen", false);
    if (reason) setStatus(reason, true);
    scheduleReconnect(reason); // v1.4：持久配对场景自动重连
  }
}

// ================= UI 事件 =================
$("btnConnect").onclick = () => {
  manualDisconnect = false;
  reconnectDelay = 1000;
  if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
  connect();
};
$("btnDisconnect").onclick = () => { manualDisconnect = true; teardown("已断开"); };
$("btnClose").onclick = () => { if (streaming) hidePanel(); };
$("clearPair").onclick = () => {
  localStorage.removeItem("pairSecret");
  updatePairInfo();
  setStatus("已清除持久配对，下次连接需输入配对码");
};

// WS-1/WS-2 发送端入口
function refreshSendButtons() {
  const on = sender.isSending();
  $("btnSend").style.display = on ? "none" : "block";
  $("btnSendRelay").style.display = on ? "none" : "block";
  $("btnSendStop").style.display = on ? "block" : "none";
}
const sendStatus = (s) => { $("sendStatus").textContent = s; };
$("btnSend").onclick = async () => {
  await sender.startSender(sendStatus);
  refreshSendButtons();
};
$("btnSendRelay").onclick = async () => {
  await sender.startSenderRelay(sendStatus, {
    server: $("relayServer").value.trim(),
    token: $("token").value.trim() || undefined,
  });
  refreshSendButtons();
};
$("btnSendStop").onclick = () => {
  sender.stopSender();
  refreshSendButtons();
};

// v1.4 目标端控制：弹回 / 停止（Mac 收到后会转空闲并发 PROJECTION_STATE{active:false}）
$("btnBounce").onclick = () => sendControl("bounceBack");
$("btnStop").onclick = () => sendControl("stop");
$("btnSettings").onclick = () => showPanel(true);

// 工具栏：动鼠标浮现，2.5s 无操作淡出
let toolbarHide = null;
window.addEventListener("mousemove", () => {
  if (!streaming) return;
  $("toolbar").classList.add("show");
  clearTimeout(toolbarHide);
  toolbarHide = setTimeout(() => $("toolbar").classList.remove("show"), 2500);
});

let escDown = null;
window.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && streaming) {
    if (panel.style.display !== "none") hidePanel();
    else if (escDown == null) escDown = setTimeout(() => { manualDisconnect = true; teardown("已断开"); }, 800);
  } else if (e.key === "F1" && streaming) {
    e.preventDefault();
    const on = overlay.style.display !== "block";
    overlay.style.display = on ? "block" : "none";
    $("overlayOn").checked = on;
    localStorage.setItem("pref.overlayOn", on ? "1" : "0");
  } else if (e.key === "F2" && streaming) {
    e.preventDefault();
    panel.style.display === "none" ? showPanel(true) : hidePanel();
  }
});
window.addEventListener("keyup", (e) => {
  if (e.key === "Escape") { clearTimeout(escDown); escDown = null; }
});

// ================= 启动 =================
(async () => {
  config = await ipcRenderer.invoke("config");
  loadPrefs();
  updatePairInfo();
  await detectCodecs();
  const a = config.args || {};
  if (a.res) $("res").value = a.res;
  if (a.scale) $("scale").value = a.scale;
  if (a.windowed) $("windowed").checked = true;
  if (a.testPairSecret) { localStorage.setItem("pairSecret", a.testPairSecret); updatePairInfo(); }
  if (a.token) $("token").value = a.token;
  if (a.send) { await sender.startSender(sendStatus); refreshSendButtons(); }
  else if (a.sendRelay) {
    await sender.startSenderRelay(sendStatus, {
      server: a.server || $("relayServer").value.trim(),
      token: a.token || undefined,
      fixedCode: a.sendRelayCode || undefined,
      forceCode: !!a.sendRelayCode,
    });
    refreshSendButtons();
  }
  if (a.autoBounce) setTimeout(() => sendControl("bounceBack"), +a.autoBounce * 1000);
  if (a.connect) { applyMode("direct"); $("ip").value = a.connect; connect(); }
  else if (a.relay != null) {
    applyMode("relay");
    $("code").value = a.relay;
    if (a.server) $("relayServer").value = a.server;
    connect();
  } else if (mode === "relay" && pairSecret()) {
    // v1.4：已持久配对 → 启动即自动连接待命，无需用户操作
    connect();
  }
  if (a.exitAfter) {
    setTimeout(() => {
      const t = stats.total;
      const avgRtt = t.rtts.length ? t.rtts.reduce((x, y) => x + y) / t.rtts.length : null;
      ipcRenderer.send(
        "test-result",
        JSON.stringify({
          recv: t.recv, decoded: t.decoded, dropped: t.dropped, keyframes: t.keyframes,
          decodeErrors: t.decodeErrors, bytes: t.bytes,
          avgRttMs: avgRtt == null ? null : +avgRtt.toFixed(2),
          canvas: canvas.width + "x" + canvas.height,
          scale: display ? display.scale : null,
          cssSize: canvas.style.width + " x " + canvas.style.height,
          dpr: window.devicePixelRatio,
          projEvents,
          projActive,
          pairSaved: !!pairSecret(),
        })
      );
    }, +a.exitAfter * 1000);
  }
})();
