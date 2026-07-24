// PRESENCE/PEER_PRESENCE 线格式单测（协议 0x48/0x49，relay v1.14，docs/11 §5）。
//   node tools/test-presence.js <server> <token>
// 随机 pairHash（不碰真实配对），两个不同 deviceId 各报一个状态，应各收到对端状态。
// 再让 B 断开，A 应收到 peerState=offline。纯节点脚本、几秒退出，不是后台常驻。
"use strict";
const net = require("net");
const crypto = require("crypto");
const { T, buildFrame, FrameParser } = require("../src/protocol");

const server = process.argv[2] || "15.tokencv.com:47700";
const token = process.argv[3] || "";
const [host, portStr] = server.split(":");
const port = +portStr || 47700;
const pairHash = crypto.randomBytes(32).toString("hex");

function client(label, deviceId, name, state, onPeer) {
  const s = net.createConnection(port, host, () => {
    s.setNoDelay(true);
    const msg = { v: 1, pairHash, deviceId, name, state };
    if (token) msg.token = token;
    s.write(buildFrame(T.PRESENCE, msg));
    console.log(`[${label}] 已报 state=${state}`);
  });
  const parser = new FrameParser((t, pl) => {
    if (t === T.PEER_PRESENCE) {
      let i = {}; try { i = JSON.parse(pl.toString()); } catch {}
      console.log(`[${label}] ← PEER_PRESENCE peerName=${i.peerName} peerState=${i.peerState}`);
      onPeer && onPeer(i);
    } else if (t === T.RELAY_ERROR) {
      console.log(`[${label}] ❌ RELAY_ERROR ${pl.toString()}`);
    }
  });
  s.on("data", (b) => { try { parser.feed(b); } catch {} });
  s.on("error", (e) => console.log(`[${label}] err ${e.message}`));
  return s;
}

(async () => {
  const seen = { a: null, aOffline: false };
  const A = client("A", "dev-A-" + crypto.randomBytes(3).toString("hex"), "WinA", "recv-waiting", (i) => {
    if (i.peerState === "offline") seen.aOffline = true;
    else seen.a = i;
  });
  await new Promise((r) => setTimeout(r, 500));
  const B = client("B", "dev-B-" + crypto.randomBytes(3).toString("hex"), "MacB", "casting", () => {});
  await new Promise((r) => setTimeout(r, 2000));

  console.log("--- B 断开，A 应收到 offline ---");
  B.destroy();
  await new Promise((r) => setTimeout(r, 3000));
  A.destroy();

  const ok = seen.a && seen.a.peerState === "casting" && seen.a.peerName === "MacB" && seen.aOffline;
  console.log(ok
    ? "RESULT PASS —— A 看到 B casting，B 掉线后 A 收到 offline"
    : `RESULT FAIL —— seenPeer=${JSON.stringify(seen.a)} offlineSeen=${seen.aOffline}`);
  process.exit(ok ? 0 : 1);
})();
