---
date: 2026-07-21
tags: [netdisplay, handoff, protocol, spec]
---

# NetDisplay 线上协议规范 v1

> **本文档是两端互通的唯一依据（source of truth）。**
> 修改协议必须先改这里并在下方 changelog 记录，再改代码。
>
> Changelog:
> - 2026-07-23 v1.13 **连通性探测 `PROBE`(0x46)/`PROBE_ACK`(0x47)（§3.8, docs/11 §2）**：UI 显示「当前直连/中转哪条通」，优先直连。**直连判据 = 收到对端 PROBE_ACK，不是 TCP connect 成功**（Clash TUN 会对不可达地址假成功，两端老坑）。两端在 47800 常驻一个轻量探测响应器：收到 PROBE(8 字节随机回显) 立即原样回 PROBE_ACK，无需会话状态，与直连投射会话共存（先读一帧，PROBE 就回 ACK、HELLO 就进会话）。设了对方 IP 才探直连；没设不探不显示。中转探测=自配对随机房收 RELAY_PAIRED。显示优先级：直连通→「直连·通 Xms」，否则中转结果。两端判据必须一字不差。（Mac 端 Claude，用户要求；Windows 待实装）
> - 2026-07-23 v1.12 **双向配对撮合 `PAIR_ANNOUNCE`(0x44)/`PAIR_CONFIRMED`(0x45)**（docs/11）：让「已配对」名副其实——只有**另一台也用同一个码连上**才算配对成功，不是各自本地存码/只探测中转。两端配对时各发 `PAIR_ANNOUNCE{v,pairHash,deviceId,name,token}`；relay 按 pairHash 暂存(TTL 2min)，见到**同 pairHash、不同 deviceId** 的第二个 announce → 给双方各发 `PAIR_CONFIRMED{peerDeviceId,peerName}` 并在内存记录该对；**同 deviceId 去重、绝不自撮合**；token 校验同 REGISTER/JOIN。谁先发起都行。已部署 15 并双客户端实测通过。（Mac 端 Claude，用户要求）
> - 2026-07-23 v1.11 **配对码升级为 6 位字母+数字（§3.7）**：旧版 6 位纯数字（1M）太弱 → 6 位大小写不敏感字母+数字（31^6≈887M）。派生前先 `normalize`（转大写+仅留 [A-Z0-9]）再走原 §3.7 哈希；自检向量更新为 code `"K7M2QX"`。生成用无歧义字符集 `ABCDEFGHJKMNPQRSTUVWXYZ23456789`。**随之废弃 §3.7「code_not_found→明文码回退」那条交接兼容**：码格式一变，老 0.3.0 的 6 位纯数字明文房永远对不上，回退已无意义（两端确认都上新版）。（Mac 端 Claude，用户要求）
> - 2026-07-23 v1.10 **`name` 语义改为「用户可编辑的设备名」（§3.6）+ 配对码→房间推导（§3.7）**：`name` 那条线格式不变、老端兼容；§3.7 是新界面「两端输入同一个码」带来的**硬性互通约定**，推导算法差一字节就会各自进不同房间且两边日志都正常，务必按自检向量对一遍。（Windows 端 Claude）
> - 2026-07-21 v1 初版（Windows 端 Claude 起草）
> - 2026-07-22 v1.9 **HELLO 增加可选 `lanAddrs` + 连接升级（§3.5）**：配合 UX 重做（transport 是程序探测的**状态**、不是用户选的「直连/中转」，见 docs/10-ux-model.md 与 20-design-handoff.md）。两端 HELLO 互告各自局域网可直连地址（含 :47800 监听口）；即便走中转连上，也在后台试直连、握手成功则无感切过去。**升级只在「待命」时做、投射中不切链路**（MVP）。**判据是收到对端 HELLO/HELLO_ACK，不是 TCP connect 成功**（TUN 代理会骗）。老端忽略 `lanAddrs`，天然兼容。（Mac 端 Claude，承接 Windows #88 提案，两端已定 A）
> - 2026-07-22 v1.1 HELLO_ACK.display 增加**可选 `scale` 字段**（HiDPI 因子）；明确 **Sender 可覆盖 Receiver 请求的分辨率/缩放**，Receiver 一律以 HELLO_ACK.display 为唯一权威尺寸。向后兼容（老 Receiver 忽略 scale 即可）。（Mac 端 Claude）
> - 2026-07-22 v1.2 HELLO.screen 增加**可选 `bitrateMbps` 字段**（Receiver 期望码率，Mbps 整数）：Sender 可采纳、可用 `--bitrate` 覆盖、也可忽略（老 Sender 的 JSON 解码会跳过未知字段，天然兼容）。用途：Receiver 设置界面里让用户调码率，重连生效。（Windows 端 Claude）
> - 2026-07-22 v1.3 **codec 协商**（Receiver 端已实现，Sender 待实装，未实装时行为不变）：Receiver HELLO 增加可选顶层 **`codecs`** 数组——按偏好排序的解码能力，取值 `"hevc444"`（HEVC Rext Main 4:4:4）/`"hevc"`（HEVC Main 4:2:0）/`"h264"`。Sender 从中挑选并在 HELLO_ACK 的 `codec` 字段返回（原值 `"h264"` 扩展为可回 `"hevc"`/`"hevc444"`）；VIDEO_FRAME 载荷格式不变（HEVC 同样 Annex-B，关键帧内联 VPS/SPS/PPS）。VIDEO_CONFIG 的 `codec` 同步扩展。老 Sender 忽略 `codecs` 回 `"h264"`，天然兼容。依据：Windows 端实测硬解支持 HEVC Rext 4:4:4（见 91）。（Windows 端 Claude）
> - 2026-07-23 v1.8 **JSON 兼容性通用规则 + VIDEO_CONFIG 字段必需/可选定明**：§0 加通用规则「接收方必须容忍未知字段与缺失可选字段，不得整条丢弃」（承接 v1.7 那个 bug 的根本预防，适用所有 JSON 消息）；§5 定明 VIDEO_CONFIG 必需=codec/width/height、可选=fps/bitrateMbps（缺省=不变）。Mac 端 fps 也已改可选。（Mac 端 Claude，Windows 端提议）
> - 2026-07-23 v1.7 **VIDEO_CONFIG.bitrateMbps 明确为可选**：接收端 JSON 模型必须把它设为 optional，否则收到不带该字段的 VIDEO_CONFIG(Windows Sender 不发)会解码失败并静默丢弃，中途 resize 跟不上（Mac 端已踩坑修复；见 §5）。（Mac 端 Claude）
> - 2026-07-23 v1.6 **codec `"hevc422"`**（承接 v1.3；Windows 实测硬解通过，Mac 编码器待实装）：`codecs`/`HELLO_ACK.codec`/`VIDEO_CONFIG.codec` 新增能力值 **`"hevc422"`** = HEVC Rext **Main 4:2:2 10-bit**（Windows 端 codec string `hev1.4.10.*`）。这是 Mac(M5 VideoToolbox) 硬编能到的最佳色度（**编不了 4:4:4**，见 90）。VIDEO_FRAME 载荷不变（Annex-B，**关键帧内联 VPS+SPS+PPS**，HEVC 三参数集）。协商必须**保留 `h264` 回退**（HEVC 无软解兜底）。偏好序建议 Receiver 上报 `["hevc422","hevc","h264"]`。（Mac 端 Claude）
> - 2026-07-23 v1.5 **Relay token 认证**（仓库转公开，防公网滥用）：`RELAY_REGISTER`/`RELAY_JOIN` 增加可选 `token` 字段；relay 校验 token（与其配置一致才受理，否则回 `RELAY_ERROR{"reason":"unauthorized"}` 并断开）。**客户端两端把 relay 地址 + token 做成可配置项**（不硬编码进仓库）。relay 未配置 token 时可放行（向后兼容/私网）。（Mac 端 Claude）
> - 2026-07-23 v1.4（**Mac 端提案，待 Windows 确认/实装**）：**连接与投射解耦**——配对一次、连接常驻、投射可随时开关/切换/弹回，详见 §10。新增 3 项：① **持久配对**（HELLO_ACK 下发 `pairSecret`，重连用 `pairHash=SHA256(pairSecret)` 自动撮合，免重输码；§5 原 M4 定义，现启用）；② **`PROJECTION_STATE(0x13, Sender→Receiver)`** 投射激活/空闲态（空闲时 Receiver **保留空白窗口**待下次用）；③ **`CONTROL(0x21, Receiver→Sender)`** 目标端控制（如「弹回窗口」按钮）。投射源切换沿用 VIDEO_CONFIG，**不断连**。（Mac 端 Claude）

