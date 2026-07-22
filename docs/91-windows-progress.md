---
date: 2026-07-22
tags: [netdisplay, handoff, windows, progress]
---

# Windows 端进展（Receiver + Relay）

> 维护者：Windows 端 Claude。与 `90-mac-progress.md` + `02-protocol.md` 三方异步协作。

## 当前状态：**#1 ✅；#3 定稿 B 且 Receiver 侧 v1.6 已落地 ✅；#2 Sender 计划仍待 Mac review**

### 2026-07-22 更新之二十三（**🐛 单窗口投射 FAIL 根因 + 修复；协调机制改为 Monitor 事件驱动**）

#### 🐛 单窗口投射跨机 FAIL（Mac #51 报告）—— 根因查清并修复
- **表层根因**：Notepad 窗口当时**处于最小化状态**。Windows 的 `desktopCapturer` **不枚举最小化窗口**——实测枚举结果里根本没有它（只有 Claude/Chrome/微信/文件资源管理器等）。这是 Windows.Graphics.Capture 的固有限制。
- **真正的 bug（比根因更严重）**：原代码在「指定了 `--send-window` 却找不到该窗口」时**静默退回整屏投射**。自测复现时 HELLO_ACK 回的是 2560×1600 整屏而非窗口尺寸，**对端只能看到「尺寸是整屏」，无从反推是窗口没找到还是本就该投整屏**。Mac 拿到的 `capture failed` 是另一分支（会话中途窗口失效），同样只回笼统字符串、不带原因。
- **三处修复**：
  1. `requireWindow` 标记——明确指定窗口就**绝不退回整屏**，找不到直接报错并附可能原因。
  2. **会话开始前二次校验**窗口仍可捕获（待命期间可能被关/最小化）。
  3. **BYE 带真实原因**（`capture failed: <具体原因>`），并把 sender 状态日志转到 stdout——之前只写 DOM，headless 下失败原因等于没有输出。**这与上次给 receiver 补 `[recv]` 日志是同一类缺口，sender 侧漏了。**
- **修复后自测双路径**：窗口可见 → `display 1866×1216`（窗口尺寸，非整屏）、recv=15 decoded=15 errors=0 ✅；窗口最小化 → 明确报「窗口「longlines.txt - Notepad」已不可捕获（被关闭或最小化）——还原后对端重连即可」✅。已请 Mac 重测 ③。

#### 协调机制改为 Monitor 事件驱动（token 成本降一个数量级）
用户指出 coordinator 子 agent 烧了 97k token。剖开看：**长轮询的 curl 挂 25 秒本身不烧 token**（进程在等），烧的是**每次 poll 返回后都要调用一次模型来决定下一步，而每次模型调用都携带完整对话历史** —— 空闲一小时 ≈ 144 次模型调用，token 呈二次方累积。我上轮说的「空轮询时什么都不做就能省 token」**并不准确**：即便什么都不做，那次模型调用仍然发生。
- **新方案**：`windows/tools/chat-watch.js` 常驻长轮询（纯进程，零模型调用），**只在真有新消息时输出一行**；用 `Monitor` 工具挂上，每行 stdout = 一次唤醒。空闲期零 token，有消息才唤醒主 agent。自己发的消息（`--self`）不触发唤醒。
- 效果：空闲 1 小时从「144 次模型调用」降到 **0 次**；响应延迟反而更低（消息到达即唤醒，不必等当前 poll 周期结束）。

### 2026-07-22 更新之二十二（**win-coordinator 改为常驻长运行**）

用户指出 win-coordinator 应当**一直在线**而不是跑完就退。原因在我：首次 spawn 时给的 prompt 写了「约 6 分钟 / 最多 3 次测试后收尾退出」，它照做了。已恢复该 agent 并改为常驻规则：

- **目标运行 45 分钟以上**，只有两种情况才收尾：mac-coordinator 明确 `DONE` 且无待办，或连续 20 分钟完全无消息且无可做的测试；退出前必须在频道留言告知。
- **不间断长轮询**：`poll(wait=25) → 处理 → 立刻再 poll`，两次 poll 之间不做无关的事，消息延迟只取决于处理时间。**空轮询时什么都不做直接再 poll**（不写文件、不跑命令、不输出长文本）——既省 token 又保证不漏消息。
- **每完成一次测试立即 post 到频道**，不攒到最后一起报。
- 同步告知它双房间模型已生效（与它上一轮的认知不同，不再需要互相 kill 让房间）和新的 `interop.ps1` 脚本，并提醒待命发送端已由主循环起好、不要重复起。

**给 Mac 的建议**：你的 `mac-coordinator` prompt（`docs/coordinator-agent.md` 里写的是「最多跑 ~4 分钟 / ~3 次测试」）也建议改成常驻长轮询，否则两端 coordinator 的在线窗口很难对上——这正是之前反向测试第一次失败（30 秒待命窗口错位）的根因之一。

### 2026-07-22 更新之二十一（**切到双房间模型 + 联调脚本 `interop.ps1`**）

- **已按请求切到双房间模型**：Windows 待命发送端现常驻 `secret-win-sends` 房（pairHash `4da42aab2327da8bc267f17c2976ea891a0319fb18b441cf86fc95b528ee7514`，与密钥独立计算值一致），投整屏 2560×1600。**Mac 随时可 join 测 Win→Mac**，两方向同时待命互不抢占，不用再互相 kill 让房间。
- **新增 `windows/tools/interop.ps1`**（对标 Mac 的 `standby-sender.sh` / `interop-test.sh`），凭据全部从 15 现取、不落仓库：
  ```powershell
  .\tools\interop.ps1 standby [-Window <标题子串>]   # 待命发送端（win-sends 房）
  .\tools\interop.ps1 recv [-Seconds 30]             # join mac-sends 房，出 RECV_STATS
  .\tools\interop.ps1 stats / stop
  ```
- 写脚本时踩到三个 Windows 特有的坑，已在脚本里注释固化，供后续参考：
  1. **PowerShell 5.1 按 GBK 读 `.ps1`**，含中文的脚本必须存成 **UTF-8 with BOM**，否则整个文件解析失败（报的是莫名其妙的语法错误，不是编码错误，很难一眼看出）。
  2. **`$args` 是 PowerShell 自动变量**，赋值即报错，改用 `$sendArgs`。
  3. **`Start-Process npx` 起不来**（npx 是 `.cmd` 不是 exe，报 "%1 is not a valid Win32 application"），改直接调 `node_modules\electron\dist\electron.exe`。
- `stats` 会区分「发送端没起」「起了但没人连（`SEND_STATS null`）」「还没到统计周期」三种情况——第一版笼统报「未产生统计」，排查时会误导。

### 2026-07-22 更新之二十（**🐛 修复 relay register-flapping（已上线）+ 子 agent 联调 PASS**）

#### win-coordinator 首轮成果
**Mac→Win RESULT PASS**（HEVC）：
```json
{"codec":"hevc","width":1280,"height":800,"recv":62,"decoded":62,"dropped":0,
 "errors":0,"keyframes":3,"bytes":677970,"wireBytes":678528,"avgRttMs":372.97}
```
`decoded/recv = 100%`、`dropped=0` —— 背压新参数（阈值 24 + 连续 3 次）在 373ms 真实中转 RTT 上**零误伤**。丢帧率演进：15.7% → 0.87% → **归零**。`wireBytes-bytes=558=62×9` 口径校验正确。免码重连在本次 join 中又隐式验证一次。

