// Mock Sender：在没有 Mac 的环境下模拟 Mac 端行为，供 Receiver 本地测试。
// 行为对齐 90-mac-progress.md 的实测事实：建连即发 Sender HELLO；收 Receiver HELLO 回 HELLO_ACK；
// 推 VIDEO_FRAME（首帧关键帧含 SPS/PPS）；PING 原样回 PONG。
// 视频源：ffmpeg testsrc2 实时编码 H.264 Annex-B（插入 AUD 作为帧分隔、关键帧前插 SPS/PPS）。
// 直连: node tools/mock-sender.js [--port 47800] [--width 1280] [--height 800] [--fps 30]
// 中转: node tools/mock-sender.js --relay [--code 654321] [--server 15.tokencv.com:47700]
"use strict";
const net = require("net");
const os = require("os");
const { spawn } = require("child_process");
const { T, buildFrame, FrameParser, buildVideoPayload } = require("../src/protocol");

const arg = (name, def) => {
  const i = process.argv.indexOf("--" + name);
  return i > 0 ? process.argv[i + 1] : def;
};
const PORT = +arg("port", 47800);
const W = +arg("width", 1280) & ~1;
const H = +arg("height", 800) & ~1;
const FPS = Math.min(60, Math.max(30, +arg("fps", 30)));
const V14 = process.argv.includes("--v14");
// v1.4 持久配对：固定 pairSecret（可用 --pair-secret 覆盖），跨次运行一致
const PAIR_SECRET = arg("pair-secret", Buffer.from("mock-fixed-secret-32bytes-padding!").subarray(0, 32).toString("base64"));
const crypto = require("crypto");
const PAIR_HASH = crypto.createHash("sha256").update(Buffer.from(PAIR_SECRET, "base64")).digest("hex");

function handleConnection(sock) {
  console.log("[mock] receiver connected from", sock.remoteAddress);
  sock.setNoDelay(true);
  let ffmpeg = null;
  let stop = () => {};

  // 建连立即发 Sender HELLO（协议 §3.1）
  sock.write(
    buildFrame(T.HELLO, {
      version: 1,
      role: "sender",
      name: os.hostname() + "-mock",
      deviceId: "mock-sender-0000",
    })
  );

  let vw = W, vh = H, vfps = FPS, vscale = 1;
  let frameNo = 0; // 跨 ffmpeg 重启保持，保证 pts 单调（协议 §4）
  const parser = new FrameParser((type, payload) => {
    if (type === T.HELLO) {
      const hello = JSON.parse(payload.toString());
      console.log("[mock] got receiver HELLO:", JSON.stringify(hello));
      // v1.1：对齐 Mac 行为——按 receiver 请求的 screen 建流（宽高取偶、fps 夹 30–60），ACK 回带 scale
      if (hello.screen) {
        vw = (hello.screen.width || W) & ~1;
        vh = (hello.screen.height || H) & ~1;
        vfps = Math.min(60, Math.max(30, hello.screen.fps || FPS));
        vscale = hello.screen.scale || 1;
      }
      const ack = {
        version: 1,
        accepted: true,
        display: { width: vw, height: vh, fps: vfps, scale: vscale },
        codec: "h264",
      };
      if (V14) ack.pairSecret = PAIR_SECRET; // v1.4 持久配对下发
      sock.write(buildFrame(T.HELLO_ACK, ack));
      startVideo();
      if (V14) {
        // v1.4 时间线：投射中(A) → 4s 后空闲 → 7s 后切源(B, 新尺寸)恢复
        sock.write(buildFrame(T.PROJECTION_STATE, { active: true, label: "Mock 窗口 A", sourceKind: "window" }));
        setTimeout(() => {
          if (sock.destroyed) return;
          stop();
          console.log("[mock] v14: -> idle");
          sock.write(buildFrame(T.PROJECTION_STATE, { active: false }));
        }, 4000);
        setTimeout(() => {
          if (sock.destroyed) return;
          vw = 1280; vh = 720;
          console.log("[mock] v14: switch source -> 1280x720 active");
          sock.write(buildFrame(T.VIDEO_CONFIG, { codec: "h264", width: vw, height: vh, fps: vfps }));
          sock.write(buildFrame(T.PROJECTION_STATE, { active: true, label: "Mock 窗口 B", sourceKind: "window" }));
          startVideo();
        }, 7000);
      }
      // --reconfig N：N 秒后模拟 Mac 端单窗口投射 resize——发 VIDEO_CONFIG 换分辨率并重启编码
      const reconfigAfter = +arg("reconfig", 0);
      if (reconfigAfter > 0) {
        setTimeout(() => {
          if (sock.destroyed) return;
          stop();
          vw = 1280; vh = 720;
          console.log(`[mock] reconfig -> ${vw}x${vh}, sending VIDEO_CONFIG`);
          sock.write(buildFrame(T.VIDEO_CONFIG, { codec: "h264", width: vw, height: vh, fps: vfps }));
          startVideo();
        }, reconfigAfter * 1000);
      }
    } else if (type === T.PING) {
      sock.write(buildFrame(T.PONG, Buffer.from(payload)));
    } else if (type === T.REQUEST_KEYFRAME) {
      console.log("[mock] REQUEST_KEYFRAME (ffmpeg -g 会周期给关键帧，忽略)");
    } else if (type === T.CONTROL) {
      const c = JSON.parse(payload.toString());
      console.log("[mock] CONTROL:", JSON.stringify(c));
      if (c.action === "bounceBack" || c.action === "stop") {
        stop();
        sock.write(buildFrame(T.PROJECTION_STATE, { active: false }));
        console.log("[mock] v14: " + c.action + " -> idle");
      }
    } else if (type === T.BYE) {
      console.log("[mock] BYE:", payload.toString());
      sock.end();
    }
  });
  sock.on("data", (d) => {
    try {
      parser.feed(d);
    } catch (e) {
      console.error("[mock] protocol error:", e.message);
      sock.destroy();
    }
  });

  function startVideo() {
    // AUD 在每个 packet 最前 → 用 AUD(NAL type 9) 切分 access unit
    ffmpeg = spawn("ffmpeg", [
      "-hide_banner", "-loglevel", "error",
      "-re", "-f", "lavfi", "-i", `testsrc2=size=${vw}x${vh}:rate=${vfps}`,
      "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency",
      "-profile:v", "high", "-g", String(vfps * 2), "-bf", "0",
      "-bsf:v", "dump_extra=freq=keyframe,h264_metadata=aud=insert",
      "-f", "h264", "-",
    ]);
    ffmpeg.stderr.on("data", (d) => process.stderr.write("[ffmpeg] " + d));

    let acc = Buffer.alloc(0);
    const AUD = Buffer.from([0, 0, 0, 1, 0x09]);

    const isKey = (au) => {
      // 扫 NAL 起始码找 type 5 (IDR)
      let i = 0;
      while ((i = au.indexOf(Buffer.from([0, 0, 1]), i)) !== -1) {
        const nal = au[i + 3];
        if (nal !== undefined && (nal & 0x1f) === 5) return true;
        i += 3;
      }
      return false;
    };

    const emit = (au) => {
      if (au.length === 0) return;
      const ptsUs = Math.round((frameNo * 1e6) / vfps);
      frameNo++;
      sock.write(buildFrame(T.VIDEO_FRAME, buildVideoPayload(ptsUs, isKey(au), au)));
    };

    ffmpeg.stdout.on("data", (chunk) => {
      acc = acc.length === 0 ? chunk : Buffer.concat([acc, chunk]);
      // 以 AUD 为界切分；保留最后一段（可能不完整）
      let start = acc.indexOf(AUD);
      if (start === -1) return;
      let next;
      while ((next = acc.indexOf(AUD, start + AUD.length)) !== -1) {
        emit(acc.subarray(start, next));
        start = next;
      }
      acc = acc.subarray(start);
    });

    stop = () => ffmpeg && ffmpeg.kill("SIGKILL");
  }

  sock.on("close", () => {
    console.log("[mock] receiver disconnected");
    stop();
  });
  sock.on("error", () => {});
}

