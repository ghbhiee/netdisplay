// PAIR_ANNOUNCE/CONFIRMED 线格式单测（协议 0x44/0x45，relay v1.12）。
//   node tools/test-pair-announce.js <server> <token>
// 用**随机 pairHash**（不碰任何真实配对），两个不同 deviceId 各发一次 ANNOUNCE，
// 应各收到对端的 PAIR_CONFIRMED。纯节点脚本、~1s 退出，不是后台常驻进程。
"use strict";
const net = require("net");
const crypto = require("crypto");
const { T, buildFrame, FrameParser } = require("../src/protocol");

const server = process.argv[2] || "15.tokencv.com:47700";
const token = process.argv[3] || "";
const [host, portStr] = server.split(":");
const port = +portStr || 47700;
const pairHash = crypto.randomBytes(32).toString("hex"); // 随机房间

function announce(label, deviceId, name) {
  return new Promise((resolve) => {
    const s = net.createConnection(port, host, () => {
      s.setNoDelay(true);
      const msg = { v: 1, pairHash, deviceId, name };
      if (token) msg.token = token;
      s.write(buildFrame(T.PAIR_ANNOUNCE, msg));
      console.log(`[${label}] 已发 ANNOUNCE deviceId=${deviceId} name=${name}`);
    });
    const parser = new FrameParser((t, pl) => {
      if (t === T.PAIR_CONFIRMED) {
        let info = {}; try { info = JSON.parse(pl.toString()); } catch {}
        console.log(`[${label}] ✅ 收到 PAIR_CONFIRMED peerDeviceId=${info.peerDeviceId} peerName=${info.peerName}`);
        s.destroy();
        resolve(info);
      } else if (t === T.RELAY_ERROR) {
        console.log(`[${label}] ❌ RELAY_ERROR ${pl.toString()}`);
        s.destroy();
        resolve(null);
      }
    });
    s.on("data", (b) => { try { parser.feed(b); } catch {} });
    s.on("error", (e) => { console.log(`[${label}] socket error ${e.message}`); resolve(null); });
    setTimeout(() => { s.destroy(); resolve(null); }, 6000);
  });
}

(async () => {
  const A = announce("A", "dev-A-" + crypto.randomBytes(3).toString("hex"), "Windows测试端A");
  await new Promise((r) => setTimeout(r, 400)); // B 稍后到，模拟真实一先一后
  const B = announce("B", "dev-B-" + crypto.randomBytes(3).toString("hex"), "Mac测试端B");
  const [ra, rb] = await Promise.all([A, B]);
  const ok = ra && rb && ra.peerName === "Mac测试端B" && rb.peerName === "Windows测试端A";
  console.log(ok ? "RESULT PASS —— 双向 ANNOUNCE 各收到对端信息、名字正确、顺序无关"
                 : "RESULT FAIL —— 见上");
  process.exit(ok ? 0 : 1);
})();
