// NetDisplay — Electron 主进程
//
// 三个窗口，职责分明（见 windows/src/UI-CONTRACT.md）：
//   engine  index.html  网络/协议/解码/采集。平时隐藏；对方投过来时它**就是**
//                       设计里那个「接收显示窗口」。是唯一状态源。
//   panel   panel.html  主面板。纯界面，不碰 socket。
//   tray    tray.html   托盘弹出菜单。设计要的彩色图标+两行条目+内联 chip，
//                       原生 Menu 做不到，所以自绘一个无边框置顶窗口。
// 三者互不直接通信，全部经这里中转。
"use strict";
const { app, BrowserWindow, ipcMain, screen, Tray, nativeImage, desktopCapturer, clipboard } = require("electron");
const path = require("path");

const argv = process.argv.slice(1);
const arg = (name) => {
  const i = argv.indexOf("--" + name);
  return i >= 0 ? argv[i + 1] : null;
};
const testArgs = {
  connect: arg("connect"),
  port: arg("port"),
  relay: arg("relay"),
  server: arg("server"),
  exitAfter: arg("exit-after"),
  res: arg("res"),
  scale: arg("scale"),
  windowed: arg("windowed"),
  autoBounce: arg("auto-bounce"), // 测试：N 秒后自动发 CONTROL bounceBack
  token: arg("token"), // 测试：relay 访问令牌
  testPairSecret: arg("test-pair-secret"), // 测试：预置 pairSecret（base64）
  pairCode: arg("pair-code"), // 测试：按 6 位码建一条配对设备并选中，走真实 UI 路径
  showTray: argv.includes("--show-tray") ? "1" : null, // 测试：启动后自动弹出托盘菜单（否则只能手点图标，没法自动核对）
  probeRelay: argv.includes("--probe-relay") ? "1" : null, // 测试：只做一次中转健康探测，打印结论后退出
  send: argv.includes("--send") ? "1" : null, // 启动即开发送端（WS-1）
  sendRelay: argv.includes("--send-relay") ? "1" : null, // 启动即开中转发送（WS-2）
  sendRelayCode: arg("send-relay-code"), // 测试：固定配对码（并强制走码注册）
  autoConnect: arg("auto-connect"), // 测试：自动模式连接（并行直连+中转），值为直连地址
  sendWindow: arg("send-window"), // 测试：按标题子串选窗口作为投射源（WS-3）
  sendStatsAfter: arg("send-stats-after"), // 互调：N 秒后打印 SEND_STATS（需 --enable-logging）
  sendStatsRepeat: argv.includes("--send-stats-repeat") ? "1" : null,
  secret: arg("secret"), // 联调：共享固定 pairSecret（base64），零配对码待命
  pairhash: arg("pairhash"), // 联调：直接指定房间 pairHash（hex），不下发 secret
  headless: argv.includes("--headless") ? "1" : null, // 无窗口 CLI 模式
  recvRelay: argv.includes("--recv-relay") ? "1" : null, // 接收端：中转 join（配 --secret/--pairhash）
  recvStatsAfter: arg("recv-stats-after"), // 接收端：N 秒后打印 RECV_STATS
  recvStatsRepeat: argv.includes("--recv-stats-repeat") ? "1" : null,
};
const isTest = !!testArgs.exitAfter;
const isHeadless = !!testArgs.headless; // CLI 待命模式：无窗口、无托盘、日志走 stdout
const uiEnabled = !isTest && !isHeadless;

// 测试隔离：多实例并跑时各用独立 userData（否则 localStorage 抢锁、写入不落盘）
const userDataDir = arg("user-data");
if (userDataDir) app.setPath("userData", userDataDir);

let engineWin = null;   // 网络/解码/采集 + 接收画面
let panelWin = null;    // 主面板
let trayWin = null;     // 托盘弹出菜单
let tray = null;
let quitting = false;