#### 🐛 relay register-flapping（子 agent 发现，已修复并部署）
- **现象**：两个发送端抢同一 pairHash 时，relay **静默无限互踢**——A register 顶掉 B → B 的自愈逻辑 3 秒后重注册顶掉 A → 循环。实测 60 秒内单侧注册了 10 次，**双方日志都只显示「注册成功」**，谁也发现不了。
- **重要性**：这为更早那次「PAIRED 成功但收不到 HELLO_ACK、`width/height=null`」提供了此前未识别的成因。当时归因为「撞上已超时退出的死 sender」，但 flapping **不需要任何一方退出**就能复现同样症状——原诊断可能是错的。
- **修法**：保留「后来者顶替」（断线自愈依赖它），但加抖动检测：同一房间 15 秒窗口内被顶替超过 3 次即拒绝并回 `RELAY_ERROR{"reason":"room_occupied"}`。另给所有连接开 TCP keepalive(30s)，让 OS 探到半开连接，死连接不再永久占房间。
- **实测**：修复前线上旧版**连续 6 次注册全部被接受**（bug 确认存在）；修复后前 4 次接受、**第 5 次回 `room_occupied`**，循环可打破。回归全过：pairHash 撮合 ✅ 断线自愈顶替仍工作 ✅ code 流程 ✅ token 鉴权 ✅。测试脚本入仓 `relay/tools/test-flapping.js`。
- **客户端侧**：Windows Sender 收到 `room_occupied` 停止自动重连并提示「该房间已有另一个发送端在待命」——继续重试只会和对方互踢。已请 Mac 客户端同样处理。

#### 待 Mac 配合
下一轮测 **Win→Mac**（正好验证 Mac 新改的接收端背压在跨机下的真实丢帧率），需要 Mac 先 kill 持久发送端 pid 11984 并回 `ROOM-FREE`，之后由我 register 常驻、Mac join。

### 2026-07-22 更新之十九（**已 spawn `win-coordinator` 实时联调子 agent**）

按 `docs/coordinator-agent.md` 的请求，Windows 侧的镜像子 agent 已起（后台常驻，约 6 分钟 / 最多 3 次测试上限），与 `mac-coordinator` 在 agent-chat 上长轮询实时协商、自行跑测试并回报对账数据。主 5 分钟循环继续做开发推进，联调交给它。

给子 agent 的 prompt 里固化了这些已踩过的坑，避免它重犯：
- relay 房间模型（发送方 register 常驻、接收方 join；空房间 JOIN 立即 `code_not_found`）
- 同一时刻房间只容一对连接，起接收端前先确认自己没有发送端占着同一房间
- 多 Electron 实例必须 `--user-data` 隔离（localStorage 抢锁）
- 中文消息必须写文件再 POST（命令行内联会编码损坏）
- Electron 日志会折行，提取 JSON 要先拼行再正则
- 已知正常现象：中转 RTT 350–600ms；Mac blank 虚拟屏内容不变时产帧极少，低帧率不是故障

**收到 Mac 的对称修复**：它已在 Mac Receiver 的 Decoder 加了在途解码计数 + 丢 delta + 立即 REQUEST_KEYFRAME（1s 节流），`RECV_STATS` 也加了 `dropped` 字段与我对齐，回环回归 `dropped=0`。
⚠️ 顺带提醒（已在频道说）：我这边最终生效的参数是**阈值 24 + 需连续 3 次采样超标**，而不是阈值 8 的瞬时判定——Mac 现在用的 `pending>=8` 瞬时值正是我实测会误伤突发到达、导致 15.7% 丢帧的那组参数。跨机测时若看到 dropped 偏高，建议照此调。

### 2026-07-22 更新之十八（**反向② RESULT PASS + 背压调参：丢帧 15.7% → 0.87%（稳态零丢）**）

#### relay 房间模型（Mac 纠正，已确认并采纳）
房间必须是**发送方 register 常驻、接收方随时 join**；接收方在空房间 JOIN 会立即 `code_not_found`。之前反向失败正是双方都想当「待命方」。以后固定按此。

#### 反向② Mac→Windows RESULT PASS（HEVC）
```
RECV_STATS(92s): {"codec":"hevc","width":1280,"height":800,"recv":921,"decoded":913,
                  "dropped":8,"errors":0,"keyframes":39,"bytes":6755869,"wireBytes":6764158,"avgRttMs":377}
```

#### 🔧 背压调参（承接上轮修复，两组跨机实测）
| 配置 | 帧数 | 丢帧 | 丢帧率 | RTT 趋势 |
|---|---|---|---|---|
| 阈值 8（仅加了请求关键帧） | 847 | 133 | **15.7%** | 387→474→570 **持续增长** |
| **阈值 24 + 需连续 3 次超标** | 921 | **8** | **0.87%** | 354→364→377 **稳定** |

且这 8 帧全部发生在启动阶段——`t=30s` 后 dropped 锁定在 8 不再增长，**稳态零丢帧**。

**根因**：中转链路 400–600ms RTT 上帧是**突发到达**的（TCP 缓冲一次吐十几帧），队列瞬时冲高但硬解能迅速消化。按瞬时值 `>8` 丢帧把正常突发误判成积压，触发「丢帧 → 请关键帧 → 等一个 RTT → 再丢」的**自激循环**——上轮观察到的 RTT 一路涨到 570ms，有一部分正是这个循环自己造成的额外负载。改为「更高阈值 + 连续多次采样都超标才判定」，突发不误伤、真积压仍兜得住。

⚠️ **给 Mac 的提醒**：若 Mac Receiver 也有瞬时阈值丢帧逻辑，建议同样检查——**这个坑在回环（RTT<1ms）下永远测不出来**，只有跨公网中转才暴露。

#### 剩余联调项
① 免码重连——这几轮已隐式验证多次（每次 headless join 都是共享 secret 免码，pairSecret 也落盘），是否单独再跑听 Mac。
③ 单窗口投射跨机——我侧 WS-3 本地验过（投记事本 → resize → VIDEO_CONFIG → canvas 跟随），跨机未验；按 relay 模型应由我 `--send-window` register 常驻、Mac join。

### 2026-07-22 更新之十七（**🎉 双向跨机联调全部打通（含 HEVC）+ 联调逮到并修掉一个真 bug**）

#### ② Mac 发 → Windows 收：PASS，且 **codec 协商真实生效走了 HEVC**
```
[recv] sender HELLO: name=LegionAir
[recv] HELLO_ACK: {"codec":"hevc","display":{"width":1280,"height":800,"fps":60,"scale":1},"pairSecret":...}
RECV_STATS: {"codec":"hevc","width":1280,"height":800,"recv":50,"decoded":14,"dropped":36,
             "errors":0,"keyframes":1,"bytes":256742,"wireBytes":257192,"avgRttMs":373}
```
我上报 `["hevc422","hevc","h264"]` → Mac 挑 `hevc`（它编不了 422）→ **我的 WebCodecs HEVC 硬解在真实 VideoToolbox 流上零错误**。至此收发两个方向都验过，对称 App 闭环。

#### 🐛 联调暴露的真 bug（我这侧，已修）：背压丢帧后不请求关键帧
- 现象：`decoded=14 / recv=50`，丢 36 帧但 `errors=0`。
- 根因：背压逻辑在解码队列积压时置 `waitingKey=true` 丢弃后续 delta 帧，**但没有发 `REQUEST_KEYFRAME`**。于是只能等对端下一个周期 GOP（Mac 2s 一个 IDR）才恢复，本次只收到 1 个关键帧，后面几乎全丢。
- **为什么本地测试从没暴露**：回环 RTT < 1ms 永不积压；中转 373ms RTT + HEVC 解码器首次初始化才触发。**这是跨机联调独有的价值**。
- 修复：背压触发时立即 `requestKeyframe(1000)`（1 秒节流防抖）。恢复时间从「最多一个 GOP」缩短到「一个 RTT + 编码延迟」。已请 Mac 配合复测。

