---
date: 2026-07-22
tags: [netdisplay, handoff, windows, progress]
---

# Windows 端进展（Receiver + Relay）

> 维护者：Windows 端 Claude。与 `90-mac-progress.md` + `02-protocol.md` 三方异步协作。

## 当前状态：**93 号（v1.4 投射解耦）全部完成 ✅；92 号全部完成 ✅ —— 待真实 Mac 联调**

### 2026-07-22 更新之三（执行 93-windows-tasks.md，v1.4）

**对 93「需要确认/反馈」的回答：**
1. **v1.4 协议（§10）无异议**，Receiver 已全部实装。`pairHash` 算法两端对齐：**`hex(SHA256(pairSecret 的原始 32 字节))`，小写 hex**——注意是先 base64 解码回 32 字节再哈希，不是对 base64 字符串哈希。
2. **relay 已小改并重新部署上线**（详见 05 顶部更新说明）：原实现只认 6 位 code，现在 REGISTER/JOIN 接受 `pairHash`（64 位小写 hex）作为房间键，且 pairHash 房间**不过期**（Sender 无限期待命）、**同 hash 重复 REGISTER 替换旧连接**（解决断线残留导致的 code_taken，自愈）。已实测：pairHash 撮合 ✅、替换注册（旧连接被踢）✅、6 位 code 流程回归 ✅。

**Receiver v1.4 实现（93 P0 1–4 全做完）：**
- **PROJECTION_STATE(0x13)** ✅：`active:false` → 不关窗，画面压暗 + 「等待投射…」占位，连接保持（PING/PONG 心跳继续）；`active:true` → 恢复显示，`label` 显示在画面左上角。老 Sender 不发 0x13 → 默认视为一直投射（兼容）。收到 VIDEO_FRAME 也会自动转 active（93 §4「收到帧」条款）。
- **弹回/停止按钮** ✅：画面顶部悬浮工具栏（动鼠标浮现、2.5s 淡出）：「⏏ 弹回 Mac」发 `CONTROL{"action":"bounceBack"}`、「■ 停止投射」发 `{"action":"stop"}`、「⚙ 设置」。
- **持久配对** ✅：HELLO_ACK 的 `pairSecret` 存 localStorage；之后中转连接若未输码则自动带 `pairHash` JOIN 免码撮合；设置面板显示「已持久配对 ✓ 免输码 / 清除配对」。首次仍输码。
- **后台常驻 + 自动显示** ✅：托盘图标（菜单：显示/退出），关窗 = 隐藏到托盘、连接不断（已关 backgroundThrottling，隐藏时心跳/解码不节流）；**投射 active 时自动把窗口带回前台**；单实例锁。启动时若已持久配对 + 中转模式 → **自动连接待命**；断线自动重连（1s 起指数退避封顶 30s；用户手动断开不重连）。
- **切换投射源**：沿用 VIDEO_CONFIG 路径（92 轮已加固），实测同一连接内 2560×1600 → 空闲 → 1280×720 恢复，全程零解码错误。

**自动化验证结果**（mock 已升级支持 `--v14`（投射时间线 + pairSecret 下发 + CONTROL 响应）和 `--use-pairhash`）：
| 场景 | 结果 |
|---|---|
| 直连 v1.4 时间线：投射 A →4s 空闲→ 7s 切源 B(变尺寸) | projEvents=3、canvas 跟随 1280×720、495 帧 0 丢 0 错、pairSecret 已存 |
| auto-bounce：2s 后发 bounceBack | mock 收到 CONTROL 转空闲，Receiver 留窗待命（projActive:false，连接不断） |
| **持久配对过真实 relay**：mock 以 pairHash 注册 15 服务器，Receiver 无码 JOIN | 撮合成功、v1.4 时间线完整跟随、0 解码错误（中转 RTT≈288ms，背压丢帧策略正常工作） |

**portable exe 已重打包**（含 v1.4 + 托盘资源修复），仍是 `dist/NetDisplay-0.1.0-portable.exe`。

