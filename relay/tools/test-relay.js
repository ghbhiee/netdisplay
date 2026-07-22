// Relay 功能自测：模拟 sender REGISTER + receiver JOIN，验证 PAIRED 与双向透明转发。
// 用法: node test-relay.js [host] [port]   （relay 启用鉴权时设 NETDISPLAY_RELAY_TOKEN）
const net = require("net");
const HOST = process.argv[2] || "15.tokencv.com";
const PORT = +(process.argv[3] || 47700);
const TOKEN = process.env.NETDISPLAY_RELAY_TOKEN || undefined;

function frame(type, payload) {
  const p = Buffer.isBuffer(payload) ? payload : Buffer.from(payload, "utf8");
  const b = Buffer.alloc(5 + p.length);
  b[0] = type;
  b.writeUInt32BE(p.length, 1);
  p.copy(b, 5);
  return b;
}

// 极简帧解析器（每连接一个）
function makeParser(onFrame) {
  let buf = Buffer.alloc(0);
  return (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 5) {
      const len = buf.readUInt32BE(1);
      if (buf.length < 5 + len) break;
      onFrame(buf[0], buf.subarray(5, 5 + len));
      buf = buf.subarray(5 + len);
    }
  };
}

const code = String(100000 + Math.floor(Math.random() * 900000));
let pairedCount = 0;
const results = [];
const fail = (m) => { console.error("FAIL:", m); process.exit(1); };

// 1) sender 注册
const sender = net.createConnection(PORT, HOST, () => {
  sender.setNoDelay(true);
  sender.write(frame(0x40, JSON.stringify({ v: 1, role: "sender", code, token: TOKEN })));
  // 2) 注册发出后再让 receiver 加入
  setTimeout(startReceiver, 300);
});
sender.on("data", makeParser((t, p) => {
  if (t === 0x42) {
    results.push("sender PAIRED " + p.toString());
    if (++pairedCount === 2) afterPaired();
  } else if (t === 0x43) fail("sender got RELAY_ERROR " + p.toString());
  else if (t === 0x99) {
    results.push("sender got echo payload: " + p.toString());
    finish();
  }
}));
sender.on("error", (e) => fail("sender socket: " + e.message));

let receiver;
function startReceiver() {
  receiver = net.createConnection(PORT, HOST, () => {
    receiver.setNoDelay(true);
    receiver.write(frame(0x41, JSON.stringify({ v: 1, role: "receiver", code, token: TOKEN })));
  });
  receiver.on("data", makeParser((t, p) => {
    if (t === 0x42) {
      results.push("receiver PAIRED " + p.toString());
      if (++pairedCount === 2) afterPaired();
    } else if (t === 0x43) fail("receiver got RELAY_ERROR " + p.toString());
    else if (t === 0x98) {
      results.push("receiver got payload: " + p.toString());
      // 回一条给 sender，验证反向转发
      receiver.write(frame(0x99, "pong-through-relay"));
    }
  }));
  receiver.on("error", (e) => fail("receiver socket: " + e.message));
}

// 3) 配对成功后 sender→receiver 发自定义帧，验证透明转发
function afterPaired() {
  sender.write(frame(0x98, "hello-through-relay"));
}

function finish() {
  console.log("PASS");
  results.forEach((r) => console.log("  " + r));
  // 4) 附加：错误码测试
  const bad = net.createConnection(PORT, HOST, () => {
    bad.write(frame(0x41, JSON.stringify({ v: 1, role: "receiver", code: "000001", token: TOKEN })));
  });
  bad.on("data", makeParser((t, p) => {
    if (t === 0x43) {
      console.log("  bad-code test: RELAY_ERROR " + p.toString());
      process.exit(0);
    }
  }));
  setTimeout(() => fail("bad-code test timeout"), 5000);
}

setTimeout(() => fail("overall timeout"), 15000);