#### 共享 secret 零点击联调（Windows→Mac 方向复测）
| | 帧 | 关键帧 | 丢帧 | 错误 | bytes |
|---|---|---|---|---|---|
| Windows Sender | sent 1074 | 2 | 0 | 0 | 12747585 |
| Mac Receiver | recv 1053 / decoded 1053 | 2 | — | 0 | 12449633 |

差 21 帧 / 297952 字节 ≈ 14.2KB/帧，与均值同量级 → 纯快照时点差。中途 t=16s 那次 dump `avgFps=56.9`，说明桌面有内容变化时能跑满接近 60fps，此前 14fps 是静止桌面 + 自适应码率所致。

#### 接收端也 headless 化（与发送端对称）
```
npx electron . --headless --recv-relay --secret <SECRET> --token <TOKEN> --recv-stats-after 20 --recv-stats-repeat
```
- 新增 `--recv-relay` / `--recv-stats-after` / `--recv-stats-repeat`，`--secret/--pairhash` 收发两端通用。
- `RECV_STATS` 字段对标 Mac：`{codec,width,height,recv,decoded,dropped,errors,keyframes,bytes,wireBytes,avgRttMs}`。**`bytes` 统一为 Annex-B 口径**（可与对端 SEND_STATS 直接对账），`wireBytes` 保留含 9 字节帧头的线上字节。实测 `wireBytes - bytes = 5229 = 581 帧 × 9` ✓ 口径分离正确。
- 加了 `[recv]` 前缀的连接状态日志（连接/配对/HELLO/HELLO_ACK/断开原因）走 stdout——第一次反向测试 `recv=0` 时就是因为没有这个日志只能靠猜，补上后立刻定位。

#### 给 Mac 的一个 relay 改进提议（待你决定）
第一次反向失败的原因基本确认是：我 join 时房间里是个**已退出的 sender 连接**，relay 撮合时不校验对端存活照样 PAIRED。现在靠 TCP close 事件清房间，进程被强杀时可能残留。**需要的话我给 relay 加「register 方掉线即清房间」或心跳探活**，你说要我就加。

### 2026-07-22 更新之十六（**🎉 首次跨机联调 PASS 并对账完成 + headless CLI 待命发送端就绪**）

#### 首次 Windows→Mac 跨机联调（经 15 relay，h264 基线）—— 对账完全对上
| | 帧 | 关键帧 | 丢帧 | 错误 |
|---|---|---|---|---|
| Windows Sender | sent **321** / captured 321 | 2 | **0** | 0 |
| Mac Receiver | recv **312** / decoded 312 | — | — | **0** |

sent 321 vs recv 312 的差 9 帧是**统计时点不同**（Mac 报的是 37s 快照，我是会话结束后累计），非丢帧。`keyframeRequests=1` 与 Mac 请求过一次关键帧、我 `keyframes=2`（首帧 + 响应）互相印证。bytes 口径两侧已统一（都只算 Annex-B），可直接对账。

#### headless CLI 待命发送端（回应用户「改用纯 CLI 联调，别用界面」）
- 新增 `--headless`：无窗口、无托盘，renderer 日志直接转到主进程 stdout（**不再需要 `--enable-logging`**，也不受打包版无控制台的限制）。
- 新增 `--secret <base64>` / `--pairhash <hex>`：共享固定配对，**零配对码零点击**。给 secret 时按 `sha256(base64decode(secret))` 算房间；给 pairhash 时直接用。
- 已用 15 上的共享 `test-pair-secret` 起了常驻待命发送端，注册 pairHash **`a651f8ecec987c53f4477a5bd6c98d1268d031e8d6c655dbb24ab3070461a1b1`**（与密钥独立计算值一致）。Mac 端 `receive --secret <同一密钥>` 即可随时连，断线自动重注册同一 hash。
  ```
  npx electron . --headless --send-relay --secret <SECRET> --token <RELAY_TOKEN> --send-stats-after 30 --send-stats-repeat
  ```

⚠️ **实装时发现的一个坑（Mac 端若也支持 --pairhash 请自查）**：只给 `--pairhash` 而无 secret 时，发送端**不能**在 HELLO_ACK 里下发本机生成的 pairSecret——对端存下后算出的 hash 与当前房间不符，下次直接连不上。已加条件判断规避；给 `--secret` 时正常下发（值相同，无害）。

**下一步建议顺序**：② Mac 发→Win 收（唯一完全没验过的方向）→ ① 免码重连 → ③ 单窗口投射。已在频道提出，听 Mac 定。

### 2026-07-22 更新之十五（**接入 agent-chat 实时频道 ✅ + Sender 已在 relay 待命等你连**）

- **agent-chat 已接上**（消息 #6/#7，from=`windows-claude`）。token 从 `ssh 15 'cat /root/cc/agent-chat/token'` 取，以后每轮 poll。
- **Phase-2 的 8 条边界全部接受**，等基线互调做完再动手。特别确认：① 可选增强不替换 WebCodecs H.264 基线、`HELLO_ACK.codec` 必须反映实际路径；④ 周期 GOP，REQUEST_KEYFRAME 只能等下一个 IDR（最坏黑一个 GOP）；⑦ 窗口模式留 WebCodecs，ffmpeg 路径只做整屏。
- **🔴 联调进行中，等你连**：Windows Sender 已在 relay 注册待命，**配对码 771122**，投射源整屏 2560×1600，会协商成 h264。
  你跑：`receive --server 15.tokencv.com:47700 --token <RELAY_TOKEN> --code 771122 --codecs h264 --window`
  - **配对码不会真过期**：relay 的 5 分钟 TTL 到期会清房间断我的注册连接，但我的 Sender 检测到 close 后 3 秒用同一固定码自动重注册（沿用 pairHash 自愈那套）。**你随时方便随时连，不用等我重发码。**
  - 连上后我立刻能报 sent/dropped/keyframes/bytes/avgFps（开发模式跑，stdout 计数可取）。
  - 截至本轮结束 relay 上未见 JOIN，估计你那侧在等用户跑命令。已在频道里问了。

### 2026-07-22 更新之十四（**回答你的提问：Windows 硬件能出 HEVC 4:2:2 ✅，但不是通过 WebCodecs**）

你问「若你 Windows Sender 侧硬件能真出 4:2:2，那 Windows→Mac 方向可以走 hevc422」——**答案是能，实测通过**。但要区分两层，这也修正了我更新之十二的结论边界：

| 层面 | HEVC 编码 | HEVC 4:2:2 10-bit |
|---|---|---|
| **WebCodecs**（我现在用的） | ❌ 完全不支持 | ❌ |
| **本机硬件**（ffmpeg 直调） | ✅ NVENC / QSV / MF 全都有 | ✅ **NVENC 与 QSV 都实测出真 4:2:2** |

本机 GPU：**NVIDIA RTX 5060 Laptop（Blackwell）+ Intel Arrow Lake iGPU**。实测（学你 VT 的教训，**不看编码是否成功，只认 ffprobe 实测输出**）：

- `hevc_nvenc -pix_fmt yuv422p10le` → ffprobe 实证 **`profile=Rext, pix_fmt=yuv422p10le`** ✅ 真 4:2:2（Blackwell NVENC 原生支持 4:2:2）
- `hevc_qsv -pix_fmt y210le` → 同样 **`profile=Rext, yuv422p10le`** ✅
- **实时性能**：NVENC 编 **2560×1600@60**，实测 **235fps / 3.92x 实时**，远超需求。
- **产出的流可解**：把 NVENC 的 4:2:2 流喂我的 WebCodecs 解码器 → **30 AU / 30 帧解出，0 error** ✅（你 Mac Decoder 也验过 49/49，两端都能解）
- **参数集内联合规**：NAL 序列 `AUD(35), VPS(32), SPS(33), PPS(34), SEI(39), IDR(19)` —— 符合 02 §4「关键帧内联 VPS+SPS+PPS」。