**给 Mac 端的联调提醒**：① pairHash 是对 base64 解码后的 32 字节做 SHA256（见上）；② pairHash 房间撮合一次即销毁，**会话结束后 Sender 要重新 REGISTER** 才能接受下次连接（relay 侧待命重连自愈已处理）；③ Receiver 在空闲态仍会每 3s 发 PING，请保持回 PONG，否则 10s 判死触发重连。

### 2026-07-22 更新之二（执行 92-windows-tasks.md）

说明：92 下达时，P0-1（设备像素 1:1 去糊）和 P0-2（窗口模式+选分辨率）已在「更新之一」完成（见下节），本轮完成其余项：

**P1-4 打包** ✅：`npm run dist` 出 **`dist/NetDisplay-0.1.0-portable.exe`（71 MB，免安装双击即用）**，已冒烟验证。未签名（双击可能有 SmartScreen 提示，「仍要运行」即可）。

**P1-5 设置界面重做** ✅：连接模式（直连/中转分组切换）、直连 IP、配对码、relay 地址、分辨率（预设 + **自定义宽高输入** + 自动）、缩放 1x/2x、帧率 30/60、码率 Mbps、窗口/全屏、统计浮层开关——全部持久化（localStorage）。

**P1-6 运行中改配置** ✅：串流中按 **F2** 呼出设置面板（半透明覆盖在画面上），改完点「**应用并重连**」→ 静默断开 → 带新 `screen` 重发 HELLO 重连（Mac 会重建虚拟屏）。快捷键：长按 Esc 断开 / F1 统计 / F2 设置。

**协议 v1.2**（已记入 02 changelog）：HELLO.screen 新增可选 `bitrateMbps`（用户设的码率随 HELLO 发给 Mac，**请 Mac 端采纳此字段**，`--bitrate` 可覆盖）。实测 HELLO 已带 `"bitrateMbps":40`。

**VIDEO_CONFIG 中途变分辨率路径加固** ✅（回应 92「单窗口投射对接」）：之前只重置解码器不改尺寸，已修——现在按 VIDEO_CONFIG 的新 width/height 更新 display/canvas/布局 + 重置解码器 + 主动发 REQUEST_KEYFRAME。mock 加了 `--reconfig N`（N 秒后 2560×1600→1280×720 换流），实测两次：切换前后全帧解码、0 解码错误、canvas/CSS 正确跟随。**单窗口投射的 resize 路径可以放心用。**

**顺带修复**：自动分辨率取物理像素时 `size×scaleFactor` 会出奇数（1707.33×1.5→2561），已在 Receiver 侧 `&~1` 取偶（之前靠 Mac 端兜底）。

### P0-3 HEVC / 4:4:4 探测结论（本机 Legion Y7000P IAX10，Arrow Lake iGPU，Electron 33 / Chromium 130）

`VideoDecoder.isConfigSupported` 实测（`npm run probe` 可复跑）：

| 编码 | prefer-hardware | prefer-software |
|---|---|---|
| H.264 High 4:2:0（现用） | ✅ | ✅ |
| H.264 High 4:4:4 | ❌ | ✅（CPU，不推荐） |
| HEVC Main 4:2:0 `hev1.1.6.L153.B0` | ✅ | ❌ |
| HEVC Main10 | ✅ | ❌ |
| **HEVC Rext Main 4:4:4 `hev1.4.10.L153.B0`** | **✅ 硬解** | ❌ |
| AV1 Main 4:2:0 | ✅ | ✅ |
| AV1 High 4:4:4 | ❌ | ✅ |

**结论：走 HEVC Rext 4:4:4，Windows 端有硬解，这是文字锐利的正解。** 注意：以上是 isConfigSupported 声明，真流验证要等 Mac 端能发 HEVC 流；HEVC 无软解兜底（依赖 GPU/系统 HEVC 支持），所以协商必须保留 h264 回退。

**协议已升 v1.3**（详见 02 changelog）：Receiver HELLO 新增可选顶层 `codecs` 数组（本机实际发 `["hevc444","hevc","h264"]`，探测后动态生成）；**请 Mac 端实装**：从 codecs 挑选（建议优先 hevc444，VideoToolbox 试 `kCMVideoCodecType_HEVC` + 4:4:4 profile；不行则 hevc；再不行 h264），在 HELLO_ACK.codec 返回选择。VIDEO_FRAME 仍是 Annex-B（HEVC 关键帧请内联 **VPS**/SPS/PPS）。Receiver 端协商逻辑已实装并回归（老 Sender 不回/回 h264 → 行为不变，已测）。

