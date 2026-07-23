// 验证 WebView2（= Edge 的引擎，Tauri 在 Windows 上用它）能否硬解 HEVC / 4:2:2。
//
// 这是「换 Tauri」这条路的**前提**：Tauri 保留现有视频管线的价值，全靠 WebView2
// 提供和 Electron 里一样的 WebCodecs 硬解能力。若不成立，就只能走原生重写。
// 用 Edge 代测——WebView2 与 Edge 同引擎同版本。
"use strict";
const http = require("http");
const { spawn, execSync } = require("child_process");

const PAGE = `<!doctype html><meta charset="utf-8"><body><pre id="o">探测中…</pre><script>
(async () => {
  const cases = [
    ["H.264 High 4:2:0", "avc1.640033"],
    ["HEVC Main 4:2:0",  "hev1.1.6.L153.B0"],
    ["HEVC Main10",      "hev1.2.4.L153.B0"],
    ["HEVC Rext 4:2:2",  "hev1.4.10.L153.B0"],
  ];
  const out = { ua: navigator.userAgent, hasVideoDecoder: typeof VideoDecoder !== "undefined",
    hasVideoEncoder: typeof VideoEncoder !== "undefined", decode: {}, encode: {} };
  if (out.hasVideoDecoder) {
    for (const [name, codec] of cases) {
      for (const hw of ["prefer-hardware", "prefer-software"]) {
        try {
          const r = await VideoDecoder.isConfigSupported({ codec, hardwareAcceleration: hw,
            optimizeForLatency: true, codedWidth: 2560, codedHeight: 1600 });
          out.decode[name + " / " + hw] = !!r.supported;
        } catch (e) { out.decode[name + " / " + hw] = "err:" + e.name; }
      }
    }
  }
  if (out.hasVideoEncoder) {
    try {
      const r = await VideoEncoder.isConfigSupported({ codec: "avc1.640033", width: 1280,
        height: 720, bitrate: 8e6, framerate: 30, avc: { format: "annexb" } });
      out.encode["H.264 annexb"] = !!r.supported;
    } catch (e) { out.encode["H.264 annexb"] = "err:" + e.name; }
  }
  document.getElementById("o").textContent = JSON.stringify(out, null, 2);
  await fetch("/result", { method: "POST", body: JSON.stringify(out) });
})();
</script></body>`;

const srv = http.createServer((req, res) => {
  if (req.method === "POST" && req.url === "/result") {
    let b = "";
    req.on("data", (c) => (b += c));
    req.on("end", () => {
      res.end("ok");
      console.log("WEBVIEW2_PROBE " + b);
      setTimeout(() => { try { execSync('taskkill /f /im msedge.exe /fi "WINDOWTITLE eq *" >nul 2>&1'); } catch {} srv.close(); process.exit(0); }, 300);
    });
    return;
  }
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  res.end(PAGE);
});

srv.listen(38471, "127.0.0.1", () => {
  const edge = "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";
  spawn(edge, ["--app=http://127.0.0.1:38471/", "--window-size=520,420",
    "--user-data-dir=" + process.env.TEMP + "\\nd-edge-probe"], { detached: true, stdio: "ignore" }).unref();
});
setTimeout(() => { console.error("探测超时（Edge 可能未启动）"); process.exit(1); }, 45000);
