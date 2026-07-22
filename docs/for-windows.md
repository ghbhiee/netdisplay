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

### 2. 【大件·对称 App】Windows 发送端（Sender）
目标：让 Windows 也能**发送**（抓屏/窗口 → 编码 → 按协议发），这样两端对称、任意方向投射。
- **线上协议必须与 `mac/` 的发送端完全一致**（这样 Mac 接收端能解）。参考 `mac/Sources/netdisplay-sender/`：`Session.swift`（HELLO/HELLO_ACK/VIDEO_FRAME/VIDEO_CONFIG/PROJECTION_STATE/CONTROL/PING 流程）、`Encoder.swift`（H.264 Annex-B、关键帧内联 SPS/PPS）、`Wire.swift`（帧格式/JSON 模型）、`RelayClient.swift`（中转注册/配对/token）。
- Windows 平台实现建议：**Windows.Graphics.Capture**（抓屏/窗口）+ **Media Foundation 硬件 H.264**（或先用 ffmpeg 起步）。输出必须是 **Annex-B、关键帧带 SPS/PPS、一帧一个 VIDEO_FRAME**（见 02 §4）。
- 作为 Sender 角色：连上后发 `HELLO{role:"sender"}`、收 Receiver 的 HELLO 后回 `HELLO_ACK{display,codec}`、推 VIDEO_FRAME（首帧关键帧）、响应 `REQUEST_KEYFRAME`、回 `PONG`；直连监听 47800 / 中转 REGISTER（带 token/pairHash）。
- 单窗口投射、resize→VIDEO_CONFIG、扩展屏/舞台等交互是 Mac 端先行的形态，你可**先做「整屏发送」MVP**，窗口/舞台后续对齐。
- **先在 91 里回一版你的实现计划**（平台 API 选型 + 里程碑），我 review 后你再动手，避免走偏。

### 3. HEVC codec 取舍（承接 93）
- 已知：Mac(M5) 编不了 HEVC 4:4:4，最好 **HEVC 4:2:2 10-bit(Rext)**。请定：
  - A：只上 HEVC 4:2:0（"hevc"，省带宽，色度不变）；或 B：加 `"hevc422"`（需你 `isConfigSupported` 实测 WebCodecs 能解 **HEVC Rext Main 4:2:2 10-bit**）。
  - 把结论 + 4:2:2 能否解写进 91。定了我这边实装 Mac 编码器。

### 4. 联调（随时可约）
- 你说「待真实 Mac 联调」。约定：用户在 Mac 端跑 `mac/.build/debug/netdisplay-sender relay`（或菜单栏 App），把配对码/持久配对告诉你，你 Windows Receiver 连上验真流。发现问题写 91。

## Mac 端我在并行做
- ✅ **持久配对 Mac 端已实装**（提交见仓库）：HELLO_ACK 下发 `pairSecret`（32字节 base64，存 `~/.netdisplay-sender/pairSecret`）；relay 模式若已有 pairSecret 则用 **pairHash 免码注册**（打印「已持久配对·免码」）。pairHash 算法与你对齐：`hex(sha256(base64decode(pairSecret)))` 小写，已实测一致。
  - 联调流程：首次用**配对码**连一次 → Mac 下发 pairSecret、两端各存 → 之后两端都免码（Mac register 带 pairHash、你 JOIN 带 pairHash）。
  - 我这边要真机连你部署的 relay 需要 **token**（我从 OneDrive `95-relay-token.md` 取，填进本地配置，不进仓库）。
- ⏳ **Mac 接收端**（对称 App 的另一半）我接着做。你不用管这两块，进展我写 90。
