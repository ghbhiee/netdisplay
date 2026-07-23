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
let switchingDirection = false; // 正在为「换投射方向」而重建连接 → 这次断线不算异常，不重置角色
let reconnectTimer = null;
let reconnectDelay = 1000;

let sharedSecret = null; // --secret：联调用共享固定密钥（优先于持久保存的）
let sharedHash = null; // --pairhash：直接指定房间

function pairSecret() {
  return sharedSecret || localStorage.getItem("pairSecret") || null;
}
function pairHashHex() {
  if (sharedHash) return sharedHash;
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

// ================= 设置（全部持久化） =================
const FIELDS = ["ip", "code", "relayServer", "token", "res", "scale", "fps", "bitrate", "customW", "customH"];
const CHECKS = ["windowed", "overlayOn"];
// 默认「等对方连我」——它不需要用户填任何东西就能开始，是零输入的起点
let mode = localStorage.getItem("pref.mode") || "listen";

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

// 用户只需回答一个问题：**我等对方连我，还是我去连对方**。
// 「直连 vs 中转」不再是要选的模式——填了地址就试直连、填了配对码就试中转，
// 两个都填就并行竞速。这样「自动」这个需要理解的概念自然消失了。
function applyMode(m) {
  mode = m;
  localStorage.setItem("pref.mode", m);
  $("gListen").classList.toggle("on", m === "listen");
  $("gConnect").classList.toggle("on", m === "connect");
}
for (const g of [$("gListen"), $("gConnect")]) {
  g.querySelector(".head").addEventListener("click", () => applyMode(g.dataset.mode));
}

// 我的配对码：长期有效、持久保存（用户明确要求「配对码可以是长期有效的」）。
// 每次重启换新码会让对方反复来问，体验很差。
function myPairCode() {
  let c = localStorage.getItem("my.pairCode");
  if (!/^\d{6}$/.test(c || "")) {
    c = String(100000 + (nodeCrypto.randomBytes(4).readUInt32BE(0) % 900000));
    localStorage.setItem("my.pairCode", c);
  }
  return c;
}
function refreshListenInfo() {
  $("myCode").textContent = myPairCode();
  const ip = (config && config.lanIp) || "获取中…";
  $("myAddr").textContent = ip === "获取中…" ? ip : `${ip}:47800`;
}
$("btnNewCode").onclick = () => {
  localStorage.removeItem("my.pairCode");
  refreshListenInfo();
  setStatus("已换新配对码，需要把新码告诉对方");
};
$("btnCopyAddr").onclick = () => {
  navigator.clipboard.writeText($("myAddr").textContent).then(
    () => setStatus("地址已复制"), () => setStatus("复制失败", true));
};
$("btnAdv").onclick = () => {
  const a = $("adv");
  a.classList.toggle("hidden");
  $("btnAdv").textContent = a.classList.contains("hidden") ? "高级设置 ▾" : "高级设置 ▴";
};

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
  if (msg) console.log("[recv] " + msg); // headless 模式转到 stdout，便于 CLI 联调排障
}

// ================= 面板状态 =================
function showPanel(overStream) {
  panel.style.display = "flex";
  panel.classList.toggle("over-stream", !!overStream);
  $("btnConnect").textContent = overStream ? "应用并重连" : "连接";
  $("btnDisconnect").style.display = overStream ? "block" : "none";
  $("btnClose").style.display = overStream ? "block" : "none";
  refreshRoleBar();
}

// 角色开关只在「已连上或正在投射」时才有意义——没连接时点「投射本机」没有对象
function refreshRoleBar() {
  const linked = !!sock || sender.isSending();
  $("roleBar").classList.toggle("hidden", !linked);
  const projecting = sender.isSending();
  $("btnProject").style.display = projecting ? "none" : "block";
  $("btnProjectStop").style.display = projecting ? "block" : "none";
  pushTrayState();
}

// 把状态推给托盘，让菜单能显示当前值并高亮选中项
function pushTrayState() {
  try {
    ipcRenderer.send("tray-state", {
      connected: !!sock || sender.isSending(),
      projecting: sender.isSending(),
      res: $("res").value, scale: $("scale").value, fps: $("fps").value,
      sources: sourceList.filter((s) => s.kind === "window").map((s) => ({ id: s.id, name: s.name })),
      source: $("sendSource").value,
      code: myPairCode(),
    });
  } catch {}
}

