// v1.5 token 认证测试：无 token 应被拒（unauthorized）、带 token 应可配对。
// 用法: NETDISPLAY_RELAY_TOKEN=<token> node test-token.js [host]
const net = require("net");
const HOST = process.argv[2] || "15.tokencv.com";
const PORT = 47700;
const TOKEN = process.env.NETDISPLAY_RELAY_TOKEN;
if (!TOKEN) { console.error("请设置 NETDISPLAY_RELAY_TOKEN 环境变量"); process.exit(2); }

const frame = (t, o) => {
  const p = Buffer.from(JSON.stringify(o));
  const b = Buffer.alloc(5 + p.length);
  b[0] = t; b.writeUInt32BE(p.length, 1); p.copy(b, 5);
  return b;
};
const parse = (cb) => {
  let buf = Buffer.alloc(0);
  return (c) => {
    buf = Buffer.concat([buf, c]);
    while (buf.length >= 5) {
      const l = buf.readUInt32BE(1);
      if (buf.length < 5 + l) break;
      cb(buf[0], buf.subarray(5, 5 + l));
      buf = buf.subarray(5 + l);
    }
  };
};
const code = String(100000 + Math.floor(Math.random() * 900000));

// 1) 无 token REGISTER → unauthorized
const s1 = net.createConnection(PORT, HOST, () => s1.write(frame(0x40, { v: 1, role: "sender", code })));
s1.on("data", parse((t, p) => {
  if (t === 0x43 && JSON.parse(p).reason === "unauthorized") {
    console.log("PASS: no-token -> unauthorized");
    step2();
  } else { console.log("FAIL step1", t, p.toString()); process.exit(1); }
}));

function step2() {
  let paired = 0;
  const done = () => { console.log("PASS: with-token -> PAIRED"); process.exit(0); };
  const a = net.createConnection(PORT, HOST, () => a.write(frame(0x40, { v: 1, role: "sender", code, token: TOKEN })));
  a.on("data", parse((t) => { if (t === 0x42 && ++paired === 2) done(); }));
  setTimeout(() => {
    const b = net.createConnection(PORT, HOST, () => b.write(frame(0x41, { v: 1, role: "receiver", code, token: TOKEN })));
    b.on("data", parse((t, p) => {
      if (t === 0x42 && ++paired === 2) done();
      if (t === 0x43) { console.log("FAIL step2", p.toString()); process.exit(1); }
    }));
  }, 300);
}
setTimeout(() => { console.log("FAIL timeout"); process.exit(1); }, 10000);
