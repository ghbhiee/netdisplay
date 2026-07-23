# Windows 端（收发对称，v0.3.0）

Electron + Node `net` + WebCodecs（硬解 / 软编）+ ffmpeg/NVENC（HQ 4:2:2）。由 Windows 端 Claude 维护。协议见 `../docs/02-protocol.md`。

> **换新 session 先读 [`tools/AGENT-WORKFLOW.md`](tools/AGENT-WORKFLOW.md)** —— Monitor（事件唤醒）与 Loop（定时唤醒）
> 怎么用、怎么配合、踩过哪些坑。这套机制决定协作节奏和 token 成本，但换会话就会忘。

**发布产物**：`npm run dist` → `dist/NetDisplay-0.3.0-portable.exe`（免安装，双击即用；未签名，首次运行 SmartScreen 选「仍要运行」）。

> 改 `package.json` 版本号时**不要用 `Set-Content -Encoding utf8`** —— PowerShell 5.1 那个开关会写入 BOM，electron-builder 读 JSON 会报
> `readObjectStart: expect { or n, but found ﻿`。用 `[System.IO.File]::WriteAllText($p,$c,[System.Text.UTF8Encoding]::new($false))`。
> （注意与 `.ps1` 相反：含中文的 PowerShell 脚本**必须**有 BOM，否则按 GBK 读会解析失败。）

## 直连模式（局域网 / USB4，绕过中转）

发送端监听 `0.0.0.0:47800`（实际是 `::` 双栈，IPv4 可入），接收端直接连它的 IP，不经 relay，延迟从中转的 300–600ms 降到个位数毫秒。

```powershell
# 发送端（本机 IP 例：192.168.50.40）
npx electron . --headless --send --send-stats-after 15 --send-stats-repeat
# 接收端（另一台机器）
… --recv --host 192.168.50.40 --port 47800
```

**连不上时按顺序查**：
1. `Get-NetTCPConnection -LocalPort 47800 -State Listen` —— 应显示 `::` 在监听
2. `Get-NetConnectionProfile` —— 记下网络是 Private 还是 Public
3. `Get-NetFirewallApplicationFilter | ? Program -like "*electron*"` —— 对应的入站允许规则**必须覆盖上一步那个 profile**，否则外部连接会被静默丢弃（本机自连测不出来，同机走 loopback 不过防火墙）
4. 打包版和开发版是**不同的程序路径**（`NetDisplay.exe` 在临时解压目录、开发版是 `node_modules\electron\dist\electron.exe`），各自需要自己的放行规则

## 运行 / 打包

```bash
npm install
npm start          # 启动 Receiver
npm run dist       # 打包 portable .exe（输出 dist/，需网络下载 electron 二进制）
npm run probe      # 探测本机 WebCodecs 解码能力（HEVC/4:4:4/AV1）
```

## 功能概览

- **收发对称**：既可作 Receiver 接收，也可作 Sender 发送（整屏或单窗口，直连/中转皆可，窗口 resize 自动跟随）
- 直连（USB4 网桥 / 局域网，Sender:47800）与服务器中转（配对码 / v1.4 持久配对免码）两种模式
- v1.5：中转服务器地址与访问 token 均在设置界面配置（不硬编码）
- 分辨率/HiDPI 缩放/帧率/码率可配，全屏与窗口模式均保证「1 视频像素 = 1 物理像素」（高 DPI 防糊）
- v1.4 投射解耦：空闲待命不关窗、投射自动前台、悬浮工具栏「弹回 Mac / 停止投射」
- 托盘常驻、关窗不断连、断线自动重连（持久配对时）
- v1.3 codec 协商：按本机能力上报 `codecs`（如 `["hevc444","hevc","h264"]`）

快捷键：长按 Esc 断开 · F1 统计浮层 · F2 设置。

## 联调工具（tools/）

- `mock-sender.js` — 模拟 Mac Sender（ffmpeg testsrc2 实时 H.264）：
  `node tools/mock-sender.js [--port 47800] [--v14] [--reconfig N] [--relay [--use-pairhash] [--token T]]`
