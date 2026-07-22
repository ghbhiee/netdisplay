# NetDisplay 跨机联调助手（Windows 侧），对标 Mac 的 tools/standby-sender.sh + interop-test.sh
#
# 双房间模型（docs/coordinator-agent.md）：各方向的**发送端**常驻自己的房间，互不抢占。
#   secret-win-sends : Windows 发送端常驻 → Mac join，测 Win→Mac
#   secret-mac-sends : Mac  发送端常驻 → Windows join，测 Mac→Win
#
# 用法：
#   .\tools\interop.ps1 standby [-Window <标题子串>]   # 起 Windows 待命发送端（win-sends 房，常驻）
#   .\tools\interop.ps1 recv [-Seconds 30]             # join mac-sends 房接收，输出 RECV_STATS
#   .\tools\interop.ps1 stats                          # 打印待命发送端最近一次 SEND_STATS
#   .\tools\interop.ps1 stop                           # 停掉本机所有 electron 实例
#
# 凭据全部从 15 服务器现取，不落仓库。
param(
  [Parameter(Position = 0)][ValidateSet("standby", "recv", "stats", "stop")][string]$Mode = "standby",
  [int]$Seconds = 30,
  [string]$Window,
  [string]$LogDir = "$env:TEMP\netdisplay-interop"
)

$ErrorActionPreference = "Stop"
$AppDir = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Force $LogDir | Out-Null

# 直接用 electron 可执行文件：Start-Process 起不了 npx（那是 .cmd 不是 exe）
$ElectronExe = Join-Path $AppDir "node_modules\electron\dist\electron.exe"

function Get-Secret([string]$name) {
  (ssh root@15.tokencv.com "cat /root/cc/agent-chat/$name").Trim()
}
function Get-RelayToken {
  $line = ssh root@15.tokencv.com "grep -m1 'RELAY_TOKEN' /root/cc/agent-chat/INTEROP.md"
  if ($line -match '`([0-9a-f]{16,})`') { return $Matches[1] }
  throw "无法从 15 的 INTEROP.md 解析 RELAY_TOKEN"
}
# Electron 日志会折行，先拼行再提取完整 JSON
function Get-LastJson([string]$file, [string]$tag) {
  if (-not (Test-Path $file)) { return $null }
  $j = (Get-Content $file -Raw) -replace "`r`n", '' -replace "`n", ''
  $m = [regex]::Matches($j, "$tag (\{[^}]*\})")
  if ($m.Count -eq 0) { return $null }
  return $m[$m.Count - 1].Groups[1].Value
}

switch ($Mode) {
  "stop" {
    Get-Process -Name electron -ErrorAction SilentlyContinue | Stop-Process -Force
    "stopped"
  }

  "stats" {
    $log = "$LogDir\standby.log"
    $s = Get-LastJson $log "SEND_STATS"
    if ($s) { "SEND_STATS $s"; break }
    # 无会话时发送端会打 "SEND_STATS null"，据此区分「没起」和「起了但没人连」
    if ((Test-Path $log) -and (Select-String -Path $log -Pattern "SEND_STATS null" -Quiet)) {
      "发送端在待命，但还没有接收端连入（SEND_STATS null）—— 让对端 join 后再看"
    }
    elseif (Test-Path $log) { "发送端已起但还没到统计周期（30s 一次），稍等再看" }
    else { "发送端未启动，先跑 .\tools\interop.ps1 standby" }
  }

  "standby" {
    # Windows 作为发送方 → 常驻自己的 win-sends 房间
    $secret = Get-Secret "secret-win-sends"
    $token = Get-RelayToken
    # 注意：不能用 $args，那是 PowerShell 自动变量，赋值会报错
    $sendArgs = @("--headless", "--send-relay", "--secret", $secret, "--token", $token,
      "--send-stats-after", "30", "--send-stats-repeat",
      "--user-data", "$env:TEMP\nd-standby-send")
    if ($Window) { $sendArgs += @("--send-window", $Window) }
    $log = "$LogDir\standby.log"
    Remove-Item $log -ErrorAction SilentlyContinue
    Start-Process $ElectronExe -ArgumentList (@($AppDir) + $sendArgs) -WorkingDirectory $AppDir `
      -RedirectStandardOutput $log -RedirectStandardError "$LogDir\standby.err.log" -WindowStyle Hidden
    Start-Sleep 6
    $reg = Select-String -Path $log -Pattern "relay registered" -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($reg) { "SENDER-UP win $(if ($Window) { "window:$Window" } else { 'screen' })"; $reg.Line }
    else { "未看到注册日志，请查 $log"; Get-Content $log -Tail 5 -ErrorAction SilentlyContinue }
  }

  "recv" {
    # Windows 作为接收方 → join Mac 发送端常驻的 mac-sends 房间
    $secret = Get-Secret "secret-mac-sends"
    $token = Get-RelayToken
    $log = "$LogDir\recv.log"
    Remove-Item $log -ErrorAction SilentlyContinue
    & $ElectronExe $AppDir --headless --recv-relay --secret $secret --token $token `
      --recv-stats-after ([Math]::Max(5, $Seconds - 5)) --exit-after $Seconds `
      --user-data "$env:TEMP\nd-standby-recv" *>&1 | Tee-Object -FilePath $log | Out-Null
    $r = Get-LastJson $log "RECV_STATS"
    Select-String -Path $log -Pattern "HELLO_ACK|\[recv\]" -ErrorAction SilentlyContinue |
      Select-Object -Last 3 | ForEach-Object { $_.Line -replace '.*\[recv\]', '[recv]' }
    if ($r) { "RECV_STATS $r" } else { "未拿到 RECV_STATS —— 对端可能没有发送端在 mac-sends 房待命" }
  }
}
