# netdisplay-sender

NetDisplay 的 **Mac 端发送程序**：把 Mac 的一块**虚拟显示器**通过网络串流到 Windows，
把 Windows 电脑变成 Mac 的扩展屏（非镜像）。用 H.264 硬件编解码走 TCP，支持局域网/USB4
直连和经中转服务器的配对连接。

> 协议规范以共享 handoff 的 `02-protocol.md` 为唯一依据（source of truth）。
> 本仓库是三组件中的 Sender；Receiver（Windows/Electron）和 Relay（Go）另见 handoff。

## 管线

```
CGVirtualDisplay(私有API)  →  ScreenCaptureKit  →  VideoToolbox H.264  →  Annex-B  →  TCP
  建虚拟显示器(系统当真屏)      捕获该虚拟屏(NV12)     低延迟/无B帧/2s关键帧    关键帧内联SPS/PPS
```

## 环境要求

- Apple Silicon，macOS 14+（实测 macOS 26.5.1 / M5）。
- Xcode / Swift 6（实测 Xcode 26.6 / Swift 6.3.3）。
- **屏幕录制权限**：首次运行 ScreenCaptureKit 会请求；授权跟随启动它的终端 App，改权限后需重启进程。
- 调试需要 `ffmpeg`/`ffplay`（`brew install ffmpeg`）。

## 构建

```bash
swift build            # 产物 .build/debug/netdisplay-sender
swift build -c release # 发布构建
```

私有 `CGVirtualDisplay` 头以 C target（`Sources/CVirtualDisplay/`）桥接给 Swift；
类由系统 CoreGraphics 在运行时提供。

## 菜单栏 App（推荐日常用）

```bash
bash scripts/setup-signing.sh     # 只需一次：建稳定签名证书，让「屏幕录制」授权不随重编丢失
bash scripts/make-app.sh          # 产出 build/NetDisplay.app
open build/NetDisplay.app         # 图标出现在右上角菜单栏
```

菜单栏图标点开即可改 **模式(中转/直连)、缩放、码率、帧率、分辨率、清晰优先**，改完**实时生效**（会自动重连/重建虚拟屏）；中转模式菜单里直接显示**配对码**、点按复制。无参数运行二进制（或双击 .app）也进这个界面。

## 运行（命令行）

单窗口投射（只投一个程序窗口，不带桌面）：

- `--window <应用名>`：把某个 App 的窗口（如 iTerm、Safari）当作投射源，只投它、按窗口原生像素编码。菜单栏 App 里也有「投射源」子菜单选。
  例：`netdisplay-sender relay --window iTerm`。窗口在哪块屏、多大，就按其原生像素投；不建虚拟屏。窗口**改大小会自动跟随**（发 VIDEO_CONFIG）。
- `--stage`（配合 `--window`）：**扩展屏模式**。建一块离屏「舞台」虚拟屏，把该窗口**移到舞台上**（离开主屏，像最小化了），只投这个窗口、无桌面。目标端小窗口共存。停止后窗口自动回主屏、舞台屏销毁。
  例：`netdisplay-sender relay --window iTerm --stage`。菜单栏 App 里选「投射源」后勾「移到扩展屏」。
  - **需要「辅助功能」权限**（移动别的 App 窗口）：首次会弹系统设置授权；用固定签名的 `.app` 授权后长期有效。

缩放/分辨率覆盖（`listen` 与 `relay` 通用，用于「整个桌面/扩展屏」模式）：

- `--scale 2`：建 **HiDPI @2x** 虚拟屏——macOS 按「宽/2 × 高/2」逻辑点渲染（字/图标正常大小），
  画面像素仍是原分辨率、清晰不缩水。**高分屏上「字太小」就加这个。**
- `--width W --height H`：强制虚拟屏分辨率，覆盖 Receiver 上报值。
- 不带这些参数时，按 Receiver HELLO 上报的分辨率/缩放建屏。实际尺寸/scale 通过 HELLO_ACK.display 回给 Receiver。

