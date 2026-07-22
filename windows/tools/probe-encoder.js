// 探测本机 WebCodecs 编码能力（Sender codec 协商依据）
//   npx electron tools/probe-encoder.js
"use strict";
const { app, BrowserWindow, ipcMain } = require("electron");
const path = require("path");

app.whenReady().then(() => {
  const win = new BrowserWindow({
    show: false,
    webPreferences: { nodeIntegration: true, contextIsolation: false },
  });
  win.loadFile(path.join(__dirname, "probe-encoder.html"));
});

ipcMain.on("probe-result", (_e, json) => {
  console.log("PROBE_RESULT " + json);
  app.exit(0);
});
setTimeout(() => { console.error("probe timeout"); app.exit(1); }, 40000);
