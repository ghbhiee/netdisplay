---
date: 2026-07-21
tags: [netdisplay, handoff, mac, progress]
---

# Mac 端进展（Sender）

> 维护者：Mac 端 Claude。与 `91-windows-progress.md` + `02-protocol.md` 三方异步协作。

## 当前状态：**v1.4 增量1+2+4 已做并实测（解耦/活切/舞台跟随）；持久配对(需relay)+HEVC 待 Windows 协作** ✅

- 🔬 **hevc422 编码·最终定论：Mac 端不可行（VT 硬编限制）**。实装了 BGRA→p422(10bit 4:2:2) 的 VTPixelTransferSession 转换级喂给编码器，但：VT 接受 Main42210 profile（setProperty status=0、readback 确认），喂真 10bit 4:2:2 输入，**HW 编码器仍输出 Main/yuv420p**（ffprobe 实证，116KB 干净抓包）；强制 SW 路径即便能出 4:2:2 也远达不到 60fps 实时。→ **negotiateCodec 不再上报 hevc422，Mac 实时 HEVC 封顶 4:2:0（hevc）**。p422 转换级代码保留在 Encoder 里（被 codec 门控、当前不选中），未来支持 4:2:2 HW 编码的 Mac 可直接放开。h264/hevc 回归自测 PASS（44/44、53/53、0 error）。

- ✅ **Mac 接收端·渲染器**：`FrameRenderer`（Metal 后端 CIContext，NV12 CVPixelBuffer→CGImage，YUV→RGB 用 buffer 附带的色彩属性）+ `ReceiverWindow`（NSWindow，按 stream 尺寸等比适配屏幕，逐帧 `layer.contents=CGImage` GPU 合成）。`receive --window` 开实时窗口、`--snapshot PATH` 存首帧 PNG（无 UI 验证）。
- ✅ **验证**：直连回环 `--snapshot` → PNG **1280x800、3402 distinct 采样色、mean 129.6、0 error**（真实虚拟桌面内容，非黑屏），解码→转换链路确证。`--window` 是标准 AppKit 把同一 CGImage 贴层，待真机肉眼确认。
- ✅ **接收端字节计账**（回应 Windows）：`recv` 统计的 `bytes` 只算 **Annex-B 载荷本身**（不含 VIDEO_FRAME 的 9 字节 pts+flags 头），**与 Windows Sender 的 `bytes` 口径一致**——两侧数字可直接对账，差值不再有帧×9 偏移。stats 行加 `x.xxMbps(annexb)`。
- Mac 接收端（对称 App 的一半）核心已齐：解码/直连/中转/持久配对/渲染。剩 hevc422（v210 转换级）与 UI 整合。

- ✅ **Mac 接收端·中转模式 `ReceiverRelayClient.swift`**：拨 relay → RELAY_JOIN{role:receiver, code 或 pairHash, token} → RELAY_PAIRED 后把透明管交给 ReceiverSession 跑正常握手/解码；断线按 pairHash 免码重连待命。PairStore 加**按角色分槽**（sender=本机自签、receiver=对端下发），HELLO_ACK.pairSecret 存进 receiver 槽 → 下次 JOIN 免码。`receive --server` 走中转、否则直连。
- ✅ **实测（真实 15 relay，带 token）**：Mac Sender relay ↔ Mac Receiver relay，pairHash JOIN → PAIRED → **handshake OK 1280x800@60 h264 → 解码 42fps 0 error**、receiver 存下 pairSecret。跨网络中转收流链路打通。（静止虚拟桌面帧率低同前，非接收端问题。）
- **下一步（我）**：CVImageBuffer → NSWindow/Metal 渲染器（把画面显示出来，当前仍是计数版）。

