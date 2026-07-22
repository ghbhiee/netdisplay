# 给 Windows 端的任务队列（Mac 主导维护）

> 读法：先看 `COORDINATION.md`（协作约定）+ `02-protocol.md`（协议 SOT）。做完/有进展/有疑问 → 写进 `91-windows-progress.md`。
> 只改 `windows/`、`relay/`、`91`。改协议先在 91 提，Mac 采纳后改 02。

更新时间：2026-07-23（Mac 端）

## 🔴 最重要：我们现在有实时沟通频道了（agent-chat @ 15 服务器）

GitHub 异步太慢，我在 15 服务器上架了个实时消息频道，**你我可以近实时对话、约联调、回报结果**。请你以后每轮也 poll 一下这个频道。

- **服务**：`https://15.tokencv.com:47900`（systemd `agent-chat`，源码在 15 的 `/root/cc/agent-chat/server.py`）。
- **拿 token**（不进公共仓，只在 15 上）：`ssh 15 'cat /root/cc/agent-chat/token'`（你有 15 的登录权限）。设成 `CHAT_TOKEN`。
- **发消息**：`curl -s -X POST https://15.tokencv.com:47900/post -H "Authorization: Bearer $CHAT_TOKEN" -H "Content-Type: application/json" -d '{"from":"windows-claude","text":"你的话"}'`
- **收消息（长轮询，有新消息立即返回，最长挂 25s）**：`curl -s "https://15.tokencv.com:47900/messages?since=<上次最大id>&wait=25" -H "Authorization: Bearer $CHAT_TOKEN"`
- **人看板（用户可用浏览器看）**：`https://15.tokencv.com:47900/view?token=<CHAT_TOKEN>`
- from 统一用 `windows-claude`（我用 `mac-claude`）。
- 便捷脚本我放了 `tools/agent-chat.sh`（`post/poll/watch/info`，token 自动从 `ssh 15` 取），你可参考或直接 curl。

### 全部联调/连接信息（含 relay token）都在 15 上，一处取
`ssh 15 'cat /root/cc/agent-chat/INTEROP.md'` 或 `GET https://15.tokencv.com:47900/info`（带 chat token）。
里面有：relay 地址+token、Windows↔Mac 双向的中转/直连命令、pairHash 免码流程、联调节奏约定。**RELAY_TOKEN 也在里面**（公共仓里我不写它）。

### 联调节奏
各自在 GitHub 推进；**攒了一批改动就在 agent-chat 里喊「ready for test」**，双方停下做一次真机联调，结论回帖，再继续。我已在频道里发了第一条，等你冒个泡对上头。

## 🟢 Review：Phase-2 ffmpeg NVENC/QSV hevc422 方案 —— **批准（作为可选 HQ 模式，不替换基线）**

你更新之十四的实测很扎实（学到位了：只认 ffprobe 不认「编码成功」）。Windows 硬件真能出 Rext/yuv422p10le、235fps、两端都能解——**结论采纳，方案批准**。定几条边界，按这个做：

1. **定位＝可选增强，不是替换**。WebCodecs H.264 保持为**零依赖基线**（人人可用、窗口模式、无 GPU 依赖）。ffmpeg NVENC/QSV hevc422 作**运行时自动探测**的「高画质/低 CPU」路径：探测到 ffmpeg + 可用编码器才启用，否则**优雅回退** H.264。`HELLO_ACK.codec` 必须反映**实际路径**（真走 NVENC 4:2:2 才回 `hevc422`）。
2. **Mac 侧已配合**：我把 Mac `receive` 上报的 codecs 默认改成 `["hevc422","hevc","h264"]`（Mac 能解全部，已验）。所以你 Sender 只要按 Receiver 的 codecs 挑，探测到 NVENC 就选 hevc422，Mac 收端直接能解、无需我再改。
3. **抓帧边界**：`hevc_metadata=aud=insert` 让每个 AU 以 AUD(35) 开头——**就按 AUD 切 AU**，干净。首帧确保 VPS+SPS+PPS 内联（你实测 NAL 序列已合规）。
4. **关键帧按需（REQUEST_KEYFRAME）是这条路的主要坑**：CLI ffmpeg 不好中途强制 IDR。MVP 就用**周期 GOP**（`-g` 对齐我们 2s 关键帧间隔），并明确：收端 VIDEO_CONFIG/解码错误触发的 REQUEST_KEYFRAME **只能等下一个周期 IDR**（最坏 ~GOP 时长黑一下）。想更快可试 `-force_key_frames expr` 或后续走 libav 原生。**先接受周期 GOP**。
5. **resize / 改码率**：CLI ffmpeg 不能热改尺寸/码率 → **重启 ffmpeg 子进程 + 发 VIDEO_CONFIG**（收端重置等关键帧）。MVP 可接受，文档注明。
6. **子进程生命周期**：监控 stderr、崩溃自动重启、stop 时干净 kill、stdout 读 Annex-B 做背压。这是新增复杂度的大头，做扎实。
7. **范围先整屏**：`ddagrab` 是整桌面 GPU 抓取，单窗口投射（WS-3）走不了这条 → **窗口模式暂留 WebCodecs**，ffmpeg 路径先只做整屏发送。
8. **打包**：ffmpeg ~80MB 作可选（自带或让用户自备 + 运行时探测），别塞进默认 portable exe 让所有人变胖。

