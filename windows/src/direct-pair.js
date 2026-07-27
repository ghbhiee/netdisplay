// 直连配对 / 探测的纯网络逻辑（02 §3.9, docs/11 §6）。**不依赖 electron**，便于回环自检
// （sender.js require 了 electron，没法在纯 node 里跑；这块抽出来两边共用）。
//
// 47800 常驻响应器一个端口三种客户，peek 首帧类型分派：
//   PROBE(0x46)      → 原样回 PROBE_ACK（连通性探测，§3.8）
//   PAIR_HELLO(0x4A) → 武装校验：已武装且 secret 匹配才受理、回本机 PAIR_HELLO（不带 secret），
//                      否则静默忽略（别人知道你 IP 也配不上）
//   HELLO(0x01)      → 投射会话，原样交回注入的 onHelloSession（把已 peek 字节回灌，不丢帧）
"use strict";

const net = require("net");
const nodeCrypto = require("crypto");
const { T, buildFrame, FrameParser } = require("./protocol");

const normalizeCode = (c) => String(c || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
// secret = 配对码派生（和中转 §3.7 完全同一套），不是随机数。
const secretFromCode = (code) =>
  nodeCrypto.createHash("sha256").update("netdisplay-pair:" + normalizeCode(code)).digest("base64");
const normalizeIp = (a) => String(a || "").replace(/^::ffff:/, "") || null;

// 造一个 net.createServer 的连接处理器。deps：
//   getArmed()        → 当前武装的 secret（null=未武装）
//   deviceId()/name() → 本机标识
//   onHelloSession(sock, relayMode, initialBuf) → HELLO 首帧交给投射会话，回灌已读字节
//   onDirectPaired({peerDeviceId,peerName,addr,secret}) → 受理方成对通知
//   dbg(...)          → 日志
function makeDispatcher(deps) {
  const dbg = deps.dbg || (() => {});
  return function dispatch(sock, relayMode) {
    sock.setNoDelay(true);
    let buf = Buffer.alloc(0);
    let done = false;
    const onData = (d) => {
      if (done) return;
      buf = Buffer.concat([buf, d]);
      if (buf.length < 1) return;
      const type = buf[0];
      if (type === T.HELLO) {
        done = true; sock.removeListener("data", onData);
        deps.onHelloSession(sock, relayMode, buf); // 回灌含这条 HELLO 的全部已读字节
        return;
      }
      if (type === T.PROBE || type === T.PAIR_HELLO) {
        if (buf.length < 5) return;              // 等够帧头 [type][len u32]
        const len = buf.readUInt32BE(1);
        if (buf.length < 5 + len) return;        // 等够 payload
        const payload = buf.slice(5, 5 + len);
        const rest = buf.slice(5 + len);
        if (type === T.PROBE) {
          try { sock.write(buildFrame(T.PROBE_ACK, Buffer.from(payload))); } catch {}
          buf = rest;                            // 同一连接可能连发多次探测，保持监听
          return;
        }
        done = true; sock.removeListener("data", onData);
        handleInboundPairHello(sock, payload, deps);
        return;
      }
      done = true; try { sock.destroy(); } catch {} // 首帧是别的：直连响应器不认
    };
    sock.on("data", onData);
    sock.on("error", () => {});
  };
}

// 受理方：武装校验是安全核心。未武装或 secret 不符 = 静默忽略（destroy，不回任何帧）。
function handleInboundPairHello(sock, payload, deps) {
  const dbg = deps.dbg || (() => {});
  const armed = deps.getArmed();
  let msg = null; try { msg = JSON.parse(payload.toString()); } catch {}
  if (!msg || msg.v !== 1 || !msg.deviceId) { try { sock.destroy(); } catch {} return; }
  if (!armed || msg.secret !== armed) {
    dbg("PAIR_HELLO 拒绝：" + (!armed ? "未武装" : "secret 不符") + "（静默忽略）");
    try { sock.destroy(); } catch {}
    return;
  }
  const addr = normalizeIp(sock.remoteAddress);
  try { sock.write(buildFrame(T.PAIR_HELLO, { v: 1, deviceId: deps.deviceId(), name: deps.name() })); } catch {}
  dbg("PAIR_HELLO 受理，成对 peer=" + msg.deviceId + " @" + addr);
  try { deps.onDirectPaired({ peerDeviceId: msg.deviceId, peerName: msg.name || "", addr, secret: armed }); } catch {}
  setTimeout(() => { try { sock.destroy(); } catch {} }, 200); // 投射另起连接，握手连接可关
}

// 发起方：拨对方 IP:47800 发 PAIR_HELLO{secret}，等对端回 PAIR_HELLO。3s 超时。
// 调用方应在此之前已把本机武装成同一个 secret（对端拨过来时我方也能受理）。
// deviceId/name 为字符串值。cb(err|null, {peerDeviceId,peerName,addr,secret})
function directPair({ ip, code, deviceId, name, port }, cb) {
  const secret = secretFromCode(code);
  let settled = false;
  const finish = (err, res) => {
    if (settled) return; settled = true;
    clearTimeout(timer); try { sock.destroy(); } catch {}
    cb && cb(err, res);
  };
  const sock = net.createConnection(port || 47800, ip, () => {
    sock.setNoDelay(true);
    sock.write(buildFrame(T.PAIR_HELLO, { v: 1, deviceId, name, secret }));
  });
  const parser = new FrameParser((type, payload) => {
    if (type !== T.PAIR_HELLO) return; // 只认对端回的配对帧
    let msg = null; try { msg = JSON.parse(payload.toString()); } catch {}
    if (!msg || !msg.deviceId) return;
    finish(null, { peerDeviceId: msg.deviceId, peerName: msg.name || "", addr: normalizeIp(ip), secret });
  });
  sock.on("data", (d) => { try { parser.feed(d); } catch {} });
  sock.on("error", (e) => finish(new Error((e && e.message) || "连接失败")));
  const timer = setTimeout(() => finish(new Error("超时：对方未在配对界面或 IP 不可达")), 3000);
}

module.exports = { secretFromCode, normalizeCode, normalizeIp, makeDispatcher, directPair };
