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

module.exports = { startCapture, isKeyAU, forEachNal };
