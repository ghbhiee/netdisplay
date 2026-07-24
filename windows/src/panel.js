// NetDisplay 主面板 renderer：纯界面，不碰 socket。
// 契约见 src/UI-CONTRACT.md —— engine 是唯一状态源，这里只做「渲染 + 发命令」。
"use strict";
const { ipcRenderer } = require("electron");

const $ = (id) => document.getElementById(id);
const cmd = (c, args) => ipcRenderer.send("nd-cmd", Object.assign({ cmd: c }, args || {}));

// ===== 引擎状态（只读快照，本文件任何地方都不得直接改它来做乐观更新） =====
const EMPTY_STATE = {
  role: "standby", recvSvc: "off",
  devices: [], selectedId: null,
  sources: [], pickSel: "",
  quality: { res: "", scale: "", fps: "", rate: "" },
  relay: { addr: "", token: "", forceRelay: false, status: "unset", rttMs: null },
  localName: "", peerName: "", castSourceName: "", theme: "light",
};
let S = EMPTY_STATE;

// ===== 纯 UI 状态（不含任何业务信息，刷新丢了也无所谓） =====
const ui = {
  tab: "cast",
  qualityOpen: false,
  advOpen: false,
  renamingId: null,   // 正在行内重命名的设备
  renameVal: "",
  confirmId: null,    // 正在二次确认解除配对的设备
  localEditing: false,
  pairOpen: false,
  relayOpen: false,
  pairErr: false,
};

// 契约「画质取值表」：发出去和比对选中态一律用内部值，中文只是标签。
// res 的分隔符必须是半角小写 x —— 引擎拿它 split("x") 拆编码宽高，全角 × 会拆出 NaN，
// 而 NaN 要一路走到编码器才炸，报错和真正原因隔着十万八千里。
const QUALITY_DEFS = [
  { key: "res", label: "分辨率", opts: [["auto", "跟随对方"], ["1920x1080", "1920×1080"], ["2560x1440", "2560×1440"]] },
  { key: "scale", label: "缩放", opts: [["1", "100%"], ["1.5", "150%"], ["2", "200%"]] },
  { key: "fps", label: "帧率", opts: [["30", "30 fps"], ["60", "60 fps"]] },
  { key: "rate", label: "码率", opts: [["auto", "自动"], ["10", "10 Mbps"], ["20", "20 Mbps"]] },
];

// 设计稿里程序窗口是 Unicode 占位图标（拿不到真实应用图标时的兜底）
const WIN_GLYPHS = ["▦", "◨", "▤", "◧", "◫", "▧", "▥", "▨", "▩", "◪", "◩"];

// ---------- 小工具 ----------
function el(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text; // 设备名/窗口名来自对端，一律 textContent
  return n;
}
function show(node, on) { node.classList.toggle("hidden", !on); }

let toastTimer = null;
function toast(msg) {
  const t = $("toast");
  t.textContent = String(msg == null ? "" : msg);
  show(t, true);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => show(t, false), 2600);
}

const selected = () => (S.devices || []).find((d) => d.id === S.selectedId) || null;
const transportText = (d) => (d.transport === "relay" ? "中转" : d.transport === "direct" ? "直连" : "");

function deviceStatus(d) {
  if (d.conn === "on") {
    const parts = ["已连接"];
    const tp = transportText(d);
    if (tp) parts.push(tp);
    if (typeof d.rttMs === "number") parts.push(d.rttMs + "ms");
    return parts.join(" · ");
  }
  if (d.conn === "connecting") return "连接中…";
  // docs/11：服务器确认对端也输了同码前，是「等待对方…」，不是「未连接」——
  // 「未连接」会让人以为配好了只是没连，其实还没配成。
  if (d.pairStatus === "waiting") return "等待对方输入配对码…";
  return d.online ? "未连接" : "离线";
}

