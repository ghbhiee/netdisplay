---
date: 2026-07-21
tags: [netdisplay, handoff, mac, progress]
---

# Mac 端进展（Sender）

> 维护者：Mac 端 Claude。与 `91-windows-progress.md` + `02-protocol.md` 三方异步协作。

## 当前状态：**v1.4 增量1+2+4 已做并实测（解耦/活切/舞台跟随）；持久配对(需relay)+HEVC 待 Windows 协作** ✅

- ✅ **#22 Mac 菜单栏「连接设置」面板(统一 UI 第一步)**：把散落的『模式(中转/直连)』『中转设置』合并成**一个「连接设置…」对话框**——连接方式(自动/直连/中转)下拉 + 对方地址(直连/自动用) + 中转服务器 + token(等宽可粘)。AppConfig.Mode 加 `.auto`(发送端暂按 relay 注册,完整 A位 listen+register 待 #25)。构建通过、App 启动无崩溃。对齐 10-ux-model『连接方式只设一处、收发共用』。

- ✅ **W1/WS-5d 收官 + 采纳 Windows 的 CPU 翻盘 + 通过 W3(b) 编排规范**：① W1 双向对账干净(sent1604/recv1583 快照差,codec=hevc422 三证据,0错)。② **纠正定位**:Phase 2 HQ 不降 CPU,反而每帧 ≈2倍(31.86 vs 15.59ms,hwdownload memcpy 之故)——**Phase 2 = 纯画质增益**,非 CPU;我之前说的『降 CPU 收益』收回。已改 for-windows。③ **审阅并采纳 Windows 的选项A 连接角色编排规范(91 更新之三十四)**:deviceId 字节序定 A/B 位、待命常驻、B位投=反转重建、**断线一律回默认角色(防双方都listen/都dial死锁)**、抢投 CONTROL stop + deviceId 裁决。已折进 10-ux-model(两端权威一致)。→ **我的 #25 前置依赖满足,可实现**。

- ✅ **Mac 发布改为通用二进制(Intel+Apple Silicon)**：make-app.sh release 现在 `swift build --arch arm64 --arch x86_64` 出 fat binary(.build/apple/Products/Release),签名打包。NetDisplay.app 实测 `x86_64 arm64` 双架构,GitHub v0.3.0 资产已更新——现在 Intel Mac 也能跑,不只 Apple Silicon。

- 🎉 **W1/WS-5d PASS：真 NVENC 4:2:2 跨机 → Mac 解码零错(Phase 2 收官)**：带 --codecs hevc422 连 Windows 常驻 HQ 发送端,协商 codec=**hevc422**、2560x1600@60、**recv=1583 decoded=1583 dropped=0 errors=0**、14 关键帧 10.5MB。**过网络的真 Rext 4:2:2 10-bit,我 Mac VTDecompressionSession 全解零错**(不是本地文件)。等 Windows 侧 HQ SEND_STATS + CPU 对比收尾对账。(注:interop-test 之前硬编 --codecs h264 导致首次走基线,已改成默认上报 hevc422。)
- ✅ **Mac auto 模式(ReceiverAuto,镜像 Windows connectAuto)**：`receive --auto` 并行直连+中转,**胜出判据=先握手者(app 层),不是 TCP connect**——防代理。在**用户这台 Clash TUN Mac 实测**:bogus 不可达直连(代理让 connect 假成功)+ 中转到本地 sender → **『auto: relay won』、handshake OK,直连正确落败**,没被代理骗到。这正是 Windows 逮的坑,两端现在都堵上了。构建通过。

- 📋 **给 Windows 排了明确任务队列(项目继续迭代)**：之前没及时派活让 Windows 空等,是疏漏。for-windows.md 顶部加『Windows 当前任务队列』:W1 WS-5d HQ 4:2:2 跨机对账(收官 Phase2)、W2 WS-5c 收尾(崩溃/resize 重启+背压)、W3 统一 UI 收尾(直连接收+选项A 连接角色编排)+真机验、W4 exe 附 GitHub v0.3.0 release、W5 后续输入转发/远程控制(让扩展屏可交互,协议已留 INPUT_EVENT 0x20)。
- ⚠️ **采纳 Windows 关键发现→写进 10-ux-model 通用规则**:auto 模式 happy-eyeballs 的胜出判据**必须用应用层协议应答(Sender HELLO / RELAY_PAIRED),不能用 TCP connect 成功**——代理/VPN(尤其 Clash TUN)下 connect 连不可达地址也会假成功。**用户 Mac 正是 Clash TUN,我做 Mac auto 时必照此**。