- ✅ **Mac 接收端·网络会话 `ReceiverSession.swift`**（直连模式）：拨号 Sender:47800 → 发 HELLO{role:receiver,screen,codecs} → 收 HELLO_ACK 起 Decoder（按协商 codec）→ VIDEO_FRAME 解析([pts u64|flags u8|annexB]) 喂解码 → PROJECTION_STATE 日志 → PING(3s)/PONG 回显 → 看门狗(10s无数据断) → 解码错误自动发 REQUEST_KEYFRAME；VIDEO_CONFIG 重建解码器等关键帧。新增 `receive` 命令。
- ✅ **回环实测**（Mac `listen` ↔ Mac `receive`）：**handshake OK**（stream 1280x800@60 h264）、解码帧数==收到帧数、0 error、连接稳定无看门狗触发。（静止虚拟桌面 SCK 按变化投帧、稳态帧率低是采集侧特性，非接收端问题；真实内容会连续。）**Windows WS-1/WS-2 Sender → Mac receive 可真机互调了。**
- **下一步（我）**：① NSWindow/Metal 渲染器把 CVImageBuffer 显示出来（当前 onFrame 是计数）；② Receiver 中转模式（relay JOIN + pairHash 免码）。

- ✅ **Mac 接收端·解码核心 `Decoder.swift`**：VTDecompressionSession；Annex-B 拆 NAL（3/4 字节起始码）、参数集分类（H264 SPS7/PPS8、HEVC VPS32/SPS33/PPS34）→ CMVideoFormatDescriptionCreateFrom{H264,HEVC}ParameterSets → 建/换会话；VCL 转 AVCC 喂 VTDecompressionSessionDecodeFrame（异步 handler 出 CVImageBuffer）；解码错误回调触发 REQUEST_KEYFRAME（待网络层接）。
- ✅ **回环自测命令 `decode-selftest`**（虚拟屏→Encoder→Decoder 计帧）：**PASS** —— h264 45/45、hevc 52/52，0 error、pts 单调。下一步把 Decoder 接网络（Receiver 会话），即可与 Windows WS-1 Sender 真机互调。

- 🔧 **修复 resize 掉 codec bug**：StreamPipeline.reconfigure() 之前重建 Encoder 没传 codec → 窗口 resize 后 HEVC 会话会静默降回 H.264。现在存 `encCodec` 并传入，resize 后保持编码格式。
- 🔬 **hevc422 调研结论**：VT 的输出色度取决于**输入像素格式**，喂 BGRA(8bit) 即便设 Main42210 profile，ffprobe 实测输出仍是 **Main / yuv420p**（20Mbps 30fps 出流正常，但不是 4:2:2）。要真 4:2:2 10bit 必须先把 BGRA 转成 10bit 4:2:2 缓冲（v210）再喂编码器——需加一个 VTPixelTransferSession 转换级（下一步）。已备好 `VideoCodec.profileLevel/.captureFormat` 与 negotiate 里的 hevc422 项，转换级落地后放开即可。

- ✅ **codec 协商**：Session 读 HELLO.codecs → negotiateCodec 挑 Mac 能编的（hevc→h264，hevc422 暂排除）→ 回 HELLO_ACK.codec + 用于编码器/VIDEO_CONFIG。实测 [hevc422,hevc,h264]→hevc、[h264]→h264。真实会话自动用 HEVC 4:2:0。

- ✅ **HEVC 编码器（codec 化）**：Encoder 支持 h264/hevc/hevc422 参数化；`--codec hevc` 实测出 HEVC Main 4:2:0，VPS+SPS+PPS 正确内联、ffmpeg 解 91 帧。下一步 codec 协商 + hevc422（4:2:2 输入）。

- ✅ **v1.4 增量3 持久配对（Mac 端）**：HELLO_ACK 下发 pairSecret（存 ~/.netdisplay-sender/pairSecret）；relay 有 secret 则 pairHash 免码注册。pairHash=hex(sha256(base64decode(secret)))，与 Windows 实测一致。

### 2026-07-23 更新之二：v1.4 连接/投射解耦（Mac 端增量 1+2 完成）

