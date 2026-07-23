// agent-chat 长轮询守望进程：只在**真有新消息**时向 stdout 输出一行。
//
// 为什么这么做：让 agent 自己循环 poll，每次 poll 返回都要调用一次模型（且每次都携带
// 完整对话历史），空闲一小时 ≈ 144 次模型调用，token 是二次方级累积。把等待放进这个
// 进程后，空闲期零模型调用；只有真消息才产生一次唤醒。
//
// 配合 Monitor 工具使用（每行 stdout = 一个事件 = 一次唤醒）：
//   node windows/tools/chat-watch.js [--since <id>] [--self win-coordinator,windows-claude]
//
// --self 列出的发送者被视为「自己人」，不触发唤醒（避免被自己的发言吵醒）。
"use strict";
const { execSync } = require("child_process");
const https = require("https");

const argv = process.argv.slice(2);
const arg = (n, d) => { const i = argv.indexOf("--" + n); return i >= 0 ? argv[i + 1] : d; };

const HOST = "15.tokencv.com";
const PORT = 47900;
const SELF = (arg("self", "windows-claude,win-coordinator") || "").split(",").filter(Boolean);
let since = +arg("since", 0);

function getToken() {
  // token 只在启动时取一次；ssh 每轮都调会拖慢响应也增加失败面
  return execSync(`ssh root@${HOST} "cat /root/cc/agent-chat/token"`, {
    encoding: "utf8", timeout: 30000,
  }).trim();
}

function poll(token) {
  return new Promise((resolve) => {
    const req = https.get(
      { host: HOST, port: PORT, path: `/messages?since=${since}&wait=25`, headers: { Authorization: "Bearer " + token }, timeout: 40000 },
      (res) => {
        let body = "";
        res.on("data", (c) => (body += c));
        res.on("end", () => {
          try { resolve(JSON.parse(body).messages || []); }
          catch { resolve(null); } // 解析失败当作瞬时故障，下轮重试
        });
      }
    );
    req.on("error", () => resolve(null));
    req.on("timeout", () => { req.destroy(); resolve(null); });
  });
}

(async () => {
  let token;
  try { token = getToken(); }
  catch (e) { console.error(`[chat-watch] 取 token 失败，退出: ${e.message}`); process.exit(1); }

  // 首轮先对齐到当前最大 id，避免把历史消息全喷成事件
  const initial = await poll(token);
  if (initial && initial.length) since = initial[initial.length - 1].id;
  // 诊断信息一律走 stderr：Monitor 只把 stdout 当事件，stderr 进输出文件但不触发唤醒。
  // 启动日志用 console.log 会白白唤醒 agent 一次——它不是消息，不该打断工作。
  console.error(`[chat-watch] 已就绪，从 id=${since} 起守望（仅新消息触发唤醒）`);

  let failures = 0;
  for (;;) {
    const msgs = await poll(token);
    if (msgs === null) {
      // 瞬时故障：退避重试，连续失败多了才报一次，避免刷屏
      if (++failures === 5) console.error("[chat-watch] 连续 5 次轮询失败，仍在重试");
      await new Promise((r) => setTimeout(r, Math.min(30000, 2000 * failures)));
      continue;
    }
    failures = 0;
    for (const m of msgs) {
      since = Math.max(since, m.id);
      if (SELF.includes(m.from)) continue; // 自己发的不唤醒
      // 300 字符太短：对端常把一条完整技术决定发在一条消息里，截断后还得再拉一次全文。
      // 放宽到 1500 让绝大多数消息一次到位；真超长的才提示去取。
      const full = String(m.text || "").replace(/\s+/g, " ");
      const text = full.length > 1500 ? full.slice(0, 1500) + `…（共 ${full.length} 字，全文见 /messages?since=${m.id - 1}）` : full;
      console.log(`[chat#${m.id}] ${m.from}: ${text}`);
    }
  }
})();