## 0. 通用约定

- 所有多字节整数为**大端序（big-endian）**。
- 所有 JSON 载荷为 UTF-8 编码、无 BOM。
- **JSON 兼容性（v1.8，通用规则，适用于所有 JSON 消息 HELLO/HELLO_ACK/VIDEO_CONFIG/PROJECTION_STATE/…）**：接收方**必须容忍未知字段**（忽略）**与缺失的可选字段**（用默认/不变），**不得因为多一个或少一个字段就整条消息解码失败并丢弃**。反例即 2026-07-23 的真 bug：把 VIDEO_CONFIG 的可选字段声明为必需 → 对端不发 → 整条静默丢弃。以后每加新字段（如 hevc422、直连协商）都靠这条原则平滑演进。**推论：每个会改变状态或可能解析失败的分支都要留一行日志**，否则跨端排查只能靠复现和猜测。
- 所有 TCP 连接必须设置 `TCP_NODELAY`。
- 端口：Sender 直连监听 **TCP 47800**；调试裸流 **TCP 47801**；Relay **TCP 47700**。
- `PROTOCOL_VERSION = 1`。HELLO 交换时版本不一致则发 BYE 并断开。

## 1. 帧格式（Framing）

每条消息（本协议称"帧"）的线上格式：

```
+---------+------------------+----------------------+
| type    | length           | payload              |
| u8      | u32 big-endian   | length 字节           |
+---------+------------------+----------------------+
```

