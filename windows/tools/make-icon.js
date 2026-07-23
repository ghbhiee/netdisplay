// 生成应用图标与托盘图标（无第三方依赖：用 Electron 的 canvas 渲染后存 PNG）。
//   npx electron tools/make-icon.js
// 产出 assets/icon.png(256) + assets/tray.png(32) + assets/tray@2x.png(64)
//
// 设计：两块叠放的屏幕 + 投射光弧 —— 表达「把一块屏投到另一块」。
// 托盘尺寸只有 16–32px，所以造型必须极简：细节在小尺寸下会糊成一团。
"use strict";
const { app, BrowserWindow, ipcMain } = require("electron");
const fs = require("fs");
const path = require("path");

const DRAW = `
function draw(S, mono) {
  const c = document.createElement("canvas");
  c.width = c.height = S;
  const x = c.getContext("2d");
  const u = S / 32;                       // 以 32 为设计基准，按比例放大
  const accent = mono ? "#ffffff" : "#3d8bfd";
  const back   = mono ? "rgba(255,255,255,.45)" : "#7fb2ff";

  const rr = (X, Y, W, H, R) => {
    x.beginPath();
    x.moveTo(X + R, Y);
    x.arcTo(X + W, Y, X + W, Y + H, R);
    x.arcTo(X + W, Y + H, X, Y + H, R);
    x.arcTo(X, Y + H, X, Y, R);
    x.arcTo(X, Y, X + W, Y, R);
    x.closePath();
  };

  // 后面那块屏（目标）
  x.fillStyle = back;
  rr(13 * u, 6 * u, 15 * u, 11 * u, 2 * u);
  x.fill();

  // 前面那块屏（来源）——实心强调色，小尺寸下也能一眼认出
  x.fillStyle = accent;
  rr(4 * u, 11 * u, 16 * u, 12 * u, 2.2 * u);
  x.fill();

  // 底座：一条短横线，暗示「显示器」而不是「卡片」
  x.fillStyle = accent;
  rr(9 * u, 24 * u, 6 * u, 1.6 * u, 0.8 * u);
  x.fill();

  // 投射信号弧：画在后屏的空白处，不能被前屏挡住——初版放在两屏交界，
  // 一半被遮，小尺寸下糊成一团看不出是什么。
  x.strokeStyle = mono ? "#ffffff" : "#1f6fe0";
  x.lineCap = "round";
  for (const [r, w] of [[3.2, 1.5], [5.6, 1.5]]) {
    x.lineWidth = w * u;
    x.beginPath();
    x.arc(15 * u, 15.5 * u, r * u, -Math.PI * 0.42, -Math.PI * 0.08);
    x.stroke();
  }

  return c.toDataURL("image/png").split(",")[1];
}
require("electron").ipcRenderer.send("icons", {
  icon: draw(256, false),
  tray: draw(32, false),
  tray2x: draw(64, false),
});
`;

app.whenReady().then(() => {
  const w = new BrowserWindow({ show: false, webPreferences: { nodeIntegration: true, contextIsolation: false } });
  w.loadFile(path.join(__dirname, "blank.html"));
  w.webContents.on("did-finish-load", () => w.webContents.executeJavaScript(DRAW));
});

ipcMain.on("icons", (_e, imgs) => {
  const dir = path.join(__dirname, "..", "assets");
  fs.mkdirSync(dir, { recursive: true });
  for (const [name, b64] of Object.entries({ "icon.png": imgs.icon, "tray.png": imgs.tray, "tray@2x.png": imgs.tray2x })) {
    fs.writeFileSync(path.join(dir, name), Buffer.from(b64, "base64"));
    console.log("已生成 " + name);
  }
  app.exit(0);
});
setTimeout(() => { console.error("超时"); app.exit(1); }, 20000);