#### 结论与建议
1. **Windows→Mac 走 hevc422 是可行的**，但必须绕开 WebCodecs、走 ffmpeg(NVENC/QSV) 或原生 MF。协议不用改。
2. **这让 Phase 2 的价值从「降 CPU」升级为「降 CPU + 提画质」**，我认为值得做，方案也比原生 addon 简单：
   **`ffmpeg ddagrab`（Desktop Duplication，GPU 内抓屏）→ `hevc_nvenc` 4:2:2 → Annex-B 出 stdout → 我分帧按协议发**。全程 GPU 零拷贝，同时解决当前 H.264 软编 CPU 偏高的问题。
   代价：产物要带 ffmpeg（约 80MB）或依赖用户自备；且 NVENC 路径依赖 N 卡（QSV 作核显回退，无独显机器仍可用）。
3. **先不动手**——按约定这属于架构级选型，**请你 review 后我再做**。当前 h264/WebCodecs 路径保持可用，不受影响。

**复现命令**（你或用户想自己验）：
```bash
ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=30 -frames:v 30 \
  -c:v hevc_nvenc -pix_fmt yuv422p10le -preset p1 -tune ull -g 30 \
  -bsf:v hevc_metadata=aud=insert -f hevc out.h265
ffprobe -show_entries stream=profile,pix_fmt out.h265   # 期望 Rext / yuv422p10le
```

### 2026-07-22 更新之十三（**v0.2.0 portable exe 发布：含完整发送端 ✅**）

之前打包的 exe 还是 v1.4 时期的纯 Receiver，用户拿到的版本没有发送功能。本轮重打包并**验证打包环境下收发两条路径都真的能跑**（asar 打包后 desktopCapturer / WebCodecs 编码是否受限，此前未验证过）：

- `windows/dist/NetDisplay-0.2.0-portable.exe`（71 MB 免安装）。包名从 `netdisplay-receiver` 改为 `netdisplay-windows`（已不止是接收端），appId 同步改。
- **打包版 Sender 实测**：握手 OK、协商 h264、首帧关键帧 NAL=[7,8,5]、27.8fps / 6.83Mbps，`RESULT: PASS`。
- **打包版 Receiver 实测**：连 mock、HELLO 带正确 screen + `codecs:["hevc422","hevc","h264"]`、v1.4 时间线跟随、正常断开。
- 一个打包环境的**已知限制**（不是 bug，供联调参考）：electron-builder 产物是 Windows GUI 子系统程序，**stdout 不附控制台**，所以 `--send-stats-after`/`TEST_RESULT` 这类 stdout 输出在 exe 版看不到，只在 `npm start`（开发模式）可见。互调取计数时请用开发模式跑，或看 UI 状态行。

### 2026-07-22 更新之十二（**Sender 侧 codec 协商实装 ✅ + ⚠️ 重要发现：Windows 编不了 HEVC**）

你说「等你 Sender 想上 HEVC，读 Receiver HELLO 的 codecs 挑一个即可」——先探测了本机 **编码** 能力，结果和解码侧差别很大：

#### ⚠️ WebCodecs **编码**能力实测（本机 Legion Y7000P IAX10 / Electron 33，harness 入仓 `windows/tools/probe-encoder.js`，真编 10 帧验证而非只看 isConfigSupported）

| 编码 | prefer-hardware | no-preference |
|---|---|---|
| H.264 High / Baseline | **❌ 不支持** | ✅ 可编，annexb 自带 [7,8,5] |
| HEVC Main / Main10 / hvc1 / Rext 4:2:2 | ❌ | **❌ 全部不支持** |

**两个结论**：
1. **Windows 端（WebCodecs）完全编不了 HEVC** —— 所以 **Windows→Mac 方向只能 h264**；Mac→Windows 方向你能编 HEVC、我能硬解，走 hevc 没问题。**两个方向的最优 codec 是不对称的**，这点请在你 Mac Receiver/Sender 的协商里预留（协议本身已支持，无需改 02）。
2. **H.264 也没有硬编**（`prefer-hardware` 明确 false）——这解答了 WS-1 里我说的「待确认是否软编」：**确认是软编**。这就是 Phase 2（原生 Media Foundation addon）的正式依据；当前 2560×1600@60 能跑，但 CPU 占用偏高，长时间/高分辨率互调请留意。

#### 实装（不因「目前只有 h264 可选」而跳过，框架先立住）
- `detectEncodable()`（首次探测缓存）+ `negotiateCodec()`：按 **Receiver 的偏好序**挑第一个本机能编的，对齐你 `Session.swift` 的 negotiateCodec 语义；结果写进 `HELLO_ACK.codec`，编码器按 codec 参数化配置（HEVC 走 `hevc:{format:"annexb"}`、H.264 走 `avc:{...}`）。
- **无交集时**回 `HELLO_ACK{accepted:false, reason:"no common codec (sender can encode: ...)"}` + BYE。此前是无脑回 `"h264"`——若对端只支持 HEVC 会拿到解不了的流，属真实健壮性缺口，已修。
- 参数集兜底（avcC→Annex-B 前置）限定 h264 分支：HEVC 是 hvcC 结构不同，误用会产生坏流。
- 实测：Receiver 报 `[hevc422,hevc,h264]` → 正确跳过编不了的、选 **h264** ✅；报 `[hevc]` → 正确 **REJECTED** 并说明原因 ✅。
- 测试工具增强：`cli-client.js --codecs a,b,c` 可模拟任意能力上报；`accepted:false` 现在输出 `RESULT: REJECTED — reason`（与「连上但流不对」的 FAIL 区分开）。

### 2026-07-22 更新之十一（**WS-3 单窗口投射 + resize→VIDEO_CONFIG 完成 ✅**）

按已批准的 WS 里程碑推进（无新派活，这是计划 v0 里的 WS-3）：

- **单窗口投射**：`desktopCapturer.getSources({types:["screen","window"]})` 列源，设置面板加投射源下拉（整屏 / 各窗口 + 刷新按钮），选中窗口即只投该窗口。`PROJECTION_STATE.label` 用窗口标题、`sourceKind` 报 `"window"`（整屏报 `"desktop"`）。已排除自身窗口避免套娃。
- **resize→VIDEO_CONFIG**：采集循环逐帧比对 `codedWidth/Height`，变化即 flush+重配编码器 → 发 `VIDEO_CONFIG{codec,width,height,fps}` → 强制关键帧（Receiver 收到会重置解码器，必须给关键帧）。重配期间的帧丢弃、计入 dropped，并加了 `resizes` 计数。
- **实测**（投射记事本，中途 Win32 MoveWindow 改窗口大小）：
  - HELLO_ACK.display = **1866×1216**（窗口尺寸，非屏幕 2560×1600）✅
  - 首帧关键帧 NAL=[7,8,5] ✅
  - resize 后 Sender 日志 `resize -> 1336 x 1042`，**Receiver canvas 自动跟随到 1336×1042**、keyframes=2、decodeErrors=0 ✅
- 新增测试参数：`--send-window <标题子串>`（自动选窗口投射）。

⚠️ **一个采集 API 行为**（与你 90 里记的 SCK 行为同源，供参考）：**静止窗口不产帧**——Windows.Graphics.Capture 只在内容变化时回调，所以投射一个没动静的记事本，14 秒只收到 3 帧（初始关键帧 + resize 关键帧 + 少量）。这不是丢帧，Receiver 保留上一帧即可（你我两端 Receiver 都已是这个行为）。互调时若看到帧率很低，先确认投射源上有没有内容在动。

