---
date: 2026-07-21
tags: [netdisplay, handoff, windows, electron]
---

# Windows 端 Receiver 规范

> 负责方：Windows 端 Claude（不需要 Mac 端实现）。Mac 端阅读本文档是为了了解对端行为，便于联调。

## 技术选型

**Electron + Node `net` 模块 + WebCodecs `VideoDecoder` + canvas 渲染。**

理由：

- Chromium 的 WebCodecs H.264 解码走 D3D11/DXVA 硬解，延迟低（3–8ms），且 `codec: "avc1.*"` 配置在**不提供 `description` 时默认接受 Annex-B 输入**，与协议的 VIDEO_FRAME 格式零转换对接。
- TCP 客户端、帧解析、配对 UI、全屏窗口在 Electron 里都是现成能力，开发速度最快。
- 若后续对渲染延迟不满意，M4 之后可评估 Rust/原生重写，协议不变。

## 行为规范（与协议对应）

- 启动后 UI 提供两个入口：
  - **直连**：输入 IP（默认 `10.77.0.1`，即 USB4 网桥的 Mac 端地址），连 `47800`。
  - **中转**：输入 6 位配对码，连 `15.tokencv.com:47700` 发 RELAY_JOIN。
- 连接建立（或收到 RELAY_PAIRED）后立即发 HELLO，`screen` 填当前显示器的物理分辨率（`screen.getPrimaryDisplay().size × scaleFactor`）和 60fps。
- 收到 HELLO_ACK 后按 `display` 尺寸配置解码器：`VideoDecoder({codec: "avc1.640033", optimizeForLatency: true})`，不设 description（Annex-B 模式）。
- VIDEO_FRAME → `EncodedVideoChunk({type: keyframe?"key":"delta", timestamp: pts_us, data})` → decode → `VideoFrame` 画到全屏 canvas。**不做 jitter buffer**：解码输出直接渲染，积压则丢帧到最新关键帧。
- 每 3 秒发 PING（payload 为当前 `performance.now()` 的 8 字节表示），收 PONG 计算 RTT 显示在角落（可开关）。
- 断流 10 秒提示重连；重连成功后发 REQUEST_KEYFRAME。
- 全屏无边框窗口（`fullscreen: true, frame: false`），`Esc` 长按退出。

## 输入回传（M4，先不做）

全屏窗口捕获 mousemove/mousedown/wheel/keydown，按协议 §6 归一化后发 INPUT_EVENT。实装前提：中转模式加密已就绪（协议约定）。

## 给 Mac 端的联调提示

- Windows 端会先用一个 **Node 命令行最小客户端**（无 UI，只解码统计不渲染或 dump 到文件）做协议联调，再上 Electron UI。联调脚本会放进 `91-windows-progress.md` 说明。
- Windows 屏幕为 2560×1600（以实际 HELLO 上报为准）。
- USB4 直连时 Windows 侧静态 IP 配 `10.77.0.2/24`。
