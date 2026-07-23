// 检查每个界面脚本引用的 DOM id 是否都存在于它配套的 HTML 里。
//   node tools/check-dom-refs.js
//
// 起因：重做界面时删掉了 #hint，renderer 仍在 startStreaming 里用它 → 抛
// 「Cannot read properties of null」，而异常发生在帧回调里被吞掉，表面症状是
// 「连接成功但没有画面」，查了四轮才定位到。这类问题静态一扫就能发现。
//
// 现在有三对窗口（引擎/主面板/托盘），三对都要扫。panel.js 和 tray.js 是
// 另外写的，我没有逐行读过——正因如此才更要有这道静态检查兜着。
"use strict";
const fs = require("fs");
const path = require("path");

const dir = path.join(__dirname, "..", "src");
const PAIRS = [
  ["renderer.js", "index.html"],
  ["panel.js", "panel.html"],
  ["tray.js", "tray.html"],
];

// 注释里提到 $("res") 只是在讲历史，不是真引用。不剔掉就会报假警，
// 而假警和真警混在一起时，真警就会被当成噪音忽略掉——那这工具就废了。
// 用空格替换而不是删除：行号要和原文对齐，否则报出来的位置指向别处，更难查。
const blank = (s) => s.replace(/[^\n]/g, " ");
const stripComments = (raw) =>
  raw
    .replace(/\/\*[\s\S]*?\*\//g, blank)
    .replace(/(^|[^:])\/\/[^\n]*/g, (m, p1) => p1 + blank(m.slice(p1.length)));

let failed = 0;
let total = 0;

for (const [jsName, htmlName] of PAIRS) {
  const jsPath = path.join(dir, jsName);
  const htmlPath = path.join(dir, htmlName);
  if (!fs.existsSync(jsPath) || !fs.existsSync(htmlPath)) {
    console.log(`⚠️  跳过 ${jsName} / ${htmlName}（文件不存在）`);
    continue;
  }
  const js = stripComments(fs.readFileSync(jsPath, "utf8"));
  const html = fs.readFileSync(htmlPath, "utf8");

  // 支持 $("x") 和 document.getElementById("x") 两种写法——别的文件不一定
  // 用了 $ 这个简写，只认一种的话会漏扫，而漏扫比不扫更危险（给人已检查的错觉）。
  const referenced = [
    ...js.matchAll(/\$\("([A-Za-z][\w-]*)"\)/g),
    ...js.matchAll(/getElementById\("([A-Za-z][\w-]*)"\)/g),
  ].map((m) => m[1]);
  const declared = new Set([...html.matchAll(/id="([^"]+)"/g)].map((m) => m[1]));

  const missing = [...new Set(referenced)].filter((id) => !declared.has(id));
  total += new Set(referenced).size;
  if (missing.length) {
    failed++;
    console.log(`❌ ${jsName} 引用了 ${htmlName} 中不存在的 id：`);
    for (const id of missing) {
      const line =
        js.split("\n").findIndex((l) => l.includes(`"${id}"`)) + 1;
      console.log(`   "${id}"  —— ${jsName}:${line}`);
    }
  } else {
    console.log(`✅ ${jsName} → ${htmlName}：${new Set(referenced).size} 个引用全部存在`);
  }
}

if (failed) process.exit(1);
console.log(`✅ 三对窗口共 ${total} 个 DOM 引用全部对得上`);
