---
date: 2026-07-28
tags: [netdisplay, backlog, mac]
---

# NetDisplay 待完善清单（Mac 端视角）

> 回应 agent-chat 任务 #2「NetDisplay 还有什么要完善的（mac 侧）」。
> 按**用户能感知的影响**排序，不是按实现难度。标注了归属方，方便和 Windows 端对齐。

## P0 — 没验证过，可能还是坏的

### 1. 「第二次投射失败」的实机验证 【两端】
根因已定位并两端修复：接收端在 `HELLO_ACK` 里把设备 `secret` 覆盖成对端下发的
`pairSecret`，而新模型里 `secret` 就是中转房间钥匙，一覆盖就把自己搬进另一个房间 →
首次会话之后永远配不上。Windows 0.4.10 修、Mac 同款路径一并删（v1.16）。

**但从未在真机上验证过修好了。** 用户装上 v0.4.12 后需要：
两端解除配对 → 重新配同一个码 → 投一次 → **再投第二次**。
验证时我会查 relay 确认「两端 presence 落在同一房间 + 会话有真实字节流（不是 0 字节秒断）」。

> ⚠️ 必须两端都装 0.4.10+，否则旧版会再污染一次配对。

## P1 — 功能缺口

### 2. Windows 直连配对未实现 【Windows】
Windows 已有直连**传输**（happy-eyeballs 并行竞速 47800/PROBE），但**直连配对**完全没做：
`pairHello` 在 `windows/src` 出现 0 次；代码里两处 TODO 自述「批二实现」。
规格已定稿（`docs/02-protocol.md` §3.9 v1.15b + `docs/11` §6），Mac 侧是现成参考实现，
含正/负两条自检（`directpair-selftest`、`directpair-reject-selftest`）。

> 注意：用户两台机共用 Clash 出口 IP = 跨网，**直连在他现有环境下打不通**，
> 验证需要两端退出 TUN、真的在同一局域网。

### 3. Windows 整屏投射仍是镜像，不是扩展屏 【Windows】
Windows 无系统级虚拟显示器 API。当前投「整个屏幕」= 复制现有屏。
已在 README 写了 VDD（`VirtualDrivers/Virtual-Display-Driver`）的安装指引作为过渡方案，
但**产品内没有引导**——用户不读 README 就不知道要装。
建议：Windows 端检测到没有虚拟屏时，在投射源列表里给一条提示 + 跳转链接。

### 4. 输入转发（远程控制）未做 【两端，Mac 已有半成品】
局域网下延迟够低（个位数 ms），扩展屏本该可交互，但现在只能看不能操作。
协议里 `INPUT_EVENT(0x20)` 已占位，Mac 端有 input-back 的实验代码。
这是「扩展屏」和「远程投屏」的分界线，做完体验会有质变。

## P2 — 打磨

### 5. 直连/中转的自动升级 【两端】
协议 v1.9 定了 `HELLO.lanAddrs` + 连接升级（中转连上后后台试直连、成功则无感切换），
**至今没实装**。现在配对方式决定传输方式，中转配对的设备即使在同一局域网也一直走中转。

### 6. 中转服务是单点 【运维】
`15.tokencv.com:47700` 挂了整个跨网协作停摆，无冗余、无健康告警。
客户端也没有「多中转候选」的概念。

### 7. Mac 接收端只能窗口显示 【Mac】
协议 §3.10 定义了 `mode=extend`（对方按第二显示器/全屏呈现），但 Mac 作为**接收方**
目前一律用普通窗口，没有真的把收到的画面变成一块虚拟显示器。
Mac 有 `CGVirtualDisplay`，技术上可行，只是没做。

### 8. 无自动化测试 / CI 【两端】
现在全靠手写 selftest 子命令（`paircode-selftest`、`resolution-selftest`、
`directpair-selftest`、`directpair-reject-selftest`、`presence-test`）+ 人工跑。
没有 CI，改协议时靠自觉两端对齐。**协议是唯一依据但没有跨端一致性测试**——
这是目前最大的质量风险（`§3.7 pairHash` 那种「差一字节就进不同房间、两边日志都正常」的坑
就是靠人工自检向量兜住的）。

### 9. macOS 包体验 【Mac】
自签名 → 首次打开要右键；换签名身份后 TCC 授权失效要重新勾屏幕录制。
没有公证（notarization），也没有自动更新。

## 已修但值得记住的坑（防回归）

- **打包破坏签名**：`ditto -c -k` 不带 `--sequesterRsrc` 会在 bundle 内生成 `._*`，
  codesign 判定「多出文件」→ 下载解压出来的副本验签必失败，而**本地那份永远是好的**。
  已改 `zip -r -X` 并在 `make-app.sh` 加了「打包后解压验签，不过就 exit 1」的闸门。
- **clamp 与 resize 检测**：拿被 clamp 过的编码尺寸去比原生源尺寸，会每轮误判 resize →
  无限重建编码器。两端都踩过（Windows 先踩，Mac 加 clamp 时照着避开）。
- **relay 限流维度**：per-IP 限流在「两台机共用 Clash 出口 IP」时会互相饿死，已改 per-room。
- **presence 只在 onSelect 建立**：启动时不建 → 对端永远看不到本机状态。已改启动即建。
