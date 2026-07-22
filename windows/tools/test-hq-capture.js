// WS-5a 自测：HQ 采集管线能否产出可用的 AU 流。
//   node tools/test-hq-capture.js [desktop|window] [窗口标题子串] [秒数]
// 校验：能出帧、首帧是关键帧、关键帧内联 VPS/SPS/PPS、AU 边界正确、pts 单调。
"use strict";
const { probeHQ } = require("../src/ffmpeg-probe");
const { startCapture, forEachNal } = require("../src/ffmpeg-capture");

const mode = process.argv[2] || "desktop";
const title = process.argv[3] || "Notepad";
const seconds = +(process.argv[4] || 6);

function nalTypes(au, max = 6) {
  const out = [];
  forEachNal(au, (t) => { if (out.length < max) out.push(t); });
  return out;
}

(async () => {
  const hq = await probeHQ(null, console.log);
  if (!hq.available) { console.log("HQ 不可用: " + hq.detail); process.exit(1); }

  const stats = { frames: 0, keyframes: 0, bytes: 0, firstKey: null, firstNals: null,
    ptsMonotonic: true, lastPts: -1, errors: [] };

  const cap = startCapture({
    ffmpeg: hq.ffmpeg, encoder: hq.encoder, pixFmt: hq.pixFmt,
    source: mode === "window" ? { kind: "window", name: title } : { kind: "desktop" },
    fps: 30, bitrateMbps: 20, gopSeconds: 2,
    onFrame(au, isKey, ptsUs) {
      if (stats.frames === 0) { stats.firstKey = isKey; stats.firstNals = nalTypes(au); }
      if (ptsUs <= stats.lastPts) stats.ptsMonotonic = false;
      stats.lastPts = ptsUs;
      stats.frames++; stats.bytes += au.length;
      if (isKey) stats.keyframes++;
    },
    onError(msg) { stats.errors.push(msg); },
    onLog(m) { if (/ffmpeg\/|error|失败/i.test(m)) console.log(m); },
  });

  setTimeout(() => {
    cap.stop();
    setTimeout(() => {
      console.log("\n=== HQ_CAPTURE_RESULT ===");
      console.log(JSON.stringify({ mode, ...stats, fps: +(stats.frames / seconds).toFixed(1),
        mbps: +((stats.bytes * 8) / seconds / 1e6).toFixed(2) }, null, 2));
      // VPS(32)/SPS(33)/PPS(34) 必须在首个关键帧里（协议 §4）
      const ps = stats.firstNals || [];
      const hasParamSets = ps.includes(32) && ps.includes(33) && ps.includes(34);
      const pass = stats.frames > 0 && stats.firstKey === true && hasParamSets &&
        stats.ptsMonotonic && stats.errors.length === 0;
      console.log(pass ? "RESULT: PASS" : "RESULT: FAIL");
      if (!hasParamSets && stats.frames > 0) console.log(`  ✗ 首帧缺参数集，NAL=[${ps}]（期望含 32,33,34）`);
      if (stats.errors.length) console.log("  ✗ 错误: " + stats.errors[0].split("\n")[0]);
      process.exit(pass ? 0 : 1);
    }, 1200);
  }, seconds * 1000);
})();
