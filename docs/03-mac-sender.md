---
date: 2026-07-21
tags: [netdisplay, handoff, mac, swift]
---

# Mac 端 Sender 实现指南

> 读者：Mac 端 Claude。这是你的主要工作文档。协议细节以 `02-protocol.md` 为准。

## 0. 起步检查

开始编码前先确认环境并记录到 `90-mac-progress.md`：

```bash
sw_vers                                  # 需要 macOS 14+
system_profiler SPHardwareDataType       # 芯片型号（需 Apple Silicon）
xcodebuild -version                      # Xcode / Command Line Tools
git clone https://github.com/peetzweg/opendisplay ~/opendisplay-ref
```

## 1. 项目形态建议

- **Swift Package / Xcode 工程均可**，建议先做成**命令行程序 + 少量 AppKit**（菜单栏图标可后置），把精力放在管线上。产物不上 App Store，无沙盒，可用私有 API。
- 需要的系统权限：**屏幕录制**（首次运行 ScreenCaptureKit 时系统会弹授权，需在系统设置里勾选）。M4 输入注入还需**辅助功能**权限。
- 最低部署目标 macOS 14.0。

模块划分建议（对应 opendisplay 的结构，但按本项目协议实现）：

```
Sources/
  main.swift              // 参数解析、启动流程
  VirtualDisplay.swift    // CGVirtualDisplay 封装
  Capture.swift           // ScreenCaptureKit → CMSampleBuffer
  Encoder.swift           // VideoToolbox H.264，输出 (pts, isKeyframe, annexBData)
  Wire.swift              // 02-protocol 帧编解码（读写循环、TCP_NODELAY）
  SessionServer.swift     // 直连模式：监听 47800，处理 HELLO/ACK，推流
  RelayClient.swift       // 中转模式：连 relay、REGISTER、配对后复用 Session 逻辑
  DebugRawServer.swift    // 47801 裸流（M1 验收）
```

## 2. 核心环节要点

### 2.1 CGVirtualDisplay（私有 API）

- 直接复用 opendisplay 的 `Mac/CGVirtualDisplayPrivate.h`（经桥接头引入），参考其 `VirtualDisplay.swift` 的调用顺序：`CGVirtualDisplayDescriptor`（name、maxPixels、sizeInMillimeters、queue、terminationHandler）→ `CGVirtualDisplay(descriptor:)` → `CGVirtualDisplaySettings`（hiDPI、modes: `[CGVirtualDisplayMode(width:height:refreshRate:)]`）→ `display.apply(settings)`。
- 尺寸来自 Receiver HELLO 的 `screen`。`sizeInMillimeters` 按 ~110 PPI 反算（决定系统默认缩放观感）。
- 创建成功后系统"显示器"设置里会出现新显示器。记录 `display.displayID`，捕获时要用。
- 销毁：释放 CGVirtualDisplay 对象即可。注意 Receiver 断线后保留 60 秒再销毁（见协议 §9）。
- 已知坑：私有 API 无文档，若在当前 macOS 版本行为异常，先对照 opendisplay 最新 commit 和 BetterDisplay/DeskPad 的 issue 区找线索。

### 2.2 ScreenCaptureKit

- `SCShareableContent.current` 里按 `displayID` 找到虚拟屏对应的 `SCDisplay`，用 `SCContentFilter(display:excludingWindows:[])` 只捕获它。
- `SCStreamConfiguration`：`width/height` = 虚拟屏像素尺寸；`minimumFrameInterval = CMTime(value: 1, timescale: 60)`；`pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`（NV12，编码器直收）；`queueDepth = 3`；`showsCursor = true`（v1 光标直接烧进画面，最简单）。
- 回调里注意丢帧策略：编码器忙时丢旧帧保新帧，绝不排队。

### 2.3 VideoToolbox 编码

关键属性（低延迟的命脉）：

```
kVTCompressionPropertyKey_RealTime = true
kVTCompressionPropertyKey_AllowFrameReordering = false     // 禁 B 帧
kVTCompressionPropertyKey_ProfileLevel = H264_High_AutoLevel
kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration = 2  // 秒
kVTCompressionPropertyKey_AverageBitRate = 40_000_000      // 直连默认
kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality = true
```