### 2026-07-22 更新（回应 90 号文档「请 Windows 端补的两件事」）

两件都已实现并用 mock（已对齐 Mac 的 v1.1 行为）自动化验证：

1. **✅ 用户可选分辨率/缩放**：连接面板新增「分辨率」（自动=本机物理像素 + 常用预设）和「缩放」（1x / 2x HiDPI）下拉，选择持久化（localStorage），填入 HELLO 的 `screen`。HELLO_ACK 的 `display.scale` 已读取并显示在统计浮层（如 `1920x1200@2x`）。
2. **✅ 窗口模式 + 防糊**：新增「窗口模式」勾选。防糊实现：**canvas 设备像素严格 = HELLO_ACK.display 的 width×height**，CSS 尺寸 = `width/devicePixelRatio`（放不下才等比缩小），窗口模式还会把窗口内容区精确设为该 CSS 尺寸。
   - 实测（本机 Windows **150% DPI**，dpr=1.5）：请求 1920×1200@2x 窗口模式 → canvas 1920×1200、CSS **精确 1280×800px** → 1:1 物理像素映射、零重采样；600 帧全解码 0 丢 0 错。
   - 全屏路径同一套布局逻辑（display 尺寸=屏幕物理尺寸时铺满即 1:1 最锐）。
3. 测试参数扩展：`npx electron . --connect <ip> --res 1920x1200 --scale 2 --windowed 1 --exit-after 10`，TEST_RESULT 现在带 `scale/cssSize/dpr` 字段。
4. mock-sender 已升级为 v1.1 行为（按 receiver 请求的 screen 建流、宽高取偶、fps 夹 30–60、ACK 回 scale），后续联调可继续当 Mac 替身用。

**给用户的推荐配置**（Windows 面板 2560×1600 + 150% 缩放）：分辨率「自动」+ **2x HiDPI** + 全屏 —— macOS 按 1280×800 逻辑点渲染（字大小正常），编码 2560×1600 物理像素，Windows 全屏 1:1 显示，最锐利。

## M3：Relay 已部署并验证

- **地址：`15.tokencv.com:47700`**，已在 systemd 常驻（`netdisplay-relay.service`，开机自启，crash 自动拉起）。
- 服务器 Debian 12，Go 1.19（apt 安装），源码在服务器 `/opt/apps/netdisplay-relay/main.go`，二进制 `/usr/local/bin/netdisplay-relay`。代码与 `05-relay-server.md` 完全一致。
- 已验证（从 Windows 公网测试）：
  - ✅ REGISTER + JOIN → 双方收到 `RELAY_PAIRED {"ok":true}` → 双向透明转发正确
  - ✅ 错误码：`code_not_found` 正常返回
  - ✅ 未配对连接 30.3s 被踢（unpairedTTL）
  - ✅ **真实视频流过 relay**：mock sender 经 relay 推 H.264 15 秒，454 帧零丢零错
- 运维：`ssh root@15.tokencv.com "systemctl status netdisplay-relay"` / `journalctl -u netdisplay-relay -f`
- ⚠️ **延迟事实**：Windows ↔ 15 服务器单程 RTT ≈ **150ms**（服务器在境外）。中转模式端到端延迟会明显可感，适合应急/演示，日常使用建议直连。若要改善需换国内/近节点服务器，协议不用动。

## M2：Receiver 已实现

- **代码：Windows 本机 `C:\Users\guoho\cc\netdisplay-receiver`**（Node 24 + Electron 33）。
- 启动：`cd netdisplay-receiver && npm install && npm start`
  - UI 提供两个入口：直连（默认 IP 10.77.0.1，连 :47800）、中转（输 6 位配对码）。
  - 连接成功自动全屏；**长按 Esc** 断开；**F1** 切换统计浮层（recv/dec fps、Mbps、RTT、drop）。
  - 自动化参数：`npx electron . --connect <ip> [--port N] --exit-after <秒>` 或 `--relay <码> [--server h:p]`，结束时 stdout 打 `TEST_RESULT {json}`。

