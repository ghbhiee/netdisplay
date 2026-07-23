// NetDisplay 托盘弹出菜单（无边框透明窗口，贴托盘图标弹出）。
//
// 为什么不用 Electron 原生 Menu：设计要求彩色 SVG 图标、两行条目（主标题 + 灰色副行）、
// 内联 chip 选分辨率/缩放、右侧彩色操作文字——原生菜单一个都做不到。
//
// 本文件不保存任何业务状态：快照来自 nd-state-get，之后由 nd-state 整份覆盖重渲染。
// 本地只留 UI 状态（哪个二级菜单开着），因为它跟引擎无关，引擎推状态时不该把它关掉。
"use strict";
const { ipcRenderer } = require("electron");

const $ = (id) => document.getElementById(id);
const cmd = (c, extra) => ipcRenderer.send("nd-cmd", Object.assign({ cmd: c }, extra || {}));
const closeTray = () => ipcRenderer.send("nd-tray-close");

// 菜单本体 246px + 二级菜单向左弹 170px + 4px 间隙 + 两侧 12px 阴影余量。
// 宽度取固定值：二级菜单开合时窗口宽度不变，main.js 只需按右下角定位一次，不必跟着改。
const PAD = 12;
const MENU_W = 246;
const SUB_W = 170;
const SUB_GAP = 4;
const WIN_W = PAD * 2 + MENU_W + SUB_GAP + SUB_W;

// 画质：发出去和存回来的一律是内部值，中文只用于显示（见 UI-CONTRACT「画质取值表」）。
// res 的分隔符必须是半角小写 x——引擎要 split("x") 拆编码宽高，全角 × 会拆出 NaN。
const RES_OPTS = [
  { v: "auto", label: "跟随对方" },
  { v: "1920x1080", label: "1920×1080" },
  { v: "2560x1440", label: "2560×1440" },
];
const SCALE_OPTS = [
  { v: "1", label: "100%" },
  { v: "1.5", label: "150%" },
  { v: "2", label: "200%" },
];
// 三档预设联动主面板的帧率/码率（契约里没有 trayQuality 字段，预设名反推自 quality）
const PRESETS = [
  { name: "流畅优先", desc: "30fps · 低码率", fps: "30", rate: "auto" },
  { name: "平衡", desc: "60fps · 自动", fps: "60", rate: "auto" },
  { name: "清晰优先", desc: "60fps · 20Mbps", fps: "60", rate: "20" },
];
const WIN_ICONS = ["▦", "◨", "▤", "◧", "◫", "▧", "▥", "▨", "▩", "◪", "◩"];

let S = null;          // 引擎状态快照
let sub = null;        // 唯一的 UI 状态："more" | "moreq" | null

// ---------- 小工具 ----------

const show = (el, on) => el.classList.toggle("hide", !on);
const text = (el, v) => { el.textContent = v == null ? "" : String(v); };

function iconFor(id) {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) >>> 0;
  return WIN_ICONS[h % WIN_ICONS.length];
}

// 「直连 · 3ms」——探测不到的部分就不显示，别拼出「· null」这种东西
function linkLabel(d) {
  if (!d) return "";
  const t = d.transport === "relay" ? "中转" : d.transport === "direct" ? "直连" : "";
  const r = typeof d.rttMs === "number" ? d.rttMs + "ms" : "";
  return [t, r].filter(Boolean).join(" · ");
}

let toastTimer = null;
function toast(msg) {
  const el = $("toast");
  text(el, msg);
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 2600);
}

function row(cls, parts, onClick) {
  const d = document.createElement("div");
  d.className = cls;
  for (const p of parts) {
    const s = document.createElement("span");
    s.className = p.cls;
    if (p.text != null) s.textContent = p.text;
    if (p.color) s.style.color = p.color;
    if (p.style) s.setAttribute("style", (s.getAttribute("style") || "") + p.style);
    if (p.onClick) s.addEventListener("click", p.onClick);
    d.appendChild(s);
  }
  if (onClick) d.addEventListener("click", onClick);
  return d;
}

function setSub(next) {
  sub = sub === next ? null : next;
  render();
}

// ---------- 渲染 ----------