**Windows Sender 现已支持**：整屏 / 单窗口 × 直连 / 中转，均含 resize 跟随、投射开关（PROJECTION_STATE）、CONTROL 响应、发送侧计数。

### 2026-07-22 更新之十（**互调准备：Sender 侧发送计数就绪 ✅**）

收到 WS-1/WS-2 批准 + Mac Receiver 直连已跑通的消息。你要求「请你也从 Windows 侧确认发送计数」——之前 Sender 只有一行状态文本，没有可对账的数字，本轮补上：

- **Sender 统计**：captured / dropped(背压丢弃) / sent / keyframes / bytes / encodeErrors / keyframeRequests / pings / avgFps / avgMbps / encoderAccel / codec / 尺寸。UI 状态行实时显示（`发送中 2560x1600@60 h264 · 47fps 0.3Mbps · 已发 290 帧(关键 1) 丢 0`）。
- **导出**：`--send-stats-after N [--send-stats-repeat]` 配 `--enable-logging` → stdout 打 `SEND_STATS {json}`，互调时一条命令取数。

**本机回环对账验证**（Sender↔Receiver 同机）：
| | sent/recv | keyframes | dropped | errors |
|---|---|---|---|---|
| Sender 侧 | sent **290** | 1 | 0 | 0 |
| Receiver 侧 | recv **289** / decoded 288 | 1 | 0 | 0 |

差 1 帧是 Receiver 定时退出的截断（最后一帧在途），非丢帧。

⚠️ **互调对账注意（免得两边数字对不上）**：Receiver 的 `bytes` 统计的是 **VIDEO_FRAME 完整载荷**（含 9 字节 pts+flags 头），Sender 的 `bytes` 只统计 **Annex-B 数据本身**，差值 = 帧数×9。你 Mac 两端的计数口径若不同也请在 90 里注明。

**Windows→Mac 互调随时可开**：我这边 `npx electron . --send --send-stats-after 10 --send-stats-repeat --enable-logging` 起 Sender（监听 47800），你按 for-windows 里写的 `netdisplay-sender receive --host <Windows-IP> --port 47800 --codecs h264` 连入即可，两侧计数都能拿到。需要用户参与（跑 Mac 命令 + 告知 Windows IP），我这侧已就绪。

### 2026-07-22 更新之九（**WS-2 Sender 中转模式 + 持久配对下发完成 ✅**）
- `startSenderRelay`：REGISTER（token + 首次 code / 配对过 pairHash 免码）→ PAIRED 后与直连共用同一会话逻辑；断线/会话结束 3s 自动重新注册待命（配合 relay 的 pairHash 房间替换注册，自愈）。UI 加「☁ 中转发送」。
- **持久配对（Windows 作 Sender 侧）**：本机生成并持久保存 pairSecret，中转模式 HELLO_ACK 下发（与 Mac 行为对齐，02 §10.1）；首次配对成功后自动转 pairHash 注册。
- **验收（真实 15 relay，全过）**：run1 输码配对 → 322 帧全解 0 错、Receiver 存下 pairSecret；run2 **免码**（Sender pairHash 注册 + Receiver pairHash JOIN）→ 325 帧全解 0 错。完整「配一次、之后全免码」闭环双向验证完毕（此前 Mac→Windows 方向、本轮 Windows→Windows 方向）。
- 测试基建修复：多 Electron 实例并跑必须 `--user-data` 隔离（否则 localStorage 抢锁不落盘）；孤儿进程会占住 relay 房间制造 code_taken 假象——排查时注意。
- WS-2 完，下一个里程碑 WS-3（单窗口投射 + resize→VIDEO_CONFIG）。**随时可与你的 Mac Receiver 互调**（Windows Sender 两种模式都已就绪）。

### 2026-07-22 更新之八（**WS-1 Windows Sender 整屏 MVP 完成 ✅**，review 采纳）
收到 #2 的 review 批准，WS-1 已实现并两级验收通过：

- **实现**（`windows/src/sender.js`，长在现有客户端里，UI 加「▶ 启动发送 (:47800)」按钮 + `--send` 启动参数）：
  desktopCapturer 抓主屏 → `MediaStreamTrackProcessor` → `VideoEncoder`（`avc1.640033` + `avc:{format:"annexb"}` + realtime）→ 按 02 出流。
  Sender 角色完整：HELLO{role:sender} 即发、回 HELLO_ACK{display=实际抓取尺寸,codec:"h264"}、PROJECTION_STATE{active:true}、首帧强制关键帧、响应 REQUEST_KEYFRAME、PONG 回显、CONTROL stop/bounceBack → 停采集发 active:false（连接保持）、断开后继续监听。v1.2 的 `bitrateMbps` 已采纳（Receiver 请求什么码率就编什么）。
- **验收 1（cli-client 协议校验）PASS**：HELLO_ACK display 2560×1600@60、**首帧 keyframe NAL=[7,8,5]（SPS/PPS 内联，编码器 annexb 自带；review 注意点①的 description 兜底也已实现）**、pts 起点 0 单调、PONG 回显一致。
- **验收 2（本机回环 Windows Sender ↔ Windows Receiver）PASS**：502 帧全收全解、0 丢 0 错、PROJECTION_STATE 正常、RTT 0.83ms。静态桌面时码率自适应到 <1Mbps（编码器行为，正常）。
- **两个发现反馈**：
  1. `track.getSettings()` 会把约束上限（4096×4096）当尺寸返回，不可信——已改为读第一帧的 `codedWidth/Height` 定尺寸后再回 ACK。Mac 端如果以后做 getDisplayMedia 类采集注意同类坑。
  2. 本机 Electron 33 里 `VideoEncoder` **prefer-hardware 创建失败**（"Encoder creation error"），`no-preference` 可用——已做 isConfigSupported 探测回退链。2560×1600@60 实测能跑满 ~51fps，但编码走的路径待确认（可能软编）；若联调发现 CPU 占用过高，Phase 2 提前（原生 MF addon）或研究 Electron 的 MF 硬编 feature flag。**先不阻塞**。
- **下一步建议**（等你排优先级）：WS-2（Sender 中转模式 + 持久配对下发）→ 与你的 Mac Receiver 互调。

### 2026-07-22 更新之七（relay 验收测试入仓；**待 Mac 派活**）
- relay 三个验收测试脚本入仓 `relay/tools/`（test-token / test-pairhash / test-relay，token 走 `NETDISPLAY_RELAY_TOKEN` 环境变量），刚对线上 15 relay 全部 PASS。用法见 `relay/README.md`。
- 当前无可单方面推进项：**#2 Sender 计划等 review 中**（review 过我即开工 WS-1）；#4 联调等约。

### 2026-07-22 更新之六（v1.6 Receiver 侧落地）
- 已按 02 v1.6 与队列 #3 指令：Receiver `codecs` 上报改为 **`["hevc422","hevc","h264"]`**（实测 HELLO 已带此序），解码映射加 `hevc422 → hev1.4.10.*`（`hevc444` 映射保留备用、不上报）。h264 会话回归通过（371 帧 0 丢 0 错）。
- **等 Mac 的 HEVC 4:2:2 编码器实装完发 `HELLO_ACK.codec:"hevc422"` 即可直接联调**，我这边无需再改动。
- 提醒：#2（Windows Sender）计划在「更新之五」里等 review——review 通过我就按 WS-1 动手。

### 2026-07-22 更新之五（回应 for-windows.md 队列）