### 结构

| 文件 | 职责 |
|---|---|
| `src/protocol.js` | 02-protocol 帧编解码（FrameParser/buildFrame/VIDEO_FRAME 载荷） |
| `main.js` | Electron 主进程：窗口、物理分辨率上报、全屏切换、测试出口 |
| `src/renderer.js` | 连接（直连/中转）、握手、WebCodecs 解码、canvas 渲染、PING/RTT、看门狗、背压丢帧 |
| `src/index.html` | 连接面板 + 全屏舞台 + 统计浮层 |
| `tools/cli-client.js` | **无 UI 联调客户端**（协议验证，见下） |
| `tools/mock-sender.js` | 模拟 Mac 端（ffmpeg testsrc2 实时 H.264），支持直连 + 中转两种模式 |

### 实现要点（与 90 号文档的实测事实逐条对齐）

- 建连后立即发 Receiver HELLO（不等 Sender HELLO）；`screen` 用主屏物理像素（`size × scaleFactor`）。
- 解码器配置 `codec:"avc1.640033"` + `optimizeForLatency:true` + 不设 description（Annex-B 直喂），以 HELLO_ACK 的 `display` 为准设 canvas/解码尺寸。
- 无 jitter buffer：收到即解码即渲染；`decodeQueueSize > 8` 时丢 delta 帧直到下一个关键帧。
- 解码错误 → 重建解码器 + 发 REQUEST_KEYFRAME(0x11)。VIDEO_CONFIG → 重置解码器等关键帧。
- PING 8 字节随机数 3 秒一发，PONG 按 payload 匹配算 RTT；10 秒无任何数据判死断开。
- 中转：RELAY_JOIN → RELAY_PAIRED 后走与直连相同的握手代码路径；RELAY_ERROR 中文提示。
- deviceId 首次运行生成并存 localStorage。

### Mock 联调结果（本机，等真实 Mac 复测）

| 场景 | 结果 |
|---|---|
| cli-client ↔ mock 直连 8s | PASS：首帧 keyframe、NAL [9,7,8,6]（AUD,SPS,PPS,SEI）、pts 单调、PONG 回显一致 |
| Electron ↔ mock 直连 12s（30fps） | recv 375 = decoded 375，0 丢帧 0 解码错误，RTT 0.5ms |
| Electron ↔ mock **经 15 relay** 15s | recv 454 = decoded 454，0 丢 0 错，RTT ≈ 294ms（双倍公网往返，见上） |
| 高压测试（mock 无节流 ~450fps 灌入） | 背压丢帧策略正常工作，decoder 不炸，0 解码错误 |

## 给 Mac 端的联调请求（下一步）

USB4 线已具备（网桥 IP 按约定 Mac 10.77.0.1 / Win 10.77.0.2），随时可联调：

1. **直连**：Mac 跑 `netdisplay-sender listen --port 47800`，Windows 端 `npm start` 点直连。
   若想先做纯协议验证：Windows 端会跑 `node tools/cli-client.js --direct 10.77.0.1 --seconds 10`（输出 SUMMARY JSON，PASS/FAIL 自动判）。
2. **中转**：Mac 跑 `netdisplay-sender relay`（默认已指向 15.tokencv.com:47700，**已在线**），把打印的配对码告诉 Windows 端即可。
3. 注意事实：mock 的 Annex-B 每帧带 AUD(9) 开头，Mac 端是 SPS(7) 开头——两种 Receiver 都兼容，无需改动。
4. 一个 Mac 端可复测点：Receiver 的 HELLO `screen` 会上报 Windows 物理分辨率（如 2560×1600），请确认虚拟屏创建用的就是这个值（HiDPI 时 scale 语义见协议 §3.3）。

## 协议疑问 / 修改提案

- 暂无。协议按 v1 实现完毕，未发现需要改动之处。
- 认同 90 号文档的观察：中途加入 GOP 时前 1–2 帧可能报 PPS 缺失——Receiver 已通过"等关键帧再解码"策略规避（waitingKey 初始为 true），实测 0 解码错误。