function render() {
  const s = S || {};
  document.documentElement.setAttribute("data-theme", s.theme === "dark" ? "dark" : "light");

  const role = s.role || "standby";
  const casting = role === "casting";
  const receiving = role === "receiving";
  const switching = role === "switching";
  const svcOff = (s.recvSvc || "off") === "off";

  const devices = Array.isArray(s.devices) ? s.devices : [];
  const sel = devices.find((d) => d.id === s.selectedId) || null;
  const peerName = s.peerName || (sel ? sel.name : "") || "对方";
  const link = linkLabel(sel);

  // --- 第一节：投射 ---
  text($("castTitle"), casting ? "投射中 · " + (s.castSourceName || "整块屏幕") : "投射");
  show($("castSub"), casting);
  if (casting) text($("castSub"), "目标：" + peerName + (link ? " · " + link : ""));

  const castAct = $("castAction");
  text(castAct, receiving ? "接收中不可用" : switching ? "切换中…" : casting ? "断开" : "开始 ▸");
  castAct.style.color = casting ? "var(--err)" : receiving || switching ? "var(--sub)" : "var(--accent)";
  $("castItem").classList.toggle("dim", receiving);

  // --- 第一节：接收服务 ---
  text($("recvTitle"), receiving ? "接收投屏中" : svcOff ? "启动接收服务" : "接收服务 · 等待连接");
  show($("recvSub"), receiving);
  if (receiving) text($("recvSub"), "来源：" + peerName + (link ? " · " + link : ""));

  const recvAct = $("recvAction");
  text(recvAct, casting ? "投射中不可用" : receiving ? "断开" : svcOff ? "" : "关闭");
  recvAct.style.color = receiving ? "var(--err)" : "var(--sub)";
  $("recvItem").classList.toggle("dim", casting);

  // --- 第二节：投射内容 ---
  // 接收服务开着就不列投什么。投射与接收互斥，正等着收画面的时候还摆一排
  // 「投射内容」，等于请用户点一个必然会被拒的东西。（用户提的，两端一致。）
  const srcOn = !!sel && sel.conn === "on" && !receiving && svcOff;
  show($("secSrc"), srcOn);
  show($("sepSrc"), srcOn);
  if (srcOn) renderSources(s);
  else { $("srcList").innerHTML = ""; $("moreWinMenu").innerHTML = ""; }

  // --- 第三节：已配对设备 ---
  text($("devHeader"), svcOff ? "投射目标 · 已配对设备"
    : receiving ? "接收中 · 已配对设备" : "等待接收 · 已配对设备");
  renderDevices(devices, s, { casting, receiving, svcOff });
  show($("addDevItem"), devices.length === 0);

  // --- 第四节：显示设置 ---
  const q = s.quality || {};
  // 引擎万一回的是数字（60 而不是 "60"），严格比较会静默地全都不选中——统一成字符串再比
  const qv = (k) => (q[k] == null ? "" : String(q[k]));
  renderChips($("resChips"), RES_OPTS, qv("res"), "res");
  renderChips($("scaleChips"), SCALE_OPTS, qv("scale"), "scale");
  const preset = PRESETS.find((p) => p.fps === qv("fps") && p.rate === qv("rate"));
  text($("qualityName"), preset ? preset.name : "自定义");
  renderPresets(preset);

  // 二级菜单：只允许开一个，且开着的那个必须完整落在菜单高度内（见 clampSub）
  show($("moreWinMenu"), sub === "more" && srcOn);
  show($("moreQMenu"), sub === "moreq");

  requestAnimationFrame(() => { clampSub(); reportSize(); });
}

function renderSources(s) {
  const list = Array.isArray(s.sources) ? s.sources : [];
  const wins = list.filter((x) => x.kind === "window");
  const screens = list.filter((x) => x.kind === "desktop");
  const pick = s.pickSel || "";

  // 「整块屏幕」用空 id 表示；多显示器时才把各屏单列出来，单屏不制造冗余行
  const inline = [{ id: "", name: "整块屏幕", icon: "🖥" }]
    .concat(screens.length > 1 ? screens.map((x) => ({ id: x.id, name: x.name, icon: "🖥" })) : [])
    .concat(wins.slice(0, 8).map((x) => ({ id: x.id, name: x.name, icon: iconFor(x.id) })));
  const more = wins.slice(8).map((x) => ({ id: x.id, name: x.name, icon: iconFor(x.id) }));

  const box = $("srcList");
  box.innerHTML = "";
  for (const it of inline) box.appendChild(srcRow("row", it, pick));

  show($("moreWinHost"), more.length > 0);
  const mbox = $("moreWinMenu");
  mbox.innerHTML = "";
  for (const it of more) mbox.appendChild(srcRow("subrow", it, pick));
}

