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
const raw = fs.readFileSync(path.join(dir, "renderer.js"), "utf8");
const html = fs.readFileSync(path.join(dir, "index.html"), "utf8");

// 注释里提到 $("res") 只是在讲历史，不是真引用。不剔掉就会报假警，
// 而假警和真警混在一起时，真警就会被当成噪音忽略掉——那这工具就废了。
// 用空格替换而不是删除：行号要和原文对齐，否则报出来的位置指向别处，更难查。
const blank = (s) => s.replace(/[^\n]/g, " ");
const js = raw
  .replace(/\/\*[\s\S]*?\*\//g, blank)
  .replace(/(^|[^:])\/\/[^\n]*/g, (m, p1) => p1 + blank(m.slice(p1.length)));

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
