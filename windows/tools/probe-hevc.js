// HEVC 真流解码探测（队列 #3 取证用）
// 先用 ffmpeg/x265 生成 %TEMP%\hevc{420_8,422_10,444_10}.h265（Annex-B, 含 AUD），再:
//   npx electron tools/probe-hevc.js
"use strict";
const { app, BrowserWindow, ipcMain } = require("electron");
const path = require("path");

app.whenReady().then(() => {
  const win = new BrowserWindow({
    show: false,
    webPreferences: { nodeIntegration: true, contextIsolation: false },
  });
  win.loadFile(path.join(__dirname, "probe-hevc.html"));
});

ipcMain.on("probe-result", (_e, json) => {
  console.log("PROBE_RESULT " + json);
  app.exit(0);
});
setTimeout(() => { console.error("probe timeout"); app.exit(1); }, 30000);
