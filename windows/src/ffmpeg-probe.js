// WS-5a：HQ 路径（ffmpeg + 硬件编码器）的运行时探测。
//
// 设计原则（Mac 定的边界①）：HQ 是可选增强，探测失败必须优雅回退 WebCodecs 基线，
// 且 HELLO_ACK.codec 只能反映**实际生效的路径**——不能因为「装了 ffmpeg」就声称 hevc422。
// 所以这里不只查编码器是否列出，还真编一小段并用 ffprobe 验证**输出确实是 4:2:2**
// （Mac 端的教训：VideoToolbox 接受 Main42210 profile 却把输出降成 4:2:0）。
"use strict";
const { spawn, execFile } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

let cached = null; // 探测结果缓存（进程内一次）

function run(cmd, args, timeoutMs = 20000) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: timeoutMs, windowsHide: true, maxBuffer: 8 * 1024 * 1024 },
      (err, stdout, stderr) => resolve({ err, stdout: stdout || "", stderr: stderr || "" }));
  });
}

const isUsable = async (c) => {
  const r = await run(c, ["-version"], 8000);
  return !r.err && /version/i.test(r.stdout + r.stderr);
};

// 用户在设置里显式指定了路径就**只用那个**：无效时报错而不是偷偷换成 PATH 里的另一个。
// 指定通常是有原因的（某个自带 NVENC 的构建），静默替换会让人对着一个自己没选的
// ffmpeg 排查问题。同 requireWindow 的原则。
async function findBinary(name, explicit) {
  if (explicit) return (await isUsable(explicit)) ? explicit : null;
  return (await isUsable(name)) ? name : null; // PATH
}

// 真编 30 帧并验证输出色度，避免「声称支持但实际降级」
async function verifyEncoder(ffmpeg, ffprobe, encoder, pixFmt) {
  const out = path.join(os.tmpdir(), `nd-probe-${encoder}-${Date.now()}.h265`);
  const r = await run(ffmpeg, [
    "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
    "-frames:v", "30",
    "-c:v", encoder, "-pix_fmt", pixFmt, "-preset", "p1",
    "-bsf:v", "hevc_metadata=aud=insert",
    "-f", "hevc", out,
  ], 30000);

  let verdict = { ok: false, reason: "" };
  try {
    if (r.err || !fs.existsSync(out) || fs.statSync(out).size < 1000) {
      verdict.reason = "编码失败: " + ((r.stderr || "").trim().split("\n").pop() || "no output");
    } else if (ffprobe) {
      const p = await run(ffprobe, [
        "-hide_banner", "-loglevel", "error",
        "-show_entries", "stream=profile,pix_fmt", "-of", "csv=p=0", out,
      ], 10000);
      const got = (p.stdout || "").trim();
      // 关键：输出的 pix_fmt 必须真是请求的那个，不能被悄悄降级
      if (got.includes(pixFmt)) verdict = { ok: true, reason: got };
      else verdict.reason = `色度被降级: 请求 ${pixFmt}，实得「${got}」`;
    } else {
      verdict = { ok: true, reason: "已编码（无 ffprobe，未校验色度）" };
    }
  } finally {
    try { fs.unlinkSync(out); } catch {}
  }
  return verdict;
}

/**
 * 探测 HQ 路径可用性。
 * @param {string} explicitFfmpeg 用户在设置里指定的 ffmpeg 路径（可空）
 * @returns {{available:boolean, ffmpeg:string|null, ffprobe:string|null,
 *            encoder:string|null, codec:string|null, detail:string}}
 */
async function probeHQ(explicitFfmpeg, log = () => {}) {
  if (cached) return cached;

  const ffmpeg = await findBinary("ffmpeg", explicitFfmpeg);
  if (!ffmpeg) {
    cached = { available: false, ffmpeg: null, ffprobe: null, encoder: null, codec: null,
      detail: explicitFfmpeg
        ? `设置里指定的 ffmpeg 不可用：${explicitFfmpeg}（不会自动改用 PATH 里的其它 ffmpeg）——HQ 模式不可用，将使用 WebCodecs 基线`
        : "未找到 ffmpeg（PATH 里没有，也未在设置中指定）——HQ 模式不可用，将使用 WebCodecs 基线" };
    log("[hq] " + cached.detail);
    return cached;
  }
  const ffprobe = await findBinary("ffprobe", explicitFfmpeg ? explicitFfmpeg.replace(/ffmpeg(\.exe)?$/i, "ffprobe$1") : null);

  // 先看编码器是否被编译进来，再逐个真编验证
  const list = await run(ffmpeg, ["-hide_banner", "-encoders"], 15000);
  const listed = (n) => new RegExp(`\\b${n}\\b`).test(list.stdout + list.stderr);

  const tries = [];
  if (listed("hevc_nvenc")) tries.push({ encoder: "hevc_nvenc", pixFmt: "yuv422p10le", codec: "hevc422" });
  if (listed("hevc_qsv")) tries.push({ encoder: "hevc_qsv", pixFmt: "y210le", codec: "hevc422" });

  const attempts = [];
  for (const t of tries) {
    const v = await verifyEncoder(ffmpeg, ffprobe, t.encoder, t.pixFmt);
    attempts.push(`${t.encoder}: ${v.ok ? "OK" : "不可用"}（${v.reason}）`);
    log(`[hq] 验证 ${t.encoder} → ${v.ok ? "通过" : "失败"}: ${v.reason}`);
    if (v.ok) {
      cached = { available: true, ffmpeg, ffprobe, encoder: t.encoder, pixFmt: t.pixFmt,
        codec: t.codec, detail: `${t.encoder} 真 4:2:2 已验证（${v.reason}）` };
      return cached;
    }
  }

  cached = { available: false, ffmpeg, ffprobe, encoder: null, codec: null,
    detail: tries.length
      ? "找到 ffmpeg 但没有可用的 4:2:2 硬件编码器：" + attempts.join("；")
      : "ffmpeg 不含 hevc_nvenc / hevc_qsv —— HQ 模式不可用，将使用 WebCodecs 基线" };
  log("[hq] " + cached.detail);
  return cached;
}

const resetProbeCache = () => { cached = null; };

module.exports = { probeHQ, resetProbeCache };