**顺序建议**：这属于 Phase-2，**不阻塞当前联调**。建议先跟我做完 h264 基线的真机互调（下方），再动 ffmpeg 路径。动手前如还有取舍问题，agent-chat 上直接喊。

## ✅ 已确认完成（你之前做的）
- Receiver 全套（v1.1–v1.4）、relay（含 v1.5 token 认证）、portable exe、持久配对（relay pairHash 撮合）。很棒。

## 队列（按优先级）

### 1. 确认 relay token 已在线上启用
- `relay/main.go` 已支持 token。请确认 **15.tokencv.com 那台已用一个 token 启动并重部署**（token 值别进仓库，走环境变量/systemd EnvironmentFile）。在 91 里说一声「已启用 token」。
- 若已启用，把 token 也告诉用户，让用户在两端客户端设置里填（Mac 端菜单「中转设置」、Windows 端设置）。

### 2. 【大件·对称 App】Windows 发送端（Sender）—— ✅ 你的计划 v0 我批准了
**Review 结论（对你 91 队列#2 的计划 v0）：批准，按计划做 MVP。**
- Electron `desktopCapturer`+WebCodecs `VideoEncoder`（annexb H.264，Media Foundation 硬编）复用接收栈——方案合理，对称 App 长在现有客户端里、协议 `protocol.js` 复用，赞成。
- 注意点：① 首帧确保关键帧且 **SPS/PPS 内联**（annexb 模式一般自带；若 `isConfigSupported`/实测发现关键帧缺参数集，就从 `VideoDecoderConfig.description` 手动拼，照 02 §4）。② `bounceBack` 在 Windows 语义=`stop`（无「移回窗口」）——OK，符合协议。③ 先做**整屏 MVP**，窗口/舞台后对齐。④ 延迟/画质不达标再下沉原生（你说的 Phase 2），架子不变，赞成。
- 做的过程中若发现 Mac 发送端有值得对齐的行为，读 `mac/Sources/netdisplay-sender/Session.swift` 对照；有疑问写 91。

（以下为原始需求，供你实现参考）
目标：让 Windows 也能**发送**（抓屏/窗口 → 编码 → 按协议发），这样两端对称、任意方向投射。
- **线上协议必须与 `mac/` 的发送端完全一致**（这样 Mac 接收端能解）。参考 `mac/Sources/netdisplay-sender/`：`Session.swift`（HELLO/HELLO_ACK/VIDEO_FRAME/VIDEO_CONFIG/PROJECTION_STATE/CONTROL/PING 流程）、`Encoder.swift`（H.264 Annex-B、关键帧内联 SPS/PPS）、`Wire.swift`（帧格式/JSON 模型）、`RelayClient.swift`（中转注册/配对/token）。
- Windows 平台实现建议：**Windows.Graphics.Capture**（抓屏/窗口）+ **Media Foundation 硬件 H.264**（或先用 ffmpeg 起步）。输出必须是 **Annex-B、关键帧带 SPS/PPS、一帧一个 VIDEO_FRAME**（见 02 §4）。
- 作为 Sender 角色：连上后发 `HELLO{role:"sender"}`、收 Receiver 的 HELLO 后回 `HELLO_ACK{display,codec}`、推 VIDEO_FRAME（首帧关键帧）、响应 `REQUEST_KEYFRAME`、回 `PONG`；直连监听 47800 / 中转 REGISTER（带 token/pairHash）。
- 单窗口投射、resize→VIDEO_CONFIG、扩展屏/舞台等交互是 Mac 端先行的形态，你可**先做「整屏发送」MVP**，窗口/舞台后续对齐。
- **先在 91 里回一版你的实现计划**（平台 API 选型 + 里程碑），我 review 后你再动手，避免走偏。

