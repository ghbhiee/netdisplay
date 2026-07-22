---
date: 2026-07-23
tags: [netdisplay, handoff, windows, tasks, v1.4]
---

# 给 Windows 端的任务（v1.4：连接与投射解耦 + 目标端控制）

> 先读 `02-protocol.md` §10 + changelog v1.4（Mac 端提案）。目标：**配对一次、连接常驻、投射随时开关/切换/弹回，目标窗口一直在**。
> 用户想要的体验：源机（Mac）操作即可投射;目标机（Windows）App **后台常驻**，投射来了自动显示，没投射时是个**空白窗口待命**；目标窗口上有个**「弹回」按钮**一键把窗口送回 Mac。

Mac 端会做的（供你对接）：持久配对下发 `pairSecret`;投射开始/停止发 `PROJECTION_STATE(0x13)`;切换投射源只发新 `VIDEO_CONFIG`**不断连**;收到你的 `CONTROL(0x21) bounceBack` 会把窗口移回 Mac 主屏并转空闲。

## P0 — 必做

### 1. 处理 `PROJECTION_STATE(0x13)`：空闲时保留空白窗口
- 收到 `{"active":false}` → **不要关窗**，显示占位（如「等待投射…」/上一帧灰掉）。收到 `{"active":true, "label":...}` → 正常显示，可把 label 显示在标题/角标。
- 关键：连接不断的前提下，画面可以「有→无→有」，窗口始终在。

### 2. 目标窗口上的「弹回」按钮 → 发 `CONTROL(0x21)`
- 窗口上放个按钮（或右键菜单/快捷键），点击发 `{"action":"bounceBack"}`。可选再来个「停止投射」发 `{"action":"stop"}`。
- 发完 Mac 会把窗口移回它主屏、停止投射并发 `PROJECTION_STATE{active:false}`，你随即进入空白待命。

### 3. 持久配对（免每次输码）
- HELLO_ACK 里若带 `pairSecret`（base64 32 字节）→ **持久保存**（localStorage/文件）。
- 之后重连中转：`RELAY_JOIN` 带 `pairHash = hex(sha256(pairSecret))`（不带 code，或 code 置空）;relay 已支持按 pairHash 撮合（Mac 端 REGISTER 也带同一 pairHash）。**不再要用户输码**。
- 直连模式不涉及配对。首次仍走输码配对拿到 pairSecret。

### 4. 后台常驻 + 自动显示
- App 可最小化到托盘/后台常驻;有投射（active:true / 收到帧）时自动把窗口显示到前台（或有提示），空闲时窗口留着显示空白。
- 目标是：用户只在 Mac 上操作，Windows 这边**不用手动点连接/重启**，配一次之后自动就绪。

## 说明 / 已经不用改的
- **切换投射源不需要你改**：Mac 换窗口只发新 `VIDEO_CONFIG`（你已加固中途改分辨率的路径），**同一连接**跟随即可，不会断连、不用重启你的 App。
- 单窗口/舞台投射对你透明（还是一路窗口大小的视频，窗口模式显示）。

## 需要你确认/反馈的
- v1.4 协议（§10）你看有没有异议;`pairHash` 的具体算法（hex(sha256(pairSecret)) 小写）两端要一致。
- relay 目前按房间撮合：REGISTER/JOIN 用 pairHash 当房间号是否已支持（05 里 relay 用 code 当 key，pairHash 可直接复用 code 字段位置或加 pairHash 字段——请确认 relay 实现，必要时小改）。

## ⚠️ 重要发现：Mac 不能硬编 HEVC 4:4:4（影响 v1.3 codec 协商）

Mac 端实测 **M5 VideoToolbox 无法编码 HEVC 4:4:4**（`main444` 直接 Invalid argument；软件路径也退回 Main 4:2:0）。硬编能到的**最好色度是 HEVC 4:2:2 10-bit（Rext / main42210）**，实测可出（`yuv422p10le`）。

所以你 91 里探测到"能解 HEVC Rext 4:4:4"没用武之地——**Mac 送不出 4:4:4**。可选路线：
- **A. HEVC 4:2:0（"hevc"）**：Mac 能编，比 H.264 压缩率高（省中转带宽），但色度还是 4:2:0（文字色边不改善）。你现有 "hevc" 串即指这个。
- **B. HEVC 4:2:2 10-bit（建议新增串 `"hevc422"`）**：Mac 能编，**水平满色度**（对彩色文字边有改善，非全 4:4:4）。需要你确认 WebCodecs 能解 **HEVC Rext Main 4:2:2 10-bit**（`hev1.4.10.L153.B0` 是 4:4:4 的；4:2:2 的 general_profile 也是 Rext=4，chroma_format_idc=2；请 `isConfigSupported` 实测一个 4:2:2 10bit 的 config）。能解就把 `"hevc422"` 加进 codecs 数组。
- **务实建议**：文字模糊里，Windows 你已修的**设备像素 1:1** + 提高码率，多数（尤其低饱和终端文字）已经够清；4:2:2 的收益主要在彩色文字。**先让用户试 H.264 + 1:1 + 高码率**，不够再上 hevc422。请把你对 A/B 的取舍 + 4:2:2 是否可解，反馈到 91。

## v1.4 持久配对：relay 需按 pairHash 撮合（补充 P0-3）
Mac 会在 HELLO_ACK 下发 `pairSecret`，重连时在 `RELAY_REGISTER` 带 `pairHash`。**relay 现在用 6 位 code 当房间号（05 代码里校验 len==6）**，pairHash 是 64 位 hex，进不去。请给 relay 加：REGISTER/JOIN 若带 `pairHash` 则用它当房间号撮合（与 code 二选一）。这样才能"配一次以后免输码"。改完在 91 说一声。

## 优先级
**1（PROJECTION_STATE 空白待命）→ 2（弹回按钮）→ 4（后台常驻自动显示）→ 3（持久配对，含 relay pairHash）→ codec A/B 取舍**。1+2 做完，"源端操作、目标端待命+一键弹回" 的核心体验就有了。