// ---------- 状态接入 ----------
function applyState(next) {
  if (!next || typeof next !== "object") return;
  const prevRole = S.role;
  S = Object.assign({}, EMPTY_STATE, next, {
    devices: Array.isArray(next.devices) ? next.devices : [],
    sources: Array.isArray(next.sources) ? next.sources : [],
    quality: Object.assign({}, EMPTY_STATE.quality, next.quality),
    relay: Object.assign({}, EMPTY_STATE.relay, next.relay),
  });

  // 角色变了就把 tab 跟过去：正在投射却停在接收页会让人以为没生效
  if (S.role !== prevRole) {
    if (S.role === "casting") ui.tab = "cast";
    else if (S.role === "receiving") ui.tab = "recv";
  }
  // 设备被解除配对后，残留的行内编辑状态要清掉
  const ids = new Set(S.devices.map((d) => d.id));
  if (ui.renamingId && !ids.has(ui.renamingId)) ui.renamingId = null;
  if (ui.confirmId && !ids.has(ui.confirmId)) ui.confirmId = null;

  render();
}

ipcRenderer.on("nd-state", (_e, s) => applyState(s));
ipcRenderer.on("nd-toast", (_e, msg) => toast(msg));
// 托盘的「＋ 添加设备…」「中转设置…」「帧率/码率（主面板）…」需要叫开面板里的弹窗；
// 契约表只覆盖 panel→engine 的命令，这个 main→panel 的入口名待确认（不接也不会坏）。
ipcRenderer.on("nd-open", (_e, what) => openFromOutside(what));
window.ndOpen = openFromOutside;

function openFromOutside(what) {
  if (what === "pair") openPair();
  else if (what === "relay") openRelay();
  else if (what === "quality") { ui.tab = "recv"; ui.qualityOpen = true; render(); }
}

// ---------- 渲染 ----------
function render() {
  document.documentElement.dataset.theme = S.theme === "dark" ? "dark" : "light";
  $("themeBtn").textContent = S.theme === "dark" ? "◐ 浅色" : "◑ 深色";

  renderTabs();
  renderCastPage();
  renderRecvPage();
  renderQuality();
  renderDevices();
  renderLocalName();
  renderAdvanced();
  renderModals();
}

function renderTabs() {
  const c = $("tabCast"), r = $("tabRecv");
  c.classList.toggle("on-cast", ui.tab === "cast");
  r.classList.toggle("on-recv", ui.tab === "recv");
  $("castDot").textContent = S.role === "casting" ? "●" : "";
  $("recvDot").textContent = S.role === "receiving" ? "●" : "";
  show($("pageCast"), ui.tab === "cast");
  show($("pageRecv"), ui.tab === "recv");
}

// 投射内容行：pickSel === "" 代表整块屏幕，所以固定给一条「整块屏幕」；
// 引擎只在多显示器时才会给出多个 desktop 源，那时才逐个列出，否则会和上面那条重复。
function sourceRows() {
  const rows = [{ id: "", icon: "🖥", name: "整块屏幕", desc: "作为对方的第二显示器" }];
  const desktops = S.sources.filter((s) => s.kind === "desktop");
  const windows = S.sources.filter((s) => s.kind !== "desktop");
  if (desktops.length > 1) {
    desktops.forEach((s) => rows.push({ id: s.id, icon: "🖥", name: s.name, desc: "显示器" }));
  }
  windows.forEach((s, i) => rows.push({ id: s.id, icon: WIN_GLYPHS[i % WIN_GLYPHS.length], name: s.name, desc: "程序窗口" }));
  return rows;
}

function castBlockReason() {
  if (!S.devices.length) return "还没有配对设备 — 先点「＋ 添加设备」和另一台电脑配对";
  const sel = selected();
  if (!sel) return "先在下面「已配对设备」里选一台投射目标";
  if (S.role === "receiving") return "正在接收对方画面，先断开投屏才能投射";
  if (S.role === "switching") return "正在切换，请稍候";
  if (S.role === "casting") return "已经在投射了";
  if (!sel.online) return "「" + sel.name + "」当前离线，无法投射";
  return null;
}

