// P0-3：探测本机 WebCodecs 解码能力（HEVC / 4:4:4 / AV1）
// 用法: npx electron tools/probe-codecs.js
"use strict";
const { app, BrowserWindow, ipcMain } = require("electron");

const PROBE = `
(async () => {
  const cases = [
    ["H.264 High 4:2:0 (基线参照)",      "avc1.640033"],
    ["H.264 High 4:4:4 Predictive",     "avc1.f40033"],
    ["HEVC Main 4:2:0",                 "hev1.1.6.L153.B0"],
    ["HEVC Main10",                     "hev1.2.4.L153.B0"],
    ["HEVC Rext(Main 4:4:4)",           "hev1.4.10.L153.B0"],
    ["AV1 Main 4:2:0",                  "av01.0.08M.08"],
    ["AV1 High 4:4:4",                  "av01.1.08M.08"],
  ];
  const prefs = ["no-preference", "prefer-hardware", "prefer-software"];
  const out = [];
  for (const [name, codec] of cases) {
    const row = { name, codec };
    for (const hw of prefs) {
      try {
        const r = await VideoDecoder.isConfigSupported({
          codec, hardwareAcceleration: hw, optimizeForLatency: true,
          codedWidth: 2560, codedHeight: 1600,
        });
        row[hw] = !!r.supported;
      } catch (e) { row[hw] = "err:" + e.name; }
    }
    out.push(row);
  }
  require("electron").ipcRenderer.send("probe-result", JSON.stringify(out));
})();
`;

app.whenReady().then(() => {
  const win = new BrowserWindow({
    show: false,
    webPreferences: { nodeIntegration: true, contextIsolation: false },
  });
  win.loadFile(require("path").join(__dirname, "probe.html")); // data:URL 非 secure context，无 WebCodecs
});

ipcMain.on("probe-result", (_e, json) => {
  console.log("PROBE_RESULT " + json);
  app.exit(0);
});
setTimeout(() => { console.error("probe timeout"); app.exit(1); }, 20000);
