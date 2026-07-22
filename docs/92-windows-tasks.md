---
date: 2026-07-22
tags: [netdisplay, handoff, windows, tasks]
---

# 给 Windows 端 Claude 的任务清单（Mac 端下达）

> 背景：M1（Mac Sender）+ M2（你的 Receiver）+ M3（Relay）都已跑通，中转能投画面。
> 用户实测反馈两个核心问题 →「**画面糊、字太小、分辨率难调**」，加若干工程化 & 新功能需求。
> 先读 `02-protocol.md`（已升 **v1.1**，见其 changelog + §3.4）和 `90-mac-progress.md`（Mac 端已做的对应改动）。
> 你的代码在 `C:\Users\guoho\cc\netdisplay-receiver`（Electron 33 + Node 24）。

Mac 端已经做完的、你要对接的事实：
- 协议 **v1.1**：`HELLO_ACK.display` 现在带可选 `scale`，形如 `{"width":2560,"height":1600,"fps":60,"scale":2}`。**`width×height` 是编码物理像素，`scale` 是 HiDPI 因子（逻辑点=width/scale）**。
- Mac 端可用 `--scale/--width/--height/--fps/--bitrate/--quality` 覆盖，最终尺寸一律以 `HELLO_ACK.display` 为准。
- Mac 端已做成菜单栏 App，可实时改配置。

---

## P0 — 清晰度 / 防糊（用户第一痛点，最高优先）

### 1. canvas 必须按「设备像素 1:1」渲染（去糊的关键）
现在糊的**主因**在这：Windows 常是 150% DPI，Electron 里 CSS 像素 ≠ 物理像素。把 `HELLO_ACK.display` 的 `width×height`（如 2560×1600）画进一个被系统再缩放的窗口 → 二次缩放 → 糊。
- canvas 的**后备缓冲**必须正好是 `display.width × display.height` 物理像素（`canvas.width/height` 设为该值）。
- canvas 的 **CSS 显示尺寸**要按 `window.devicePixelRatio` 校正：显示尺寸(px) = 物理尺寸 / devicePixelRatio，使「1 视频像素 = 1 屏幕物理像素」。
- 或给窗口/webContents 关掉缩放：`app.commandLine.appendSwitch('force-device-scale-factor','1')` 或 `high-dpi-support=1`，并用 `image-rendering: pixelated/crisp-edges` 兜底。
- 全屏且面板原生 2560×1600、canvas 2560×1600、设备像素 1:1 时应当**最锐**。先把这个做对，多数「糊」会消失。

### 2. 窗口模式（非全屏）+ 指定分辨率（用户明确要）
- Receiver 支持**不全屏**、以一个可调大小的**窗口**显示投来的画面。
- 让用户在 UI 里选/输入期望分辨率与缩放，填进 **HELLO 的 `screen`**（`width/height/scale`）发给 Mac；Mac 会照建虚拟屏并在 `HELLO_ACK.display` 回实际值。
- 窗口里同样遵守 P0-1 的「设备像素 = display.width×height」，否则窗口缩放又会糊。

### 3.（进阶，需两端协商）评估 HEVC / 4:4:4
- 文字锐利的深层解法是避开 4:2:0 色度下采样（Moonlight 桌面清晰靠 4:4:4）。
- 请确认你的 **WebCodecs** 能力：`VideoDecoder.isConfigSupported({codec:'hev1.1.6.L153.B0'})`（HEVC）、以及 4:4:4 profile 是否可解。把结论写回 `91`。
- 若两端都支持，我们在 HELLO/HELLO_ACK 里协商 `codec`/`chroma`，**届时一起升协议**（Mac 端 VideoToolbox 可出 HEVC / 试 4:4:4）。这条不阻塞 P0-1/2。

---

## P1 — 工程化（用户要「独立程序 + 设置界面 + 运行中改配置」）

### 4. 打包成独立可执行程序
- 现在是 `npm start` 跑 Electron。用 **electron-builder** 出 Windows 产物：优先 **portable .exe**（免安装双击即用），可另出 NSIS 安装包。
- 目标：用户拿到一个 exe 双击就能用，不装 node/依赖。

### 5. 重做启动/设置界面
把这些做成设置项（带记忆，存本地）：
- 连接：模式(直连/中转)、直连 IP(默认 10.77.0.1)、中转配对码、relay 地址。
- 画面：分辨率(含「跟随本机物理」)、缩放 scale、码率、帧率、全屏/窗口。
- 显示：RTT/fps/丢帧 浮层开关。

### 6. 运行中改配置、实时生效
- 改分辨率/缩放：断开→带新 `screen` 重发 HELLO 重连（Mac 会重建虚拟屏）。改码率：先断连重连（Sender 端动态码率是 M4）。
- 与 Mac 端的菜单栏 App 对称，双方都能不重启改配置。

---

## 其它对接说明
- **单窗口投射（Mac 端 C 功能，我在做）对你基本透明**：Mac 会把「某个窗口」当作虚拟屏内容投来，窗口 resize → 分辨率变 → Mac 发 **VIDEO_CONFIG(0x12)**，你按现有「重置解码器等关键帧」处理即可（你 91 里说已支持）。请确认中途分辨率变化路径稳。
- 首帧关键帧、SPS/PPS、PING/PONG、REQUEST_KEYFRAME 等 M1/M2 事实不变。
- 进展/联调脚本写回 `91-windows-progress.md`；有协议改动先改 `02-protocol.md` 并记 changelog。

## 建议优先级
**P0-1（设备像素 1:1 去糊）→ P0-2（窗口+选分辨率）→ P1-4/5/6（打包+设置+实时改）→ P0-3（HEVC/4:4:4 评估）。**
P0-1 大概率一改就明显变清，先做它。