function renderCastPage() {
  const switching = S.role === "switching";
  const casting = S.role === "casting";

  show($("castSwitching"), switching);
  show($("castingBar"), casting);
  show($("castPick"), !casting && !switching);

  if (casting) {
    $("castingTitle").textContent = "正在投射给 " + (S.peerName || "对方");
    $("castingSource").textContent = "来源：" + (S.castSourceName || "整块屏幕");
    return;
  }
  if (switching) return;

  const list = $("sourceList");
  list.textContent = "";
  for (const row of sourceRows()) {
    const node = el("div", "src" + (S.pickSel === row.id ? " on" : ""));
    node.appendChild(el("div", "icon", row.icon));
    node.appendChild(el("div", "name", row.name));
    node.appendChild(el("div", "desc", row.desc));
    node.appendChild(el("div", "ck", S.pickSel === row.id ? "✓" : ""));
    node.addEventListener("click", () => cmd("pick-source", { id: row.id }));
    list.appendChild(node);
  }

  const blocked = castBlockReason();
  show($("castEmpty"), S.devices.length === 0);
  $("btnStartCast").classList.toggle("off", !!blocked);
}

function renderRecvPage() {
  const casting = S.role === "casting";
  const receiving = S.role === "receiving";
  const switching = S.role === "switching";
  const svcOff = S.recvSvc !== "waiting";

  show($("recvSwitching"), switching);
  show($("recvBar"), receiving);
  show($("recvStatusRow"), !receiving && !switching);

  if (receiving) $("recvBarTitle").textContent = "正在接收 " + (S.peerName || "对方") + " 的画面";

  if (!receiving && !switching) {
    const dot = $("recvSvcDot");
    dot.classList.toggle("live", !casting && !svcOff);
    if (casting) {
      $("recvStatusTitle").textContent = "投射中 — 接收服务不可用";
      $("recvStatusSub").textContent = "同一时刻只能投射或接收其一";
    } else if (svcOff) {
      $("recvStatusTitle").textContent = "接收服务已关闭";
      $("recvStatusSub").textContent = "开启后对方才能投射到本机";
    } else {
      $("recvStatusTitle").textContent = "等待连接中…";
      $("recvStatusSub").textContent = "以「" + (S.localName || "本机") + "」待命 — 对方开始投射后自动显示";
    }
  }

  // 四态循环：关闭 → 等待 → （对方投过来）接收中 → 断开投屏回等待
  const btn = $("btnRecvSvc");
  let label, cls;
  if (switching) { label = "切换中…"; cls = "btn-svc muted"; }
  else if (casting) { label = "投射中 — 接收服务不可用"; cls = "btn-svc muted"; }
  else if (receiving) { label = "断开投屏（服务保持开启）"; cls = "btn-svc"; }
  else if (svcOff) { label = "开启接收服务"; cls = "btn-svc solid"; }
  else { label = "关闭接收服务"; cls = "btn-svc"; }
  $("recvBtnLabel").textContent = label;
  btn.className = cls;
}

let qualityBuilt = false;
function renderQuality() {
  $("qualityChev").textContent = ui.qualityOpen ? "▾" : "▸";
  show($("qualityBody"), ui.qualityOpen);

  const box = $("qualityGroups");
  if (!qualityBuilt) {
    for (const g of QUALITY_DEFS) {
      const row = el("div", "qrow");
      row.appendChild(el("div", "qlabel", g.label));
      const opts = el("div", "qopts");
      for (const [value, label] of g.opts) {
        const b = el("button", "qopt", label);
        b.dataset.key = g.key;
        b.dataset.value = value;
        b.addEventListener("click", () => cmd("quality", { key: g.key, value }));
        opts.appendChild(b);
      }
      row.appendChild(opts);
      box.appendChild(row);
    }
    qualityBuilt = true;
  }
  for (const b of box.querySelectorAll(".qopt")) {
    const cur = S.quality[b.dataset.key];
    b.classList.toggle("on", cur != null && String(cur) === b.dataset.value);
  }
}