if (process.argv.includes("--relay")) {
  // 中转模式：作为 sender 连 relay 注册，配对后按同一套逻辑推流（协议 §3.2）
  const [host, portStr] = arg("server", "15.tokencv.com:47700").split(":");
  const code = arg("code", String(100000 + Math.floor(Math.random() * 900000)));
  const useHash = process.argv.includes("--use-pairhash");
  const token = arg("token", null); // v1.5 relay 鉴权
  const sock = net.createConnection(+portStr || 47700, host, () => {
    sock.setNoDelay(true);
    const reg = { v: 1, role: "sender", code: "" };
    if (token) reg.token = token;
    if (useHash) {
      reg.pairHash = PAIR_HASH;
      console.log(`[mock] registering on relay ${host} with pairHash ${PAIR_HASH.slice(0, 12)}…`);
    } else {
      reg.code = code;
      console.log(`[mock] registering on relay ${host}, pairing code: ${code}`);
    }
    sock.write(buildFrame(T.RELAY_REGISTER, reg));
  });
  const preParser = new FrameParser((type, payload) => {
    if (type === T.RELAY_PAIRED) {
      console.log("[mock] RELAY_PAIRED, starting session");
      // 同一 chunk 里可能紧跟对端 HELLO：截住残留字节，切换 parser 后重新注入
      const remnant = preParser.buf;
      preParser.buf = Buffer.alloc(0);
      sock.removeAllListeners("data");
      handleConnection(sock);
      if (remnant.length) process.nextTick(() => sock.emit("data", remnant));
    } else if (type === T.RELAY_ERROR) {
      console.error("[mock] RELAY_ERROR:", payload.toString());
      process.exit(1);
    }
  });
  sock.on("data", (d) => preParser.feed(d));
  sock.on("error", (e) => { console.error("[mock] relay socket:", e.message); process.exit(1); });
} else {
  const server = net.createServer(handleConnection);
  server.listen(PORT, () => console.log(`[mock] sender listening :${PORT}  (${W}x${H}@${FPS})`));
}
