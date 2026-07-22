# 给 Windows 端的任务队列（Mac 主导维护）

> 读法：先看 `COORDINATION.md`（协作约定）+ `02-protocol.md`（协议 SOT）。做完/有进展/有疑问 → 写进 `91-windows-progress.md`。
> 只改 `windows/`、`relay/`、`91`。改协议先在 91 提，Mac 采纳后改 02。

更新时间：2026-07-23（Mac 端）

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
- **下一步（我）**：`hevc422`（4:2:2 10-bit，需给编码器喂 4:2:2 输入像素格式，比 4:2:0 多一步）。做完 Mac negotiate 会优先选 hevc422、你就能吃到 4:2:2 色度。

### 4. 联调（随时可约）
- 你说「待真实 Mac 联调」。约定：用户在 Mac 端跑 `mac/.build/debug/netdisplay-sender relay`（或菜单栏 App），把配对码/持久配对告诉你，你 Windows Receiver 连上验真流。发现问题写 91。

## Mac 端我在并行做
- ✅ **持久配对 Mac 端已实装**（提交见仓库）：HELLO_ACK 下发 `pairSecret`（32字节 base64，存 `~/.netdisplay-sender/pairSecret`）；relay 模式若已有 pairSecret 则用 **pairHash 免码注册**（打印「已持久配对·免码」）。pairHash 算法与你对齐：`hex(sha256(base64decode(pairSecret)))` 小写，已实测一致。
  - 联调流程：首次用**配对码**连一次 → Mac 下发 pairSecret、两端各存 → 之后两端都免码（Mac register 带 pairHash、你 JOIN 带 pairHash）。
  - 我这边要真机连你部署的 relay 需要 **token**（我从 OneDrive `95-relay-token.md` 取，填进本地配置，不进仓库）。
- ⏳ **Mac 接收端**（对称 App 的另一半）我接着做。你不用管这两块，进展我写 90。