function renderDevices() {
  const list = $("devList");
  list.textContent = "";
  show($("devEmpty"), S.devices.length === 0);

  for (const d of S.devices) {
    const row = el("div", "dev" + (S.selectedId === d.id ? " on" : ""));
    row.appendChild(el("span", "radio", S.selectedId === d.id ? "◉" : "○"));

    const dot = el("div", "pdot");
    dot.style.background = d.conn === "on" ? "var(--ok)" : d.online ? "var(--accent)" : "var(--sub)";
    row.appendChild(dot);

    if (ui.renamingId === d.id) {
      const input = el("input", "rename-input");
      input.type = "text";
      input.value = ui.renameVal;
      input.addEventListener("click", (e) => e.stopPropagation());
      input.addEventListener("input", () => { ui.renameVal = input.value; });
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter") saveRename(d.id);
        if (e.key === "Escape") { ui.renamingId = null; render(); }
      });
      row.appendChild(input);
      const save = el("button", "btn-txt", "保存");
      save.style.color = "var(--accent)";
      save.addEventListener("click", (e) => { e.stopPropagation(); saveRename(d.id); });
      row.appendChild(save);
      // 引擎推状态会重建这一行，焦点得补回来，否则打一半字焦点就没了
      setTimeout(() => {
        if (document.activeElement === input) return;
        if (document.activeElement && document.activeElement.tagName === "INPUT") return;
        input.focus();
        input.setSelectionRange(input.value.length, input.value.length);
      }, 0);
    } else if (ui.confirmId === d.id) {
      row.appendChild(el("div", "confirm-txt", "确认解除与「" + d.name + "」的配对？"));
      const yes = el("button", "btn-danger", "解除");
      yes.addEventListener("click", (e) => { e.stopPropagation(); ui.confirmId = null; cmd("unpair", { id: d.id }); render(); });
      const no = el("button", "btn-txt", "取消");
      no.addEventListener("click", (e) => { e.stopPropagation(); ui.confirmId = null; render(); });
      row.appendChild(yes);
      row.appendChild(no);
    } else {
      const grow = el("div", "grow");
      grow.appendChild(el("div", "name", d.name));
      grow.appendChild(el("div", "st" + (d.conn === "on" ? " ok" : ""), deviceStatus(d)));
      row.appendChild(grow);

      if (d.conn === "on") {
        const off = el("button", "btn-ghost", "断开");
        off.addEventListener("click", (e) => { e.stopPropagation(); cmd("disconnect", { id: d.id }); });
        row.appendChild(off);
      }
      const rn = el("button", "btn-txt", "重命名");
      rn.addEventListener("click", (e) => {
        e.stopPropagation();
        ui.renamingId = d.id; ui.renameVal = d.name; ui.confirmId = null;
        render();
      });
      const up = el("button", "btn-txt danger", "解除配对");
      up.addEventListener("click", (e) => {
        e.stopPropagation();
        ui.confirmId = d.id; ui.renamingId = null;
        render();
      });
      row.appendChild(rn);
      row.appendChild(up);
    }

    row.addEventListener("click", () => selectDevice(d));
    list.appendChild(row);
  }
}

function selectDevice(d) {
  if (S.selectedId === d.id) return;
  if (S.role === "casting" || S.role === "receiving") {
    toast("投射/接收进行中，无法切换设备");
    return;
  }
  cmd("select-device", { id: d.id });
}

function saveRename(id) {
  const name = (ui.renameVal || "").trim();
  ui.renamingId = null;
  if (name) cmd("rename", { id, name });
  render();
}

function renderLocalName() {
  $("localNameText").textContent = S.localName || "（未命名）";
  show($("localNameText"), !ui.localEditing);
  show($("btnEditLocal"), !ui.localEditing);
  const input = $("localNameInput");
  show(input, ui.localEditing);
  if (ui.localEditing && document.activeElement !== input) {
    input.focus();
    input.setSelectionRange(input.value.length, input.value.length);
  }
}

function renderAdvanced() {
  $("advChev").textContent = ui.advOpen ? "▾" : "▸";
  show($("advBody"), ui.advOpen);
  // 正在输入的框不要被引擎推来的值覆盖
  setIfIdle($("advRelayAddr"), S.relay.addr || "");
  setIfIdle($("advRelayToken"), S.relay.token || "");
  $("advForce").classList.toggle("on", !!S.relay.forceRelay);
}