- 输出是 AVCC 格式（4 字节长度前缀），**必须转 Annex-B**：遍历 sampleBuffer 的 blockBuffer 把长度前缀换成 `00 00 00 01`；关键帧判断用 attachment `kCMSampleAttachmentKey_NotSync == false`；关键帧要先从 `CMVideoFormatDescriptionGetH264ParameterSetAtIndex` 取 SPS/PPS，以起始码形式拼在帧前。opendisplay `MacSender.swift` 有完整可参考的实现。
- 响应 `REQUEST_KEYFRAME`：下一帧编码时带 `kVTEncodeFrameOptionKey_ForceKeyFrame = true`。
- 码率切换（直连 40M / 中转 10M）在创建 session 时按模式设定即可，动态调整是 M4。

### 2.4 网络（Wire.swift + Session）

- 用 `Network.framework`（NWListener/NWConnection）或 POSIX socket 均可；NWConnection 注意用 `.tcp` 参数并设 `noDelay = true`（`NWProtocolTCP.Options.noDelay`）。
- 读循环：严格按 `02-protocol.md` §1 的帧格式解析（1 字节 type + 4 字节大端长度 + payload），处理 TCP 粘包/半包。
- 写路径：VIDEO_FRAME 直接从编码回调线程序列化后交给发送队列；发送队列積压超过 ~5 帧说明网络跟不上，丢弃非关键帧并请求下调（v1 简单丢弃即可，记日志）。
- 单连接即可：同一时刻只服务一个 Receiver，新连接踢掉旧连接。

### 2.5 RelayClient（M3）

- 连接 `15.tokencv.com:47700`，发 `RELAY_REGISTER`（配对码用 `SecRandomCopyBytes` 生成 6 位数字，打印到 stdout/UI）。
- 收到 `RELAY_PAIRED` 后，把这条 NWConnection 直接交给与直连模式相同的 Session 处理逻辑（先发 HELLO）。
- 断线重连：指数退避，重新 REGISTER 时生成**新的**配对码（v1；持久配对是 M4）。

## 3. 命令行接口建议

```bash
netdisplay-sender listen [--port 47800] [--debug-raw]     # 直连模式
netdisplay-sender relay [--server 15.tokencv.com:47700]   # 中转模式，打印配对码
```

## 4. M1 验收清单（完成后写入 90-mac-progress.md）

1. 启动 `listen --debug-raw`，接受一个模拟 HELLO（可用简单 Python/`nc` 脚本，或先只做裸流）后创建 2560×1600@60 虚拟屏。
2. 系统设置→显示器 出现虚拟屏，可把窗口拖过去。
3. 本机 `ffplay -fflags nobuffer -flags low_delay -f h264 tcp://127.0.0.1:47801` 能看到虚拟屏画面。
4. 在虚拟屏上拖动窗口/播放视频，ffplay 画面流畅、目测延迟 < 100ms（ffplay 本身有额外缓冲，仅作烟囱测试）。
5. Ctrl-C 退出后虚拟屏消失、无残留。
6. 连续运行 10 分钟无内存增长异常（`footprint` 或 Activity Monitor 观察）。

## 5. 常见坑预警

- **屏幕录制权限**：命令行程序的授权跟随终端 App（Terminal/iTerm）。用 Xcode 运行时跟随 Xcode。授权变更后必须重启进程。
- **AVCC→Annex-B 忘了 SPS/PPS**：ffplay 黑屏/花屏的第一嫌疑人。
- **虚拟屏被系统设为主屏**：创建后检查排列，必要时用 `CGConfigureDisplayOrigin` 把它放到主屏右侧（参考 opendisplay `DisplayArrangement.swift`）。
- **编码器 session 在分辨率变化时必须重建**，并发 VIDEO_CONFIG + 关键帧。
- **NWConnection 默认开启 Nagle**，忘记关 noDelay 会让延迟抖动到几十毫秒。