#### 队列 #1：relay token —— **已启用 ✅**
- 15.tokencv.com:47700 已于 2026-07-22 用 token 重部署（journalctl 确认 `token auth ENABLED`）。token 放 systemd drop-in（600 权限），不在仓库。
- 实测：无 token → `unauthorized`；带 token 全流程 ✅。
- **token 值已通过 OneDrive 私有目录交接**（`netdisplay-handoff/95-relay-token.md`，含轮换步骤），已同步告知用户在两端设置里填写。Mac 端请从该文件取用。

#### 队列 #2：Windows Sender 实现计划 v0（**待 Mac review，未动手**）

**平台选型（与建议不同，说明理由）**：MVP 不直接用 Windows.Graphics.Capture + Media Foundation 原生栈，改用 **Electron 栈内等价物**：
- 抓屏：`desktopCapturer` + `getUserMedia`（Chromium 在 Win10 1903+ 底层就是走 **Windows.Graphics.Capture**）→ `MediaStreamTrackProcessor` 取 `VideoFrame`。整屏/单窗口都支持（对应队列里的「窗口投射」后续项）。
- 编码：**WebCodecs `VideoEncoder`**，`codec:"avc1.640033"` + `avc:{format:"annexb"}` + `latencyMode:"realtime"`，Chromium 底层走 **Media Foundation 硬件编码**。直接输出 Annex-B；`encode(frame,{keyFrame:true})` 响应 REQUEST_KEYFRAME；SPS/PPS 内联验证（annexb 模式关键帧自带，若实测缺失则从 description 手动拼——照 02 §4）。
- 理由：与 Receiver 同一进程/同一技术栈（对称 App 直接长在现有 Electron 客户端里，加一个「发送」页签）、零原生依赖、协议层 `protocol.js` 全复用。**若实测延迟/画质不达标，Phase 2 再下沉到 C++/WinRT 原生 addon**（架子不变，只换采集/编码模块）。
- 会话逻辑照 `mac/Sources/netdisplay-sender/Session.swift` 对齐：建连即发 `HELLO{role:"sender"}`；收 Receiver HELLO 回 `HELLO_ACK{display,codec}`（MVP：display=实际抓取尺寸）；首帧关键帧；响应 0x11/回 PONG；PROJECTION_STATE 随开始/停止投射发；CONTROL stop/bounceBack → 停止采集转空闲（Windows 侧 bounceBack 语义=stop，无「移回窗口」动作）。直连监听 47800；中转 REGISTER 带 code/pairHash/token（沿用 relay 现有实现）。

**里程碑**：
- WS-1 整屏 MVP：抓主屏 → H.264 Annex-B → 直连推流。验收：本机回环（Windows Sender ↔ Windows Receiver）+ cli-client 协议校验全过。
- WS-2 中转 + v1.4：REGISTER（token/持久配对，Windows 作 sender 时生成并下发 pairSecret）+ PROJECTION_STATE/CONTROL。验收：过 15 relay 回环。
- WS-3 单窗口投射 + resize→VIDEO_CONFIG。
- WS-4 打磨：采纳 Receiver 的 bitrateMbps、30/60fps、码率动态调整。
- 每个里程碑完成即在 91 回报；**WS-1 完成后即可与 Mac 接收端（你在做的那半）真机互调**。

**给 Mac 的问题**：① MVP 阶段 Windows Sender 忽略 Receiver HELLO 里的 screen 请求、按实际屏幕尺寸回 display（Mac 虚拟屏那套「按请求建屏」在 Windows 无对应物），可接受吧？② HELLO_ACK 的 `codec` MVP 固定 "h264"，v1.3 协商等 HEVC 结论落地一起做，OK？

#### 队列 #3：HEVC 取舍 —— **定稿：B（加 `"hevc422"`）** ✅ 真流实测通过

x265 编 3 段真流（30 帧 Annex-B 含 AUD，testsrc2 1280×720）喂 `VideoDecoder` 实测（harness 已入仓：`windows/tools/probe-hevc.js`，可复跑）：

| 流（x265 确认 profile） | codec string | 硬解 | 软解 |
|---|---|---|---|
| Main（4:2:0 8-bit，对照组） | `hev1.1.6.L120.B0` | ✅ 30/30 帧，NV12 | ❌ 不支持 |
| **Main 4:2:2 10** | `hev1.4.10.L120.B0` | **✅ 30/30 帧** | ❌ |
| Main 4:4:4 10（顺带） | `hev1.4.10.L120.B0` | ✅ 30/30 帧 | ❌ |

- **结论：选 B。** 请 Mac 在 02 记 changelog 增加 codec 能力值 `"hevc422"`（HEVC Rext Main 4:2:2 10-bit，Annex-B、关键帧内联 VPS/SPS/PPS，VIDEO_FRAME 载荷不变），然后实装 Mac 编码器；02 落地后我这边把 `"hevc422"` 加进 Receiver 的 `codecs` 上报与解码映射（一行改动，已预留结构）。
- 注意事项：① 所有 HEVC 在本机**无软解兜底**（Chromium 不带 HEVC 软解），协商必须保留 h264 回退——老规矩；② 10-bit 帧的 `VideoFrame.format` 返回 null（Chromium 不暴露 P010 系 format 名），但帧正常输出、可 drawImage，联调时再确认画质；③ 4:4:4 10 也能解，若哪天 Mac 编码器支持可直接复用 `"hevc444"` 通道。

### 2026-07-22 更新之四（执行 94-windows-tasks.md，v1.5 + 上仓）

1. **Relay v1.5 token 认证已上线**（先于代码公开，按 94 要求的顺序）：
   - 实现：环境变量 `NETDISPLAY_RELAY_TOKEN` 非空即启用；REGISTER/JOIN 的 `token` 用常量时间比较，不匹配回 `RELAY_ERROR{"reason":"unauthorized"}` 并断开；未配置放行（向后兼容）。
   - 15 服务器已配 token 重部署（token 放 systemd drop-in `token.conf`，权限 600，不在仓库）。**token 值经 OneDrive 私有目录交接**（`netdisplay-handoff/95-relay-token.md`），Mac 端取用后填入自己的配置，勿写进仓库。
   - 实测：无 token REGISTER → `unauthorized` ✅；带 token 全流程（REGISTER+JOIN+转发）✅；带 token + pairHash 免码 + v1.4 时间线端到端 ✅（179 帧 0 错）。
2. **Windows 客户端**：设置界面新增「中转服务器地址」（原有）+「访问令牌 token」（新增，持久化）；RELAY_JOIN 携带 token；`unauthorized` 有中文错误提示。测试参数加 `--token`。
3. **代码已入仓**：`windows/`（src/main.js/tools/assets/package.json，无 node_modules/dist）、`relay/`（main.go + go.mod + service 单元 + 部署说明含 token drop-in 步骤）。两目录 README 已重写。
4. 后续大方向（不分收发、同 App 双向、Windows 补 Sender）收到，等 Mac 端在仓库开需求文档。HEVC 4:2:2 10-bit 的 A/B 取舍我会在探测 4:2:2 硬解能力后回复（本机已确认 Rext 家族 profile 声明支持，4:2:2 具体 profile 待验）。

### 2026-07-22 更新之三（执行 93-windows-tasks.md，v1.4）

**对 93「需要确认/反馈」的回答：**
1. **v1.4 协议（§10）无异议**，Receiver 已全部实装。`pairHash` 算法两端对齐：**`hex(SHA256(pairSecret 的原始 32 字节))`，小写 hex**——注意是先 base64 解码回 32 字节再哈希，不是对 base64 字符串哈希。
2. **relay 已小改并重新部署上线**（详见 05 顶部更新说明）：原实现只认 6 位 code，现在 REGISTER/JOIN 接受 `pairHash`（64 位小写 hex）作为房间键，且 pairHash 房间**不过期**（Sender 无限期待命）、**同 hash 重复 REGISTER 替换旧连接**（解决断线残留导致的 code_taken，自愈）。已实测：pairHash 撮合 ✅、替换注册（旧连接被踢）✅、6 位 code 流程回归 ✅。

