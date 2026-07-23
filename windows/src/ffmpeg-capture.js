// WS-5a/b：HQ 采集编码管线 —— ffmpeg 子进程 + 硬件 HEVC 4:2:2。
//
// 整屏走 ddagrab（Desktop Duplication，GPU 抓取），单窗口走 gdigrab（GDI，按窗口标题）。
// 两者都经 hwdownload 到系统内存再喂 NVENC/QSV —— 实测 GPU 内直连管线不可行
// （ddagrab 输出 D3D11 帧，NVENC 拒收；hwmap 到 CUDA 也失败），但归因测试显示
// hwdownload + 编码的增量开销≈0，瓶颈在抓屏本身，所以这条路可行。
//
// 输出按 AUD(NAL 35) 切成 access unit，每个 AU 就是一帧，交给上层按协议 §4 发送。
"use strict";
const { spawn } = require("child_process");

const NAL_AUD = 35;
const IRAP_LOW = 16, IRAP_HIGH = 23; // IRAP（含 IDR/CRA/BLA）NAL 类型区间

// 扫描 Annex-B 起始码，回调每个 NAL 的类型与偏移
function forEachNal(buf, cb) {
  for (let i = 0; i + 3 < buf.length; i++) {
    let sc = 0;
    if (buf[i] === 0 && buf[i + 1] === 0 && buf[i + 2] === 1) sc = 3;
    else if (buf[i] === 0 && buf[i + 1] === 0 && buf[i + 2] === 0 && buf[i + 3] === 1) sc = 4;
    if (!sc) continue;
    const t = (buf[i + sc] >> 1) & 0x3f; // HEVC：NAL 类型在头字节的高 6 位
    if (cb(t, i, sc) === false) return;
    i += sc;
  }
}

// 从 HEVC SPS 里解出编码尺寸。HELLO_ACK 必须带真实 width/height（对端据此配解码器
// 和 canvas），而 ffmpeg 路径下这个尺寸只有流里才有——ddagrab/gdigrab 抓到多大取决于
// 屏幕/窗口，我们并不预先知道。
function parseSpsSize(au) {
  let sps = null;
  forEachNal(au, (t, i, sc) => {
    if (t === 33) { sps = au.subarray(i + sc + 2); return false; } // 跳过 2 字节 NAL 头
  });
  if (!sps) return null;
  try {
    // 去除防竞争字节（0x000003 → 0x0000）后再按位读，否则字段会错位
    const rbsp = [];
    for (let i = 0; i < sps.length; i++) {
      if (i >= 2 && sps[i] === 3 && sps[i - 1] === 0 && sps[i - 2] === 0) continue;
      rbsp.push(sps[i]);
    }
    let bitPos = 0;
    const u = (n) => { let v = 0; for (let k = 0; k < n; k++) { v = (v << 1) | ((rbsp[bitPos >> 3] >> (7 - (bitPos & 7))) & 1); bitPos++; } return v; };
    const ue = () => { let z = 0; while (u(1) === 0 && z < 32) z++; return z ? ((1 << z) - 1) + u(z) : 0; };

    u(4);                                  // sps_video_parameter_set_id
    const maxSubLayers = u(3);             // sps_max_sub_layers_minus1
    u(1);                                  // sps_temporal_id_nesting_flag
    // profile_tier_level
    u(8); u(32); u(4); bitPos += 44;       // general_profile/compat/flags
    u(8);                                  // general_level_idc
    const subPresent = [];
    for (let i = 0; i < maxSubLayers; i++) subPresent.push([u(1), u(1)]);
    if (maxSubLayers > 0) for (let i = maxSubLayers; i < 8; i++) u(2);
    for (const [p, l] of subPresent) {
      if (p) { u(8); u(32); u(4); bitPos += 44; }
      if (l) u(8);
    }
    ue();                                  // sps_seq_parameter_set_id
    const chroma = ue();                   // chroma_format_idc
    if (chroma === 3) u(1);                // separate_colour_plane_flag
    let w = ue(), h = ue();                // pic_width/height_in_luma_samples（CTU 对齐后的编码尺寸）

    // conformance window：编码尺寸按 CTU 向上取整，真实显示尺寸要减掉裁剪量。
    // 实测 1280x720 的流里 pic_height=736，不减这段会把 736 报给对端。
    if (u(1)) {                            // conformance_window_flag
      const subW = chroma === 1 || chroma === 2 ? 2 : 1; // 4:2:0/4:2:2 水平 2 倍
      const subH = chroma === 1 ? 2 : 1;                 // 仅 4:2:0 垂直 2 倍
      const left = ue(), right = ue(), top = ue(), bottom = ue();
      w -= subW * (left + right);
      h -= subH * (top + bottom);
    }
    return w > 0 && h > 0 ? { width: w, height: h } : null;
  } catch { return null; }
}

const isKeyAU = (au) => {
  let key = false;
  forEachNal(au, (t) => {
    if (t >= IRAP_LOW && t <= IRAP_HIGH) { key = true; return false; }
  });
  return key;
};