function setIfIdle(input, value) {
  if (document.activeElement === input) return;
  if (input.value !== value) input.value = value;
}

function renderModals() {
  show($("pairModal"), ui.pairOpen);
  show($("pairErr"), ui.pairErr);
  $("pairCode").classList.toggle("err", ui.pairErr);

  show($("relayModal"), ui.relayOpen);
  const ok = S.relay.status === "ok";
  $("relayDot").style.background = ok ? "var(--ok)" : S.relay.status === "error" ? "var(--err)" : "var(--sub)";
  $("relayStatusText").textContent = relayStatusText();
  setIfIdle($("mRelayAddr"), S.relay.addr || "");
  setIfIdle($("mRelayToken"), S.relay.token || "");
  $("mForce").classList.toggle("on", !!S.relay.forceRelay);
}

function relayStatusText() {
  if (!S.relay.addr) return "未设置中转服务器";
  // 引擎探测出的具体原因优先：「Token 不正确」和「连不上」要用户做的事完全不同，
  // 混成一句「检查地址和 Token」等于让他两样都试一遍。
  if (S.relay.message) return S.relay.message;
  if (S.relay.status === "error") return "中转服务连不上 · " + S.relay.addr + " — 检查地址和 Token";
  if (S.relay.status === "ok") {
    return "中转服务可用 · " + S.relay.addr + (typeof S.relay.rttMs === "number" ? " · 约 " + S.relay.rttMs + "ms" : "");
  }
  return "中转服务器 · " + S.relay.addr + " — 尚未连通";
}

// ---------- 弹窗开合 ----------
function openPair() {
  ui.pairOpen = true; ui.pairErr = false;
  $("pairCode").value = "";
  $("pairAddr").value = "";
  render();
  setTimeout(() => $("pairCode").focus(), 0);
}
function closePair() { ui.pairOpen = false; ui.pairErr = false; render(); }
function openRelay() { ui.relayOpen = true; render(); }
function closeRelay() { ui.relayOpen = false; render(); }

// v1.11：码是 6 位字母+数字，大小写不敏感。归一化（大写 + 只留 [A-Z0-9]）交给
// 引擎统一做（两端必须逐字节一致），这里只做本地校验挡一下明显的错。
function normCode(s) { return String(s || "").toUpperCase().replace(/[^A-Z0-9]/g, ""); }
function submitPair() {
  const code = normCode($("pairCode").value);
  if (!/^[A-Z0-9]{6}$/.test(code)) { ui.pairErr = true; render(); return; }
  cmd("pair", { code, addr: ($("pairAddr").value || "").trim() });
  closePair(); // 结果由引擎的 nd-toast + 设备列表体现
}

function saveRelay(fromModal) {
  const addr = (fromModal ? $("mRelayAddr") : $("advRelayAddr")).value.trim();
  const token = (fromModal ? $("mRelayToken") : $("advRelayToken")).value;
  cmd("relay-save", { addr, token, forceRelay: !!S.relay.forceRelay });
  if (fromModal) closeRelay();
}

function toggleForceRelay(fromModal) {
  const addr = (fromModal ? $("mRelayAddr") : $("advRelayAddr")).value.trim();
  const token = (fromModal ? $("mRelayToken") : $("advRelayToken")).value;
  cmd("relay-save", { addr, token, forceRelay: !S.relay.forceRelay });
}

// ---------- 事件绑定（静态节点，只绑一次） ----------
$("themeBtn").addEventListener("click", () => cmd("theme", { v: S.theme === "dark" ? "light" : "dark" }));
// 无边框窗口的最小化只能由主进程做；关闭走 window.close()（main.js 里已有 close 拦截）
$("btnMin").addEventListener("click", () => ipcRenderer.send("nd-win", "minimize"));
$("btnClose").addEventListener("click", () => window.close());

$("tabCast").addEventListener("click", () => { ui.tab = "cast"; render(); });
$("tabRecv").addEventListener("click", () => { ui.tab = "recv"; render(); });