- `length` 是 payload 的字节数，不含 type 和 length 本身。
- payload 上限 16 MiB（`16*1024*1024`），超出视为协议错误，断开连接。
- 空 payload 的帧 `length = 0`。

## 2. 消息类型总表

| type | 名称 | 方向 | payload | 阶段 |
|---|---|---|---|---|
| 0x01 | HELLO | 双方→对方 | JSON | M1 |
| 0x02 | HELLO_ACK | Sender→Receiver | JSON | M1 |
| 0x10 | VIDEO_FRAME | Sender→Receiver | 二进制（见 §4） | M1 |
| 0x11 | REQUEST_KEYFRAME | Receiver→Sender | 空 | M2 |
| 0x12 | VIDEO_CONFIG | Sender→Receiver | JSON | M2 |
| 0x13 | PROJECTION_STATE | Sender→Receiver | JSON `{"active":bool,"label":string}` | v1.4 |
| 0x20 | INPUT_EVENT | Receiver→Sender | JSON | M4 |
| 0x21 | CONTROL | Receiver→Sender | JSON `{"action":string,...}` | v1.4 |
| 0x30 | PING | Receiver→Sender | 8 字节任意回显数据 | M2 |
| 0x31 | PONG | Sender→Receiver | 原样回显 PING 的 payload | M2 |
| 0x3F | BYE | 双方→对方 | JSON `{"reason": string}`，可空 | M1 |
| 0x40 | RELAY_REGISTER | Sender→Relay | JSON | M3 |
| 0x41 | RELAY_JOIN | Receiver→Relay | JSON | M3 |
| 0x42 | RELAY_PAIRED | Relay→双方 | JSON | M3 |
| 0x43 | RELAY_ERROR | Relay→任一方 | JSON `{"reason": string}` | M3 |
| 0x44 | PAIR_ANNOUNCE | Client→Relay | JSON `{v,pairHash,deviceId,name,token}` | v1.12 |
| 0x45 | PAIR_CONFIRMED | Relay→双方 | JSON `{peerDeviceId,peerName}` | v1.12 |
| 0x46 | PROBE | 探测方→对端:47800 | 8 字节随机数（回显用） | v1.13 |
| 0x47 | PROBE_ACK | 对端→探测方 | 原样回显 PROBE 的 8 字节 | v1.13 |

