# Windows 端（Receiver 已完成，Sender 待做）

Electron + Node `net` + WebCodecs 硬解。由 Windows 端 Claude 维护。协议见 `../docs/02-protocol.md`。

## 运行 / 打包

```bash
npm install
npm start          # 启动 Receiver
npm run dist       # 打包 portable .exe（输出 dist/，需网络下载 electron 二进制）
npm run probe      # 探测本机 WebCodecs 解码能力（HEVC/4:4:4/AV1）
```

## 功能概览

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
- `cli-client.js` — 无 UI 协议验证客户端：`node tools/cli-client.js --direct <ip> | --relay <码>`
- `probe-codecs.js` — WebCodecs 能力探测

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
--send-stats-after N [--send-stats-repeat]   N 秒后打印 SEND_STATS{json}（配 --enable-logging）
```

## 互调（Windows 发 → 对端收）

```bash
npx electron . --send --send-stats-after 10 --send-stats-repeat --enable-logging
```

监听 47800 等对端连入；每 10 秒打一行 `SEND_STATS`（sent/dropped/keyframes/bytes/avgFps/avgMbps）用于与接收端计数对账。
注意口径：Sender 的 `bytes` 只含 Annex-B 数据，Receiver 的 `bytes` 含每帧 9 字节 pts+flags 头。