function srcRow(cls, it, pick) {
  return row(cls, [
    { cls: "mark", text: pick === it.id ? "✓" : "" },
    { cls: "emj", text: it.icon },
    { cls: "name", text: it.name },
  ], () => { cmd("pick-source", { id: it.id }); sub = null; render(); });
}

function renderDevices(devices, s, f) {
  const box = $("devList");
  box.innerHTML = "";

  for (const d of devices) {
    const on = d.conn === "on";
    const status = on ? (f.casting ? "投射中" : f.receiving ? "接收中" : "已连接")
      : d.conn === "connecting" ? "连接中…" : d.online ? "在线" : "离线";
    // 已开接收服务时只显示状态、不给连接操作（README 第三节）
    const actionOn = f.svcOff && d.online && !(f.casting && !on);

    const parts = [
      { cls: "mark", text: s.selectedId === d.id ? "◉" : "○",
        color: s.selectedId === d.id ? "var(--accent)" : "var(--sub)" },
      { cls: "dot", style: "background:" + (on ? "var(--ok)" : d.online ? "var(--accent)" : "var(--sub)") + ";" },
      { cls: "name", text: d.name },
      { cls: "st", text: status, color: on ? "var(--ok)" : "var(--sub)" },
    ];
    if (actionOn) {
      parts.push({
        cls: "act", text: on ? "断开" : "连接",
        color: on ? "var(--err)" : "var(--accent)",
        onClick: (e) => {
          e.stopPropagation();
          if (on) { cmd("disconnect", { id: d.id }); closeTray(); return; }
          if (f.casting) { toast("投射中，无法连接其他设备"); return; }
          cmd("connect", { id: d.id });
          closeTray();
        },
      });
    }

    const el = row("devrow", parts, () => {
      if (f.casting || f.receiving) { toast("投射/接收进行中，无法切换设备"); return; }
      cmd("select-device", { id: d.id });
    });
    // 进行中时非当前设备置灰，点了只提示
    if ((f.casting || f.receiving) && s.selectedId !== d.id) el.classList.add("dim");
    box.appendChild(el);
  }
}

function renderChips(box, opts, cur, key) {
  box.innerHTML = "";
  for (const o of opts) {
    const c = document.createElement("span");
    c.className = "chip" + (cur === o.v ? " on" : "");
    c.textContent = o.label;
    c.addEventListener("click", () => cmd("quality", { key, value: o.v }));
    box.appendChild(c);
  }
}

function renderPresets(cur) {
  const box = $("moreQMenu");
  box.innerHTML = "";
  for (const p of PRESETS) {
    box.appendChild(row("subrow", [
      { cls: "mark", text: cur && cur.name === p.name ? "✓" : "" },
      { cls: "name", text: p.name },
      { cls: "desc", text: p.desc },
    ], () => {
      // 预设 = 帧率 + 码率两项的组合，契约里没有「预设」这个命令
      cmd("quality", { key: "fps", value: p.fps });
      cmd("quality", { key: "rate", value: p.rate });
    }));
  }
  box.appendChild(row("subrow", [
    { cls: "mark", text: "" },
    { cls: "name", text: "帧率 / 码率（主面板）…" },
  ], () => { cmd("open-panel", { section: "quality" }); closeTray(); }));
}

// 二级菜单默认与触发行齐平，但两个触发行都靠菜单底部，直接弹会溢出到菜单外
// （窗口是透明的，溢出部分会被裁掉）。这里往上顶，让它始终落在菜单内。
function clampSub() {
  for (const el of [$("moreWinMenu"), $("moreQMenu")]) {
    if (el.classList.contains("hide")) continue;
    el.style.top = "0px";
    const menuBottom = $("menu").getBoundingClientRect().bottom - 5;
    const over = el.getBoundingClientRect().bottom - menuBottom;
    if (over > 0) el.style.top = -Math.ceil(over) + "px";
  }
}