$("btnStartCast").addEventListener("click", () => {
  const why = castBlockReason();
  if (why) { toast(why); return; }
  cmd("start-cast");
});
$("btnStopCast").addEventListener("click", () => cmd("stop"));
$("btnEmptyAdd").addEventListener("click", openPair);

$("btnRecvSvc").addEventListener("click", () => {
  if (S.role === "switching") { toast("正在切换，请稍候"); return; }
  if (S.role === "casting") { toast("正在投射，接收服务不可用"); return; }
  if (S.role === "receiving") { cmd("drop-stream"); return; }
  cmd("recv-svc", { on: S.recvSvc !== "waiting" });
});

$("qualityHead").addEventListener("click", () => { ui.qualityOpen = !ui.qualityOpen; render(); });
$("advHead").addEventListener("click", () => { ui.advOpen = !ui.advOpen; render(); });

$("btnAddDevice").addEventListener("click", openPair);

$("btnEditLocal").addEventListener("click", () => {
  ui.localEditing = true;
  $("localNameInput").value = S.localName || "";
  render();
});
$("localNameInput").addEventListener("keydown", (e) => {
  if (e.key === "Enter") {
    const name = $("localNameInput").value.trim();
    ui.localEditing = false;
    if (name && name !== S.localName) cmd("local-name", { name });
    render();
  }
  if (e.key === "Escape") { ui.localEditing = false; render(); }
});
$("localNameInput").addEventListener("blur", () => { ui.localEditing = false; render(); });

// 高级设置没有保存按钮（设计稿如此）：失焦或回车即提交
for (const id of ["advRelayAddr", "advRelayToken"]) {
  $(id).addEventListener("change", () => saveRelay(false));
  $(id).addEventListener("keydown", (e) => { if (e.key === "Enter") $(id).blur(); });
}
$("advForce").addEventListener("click", () => toggleForceRelay(false));

$("btnPairClose").addEventListener("click", closePair);
$("pairModal").addEventListener("click", (e) => { if (e.target === $("pairModal")) closePair(); });
$("btnPairSubmit").addEventListener("click", submitPair);
$("pairCode").addEventListener("input", () => {
  const box = $("pairCode");
  // 边打边归一化成大写字母数字；保留一个空格分组显示（123 456 更好念）
  const n = normCode(box.value).slice(0, 6);
  box.value = n.length > 3 ? n.slice(0, 3) + " " + n.slice(3) : n;
  if (ui.pairErr) { ui.pairErr = false; render(); }
});
$("pairCode").addEventListener("keydown", (e) => { if (e.key === "Enter") submitPair(); });
$("pairAddr").addEventListener("keydown", (e) => { if (e.key === "Enter") submitPair(); });
$("btnGenCode").addEventListener("click", () => {
  // 生成用排除易混字符（I O L 0 1）的字母表，纯 UX；输入端不受限。
  const ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
  const buf = new Uint8Array(6);
  crypto.getRandomValues(buf);
  let s = "";
  for (let i = 0; i < 6; i++) s += ALPHABET[buf[i] % ALPHABET.length];
  $("pairCode").value = s.slice(0, 3) + " " + s.slice(3);
  ui.pairErr = false;
  render();
});

$("btnRelayClose").addEventListener("click", closeRelay);
$("relayModal").addEventListener("click", (e) => { if (e.target === $("relayModal")) closeRelay(); });
$("btnRelaySave").addEventListener("click", () => saveRelay(true));
$("mForce").addEventListener("click", () => toggleForceRelay(true));
for (const id of ["mRelayAddr", "mRelayToken"]) {
  $(id).addEventListener("keydown", (e) => { if (e.key === "Enter") saveRelay(true); });
}

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return;
  if (ui.pairOpen) closePair();
  else if (ui.relayOpen) closeRelay();
});

// ---------- 启动：先拿快照，再听增量 ----------
render();
ipcRenderer.invoke("nd-state-get")
  .then((s) => { if (s) applyState(s); })
  .catch((err) => { console.warn("[panel] nd-state-get 失败：", err); });