- ✅ **增量1 解耦**：连接常驻，投射变成可开关/切换/弹回的子状态。发 `PROJECTION_STATE(0x13)`（active:true 带 label / active:false 空闲）；收 `CONTROL(0x21){"bounceBack"}` → 停投射、弹回窗口（reap 舞台屏→窗口回主屏）、转空闲。实测：弹回后 **PONG 正常、无 BYE，连接仍活**。
- ✅ **增量2 活切源不重连**：菜单/控制器改「投射源/分辨率」→ `session.switchSource` → 同一连接发 `VIDEO_CONFIG(新尺寸)`，**HELLO_ACK 全程只发 1 次、不重连、目标 App 不重启**。实测 window↔desktop 来回切，只 1 次握手、2 次 VIDEO_CONFIG、无 BYE。
- ✅ **增量4 舞台跟随最前窗口**：`--window <App> --stage` 现在=**舞台跟随**——把选定窗口移到离屏 **HiDPI @2x 舞台**（3840×2400/1920×1200pt，retina 清晰），之后**投射舞台上最前的窗口**；拖别的窗口上舞台→旧窗口弹回主屏、新窗口顶上（发 VIDEO_CONFIG 变分辨率）。实测 TextEdit→拖 Finder 上台→自动切 Finder；online 回 1 无泄漏。
- ⏳ **Mac 待做**：增量3 持久配对（HELLO_ACK 下发 pairSecret，重连用 pairHash 免输码）——**依赖 relay 按 pairHash 撮合（Windows 改 relay，见 93）**。
- ⚠️ **HEVC 结论（重要）**：**M5 VideoToolbox 编不了 HEVC 4:4:4**（实测 main444=Invalid argument）。硬编最好 **HEVC 4:2:2 10-bit(Rext)**。你 91 探测的 4:4:4 硬解 Mac 送不出。取舍见 93（先试 H.264+设备像素1:1+高码率，不够再上 hevc422）。
- **Windows 端配合项在 `93-windows-tasks.md`**：处理 PROJECTION_STATE（空闲保留空白窗口）、加「弹回」按钮发 CONTROL、持久配对+relay pairHash、后台常驻自动显示、codec A/B 取舍。切换源你不用改（走 VIDEO_CONFIG）。

---

### （旧）M1 完成；菜单栏 App + 单窗口投射 + resize跟随 + v1.2码率 已做 ✅

### 2026-07-23 更新（读 91 后：v1.2 码率 + C-2 resize + Mac 端产品化）

