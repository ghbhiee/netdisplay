// 直连配对回环自检（02 §3.9, docs/11 §6）。对齐 Mac 的 directpair-selftest / directpair-reject-selftest。
// 用真实的 src/direct-pair.js（不依赖 electron），在本机起响应器 + 拨号，覆盖：
//   ① PROBE → PROBE_ACK 原样回显（探测响应器不被配对逻辑破坏）
//   ② HELLO 首帧 → 交回 onHelloSession，且已读字节完整回灌（投射路径不丢帧）
//   ③ 正确配对码 → 双方成对（发起方拿到对端信息、受理方 onDirectPaired 触发）
//   ④ 错误配对码 → 静默拒绝（受理方不成对、不回帧）——安全负向测试，最关键
//   ⑤ 未武装 → 即便码对也拒绝
"use strict";
const net = require("net");
const { T, buildFrame, FrameParser } = require("../src/protocol");
const { secretFromCode, makeDispatcher, directPair } = require("../src/direct-pair");

let pass = 0, fail = 0;
const ok = (n, c) => { console.log((c ? "✅ " : "❌ ") + n); c ? pass++ : fail++; };
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// 起一个响应器：armed 可变（模拟点配对/关弹窗），记录 onHelloSession / onDirectPaired 调用。
function makeResponder(deviceId, name) {
  // sessionsAllowed 复刻 sender.js 注入的安全门：idle(=false) 时 HELLO 一律拒、不起会话。
  const state = { armed: null, hello: null, paired: null, sessionsAllowed: true };
  const dispatch = makeDispatcher({
    getArmed: () => state.armed,
    deviceId: () => deviceId,
    name: () => name,
    onHelloSession: (sock, _relay, buf) => {
      if (!state.sessionsAllowed) { try { sock.destroy(); } catch {} return; } // 安全门：idle 拒会话
      state.hello = buf; try { sock.destroy(); } catch {}
    },
    onDirectPaired: (info) => { state.paired = info; },
    dbg: () => {},
  });
  const server = net.createServer((sock) => dispatch(sock, false));
  return { state, server, listen: (port) => new Promise((r) => server.listen(port, "127.0.0.1", r)),
    close: () => new Promise((r) => server.close(r)) };
}

// 裸拨号发一帧（用于 PROBE/HELLO 用例），收集回帧。
function sendRaw(port, frame, holdMs) {
  return new Promise((resolve) => {
    const chunks = [];
    const sock = net.createConnection(port, "127.0.0.1", () => sock.write(frame));
    sock.on("data", (d) => chunks.push(d));
    sock.on("error", () => {});
    setTimeout(() => { try { sock.destroy(); } catch {} resolve(Buffer.concat(chunks)); }, holdMs || 300);
  });
}

(async () => {
  const R = makeResponder("A-dev", "MachineA");
  await R.listen(0);
  const port = R.server.address().port;

  // ① PROBE → PROBE_ACK 回显
  const probe = Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]);
  const ack = await sendRaw(port, buildFrame(T.PROBE, probe), 300);
  ok("① PROBE→PROBE_ACK 原样回显", ack.length === 13 && ack[0] === T.PROBE_ACK && ack.slice(5).equals(probe));

  // ② HELLO 首帧 → onHelloSession 拿到完整回灌字节
  R.state.hello = null;
  const helloFrame = buildFrame(T.HELLO, { version: 1, role: "receiver", deviceId: "X" });
  await sendRaw(port, helloFrame, 200);
  await wait(50);
  ok("② HELLO→onHelloSession 且字节完整回灌",
    !!R.state.hello && R.state.hello.length === helloFrame.length && R.state.hello[0] === T.HELLO && R.state.hello.equals(helloFrame));

  // ③ 正确码 → 成对
  R.state.paired = null;
  R.state.armed = secretFromCode("K7M2QX"); // A 处于直连页、已武装
  const res3 = await new Promise((r) =>
    directPair({ ip: "127.0.0.1", port, code: "k7-m2qx", deviceId: "B-dev", name: "MachineB" }, (e, res) => r({ e, res })));
  await wait(50);
  ok("③ 正确码：发起方拿到对端 A-dev", !res3.e && res3.res && res3.res.peerDeviceId === "A-dev");
  ok("③ 正确码：受理方 onDirectPaired 触发、记到 B-dev + secret",
    !!R.state.paired && R.state.paired.peerDeviceId === "B-dev" && R.state.paired.secret === secretFromCode("K7M2QX"));

  // ④ 错误码 → 静默拒绝（不成对、发起方拿不到回帧）
  R.state.paired = null; // A 仍武装 K7M2QX
  const res4 = await new Promise((r) =>
    directPair({ ip: "127.0.0.1", port, code: "WRONG9", deviceId: "C-dev", name: "MachineC" }, (e, res) => r({ e, res })));
  await wait(50);
  ok("④ 错误码：受理方未成对（onDirectPaired 未触发）", R.state.paired === null);
  ok("④ 错误码：发起方未拿到成对（被拒/无回帧）", !!res4.e && !res4.res);

  // ⑤ 未武装 → 即便码对也拒绝
  R.state.paired = null; R.state.armed = null; // 关了弹窗，解除武装
  const res5 = await new Promise((r) =>
    directPair({ ip: "127.0.0.1", port, code: "K7M2QX", deviceId: "D-dev", name: "MachineD" }, (e, res) => r({ e, res })));
  await wait(50);
  ok("⑤ 未武装：即便码对也拒绝", R.state.paired === null && !!res5.e);

  // ⑥ 安全门：idle（未投射）时 HELLO 一律拒、不起会话
  R.state.hello = null; R.state.sessionsAllowed = false;
  await sendRaw(port, buildFrame(T.HELLO, { version: 1, role: "receiver", deviceId: "X" }), 200);
  await wait(50);
  ok("⑥ 安全门：idle 时 HELLO 被拒、不起会话", R.state.hello === null);
  R.state.sessionsAllowed = true;

  await R.close();
  console.log(`\n直连配对自检：${pass} 通过, ${fail} 失败`);
  process.exit(fail ? 1 : 0);
})();
