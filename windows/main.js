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
  sendWindow: arg("send-window"), // 测试：按标题子串选窗口作为投射源（WS-3）
  sendStatsAfter: arg("send-stats-after"), // 互调：N 秒后打印 SEND_STATS（需 --enable-logging）
  sendStatsRepeat: argv.includes("--send-stats-repeat") ? "1" : null,
};
const isTest = !!testArgs.exitAfter;

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
    if (!quitting && !isTest) {
      e.preventDefault();
      win.hide();
    }
  });

  if (!isTest) {
    const icon = nativeImage.createFromPath(path.join(__dirname, "assets", "tray.png"));
    tray = new Tray(icon);
    tray.setToolTip("NetDisplay Receiver");
    tray.setContextMenu(
      Menu.buildFromTemplate([
        { label: "显示窗口", click: () => { win.show(); win.focus(); } },
        { type: "separator" },
        { label: "退出", click: () => { quitting = true; app.quit(); } },
      ])
    );
    tray.on("double-click", () => { win.show(); win.focus(); });
  }
});

ipcMain.handle("config", () => {
  const d = screen.getPrimaryDisplay();
  return {
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