```bash
# 直连模式：监听 47800，Windows Receiver 拨入；按其 HELLO（或覆盖参数）建虚拟屏
netdisplay-sender listen [--port 47800] [--bitrate 40] [--scale 2] [--width W --height H]

# M1 裸流自测：立即建虚拟屏，在 47801 推裸 Annex-B H.264（无协议帧头）
netdisplay-sender listen --debug-raw [--width 2560 --height 1600 --scale 1 --fps 60 --bitrate 40]
ffplay -fflags nobuffer -flags low_delay -f h264 tcp://127.0.0.1:47801

# 中转模式：连 relay，打印 6 位配对码，Windows 端输入配对后串流
netdisplay-sender relay [--server 15.tokencv.com:47700] [--bitrate 10] [--scale 2] [--width W --height H]
```

Ctrl-C（SIGINT）干净退出，销毁虚拟屏无残留。

## 端口

| 端口 | 用途 |
|---|---|
| 47800 | 直连模式监听（正式） |
| 47801 | 裸流调试口（仅 debug，无协议帧头） |
| 47700 | Relay（出站连接，中转模式） |

## 调试环境变量

| 变量 | 作用 |
|---|---|
| `NETDISPLAY_STATS=1` | 每秒打印 captured/encoded 帧率与捕获回调状态 |
| `NETDISPLAY_CAPTURE_MAIN=1` | 调试：改抓主屏（验证管线，不建议日常用） |

## 模块

| 文件 | 职责 |
|---|---|
| `CVirtualDisplay/include/CGVirtualDisplayPrivate.h` | 私有 API 头（复用自 opendisplay，GPL-3） |
| `VirtualDisplay.swift` | CGVirtualDisplay 封装；HiDPI/排列强制、随机序列号、apply 重试 |
| `Capture.swift` | ScreenCaptureKit 捕获，NV12，异常自动重启 |
| `Encoder.swift` | VideoToolbox H.264 低延迟；AVCC→Annex-B，关键帧内联 SPS/PPS |
| `StreamPipeline.swift` | 串联 VD+捕获+编码，背压丢帧，可选帧统计 |
| `Wire.swift` | 协议帧编解码 + JSON 模型 + VIDEO_FRAME 载荷 |
| `Session.swift` | 应用层会话（直连/中转共用）：HELLO/ACK/推流/PING-PONG/心跳 |
| `SessionServer.swift` | 直连监听 :47800 |
| `DebugRawServer.swift` | 裸流 :47801 |
| `RelayClient.swift` | 中转：连 relay、REGISTER、配对后接管为 Session |
| `main.swift` | CLI 解析与启动 |

## 已知坑

- **虚拟屏销毁（macOS 26 关键）**：macOS 异步移除虚拟屏，且**进程内第一次单独移除会超时失败**——必须
  **同时移除两块屏**才可靠（来源：Chromium `virtual_display_util_mac.mm` 的 `g_need_display_removal_workaround`）。
  `VirtualDisplay.reap()` 临时再建一块 throwaway、两块一起 release、轮询确认移除。Ctrl-C 退出会走 reap，**净零泄漏**。
  单纯 `= nil`（opendisplay 的做法）在 macOS 26 会漏成幽灵屏。
- **SIGKILL 仍会泄漏虚拟屏**（来不及跑 reap）；请用 Ctrl-C 干净退出。幽灵屏可注销/重启清理。
- 私有 API `applySettings` 偶发失败：多因僵尸屏 serial 冲突。已用**稳定 serial→随机回退 + 重试**规避。
- **空虚拟屏不产帧**：SCK 对无内容变化的虚拟屏不回调；有窗口/光标/内容变化即正常出帧（这是 SCK 行为）。
- SCK 偶发 `Failed to find any displays…`：已加捕获自动重启（退避重试）。

## 状态

M1 完成并实测通过（裸流 ffmpeg 解码、真实协议 HELLO/ACK/首帧关键帧/PING-PONG、
REQUEST_KEYFRAME 13ms、中转配对、2560×1600 与 1280×800 均验证）。License 依赖私有头，
沿用 opendisplay 的 GPL-3.0，个人自用。