// 托盘菜单里改参数 → 等同于在主界面改（含持久化与重连生效）
ipcRenderer.on("tray-cmd", (_e, m) => {
  if (m.cmd === "set") {
    $(m.key).value = m.value;
    localStorage.setItem("pref." + m.key, m.value);
    if (m.key === "res") syncCustomVisibility();
    pushTrayState();
    // 画质是「作为目标时」的请求，改了要重连才生效（HELLO.screen 在握手时发）
    if (sock) { setStatus("画质已改，正在重连生效…"); connect(); }
  } else if (m.cmd === "set-source") {
    $("sendSource").value = m.value;
    applySource();
    pushTrayState();
  } else if (m.cmd === "start-project") {
    $("btnProject").click();
  } else if (m.cmd === "stop-project") {
    $("btnProjectStop").click();
  }
});
function hidePanel() {
  panel.style.display = "none";
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
  const ip = $("ip").value.trim();
  const [host, portStr] = $("relayServer").value.trim().split(":");
  const code = $("code").value.trim();
  const hash = pairHashHex();
  const tok = $("token").value.trim();
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

// 监听模式：同时开两条入口等对方来连——47800 供局域网直连，中转用长期配对码注册。
// 用户不必选「直连还是中转」，对方用哪种都能连上。
async function startListening() {
  setStatus("正在待命，等对方连接…");
  await sender.startSender(sendStatus); // 监听 47800
  const server = $("relayServer").value.trim();
  if (server) {
    await sender.startSenderRelay(sendStatus, {
      server, token: $("token").value.trim() || undefined,
      fixedCode: myPairCode(), forceCode: !pairSecret(), // 已配对则走 pairHash 免码
    });
  }
  refreshRoleBar();
  setStatus(`待命中 · 配对码 ${myPairCode()} · 或直连 ${$("myAddr").textContent}`);
}

function connect() {
  // 运行中「应用并重连」：先静默断开，再按当前设置重连
  if (sock) teardown(null, true);

  // 监听模式：本机待命等对方来连。两条路同时开着——监听 47800 供局域网直连，
  // 同时用我的长期配对码在中转注册，对方用哪种方式都能连上。
  if (mode === "listen") return startListening();

  // 连接模式：填了什么就试什么；两个都填就并行竞速（先握手成功的胜出）
  const ip = $("ip").value.trim();
  const code = $("code").value.trim();
  const hasCode = /^\d{6}$/.test(code) || !!pairHashHex();
  if (ip && hasCode) return connectAuto();
  if (!ip && !hasCode) return setStatus("请填写对方的配对码，或它的局域网地址", true);
  if (ip) {
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

function helloPayload() {
  return {
    version: 1,
    role: "receiver",
    name: os.hostname(),
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

  const finish = (winner, addr) => {
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
    // 探测时只发了 HELLO 就停下等应答，会话状态（HELLO_ACK/尺寸/codec）还没建立。
    // 切过来后必须让对端重走一遍握手，否则新链路上永远等不到 HELLO_ACK，视频起不来。
    upgradeHandshakePending = true;
    sock.write(buildFrame(T.HELLO, helloPayload()));
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
    const p = new FrameParser((t) => {
      if (t === T.HELLO || t === T.HELLO_ACK) {
        s.removeAllListeners("data");
        finish(s, addr);
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
  role.clearPairing(); // 连接角色也是配对的一部分，一并清掉，否则会拿旧 peerId 算角色
  updatePairInfo();
  setStatus("已解除配对，下次连接需重新输入配对码");
};

const sendStatus = (s) => {
  $("sendStatus").textContent = s;
  if (s) console.log("[sender] " + s); // headless 模式转到 stdout，和 setStatus 的 [recv] 对称
};

// WS-3：投射源列表（整屏 / 单窗口）
let sourceList = [];
async function refreshSources() {
  const keep = $("sendSource").value;
  sourceList = await sender.listSources();
  const sel = $("sendSource");
  sel.innerHTML = '<option value="">整个屏幕</option>';
  for (const s of sourceList.filter((x) => x.kind === "window")) {
    const o = document.createElement("option");
    o.value = s.id;
    o.textContent = s.name.length > 42 ? s.name.slice(0, 40) + "…" : s.name;
    sel.appendChild(o);
  }
  if (keep && sourceList.some((s) => s.id === keep)) sel.value = keep;
  applySource();
}
function applySource() {
  const id = $("sendSource").value;
  sender.setSource(id ? sourceList.find((s) => s.id === id) : null);
}
$("btnRefreshSources").onclick = refreshSources;
$("sendSource").onchange = applySource;

// 「投射本机」是一个动作，不再让用户选 listen 还是 register ——
// 走哪条由上面设的「连接方式」决定，这是 10-ux-model 的核心：
// transport（连接方式）与 role（谁投谁）是正交的，不该塞进同一个按钮。
$("btnProject").onclick = async () => {
  applySource();
  const pos = role.myPosition(deviceId);

  // 规范第 4 条：A 位本就是 sender，直接开投无需重连；B 位必须反转角色重建连接。
  if (sock) {
    if (pos === "B") {
      // 我是 B 位（dial/join），想投必须占到 A 位 → 反转 + 重建
      setStatus("切换中… 正在接管投射方向");
      sendControl("stop"); // 让对方先转空闲（抢投编排，规范第 6 条）
      role.markReversedForProjecting(deviceId);
      switchingDirection = true; // 这次断线是有意的，不要重置角色
      manualDisconnect = true;
      teardown(null, true);
      await new Promise((r) => setTimeout(r, 400)); // 给对方处理 stop 的时间
      manualDisconnect = false;
      switchingDirection = false;
    } else {
      // A 位或未配对：仅让对方停投，连接不用重建
      setStatus("切换中… 正在请对方停止投射");
      sendControl("stop");
      manualDisconnect = true;
      teardown(null, true);
      await new Promise((r) => setTimeout(r, 300));
      manualDisconnect = false;
    }
  } else if (pos === "B") {
    // 没连接但我默认是 B 位：直接投的话对方不会来连我，先反转成 A 位
    role.markReversedForProjecting(deviceId);
  }
  const useDirect = mode === "direct" || (mode === "auto" && !pairSecret());
  if (useDirect) {
    sendStatus("正在等待对方连入…");
    await sender.startSender(sendStatus);
  } else {
    await sender.startSenderRelay(sendStatus, {
      server: $("relayServer").value.trim(),
      token: $("token").value.trim() || undefined,
    });
  }
  refreshRoleBar();
};
$("btnProjectStop").onclick = () => {
  sender.stopSender();
  refreshRoleBar();
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
  refreshListenInfo();
  updatePairInfo();
  pushTrayState();
  await detectCodecs();
  const a = config.args || {};
  if (a.res) $("res").value = a.res;
  if (a.scale) $("scale").value = a.scale;
  if (a.windowed) $("windowed").checked = true;
  if (a.secret) sharedSecret = a.secret; // 联调：共享固定配对
  if (a.pairhash) sharedHash = a.pairhash;
  if (a.testPairSecret) { localStorage.setItem("pairSecret", a.testPairSecret); updatePairInfo(); }
  if (a.token) $("token").value = a.token;
  await refreshSources();
  // 测试：--send-window <名字子串> 选中匹配的窗口作为投射源
  if (a.sendWindow) {
    sender.requireWindow(a.sendWindow); // 声明后不允许悄悄退回整屏
    const m = sourceList.find((s) => s.kind === "window" && s.name.includes(a.sendWindow));
    if (m) {
      $("sendSource").value = m.id;
      applySource();
      // 确认 select 真的接受了这个值：option 不存在时赋值会被静默丢弃，
      // 那样会退回整屏，而对端只会看到「尺寸是整屏」，很难反推原因。
      const ok = $("sendSource").value === m.id;
      console.log(`SEND_SOURCE ${ok ? "OK" : "SELECT_REJECTED"} kind=${m.kind} name="${m.name}" id=${m.id}`);
      if (!ok) console.log("SEND_SOURCE_FALLBACK 将退回整屏投射");
    } else {
      console.log(`SEND_SOURCE_NOT_FOUND "${a.sendWindow}" —— 可选窗口: ` +
        sourceList.filter((s) => s.kind === "window").map((s) => `"${s.name}"`).join(", "));
    }
  }
  if (a.send) { await sender.startSender(sendStatus); refreshRoleBar(); }
  else if (a.sendRelay) {
    await sender.startSenderRelay(sendStatus, {
      server: a.server || $("relayServer").value.trim(),
      token: a.token || undefined,
      fixedCode: a.sendRelayCode || undefined,
      forceCode: !!a.sendRelayCode,
      secret: a.secret || undefined, // 共享固定配对（联调）
      pairHash: a.pairhash || undefined,
    });
    refreshRoleBar();
  }
  // 接收端 headless 中转待命（配 --secret/--pairhash，零码零点击）
  if (a.recvRelay) {
    applyMode("relay");
    if (a.server) $("relayServer").value = a.server;
    if (a.token) $("token").value = a.token;
    $("code").value = ""; // 强制走 pairHash 路径
    connect();
  }
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
  if (a.autoConnect) { applyMode("auto"); $("ip").value = a.autoConnect; connect(); }
  else if (a.connect) { applyMode("direct"); $("ip").value = a.connect; connect(); }
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