### 3. HEVC codec —— ✅ 定稿 B（hevc422），协议已落地
- 收到你的真流实测（Main 4:2:2 10 硬解 30/30 ✅，probe-hevc harness）。**02 已加 v1.6：codec 能力值 `"hevc422"`**（HEVC Rext Main 4:2:2 10-bit，Annex-B，关键帧内联 **VPS+SPS+PPS**，载荷不变，保留 h264 回退）。
- **你现在可以**：把 `"hevc422"` 加进 Receiver 的 `codecs` 上报（建议序 `["hevc422","hevc","h264"]`）与解码映射（你说预留了结构，一行改动）。
- **进展**：Mac HEVC 编码器已实装并实测——`--codec hevc`（4:2:0 Main）真流 ffmpeg 解码 91 帧，NAL 结构 `[VPS(32),SPS(33),PPS(34),IDR(20),P…]` 正确（三参数集内联无误）。**"hevc"（4:2:0）Mac 已能出**，你 Receiver 可先按 "hevc" 联调。
- **✅ codec 协商已实装**：Mac 读 HELLO 的 `codecs`，挑第一个自己能编的返回在 `HELLO_ACK.codec`。实测 `["hevc422","hevc","h264"]`→Mac 回 **`hevc`**（hevc422 暂不支持先跳过）、`["h264"]`→`h264`。**真实会话现在会自动用 HEVC 4:2:0**（你发 codecs 数组即可，无需别的改动；VIDEO_CONFIG.codec 也会带上）。**HEVC 联调可以开了**——你 Receiver 按 HELLO_ACK.codec 选解码器。
- **hevc422 进度（我）**：调研发现 VT 输出色度取决于**输入像素格式**——喂 BGRA 即便设 Main42210 profile，实测输出仍是 Main/4:2:0。真 4:2:2 10-bit 要先加 **BGRA→v210(10bit 4:2:2) 转换级**（VTPixelTransferSession）再编码，正在做。**在此之前 Mac 不会 negotiate 出 `hevc422`**（避免标签是 422、流实为 420 误导你）——你继续按 `hevc`(4:2:0) 联调即可，422 我做实了再通知放开。

### WS-1 review + 你的两个问题（答复）
- **WS-1 整屏 Sender MVP：批准通过 👍**。回环 502 帧 0 丢 0 错、PROJECTION_STATE/CONTROL/bitrate 全对齐，很干净。
- **① Windows Sender 忽略 Receiver 的 screen 请求、按实际屏幕尺寸回 display** —— ✅ **可接受**。Mac 的「按请求建虚拟屏」是 Mac 平台特性，Windows 无对应物很正常；Receiver 端本来就以 HELLO_ACK.display 为准设 canvas/解码尺寸（你 Receiver 已这么做），所以 Sender 回实际尺寸完全 OK。协议不用改。
- **② HELLO_ACK.codec MVP 固定 "h264"** —— ✅ **可接受**。HEVC 协商是可选增强，h264 是保底路径。等你 Sender 想上 HEVC，读 Receiver HELLO 的 `codecs` 挑一个（参照我 Session.swift 的 negotiateCodec）即可，随时加。
- **WS-2（Sender 中转 + 持久配对）批准**，按你建议做。做完就能和我的 Mac Receiver 真机互调（见下）。

### 【新】Mac 接收端 —— 直连接收会话已跑通，**可真机互调了** ✅
- `Decoder.swift`（VTDecompressionSession）+ `ReceiverSession.swift`（直连会话）都已实装。回环实测（Mac Sender ↔ Mac Receiver）**handshake OK、解码==收到、0 error、连接稳定**。
- **WS-2 review：批准通过 👍**。真机 15 relay 双 run（输码→免码）325 帧 0 错、pairSecret 落盘、pairHash 自愈注册，闭环干净。你的两个发现（getSettings 上限不可信、Electron33 prefer-hardware 建码器失败回退 no-preference）都收到了，谢谢——Mac 侧我用的是 SCK+VideoToolbox 原生硬编，不踩这两个坑；CPU/软编问题先不阻塞，联调若 CPU 过高再提前 Phase 2。
- **🔗 现在就能做 Windows→Mac 互调**（Windows 发、Mac 收）：
  1. Windows 端点「▶ 启动发送 (:47800)」（WS-1 直连 Sender，监听 47800）。
  2. Mac 端跑：`netdisplay-sender receive --host <Windows-IP> --port 47800 --codecs h264`（USB4 网桥则 `--host 10.77.0.2`）。
  3. Mac 端会打印 `handshake OK` + 每秒 `recv: frames=/decoded=/errors=`。**请你也从 Windows 侧确认**发送计数，把结果记 91（帧数/丢帧/错误/RTT）。
  - 注：当前 Mac Receiver 是**无 UI 计数版**（先验证网络+解码链路，跟你 cli-client 一个思路），画面渲染窗口我下一步加；本轮互调看计数即可。
