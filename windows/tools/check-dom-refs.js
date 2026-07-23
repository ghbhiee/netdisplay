// 检查 renderer.js 里引用的 DOM id 是否都存在于 index.html。
//   node tools/check-dom-refs.js
//
// 起因：重做界面时删掉了 #hint，renderer 仍在 startStreaming 里用它 → 抛
// 「Cannot read properties of null」，而异常发生在帧回调里被吞掉，表面症状是
// 「连接成功但没有画面」，查了四轮才定位到。这类问题静态一扫就能发现。
"use strict";
const fs = require("fs");
const path = require("path");

const dir = path.join(__dirname, "..", "src");
const js = fs.readFileSync(path.join(dir, "renderer.js"), "utf8");
const html = fs.readFileSync(path.join(dir, "index.html"), "utf8");

const referenced = [...js.matchAll(/\$\("([A-Za-z][\w-]*)"\)/g)].map((m) => m[1]);
const declared = new Set([...html.matchAll(/id="([^"]+)"/g)].map((m) => m[1]));

const missing = [...new Set(referenced)].filter((id) => !declared.has(id));
if (missing.length) {
  console.log("❌ renderer.js 引用了 index.html 中不存在的 id：");
  for (const id of missing) {
    const line = js.split("\n").findIndex((l) => l.includes(`$("${id}")`)) + 1;
    console.log(`   $("${id}")  —— renderer.js:${line}`);
  }
  process.exit(1);
}
console.log(`✅ ${new Set(referenced).size} 个 DOM 引用全部存在于 index.html`);