- ✅ **Mac GUI 接收支持直连(消掉『作为目标不能直连』)**：AppConfig 加 `peerHost`(直连对方地址);菜单栏『接收投射』按连接方式分流——直连→ReceiverSession 拨号对方:47800、中转→ReceiverRelayClient(原路径);窗口回调(onReady/onProjectionState/onResize/onFrame)两条路共用。直连接收回环实测 recv=53 decoded=53 0 错。这是统一模型『直连接收两端都要有』的一步(Windows 侧也会补)。

- 🎯 **UX 模型定案(选项 A,Windows review 后)**：Windows #78 指出我原模型漏洞——协议里连接角色与投射角色绑定、双方待命有谁 listen 死锁,「不断连切换方向」需改协议。**拍板选项 A(不改协议)**:配对定固定常驻连接角色(deviceId 序,待命连接已保持→对方投来自动显示)、切换方向=快速重建(提示切换中)、抢投复用 CONTROL stop、自动模式 happy-eyeballs 并行探测。UI 只承诺『切换是一个开关的事』不承诺物理不断连。10-ux-model 已更新。Windows 先做非争议 UI(合并连接面板/去俩并列发送键/收敛主界面),编排等 10 落定一起对。
- 🔧 **Monitor 修复**：我的频道 Monitor(#56-64后哑了、#66-78 靠手动 poll 才看到)已 TaskStop 重 arm(bc7bmwh3j,curl 加 --max-time 防挂死)。Windows 侧正常(持续回消息+推 WS-5a/b 提交)。

- 🎨 **统一交互模型 docs/10-ux-model.md（UX SoT，回应用户『来源/目标逻辑乱』）**：看了 Windows 前端(index.html:连接模式配接收+发送端两个并列直连/中转按钮)与 Mac 菜单散乱,定统一模型:**一次配对→常驻连接→角色开关随时切谁投谁**(落地协议 v1.4 解耦,协议不改)。要点:连接方式(自动/直连/中转)只设一次收发共用、去掉并列的直连发送/中转发送按钮合并为『投射本机』、直连接收两端都补(目标 dial 对方:47800)、画质归『作为目标时』。已请 Windows 对齐,对齐后两端各自重构 UI(Mac 我重构菜单栏+补直连接收)。

- ✅ **Mac 解真 4:2:2 10-bit 已实测(de-risk WS-5d)**：加 `decode-file` 命令(读 Annex-B 文件、按 AUD 切 AU 喂 Decoder)。ffmpeg libx265 生成真 Rext/yuv422p10le(ffprobe 确认)→ 我的 VTDecompressionSession **60/60 AU 全解 0 error**。纠正了之前『hevc422 自测其实喂 4:2:0』的空白——真 4:2:2 解码这关 Mac 已过,Windows WS-5 出真 NVENC 4:2:2 时 Mac 接收端直接能收。

- ✅ **Review Windows WS-5/Phase-2 计划 → 批准开工**：实测撑腰、诚实自纠(GPU 零拷贝不可行→hwdownload 过内存但开销≈0)。**批准 + 放开边界⑦**:单窗口也走 HQ(整屏 ddagrab/单窗口 gdigrab,都真 4:2:2)——因用户定调单窗口一等特性。HQ 默认 30fps 可调、优雅回退、codec 反映实际路径、子进程失败留日志,均认可。写进 for-windows.md + 频道。
- ⚠️ **发现一个待验点(我)**：之前 hevc422 自测喂的是 VT 降成 4:2:0 的流,『Mac VTDecompressionSession 解**真** Rext Main422_10』尚未实测。下轮本地用 ffmpeg 生成真 4:2:2 10bit 流喂 Decoder 预验,de-risk WS-5d。

- 📌 **定位定稿(用户拍板)+ README 更新**：接受延迟(跨公网最坏~300ms、主场景局域网低延迟);定位=**通用对称的网络第二显示屏**(任意两台 Mac↔Win/Win↔Win/Mac↔Mac、谁发谁收)、**整屏+单窗口都是一等特性**。README 重写:现状改为『对称 App 双向已跑通』、加『使用场景与延迟(局域网=真扩展屏/跨公网=远程投屏)』+ CGNAT 同出口IP≠可直连提醒。已在频道纠正 Windows『只是远程投屏』的收窄说法。**Phase 2(WS-5 NVENC 真4:2:2 HQ)已放行 Windows 开工**(基线全绿,先在 91 出实现说明我 review)。

- 🚀 **发布 GitHub Release v0.3.0（Mac 版）**：`scripts/make-app.sh release` 出签名 NetDisplay.app(NetDisplay Dev 身份)→ditto 打包保签名→`gh release create v0.3.0` 附 NetDisplay-macOS.zip(295K，菜单栏 App 收发一体)。Release notes 含安装/中转配置说明(**token 不入公共 release**，让用户在客户端设置填)。已请 Windows 把它的 exe 附到同一 v0.3.0 release。中转地址+token 已直接给用户。

- ❌ **直连优化作废(用户确认两端不在同一局域网)**：之前两端相同出口 IP 121.52.252.30 是 CGNAT 巧合、非可直达;跨不同 NAT 直连需打洞,relay 已解决,不折腾。**中转=咱俩的连接方式**;`--host` 直连模式代码保留给真·同网/USB4 场景(对本 Mac↔Windows 对不适用)。若以后在意 ~300ms(relay 境外),杠杆是换近的 relay 节点而非直连。至此 v1.4 四项跨机全绿、协议 v1.8 加固,Mac 端功能完整(收发 GUI+全模式),对称 App 闭环。

- ✅ **v1.4 四项联调全部 PASS（③单窗口+resize 收工）+ 协议 v1.8 加固**：③最终对账逐字节一致(两侧 width=2236 recv=7=sent=7 keyframes=3 bytes=621619)。承接 VIDEO_CONFIG 那个 bug 的根本预防：VideoConfig 的 fps 也改可选；02 §0 加通用规则「接收方容忍未知字段+缺失可选字段，不得整条丢弃」、§5 定明必需(codec/width/height)/可选(fps/bitrateMbps)。以后加字段(hevc422/直连协商)平滑演进不再重演静默丢弃。构建通过。
- **下一件大的：直连优化**。我的 Mac LAN IP=192.168.50.119（en0）。已发频道，等 Windows 的内网 IP 看是否同网段可直连(省中转 ~300ms)。

- 🐛✅ **修复 VIDEO_CONFIG 静默丢弃（Windows 证据链定位）**：根因=我的 `VideoConfig` 结构体 `bitrateMbps` 非可选，而 Windows 的 VIDEO_CONFIG 不带该字段 → `JSONDecoder` 解码失败 → guard 静默 return，收到的每条 VIDEO_CONFIG 都被丢、中途 resize 跟不上。Windows 用「我 RECV_STATS 与他 sent 逐项一致(recv=5 keyframes=3 bytes=687568)」证明 TCP 有序下我必然收到了 VIDEO_CONFIG——铁证。修：①bitrateMbps 改可选；②handleVideoConfig 现在 log+更新 streamW/H+重置背压+onResize 回调让窗口跟随+解码失败也打日志(永不再静默)。direct/relay/菜单栏都接了 onResize。02 记 v1.7、§5 补可选说明。构建通过。跨机确认待 Windows 触发一次真·中途 resize。

- ✅ **单窗口投射跨机 PASS + 我的 PROJECTION_STATE 上浮验证**：Win→Mac 投 Notepad 窗口，Mac 收到尺寸 **1866x1216(窗口非整屏)**、codec h264、**label="longlines.txt - Notepad" kind=window**——本轮加的 onProjectionState→窗口标题这条链跨机实测通了。Windows 也修了个真 bug(指定窗口找不到时静默退回整屏 / BYE 不带原因)。resize→VIDEO_CONFIG 待测。
- ✅ **协调改用 Monitor + 主 agent（取代常驻子 agent，省 token）**：常驻子 agent 空转烧 token，改成一个长轮询守望进程(Monitor 常驻)盯 agent-chat，只有 Windows 发消息才把该消息吐成事件唤醒主 agent 处理，空闲零模型调用。身份回归 mac-claude。Windows 侧也独立切到了 Monitor(#52)。coordinator-agent.md 已更新为此模型。

- ✅ **接收端 PROJECTION_STATE→窗口标题**（配合 win-coordinator 单窗口投射测试）：ReceiverSession 加 onProjectionState 回调、ReceiverRelayClient 转发、ReceiverWindow.setLabel 更新标题后缀(投射源 label/sourceKind；active=false 显示「等待投射…」)。direct/relay/菜单栏 App 三处都接了。win-coordinator 起 --send-window 时 Mac 窗口标题会显示被投窗口名。构建通过。
- 📌 **mac-coordinator 改常驻**：coordinator-agent.md 里把「~4分钟/3次」改为常驻长运行(45分钟+，只在 DONE 无待办或20分钟静默才收尾)，与 Windows 已常驻的 win-coordinator 对齐——两端都常驻才能真正随时对上。本轮 spawn 一个常驻 mac-coordinator 去和在线的 win-coordinator 实时跑剩余项(Win→Mac 复测/单窗口/直连)。

- ✅ **菜单栏 App 加接收模式（对称 App GUI 成型）**：之前 App 只能发；现在加了「接收投射（本机作目标屏）」菜单项——弹框输配对码(免码可留空)、连中转设置里的 server/token、上报本机主屏像素+可解码 codecs、复用已验证的 ReceiverRelayClient+ReceiverWindow 出窗口显示。停止接收一键收。至此 Mac 端菜单栏 App 收发一体。构建通过、App 启动无崩溃(接收组件正是那次 1339 帧跨机测跑通的同一套)。

- ✅✅ **背压调参真机大流量验证通过（首次非回环）**：spawn 持久 mac-coordinator 子agent(后台) join Windows 常驻发送端(secret-win-sends 房)测 Win→Mac：**recv=1339 decoded=1339 dropped=0 errors=0**、2560x1600@60 h264、36MB。~300ms 真实中转 RTT + TCP 突发下阈值24+连续3次的背压**稳态零丢、零误伤**——这是回环(RTT<1ms)永远测不出的路径，实锤了。子agent 因 win-coordinator 未在其窗口内活跃(各自 cadence 未重叠)跑完 1 次即待命收尾；但**无需重叠**：靠 Windows 常驻发送端就测成了，双房间待命模型按设计工作。留了两个后续给频道：单窗口投射跨机(需专门 window-projection 发送端，改 standby 前先协调)、直连优化(同出口 121.52.252.30，LAN/USB4 --host 省~300ms)。

- ✅ **Mac 客户端处理 `RELAY_ERROR room_occupied`（配合 Windows 的 relay 防抖修复）**：RelayClient 收到 room_occupied 即 `stopped=true` 停止重连(否则会和对方发送端互踢)、打印中文提示、上报 `.error`。实测(对已上线的 relay 修复版)：同房间起第二个发送端，register 3 次后收到 room_occupied 并停住(不再 flap)，在位发送端存活、我另一房间的持久待命发送端不受影响。两端合力根治 flapping。

- ✅ **win-coordinator 上线并跑通 recv-from-mac 复测**：Windows spawn 了持久 win-coordinator 子 agent，实时复测 Mac→Win(HEVC) 背压修复→**62/62 dropped=0 errors=0 稳态零丢**(373ms 真机)，免码重连也隐式再验。
- ✅ **双房间模型消除房间占用冲突**(#35 撞了)：新增 `secret-mac-sends`(Mac 发送端常驻→Win 收)/`secret-win-sends`(Win 发送端常驻→Mac 收) 两个专用房间，两方向同时常驻可测、零 kill/让房间。standby-sender.sh 用 mac-sends、interop-test recv 用 win-sends/send 用 mac-sends。已重起 Mac 待命发送端于 mac-sends 房。已请 Windows 切 win-sends。

- ✅ **采纳 Windows 跨机实测的背压调参（他专门给我提了醒）**：上轮我加的瞬时阈值 `pending>=8` 有和 Windows 同样的坑——中转 400-600ms RTT 上 TCP 突发吐十几帧、队列瞬时冲高但很快消化，按瞬时值丢帧会把突发误判成积压、触发「丢→请关键帧→等 RTT→再丢」自激循环(他实测阈值8=15.7%丢、RTT 冲到 570ms)。改为**高阈值(24)+需连续 3 帧都超标**才判真积压，突发不误伤。回环回归 dropped=0 recv==decoded errors=0。这坑回环 RTT<1ms 永远测不出，感谢跨机联调暴露。

- ✅ **Mac 接收端加解码背压（对称 Windows 那个 bug 的修法，主动预防）**：Decoder 加在途异步解码计数 `pending`；ReceiverSession 在 `pending>=8` 且非关键帧时丢 delta 帧并**立即 REQUEST_KEYFRAME(1s 节流)**、丢到下一个关键帧恢复——高 RTT/慢解时恢复缩到 ~1 RTT 而非一个 GOP。RECV_STATS 加 `dropped` 字段(对齐 Windows)。回环回归：LAN 速度不触发、dropped=0 recv=decoded=60 errors=0，正常路径无影响。

- 🎉🎉🎉 **对称 App 双向闭环达成（跨机真机中转）**：Win→Mac(h264) + **Mac→Win(HEVC)** 都 PASS。反向是我 negotiate 出 hevc、Windows WebCodecs 硬解我的 VideoToolbox 流 errors=0——codec 协商真实生效。联调逮到并促成 Windows 修了一个真背压 bug(丢帧不发 REQUEST_KEYFRAME，本地 RTT<1ms 暴露不出、373ms 跨机+HEVC 冷启动才触发)。已重起干净持久 Mac 待命发送端配合其复测。
- 📣 **已(消息+GitHub)请 Windows spawn 持久 win-coordinator 对话+测试子 agent**：docs/coordinator-agent.md 加了现状+直接请求+对齐好的 Windows 子 agent prompt，并在 agent-chat 贴了 spawn 指令。目标：两端各常驻一个子 agent 挂长轮询实时协作，脱离 5 分钟主循环。

- 🎉🎉 **实时协调子 agent 机制实战成功 + Win→Mac 基线双向对账 PASS**：spawn 的 mac-coordinator 子 agent 与在线的 windows-claude 经 agent-chat 长轮询实时协商，`interop-test recv` 跑通 **Win→Mac h264**：Mac recv=1053 decoded=1053 errors=0 keyframes=2 vs Windows sent=1074 dropped=0 encodeErrors=0 keyframes=2——差 21 帧=快照时点差(bytes 口径两侧一致可解释)，**全链路零丢零错**，双方互认。桌面有内容时实测 ~57fps 满帧(链路无瓶颈)。
- ✅ **纠正 relay 模型 + 持久待命工具 `tools/standby-sender.sh`**：relay 房间是【发送方先 register 常驻、接收方随时 join】(空房间 JOIN 立即 code_not_found)。所以持久挂的必须是发送端。加 standby-sender.sh(start/status/stop，nohup 常驻，blank 虚拟屏、idle 到有人 join 才编码、token+secret 门控)。interop-test 的 pkill 改精确化(recv 只杀 receiver、send 只杀 relay)以免误杀 standby。**反向② Mac→Win**：已起持久 Mac 待命发送端，Windows 随时 join 即可自动完成(消除了 30s 双窗口对齐摩擦)。
- 📌 **后续优化记点**：两机同出口 IP 121.52.252.30，直连(LAN/USB4 10.77.0.1-2)可省中转 ~300ms RTT。

- ✅ **实时联调协调子 agent 机制**（回应用户「主循环太慢、主 agent 沟通难」）：定义 `docs/coordinator-agent.md`——两端各 spawn 一个协调子 agent，挂 agent-chat 长轮询(对方一发消息秒回)，看到消息就在子 agent 里跑 interop-test 并回报，脱离 5 分钟 cron 主循环。含协商协议(PROPOSE/SENDER-UP/RESULT/ACK/NEXT/DONE)与两端子 agent prompt。本轮 spawn 了 mac-coordinator(后台) 待命对上 win-coordinator。

- ✅ **自动化联调脚本 `tools/interop-test.sh`**（承接纯 CLI 方案）：`recv [秒]` 探测共享房间——有待命发送端就解码并把 `RECV_STATS` 自动贴到 agent-chat，没有就干净报「no standby Sender」；`send [秒]` 起 Mac 待命发送端供对端 join。token/secret 从 15 读、不入仓。实测：Windows 离线时 recv 干净报无发送端、send 正常 register 待命。Windows 一旦起 headless 待命发送端，我在任意 loop 轮次跑 `interop-test.sh recv` 即可全自动测+回报。

- ✅ **纯 CLI 联调支持（免界面免配对码）——回应用户要求**：给 `relay`(发送) 和 `receive`(接收) 都加了 `--secret <b64>` / `--pairhash <hex>`，用共享密钥钉死同一个 relay 房间。**待命模型**：发送方 `relay --secret X` 在 relay 上 register 该 pairHash 待命，接收方 `receive --secret X` 随时 join → 自动 PAIRED，无需交换 6 位码、无需点任何界面。实测 Mac↔Mac：PAIRED→handshake OK→RECV_STATS(recv=45 decoded=45 err=0)。共享密钥存 15 的 `/root/cc/agent-chat/test-pair-secret`（也在 /info 第5节）。已请 Windows 用无界面 CLI 发送端起 headless 待命，我就能自己节奏随时连测。
- 🐞 **顺手修 flag bug**：之前把 `window` 加进 boolFlags 破坏了发送端 `--window <appName>`（窗口投射）取值。改：接收端显示窗口的开关改名 `--view`，`--window <app>` 恢复为取值 flag。

- ✅ **接收端机读计数导出 `RECV_STATS`**（对标 Windows 的 SEND_STATS，便于两侧自动对账）：`receive --stats-after N [--stats-repeat]` → stdout 打 `RECV_STATS {json}`（累计 recv/decoded/errors/keyframes/bytes/codec/width/height；bytes 只算 Annex-B，与 Sender 口径一致）。含关键帧计数（读 VIDEO_FRAME flags 位）。回环实测输出正常（recv=decoded=47 err=0 key=1）。直连+中转两条路径都接了；stdout 加 fflush 防重定向缓冲丢行。

- 🎉 **首个跨平台真机联调 PASS（Windows 发 → Mac 收，经 15 relay）**：Windows Claude 上线 agent-chat、起中转发送给配对码 771122，我 `receive --server 15...:47700 --token .. --code 771122 --codecs h264` 连上。**JOIN→PAIRED→handshake OK(2560x1600@60 h264)，37s recv=312 decoded=312 errors=0（1:1 全解 0 错）**，峰值 14fps（Windows 静止桌面+自适应码率）。持久配对生效（pairSecret 已存，下次免码）。对称 App 端到端跨平台首次验证成功。等 Windows 贴 SEND_STATS 收尾对账。

- ✅ **接收端上报 codecs 默认含 hevc422**：`receive` 默认 `["hevc422","hevc","h264"]`（Mac VT 解 Rext Main422_10 已验 44/44）。这样 Windows 若走 ffmpeg NVENC/QSV 出真 4:2:2，协商即选 hevc422、Mac 直接能收，无需再改收端。
- 📋 **Review 了 Windows 的 Phase-2 提案**（ffmpeg `ddagrab→hevc_nvenc 4:2:2→Annex-B`）：批准为**可选 HQ 模式**（不替换 WebCodecs H.264 基线），给了 8 条边界（运行时探测+回退、AUD 切帧、周期 GOP 关键帧、resize 重启子进程、子进程生命周期、窗口模式暂留 WebCodecs、ffmpeg 可选打包）。不阻塞当前 h264 基线联调。详见 for-windows.md。

- ✅ **架起实时沟通频道 agent-chat（15 服务器）**：自包含 Python HTTPS 服务（复用 15 的 Let's Encrypt 证书，systemd `agent-chat`，:47900，Bearer token 认证，长轮询近实时）。端点 /post /messages(long-poll) /info /view(浏览器看板) /health。互联信息集中在 15 的 `/root/cc/agent-chat/INTEROP.md`（含 relay token，公共仓不放密钥）。仓库加 `tools/agent-chat.sh` 便捷脚本。已从 Mac 全链路自测（health/401/post/poll 均 OK），发了首帖约 Windows 联调。**下轮起每轮 poll 频道**。

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
