// 临时：用 puppeteer-core 连上已开的 NetDisplay(--remote-debugging-port=9222)，驱动面板做实机联调。
// 用法：node tools/drive-cdp.js <action> [arg]
//   state            读面板状态
//   pair <CODE>      打开配对弹窗(中转 tab)、填码、点配对（进入 announce 等待态）
//   recv-on          点「开启接收服务」
//   recv-off         再点一次（关闭/回待命）
//   unpair-first     解除列表里第一个设备
// 不参与打包，仅本次联调用。
const puppeteer = require("puppeteer-core");

async function getPanel(browser) {
  for (const p of await browser.pages()) {
    try { if (await p.evaluate(() => !!document.getElementById("pairModal"))) return p; } catch {}
  }
  return null;
}

async function readState(panel) {
  return panel.evaluate(() => {
    const txt = (id) => { const e = document.getElementById(id); return e ? (e.textContent || "").trim() : null; };
    const rows = Array.from(document.querySelectorAll("#devList > *")).map(r => r.textContent.replace(/\s+/g, " ").trim());
    const modalOpen = (() => { const m = document.getElementById("pairModal"); if (!m) return false; return !m.classList.contains("hidden") && getComputedStyle(m).display !== "none"; })();
    return {
      recvBtn: txt("recvBtnLabel"), recvTitle: txt("recvStatusTitle"),
      devices: rows, pairModalOpen: modalOpen,
      pairErr: txt("pairErr"), pairSubmit: txt("btnPairSubmit"),
      relay: txt("pairRelayText"),
    };
  });
}

(async () => {
  const action = process.argv[2] || "state";
  const arg = process.argv[3];
  const browser = await puppeteer.connect({ browserURL: "http://localhost:9222", defaultViewport: null });
  const panel = await getPanel(browser);
  if (!panel) { console.log("!! 无面板窗口"); await browser.disconnect(); return; }

  if (action === "pair") {
    await panel.evaluate(() => document.getElementById("btnAddDevice").click());
    await new Promise(r => setTimeout(r, 400));
    await panel.evaluate((code) => {
      // 确保在「中转（配对码）」tab
      const rt = document.getElementById("pairTabRelay"); if (rt) rt.click();
      const inp = document.getElementById("pairCode");
      inp.value = code; inp.dispatchEvent(new Event("input", { bubbles: true }));
      document.getElementById("btnPairSubmit").click();
    }, arg);
    await new Promise(r => setTimeout(r, 600));
  } else if (action === "recv-on" || action === "recv-off") {
    await panel.evaluate(() => document.getElementById("btnRecvSvc").click());
    await new Promise(r => setTimeout(r, 500));
  } else if (action === "unpair-first") {
    await panel.evaluate(() => {
      const row = document.querySelector("#devList > *");
      if (!row) return;
      const un = Array.from(row.querySelectorAll("*")).find(e => (e.textContent || "").trim() === "解除配对");
      un && un.click();
    });
    await new Promise(r => setTimeout(r, 300));
    await panel.evaluate(() => {
      const yes = Array.from(document.querySelectorAll("#devList *")).find(e => /确认|解除/.test(e.textContent) && e.tagName === "BUTTON");
      yes && yes.click();
    });
    await new Promise(r => setTimeout(r, 300));
  }

  console.log(JSON.stringify(await readState(panel), null, 2));
  await browser.disconnect();
})().catch(e => { console.error("ERR", e.message); process.exit(1); });