/**
 * @param {object} o
 *   o.ffmpeg/o.encoder/o.pixFmt  来自 probeHQ
 *   o.source  {kind:"desktop"} | {kind:"window", name:"窗口标题"}
 *   o.fps/o.bitrateMbps/o.gopSeconds
 *   o.onFrame(au:Buffer, isKey:boolean, ptsUs:number)
 *   o.onError(msg)   致命错误（上层据此回退基线或结束会话）
 *   o.onLog(msg)
 */
function startCapture(o) {
  const fps = Math.min(60, Math.max(5, o.fps || 30));
  const gop = Math.max(1, o.gopSeconds || 2) * fps;
  const log = o.onLog || (() => {});

  const input = o.source && o.source.kind === "window"
    // gdigrab 按标题抓单窗口（边界⑦放开后新增的路径）
    ? ["-f", "gdigrab", "-framerate", String(fps), "-i", `title=${o.source.name}`]
    : ["-f", "lavfi", "-i", `ddagrab=output_idx=0:framerate=${fps}`];

  // ddagrab 产的是 D3D11 帧，必须 hwdownload；gdigrab 已经是系统内存帧，不能加
  const vf = o.source && o.source.kind === "window" ? [] : ["-vf", "hwdownload,format=bgra"];

  const args = [
    "-hide_banner", "-loglevel", "warning",
    ...input, ...vf,
    "-c:v", o.encoder,
    "-pix_fmt", o.pixFmt,
    "-preset", "p1", "-tune", "ull",
    "-g", String(gop),
    "-b:v", `${Math.max(1, o.bitrateMbps || 20)}M`,
    // 每个 AU 以 AUD 开头，这是上层切帧的依据（边界③）
    "-bsf:v", "hevc_metadata=aud=insert",
    "-f", "hevc", "pipe:1",
  ];

  log(`[hq] ffmpeg ${args.join(" ")}`);
  const proc = spawn(o.ffmpeg, args, { windowsHide: true });

  let acc = Buffer.alloc(0);
  let frameNo = 0;
  let stopped = false;
  let sawFrame = false;

  // 按 AUD 切 AU：缓冲里找相邻两个 AUD，中间就是一个完整 AU
  const audOffsets = (buf) => {
    const offs = [];
    forEachNal(buf, (t, i) => { if (t === NAL_AUD) offs.push(i); });
    return offs;
  };

  proc.stdout.on("data", (chunk) => {
    if (stopped) return;
    acc = acc.length ? Buffer.concat([acc, chunk]) : chunk;
    const offs = audOffsets(acc);
    if (offs.length < 2) return; // 至少要有下一个 AUD 才能确定当前 AU 结束
    for (let k = 0; k + 1 < offs.length; k++) {
      const au = acc.subarray(offs[k], offs[k + 1]);
      if (au.length === 0) continue;
      sawFrame = true;
      o.onFrame(au, isKeyAU(au), Math.round((frameNo++ * 1e6) / fps));
    }
    acc = acc.subarray(offs[offs.length - 1]); // 保留最后一个未完成的 AU
  });

  // stderr 全程留存：ffmpeg 的失败原因只在这里（边界⑥）
  let stderrTail = "";
  proc.stderr.on("data", (d) => {
    const s = d.toString();
    stderrTail = (stderrTail + s).slice(-4000);
    // warning 级别以上才回报，避免刷屏
    for (const line of s.split(/\r?\n/)) {
      if (/error|failed|invalid|cannot|unable/i.test(line)) log("[hq/ffmpeg] " + line.trim());
    }
  });

  proc.on("error", (e) => {
    if (!stopped) o.onError(`ffmpeg 启动失败: ${e.message}`);
  });

  proc.on("close", (code) => {
    if (stopped) return;
    // 非主动停止的退出一律视为异常，把 stderr 尾部带出去便于定位
    const why = sawFrame
      ? `ffmpeg 退出（code=${code}），已产出过帧`
      : `ffmpeg 未产出任何帧就退出（code=${code}）`;
    o.onError(`${why}\n${stderrTail.trim().split("\n").slice(-3).join("\n")}`);
  });

  return {
    get pid() { return proc.pid; },
    /** 周期 GOP 模式下无法中途强制 IDR，只能等下一个（边界④，已与 Mac 确认接受） */
    requestKeyframe() {
      log(`[hq] 收到 REQUEST_KEYFRAME —— 周期 GOP 模式下等待下一个 IDR（最长 ${o.gopSeconds || 2}s）`);
    },
    stop() {
      if (stopped) return;
      stopped = true;
      try { proc.stdin.end(); } catch {}
      try { proc.kill(); } catch {}
      // Windows 上 ffmpeg 可能有子进程，确保整棵树都清掉，否则会占着采集设备
      setTimeout(() => {
        try { if (proc.exitCode === null) spawn("taskkill", ["/pid", String(proc.pid), "/f", "/t"], { windowsHide: true }); } catch {}
      }, 800);
    },
  };
}

module.exports = { startCapture, isKeyAU, forEachNal, parseSpsSize };