// 引擎推上来的最新状态。panel/tray 起来时先拿这份快照，避免开局空白。
//
// 初值不能是 null。panel/tray 一起来就 invoke("nd-state-get")，那时引擎多半还没
// 推过状态；给 null 的话它们会在 `state.role` 上抛异常，而异常发生在首次绘制之前
// → ready-to-show 永远不触发 → **窗口根本不出现**。实测就是这个症状：进程活着、
// 三个 renderer 都加载了、日志毫无报错，但桌面上一个窗口也没有。
const EMPTY_STATE = {
  role: "standby", recvSvc: "off", devices: [], selectedId: null,
  sources: [], pickSel: "",
  quality: { res: "auto", scale: "1", fps: "60", rate: "auto" },
  relay: { addr: "", token: "", forceRelay: false, status: "unset", rttMs: null },
  localName: require("os").hostname(), peerName: "", castSourceName: "整块屏幕",
  theme: "dark",
};
let lastState = EMPTY_STATE;

if (!app.requestSingleInstanceLock() && !isTest) {
  app.quit();
} else {
  app.on("second-instance", () => showPanel());
}

const ASSET = (f) => path.join(__dirname, "assets", f);
const WEBPREFS = { nodeIntegration: true, contextIsolation: false, backgroundThrottling: false };

function createEngine() {
  engineWin = new BrowserWindow({
    width: 1440, height: 900,
    icon: ASSET("icon.png"),
    show: false, // 平时藏着；收到投射时 nd-receive-window 会叫它出来
    backgroundColor: "#000000",
    autoHideMenuBar: true,
    title: "NetDisplay",
    webPreferences: WEBPREFS,
  });
  engineWin.loadFile("src/index.html");

  // 关接收窗口 = 断开投屏，不是退出程序
  engineWin.on("close", (e) => {
    if (!quitting && uiEnabled) { e.preventDefault(); engineWin.hide(); send(engineWin, "nd-cmd", { cmd: "drop-stream" }); }
  });

  // headless：把 renderer 的日志转到主进程 stdout，无需 --enable-logging
  if (isHeadless) {
    engineWin.webContents.on("console-message", (_e, _lvl, message) => {
      if (/^\[sender\]|^\[recv\]|^SEND_STATS|^RECV_STATS|^SEND_SOURCE|^PROBE_RESULT/.test(message)) console.log(message);
    });
  }
}

function createPanel() {
  panelWin = new BrowserWindow({
    width: 430, height: 780,
    minWidth: 430, maxWidth: 430, // 设计是 430px 定宽，拉宽只会让布局散架
    icon: ASSET("icon.png"),
    show: false,
    frame: false, // 标题栏按设计自绘
    backgroundColor: "#00000000",
    transparent: false,
    title: "NetDisplay",
    webPreferences: WEBPREFS,
  });
  panelWin.loadFile("src/panel.html");
  panelWin.once("ready-to-show", () => panelWin.show());
  // 兜底：ready-to-show 依赖首次绘制，而界面里任何一个启动期异常都会让它永远
  // 不触发——症状是「进程活着、日志干净、桌面上什么都没有」，最难查的一类。
  // 宁可显示一个画坏的窗口，也不要让程序看起来根本没启动。
  setTimeout(() => {
    if (panelWin && !panelWin.isDestroyed() && !panelWin.isVisible() && !quitting) {
      console.log("[main] 面板未在 3s 内就绪，强制显示（界面可能有启动异常）");
      panelWin.show();
    }
  }, 3000);
  // 关主面板 = 收进托盘。连接要常驻，关窗就退出会让投射莫名其妙中断。
  panelWin.on("close", (e) => {
    if (!quitting) { e.preventDefault(); panelWin.hide(); }
  });
}

function createTrayWin() {
  trayWin = new BrowserWindow({
    width: 444, height: 520,
    show: false,
    frame: false,
    transparent: true,
    resizable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    focusable: true,
    webPreferences: WEBPREFS,
  });
  trayWin.loadFile("src/tray.html");
  trayWin.on("blur", () => hideTrayWin()); // 点别处就收起，和原生菜单一致
}

function hideTrayWin() {
  if (trayWin && !trayWin.isDestroyed() && trayWin.isVisible()) trayWin.hide();
}