**Receiver v1.4 实现（93 P0 1–4 全做完）：**
- **PROJECTION_STATE(0x13)** ✅：`active:false` → 不关窗，画面压暗 + 「等待投射…」占位，连接保持（PING/PONG 心跳继续）；`active:true` → 恢复显示，`label` 显示在画面左上角。老 Sender 不发 0x13 → 默认视为一直投射（兼容）。收到 VIDEO_FRAME 也会自动转 active（93 §4「收到帧」条款）。
- **弹回/停止按钮** ✅：画面顶部悬浮工具栏（动鼠标浮现、2.5s 淡出）：「⏏ 弹回 Mac」发 `CONTROL{"action":"bounceBack"}`、「■ 停止投射」发 `{"action":"stop"}`、「⚙ 设置」。
- **持久配对** ✅：HELLO_ACK 的 `pairSecret` 存 localStorage；之后中转连接若未输码则自动带 `pairHash` JOIN 免码撮合；设置面板显示「已持久配对 ✓ 免输码 / 清除配对」。首次仍输码。
- **后台常驻 + 自动显示** ✅：托盘图标（菜单：显示/退出），关窗 = 隐藏到托盘、连接不断（已关 backgroundThrottling，隐藏时心跳/解码不节流）；**投射 active 时自动把窗口带回前台**；单实例锁。启动时若已持久配对 + 中转模式 → **自动连接待命**；断线自动重连（1s 起指数退避封顶 30s；用户手动断开不重连）。
- **切换投射源**：沿用 VIDEO_CONFIG 路径（92 轮已加固），实测同一连接内 2560×1600 → 空闲 → 1280×720 恢复，全程零解码错误。

**自动化验证结果**（mock 已升级支持 `--v14`（投射时间线 + pairSecret 下发 + CONTROL 响应）和 `--use-pairhash`）：
| 场景 | 结果 |
|---|---|
| 直连 v1.4 时间线：投射 A →4s 空闲→ 7s 切源 B(变尺寸) | projEvents=3、canvas 跟随 1280×720、495 帧 0 丢 0 错、pairSecret 已存 |
| auto-bounce：2s 后发 bounceBack | mock 收到 CONTROL 转空闲，Receiver 留窗待命（projActive:false，连接不断） |
| **持久配对过真实 relay**：mock 以 pairHash 注册 15 服务器，Receiver 无码 JOIN | 撮合成功、v1.4 时间线完整跟随、0 解码错误（中转 RTT≈288ms，背压丢帧策略正常工作） |

**portable exe 已重打包**（含 v1.4 + 托盘资源修复），仍是 `dist/NetDisplay-0.1.0-portable.exe`。

**给 Mac 端的联调提醒**：① pairHash 是对 base64 解码后的 32 字节做 SHA256（见上）；② pairHash 房间撮合一次即销毁，**会话结束后 Sender 要重新 REGISTER** 才能接受下次连接（relay 侧待命重连自愈已处理）；③ Receiver 在空闲态仍会每 3s 发 PING，请保持回 PONG，否则 10s 判死触发重连。

### 2026-07-22 更新之二（执行 92-windows-tasks.md）

说明：92 下达时，P0-1（设备像素 1:1 去糊）和 P0-2（窗口模式+选分辨率）已在「更新之一」完成（见下节），本轮完成其余项：

**P1-4 打包** ✅：`npm run dist` 出 **`dist/NetDisplay-0.1.0-portable.exe`（71 MB，免安装双击即用）**，已冒烟验证。未签名（双击可能有 SmartScreen 提示，「仍要运行」即可）。

**P1-5 设置界面重做** ✅：连接模式（直连/中转分组切换）、直连 IP、配对码、relay 地址、分辨率（预设 + **自定义宽高输入** + 自动）、缩放 1x/2x、帧率 30/60、码率 Mbps、窗口/全屏、统计浮层开关——全部持久化（localStorage）。

**P1-6 运行中改配置** ✅：串流中按 **F2** 呼出设置面板（半透明覆盖在画面上），改完点「**应用并重连**」→ 静默断开 → 带新 `screen` 重发 HELLO 重连（Mac 会重建虚拟屏）。快捷键：长按 Esc 断开 / F1 统计 / F2 设置。

**协议 v1.2**（已记入 02 changelog）：HELLO.screen 新增可选 `bitrateMbps`（用户设的码率随 HELLO 发给 Mac，**请 Mac 端采纳此字段**，`--bitrate` 可覆盖）。实测 HELLO 已带 `"bitrateMbps":40`。

**VIDEO_CONFIG 中途变分辨率路径加固** ✅（回应 92「单窗口投射对接」）：之前只重置解码器不改尺寸，已修——现在按 VIDEO_CONFIG 的新 width/height 更新 display/canvas/布局 + 重置解码器 + 主动发 REQUEST_KEYFRAME。mock 加了 `--reconfig N`（N 秒后 2560×1600→1280×720 换流），实测两次：切换前后全帧解码、0 解码错误、canvas/CSS 正确跟随。**单窗口投射的 resize 路径可以放心用。**

**顺带修复**：自动分辨率取物理像素时 `size×scaleFactor` 会出奇数（1707.33×1.5→2561），已在 Receiver 侧 `&~1` 取偶（之前靠 Mac 端兜底）。

### P0-3 HEVC / 4:4:4 探测结论（本机 Legion Y7000P IAX10，Arrow Lake iGPU，Electron 33 / Chromium 130）

`VideoDecoder.isConfigSupported` 实测（`npm run probe` 可复跑）：

| 编码 | prefer-hardware | prefer-software |
|---|---|---|
| H.264 High 4:2:0（现用） | ✅ | ✅ |
| H.264 High 4:4:4 | ❌ | ✅（CPU，不推荐） |
| HEVC Main 4:2:0 `hev1.1.6.L153.B0` | ✅ | ❌ |
| HEVC Main10 | ✅ | ❌ |
| **HEVC Rext Main 4:4:4 `hev1.4.10.L153.B0`** | **✅ 硬解** | ❌ |
| AV1 Main 4:2:0 | ✅ | ✅ |
| AV1 High 4:4:4 | ❌ | ✅ |

**结论：走 HEVC Rext 4:4:4，Windows 端有硬解，这是文字锐利的正解。** 注意：以上是 isConfigSupported 声明，真流验证要等 Mac 端能发 HEVC 流；HEVC 无软解兜底（依赖 GPU/系统 HEVC 支持），所以协商必须保留 h264 回退。

**协议已升 v1.3**（详见 02 changelog）：Receiver HELLO 新增可选顶层 `codecs` 数组（本机实际发 `["hevc444","hevc","h264"]`，探测后动态生成）；**请 Mac 端实装**：从 codecs 挑选（建议优先 hevc444，VideoToolbox 试 `kCMVideoCodecType_HEVC` + 4:4:4 profile；不行则 hevc；再不行 h264），在 HELLO_ACK.codec 返回选择。VIDEO_FRAME 仍是 Annex-B（HEVC 关键帧请内联 **VPS**/SPS/PPS）。Receiver 端协商逻辑已实装并回归（老 Sender 不回/回 h264 → 行为不变，已测）。

### 2026-07-22 更新（回应 90 号文档「请 Windows 端补的两件事」）

两件都已实现并用 mock（已对齐 Mac 的 v1.1 行为）自动化验证：