// 内容高度随状态变化（设备多少、第二节在不在），渲染完把窗口该多大报给 main.js。
// 宽度恒定，height 含上下透明边；pad/menuWidth 给 main.js 做右下角对齐用。
let lastH = -1;
function reportSize() {
  const h = Math.ceil($("menu").getBoundingClientRect().height) + PAD * 2;
  if (h === lastH) return;
  lastH = h;
  ipcRenderer.send("nd-tray-size", { width: WIN_W, height: h, pad: PAD, menuWidth: MENU_W });
}

// ---------- 事件 ----------

$("castItem").addEventListener("click", () => {
  const role = (S && S.role) || "standby";
  if (role === "receiving") { toast("正在接收投屏，投射不可用"); return; }
  if (role === "switching") { toast("正在切换，请稍候"); return; }
  if (role === "casting") { cmd("stop"); closeTray(); return; }
  const devices = (S && S.devices) || [];
  const sel = devices.find((d) => d.id === (S && S.selectedId));
  if (!sel) { toast("请先选择投射目标设备"); return; }
  if (!sel.online) { toast("对方离线，无法投射"); return; }
  cmd("start-cast");
  closeTray();
});

$("recvItem").addEventListener("click", () => {
  const role = (S && S.role) || "standby";
  if (role === "casting" || role === "switching") { toast("正在投射，接收服务不可用"); return; }
  if (role === "receiving") { cmd("drop-stream"); closeTray(); return; }
  const svcOff = !S || (S.recvSvc || "off") === "off";
  cmd("recv-svc", { on: svcOff });
  closeTray();
});

// 配对要输 6 位码，托盘弹窗放不下这个表单，交给主面板
$("addDevItem").addEventListener("click", () => { cmd("open-panel", { section: "pair" }); closeTray(); });
$("moreWinBtn").addEventListener("click", () => setSub("more"));
$("moreQBtn").addEventListener("click", () => setSub("moreq"));
$("relayItem").addEventListener("click", () => { cmd("open-panel", { section: "relay" }); closeTray(); });
$("openPanelItem").addEventListener("click", () => { cmd("open-panel"); closeTray(); });
$("quitItem").addEventListener("click", () => cmd("quit"));

// 点菜单外部（含窗口四周的透明区）即关闭
document.addEventListener("mousedown", (e) => {
  if (!$("menu").contains(e.target)) closeTray();
});

// 点菜单内别处收起二级菜单。必须挂在 click 冒泡末端而不是 mousedown：
// 收起会重建列表 DOM，若在 mousedown 阶段做，mouseup 落到新元素上，
// 浏览器就不再派发 click——表现成「点了没反应」。
document.addEventListener("click", (e) => {
  if (!sub) return;
  if (!$("menu").contains(e.target)) return;
  const inSub = $("moreWinMenu").contains(e.target) || $("moreQMenu").contains(e.target)
    || $("moreWinBtn").contains(e.target) || $("moreQBtn").contains(e.target);
  if (inSub) return;
  sub = null;
  render();
});

// 主进程若复用同一个隐藏窗口，再次弹出时得回到干净状态：二级菜单收起、尺寸重报一次
window.addEventListener("focus", () => {
  lastH = -1;
  if (sub) { sub = null; render(); } else { reportSize(); }
});

window.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return;
  if (sub) { sub = null; render(); return; }
  closeTray();
});

// ---------- 启动 ----------

ipcRenderer.on("nd-state", (_e, s) => { S = s || {}; render(); });
ipcRenderer.on("nd-toast", (_e, msg) => toast(msg));

ipcRenderer.invoke("nd-state-get").then((s) => { S = s || {}; render(); }).catch(() => render());

// 字体在首帧后才就位，宽高会再变一次；ResizeObserver 兜住所有非渲染触发的尺寸变化
if (window.ResizeObserver) new ResizeObserver(() => reportSize()).observe($("menu"));
render();