- ✅ **v1.2 码率采纳**：Mac 未带 `--bitrate` 时**采纳 Receiver 的 `HELLO.screen.bitrateMbps`**；带 `--bitrate`/菜单里选了具体值则以 Mac 为准（菜单加了「自动（听对端）」项）。实测：对端请求 50→编码 50；Mac `--bitrate 40`→保持 40。
- ✅ **菜单栏 App（A）**：`NetDisplay.app`（`scripts/make-app.sh`，稳定签名保授权），状态栏改 模式/缩放/码率/帧率/分辨率/清晰优先/**投射源**，实时生效；中转显示配对码可复制。
- ✅ **单窗口投射（C 核心）**：`--window <App>`（或菜单「投射源」）只投一个窗口、按窗口原生像素编码，不建虚拟屏。对你透明（就是一路视频）。
- ✅ **C-2 resize 跟随**：投射窗口改大小 → Mac 轮询检测 → 换编码器 + reconfigure SCStream + **发 VIDEO_CONFIG(新宽高)**。实测 1600×1200→2800×1940，你收到 VIDEO_CONFIG 即可跟随（你已加固该路径）。
- ✅ **C-2b 扩展屏「舞台」模式**：`--window <App> --stage`（或菜单勾「移到扩展屏」）→ 建离屏舞台虚拟屏，用**辅助功能权限把该窗口移到舞台上**（离开主屏=像最小化），只投这个窗口、无桌面 chrome，尺寸=窗口。停止后窗口自动回主屏、舞台屏 reap 干净。实测：TextEdit 从主屏 (200,150) 移到舞台 (x=1734，越过主屏 1710 边界)，投 800×600，online 回 1 无泄漏。对你透明（仍是一路窗口大小的视频，你窗口模式显示即可）。
- ⏳ **未做**：舞台上「拖任意窗口自动跟随最前窗口」（现在投选定 App 的窗口）、键鼠回传（M4，与舞台同一个辅助功能权限）。
- 🔑 **待做·清晰度正解 HEVC 4:4:4（你的 v1.3）**：你探测到 `hev1.4.10.L153.B0` 硬解可用，这是文字锐利的正解。Mac 端要实装：读 HELLO 顶层 `codecs`，优先 hevc444（VideoToolbox `kCMVideoCodecType_HEVC` + 4:4:4，需 4:4:4 捕获像素格式 + 关键帧内联 VPS/SPS/PPS）→ hevc → h264，选择回 `HELLO_ACK.codec`。**这是下一个大项**，做完文字清晰度应质变。

---

### （旧）M1 完成并验证；已读 91，M2/M3 联调就绪 ✅

### 2026-07-22 更新（回应 91-windows-progress.md）

- ✅ **Mac RelayClient ↔ 真实 relay 已互通**：`relay --server 15.tokencv.com:47700` 实测秒连、REGISTER 成功、打印配对码（不只是本地 stub）。等 Windows 端 JOIN 即可完成中转联调。
- ✅ **回应你的复测点(§给Mac的联调请求 4)**：虚拟屏**确实按 Receiver HELLO 的 `screen` 创建**——`width/height` 取偶、`scale≥2` 走 HiDPI(点尺寸=像素/scale)、`scale=1` 走 1:1。已实测 2560×1600 与 1280×800 均正确。所以你上报 2560×1600 scale=1，Mac 就建一块 2560×1600 物理像素的 1:1 虚拟屏，编码输出即 2560×1600。
- ✅ **Annex-B 差异确认无碍**：你的 mock 首帧以 AUD(9) 开头，Mac 端真实编码器首帧以 SPS(7) 开头；两者都以关键帧+SPS/PPS 起始，你的"等关键帧再解码"策略都能吃。
- 🔧 **本轮 Mac 端加固（联调前你可留意）**：① 虚拟屏 enforcement 改为**贯穿生命周期**(持续稳 mode/mirror/origin)；② **解决 macOS 26 虚拟屏销毁坑**（Chromium 配对移除 workaround，见下方"已知坑"）——Ctrl-C 现在净零泄漏；③ 稳定 serial→随机回退。这些不改协议，对你透明。
- **联调随时可开**：直连 `listen --port 47800`（USB4，Mac 10.77.0.1）或中转 `relay`（15 已在线，我把码给你）。我这边一句命令就位。

### 2026-07-22 追加：缩放/分辨率（解决「字太小/糊」）——协议已升 v1.1

用户反馈：虚拟屏被迫用 Windows 面板物理分辨率（2560×1600）且 1:1，macOS 桌面渲染得「大而字小」，Windows 又按自己 DPI 缩放 → 又小又糊。已在 Mac 端加能力：

- **Mac 端新增覆盖参数**（`listen` / `relay` 都支持）：`--scale S`、`--width W`、`--height H`，优先于 Receiver 的 HELLO 请求。
  - **`--scale 2` 就是「字太小」的解药**：Mac 建 **HiDPI @2x** 虚拟屏——macOS 按 `1280×800` 逻辑点渲染（字/图标正常大小），但**编码输出仍是 2560×1600 清晰像素**。已实测 macOS 26 上 HiDPI 稳定可用（mode `1280x800 (px 2560x1600)`）。
  - 例：`./netdisplay-sender relay --scale 2`。用户现在就能试,**你 Windows 端不改也能立刻见效**（因为你本来就按 HELLO_ACK.display 的 width×height 渲染,还是 2560×1600,只是里面的 UI 变大了）。
- **协议 v1.1**（见 02-protocol.md changelog + §3.4）：HELLO_ACK.display 增加可选 `scale`；明确 **Sender 可覆盖尺寸，Receiver 一律以 HELLO_ACK.display 为准**。已实测 ACK 正确回 `{"width":2560,"height":1600,"fps":60,"scale":2}`。

**请 Windows 端补的两件事（用户明确要）**：
1. **让用户选分辨率/缩放**：Receiver UI 加个选项，把用户选的 `width/height/scale` 填进 HELLO 的 `screen`（Sender 会按此建屏）。或至少读并利用 HELLO_ACK.display.scale。
2. **窗口模式（非全屏）+ 防糊**：允许不全屏、以指定分辨率窗口显示；关键是 **canvas 的设备像素 = HELLO_ACK.display 的 width×height**（在 Windows 150% DPI 下，CSS 尺寸要除以 devicePixelRatio，或用 `image-rendering` + 精确尺寸），否则 2560 的画面塞进被 OS 二次缩放的窗口就会糊。全屏 1:1 时最锐。
   - 「糊」的根因基本在这一步（Windows 端把画面二次缩放）；Mac 端已保证送出的是原生像素、不缩水。

### 2026-07-22 再追加：清晰度调研结论 + Mac 端清晰度旋钮

调研（Moonlight/Sunshine、chroma subsampling 资料）+ 复看 opendisplay 后的结论——**没有银弹**，糊来自三处叠加，按影响排序：
1. **码率太低**：中转默认 10 Mbps 推 2560×1600 远远不够（Moonlight 桌面用到几百 Mbps 才「接近原生」）。**直连 40–80 Mbps 才够锐**。
2. **4:2:0 色度下采样**：文字/彩色边缘发虚的经典原因，Moonlight 专门加 **4:4:4** 解决桌面文字。opendisplay 也是 4:2:0 H.264（~18 Mbps），它靠「投到 Retina iPad 且 1:1」显得还行。
3. **Windows 端二次缩放**（见上一节）。

**Mac 端已加的清晰度旋钮**（`listen`/`relay` 通用）：
- `--bitrate N`（Mbps，直连可拉到 60–80）、`--fps N`（**低码率时降到 30 甚至 24，每帧分到的码率翻倍，文字明显更清**）、`--quality`（关掉 PrioritizeSpeed，同码率更锐，代价是编码稍慢）、`--scale`（HiDPI，字更大更易读）。并加了峰值码率上限，防某帧爆量把整屏冲糊。
- **给用户的最优组合**：`listen --bitrate 60 --scale 2 --quality`（USB4 直连）；中转退而求其次 `relay --scale 2 --fps 30 --quality --bitrate 15`。

**请 Windows 端评估/配合的清晰度项**（关键）：
- **canvas 设备像素 = HELLO_ACK.display 的 width×height**（Windows 150% DPI 下必须按 devicePixelRatio 校正），这是去糊第一优先。
- 评估 **HEVC / 4:4:4**：WebCodecs 在新版 Chromium 支持 HEVC；4:4:4 解码要确认能力。若两端都支持，可显著提升文字清晰度——**这是协议层要商量的**（需要在 HELLO/HELLO_ACK 协商 codec/chroma，届时升协议）。Mac 端 VideoToolbox 可出 HEVC，也能试 4:4:4，但要 Receiver 解得了才有意义。

### 请 Windows 端做的工程化（用户明确要）
1. **打包成独立可执行程序**（现在是 `npm start` 跑 Electron）：用 electron-builder 出 `.exe`（免安装 portable 或安装包），双击即用。
2. **重做启动/设置界面**：直连 IP/中转码、分辨率、缩放(scale)、码率、帧率、全屏/窗口 等做成设置项。
3. **运行中改配置、实时生效**：改分辨率/缩放要重连并重发 HELLO（Mac 会重建虚拟屏 + VIDEO_CONFIG）；改码率可先断连重连（M4 再做 Sender 端动态码率）。

（Mac 端也在做同样的「menu bar app + 实时改配置」，见下方 Mac 端规划。）

Mac 端发送程序已实现全部管线（虚拟屏 → 捕获 → H.264 → Annex-B → TCP），
并额外实现了 M2/M3 需要的**完整线上协议**（HELLO/HELLO_ACK/VIDEO_FRAME/PING/PONG/BYE）
和**中转客户端**（RELAY_REGISTER/配对/接管），Windows 端现在可以直接开始 M2。

## 代码仓库

- 路径：`~/cc/netdisplay-sender`（Swift Package，非 git 仓库，本机）
- 构建：`cd ~/cc/netdisplay-sender && swift build`（Xcode 26.6 / Swift 6.3.3）
- 产物：`.build/debug/netdisplay-sender`
- 参考实现克隆在 `~/opendisplay-ref`（仅供参考，未纳入本仓库）

### 模块

| 文件 | 职责 |
|---|---|
| `Sources/CVirtualDisplay/include/CGVirtualDisplayPrivate.h` | 私有 API 头（复用自 opendisplay），C target 暴露给 Swift |
| `VirtualDisplay.swift` | CGVirtualDisplay 封装（HiDPI/排列强制、唯一序列号、apply 重试） |
| `Capture.swift` | ScreenCaptureKit 捕获虚拟屏，NV12，异常自动重启 |
| `Encoder.swift` | VideoToolbox H.264 低延迟，AVCC→Annex-B，关键帧内联 SPS/PPS |
| `StreamPipeline.swift` | 串起 VD+捕获+编码，背压丢帧，可选帧统计 |
| `Wire.swift` | 02-protocol 帧编解码 + JSON 模型 + VIDEO_FRAME 载荷 |
| `Session.swift` | 应用层会话（直连/中转共用）：HELLO/ACK/推流/PING-PONG/心跳 |
| `SessionServer.swift` | 直连监听 :47800 |
| `DebugRawServer.swift` | 裸流 :47801（M1 验收） |
| `RelayClient.swift` | 中转：连 relay、REGISTER、配对后接管为 Session |
| `main.swift` | CLI 解析与启动 |

## 环境（已确认）

- **Mac**：MacBook Air, **Apple M5**, 16 GB, **macOS 26.5.1 (build 25F80)**。
- Xcode 26.6，Swift 6.3.3。ffmpeg/ffplay 已装（/opt/homebrew/bin）。
- 屏幕录制权限：运行终端需授权「屏幕录制」，否则捕获无帧。当前运行环境已授权。

## 启动方式

```bash
cd ~/cc/netdisplay-sender && swift build

# 直连模式（真实协议，Windows Receiver 拨入 :47800）
./.build/debug/netdisplay-sender listen --port 47800 [--bitrate 40]

# M1 裸流自测（立即建虚拟屏，:47801 推裸 Annex-B）
./.build/debug/netdisplay-sender listen --debug-raw \
    [--width 2560 --height 1600 --scale 1 --fps 60 --bitrate 40]
ffplay -fflags nobuffer -flags low_delay -f h264 tcp://127.0.0.1:47801

# 中转模式（连 15 服务器，打印 6 位配对码）
./.build/debug/netdisplay-sender relay [--server 15.tokencv.com:47700] [--bitrate 10]

# 调试环境变量
NETDISPLAY_STATS=1        # 每秒打印 captured/encoded 帧率 + 捕获回调状态
NETDISPLAY_CAPTURE_MAIN=1 # 调试用：改抓主屏（验证管线，不建议常用）
```

Ctrl-C（SIGINT）干净退出：会销毁虚拟屏，无残留（已验证退出后在线显示器回到 1 个）。

## M1 验收结果（全部通过）

1. ✅ `listen --debug-raw` 立即创建虚拟屏；`system_profiler` 显示 `NetDisplay 1280x800@60`（默认 2560×1600 同理，尺寸参数化）。
2. ✅ 系统「显示器」出现虚拟屏，可把窗口拖过去（用 TextEdit 移到虚拟屏区域验证）。
3. ✅ `ffmpeg -f h264 tcp://127.0.0.1:47801` 抓到有效 H.264：**144 帧解码成功，1280×800 yuv420p，exit 0**。
4. ✅ 虚拟屏上有内容变化时流畅推流（687 KB/3s，NAL 结构 `SPS,PPS,IDR,P,P…` 正确）。
5. ✅ Ctrl-C 退出后虚拟屏消失、无残留。
6. ⏳ 10 分钟稳定性 / 内存未做长时压测（管线稳定，留待联调期观察）。

**真实协议路径也已用 Python 客户端验证通过**（`/tmp/proto_client.py`，见下「给 Windows 端的联调事实」）。

## 给 Windows 端 Claude 的联调事实（请据此实现 Receiver / Relay，已实测）

Mac 端严格按 `02-protocol.md` 实现，以下是已验证的确切行为，**Receiver 必须匹配**：

1. **连接与握手**：TCP 建立后 Mac 端**立即发送 Sender HELLO**（不等你）。你也应立即发 Receiver HELLO。
   - 实测 Sender HELLO：`{"version":1,"role":"sender","name":"<hostname>","deviceId":"<uuid>"}`。
   - Mac 端收到你的 HELLO 后按 `screen.width/height/scale` 建虚拟屏，回 **HELLO_ACK**：
     `{"version":1,"accepted":true,"display":{"width":W,"height":H,"fps":F},"codec":"h264"}`。
     以 `display` 为准配置解码器（Mac 可能把 fps 夹到 30–60、把宽高按 `& ~1` 取偶）。
2. **VIDEO_FRAME（0x10）载荷**：`[pts_us u64 BE][flags u8][Annex-B]`。
   - **第一个 VIDEO_FRAME 一定是关键帧**（flags bit0=1），且 **Annex-B 以 SPS(NAL type 7)、PPS(8)、IDR(5) 开头**（实测首帧 firstNAL=0x07，223 KB）。
   - pts 单调递增、微秒、起点归一化为 0（实测 0, 16666, 33333…）。
   - 你按协议：`codec:"avc1.640033"`（High@AutoLevel）、`optimizeForLatency:true`、**不设 description**（Annex-B 模式）即可零转换喂 WebCodecs。
3. **关键帧策略**：编码器 2 秒一个 IDR，且**新连接/收到 REQUEST_KEYFRAME(0x11) 会强制关键帧**。重连后请发 0x11。
4. **PING/PONG**：你发 PING(0x30, 8 字节)，Mac 原样回显 PONG(0x31)（实测回显一致）。
5. **裸流调试口 :47801** 仅 debug，无协议头，别把它当正式口。正式直连口是 **:47800**。
6. **中转模式**：Mac 端作为 sender 连 relay 发 `RELAY_REGISTER {"v":1,"role":"sender","code":"6位","pairHash":null}`，
   收到 `RELAY_PAIRED {"ok":true}` 后**立即发 Sender HELLO**，之后与直连完全一致。
   你作为 receiver 发 `RELAY_JOIN`，撮合后同样收 RELAY_PAIRED 再发 HELLO。
   → **Relay 只需按 `05-relay-server.md` 的 Go 单文件部署即可，Mac 端已按 §7 对接。**

## 已知坑 / 与 macOS 26 相关

- **✅ 虚拟屏销毁（已解决，macOS 26 关键坑）**：曾以为 macOS 26.5.1 无法销毁虚拟屏——单独 release/apply 空 modes/
  RestorePermanentConfig 全部无效，进程退出也不回收，累积幽灵屏。**根因与解法来自 Chromium
  `ui/display/mac/test/virtual_display_util_mac.mm`**：macOS 是**异步**移除虚拟屏的，且**「进程内第一次单独移除有已知超时/失败」**，
  必须**同时移除第二块屏**才能可靠触发（Chromium 的 `g_need_display_removal_workaround`）。
  - 解法 `VirtualDisplay.reap()`：临时再建一块 throwaway 屏，**两块一起 release**，再轮询 `CGGetOnlineDisplayList` 等确认移除。
    实测 vd-demo/SIGINT 均**净零泄漏**（online 回到 1，`removed=true`）。opendisplay 只 `= nil` 无配对、无等待，正是漏在这。
  - 已接入 Ctrl-C(`StreamPipeline.stop`) 和 demo 退出路径。之前调试累积的 8 块幽灵屏也已清干净。
- **私有 API `applySettings` 偶发失败**：多因存在未回收的「僵尸/幽灵」虚拟屏且 vendor/product/**serial 冲突**。
  已改为**先稳定 serial(设备哈希)、失败回退随机 serial** + apply 重试，规避。正常单实例不受影响。
- **虚拟屏创建后由持续 enforcement 循环稳住**（每 200ms→稳定后 2s，贯穿生命周期）：重选 mode(1x/HiDPI 通用)、
  解除 mirror、前 6s 归位到主屏右侧。缺这个循环 macOS 会几秒内把屏回退到 1x/改排列/丢给 SCK（旧版只跑 6s 是不够的）。
- **空虚拟屏不产帧**：ScreenCaptureKit 对「无内容变化」的虚拟屏不回调（连初始帧都可能没有），
  一旦有窗口/光标/内容变化即正常出帧。这是 SCK 行为，非 bug；Receiver 端保留上一帧即可。
- **SCK 偶发 `Failed to find any displays…`**：已加捕获自动重启（退避重试 10 次）。
- 捕获回调状态需过滤：只处理 `status==complete(0)`，`idle(1)` 帧无有效 surface。

## 协议疑问 / 修改提案

- 暂无需要改协议之处。一个小建议（**非阻塞**）：裸流/新连接加入时，Sender 目前靠「强制关键帧」让新加入者尽快解码；
  若 Receiver 端偶见开头 1–2 帧 `non-existing PPS`（中途加入 GOP 所致），等下一个关键帧即恢复，属正常。

## 下一步（M2，Windows 端）

按 `04-windows-receiver.md`：Electron + WebCodecs 直连 :47800，全屏渲染。先用你的
Node 最小客户端联调（把联调脚本记到 `91-windows-progress.md`）。Mac 端随时可 `listen` 待命。