- `cli-client.js` — 无 UI 协议验证客户端：`node tools/cli-client.js --direct <ip> | --relay <码> [--codecs hevc,h264]`
- `probe-codecs.js` — WebCodecs **解码**能力探测（isConfigSupported）
- `probe-hevc.js` — HEVC **真流**解码验证（需先用 x265 生成测试流，见文件头）
- `probe-encoder.js` — WebCodecs **编码**能力探测（真编 10 帧，验证 Annex-B 与参数集）

### 本机编码能力实测结论（详见 `../docs/91-windows-progress.md`）

| | H.264 | HEVC | HEVC 4:2:2 10bit |
|---|---|---|---|
| WebCodecs（当前实现） | ✅ 仅软编 | ❌ | ❌ |
| 硬件 / ffmpeg（NVENC·QSV） | ✅ | ✅ | ✅ 真 4:2:2，2560×1600@60 可达 235fps |

即：想上 HEVC 或 4:2:2，必须绕开 WebCodecs 走 ffmpeg/原生（Phase 2，待 review）。

## 自动化测试参数（Electron 启动参数）

```
--connect <ip> [--port N]     直连并自动开始
--relay <码> [--server h:p]   中转自动开始（码填非 6 位数字时走 pairHash 免码）
--token <T>                   relay 访问令牌
--res 1920x1200 --scale 2 --windowed 1
--auto-bounce N               N 秒后自动发弹回
--test-pair-secret <base64>   预置持久配对密钥
--exit-after N                N 秒后 stdout 输出 TEST_RESULT{json} 并退出
--user-data <dir>             独立 userData（多实例并跑必须，否则 localStorage 抢锁）

--send                        启动即开直连发送端（监听 :47800）
--send-relay [--send-relay-code C]  启动即开中转发送（可固定首次配对码）
--send-window <标题子串>      投射匹配的窗口而非整屏（WS-3）
--headless                    无窗口无托盘，日志直接走 stdout（CLI 待命模式）
--secret <base64>             共享固定配对密钥，零配对码待命（联调用）
--pairhash <hex>              直接指定 relay 房间 hash（不下发 secret）
--send-stats-after N [--send-stats-repeat]   N 秒后打印 SEND_STATS{json}（配 --enable-logging）
```

## 互调（Windows 发 → 对端收）

```bash
npx electron . --send --send-stats-after 10 --send-stats-repeat --enable-logging
```

监听 47800 等对端连入；每 10 秒打一行 `SEND_STATS`（sent/dropped/keyframes/bytes/avgFps/avgMbps）用于与接收端计数对账。

**跨机联调（推荐用脚本，凭据自动从 15 取）**：

```powershell
.\tools\interop.ps1 standby                 # 起待命发送端（常驻 secret-win-sends 房，等 Mac join）
.\tools\interop.ps1 standby -Window Notepad # 同上，但只投指定窗口
.\tools\interop.ps1 recv -Seconds 30        # join secret-mac-sends 房接收，输出 RECV_STATS
.\tools\interop.ps1 stats                   # 打印待命发送端最近一次 SEND_STATS
.\tools\interop.ps1 stop                    # 停掉本机所有 electron 实例
```

双房间模型（见 `../docs/coordinator-agent.md`）：各方向的**发送端**常驻自己的房间，两方向可同时待命、互不抢占。

**底层命令（脚本背后就是这个）**：

```bash
npx electron . --headless --send-relay --secret <SHARED_SECRET> --token <RELAY_TOKEN> --send-stats-after 30 --send-stats-repeat
```

发送端按 `sha256(base64decode(secret))` 在 relay 上常驻待命，对端用同一密钥随时接入，无需配对码、断线自动重注册。
注意口径：Sender 的 `bytes` 只含 Annex-B 数据，Receiver 的 `bytes` 含每帧 9 字节 pts+flags 头。