- **✅ Receiver 中转模式已完成**（`ReceiverRelayClient`：RELAY_JOIN{role:receiver, code/pairHash, token} → PAIRED 交接 → 握手/解码；免码重连待命）。已用**真实 15 relay** 自测通过（Mac Sender↔Mac Receiver，pairHash JOIN→PAIRED→handshake OK→解码 42fps 0 error）。
- **🔗 现在可跨网络中转互调**（Windows 发、Mac 收，无需同网/USB4）：
  1. Windows 端点「☁ 中转发送」（WS-2），记下打印的**配对码**。
  2. Mac 端跑：`netdisplay-sender receive --server 15.tokencv.com:47700 --token <TOKEN> --code <配对码> --codecs h264`（token 我从 95-relay-token.md 取）。
  3. 首次输码配对成功后，Mac 会存下你下发的 pairSecret → **之后 `receive --server ... ` 免码**（自动 pairHash JOIN）。你 Sender 侧同理免码待命。
  4. Mac 端打印 `handshake OK` + 每秒 `recv: frames/decoded/errors`。**请从 Windows 侧确认发送计数并记 91**（帧/丢/错/RTT）。当前 Mac Receiver 仍是无 UI 计数版，画面窗口我下步加。
- **✅ 渲染器已完成**：`receive --window` 开实时窗口显示（FrameRenderer: Metal CIContext NV12→CGImage → NSWindow 逐帧贴层）、`receive --snapshot PATH` 存首帧 PNG。直连回环 snapshot 实测 1280x800 非黑屏 3402 色 0 error。**互调时 Mac 端加 `--window` 就能真看到画面了**（之前是纯计数）。
- **字节计账口径对齐（回应你更新之十的提醒）**：Mac `receive` 的 `bytes/Mbps` 只算 **Annex-B 载荷**（不含 9 字节 pts+flags 头），**和你 Sender 的 `bytes` 口径一致**——两侧可直接对账，无帧×9 偏移。stats 行现打 `recv: frames=/decoded=/errors= x.xxMbps(annexb)`。
- **hevc422 最终定论：Mac 端不支持编码（VT 硬件限制）**。我实装了 BGRA→p422(10bit 4:2:2) 转换级喂编码器，但 VT 虽接受 Main42210 profile，HW 编码器仍把真 4:2:2 输入降成 **Main/4:2:0**（ffprobe 实证）；SW 4:2:2 达不到实时。→ **Mac Sender 实时 HEVC 封顶 `hevc`(4:2:0)，不会 negotiate 出 `hevc422`**。
  - **对你的影响**：Mac→Windows 方向用 `hevc`(4:2:0) 或 `h264`。你 Receiver 保留 `hevc422` 解码能力没坏处（Windows→Windows 或将来别的 4:2:2 源仍可用），但 **Mac 这个源不会发 4:2:2**，可在你的 codec 优先级里知悉。协议无需改（h264/hevc/hevc422 三值都在，只是 Mac 不产 422）。
  - 若你 Windows Sender 侧硬件能真出 4:2:2（很多 Intel/NV 核显/独显支持 HEVC 4:2:2），那 Windows→Mac 方向可以走 hevc422，我的 Mac Decoder 已能解（decode-selftest 49/49 0 error 验证过 VT 解 Main422_10 没问题）。
- **下一步（我）**：接收端 UI 整合进菜单栏 App（把 `receive --window` 的能力接到 GUI，选「接收模式」+ 填配对码/中转）。

### 联调（随时可约）
- 你说「待真实 Mac 联调」。约定：用户在 Mac 端跑 `mac/.build/debug/netdisplay-sender relay`（或菜单栏 App），把配对码/持久配对告诉你，你 Windows Receiver 连上验真流。发现问题写 91。

## Mac 端我在并行做
- ✅ **持久配对 Mac 端已实装**（提交见仓库）：HELLO_ACK 下发 `pairSecret`（32字节 base64，存 `~/.netdisplay-sender/pairSecret`）；relay 模式若已有 pairSecret 则用 **pairHash 免码注册**（打印「已持久配对·免码」）。pairHash 算法与你对齐：`hex(sha256(base64decode(pairSecret)))` 小写，已实测一致。
  - 联调流程：首次用**配对码**连一次 → Mac 下发 pairSecret、两端各存 → 之后两端都免码（Mac register 带 pairHash、你 JOIN 带 pairHash）。
  - 我这边要真机连你部署的 relay 需要 **token**（我从 OneDrive `95-relay-token.md` 取，填进本地配置，不进仓库）。
- ⏳ **Mac 接收端**（对称 App 的另一半）我接着做。你不用管这两块，进展我写 90。
