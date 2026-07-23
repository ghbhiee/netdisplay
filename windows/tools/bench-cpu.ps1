# HQ(NVENC 硬编) vs 基线(WebCodecs 软编) 的 CPU 对比 —— Phase 2「降 CPU」的实证。
#
# 方法：同一发送端、同一投射源、同一分辨率，只让对端上报的 codecs 不同来切换路径；
# 统计窗口内所有相关进程（electron 全部子进程 + ffmpeg）的 CPU 时间增量。
# 只测 electron 主进程会漏掉 GPU/渲染进程和 ffmpeg 子进程，得到的数字没有意义。
param([int]$Seconds = 20)
$ErrorActionPreference = "Stop"
$AppDir = Split-Path -Parent $PSScriptRoot
$Electron = Join-Path $AppDir "node_modules\electron\dist\electron.exe"

function Total-CpuSeconds {
  $names = @("electron", "ffmpeg")
  $t = 0.0
  foreach ($n in $names) {
    foreach ($p in (Get-Process -Name $n -ErrorAction SilentlyContinue)) {
      try { $t += $p.CPU } catch {}   # .CPU = 累计 CPU 秒（所有核合计）
    }
  }
  return $t
}

function Run-Case([string]$label, [string]$codecs) {
  Get-Process -Name electron, ffmpeg -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep 2
  $ud = "$env:TEMP\nd-bench-$([guid]::NewGuid().ToString('N').Substring(0,6))"
  # 必须开 SEND_STATS：只比原始 CPU 是不公平的——两条路径帧率可能差好几倍，
  # 真正可比的是「每帧 CPU」。没有帧数就得不出结论。
  Start-Process $Electron -ArgumentList @($AppDir, "--headless", "--send",
    "--send-stats-after", "5", "--send-stats-repeat", "--user-data", $ud) `
    -RedirectStandardOutput "$env:TEMP\bench-$label.log" -WindowStyle Hidden
  Start-Sleep 12   # 等 HQ 探测（要真编 30 帧验色度）+ 监听就绪

  # 用 cli-client 建立会话；它的 --codecs 决定协商到哪条路径
  $job = Start-Job -ScriptBlock {
    param($dir, $codecs, $secs)
    Set-Location $dir
    node tools/cli-client.js --direct 127.0.0.1 --seconds $secs --codecs $codecs 2>&1
  } -ArgumentList $AppDir, $codecs, ($Seconds + 6)

  Start-Sleep 6            # 等握手与首帧稳定，避开启动尖峰
  $t0 = Total-CpuSeconds
  $w0 = Get-Date
  Start-Sleep $Seconds
  $t1 = Total-CpuSeconds
  $elapsed = ((Get-Date) - $w0).TotalSeconds

  # 取窗口结束时的帧数（用最后一条 SEND_STATS），换算窗口内实际编了多少帧
  $sentEnd = 0; $fpsEnd = 0
  $raw = (Get-Content "$env:TEMP\bench-$label.log" -Raw -ErrorAction SilentlyContinue) -replace "`r`n", '' -replace "`n", ''
  $ms = [regex]::Matches($raw, 'SEND_STATS (\{[^}]*\})')
  if ($ms.Count) { $j = $ms[$ms.Count - 1].Groups[1].Value | ConvertFrom-Json; $sentEnd = $j.sent; $fpsEnd = $j.avgFps }

  $out = Receive-Job $job -Wait -AutoRemoveJob
  $ack = ($out | Select-String "HELLO_ACK").Line
  $cpuSec = [math]::Round($t1 - $t0, 2)
  $cores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
  # CPU% 以「单核满载=100%」计；除以核数得到整机占用率
  $pct = [math]::Round(100 * $cpuSec / $elapsed, 1)
  $pctMachine = [math]::Round($pct / $cores, 1)

  Get-Process -Name electron, ffmpeg -ErrorAction SilentlyContinue | Stop-Process -Force
  $framesInWindow = [math]::Round($fpsEnd * $elapsed)
  [pscustomobject]@{
    路径 = $label; 协商 = if ($ack -match '"codec":"(\w+)"') { $Matches[1] } else { "?" }
    CPU秒 = $cpuSec; 单核pct = "$pct%"; 整机pct = "$pctMachine%"
    平均fps = $fpsEnd; 窗口内帧数 = $framesInWindow
    每帧CPU毫秒 = if ($framesInWindow -gt 0) { [math]::Round(1000 * $cpuSec / $framesInWindow, 2) } else { $null }
  }
}

"逻辑核数: $((Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors)，统计窗口 ${Seconds}s"
$r1 = Run-Case "基线(WebCodecs软编)" "h264"
$r2 = Run-Case "HQ(ffmpeg+NVENC)" "hevc422,h264"
@($r1, $r2) | Format-Table -AutoSize
"— 原始 CPU 只在帧率相同时可比；帧率不同时看『每帧CPU毫秒』 —"
if ($r1.每帧CPU毫秒 -and $r2.每帧CPU毫秒) {
  $d = [math]::Round(100 * (1 - $r2.每帧CPU毫秒 / $r1.每帧CPU毫秒), 1)
  "每帧 CPU 变化: $(if($d -ge 0){"降低 $d%"}else{"升高 $([math]::Abs($d))%"})  （基线 $($r1.每帧CPU毫秒)ms/帧 → HQ $($r2.每帧CPU毫秒)ms/帧）"
}
