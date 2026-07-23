// NetDisplay Receiver — Electron 主进程（v1.4：托盘常驻、投射自动显示）
"use strict";
const { app, BrowserWindow, ipcMain, screen, Tray, Menu, nativeImage, desktopCapturer } = require("electron");
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

// 测试隔离：多实例并跑时各用独立 userData（否则 localStorage 抢锁、写入不落盘）
const userDataDir = arg("user-data");
if (userDataDir) app.setPath("userData", userDataDir);

let win = null;
let tray = null;
let quitting = false;

if (!app.requestSingleInstanceLock() && !isTest) {
  app.quit();
} else {
  app.on("second-instance", () => {
    if (win) { win.show(); win.focus(); }
  });
}

app.whenReady().then(() => {
  win = new BrowserWindow({
    width: 1440,
    height: 900,
    icon: path.join(__dirname, "assets", "icon.png"),
    show: !isHeadless, // headless：窗口存在（renderer 需要 WebCodecs）但不显示
    backgroundColor: "#0b0f14",
    autoHideMenuBar: true,
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false,
      backgroundThrottling: false, // 隐藏到托盘时保持心跳/解码不被节流
    },
  });
  win.loadFile("src/index.html");

  // 关窗 = 隐藏到托盘（连接常驻）；托盘菜单退出才真正退出
  win.on("close", (e) => {
    if (!quitting && !isTest && !isHeadless) {
      e.preventDefault();
      win.hide();
    }
  });

  // headless：把 renderer 的日志转到主进程 stdout，无需 --enable-logging
  if (isHeadless) {
    win.webContents.on("console-message", (_e, _lvl, message) => {
      if (/^\[sender\]|^\[recv\]|^SEND_STATS|^RECV_STATS|^SEND_SOURCE/.test(message)) console.log(message);
    });
  }

  if (!isTest && !isHeadless) {
    const icon = nativeImage.createFromPath(path.join(__dirname, "assets", "tray.png"));
    tray = new Tray(icon);
    tray.setToolTip("NetDisplay");
    buildTrayMenu();
    tray.on("double-click", () => { win.show(); win.focus(); });
  }
});

// 托盘菜单：对标 Mac 菜单栏——不只是「显示/退出」，常用参数要能直接切，
// 不必先把主窗口叫出来。状态由 renderer 通过 tray-state 推上来。
let trayState = { connected: false, projecting: false, res: "auto", scale: "1", fps: "60",
  sources: [], source: "", code: "------" };

function buildTrayMenu() {
  if (!tray) return;
  const send = (ch, v) => win && !win.isDestroyed() && win.webContents.send(ch, v);
  const radio = (label, checked, click) => ({ label, type: "radio", checked, click });

  const t = Menu.buildFromTemplate([
    { label: trayState.connected ? (trayState.projecting ? "● 正在投射本机" : "○ 已连接 · 等待投射") : "未连接",
      enabled: false },
    { type: "separator" },
    trayState.projecting
      ? { label: "停止投射", click: () => send("tray-cmd", { cmd: "stop-project" }) }
      : { label: "开始投射本机", enabled: trayState.connected, click: () => send("tray-cmd", { cmd: "start-project" }) },
    { label: "投射源", enabled: trayState.sources.length > 0, submenu:
      [{ label: "整个屏幕", type: "radio", checked: !trayState.source,
         click: () => send("tray-cmd", { cmd: "set-source", value: "" }) }].concat(
        trayState.sources.map((s) => ({
          label: s.name.length > 36 ? s.name.slice(0, 34) + "…" : s.name,
          type: "radio", checked: trayState.source === s.id,
          click: () => send("tray-cmd", { cmd: "set-source", value: s.id }),
        }))) },
    { type: "separator" },
    { label: "分辨率", submenu: ["auto", "3840x2400", "2560x1600", "1920x1200", "1280x800"].map((v) =>
        radio(v === "auto" ? "跟随本机屏幕" : v.replace("x", " × "), trayState.res === v,
          () => send("tray-cmd", { cmd: "set", key: "res", value: v }))) },
    { label: "缩放", submenu: [["1", "1x（画面大）"], ["2", "2x（字大清晰）"]].map(([v, l]) =>
        radio(l, trayState.scale === v, () => send("tray-cmd", { cmd: "set", key: "scale", value: v }))) },
    { label: "帧率", submenu: [["60", "60 fps"], ["30", "30 fps"]].map(([v, l]) =>
        radio(l, trayState.fps === v, () => send("tray-cmd", { cmd: "set", key: "fps", value: v }))) },
    { type: "separator" },
    { label: `我的配对码：${trayState.code}`, click: () => {
        require("electron").clipboard.writeText(trayState.code); } },
    { label: "打开主界面", click: () => { win.show(); win.focus(); } },
    { type: "separator" },
    { label: "退出", click: () => { quitting = true; app.quit(); } },
  ]);
  tray.setContextMenu(t);
  tray.setToolTip(trayState.projecting ? "NetDisplay · 正在投射" :
    trayState.connected ? "NetDisplay · 已连接" : "NetDisplay");
}

ipcMain.on("tray-state", (_e, s) => {
  trayState = { ...trayState, ...s };
  buildTrayMenu();
});

// 本机局域网 IP：监听模式要显示给对方，让对方能直连
function lanIp() {
  const nets = require("os").networkInterfaces();
  const cands = [];
  for (const [name, addrs] of Object.entries(nets)) {
    for (const a of addrs || []) {
      if (a.family !== "IPv4" || a.internal) continue;
      // 虚拟网卡（VPN/代理/虚拟机）常年在列，但对方多半连不上，排到最后
      const virt = /vEthernet|VMware|VirtualBox|Loopback|Hyper-V|Mihomo|TAP|Clash/i.test(name);
      cands.push({ ip: a.address, virt });
    }
  }
  cands.sort((x, y) => x.virt - y.virt);
  return cands.length ? cands[0].ip : null;
}

ipcMain.handle("config", () => {
  const d = screen.getPrimaryDisplay();
  return {
    lanIp: lanIp(),
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
  if (win && !win.isDestroyed()) win.setFullScreen(!!v);
});

ipcMain.on("set-content-size", (_e, w, h) => {
  if (win && !win.isDestroyed()) win.setContentSize(Math.max(320, w), Math.max(200, h));
});

// Sender 采集源：WS-1 整屏、WS-3 单窗口。renderer 的 getUserMedia 需要 source id
ipcMain.handle("capture-sources", async () => {
  const sources = await desktopCapturer.getSources({
    types: ["screen", "window"],
    thumbnailSize: { width: 0, height: 0 }, // 不要缩略图，省内存
  });
  return sources
    .filter((s) => s.name && s.name !== "NetDisplay Receiver") // 排除自己，避免套娃
    .map((s) => ({ id: s.id, name: s.name, kind: s.id.startsWith("screen:") ? "desktop" : "window" }));
});

// v1.4：有投射时把窗口带到前台
ipcMain.on("win-show", () => {
  if (win && !win.isDestroyed() && !win.isVisible()) { win.show(); win.focus(); }
});

ipcMain.on("test-result", (_e, json) => {
  console.log("TEST_RESULT " + json);
  quitting = true;
  app.exit(0);
});

app.on("window-all-closed", () => { if (quitting || isTest) app.quit(); });
app.on("before-quit", () => { quitting = true; });