未知 type：**跳过该帧继续解析**（向前兼容），但应记日志。

## 3. 会话建立

### 3.1 直连模式

1. Receiver 拨号连接 Sender 的 `47800`。
2. TCP 建立后，**双方各自立即发送 HELLO**（不等对方，避免死锁）。
3. Sender 校验 Receiver 的 HELLO 后回 `HELLO_ACK`，随即按 ACK 中的参数创建虚拟屏并开始推 `VIDEO_FRAME`。
4. 第一个 VIDEO_FRAME 必须是关键帧（含 SPS/PPS）。

### 3.2 中转模式

1. Sender 拨号连接 relay `47700`，发送 `RELAY_REGISTER`。此时 Sender 在 UI/日志显示配对码。
2. Receiver 拨号连接 relay，发送 `RELAY_JOIN`（用户输入的配对码）。
3. Relay 撮合成功，向**双方**发送 `RELAY_PAIRED`，之后 relay 成为透明字节管道。
4. 双方收到 `RELAY_PAIRED` 后，进入与直连模式完全相同的流程（§3.1 第 2 步起）。

### 3.3 HELLO（0x01）

Receiver → Sender 的 HELLO：

```json
{
  "version": 1,
  "role": "receiver",
  "name": "LEGION-Y7000P",
  "deviceId": "uuid-字符串，首次运行随机生成并持久化",
  "screen": {
    "width": 2560,
    "height": 1600,
    "scale": 1,
    "fps": 60
  }
}
```

- `screen` 是 Receiver 显示器的期望画面尺寸（像素）。Sender 据此创建虚拟屏。
- `scale`：Receiver 端为 1；Sender 若创建 HiDPI 虚拟屏，编码输出仍是 `width×height` 物理像素。
- `bitrateMbps`（可选，v1.2）：Receiver 期望的编码码率（Mbps，整数）。Sender 可采纳；带 `--bitrate` 时以 Sender 为准；老版本 Sender 忽略此字段。

Sender → Receiver 的 HELLO：

```json
{
  "version": 1,
  "role": "sender",
  "name": "MacBook-Pro",
  "deviceId": "uuid"
}
```

- `lanAddrs`（可选，v1.9，**双向**都可带）：本机在局域网可被直连到的地址数组，如 `["192.168.1.20:47800","[fe80::1]:47800"]`（含直连监听端口）。用途：见 §3.5「连接升级」——即便当前这条 HELLO 是走**中转**连上的，两端也借此互告各自的内网地址，好在后台悄悄试**直连**。老端忽略此字段（§0 容忍规则），天然兼容。**不含任何隐私敏感信息，只是内网 IP。**

### 3.4 HELLO_ACK（0x02）

```json
{
  "version": 1,
  "accepted": true,
  "display": { "width": 2560, "height": 1600, "fps": 60, "scale": 2 },
  "codec": "h264",
  "pairSecret": "base64（可选，仅中转模式首次配对时下发，M4）"
}
```

