// 最小联调客户端（无 UI、不解码）：验证握手与视频流协议正确性，打印统计。
// 直连:  node tools/cli-client.js --direct 10.77.0.1 [--port 47800] [--seconds 10]
// 中转:  node tools/cli-client.js --relay 483920 [--server 15.tokencv.com:47700] [--seconds 10]
"use strict";
const net = require("net");
const os = require("os");
const crypto = require("crypto");
const { T, buildFrame, FrameParser, parseVideoPayload } = require("../src/protocol");

const arg = (name, def) => {
  const i = process.argv.indexOf("--" + name);
  return i > 0 ? process.argv[i + 1] : def;
};
const SECONDS = +arg("seconds", 10);
const direct = arg("direct", null);
const relayCode = arg("relay", null);
if (!direct && !relayCode) {
  console.error("用法见文件头注释：--direct <ip> 或 --relay <6位配对码>");
  process.exit(2);
}

const stats = {
  mode: direct ? "direct" : "relay",
  helloAck: null,
  frames: 0,
  keyframes: 0,
  bytes: 0,
  firstFrameKeyframe: null,
  firstNalTypes: null,
  ptsMonotonic: true,
  lastPts: -1n,
  rttMs: [],
  errors: [],
};

let sock;
const pings = new Map();

function startProtocol() {
  // 建连/配对后立即发 Receiver HELLO（协议 §3.1）
  sock.write(
    buildFrame(T.HELLO, {
      version: 1,
      role: "receiver",
      name: os.hostname(),
      deviceId: crypto.randomUUID(),
      screen: { width: 2560, height: 1600, scale: 1, fps: 60 },
      // v1.3/v1.6：可用 --codecs hevc,h264 指定上报的解码能力（测 Sender 协商）
      codecs: (arg("codecs", "h264") || "h264").split(","),
    })
  );
  // PING 循环
  const pingTimer = setInterval(() => {
    const payload = crypto.randomBytes(8);
    pings.set(payload.toString("hex"), process.hrtime.bigint());
    sock.write(buildFrame(T.PING, payload));
  }, 3000);
  sock.on("close", () => clearInterval(pingTimer));
}

function nalTypesOf(annexb, max = 4) {
  const types = [];
  let i = 0;
  const sc = Buffer.from([0, 0, 1]);
  while (types.length < max && (i = annexb.indexOf(sc, i)) !== -1) {
    const nal = annexb[i + 3];
    if (nal !== undefined) types.push(nal & 0x1f);
    i += 3;
  }
  return types;
}

const parser = new FrameParser((type, payload) => {
  switch (type) {
    case T.HELLO:
      console.log("[cli] sender HELLO:", payload.toString());
      break;
    case T.HELLO_ACK:
      stats.helloAck = JSON.parse(payload.toString());
      console.log("[cli] HELLO_ACK:", payload.toString());
      if (stats.helloAck.accepted === false) finish(); // 协商失败：立即出结论
      break;
    case T.VIDEO_FRAME: {
      const v = parseVideoPayload(payload);
      if (stats.frames === 0) {
        stats.firstFrameKeyframe = v.keyframe;
        stats.firstNalTypes = nalTypesOf(v.data);
        console.log(
          `[cli] first frame: keyframe=${v.keyframe} nalTypes=[${stats.firstNalTypes}] size=${v.data.length}`
        );
      }
      if (v.ptsUs <= stats.lastPts) stats.ptsMonotonic = false;
      stats.lastPts = v.ptsUs;
      stats.frames++;
      if (v.keyframe) stats.keyframes++;
      stats.bytes += payload.length;
      break;
    }
    case T.PONG: {
      const key = payload.toString("hex");
      const t0 = pings.get(key);
      if (t0) {
        pings.delete(key);
        stats.rttMs.push(Number(process.hrtime.bigint() - t0) / 1e6);
      } else stats.errors.push("PONG payload mismatch");
      break;
    }
    case T.VIDEO_CONFIG:
      console.log("[cli] VIDEO_CONFIG:", payload.toString());
      break;
    case T.BYE:
      console.log("[cli] BYE:", payload.toString());
      break;
    case T.RELAY_PAIRED:
      console.log("[cli] RELAY_PAIRED:", payload.toString());
      startProtocol();
      break;
    case T.RELAY_ERROR:
      console.error("[cli] RELAY_ERROR:", payload.toString());
      process.exit(1);
      break;
    default:
      console.log(`[cli] 未知帧 type=0x${type.toString(16)} len=${payload.length}（按协议跳过）`);
  }
});

function finish() {
  const s = { ...stats, lastPts: String(stats.lastPts) };
  s.avgRttMs = stats.rttMs.length
    ? +(stats.rttMs.reduce((a, b) => a + b) / stats.rttMs.length).toFixed(2)
    : null;
  s.mbps = +((stats.bytes * 8) / SECONDS / 1e6).toFixed(2);
  s.fps = +(stats.frames / SECONDS).toFixed(1);
  console.log("=== SUMMARY ===");
  console.log(JSON.stringify(s, null, 2));
  // 对端明确拒绝（如 codec 协商无交集）是协议正常路径，与「连上了但流不对」区分开
  if (stats.helloAck && stats.helloAck.accepted === false) {
    console.log("RESULT: REJECTED — " + (stats.helloAck.reason || "no reason"));
    process.exit(0);
  }
  const pass =
    stats.helloAck?.accepted === true &&
    stats.frames > 0 &&
    stats.firstFrameKeyframe === true &&
    stats.ptsMonotonic &&
    stats.errors.length === 0;
  console.log(pass ? "RESULT: PASS" : "RESULT: FAIL");
  process.exit(pass ? 0 : 1);
}

if (direct) {
  const port = +arg("port", 47800);
  sock = net.createConnection(port, direct, () => {
    console.log(`[cli] connected to ${direct}:${port}`);
    sock.setNoDelay(true);
    startProtocol();
  });
} else {
  const [host, portStr] = arg("server", "15.tokencv.com:47700").split(":");
  sock = net.createConnection(+portStr || 47700, host, () => {
    console.log(`[cli] connected to relay ${host}, joining code ${relayCode}`);
    sock.setNoDelay(true);
    sock.write(buildFrame(T.RELAY_JOIN, { v: 1, role: "receiver", code: relayCode }));
  });
}
sock.on("data", (d) => {
  try {
    parser.feed(d);
  } catch (e) {
    stats.errors.push(e.message);
    finish();
  }
});
sock.on("error", (e) => {
  console.error("[cli] socket error:", e.message);
  process.exit(1);
});
setTimeout(finish, SECONDS * 1000);
