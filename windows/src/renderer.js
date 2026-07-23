// NetDisplay Receiver — renderer：设置、连接（直连/中转）、协议、WebCodecs 解码、渲染、统计
"use strict";
const net = require("net");
const os = require("os");
const nodeCrypto = require("crypto");
const { ipcRenderer } = require("electron");
const { T, buildFrame, FrameParser, parseVideoPayload } = require("../src/protocol");
const sender = require("../src/sender");
const role = require("../src/role");

const $ = (id) => document.getElementById(id);
const stage = $("stage"), overlay = $("overlay"), hint = $("hint");
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
let switchingDirection = false; // 正在为「换投射方向」而重建连接 → 这次断线不算异常，不重置角色
let reconnectTimer = null;
let reconnectDelay = 1000;

let plainCodeTried = false; // 交接期：pairHash 房间没人时，是否已回退试过明文码
let sharedSecret = null; // --secret：联调用共享固定密钥（优先于持久保存的）
let sharedHash = null; // --pairhash：直接指定房间

function pairSecret() {
  // 联调参数最优先，其次是当前选中设备，最后兜底到旧的单配对存储
  // （老用户升级上来时别把已有的配对弄丢）。
  if (sharedSecret) return sharedSecret;
  const d = selectedDevice();
  if (d && d.secret) return d.secret;
  return localStorage.getItem("pairSecret") || null;
}
function pairHashHex() {
  if (sharedHash) return sharedHash;
  const s = pairSecret();
  if (!s) return null;
  return nodeCrypto.createHash("sha256").update(Buffer.from(s, "base64")).digest("hex"); // 小写 hex，与 Mac 端约定一致
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
  // 自动重连需要「无需人工输入即可重建」：中转/自动模式 + 已持久配对
  if (mode === "direct" || !pairSecret()) return;
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

// ================= 设置与设备（全部持久化） =================
// 以前这些值直接从 DOM 里读（$("res").value）。新设计把界面拆到了另一个窗口，
// 引擎再也看不到那些 input，所以设置必须自己有个家。
const PREF_DEFAULTS = {
  res: "auto", scale: "1", fps: "60", rate: "auto",
  relayServer: "15.tokencv.com:47700", token: "", forceRelay: false,
  windowed: false, overlayOn: true, theme: "dark",
};
const prefs = { ...PREF_DEFAULTS };

function loadPrefs() {
  for (const k of Object.keys(PREF_DEFAULTS)) {
    const v = localStorage.getItem("pref." + k);
    if (v == null) continue;
    prefs[k] = typeof PREF_DEFAULTS[k] === "boolean" ? v === "1" : v;
  }
}
function setPref(k, v) {
  if (!(k in PREF_DEFAULTS)) return;
  prefs[k] = v;
  localStorage.setItem("pref." + k, typeof v === "boolean" ? (v ? "1" : "0") : String(v));
}

// 「模式」这个概念被设计取消了。用户不再回答「我等对方连我还是我去连对方」——
// 那是实现细节，而且实测他必然选反（他想的是「谁投给谁」）。现在方向由
// role/recvSvc 决定，走直连还是中转由程序探测，见 docs/design/README.md。
// 保留这个变量只为兼容 CLI 联调参数与 scheduleReconnect 的判断。
let mode = "relay";

// ===== 已配对设备 =====
// 设计要求一个设备列表：每台记住 secret（决定 relay 房间）、对端自报的 name、
// 本机给它起的别名。别名优先于 name——那是这台机器的用户自己起的（协议 §3.6）。
function loadDevices() {
  try { return JSON.parse(localStorage.getItem("devices") || "[]"); }
  catch { return []; } // 存坏了宁可从空列表重来，也不要整个界面起不来
}
function saveDevices(list) {
  localStorage.setItem("devices", JSON.stringify(list));
}
let devices = loadDevices();
let selectedId = localStorage.getItem("selectedId") || (devices[0] && devices[0].id) || null;

const deviceById = (id) => devices.find((d) => d.id === id) || null;
function deviceLabel(d) {
  if (!d) return "";
  // 协议 §3.6：别名 > 对端 name > deviceId 前 8 位。绝不显示空白。
  return d.alias || d.name || (d.id ? d.id.slice(0, 8) : "未知设备");
}
function selectedDevice() {
  return deviceById(selectedId);
}

// 配对码 → secret：两端输入同一个码就得到同一个房间。设计把配对改成了
// 「双方输入相同的码」（一方随机生成），而不是「一端显示、另一端输入」。
function secretFromCode(code) {
  return nodeCrypto.createHash("sha256").update("netdisplay-pair:" + code).digest("base64");
}

// HELLO.screen：期望分辨率/scale/fps/码率（协议 v1.2 §3.3）
function desiredScreen() {
  const res = prefs.res;
  const scale = +prefs.scale || 1;
  let width, height;
  if (res === "auto") ({ width, height } = config.screen);
  else [width, height] = res.split("x").map(Number);
  width &= ~1; // scaleFactor 换算可能出奇数（如 1707.33×1.5→2561），编码尺寸必须为偶
  height &= ~1;
  const out = { width, height, scale, fps: +prefs.fps || 60 };
  const br = prefs.rate === "auto" ? 0 : Math.round(+prefs.rate);
  if (br > 0) out.bitrateMbps = br;
  return out;
}

function setStatus(msg, isErr) {
  statusEl.textContent = msg || "";
  statusEl.className = isErr ? "err" : "";
  if (msg) console.log("[recv] " + msg); // headless 模式转到 stdout，便于 CLI 联调排障
}

// ================= 状态机（docs/design/README.md「Interactions & Behavior」） =================
// role: standby | switching | casting | receiving
// recvSvc: off | waiting
// 投射与接收互斥——同一对设备同一时刻只有一个来源。
let uiRole = "standby";
let recvSvc = "off";
let switchTimer = null;
let connecting = false;
let lastRttMs = null;
let pickSel = localStorage.getItem("pickSel") || ""; // "" = 整块屏幕
let localName = localStorage.getItem("localName") || os.hostname();
let peerName = "";

function setRole(r) {
  uiRole = r;
  pushState();
}

// 切换时停 0.9s 显示「切换中…」——不是装样子：换投射方向真要拆连接重建，
// 这段时间界面必须说明在干什么，否则看起来像卡死。
function enterSwitching(then) {
  setRole("switching");
  clearTimeout(switchTimer);
  switchTimer = setTimeout(async () => {
    switchTimer = null;
    try { await then(); }
    catch (e) { toast("切换失败：" + (e.message || e)); setRole("standby"); }
  }, 900);
}

// 引擎是唯一状态源，panel/tray 只渲染。见 windows/src/UI-CONTRACT.md
function uiState() {
  const connected = !!sock;
  return {
    role: uiRole,
    recvSvc,
    devices: devices.map((x) => ({
      id: x.id,
      name: deviceLabel(x),
      online: !!x.online,
      conn: x.id === selectedId ? (connected ? "on" : connecting ? "connecting" : "off") : "off",
      transport: x.id === selectedId && connected ? currentTransport : null,
      rttMs: x.id === selectedId && connected ? lastRttMs : null,
    })),
    selectedId,
    sources: sourceList.map((s) => ({ id: s.id, name: s.name, kind: s.kind })),
    pickSel,
    quality: { res: prefs.res, scale: prefs.scale, fps: prefs.fps, rate: prefs.rate },
    relay: {
      addr: prefs.relayServer,
      token: prefs.token,
      forceRelay: !!prefs.forceRelay,
      status: relayHealth.status, // 实测结果，不是「输入框填了没」
      rttMs: relayHealth.rttMs,
      message: relayHealth.message,
    },
    localName,
    peerName: peerName || deviceLabel(selectedDevice()),
    castSourceName: pickSel
      ? ((sourceList.find((s) => s.id === pickSel) || {}).name || "程序窗口")
      : "整块屏幕",
    theme: prefs.theme,
  };
}
function pushState() {
  try { ipcRenderer.send("nd-state", uiState()); } catch {}
  syncReceiveWindow();
}
function toast(text) {
  try { ipcRenderer.send("nd-toast", text); } catch {}
  if (text) console.log("[recv] " + text);
}

// 接收窗口 = 本窗口。设计要求它「对方开始投射时自动打开、断开即关闭」，
// 平时不该杵在桌面上占地方。
function syncReceiveWindow() {
  const title = peerName ? `NetDisplay — ${peerName} 的画面` : "NetDisplay";
  try {
    ipcRenderer.send("nd-receive-window", {
      show: uiRole === "receiving" && streaming,
      title,
      fullscreen: !prefs.windowed,
    });
  } catch {}
  const t = $("winTitle");
  if (t) t.textContent = title;
  const b = $("badge");
  if (b) {
    const kind = currentTransport === "direct" ? "直连" : "中转";
    b.textContent = uiRole === "receiving" && streaming
      ? `接收中 · ${kind}${lastRttMs != null ? ` · ${Math.round(lastRttMs)}ms` : ""}`
      : "";
  }
}

// ================= UI 命令（panel/tray → main → 这里） =================
ipcRenderer.on("nd-cmd", async (_e, m) => {
  try { await handleCmd(m); }
  catch (e) {
    // 命令处理抛异常曾经让界面「点了没反应」而毫无线索——务必说出来
    console.log("[recv] 命令失败 " + m.cmd + ": " + ((e && e.stack) || e));
    toast("操作失败：" + ((e && e.message) || e));
  }
});

async function handleCmd(m) {
  switch (m.cmd) {
    case "start-cast":
      return startCast();
    case "stop":
      return stopToStandby();
    case "recv-svc":
      return setRecvSvc(!!m.on);
    case "drop-stream":
      // 设计明确：接收中点主按钮只断开投屏，接收服务保持 waiting（四态循环）
      manualDisconnect = true;
      teardown("已断开投屏", true);
      manualDisconnect = false;
      setRole("standby");
      if (recvSvc === "waiting") connect();
      return toast("已断开投屏，接收服务仍在等待");
    case "select-device":
      selectedId = m.id;
      localStorage.setItem("selectedId", m.id || "");
      return pushState();
    case "connect":
      selectedId = m.id;
      localStorage.setItem("selectedId", m.id || "");
      manualDisconnect = false;
      reconnectDelay = 1000;
      return connect();
    case "disconnect":
      manualDisconnect = true;
      teardown("已断开");
      return;
    case "rename": {
      const d = deviceById(m.id);
      if (!d) return;
      d.alias = (m.name || "").trim() || null;
      saveDevices(devices);
      return pushState();
    }
    case "unpair": {
      const d = deviceById(m.id);
      devices = devices.filter((x) => x.id !== m.id);
      saveDevices(devices);
      if (selectedId === m.id) {
        selectedId = (devices[0] && devices[0].id) || null;
        localStorage.setItem("selectedId", selectedId || "");
        manualDisconnect = true;
        teardown("已解除配对", true);
        manualDisconnect = false;
      }
      role.clearPairing(); // 角色编排也是配对的一部分，留着会拿旧 peerId 算角色
      pushState();
      return toast(`已解除与「${deviceLabel(d)}」的配对`);
    }
    case "pair":
      return doPair(m.code, m.addr);
    case "pick-source":
      pickSel = m.id || "";
      localStorage.setItem("pickSel", pickSel);
      applySource();
      return pushState();
    case "quality": {
      setPref(m.key, m.value);
      pushState();
      // 画质是「本机作显示器时」的请求，写在 HELLO.screen 里，握手时才生效
      if (sock) { setStatus("画质已改，正在重连生效…"); connect(); }
      return toast("画质已调整");
    }
    case "relay-save":
      setPref("relayServer", m.addr);
      setPref("token", m.token);
      setPref("forceRelay", !!m.forceRelay);
      relayHealth = { status: "unset", rttMs: null, message: "正在检测…" };
      pushState();
      probeRelay(); // 改完立刻重测，别让界面继续显示上一套设置的结论
      return toast("中转设置已保存，正在检测可用性…");
    case "probe-relay":
      return probeRelay();
    case "local-name":
      localName = (m.name || "").trim() || os.hostname();
      localStorage.setItem("localName", localName);
      pushState();
      return toast("本机名称已改为 " + localName);
    case "theme":
      setPref("theme", m.v);
      document.body.dataset.theme = m.v;
      return pushState();
    case "refresh-sources":
      await refreshSources();
      return pushState();
  }
}

function doPair(code, addr) {
  const clean = String(code || "").replace(/\s/g, "");
  if (!/^\d{6}$/.test(clean)) {
    return toast("配对码错误，请核对后重试（应为 6 位数字）");
  }
  const secret = secretFromCode(clean);
  const id = "pair-" + nodeCrypto.createHash("sha256").update(secret).digest("hex").slice(0, 12);
  if (deviceById(id)) {
    selectedId = id;
    localStorage.setItem("selectedId", id);
    pushState();
    return toast("这台设备已经配过对了");
  }
  devices.push({
    id, secret, code: clean, name: "", alias: null, online: false,
    addr: (addr || "").trim() || null,
  });
  saveDevices(devices);
  selectedId = id;
  localStorage.setItem("selectedId", id);
  pushState();
  toast((addr || "").trim() ? `已配对，将优先直连 ${addr}` : "已配对，将通过中转连接");
}

// ===== 三个动作：开投 / 回待命 / 开关接收服务 =====
async function startCast() {
  const d = selectedDevice();
  if (!d) return toast("还没有配对设备，先点「＋ 添加设备」");
  if (uiRole === "receiving") return toast("正在接收对方画面，不能同时投射");

  enterSwitching(async () => {
    applySource();
    const pos = role.myPosition(deviceId);
    // 规范第 4 条：A 位本就是 sender，直接开投；B 位必须反转角色重建连接。
    if (sock) {
      sendControl("stop"); // 先让对方转空闲（抢投编排，规范第 6 条）
      if (pos === "B") {
        role.markReversedForProjecting(deviceId);
        switchingDirection = true; // 这次断线是有意的，不要重置角色
      }
      manualDisconnect = true;
      teardown(null, true);
      await new Promise((r) => setTimeout(r, pos === "B" ? 400 : 300));
      manualDisconnect = false;
      switchingDirection = false;
    } else if (pos === "B") {
      // 没连接但我默认是 B 位：直接投的话对方不会来连我，先反转成 A 位
      role.markReversedForProjecting(deviceId);
    }
    await sender.startSenderRelay(sendStatus, {
      server: prefs.relayServer.trim(),
      token: prefs.token.trim() || undefined,
      secret: d.secret || undefined,
    });
    setRole("casting");
    toast(`正在投射给 ${deviceLabel(d)}`);
  });
}

function stopToStandby() {
  sender.stopSender();
  if (uiRole === "receiving") {
    manualDisconnect = true;
    teardown("已停止", true);
    manualDisconnect = false;
  }
  setRole("standby");
  // 接收服务开着就该继续待命等对方，而不是彻底断掉
  if (recvSvc === "waiting") connect();
  toast("已回到待命");
}

function setRecvSvc(on) {
  recvSvc = on ? "waiting" : "off";
  if (on) {
    manualDisconnect = false;
    reconnectDelay = 1000;
    if (!selectedDevice()) { recvSvc = "off"; pushState(); return toast("还没有配对设备，先点「＋ 添加设备」"); }
    connect();
    toast("接收服务已开启，等待对方投射");
  } else {
    manualDisconnect = true;
    teardown("接收服务已关闭", true);
    manualDisconnect = false;
    setRole("standby");
    toast("接收服务已关闭");
  }
  pushState();
}

// ================= 连接 =================
// 自动模式：并行试直连与中转，先**握手成功**者胜（happy-eyeballs 风格）。
// 串行「直连超时再试中转」会在直连不可达时让用户干等数秒——这是 ux-model 采纳的建议。
//
// ⚠️ 胜出判据必须是「收到对端的协议响应」，不能是「TCP connect 成功」：
// 本机装了 Mihomo/Clash 这类代理时，连一个根本不可达的地址 connect 也会成功
// （代理接管了连接），实测会误判成「已直连」然后卡在黑屏。只有对端按协议回了
// Sender HELLO / RELAY_PAIRED，才证明这条路真的通到了 NetDisplay 对端。
function connectAuto() {
  const port = +((config.args && config.args.port) || 47800);
  const d = selectedDevice();
  // 配对时用户可以填「对方地址」——那是加速直连的线索，不是让他选连接方式。
  const ip = (d && d.addr ? String(d.addr).split(":")[0] : "").trim();
  const [host, portStr] = prefs.relayServer.trim().split(":");
  const code = "";
  const hash = pairHashHex();
  const tok = prefs.token.trim();
  setStatus("自动连接：同时尝试直连与中转…");

  let settled = false;
  const racers = [];

  // 某条路握手成功 → 它胜出，其余全部丢弃，然后把它交给正常会话逻辑
  const win = (s, kind, firstFrames) => {
    if (settled) { s.destroy(); return; }
    settled = true;
    for (const r of racers) if (r.sock !== s) r.sock.destroy();
    sock = s;
    setStatus(kind === "direct" ? `已直连 ${ip}（低延迟）` : `已通过中转 ${host} 连接`);
    wireSocket();
    // 竞速期间已经读出来的帧要补回给正式解析器，否则会丢掉 Sender HELLO
    for (const [t, p] of firstFrames) onFrame(t, p);
  };

  const race = (s, kind, onOpen) => {
    const seen = [];
    racers.push({ sock: s, kind });
    s.setNoDelay(true);
    s.on("connect", () => { try { onOpen(s); } catch {} });
    // 竞速期用临时解析器：只为判断「对端是不是真的 NetDisplay」
    const parser = new FrameParser((t, p) => {
      if (settled) return;
      seen.push([t, Buffer.from(p)]);
      // 直连：对端会立即发 Sender HELLO；中转：relay 回 RELAY_PAIRED
      if (t === T.HELLO || t === T.HELLO_ACK || t === T.RELAY_PAIRED) {
        s.removeAllListeners("data");
        win(s, kind, seen);
      } else if (t === T.RELAY_ERROR) {
        s.destroy(); // 这条路明确不通，让另一条继续跑
      }
    });
    s.on("data", (d) => { try { parser.feed(d); } catch { s.destroy(); } });
    s.on("error", () => {});
  };

  if (ip) {
    race(net.createConnection(port, ip), "direct", (s) => {
      s.write(buildFrame(T.HELLO, {
        version: 1, role: "receiver", name: os.hostname(), deviceId, screen: desiredScreen(),
        codecs: supportedCodecs,
      }));
    });
  }
  if (host && (/^\d{6}$/.test(code) || hash)) {
    race(net.createConnection(+portStr || 47700, host), "relay", (s) => {
      const join = { v: 1, role: "receiver", code: "" };
      if (tok) join.token = tok;
      if (/^\d{6}$/.test(code)) join.code = code; else join.pairHash = hash;
      s.write(buildFrame(T.RELAY_JOIN, join));
    });
  }
  if (!racers.length) return setStatus("请先填写对方地址，或填写中转服务器与配对码", true);

  setTimeout(() => {
    if (settled) return;
    for (const r of racers) r.sock.destroy();
    setStatus("直连和中转都没握手成功——确认对方已在投射，且地址/配对码正确", true);
  }, 2500);
}

// A 位待命：同时开两条入口等对方来连——47800 供局域网直连，中转按 pairHash 注册。
// 用户不必选「直连还是中转」，对方用哪种都能连上。
async function startListening() {
  const d = selectedDevice();
  setStatus("正在待命，等对方连接…");
  await sender.startSender(sendStatus); // 监听 47800
  const server = prefs.relayServer.trim();
  if (server) {
    await sender.startSenderRelay(sendStatus, {
      server, token: prefs.token.trim() || undefined,
      secret: (d && d.secret) || undefined, // 同码 → 同 pairHash → 同一个房间
    });
  }
  pushState();
  setStatus("待命中，等对方投射过来");
}

// 谁监听谁拨号由 role.js 按 deviceId 字典序定（Option A 编排），不再问用户。
// 用户问的是「谁投给谁」，那由 startCast 决定；这里只负责把连接建起来。
function connect() {
  if (sock) teardown(null, true); // 「应用并重连」：先静默断开再按当前设置重连
  const d = selectedDevice();
  if (!d) return setStatus("还没有配对设备", true);

  if (role.myPosition(deviceId) === "A") return startListening();

  // B 位：我去拨对方。先停掉可能还开着的待命，否则会在中转上留一个没人用的
  // 注册，用户看不见也不知道，还占着房间。
  if (sender.isSending()) { sender.stopSender(); pushState(); }
  return dialPeer(d);
}

function dialPeer(d) {
  plainCodeTried = false; // 每次重新拨号都允许再回退一次
  const ip = d.addr ? String(d.addr).split(":")[0].trim() : "";
  const hash = pairHashHex();
  if (!hash) return setStatus("这台设备还没配对好，请重新添加", true);

  // 配对时填了对方地址 → 直连和中转并行竞速，先握手成功的胜出
  if (ip) return connectAuto();

  connecting = true;
  pushState();
  const [host, portStr] = prefs.relayServer.trim().split(":");
  setStatus(`连接中转 ${host} …`);
  sock = net.createConnection(+portStr || 47700, host, () => {
    sock.setNoDelay(true);
    const join = { v: 1, role: "receiver", code: "", pairHash: hash };
    const tok = prefs.token.trim();
    if (tok) join.token = tok; // v1.5：公网 relay 鉴权
    setStatus("撮合中…");
    sock.write(buildFrame(T.RELAY_JOIN, join));
  });
  wireSocket();
}

// ===== 中转服务健康探测 =====
// 以前这里是 `status: 地址 && token ? "ok" : "unset"` —— 那只是在检查两个输入框
// 非空，却对用户说「中转服务可用」。没连过服务器就报可用，是在撒谎。
//
// 判据必须是**对端按协议应答**：用一个随机 64hex 房间自己和自己配一次对
// （一条连接 register、另一条 join），只有真正的 NetDisplay relay 会回
// RELAY_PAIRED。光看 TCP connect 成功不作数——Mihomo/Clash 的 TUN 透明代理下，
// 连一个根本不存在的地址 connect 也会成功，连接升级那次已经栽过一回了。
let relayHealth = { status: "unset", rttMs: null, message: null };
let relayProbing = false;

// 联调/测试跑批时跳过探测：多开两条 relay 连接会干扰对账，也会让 room 计数变脏
const isCliRun = (a) =>
  !!(a.exitAfter || a.send || a.sendRelay || a.recvRelay || a.relay != null || a.connect || a.autoConnect);

function probeRelay() {
  const addr = (prefs.relayServer || "").trim();
  if (!addr) { relayHealth = { status: "unset", rttMs: null, message: null }; return pushState(); }
  if (relayProbing) return;
  relayProbing = true;

  const [host, portStr] = addr.split(":");
  const port = +portStr || 47700;
  const room = nodeCrypto.randomBytes(32).toString("hex"); // 随机房间，不会撞上真会话
  const tok = (prefs.token || "").trim();
  const t0 = performance.now();
  const socks = [];
  let done = false;

  const finish = (status, message) => {
    if (done) return;
    done = true;
    relayProbing = false;
    clearTimeout(timer);
    for (const s of socks) { try { s.destroy(); } catch {} }
    relayHealth = {
      status,
      rttMs: status === "ok" ? Math.round(performance.now() - t0) : null,
      message,
    };
    console.log(`[recv] 中转探测 ${addr} → ${status}${relayHealth.rttMs != null ? " " + relayHealth.rttMs + "ms" : ""}${message ? " (" + message + ")" : ""}`);
    pushState();
  };

  const timer = setTimeout(
    () => finish("error", `连不上 ${addr} —— 检查地址，或确认这台机器能访问外网`),
    5000
  );

  const open = (type, payload) => {
    const s = net.createConnection(port, host, () => {
      s.setNoDelay(true);
      s.write(buildFrame(type, payload));
    });
    const parser = new FrameParser((t, pl) => {
      if (t === T.RELAY_PAIRED) finish("ok", null);
      else if (t === T.RELAY_ERROR) {
        let reason = "";
        try { reason = JSON.parse(pl.toString()).reason || ""; } catch {}
        finish("error", reason === "unauthorized"
          ? "访问 Token 不正确 —— 到中转设置里核对"
          : `服务器拒绝：${reason || "未知原因"}`);
      }
    });
    s.on("data", (d) => { try { parser.feed(d); } catch {} });
    s.on("error", (e) => finish("error", `连不上 ${addr}（${e.code || e.message}）`));
    socks.push(s);
    return s;
  };

  const base = { v: 1, code: "", pairHash: room };
  if (tok) base.token = tok;
  open(T.RELAY_REGISTER, { ...base, role: "sender" });
  // 稍等一下再 join：房间得先建起来，否则会拿到 code_not_found 而误判成服务器有问题
  setTimeout(() => { if (!done) open(T.RELAY_JOIN, { ...base, role: "receiver" }); }, 250);
}

// ===== CLI 联调入口 =====
// 界面已经没有「填地址/填码」的输入框了，但联调脚本还要能不经界面直接连。
// 这两个函数就是那条旁路，走的仍是同一套 connectAuto / RELAY_JOIN 逻辑。
function connectDirectCli(addr, alsoRace) {
  const port = +((config.args && config.args.port) || 47800);
  const host = String(addr).split(":")[0];
  if (alsoRace && pairHashHex()) {
    if (!selectedDevice()) devices.push({ id: "cli", secret: pairSecret(), name: "", alias: null, addr });
    selectedId = "cli";
    return connectAuto();
  }
  connecting = true;
  setStatus(`连接 ${host}:${port} …`);
  sock = net.createConnection(port, host, () => {
    sock.setNoDelay(true);
    setStatus("已连接，握手中…");
    sendHello();
  });
  wireSocket();
}

function connectRelayCli(code) {
  const hash = pairHashHex();
  if (!/^\d{6}$/.test(String(code || "")) && !hash) {
    return setStatus("需要 6 位配对码或已持久配对", true);
  }
  connecting = true;
  const [host, portStr] = prefs.relayServer.trim().split(":");
  setStatus(`连接中转 ${host} …`);
  sock = net.createConnection(+portStr || 47700, host, () => {
    sock.setNoDelay(true);
    const join = { v: 1, role: "receiver", code: "" };
    if (prefs.token.trim()) join.token = prefs.token.trim();
    if (/^\d{6}$/.test(String(code || ""))) {
      setStatus(`配对中（码 ${code}）…`);
      join.code = String(code);
    } else {
      setStatus("已持久配对，撮合中…");
      join.pairHash = hash;
    }
    sock.write(buildFrame(T.RELAY_JOIN, join));
  });
  wireSocket();
}

function helloPayload() {
  return {
    version: 1,
    role: "receiver",
    name: localName, // v1.10：用户可编辑的设备名，对端拿它显示在设备列表里
    deviceId,
    screen: desiredScreen(),
    codecs: supportedCodecs, // v1.3：解码能力（偏好序），老 Sender 忽略
    lanAddrs: (config && config.lanAddrs) || [], // v1.9：供对端尝试连接升级
  };
}
function sendHello() {
  sock.write(buildFrame(T.HELLO, helloPayload()));
}

// ===== v1.9 §3.5 连接升级：中转 → 直连 =====
// transport 是程序探测出的状态，不是用户选项。走中转连上后，在后台悄悄试直连，
// 通了就无感切过去。**只在待命时做**——投射中切链路会让画面中断。
let currentTransport = "relay"; // "relay" | "direct"
let upgradeTried = false;
let upgradeHandshakePending = false; // 切到直连后正在等对端重发 HELLO_ACK

function tryUpgradeToDirect(peerLanAddrs) {
  const why = currentTransport === "direct" ? "已是直连"
    : upgradeTried ? "本次会话已试过"
    : !Array.isArray(peerLanAddrs) || !peerLanAddrs.length ? "对端没给 lanAddrs"
    // 判「投射中」要看是否真在收帧，不能只看 projActive：它初值为 true（为兼容
    // 不发 PROJECTION_STATE 的老 Sender），握手阶段一律为真，会把升级全挡掉。
    : (projActive && stats.total.recv > 0) ? "正在投射中（MVP 不切链路）" : null;
  if (why) { console.log(`[recv] 跳过直连升级：${why}`); return; }
  upgradeTried = true;
  console.log(`[recv] 尝试直连升级 → ${peerLanAddrs.join(", ")}`);

  const relaySock = sock;
  const probes = [];
  let done = false;

  const finish = (winner, addr, seenFrames) => {
    if (done) { winner && winner.destroy(); return; }
    done = true;
    for (const p of probes) if (p !== winner) p.destroy();
    if (!winner) {
      console.log("[recv] 直连升级未成功，继续走中转");
      return;
    }
    // 切换：新 socket 接管，旧的中转连接拆掉
    console.log(`[recv] ✅ 已升级到直连 ${addr}（原中转连接关闭）`);
    currentTransport = "direct";
    manualDisconnect = true; // 关旧连接不该触发重连
    try { relaySock.destroy(); } catch {}
    manualDisconnect = false;
    sock = winner;
    wireSocket();
    // 探测发的 HELLO 已经让对端建好了会话，HELLO_ACK 也已经在探测期收到了。
    // **不能再发一次 HELLO** —— 对端会当成新连接再起一个会话，实测出现三个会话
    // 并存、帧发到没人收的那条上，表现为「升级成功但 recv=0」。
    // 正确做法是把探测期读到的帧回放给正式解析器（同 connectAuto 的处理）。
    const replay = seenFrames || [];
    console.log(`[recv] 回放探测期收到的 ${replay.length} 帧: ` +
      replay.map(([t]) => "0x" + t.toString(16)).join(","));
    for (const [t, p] of replay) {
      try { onFrame(t, p); } catch (e) { console.log("[recv] 回放出错: " + e.message); }
    }
    console.log(`[recv] 回放后 display=${display ? display.width + "x" + display.height : "null"}`);
    setStatus(`已连接 · 直连 ${addr.split(":")[0]}`);
  };

  for (const addr of peerLanAddrs.slice(0, 4)) {
    const m = /^\[?([^\]]+)\]?:(\d+)$/.exec(addr);
    if (!m) continue;
    const s = net.createConnection(+m[2], m[1]);
    probes.push(s);
    s.setNoDelay(true);
    s.on("connect", () => {
      // ⚠️ connect 成功不算通：Mihomo/Clash 的 TUN 透明代理下，连一个根本
      // 不存在的地址 connect 也会成功（实测 10.99.99.99）。必须等对端按协议应答。
      s.write(buildFrame(T.HELLO, helloPayload()));
    });
    const seen = [];
    const p = new FrameParser((t, pl) => {
      seen.push([t, Buffer.from(pl)]); // 全部留存，胜出后回放，避免丢掉 HELLO_ACK
      // 等 HELLO_ACK 而不是 HELLO：只有它才代表对端已建好会话、带着尺寸和 codec。
      if (t === T.HELLO_ACK) {
        s.removeAllListeners("data");
        finish(s, addr, seen);
      }
    });
    s.on("data", (d) => { try { p.feed(d); } catch { s.destroy(); } });
    s.on("error", () => {});
  }
  if (!probes.length) { upgradeTried = false; return; }
  setTimeout(() => finish(null), 1500); // 超时就安静地留在中转，不打扰用户
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
    case T.HELLO: {
      console.log("[recv] sender HELLO: " + payload.toString());
      // 记住对端 deviceId：下次连接不必先握手就能算出该谁 listen（规范第 2 条）
      try {
        const h = JSON.parse(payload.toString());
        // v1.9：拿到对端内网地址就在后台试直连升级（当前若已是直连则跳过）
        if (h.lanAddrs) setTimeout(() => tryUpgradeToDirect(h.lanAddrs), 200);
        // v1.10：对端自报的设备名。别名仍然优先——那是本机用户自己起的。
        peerName = "";
        const dd = selectedDevice();
        if (dd) {
          if (h.name) dd.name = String(h.name).slice(0, 40);
          dd.online = true;
          saveDevices(devices);
          peerName = deviceLabel(dd);
        } else if (h.name) peerName = String(h.name).slice(0, 40);
        if (h.deviceId) {
          const known = role.getPeerId();
          role.rememberPeer(h.deviceId);
          if (!known) {
            const pos = role.myPosition(deviceId);
            console.log(`[recv] 已确定默认连接角色：本机 ${pos} 位（${pos === "A" ? "常驻等待" : "主动连接"}）`);
          }
        }
      } catch {}
      break;
    }
    case T.HELLO_ACK: {
      const ack = JSON.parse(payload.toString());
      if (!ack.accepted) return teardown("对端拒绝: " + (ack.reason || "unknown"));
      console.log("[recv] HELLO_ACK: " + payload.toString());
      sessionCodec = CODEC_MAP[ack.codec] ? ack.codec : "h264"; // v1.3 协商结果
      if (ack.pairSecret) { // v1.4 持久配对：存到这台设备上，之后免输码
        const d = selectedDevice();
        if (d) { d.secret = ack.pairSecret; saveDevices(devices); }
        else localStorage.setItem("pairSecret", ack.pairSecret);
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
      // 中途流参数变化（如单窗口投射 resize）：更新尺寸 + 重置解码器等关键帧（协议 §5）
      console.log("[recv] VIDEO_CONFIG: " + payload.toString());
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
      // 交接期兼容：新版两端各自从码算 pairHash 进同一个房间（协议 §3.7），
      // 老版则是「发送方用明文码注册、接收方用明文码 join」。用户很可能先拿到
      // 一端的新版——那时两边输一样的码却各进各的房间，撮合不上，而两边日志
      // 都正常，用户只会看到「配对码不存在」。所以 pairHash 没找到房间时，
      // 自动再用明文码试一次。等两端都升级后这条路自然不会被走到。
      const dd = selectedDevice();
      if (r === "code_not_found" && !plainCodeTried && dd && dd.code) {
        plainCodeTried = true;
        console.log("[recv] pairHash 房间无人，回退用明文码再试一次（对端可能是老版本）");
        teardown(null, true);
        return connectRelayCli(dd.code);
      }
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
    this.total = { recv: 0, decoded: 0, dropped: 0, bytes: 0, annexbBytes: 0, keyframes: 0, decodeErrors: 0, rtts: [] };
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

// 背压参数：队列长度阈值 + 需连续超标次数（区分突发到达与真积压）
const QUEUE_HIGH = 24;
const QUEUE_HIGH_STREAK = 3;
let queueHighStreak = 0;

let lastKeyframeReq = 0;
function requestKeyframe(throttleMs = 0) {
  // 背压恢复用节流，避免每帧都请求；解码错误等场景不节流（throttleMs=0）
  const now = performance.now();
  if (throttleMs && now - lastKeyframeReq < throttleMs) return;
  lastKeyframeReq = now;
  if (sock && !sock.destroyed) sock.write(buildFrame(T.REQUEST_KEYFRAME));
}

function handleVideo(payload) {
  const v = parseVideoPayload(payload);
  stats.recv++; stats.total.recv++; stats.bytes += payload.length; stats.total.bytes += payload.length;
  stats.total.annexbBytes += v.data.length; // 对账口径：只算 Annex-B，与 Sender/Mac 一致
  if (v.keyframe) stats.total.keyframes++;

  if (!decoder || decoder.state === "closed") return;
  if (waitingKey && !v.keyframe) { stats.dropped++; stats.total.dropped++; return; }
  if (waitingKey) queueHighStreak = 0; // 关键帧到达，重新计数
  waitingKey = false;

  // 背压：解码队列真积压时丢到下一个关键帧（低延迟优先，协议 §4）
  //
  // 阈值不能太小：中转链路（实测 RTT 400–600ms）上帧是**突发到达**的——TCP 缓冲一次吐出
  // 十几帧，队列瞬时冲高但会被硬解迅速消化。按瞬时值丢帧会把正常突发误判成积压，
  // 触发「丢帧→请关键帧→等一个 RTT→再丢」的循环。实测阈值 8 时解码率仅 84%。
  // 改为：更高阈值 + 需连续多次采样都超标（真积压才会持续），突发不误伤。
  if (!v.keyframe && decoder.decodeQueueSize > QUEUE_HIGH) {
    if (++queueHighStreak >= QUEUE_HIGH_STREAK) {
      stats.dropped++; stats.total.dropped++;
      waitingKey = true;
      // 必须主动要关键帧：否则要等对端周期 GOP（Mac 2s）才恢复，期间整段丢弃。
      // 跨机联调实测：不请求时 50 帧只解出 14 帧。
      requestKeyframe(1000);
      return;
    }
  } else {
    queueHighStreak = 0;
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

  setStatus("");
  stage.style.display = "flex";
  $("toolbar").style.display = "flex";
  hint.style.display = "block";
  overlay.style.display = prefs.overlayOn ? "block" : "none";
  // 收到画面 = 本机正在被当显示器用。设计里这就是 receiving 态，
  // 窗口要自己弹出来（syncReceiveWindow 会通知主进程显示）。
  setRole("receiving");
  if (prefs.windowed) {
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
    ipcRenderer.send("set-fullscreen", false);
    if (reason) setStatus(reason, true);
    // 画面没了就不再是 receiving。casting 不受影响——那是发送侧的事。
    if (uiRole === "receiving") setRole("standby");
    else pushState();
    // 规范第 5 条：非主动切换的断线一律回默认角色，否则反转状态下两端各自
    // 按「上次的角色」重连，可能双方都 listen 或都 dial。
    if (!switchingDirection && role.isReversed()) {
      role.resetToDefault();
      console.log("[recv] 断线 → 已回到默认连接角色（防双方角色冲突）");
    }
    scheduleReconnect(reason); // v1.4：持久配对场景自动重连
  }
}

// ================= UI 事件 =================
// 主面板与托盘都在别的窗口里，这里只剩接收窗口自己的交互（工具栏、快捷键）。
// 界面上的按钮一律走 nd-cmd（见 UI-CONTRACT.md），不再有 onclick 绑定。

const sendStatus = (s) => {
  if (s) console.log("[sender] " + s); // headless 模式转到 stdout，和 setStatus 的 [recv] 对称
};

// WS-3：投射源列表（整屏 / 单窗口）
let sourceList = [];
async function refreshSources() {
  sourceList = await sender.listSources();
  // 记住的选择如果对应的窗口已经关掉了，就退回整屏——但要说出来。
  // 「悄悄换成别的东西投出去」是这个项目踩过的坑，不能再犯。
  if (pickSel && !sourceList.some((s) => s.id === pickSel)) {
    pickSel = "";
    localStorage.setItem("pickSel", "");
    toast("原来投射的窗口已关闭，已切回整块屏幕");
  }
  applySource();
}
function applySource() {
  sender.setSource(pickSel ? sourceList.find((s) => s.id === pickSel) : null);
}

// 「投射本机」是一个动作，不再让用户选 listen 还是 register ——
// 走哪条由上面设的「连接方式」决定，这是 10-ux-model 的核心：
// transport（连接方式）与 role（谁投谁）是正交的，不该塞进同一个按钮。
// v1.4 目标端控制：弹回 / 停止（Mac 收到后会转空闲并发 PROJECTION_STATE{active:false}）
$("btnBounce").onclick = () => sendControl("bounceBack");
$("btnStop").onclick = () => sendControl("stop");

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
    if (escDown == null) escDown = setTimeout(() => { manualDisconnect = true; teardown("已断开"); }, 800);
  } else if (e.key === "F1" && streaming) {
    e.preventDefault();
    const on = overlay.style.display !== "block";
    overlay.style.display = on ? "block" : "none";
    setPref("overlayOn", on);
  }
});
$("winClose").onclick = () => handleCmd({ cmd: "drop-stream" });
$("winMin").onclick = () => ipcRenderer.send("nd-receive-window", { minimize: true });
window.addEventListener("keyup", (e) => {
  if (e.key === "Escape") { clearTimeout(escDown); escDown = null; }
});

// ================= 启动 =================
(async () => {
  config = await ipcRenderer.invoke("config");
  loadPrefs();
  document.body.dataset.theme = prefs.theme;
  await detectCodecs();
  const a = config.args || {};
  if (a.res) setPref("res", a.res);
  if (a.scale) setPref("scale", a.scale);
  if (a.windowed) setPref("windowed", true);
  if (a.secret) sharedSecret = a.secret; // 联调：共享固定配对
  if (a.pairhash) sharedHash = a.pairhash;
  if (a.testPairSecret) localStorage.setItem("pairSecret", a.testPairSecret);
  // --pair-code：等价于用户在配对弹窗里输了这个码。走的就是 doPair 那条真实
  // 路径，所以能测到明文码回退这类只在有设备记录时才生效的逻辑。
  if (a.pairCode) doPair(a.pairCode, null);
  if (a.token) setPref("token", a.token);
  if (a.server) setPref("relayServer", a.server);
  await refreshSources();
  pushState();
  // --probe-relay：只测中转、打印结论、退出。单独开这个口子是因为 isCliRun 会在
  // 联调跑批时跳过探测，而 --exit-after 正属于跑批——照那样写，验证探测的测试
  // 恰好碰不到被测的代码。这个坑我刚提醒过 Mac，自己转头就踩了一次。
  if (a.probeRelay) {
    probeRelay();
    setTimeout(() => {
      console.log("PROBE_RESULT " + JSON.stringify(relayHealth));
      ipcRenderer.send("test-result", JSON.stringify(relayHealth));
    }, 7000);
    return;
  }
  if (!isCliRun(a)) probeRelay(); // 联调跑批时别多开两条连接干扰计数
  // 测试：--send-window <名字子串> 选中匹配的窗口作为投射源
  if (a.sendWindow) {
    sender.requireWindow(a.sendWindow); // 声明后不允许悄悄退回整屏
    const m = sourceList.find((s) => s.kind === "window" && s.name.includes(a.sendWindow));
    if (m) {
      pickSel = m.id;
      applySource();
      console.log(`SEND_SOURCE OK kind=${m.kind} name="${m.name}" id=${m.id}`);
    } else {
      console.log(`SEND_SOURCE_NOT_FOUND "${a.sendWindow}" —— 可选窗口: ` +
        sourceList.filter((s) => s.kind === "window").map((s) => `"${s.name}"`).join(", "));
    }
  }
  if (a.send) { await sender.startSender(sendStatus); setRole("casting"); }
  else if (a.sendRelay) {
    await sender.startSenderRelay(sendStatus, {
      server: a.server || prefs.relayServer.trim(),
      token: a.token || undefined,
      fixedCode: a.sendRelayCode || undefined,
      forceCode: !!a.sendRelayCode,
      secret: a.secret || undefined, // 共享固定配对（联调）
      pairHash: a.pairhash || undefined,
    });
    setRole("casting");
  }
  // 接收端 headless 中转待命（配 --secret/--pairhash，零码零点击）
  if (a.recvRelay) connectRelayCli(null);
  // 接收端计数导出，字段对标 Mac 的 RECV_STATS
  if (a.recvStatsAfter) {
    const dump = () => {
      const t = stats.total;
      const rtts = t.rtts;
      console.log("RECV_STATS " + JSON.stringify({
        codec: sessionCodec,
        width: display ? display.width : null,
        height: display ? display.height : null,
        recv: t.recv, decoded: t.decoded, dropped: t.dropped,
        errors: t.decodeErrors, keyframes: t.keyframes,
        bytes: t.annexbBytes, // Annex-B 口径，可与对端 SEND_STATS 直接对账
        wireBytes: t.bytes, // 含 9 字节 pts+flags 头的线上字节
        avgRttMs: rtts.length ? +(rtts.reduce((x, y) => x + y) / rtts.length).toFixed(2) : null,
      }));
    };
    setTimeout(dump, +a.recvStatsAfter * 1000);
    if (a.recvStatsRepeat) setInterval(dump, +a.recvStatsAfter * 1000);
  }
  if (a.autoBounce) setTimeout(() => sendControl("bounceBack"), +a.autoBounce * 1000);
  // 互调用：N 秒后打印发送侧统计（不退出，便于继续观察长时会话）
  if (a.sendStatsAfter) {
    const dump = () => console.log("SEND_STATS " + JSON.stringify(sender.getSenderStats()));
    setTimeout(dump, +a.sendStatsAfter * 1000);
    if (a.sendStatsRepeat) setInterval(dump, +a.sendStatsAfter * 1000);
  }
  if (a.autoConnect) connectDirectCli(a.autoConnect, true);
  else if (a.connect) connectDirectCli(a.connect, false);
  else if (a.relay != null) connectRelayCli(a.relay);
  else if (selectedDevice()) {
    // 已配对 → 启动即开接收服务待命。设计要求「配对后开机自动连、不用再输码」。
    setRecvSvc(true);
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