- `display` 是 Sender 实际创建的虚拟屏/**编码像素尺寸**，**Receiver 一律以此为准**——因为 Sender 可以覆盖 Receiver 在 HELLO 里请求的分辨率/缩放（用户在 Sender 侧用 `--width/--height/--scale` 指定，或因硬件限制调整，如把 fps 降到 30）。
- `width`/`height` = **编码/串流的物理像素**（解码器按此配置，画面就是这么多像素）。
- `scale`（可选，v1.1 新增）= **HiDPI 因子**。逻辑点尺寸 = `width/scale × height/scale`。含义：Sender 让 macOS 按逻辑点渲染桌面（`scale=2` 时字/图标更大更舒适），但**编码输出仍是 `width×height` 物理像素、清晰不缩水**。
  - Receiver 全屏渲染：直接按 `width×height` 像素 1:1 画即可，`scale` 可忽略。
  - Receiver **窗口渲染**：建议按 `scale` 算出「逻辑窗口大小」并让 canvas 的**设备像素 = `width×height`**（在 Windows 高 DPI 下才不糊）。
- `accepted: false` 时附 `"reason"`，随后 Sender 发 BYE 断开。

> **给 Receiver 的分辨率/缩放控制**：想让用户在 Windows 端自选，可在 HELLO 的 `screen` 里发期望的 `width/height/scale`（Sender 默认按此建屏）；Sender 若带了 `--width/--height/--scale` 覆盖参数则以 Sender 为准，最终尺寸都在 HELLO_ACK.display 里回给你。

### 3.5 连接升级（中转 → 直连，v1.9）——transport 是状态不是用户选项

配套 UX 决策（docs/10-ux-model.md）：**用户永远只交换配对码，不选也不填「直连/中转」**；走哪条路由 app 探测决定、只做展示（「已连接·直连·3ms」/「已连接·中转·310ms」）。协议侧机制：

1. **先中转连上**（一定通），完成 HELLO/HELLO_ACK。两端 HELLO 里都带上 `lanAddrs`（§3.3）。
2. **后台试直连**：拿到对端 `lanAddrs` 后，在**不影响当前中转会话**的前提下，另起 socket 去 `dial` 对端每个 `lanAddrs`，成功 `connect` 后**必须收到对端的 HELLO/HELLO_ACK 才算这条路真通**——⚠️ 只凭 TCP `connect` 成功会被代理骗（Clash/Mihomo **TUN 透明代理**下连不可达地址也返回成功；这是两端实测的坑）。
3. **无感切换**：直连握手成功 → 把媒体流切到直连、拆掉中转的转发；失败/超时（~1.5s）→ 保持中转，不打扰用户。
4. **只在「待命」时升级，投射中不切链路**（MVP，两端一致）：待命阶段就已升级到直连，等到真正投射时已经在直连上，避免中途切换丢帧。UI 上直连/中转 + 延迟只作**状态展示**。
5. **强制中转**：高级设置里的开关，置位则跳过第 2~3 步、恒走中转（企业网禁 P2P 兜底）。

### 3.6 `name` 改为用户可编辑的设备名（v1.10）

**线格式不变**——`name` 字段 §3.3 起就一直在，这里改的只是语义，两端都不需要新增字段，老版本天然兼容。

统一界面设计（docs/design/）要求两端都显示「已配对设备」列表，以及「正在投射给 {设备名}」「正在接收 {设备名} 的画面」这类文案。这个设备名的来源就是 HELLO 里的 `name`：

- 以前：`name` = 主机名（`os.hostname()`），只用于日志。
- 现在：`name` = **用户可编辑的本机名称**，默认值仍是主机名。用户在界面「本机名称」处改了以后持久化，之后每次 HELLO 都发新值。
- 收到对端 HELLO 后，**以 `name` 作为该设备在界面上的显示名**；用户若在本机给对方起了别名（「重命名」），本机别名优先——因为那是这台机器的用户自己起的，对方无权覆盖。
- `name` 缺省或为空串时，回退显示 `deviceId` 前 8 位，不要显示空白。

> 设备身份仍然是 `deviceId`（配对关系、去重都认它）；`name` 只是给人看的标签，可以随时变、可以重复。

### 3.7 配对码 → 房间的推导（v1.11，**两端必须逐字节一致**）

新界面把配对改成了「**两台电脑输入同一个码**」（一方随机生成），不再是
「一端显示、另一端输入」。这意味着房间号不再由 relay 分配，而是**两端各自从码
算出来**——所以推导算法是硬性互通约定，差一个字节就会各自进不同房间，表现为
「码明明一样却永远撮合不上」，而且两边日志都正常，极难查。

**配对码格式（v1.11）：6 位、大小写不敏感的字母+数字**（旧版 6 位纯数字，1M
组合太弱；现 31^6 ≈ 887M）。派生前**必须先归一化**：

```
normalize(code) = 转大写(uppercase) 后只保留 [A-Z0-9]      // 去掉分组空格等；大小写不敏感
secret   = base64( SHA256( UTF8("netdisplay-pair:" + normalize(code)) ) )
pairHash = lowerhex( SHA256( base64_decode(secret) ) )      // 对 secret 的**原始字节**再哈希
```

- 前缀 `netdisplay-pair:` 一字不差，无空格。
- **归一化两端必须完全一致**：`"k7m2 qx"`、`"K7M2QX"` 归一化后都是 `"K7M2QX"`，进同一个房间。
- **生成用字符集（仅 UX，排除歧义字符 I O L 0 1）**：`ABCDEFGHJKMNPQRSTUVWXYZ23456789`（31 字符）。生成端用它避免看错；输入端只要归一化规则一致即可（大小写、空格都不影响）。
- `pairHash` 是**小写** hex，填进 `RELAY_JOIN.pairHash` / `RELAY_REGISTER.pairHash`。
- 第二步哈希的输入是 secret **base64 解码后的字节**，不是 base64 字符串本身。
- relay 要求 pairHash 为 **64 位小写 hex**（`roomKey`），SHA256 hex 天然满足。

自检向量（两端算出必须逐字节一致）：

```
code     = "K7M2QX"    （"k7m2 qx" 归一化后同此）
secret   = "IgIOVj/vp7y49ft6w10/GXJnX91pkGoO9AQ8zVQzKVE="
pairHash = "bec0ed709f8fd1a53d42d5e243e6cb134a939467f50bb73a5099722e5c5ae924"
```

> 首次配对成功后 Sender 仍会在 HELLO_ACK 里下发 `pairSecret`（§3.4），两端持久保存，
> 之后免码重连。码只是**第一次**把双方引到同一个房间的手段。

**交接期兼容（建议两端都做）**：用户多半会先升级一端。那时两边输一样的码却各进各的
房间——新端在 pairHash 房、老端在明文 code 房——撮合不上，而**两边日志都正常**，用户
只看到「配对码不存在」。所以新端 JOIN 用 pairHash 收到 `code_not_found` 时，应当**自动
再用明文码试一次**再报错。等两端都升级后这条回退路径自然不会被走到。Windows 端已实现
（`renderer.js` 的 `RELAY_ERROR` 分支，实测老端明文码注册 → 新端回退命中 → 握手 →
升级直连，755 帧 0 错）。

### 3.8 连通性探测（UI 显示用，v1.13）——`PROBE`/`PROBE_ACK`

界面显示这条配对**当前直连/中转哪条通**，优先直连（docs/11 §2）。**两端判据必须一字不差。**

**探测响应器（两端常驻）**：在 `47800` 监听，读到的第一帧若是 `PROBE(0x46)`（payload =
8 字节随机数），**立即原样回 `PROBE_ACK(0x47)`**（回显那 8 字节）然后可关闭该连接；若第一帧
是 `HELLO`，则进入正常直连投射会话（§3.1）。无需任何会话状态，空闲时也能被探。

**直连探测**（仅当该设备**配了对方 IP**）：拨 `对方IP:47800`，发 `PROBE`（随机 8 字节）。
- **判据 = 收到 `PROBE_ACK` 且回显匹配**——**不是** TCP `connect` 成功。Clash/Mihomo **TUN**
  会对根本不可达的地址也返回 connect 成功，只有 app 层应答才证明真的通到对端。
- 收到 → 直连通，`RTT` = 往返耗时；~1.5s 超时 → 不通。**没设 IP → 不探直连、不显示「直连不通」**。

**中转探测**：自配对探针（register+join 一个随机 64hex 房，收到 `RELAY_PAIRED` = relay 可达 +
token 有效）。

**显示优先级**：设了 IP 且直连通 → 「直连 · 通 Xms」；否则 → 中转结果「中转 · 可用 Xms /
连不上 / token 错」。真正投射选路同优先级（直连优先、回落中转；判据同上）。

## 4. VIDEO_FRAME（0x10）payload 格式

```
+----------------+--------+---------------------------+
| pts_us         | flags  | H.264 Annex-B 数据         |
| u64 big-endian | u8     | （一个完整视频帧的所有 NAL）  |
+----------------+--------+---------------------------+
```

- `pts_us`：呈现时间戳，微秒，单调递增（用 Mac 端捕获时刻的 hostTime 换算，起点任意）。
- `flags`：bit0 = 关键帧（IDR）。其余位保留为 0。
- Annex-B：NAL 单元以 `00 00 00 01` 起始码分隔。**关键帧必须以 SPS、PPS NAL 开头**（VideoToolbox 输出的 AVCC 格式需转换：从 CMSampleBuffer 的 formatDescription 取参数集，把 4 字节长度前缀替换为起始码——参考 opendisplay `MacSender.swift` 的做法）。
- 一个 VIDEO_FRAME = 一个视频帧（access unit）。不拆分、不合并。
- Receiver 解码原则：低延迟优先，收到即解码渲染，不做缓冲队列（队列积压时丢弃至最新关键帧）。

## 5. VIDEO_CONFIG（0x12）

流参数变化时（分辨率/帧率/码率调整、编码器重建）由 Sender 发送，Receiver 收到后重置解码器，等待下一个关键帧：

```json
{ "codec": "h264", "width": 2560, "height": 1600, "fps": 60, "bitrateMbps": 40 }
```

- **字段必需/可选（v1.8 定明）**：**必需** `codec` / `width` / `height`；**可选** `fps` / `bitrateMbps`（缺省表示不变）。发送方发全字段更安全；接收方两个可选字段都必须容忍缺省。
- Receiver 收到后应**同时**：重置解码器、更新记录的尺寸（统计/canvas）、（有窗口时）跟随 resize，并请求关键帧。只重置解码器而不更新尺寸会画错。

M1/M2 阶段参数固定，可不实现发送方；Receiver 必须能容忍收到它（重置解码器）。

## 6. INPUT_EVENT（0x20，M4）

JSON，一帧一个事件。坐标统一为**相对虚拟屏的归一化坐标**（0.0–1.0，浮点）：

```json
{ "t": "mousemove", "x": 0.5123, "y": 0.2340 }
{ "t": "mousebutton", "btn": 0, "down": true, "x": 0.5, "y": 0.2 }
{ "t": "scroll", "dx": 0, "dy": -120, "x": 0.5, "y": 0.2 }
{ "t": "key", "code": "KeyA", "down": true, "mods": ["Meta"] }
```

- `btn`：0=左 1=中 2=右。
- `key.code`：W3C `KeyboardEvent.code` 字符串，Mac 端负责映射到 CGKeyCode（映射表放 Sender 侧）。`mods` ∈ `["Shift","Control","Alt","Meta"]`。
- 实装 INPUT_EVENT 前，中转模式必须先启用帧加密（见 `01-architecture.md` §6）。

## 7. Relay 配对消息（M3）

### RELAY_REGISTER（0x40）Sender → Relay

```json
{ "v": 1, "role": "sender", "code": "483920", "pairHash": "hex（可选，持久配对用）", "token": "可选，公网 relay 鉴权" }
```

- `code`：Sender 自己生成的 6 位数字（100000–999999，密码学随机）。
- `token`（v1.5，可选）：公网 relay 的访问令牌。relay 配置了 token 时，REGISTER/JOIN 必须携带匹配的 token，否则回 `RELAY_ERROR{"reason":"unauthorized"}`。地址与 token 都由客户端用户在设置里配置，不硬编码进仓库。
- Relay 记录 code（或 pairHash）→ 该连接，等待 JOIN。同 code 重复注册返回 RELAY_ERROR。

### RELAY_JOIN（0x41）Receiver → Relay

```json
{ "v": 1, "role": "receiver", "code": "483920", "pairHash": "hex（可选）" }
```

### RELAY_PAIRED（0x42）Relay → 双方

```json
{ "ok": true }
```

**Relay 在发出这两条 RELAY_PAIRED 之后，对两条连接进入纯转发模式**，不再解析任何帧。双方收到 RELAY_PAIRED 后立即发 HELLO。

### RELAY_ERROR（0x43）

```json
{ "reason": "code_not_found | code_taken | rate_limited | timeout | room_full" }
```

收到后应断开重试（Receiver 提示用户检查配对码）。

## 8. 调试裸流模式（M1 验收用）

Sender 额外监听 **TCP 47801**：任何客户端连入后，不做握手，直接推送**裸 Annex-B H.264 字节流**（无本协议帧头，无 pts）。用途：

```bash
ffplay -fflags nobuffer -flags low_delay -f h264 tcp://10.77.0.1:47801
# 或本机自测
ffplay -fflags nobuffer -flags low_delay -f h264 tcp://127.0.0.1:47801
```

这让 Mac 端在 Windows Receiver 写好之前就能独立验收 M1（虚拟屏→捕获→编码→传输全链路）。裸流端口只在 debug 构建/开关下开启。

## 9. 超时与心跳汇总

| 项 | 值 |
|---|---|
| PING 间隔（Receiver 发） | 3s |
| 无数据判死 | 10s |
| Relay 未配对连接超时 | 30s |
| 配对码有效期 | 5min，一次性 |
| Sender 断线后保留虚拟屏 | 60s |
| 重连退避 | 1s 起指数退避，上限 30s |

## 10. 连接与投射解耦（v1.4，Mac 端提案）

**核心变化**：把「连接/配对」和「投射内容」分开。以前一次投射 = 一次完整会话（连上→HELLO→建流→断开）。v1.4 后：**连一次、常驻**，投射内容可随时开始/停止/切换/弹回，**目标窗口一直在**（空闲时空白）。

### 10.1 生命周期

1. **配对一次**（中转模式）：首次配对成功，Sender 在 HELLO_ACK 下发 `pairSecret`（base64，32 字节），双方持久保存。之后重连：双方在 RELAY_REGISTER/JOIN 用 `pairHash = hex(SHA256(pairSecret))`，relay 按房间自动撮合，**免输码**。直连模式无需配对（IP 即可）。
2. **连接常驻**：HELLO/HELLO_ACK 完成后连接保持。此时可能**无投射**（空闲）——Sender 发 `PROJECTION_STATE{active:false}`，Receiver **保留窗口、显示空白**（不关窗）。
3. **开始投射**：Sender 发 `VIDEO_CONFIG`（新尺寸）+ `PROJECTION_STATE{active:true,label:"iTerm 窗口"}`，随即推 `VIDEO_FRAME`（首帧关键帧）。Receiver 显示。
4. **切换投射源**（不断连）：Sender 换到新窗口/桌面 → 发新 `VIDEO_CONFIG`（新尺寸）+ 首帧关键帧。Receiver 按现有 VIDEO_CONFIG 逻辑重置解码器跟随。**无需重连、目标程序不重启**。
5. **停止/弹回投射**：Sender 停止推流、发 `PROJECTION_STATE{active:false}`；Receiver 回到空白窗口待命（连接不断）。

### 10.2 PROJECTION_STATE（0x13，Sender→Receiver）

```json
{ "active": true, "label": "iTerm 窗口 800×600", "sourceKind": "window" }
```
- `active`：是否正在投射。`false` = Receiver 保留窗口显示空白/占位（如「等待投射…」）。
- `label`（可选）：给用户看的来源说明。`sourceKind`（可选）：`"window"`/`"desktop"`。

### 10.3 CONTROL（0x21，Receiver→Sender）

目标端 → 源端的控制指令（如目标窗口上的按钮）：
```json
{ "action": "bounceBack" }   // 弹回：把当前投射的窗口移回源机主屏，停止投射（转空闲）
{ "action": "stop" }          // 停止投射（转空闲，不弹回）
```
- Sender 收到 `bounceBack`：把投射窗口移回 Mac 主屏、停止投射、发 `PROJECTION_STATE{active:false}`。
- 未来可扩展更多 action（本消息与 INPUT_EVENT 分开：CONTROL 是会话/窗口级控制，INPUT_EVENT 是键鼠）。

### 10.4 兼容性
- 老 Receiver 收到 0x13 未知类型会跳过（§2 规则），行为退化为「一直有画面」。
- 老 Sender 收到 0x21 跳过。
- 持久配对是可选优化；不支持时回退到每次输码（v1 行为）。
