// 验证配对码持久化：同一台机器重启后必须是同一个码。
// 用户实测反馈「每次启动都变」——那样对方每次都要重新问一遍码，等于没有配对。
//   npx electron tools/test-paircode.js
"use strict";
const { app, BrowserWindow, ipcMain } = require("electron");
const path = require("path");

// 在 renderer 里跑两遍取码逻辑，中间模拟一次「重启」（重新读 localStorage）
const SCRIPT = `
function myPairCode() {
  let c = localStorage.getItem("my.pairCode");
  if (!/^\\d{6}$/.test(c || "")) {
    c = String(100000 + Math.floor(Math.random() * 900000));
    localStorage.setItem("my.pairCode", c);
  }
  return c;
}
localStorage.removeItem("my.pairCode");        // 干净起点
const first = myPairCode();                    // 首次生成
const second = myPairCode();                   // 同进程内再取
const stored = localStorage.getItem("my.pairCode"); // 模拟重启后从存储读
require("electron").ipcRenderer.send("r", { first, second, stored });
`;

app.whenReady().then(() => {
  const w = new BrowserWindow({ show: false, webPreferences: { nodeIntegration: true, contextIsolation: false } });
  w.loadFile(path.join(__dirname, "blank.html"));
  w.webContents.on("did-finish-load", () => w.webContents.executeJavaScript(SCRIPT));
});

ipcMain.on("r", (_e, r) => {
  const ok = /^\d{6}$/.test(r.first) && r.first === r.second && r.first === r.stored;
  console.log(`首次生成=${r.first}  同进程再取=${r.second}  存储中=${r.stored}`);
  console.log(ok ? "RESULT: PASS（码稳定且已持久化）" : "RESULT: FAIL（码会变）");
  app.exit(ok ? 0 : 1);
});
setTimeout(() => { console.error("超时"); app.exit(1); }, 20000);
