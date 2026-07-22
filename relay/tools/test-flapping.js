// v1.7 register-flapping 测试：两个发送端抢同一 pairHash 时，relay 应在若干次顶替后
// 回 room_occupied 打破互踢循环，而不是静默无限顶替。
// 用法: NETDISPLAY_RELAY_TOKEN=<token> node test-flapping.js [host]
const net = require("net");
const crypto = require("crypto");
const HOST = process.argv[2] || "15.tokencv.com";
const PORT = 47700;
const TOKEN = process.env.NETDISPLAY_RELAY_TOKEN || undefined;

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

const hash = crypto.createHash("sha256").update(crypto.randomBytes(32)).digest("hex");
let occupied = null;
let accepted = 0;
const conns = [];

// 连续注册同一 pairHash，模拟两个发送端互踢
function registerOnce(i, done) {
  const s = net.createConnection(PORT, HOST, () => {
    s.write(frame(0x40, { v: 1, role: "sender", token: TOKEN, code: "", pairHash: hash }));
  });
  conns.push(s);
  let settled = false;
  s.on("data", parse((t, p) => {
    if (settled) return;
    if (t === 0x43) {
      settled = true;
      const reason = JSON.parse(p).reason;
      if (reason === "room_occupied") occupied = i;
      else console.log(`  #${i} 其它错误: ${reason}`);
      done();
    }
  }));
  s.on("error", () => {});
  // 没收到错误 = 注册被接受
  setTimeout(() => { if (!settled) { settled = true; accepted++; done(); } }, 700);
}

(async () => {
  console.log(`连续注册同一 pairHash（模拟两个发送端互踢），期望第 ${4} 次前后被拒…`);
  for (let i = 1; i <= 6; i++) {
    await new Promise((r) => registerOnce(i, r));
    if (occupied) break;
  }
  conns.forEach((s) => s.destroy());
  if (occupied) {
    console.log(`PASS: 第 ${occupied} 次注册被拒 (room_occupied)，前 ${accepted} 次接受 —— 互踢循环可被打破`);
    process.exit(0);
  }
  console.log(`FAIL: 6 次注册全部被接受，relay 仍会静默无限顶替`);
  process.exit(1);
})();
