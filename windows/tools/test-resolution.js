// docs/02 §3.10 分辨率/呈现模式自测（对齐 Mac 的 resolution-selftest 四条）。
// sender.js 在 Electron renderer 上下文里跑，这里复刻它的 presentMode/clampWindow 纯函数逻辑，
// 保持与 src/sender.js 一字不差；改了那边记得同步这里。
// 规则：整屏(含指定某块屏/虚拟扩展屏)=extend 发原生、不缩放；单窗口=window clamp≤对方屏幕、
// 等比缩小、绝不放大、取偶。
function presentMode(k) { return k === "window" ? "window" : "extend"; }
function clampWindow(w, h, peer) {
  const pw = (peer && peer.width) | 0, ph = (peer && peer.height) | 0;
  let ow = w & ~1, oh = h & ~1;
  if (pw && ph && (ow > pw || oh > ph)) {
    const k = Math.min(pw / ow, ph / oh);
    ow = Math.max(2, Math.round(ow * k) & ~1);
    oh = Math.max(2, Math.round(oh * k) & ~1);
  }
  return { width: ow, height: oh };
}

const peer = { width: 1920, height: 1080 };
let ok = true;
const t = (n, c) => { console.log((c ? "✅" : "❌") + " " + n); ok = ok && c; };

// ① 跟随对方（整屏）= extend；单窗口 = window
t("整屏=extend / 单窗口=window",
  presentMode("desktop") === "extend" && presentMode(null) === "extend" && presentMode("window") === "window");
// ② 不超对方屏 → 不裁剪，原样（仅取偶）
{ const a = clampWindow(1600, 900, peer); t("不超限不裁剪 1600x900", a.width === 1600 && a.height === 900); }
// ③ 超对方屏 → 等比缩到不超，比例不变
{ const b = clampWindow(3000, 2000, peer);
  t("超限等比修正 ≤1920x1080 且比例不变",
    b.width <= 1920 && b.height <= 1080 && Math.abs(b.width / b.height - 1.5) < 0.01); }
// ④ 绝不放大：小窗投大屏，原样
{ const c = clampWindow(800, 600, { width: 2560, height: 1600 }); t("绝不放大 800x600", c.width === 800 && c.height === 600); }
// ⑤ 偶数化
{ const d = clampWindow(1921, 1081, { width: 4096, height: 4096 }); t("偶数化 1921x1081→偶", d.width % 2 === 0 && d.height % 2 === 0); }

console.log(ok ? "\n分辨率自测全部通过" : "\n有用例失败");
process.exit(ok ? 0 : 1);