// 贴着托盘图标弹出。菜单在窗口里是右上对齐的（tray.js 那边留了 12px padding），
// 所以窗口右缘对齐图标右缘、底缘压在任务栏上方。
function showTrayWin() {
  if (!trayWin || trayWin.isDestroyed()) return;
  const b = tray ? tray.getBounds() : null;
  const area = screen.getPrimaryDisplay().workArea;
  const [w, h] = trayWin.getSize();
  let x = b ? Math.round(b.x + b.width / 2 - w + 12) : area.x + area.width - w;
  let y = b ? b.y - h : area.y + area.height - h;
  // 别越界：多显示器/任务栏在上或在左时上面的推算会算出屏幕外的坐标
  x = Math.max(area.x, Math.min(x, area.x + area.width - w));
  y = Math.max(area.y, Math.min(y, area.y + area.height - h));
  trayWin.setPosition(x, y);
  trayWin.show();
  trayWin.focus();
}

function showPanel() {
  if (!panelWin || panelWin.isDestroyed()) return;
  panelWin.show();
  panelWin.focus();
}

const send = (win, ch, payload) => {
  if (win && !win.isDestroyed()) { try { win.webContents.send(ch, payload); } catch {} }
};
const broadcast = (ch, payload) => { send(panelWin, ch, payload); send(trayWin, ch, payload); };

app.whenReady().then(() => {
  createEngine();
  if (!uiEnabled) return;

  createPanel();
  createTrayWin();

  tray = new Tray(nativeImage.createFromPath(ASSET("tray.png")));
  tray.setToolTip("NetDisplay");
  // 左右键都弹自绘菜单——setContextMenu 会抢走右键并显示原生菜单，所以不能设
  tray.on("click", () => (trayWin.isVisible() ? hideTrayWin() : showTrayWin()));
  tray.on("right-click", () => (trayWin.isVisible() ? hideTrayWin() : showTrayWin()));
  tray.on("double-click", () => showPanel());

  // 托盘菜单平时只能手点图标才出得来，自动化里核对不了。给个测试口子，
  // 好把「main.js 的定位/尺寸」和「tray.js 的渲染」放在一起验。
  if (testArgs.showTray) setTimeout(showTrayWin, 3500);
});

// ================= IPC 中转 =================
ipcMain.on("nd-state", (_e, state) => {
  lastState = state;
  broadcast("nd-state", state);
  if (tray && !tray.isDestroyed()) {
    const t = state.role === "casting" ? "NetDisplay · 正在投射"
      : state.role === "receiving" ? "NetDisplay · 正在接收"
      : state.recvSvc === "waiting" ? "NetDisplay · 等待连接" : "NetDisplay";
    tray.setToolTip(t);
  }
});
ipcMain.handle("nd-state-get", () => lastState);
ipcMain.on("nd-cmd", (_e, m) => {
  // 尾部几项是窗口操作，不该打扰引擎
  if (m && m.cmd === "open-panel") {
    hideTrayWin();
    showPanel();
    // 托盘的「＋ 添加设备…」「中转设置…」「帧率/码率…」都指向主面板里的某一块，
    // 光把面板叫出来还不够——得让它自己展开到对应位置，否则用户还得再找一遍。
    if (m.section) send(panelWin, "nd-open", m.section);
    return;
  }
  if (m && m.cmd === "quit") { quitting = true; return app.quit(); }
  if (m && m.cmd === "copy") return clipboard.writeText(String(m.text || ""));
  send(engineWin, "nd-cmd", m);
});
ipcMain.on("nd-toast", (_e, text) => broadcast("nd-toast", text));

// 主面板是无边框的，最小化/关闭只能自己画，也就只能自己发消息
ipcMain.on("nd-win", (_e, action) => {
  if (!panelWin || panelWin.isDestroyed()) return;
  if (action === "minimize") panelWin.minimize();
  else if (action === "close") panelWin.hide(); // 关面板 = 收进托盘，连接要常驻
});

ipcMain.on("nd-tray-size", (_e, s) => {
  if (!trayWin || trayWin.isDestroyed() || !s) return;
  const area = screen.getPrimaryDisplay().workArea;
  const h = Math.max(120, Math.min(Math.round(s.height), area.height - 40));
  trayWin.setSize(Math.round(s.width) || 444, h);
  if (trayWin.isVisible()) showTrayWin(); // 高度变了要重新贴底，否则会飘出屏幕
});
ipcMain.on("nd-tray-close", () => hideTrayWin());

