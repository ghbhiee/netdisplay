---
date: 2026-07-23
tags: [netdisplay, pairing, connectivity, spec]
---

# 配对与连通性模型（两端唯一依据 / SoT）

> 用户 2026-07-23 明确的要求。两端（Mac + Windows）必须一致实现；relay 也要配合。
> 与 `02-protocol.md`（线上协议 SoT）配套：本文定行为，协议消息在 02 里定型。

## 1. 配对 = 双向 + 服务器/两端保存认证关系（**不是各自本地假配对**）

**核心：只有"另一台电脑也用同一个码连上了"，才算配对成功。** 各自本地存个码、只探测
一下中转可达，**不算配对**（那是"中转已就绪"，两回事）。

- **谁先发起都行**，没有必然的主从。
- **中转模式（默认）**：两端各发 `PAIR_ANNOUNCE`（宣告"我在用这个码配对"）。relay 见到
  **同一 pairHash、不同 deviceId** 的两个 announce，就给双方各发 `PAIR_CONFIRMED`
  （含对端 deviceId + name），并**在服务器内存里记下这对关系**。两端收到后各自保存
  `{peerDeviceId, peerName}` → 显示「配对成功 · 对方名」。
  - 对端还没输码 → 显示「等待对方输入配对码…」，一直等（announce 有 TTL，掉了自动重发）。
  - relay **按 deviceId 去重，绝不自撮合**（同一台自己 announce 两次不算配对）。
- **直连模式（设了对方 IP）**：配对时**一次性建连接确认**——投射方连接被投射方
  （投射方拨号 `IP:47800`），交换 HELLO 拿到对端 deviceId+name，然后**断开**、两端保存关系。
  配对时必须**一边投射一边接收**（有方向），但**谁当哪边、谁先发起都行**。
- **配对完成后**：`{peerDeviceId, peerName, secret, addr?}` 存两端。之后真正投射复用这段关系，
  不用再输码。设备行显示对方名字（v1.10 name = 用户可编辑设备名，本机别名优先）。
- **状态措辞**：未确认对端前 = 「等待对方…」；确认后 = 「已配对」。**不要在只做了本地存码 /
  只探测了中转时就显示「已配对」。**

## 2. 连通性显示：优先直连，其次中转

设备行/状态处显示这条配对**当前怎么连得上**，规则：

1. **优先直连**：若该设备**配了对方 IP**，探测直连是否通（拨 `IP:47800`，**判据必须是收到
   对端协议应答，不是 TCP connect 成功**——Clash TUN 会骗）。通 → 显示「直连 · 通（Xms）」。
2. **没设 IP 或直连不通** → 探测中转是否通（自配对探针：register+join 随机房收到
   `RELAY_PAIRED` = 可达+token 有效）。→ 显示「中转 · 可用（Xms）」/「中转 · 连不上」/「中转 · token 错」。
3. **没设 IP 的直连不算**（不显示"直连不通"，直接看中转）。
4. 真正投射时按同样的优先级选路（直连优先，回落中转）。

## 3. 两端 UI 一致

- **中转设置 / 高级设置一律用弹窗**（Mac 已是 `RelaySettingsDialog`）。**Windows 的"高级设置"
  改成同样的弹出式中转设置**（服务器地址 + token + 强制走中转），别用内嵌折叠区。
- 配对弹窗、设备行、状态措辞两端一致（见 docs/design 原型）。

## 4. 协议增量（写入 02）

- `PAIR_ANNOUNCE (0x44, client→relay)`：`{v, pairHash, deviceId, name, token}`。
- `PAIR_CONFIRMED (0x45, relay→client)`：`{peerDeviceId, peerName}`。
- relay：按 pairHash 暂存 announce（TTL ~2min），见到第二个**不同 deviceId** 即向双方发
  CONFIRMED 并记录该对；同 deviceId 重复 announce 不触发；token 校验同 REGISTER/JOIN。

## 分工

- **Mac + relay**：Mac 端 Claude 实装（relay 加 0x44/0x45 + 记录；Mac 配对流程改双向；连通性探测）。
- **Windows**：按本文实装配对双向（PAIR_ANNOUNCE/CONFIRMED）、连通性显示、高级设置改弹窗。
