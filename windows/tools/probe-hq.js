// 独立跑一次 HQ 路径探测（不启动 Electron 界面）：
//   node tools/probe-hq.js [ffmpeg路径]
"use strict";
const { probeHQ } = require("../src/ffmpeg-probe");

(async () => {
  const r = await probeHQ(process.argv[2] || null, console.log);
  console.log("\nHQ_PROBE " + JSON.stringify(r, null, 2));
  process.exit(r.available ? 0 : 1);
})();