// 接收窗口的显示/隐藏由引擎的 role 决定：设计要求「对方开始投射自动打开、
// 断开即关闭」，用户不用管这个窗口。
ipcMain.on("nd-receive-window", (_e, s) => {
  if (!engineWin || engineWin.isDestroyed() || !s) return;
  if (s.minimize) return engineWin.minimize();
  if (s.title) engineWin.setTitle(s.title);
  if (!uiEnabled) return; // headless/测试下窗口本来就不该露面
  if (s.show && !engineWin.isVisible()) { engineWin.show(); engineWin.focus(); }
  else if (!s.show && engineWin.isVisible()) { engineWin.setFullScreen(false); engineWin.hide(); }
});

// ================= 本机信息 =================
// 本机可被直连到的局域网地址（协议 v1.9 HELLO.lanAddrs）。
// 虚拟网卡（VPN/代理/虚拟机）排在后面：它们常年在列但对方多半连不上，
// 排前面会让连接升级白白多试几次、拖慢切换。
function lanCandidates() {
  const nets = require("os").networkInterfaces();
  const cands = [];
  for (const [name, addrs] of Object.entries(nets)) {
    for (const a of addrs || []) {
      if (a.family !== "IPv4" || a.internal) continue;
      const virt = /vEthernet|VMware|VirtualBox|Loopback|Hyper-V|Mihomo|TAP|Clash|WSL|Tailscale|ZeroTier/i.test(name);
      cands.push({ ip: a.address, virt, name });
    }
  }
  cands.sort((x, y) => x.virt - y.virt);
  return cands;
}
const lanIp = () => (lanCandidates()[0] || {}).ip || null;

// 只对外公布**真实网卡**的地址。虚拟网卡（Mihomo/Clash 的 TUN、VMware、WSL…）
// 的地址对端根本路由不到；而且实测本机自连时它会被选中，流量绕回代理，
// 「升级到直连」后 RTT 仍是 293ms——等于白升级。宁可不公布也不要公布假的。
const lanAddrs = (port = 47800) =>
  lanCandidates().filter((c) => !c.virt).map((c) => `${c.ip}:${port}`);

ipcMain.handle("config", () => {
  const d = screen.getPrimaryDisplay();
  return {
    lanIp: lanIp(),
    lanAddrs: lanAddrs(),
    screen: {
      width: Math.round(d.size.width * d.scaleFactor),
      height: Math.round(d.size.height * d.scaleFactor),
      scale: 1,
      fps: 60,
    },
    args: testArgs,
  };
});

ipcMain.on("set-fullscreen", (_e, v) => {
  if (engineWin && !engineWin.isDestroyed()) engineWin.setFullScreen(!!v);
});

ipcMain.on("set-content-size", (_e, w, h) => {
  if (engineWin && !engineWin.isDestroyed()) engineWin.setContentSize(Math.max(320, w), Math.max(200, h));
});

// Sender 采集源：WS-1 整屏、WS-3 单窗口。renderer 的 getUserMedia 需要 source id
ipcMain.handle("capture-sources", async () => {
  const sources = await desktopCapturer.getSources({
    types: ["screen", "window"],
    thumbnailSize: { width: 0, height: 0 }, // 不要缩略图，省内存
  });
  return sources
    .filter((s) => s.name && !/^NetDisplay/.test(s.name)) // 排除自己，避免套娃
    .map((s) => ({ id: s.id, name: s.name, kind: s.id.startsWith("screen:") ? "desktop" : "window" }));
});

ipcMain.on("win-show", () => {
  if (engineWin && !engineWin.isDestroyed() && !engineWin.isVisible()) { engineWin.show(); engineWin.focus(); }
});

ipcMain.on("test-result", (_e, json) => {
  console.log("TEST_RESULT " + json);
  quitting = true;
  app.exit(0);
});

app.on("window-all-closed", () => { if (quitting || isTest) app.quit(); });
app.on("before-quit", () => { quitting = true; });
