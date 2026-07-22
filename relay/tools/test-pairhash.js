// v1.4 relay pairHash 测试：hash 房间撮合 + 替换注册 + 旧 code 流程回归
// relay 启用鉴权时设 NETDISPLAY_RELAY_TOKEN
const net = require("net");
const crypto = require("crypto");
const HOST = process.argv[2] || "15.tokencv.com";
const PORT = 47700;
const TOKEN = process.env.NETDISPLAY_RELAY_TOKEN || undefined;

function frame(type, obj) {
  const p = Buffer.from(JSON.stringify(obj));
  const b = Buffer.alloc(5 + p.length);
  b[0] = type; b.writeUInt32BE(p.length, 1); p.copy(b, 5);
  return b;
}
function parser(onFrame) {
  let buf = Buffer.alloc(0);
  return (c) => {
    buf = Buffer.concat([buf, c]);
    while (buf.length >= 5) {
      const len = buf.readUInt32BE(1);
      if (buf.length < 5 + len) break;
      onFrame(buf[0], buf.subarray(5, 5 + len));
      buf = buf.subarray(5 + len);
    }
  };
}
const conn = (onFrame) =>
  new Promise((res) => {
    const s = net.createConnection(PORT, HOST, () => res(s));
    s.on("data", parser((t, p) => onFrame(s, t, p)));
    s.on("error", () => {});
  });

const hash = crypto.createHash("sha256").update(crypto.randomBytes(32)).digest("hex");
const results = [];

(async () => {
  // 1) senderA 用 pairHash 注册；senderB 同 hash 替换注册（A 应被踢）
  let aClosed = false;
  const a = await conn(() => {});
  a.on("close", () => { aClosed = true; });
  a.write(frame(0x40, { v: 1, role: "sender", token: TOKEN, code: "", pairHash: hash }));
  await new Promise((r) => setTimeout(r, 400));

  const bPaired = new Promise((res) => {
    conn((s, t, p) => {
      if (t === 0x42) { results.push("senderB PAIRED (替换注册后撮合成功)"); res(s); }
      if (t === 0x43) { console.error("FAIL senderB:", p.toString()); process.exit(1); }
    }).then((s) => s.write(frame(0x40, { v: 1, role: "sender", token: TOKEN, code: "", pairHash: hash })));
  });
  await new Promise((r) => setTimeout(r, 400));
  results.push("senderA closed after replace: " + aClosed);

  // 2) receiver 用 pairHash join → 应与 senderB 配对
  const rPaired = new Promise((res) => {
    conn((s, t, p) => {
      if (t === 0x42) { results.push("receiver PAIRED via pairHash"); res(s); }
      if (t === 0x43) { console.error("FAIL receiver:", p.toString()); process.exit(1); }
    }).then((s) => s.write(frame(0x41, { v: 1, role: "receiver", token: TOKEN, code: "", pairHash: hash })));
  });
  await Promise.all([bPaired, rPaired]);

  // 3) 回归：老 code 流程仍可用
  const code = String(100000 + Math.floor(Math.random() * 900000));
  const s1 = await conn((s, t) => { if (t === 0x42) results.push("code sender PAIRED (回归)"); });
  s1.write(frame(0x40, { v: 1, role: "sender", token: TOKEN, code }));
  await new Promise((r) => setTimeout(r, 300));
  const s2 = await conn((s, t) => {
    if (t === 0x42) {
      results.push("code receiver PAIRED (回归)");
      console.log("PASS");
      results.forEach((x) => console.log("  " + x));
      process.exit(0);
    }
  });
  s2.write(frame(0x41, { v: 1, role: "receiver", token: TOKEN, code }));
  setTimeout(() => { console.error("FAIL: timeout"); process.exit(1); }, 8000);
})();