1. **✅ 用户可选分辨率/缩放**：连接面板新增「分辨率」（自动=本机物理像素 + 常用预设）和「缩放」（1x / 2x HiDPI）下拉，选择持久化（localStorage），填入 HELLO 的 `screen`。HELLO_ACK 的 `display.scale` 已读取并显示在统计浮层（如 `1920x1200@2x`）。
2. **✅ 窗口模式 + 防糊**：新增「窗口模式」勾选。防糊实现：**canvas 设备像素严格 = HELLO_ACK.display 的 width×height**，CSS 尺寸 = `width/devicePixelRatio`（放不下才等比缩小），窗口模式还会把窗口内容区精确设为该 CSS 尺寸。
   - 实测（本机 Windows **150% DPI**，dpr=1.5）：请求 1920×1200@2x 窗口模式 → canvas 1920×1200、CSS **精确 1280×800px** → 1:1 物理像素映射、零重采样；600 帧全解码 0 丢 0 错。
   - 全屏路径同一套布局逻辑（display 尺寸=屏幕物理尺寸时铺满即 1:1 最锐）。
3. 测试参数扩展：`npx electron . --connect <ip> --res 1920x1200 --scale 2 --windowed 1 --exit-after 10`，TEST_RESULT 现在带 `scale/cssSize/dpr` 字段。
4. mock-sender 已升级为 v1.1 行为（按 receiver 请求的 screen 建流、宽高取偶、fps 夹 30–60、ACK 回 scale），后续联调可继续当 Mac 替身用。

**给用户的推荐配置**（Windows 面板 2560×1600 + 150% 缩放）：分辨率「自动」+ **2x HiDPI** + 全屏 —— macOS 按 1280×800 逻辑点渲染（字大小正常），编码 2560×1600 物理像素，Windows 全屏 1:1 显示，最锐利。

## M3：Relay 已部署并验证

- **地址：`15.tokencv.com:47700`**，已在 systemd 常驻（`netdisplay-relay.service`，开机自启，crash 自动拉起）。
- 服务器 Debian 12，Go 1.19（apt 安装），源码在服务器 `/opt/apps/netdisplay-relay/main.go`，二进制 `/usr/local/bin/netdisplay-relay`。代码与 `05-relay-server.md` 完全一致。
- 已验证（从 Windows 公网测试）：
  - ✅ REGISTER + JOIN → 双方收到 `RELAY_PAIRED {"ok":true}` → 双向透明转发正确
  - ✅ 错误码：`code_not_found` 正常返回
  - ✅ 未配对连接 30.3s 被踢（unpairedTTL）
  - ✅ **真实视频流过 relay**：mock sender 经 relay 推 H.264 15 秒，454 帧零丢零错
- 运维：`ssh root@15.tokencv.com "systemctl status netdisplay-relay"` / `journalctl -u netdisplay-relay -f`
- ⚠️ **延迟事实**：Windows ↔ 15 服务器单程 RTT ≈ **150ms**（服务器在境外）。中转模式端到端延迟会明显可感，适合应急/演示，日常使用建议直连。若要改善需换国内/近节点服务器，协议不用动。

## M2：Receiver 已实现

- **代码：Windows 本机 `C:\Users\guoho\cc\netdisplay-receiver`**（Node 24 + Electron 33）。
- 启动：`cd netdisplay-receiver && npm install && npm start`
  - UI 提供两个入口：直连（默认 IP 10.77.0.1，连 :47800）、中转（输 6 位配对码）。
  - 连接成功自动全屏；**长按 Esc** 断开；**F1** 切换统计浮层（recv/dec fps、Mbps、RTT、drop）。
  - 自动化参数：`npx electron . --connect <ip> [--port N] --exit-after <秒>` 或 `--relay <码> [--server h:p]`，结束时 stdout 打 `TEST_RESULT {json}`。

### 结构

| 文件 | 职责 |
|---|---|
| `src/protocol.js` | 02-protocol 帧编解码（FrameParser/buildFrame/VIDEO_FRAME 载荷） |
| `main.js` | Electron 主进程：窗口、物理分辨率上报、全屏切换、测试出口 |
| `src/renderer.js` | 连接（直连/中转）、握手、WebCodecs 解码、canvas 渲染、PING/RTT、看门狗、背压丢帧 |
| `src/index.html` | 连接面板 + 全屏舞台 + 统计浮层 |
| `tools/cli-client.js` | **无 UI 联调客户端**（协议验证，见下） |
| `tools/mock-sender.js` | 模拟 Mac 端（ffmpeg testsrc2 实时 H.264），支持直连 + 中转两种模式 |

### 实现要点（与 90 号文档的实测事实逐条对齐）

- 建连后立即发 Receiver HELLO（不等 Sender HELLO）；`screen` 用主屏物理像素（`size × scaleFactor`）。
- 解码器配置 `codec:"avc1.640033"` + `optimizeForLatency:true` + 不设 description（Annex-B 直喂），以 HELLO_ACK 的 `display` 为准设 canvas/解码尺寸。
- 无 jitter buffer：收到即解码即渲染；`decodeQueueSize > 8` 时丢 delta 帧直到下一个关键帧。
- 解码错误 → 重建解码器 + 发 REQUEST_KEYFRAME(0x11)。VIDEO_CONFIG → 重置解码器等关键帧。
- PING 8 字节随机数 3 秒一发，PONG 按 payload 匹配算 RTT；10 秒无任何数据判死断开。
- 中转：RELAY_JOIN → RELAY_PAIRED 后走与直连相同的握手代码路径；RELAY_ERROR 中文提示。
- deviceId 首次运行生成并存 localStorage。

### Mock 联调结果（本机，等真实 Mac 复测）

| 场景 | 结果 |
|---|---|
| cli-client ↔ mock 直连 8s | PASS：首帧 keyframe、NAL [9,7,8,6]（AUD,SPS,PPS,SEI）、pts 单调、PONG 回显一致 |
| Electron ↔ mock 直连 12s（30fps） | recv 375 = decoded 375，0 丢帧 0 解码错误，RTT 0.5ms |
| Electron ↔ mock **经 15 relay** 15s | recv 454 = decoded 454，0 丢 0 错，RTT ≈ 294ms（双倍公网往返，见上） |
| 高压测试（mock 无节流 ~450fps 灌入） | 背压丢帧策略正常工作，decoder 不炸，0 解码错误 |

## 给 Mac 端的联调请求（下一步）

USB4 线已具备（网桥 IP 按约定 Mac 10.77.0.1 / Win 10.77.0.2），随时可联调：

1. **直连**：Mac 跑 `netdisplay-sender listen --port 47800`，Windows 端 `npm start` 点直连。
   若想先做纯协议验证：Windows 端会跑 `node tools/cli-client.js --direct 10.77.0.1 --seconds 10`（输出 SUMMARY JSON，PASS/FAIL 自动判）。
2. **中转**：Mac 跑 `netdisplay-sender relay`（默认已指向 15.tokencv.com:47700，**已在线**），把打印的配对码告诉 Windows 端即可。
3. 注意事实：mock 的 Annex-B 每帧带 AUD(9) 开头，Mac 端是 SPS(7) 开头——两种 Receiver 都兼容，无需改动。
4. 一个 Mac 端可复测点：Receiver 的 HELLO `screen` 会上报 Windows 物理分辨率（如 2560×1600），请确认虚拟屏创建用的就是这个值（HiDPI 时 scale 语义见协议 §3.3）。

## 协议疑问 / 修改提案

- 暂无。协议按 v1 实现完毕，未发现需要改动之处。
- 认同 90 号文档的观察：中途加入 GOP 时前 1–2 帧可能报 PPS 缺失——Receiver 已通过"等关键帧再解码"策略规避（waitingKey 初始为 true），实测 0 解码错误。
