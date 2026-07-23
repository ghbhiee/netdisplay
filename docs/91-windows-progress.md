---
date: 2026-07-22
tags: [netdisplay, handoff, windows, progress]
---

# Windows 端进展（Receiver + Relay）

> 维护者：Windows 端 Claude。与 `90-mac-progress.md` + `02-protocol.md` 三方异步协作。

## 当前状态：**#1 ✅；#3 定稿 B 且 Receiver 侧 v1.6 已落地 ✅；#2 Sender 计划仍待 Mac review**

### 2026-07-23 更新之三十九（**配对码持久化发版 v0.3.1 + 一条流程教训**）

用户实测反馈「发送端每次启动随机生成配对码」。

#### ⚠️ 教训：代码修了 ≠ 用户拿到了
这个 bug 我在界面重做那轮（22:54）**就已经修了**（`my.pairCode` 持久化）。但用户在跑的 **v0.3.0 exe 打于 9:46**，比修复早 13 小时——**修复在仓库里，从没到过用户手上**。

差一点就回复「我这边早修好了」然后收工，那样用户的问题会原样留着。
→ **功能修复必须顺带确认「用户实际在跑的版本里有没有」，只看仓库不算数。** 尤其这种 portable exe 手动分发、没有自动更新的场景。

#### 已发 v0.3.1
`NetDisplay-0.3.1-portable.exe`，sha256 `137dbbdb8019a86c21002e1a215ca6aa265a35c1a5edd4d6fb42722bc3a1c673`，已挂到 v0.3.0 release（0.3.0 保留便于对比回滚）。

**验证没有只看代码**：实测打包版，同一 user-data 连开三次 exe，读 localStorage 确认**三次都是同一个码 `460268`** ✅。另加单测 `tools/test-paircode.js`（首次生成 = 同进程再取 = 存储中）。

#### ⚠️ 给 UI 重做的提醒
这个修复目前只存在于**被否掉的那版 UI** 里（配对码的显示与输入框都在那版界面上）。设计稿回来重做时**这两个必须保留**：① 显示我的配对码（要能念给对方）② 输入对方配对码。已在频道提醒 Mac 写进设计交接文档。

### 2026-07-22 更新之三十八（**技术栈定为留在 Electron + v1.9 连接升级实现**）

#### 技术栈：留在 Electron（用户拍板）
我原推荐 Tauri，核心理由是「WebView2 也有 WebCodecs，管线可原样保留」。**实测不成立**（`tools/probe-webview2.js`，同机同日）：

| 引擎 | H.264 | HEVC 4:2:0 | Main10 | **HEVC Rext 4:2:2** |
|---|---|---|---|---|
| Electron 33（Chromium 130） | ✓ | ✓ | ✓ | **硬解 ✓** |
| WebView2 / Edge 150 | ✓ | ✓ | ✓ | **❌ 硬解软解都不支持** |

**新版 Chromium 反而丢了 Rext 支持。** 换 Tauri 会直接失去刚跨机验过的 4:2:2 接收能力。
影响范围（别夸大）：Windows **发送** 4:2:2 不受影响（走 ffmpeg/NVENC 不经 WebCodecs）；Mac 编不出 4:2:2 所以 Mac→Win 本就是 4:2:0；真正丢的只有 **Windows 作为接收端解 4:2:2**（Win↔Win 高画质）。
→ **教训：别假设「新版本 ⊇ 旧版本」。** 已同步 Mac。
UI 观感问题交由设计稿解决（用户已委托设计师统一两端），**不靠换框架**。

#### v1.9 连接升级（中转 → 直连）已实现
`HELLO.lanAddrs` 双向互告 + 待命时后台试直连 + 握手成功才切。**实测升级成功**：
```
[recv] 尝试直连升级 → 192.168.50.40:47800, 28.0.0.1:47800
[recv] ✅ 已升级到直连 192.168.50.40:47800（原中转连接关闭）
[recv] HELLO_ACK: {"codec":"hevc422","display":{"width":2560,"height":1600,"fps":60}}
```

**途中修的三个 bug，每个都是「静默不生效」类型**：
1. **`lanAddrs` 恒为空**：靠调用方传参，而有 5 处入口调用 `startSender*`，漏一处就表现为「升级永不触发且无任何报错」。→ 改为 sender 内部直接向主进程要。
2. **`projActive` 初值为 `true`**（为兼容不发 PROJECTION_STATE 的老 Sender），导致握手阶段一律判成「投射中」，升级被全部挡掉。→ 判据改为 `projActive && 已收到帧`。
3. **新连接被当并发拒绝**：升级时对端带新 socket 连过来，旧中转会话还占着 `active`，被 `sock.destroy()` 拒掉 → 表现为「切过去了但没画面」。→ 改为让新连接顶替。

#### ⚠️ 端到端视频未能验证（环境限制，非代码问题）
升级后 `recv=0`。**做了对照实验**：纯直连（不经升级）同样 `recv=0` 且无 HELLO_ACK → **说明问题不在升级逻辑，而是机器锁屏时屏幕采集拿不到画面**（Desktop Duplication 在锁定会话下不产帧，与早先记录的「静态桌面不产帧」同源）。
**待机器解锁后需重跑一次端到端验证**——当前只能确认「链路切换与握手成功」，不能确认「切换后视频连续」。

### 2026-07-22 更新之三十七（**界面重做：用户反馈「完全看不懂」——换掉错误的抽象轴**）

用户原话：「设置界面完全看不懂，怎么又出来一个自动？**主屏应该选择监听还是连接**」。这个批评是对的，照做重构。

#### 核心改动：把「自动/直连/中转」换成「监听 / 连接」
**旧模型错在抽象轴选错了**：「直连 vs 中转」是**传输方式**（实现细节），用户根本不该被迫理解；而「自动」更是为了掩盖前者的复杂度又加的一层概念。
**新模型**只问一个问题：**我等对方连我，还是我去连对方**——这正好对应协议里的 A 位 / B 位，也就是刚实现的角色编排。
- **等待对方连接我**：本机同时监听 `47800`（供局域网直连）+ 用长期配对码在中转注册。对方用哪种方式都能连上。
- **我去连接对方**：填对方配对码或局域网地址。**两个都填就并行竞速**，先握手成功的胜出。
→ **「自动」这个概念自然消失了**：它不再是要选的模式，而是"填了什么就试什么"的自然结果。

#### 其余按用户要求逐条落实
- **屏幕参数移到最外层**（分辨率/缩放/帧率一行三个），随时可改，不再埋进任何分组。
- **配对码长期有效**：持久保存不再每次随机（旧行为会让对方反复来问），UI 大号显示便于念给对方，另有「换一个」按钮。
- **相关参数放在所属选择下面**：监听模式下面才显示「我的配对码 / 本机地址」，连接模式下面才显示「对方配对码 / 对方地址」。中转服务器、token、码率收进「高级设置」折叠区。
- **原生观感**：Segoe UI Variable、Windows 11 配色与控件尺寸、亮/暗自动跟随系统、去掉网页感的大圆角卡片与渐变。
- **应用图标**（`tools/make-icon.js` 生成，无第三方依赖）：两块叠放的屏 + 投射信号弧。初版信号弧被前屏遮住一半、小尺寸下糊成一团，调整到后屏空白处才清晰。
- **托盘菜单对标 Mac 菜单栏**：不只「显示/退出」，可直接切分辨率/缩放/帧率/投射源、开始或停止投射、复制配对码，不必先叫出主窗口。菜单项状态由 renderer 实时推送，选中项高亮。

#### 验证
用浏览器面板做了视觉验证（机器锁屏，截应用窗口只能截到锁屏）。折叠态与展开态布局均正确。回归：role 单测 20/20、发送端 PASS、接收端 PASS。

### 2026-07-22 更新之三十六（**W3(b) Windows 侧实现：连接角色编排落地**）

Mac 已把规范折进 `10-ux-model`（两端权威一致），本轮实现 Windows 侧。

#### 新增 `windows/src/role.js`
只回答一个问题：「这次该谁 listen」。实现规范第 2/4/5/6 条——deviceId 字典序定默认角色、反转、断线回默认、抢投裁决。

#### 20 项单元测试全过（`tools/test-role.js`）
重点验的不是单端行为，而是**两端一致性**——因为算错只会在跨机时暴露成「双方都 listen 谁也连不上」，本地单端根本测不出来：
- **两端必须互补**：四组 deviceId 组合下，两端各自独立计算，结果永远一个 A 一个 B ✓
- **反转后仍互补** ✓（换投射方向的场景）
- **断线回默认**：反转态 → `resetToDefault()` → 双方都回到 deviceId 决定的位置 ✓
- **抢投裁决互斥**：`winsContention` 在两端结果相反，不会双赢或双输 ✓

#### 已接进主流程
- **HELLO 时记住对端 deviceId** 并持久化——下次连接不必先握手就知道该谁 listen。实测日志：`已确定默认连接角色：本机 B 位（主动连接）`。
- **「投射本机」按位分流**：A 位直接开投不重连；B 位先 `CONTROL{stop}` 让对方转空闲 → 标记反转 → 重建连接 → 开投。
- **断线自动回默认角色**，但用 `switchingDirection` 标记区分「有意的换向断线」与「异常断线」——前者不该重置刚设好的反转状态。
- **解除配对时一并清角色状态**，否则会拿旧 peerId 算出错误角色。

#### 回归
发送端 PASS、接收端 PASS（角色判定正确、HQ 路径仍走 hevc422）、role 单测 20/20。

#### 待做（下一轮）
待命常驻连接（A 位持续 listen 且不投射、B 位持续 dial 并自动重连）——这需要把 sender 的「接受连接」与「开始采集」拆开，目前 sender 一有 Receiver 连入就立刻开始采集。

### 2026-07-22 更新之三十五（**W1 收官 + ⚠️ 实测推翻「Phase 2 降 CPU」这条论据**）

#### ① HQ 会话 SEND_STATS（与 Mac recv=1583 同一次会话）
```json
{"codec":"hevc422","encoderAccel":"ffmpeg:hevc_nvenc","path":"hq","width":2560,"height":1600,
 "fps":60,"sent":1604,"keyframes":14,"dropped":0,"bytes":10544404,"encodeErrors":0}
```
对账：sent 1604 vs recv 1583（差 21 = 快照时点差）、keyframes 14=14、两侧 errors=0。三项路径证据（codec / encoderAccel / path）确认真走 NVENC 4:2:2。

#### ② CPU 对比 —— **结果与我的预期相反**
同一发送端、同一投射源，只靠对端上报的 codecs 切换路径；统计全部 electron 子进程 + ffmpeg 的 CPU（只测主进程会漏掉 GPU/渲染进程和 ffmpeg 子进程，数字无意义）：

| 路径 | 协商 | CPU秒/20s | 整机占用 | 平均fps | **每帧 CPU** |
|---|---|---|---|---|---|
| 基线 WebCodecs 软编 | h264 | 17.69 | 4.4% | 56.7 | **15.59 ms** |
| HQ ffmpeg+NVENC | hevc422 | 37.47 | 9.4% | 58.7 | **31.86 ms** |

**HQ 每帧 CPU 高 104%（约 2 倍），不是降低。**

**原因**：我原方案吹的「全程 GPU 零拷贝」不存在（#78 已自曝）——ddagrab 出 D3D11 帧、NVENC 收不了，必须 `hwdownload` 拷回系统内存。2560×1600 BGRA @60fps ≈ **1 GB/s 的 memcpy**，这笔开销吃掉了 GPU 编码省下的部分还倒贴。编码确实在 GPU 上，但**搬运不是**。

**Phase 2 的价值要重新表述**：
- ✅ **画质**：真 4:2:2 10-bit，文字/细线不再被 4:2:0 色度下采样糊掉——**成立且已跨机验证**
- ❌ **降 CPU**：**不成立，反而升 2 倍**——这是我提方案时的错误论据，**收回**

绝对值都不高（整机 4.4% vs 9.4% / 20 核），HQ 作为可选高画质模式仍值得保留，但**不该再宣传成省 CPU，也不该因此设为默认**。定位仍按边界①：WebCodecs 是默认基线，HQ 是可选增强，理由从「画质+降CPU」改为「**纯画质**」。

**唯一的翻盘杠杆**：绕开 hwdownload 做 GPU 内直通。已试 `hwmap=derive_device=cuda` 的两个变体（`scale_cuda=format=yuv420p` / `p010`）均失败，暂无可行配方。

#### 📌 方法学教训（与 #83 同源）
第一版我只比原始 CPU，得出「高 145%」——**那是不公平的**，因为两条路径帧率可能差好几倍。加帧数归一化（每帧 CPU）后才得到上面可比的数。
→ 与「PASS 但没测到东西」是同一类问题：**指标本身没错，错在没确认两边在比同一件事**。基准测试必须先确认可比性（帧率、分辨率、内容），再看数值。
（bench 脚本入仓 `windows/tools/bench-cpu.ps1`，可复跑。）

### 2026-07-22 更新之三十四（**W3(b) 选项 A 连接角色编排规范 —— Mac #25 的前置依赖，请照此实现**）

> 这是 UX 模型「选项 A」的可实现细化。两端必须完全一致，否则会出现「双方都在等对方拨号」的死锁。
> 有异议先在频道提，改完这里再实现。

#### 1. 角色的两层含义（先分清，否则后面全乱）
- **连接角色**：谁 `listen/register`（下称 **A 位**）、谁 `dial/join`（**B 位**）。
- **投射角色**：谁是来源（sender）、谁是目标（receiver）。

协议里两者**绑定**：A 位 = sender、B 位 = receiver。这就是「换投射方向必须重建连接」的根因（见 #78）。

#### 2. 默认角色：deviceId 字典序
```
deviceId 较小的一方 = A 位（listen / register）
deviceId 较大的一方 = B 位（dial / join）
```
比较用 **UTF-8 字节序**（JS 的 `<`、Swift 的 `<` 对 ASCII UUID 结果一致）。deviceId 已在 HELLO 中互换且两端持久化。

**首次配对时还不知道对方 deviceId** → 临时规则：**用户在哪端点「投射本机」，哪端就是 A 位**（中转 register / 直连 listen）。HELLO 交换后双方各自算出默认角色，**连同 pairSecret 一起持久化**，此后一律按默认角色。

#### 3. 待命：连接常驻，不投射
配对后，**A 位持续 listen/register，B 位持续 dial/join 并自动重连**。连接建立即完成 HELLO/HELLO_ACK，但 A 位立刻发 `PROJECTION_STATE{active:false}`。
- 两端 UI 都显示「等待投射…」。
- 这保证了「对方一开始投射，我这边自动显示」——因为连接**早已建好**，不是临时去连。

#### 4. 谁想投 → 怎么走
| 场景 | 动作 | 是否重连 |
|---|---|---|
| **A 位想投** | 直接开采集 + 发 `PROJECTION_STATE{active:true}` | **否**（A 本就是 sender） |
| **B 位想投** | 断开 → **角色反转**（B 改 listen/register、A 改 dial/join）→ 重建 → 开投 | **是**（直连 <100ms、中转 ~1s，UI 显示「切换中…」） |

**反转后不再自动转回**：谁在投谁占 A 位，避免停止投射时又抖一次连接。

#### 5. 断线重连一律回到默认角色 ⚠️
这条是**防死锁的关键**：反转状态下若连接断开，两端各自重连时必须有确定的角色，否则可能双方都 listen（谁也连不上）或都 dial（无人接受）。
```
连接断开（非主动切换） → 双方都丢弃当前反转状态 → 回到 deviceId 默认角色重连
```
代价：断线前若 B 在投，重连后回到「A 位常驻、无人投射」的待命态，用户需重新点一次投射。**这是有意的取舍**——确定性优先于自动恢复。

#### 6. 抢投时序（复用 CONTROL，不加消息）
B 正在投、A 想投：
```
1. A → CONTROL{action:"stop"}
2. B 收到 → 停采集 → PROJECTION_STATE{active:false} → 主动断开
3. 双方按默认角色重建（A 位 listen/register、B 位 dial/join）
4. A 开投 → PROJECTION_STATE{active:true}
```
第 2 步由 **B 主动断开**，因为 B 当前占着 A 位，只有它让出连接才能重建。

**同时抢投（双方几乎同时点）的裁决**：收到 `CONTROL{stop}` 时，若自己也正在发起投射请求，则**比较 deviceId，较小者胜**（与默认角色规则同源，保证两端裁决一致）。较大者放弃本次请求并让出。

#### 7. 直连模式的补充
直连没有 relay 撮合，**双方都要知道对方地址**（配对时各自记录对端 IP）。A 位 `listen(47800)`、B 位 `dial 对方IP:47800`，角色判定与中转完全相同。

#### 8. 我这侧的实现状态
- 已实现：抢投时先发 `CONTROL{stop}`、连接方式收发共用、投射源切换不断连。
- 待实现（本轮继续）：deviceId 默认角色计算与持久化、待命常驻连接、反转重建、断线回默认。

**请 Mac 按本节实现，任何一条觉得不合理先在频道提出——两端不一致会直接导致连不上。**

### 2026-07-22 更新之三十三（**🎉 W1 完成：真 4:2:2 跨机验证通过；W2 子进程健壮性**）

#### W1（WS-5d）：Phase 2 收官 —— 真 HEVC 4:2:2 跨机零错
| | codec | 路径 | 帧 | 关键帧 | 丢帧 | 错误 | bytes |
|---|---|---|---|---|---|---|---|
| Win Sender | **hevc422** | `ffmpeg:hevc_nvenc` / `path:"hq"` | sent 1604 | 14 | 0 | 0 | 10,544,404 |
| Mac Receiver | **hevc422** | VTDecompressionSession | recv 1583 / decoded 1583 | 14 | 0 | 0 | ~10.5 MB |

NVENC 产的真 Rext 4:2:2 10-bit 流，经中转，Mac 硬解**全解零错**。关键帧 14=14 对上，帧差 21 是快照时点差。

#### ⚠️ 但第一次测「PASS 了却没测到东西」
Mac 首轮报 PASS，我核对自己的 `SEND_STATS` 发现 `codec:"h264"`、`encoderAccel:"no-preference"` —— **走的是 WebCodecs 软编基线，4:2:2 一帧没跑**。原因是它的 interop-test 硬编了 `--codecs h264`。
两侧帧数、字节、errors=0 全都完美对上，**只看这些指标会直接把 W1 记成完成**。
→ **跨端联调除了对账「数量」，必须对账「走的是哪条代码路径」**。为此我在 `SEND_STATS` 里留了 `encoderAccel` / `path` 字段，对端的 `RECV_STATS.codec` 起同样作用。已提醒 Mac，它带 `--codecs hevc422` 重测才拿到上面的真结果。

#### W2：子进程健壮性（边界⑥）
- **崩溃分类处理**：「从没产出过帧就退出」= 配置/权限/源不存在，重启无意义 → 直接上报；「产出过帧后崩溃」= 瞬时故障（设备被抢、驱动重置）→ **指数退避重启**（500ms 起，封顶 8s，上限 5 次），重启后首帧仍是关键帧，对端自然恢复。
- **stdout 背压**：ffmpeg 按帧率恒定产出、不会自己等待，socket 积压超 2MB 就丢帧并等下一个关键帧（避免对端拿到依赖已丢帧的 P 帧而花屏）。状态行显示丢帧数与重启次数。
- **停止时清理**：`projectionStop` 会 `clearTimeout` 待执行的重启，否则停完还会被拉起来。

#### 🐛 W2 途中自己制造并修掉的 bug（教训值得记）
写完背压后测试：协商正确、HELLO_ACK 正常，**但一帧都没发出去**。根因是 `BACKPRESSURE_BYTES` / `MAX_HQ_RESTARTS` 两个常量**我根本没定义**——每帧回调都抛 `ReferenceError`，而异常被 `stdout.on("data")` 的调用栈静默吞掉，**表现成「能握手但零帧」，从外部完全看不出原因**。
→ 已给 `onFrame` 回调加 try/catch，异常转成明确的 `onError` 上报。**任何「宿主调用用户回调」的地方都该这样包**，否则回调里的错误会伪装成功能不工作。

### 2026-07-22 更新之三十二（**WS-5a 收官：HQ 路径接入 codec 协商，端到端跑通**）

#### 分流规则
`detectEncodable` 现在把 ffmpeg HQ 与 WebCodecs 两套能力合并上报，会话按协商结果分流：
- 判据是「**WebCodecs 编不了这个 codec**」而非「HQ 可用」——两者都能编时优先零依赖基线，保持行为稳定（边界①：HQ 是增强不是默认替换）。
- 实测能力：`encodable: hevc422,h264 | WebCodecs: h264 | HQ: hevc_nvenc`。

#### 端到端验证（本机回环）
| 对端上报 codecs | 协商结果 | 实际路径 | 结果 |
|---|---|---|---|
| `h264` | h264 | 基线 WebCodecs | HELLO_ACK 正常 ✓ |
| `hevc422,h264` | **hevc422** | **HQ ffmpeg/NVENC** | 60fps、5.4Mbps、149→390 帧连续、关键帧周期正确 ✓ |

`HELLO_ACK` 回 `{"codec":"hevc422","display":{"width":2560,"height":1600,"fps":60}}`，尺寸正确。

#### 🐛 途中修的一个必现问题：HQ 路径的尺寸从哪来
WebCodecs 路径的尺寸来自 `VideoFrame.codedWidth`，但 ffmpeg 路径**只有流里才有**——抓到多大取决于屏幕/窗口，事先不知道。初版给 `display` 填了 0，对端会按 0×0 配解码器直接黑屏。
**解法：从 HEVC SPS 解析尺寸**。实现时踩到一个坑：`pic_height_in_luma_samples` 是 **CTU 对齐后的编码尺寸**——1280×720 的流解出来是 **1280×736**，必须再减去 `conformance_window` 的裁剪量才是真实显示尺寸（4:2:2 时水平 sub=2、垂直 sub=1）。用已知样本验证：修正前 `1280x736 ✗`，修正后 `1280x720 ✓`。
解析失败时**宁可发 BYE 也不发错尺寸**——发 0 或错值只会让对端黑屏且无从排查。

#### 另一个诊断教训
第一次测 HQ 报 FAIL，我差点当成功能缺陷。实际是 **HQ 探测要真编 30 帧验证色度，首次握手比 5 秒的测试窗口慢**。加长测试窗口后即通过。**探测型功能要把「首次调用耗时」计入测试超时**，否则会把慢当成坏。

### 2026-07-22 更新之三十一（**按 10-ux-model 重构 Windows UI + 逮到代理环境下的误判 bug**）

#### 重构内容（对齐 UX SoT）
- **连接方式提升为唯一的一处设置**（`自动 / 直连 / 中转`），收发共用。**删掉了「▶ 直连发送 (:47800)」「☁ 中转发送」两个并列按钮**——那是把 transport 和 role 两个正交概念塞进同一个按钮，正是用户觉得乱的根源。
- **主控制收敛为「● 投射本机 ▾（源）/ ■ 停止投射」**，走直连还是中转由上面的连接方式决定，用户不再感知 listen/dial、register/join。
- **角色栏仅在已连接/投射时出现**（没连接时点「投射本机」没有对象）。
- **抢投编排**（ux-model）：作为目标时点「投射本机」，先 `CONTROL{stop}` 让对方转空闲，再重建为来源，UI 提示「切换中…」。
- 画质区改标「**作为目标时的画质**（本机被投射时用；对方采纳）」——明确归属，不再和「发送」混淆。
- 默认模式改为 `auto`；文案去掉「Mac」字样（通用对称：任意两台，不是 Windows 专门当 Mac 副屏）。

#### 🐛 实现自动模式时逮到一个环境相关的真 bug
初版 happy-eyeballs 用「**TCP connect 成功**」作胜出判据。测「直连不可达 → 应回退中转」时，程序却报 **「已直连 10.99.99.99」** 然后黑屏。
**根因：本机装了 Mihomo/Clash 代理，它接管了出站 TCP，连一个根本不可达的地址 `connect` 也会成功。** 于是竞速误判、还把真正能通的中转链路给关掉了。
**修复：胜出判据改为「收到对端的协议响应」**（直连收到 Sender `HELLO`、中转收到 `RELAY_PAIRED`），只有对端按协议应答才证明这条路真的通到 NetDisplay 而不是通到某个代理。竞速期用临时解析器，胜出后把已读出的帧补回正式解析器（否则会丢掉 Sender HELLO）。
- 实测：真可达 → 正确直连（79 帧全解，RTT 1ms）；不可达 → 不再谎报成功，明确提示「直连和中转都没握手成功——确认对方已在投射，且地址/配对码正确」。

⚠️ **这个坑对任何做连通性探测的功能都成立**：在有代理/VPN 的机器上，`connect` 成功不代表连到了目标。判定「对端是不是我们要找的服务」必须依据**应用层应答**。

#### 回归
发送路径（cli-client 直连 PASS）、接收路径（76 帧 0 错）、自动模式两条分支均验证通过。CLI 入口按 ux-model 要求保持不变。

### 2026-07-22 更新之三十（**WS-5a/b 采集管线完成：两条 HQ 路径均 PASS**）

`windows/src/ffmpeg-capture.js` + 自测 harness `tools/test-hq-capture.js`。

#### 实测结果（30fps，有动态内容）
| 路径 | 帧 | 关键帧 | 首帧关键帧 | 参数集内联 | 码率 | 结论 |
|---|---|---|---|---|---|---|
| 整屏 `ddagrab` | 174 | 3 | ✓ | VPS+SPS+PPS ✓ | 6.51 Mbps | **PASS** |
| 单窗口 `gdigrab` | 175 | 3 | ✓ | ✓ | 3.29 Mbps | **PASS** |

pts 单调、AU 边界正确、零错误。**边界⑦放开后的单窗口 HQ 路径确认可行**，用户强调的一等特性能享受到 4:2:2。

#### 实现要点
- **AUD 切帧**：按 HEVC AUD（NAL 35）定位 AU 边界，缓冲里至少见到两个 AUD 才切出一个完整 AU，末尾未完成的留到下一批。关键帧判定用 IRAP 区间（NAL 16–23），不是只认 IDR。
- **两条路径的关键差异**：`ddagrab` 输出 D3D11 帧**必须** `hwdownload`；`gdigrab` 本就是系统内存帧，**加了反而报错**——这点容易踩，代码里按 source.kind 分支处理。
- **子进程生命周期（边界⑥）**：stderr 全程留尾 4KB 并按 error 级别上报；非主动退出一律视为异常并把 stderr 尾部带出；`stop()` 后用 `taskkill /T` 兜底清子进程树。**实测 stop() 后 ffmpeg 残留数 = 0**。
- **REQUEST_KEYFRAME**：周期 GOP 模式下无法中途强制 IDR，只记日志说明「最长等待 N 秒」（边界④，已与 Mac 确认接受）。

#### 失败路径同样验证
抓一个不存在的窗口 → `frames=0`、明确报错且**原因可读**：
```
ffmpeg 未产出任何帧就退出（code=...）
Error opening input file title=根本不存在的窗口xyz.
```
不会静默退回整屏——与 `requireWindow`、`ffmpeg-probe` 的显式路径处理保持同一原则。

#### 下一步
接进 `sender.js` 的 codec 协商：探测到 HQ 且对端 codecs 含 `hevc422` 才走这条，否则回退 WebCodecs 基线；`HELLO_ACK.codec` 反映实际路径。

### 2026-07-22 更新之二十九（**WS-5a 开工：HQ 探测模块完成**）

WS-5 计划已获批准（边界⑦放开，单窗口也走 HQ）。第一块交付：`windows/src/ffmpeg-probe.js`。

#### 探测不只查「有没有」，而是真编真验
Mac 端 VideoToolbox 的教训是**「接受 Main42210 profile 却把输出降成 4:2:0」**——所以只查编码器是否被列出是不够的。本模块：查 `-encoders` 列表 → **真编 30 帧** → **ffprobe 校验输出 pix_fmt 确实是请求的那个**，降级即判不可用。
```
[hq] 验证 hevc_nvenc → 通过: Rext,yuv422p10le
HQ_PROBE {"available":true,"encoder":"hevc_nvenc","pixFmt":"yuv422p10le","codec":"hevc422",
          "detail":"hevc_nvenc 真 4:2:2 已验证（Rext,yuv422p10le）"}
```
这样 `HELLO_ACK.codec` 才能保证**反映实际路径**（边界①），不会「装了 ffmpeg 就声称 hevc422」。

#### 🔁 顺手修掉一个与 requireWindow 同构的缺陷
初版 `findBinary` 是「显式指定 → 失败则回退 PATH」。测试时传了不存在的路径，探测**仍然成功**——它悄悄用了 PATH 里的另一个 ffmpeg。
这与我刚修过的 `requireWindow`（指定窗口找不到就静默投整屏）**完全同构**：**用户明确指定的东西，找不到时不能悄悄换成别的**。指定路径通常是有原因的（某个自带 NVENC 的构建），静默替换会让人对着一个自己没选的 ffmpeg 排查问题。
已改为：显式指定时只用那个，失败即报错并说明「不会自动改用 PATH 里的其它 ffmpeg」。两条路径均已验证（无效路径 → available=false 回退基线；不指定 → 用 PATH，可用）。

#### 协助 Mac 排除 WS-5d 的前提风险
Mac 诚实提醒：它之前验证「能解 hevc422」用的流其实是 VT 降级的 4:2:0，**真 4:2:2 解码尚未实测**。
我已用 **NVENC 生成真 4:2:2 样本**（`hevc,Rext,1280x720,yuv422p10le`，60 帧含 AUD，610 KB）并放到 `15:/root/cc/agent-chat/nvenc-422-sample.h265`——这是**我实际会发的那种流**，比它自己另造的样本更有代表性，可直接喂它的 Decoder 预验，避免到 WS-5d 才暴雷。

### 2026-07-22 更新之二十八（**WS-5 / Phase-2 实现说明（含可行性实测）—— 请 Mac review**）

Phase-2 已放行。按约定先出实现说明。**下面每条设计都有实测数据支撑，不是估算。**

#### 一、可行性实测（本机：RTX 5060 Laptop + Arrow Lake iGPU）

**1) GPU 内零拷贝管线不可行 —— 我原方案里这条是错的**
`ddagrab` 输出 D3D11 硬件帧，NVENC 收不了，直接接管道报 `Invalid argument (-22)`。尝试 `hwmap=derive_device=cuda` 转 CUDA 帧（`scale_cuda=format=yuv420p` / `format=p010`）**两种都失败**。
✅ **可行路径必须经 `hwdownload,format=bgra` 过一次系统内存**，实测输出真 `Rext / yuv422p10le`。

**2) 但 hwdownload 的开销可以忽略 —— 归因测试**
| 管线 | fps | speed |
|---|---|---|
| ① 只抓屏（不下载不编码） | 58 | 0.994x |
| ② 抓屏 + hwdownload | 58 | 0.996x |
| ③ 抓屏 + hwdownload + NVENC 4:2:2 | 57 | 0.995x |

三者几乎相同 ⇒ **瓶颈完全在 ddagrab 抓屏本身，hwdownload 与 NVENC 编码的增量开销≈0**。而 `speed≈1.0x` 不是「跟不上」，是 ddagrab 按 `framerate=60` **精确限速**的正常行为（抓屏本就不该快于实时）。纯编码另测有 235fps / 3.92x 余量。
⚠️ 自我修正：静态桌面下测得 0.92x 曾让我误判为「跟不上」，实际是 Desktop Duplication **只在画面变化时产帧**（与「静止窗口不产帧」同源）。**性能测试必须在有动态内容时做**，静态桌面数据无效。

**3) 单窗口也能走 HQ 路径 —— 建议修正边界⑦**
你定的边界⑦是「ddagrab 是整桌面抓取 → 单窗口投射走不了这条 → 窗口模式暂留 WebCodecs」。但 Windows 上有 **`gdigrab -i title="<窗口标题>"`** 可直接抓单个窗口：
```
ffmpeg -f gdigrab -framerate 30 -i title="longlines.txt - Notepad" \
  -c:v hevc_nvenc -pix_fmt yuv422p10le -preset p1 -bsf:v hevc_metadata=aud=insert -f hevc out.h265
→ 实测 Rext, 1708x1255, yuv422p10le, fps=30, speed=0.991x ✓
```
**用户已明确单窗口投射是核心特性、一等公民**，若 HQ 模式只支持整屏，核心特性就享受不到画质提升。建议改为：**整屏走 ddagrab、单窗口走 gdigrab**，两者都能出真 4:2:2。代价：gdigrab 是 GDI 抓取（CPU 侧），不如 ddagrab 高效，但 30fps 下实测 0.991x 无压力；若高分辨率窗口吃力可自动降帧。**这条请你拍板是否采纳。**

#### 二、实现设计
- **新模块 `windows/src/ffmpeg-sender.js`**，与现有 `sender.js` 并列；`sender.js` 按协商结果选择走 WebCodecs（基线）还是 ffmpeg（HQ）。**WebCodecs H.264 保持零依赖基线不动**（边界①）。
- **运行时探测**（启动时一次，缓存）：`ffmpeg -encoders` 查 `hevc_nvenc`/`hevc_qsv` → 试编 10 帧验证真出 4:2:2 → 任一步失败则**优雅回退** WebCodecs。`HELLO_ACK.codec` 只在真走 NVENC 4:2:2 时回 `hevc422`（边界①）。
- **分帧**：按 `hevc_metadata=aud=insert` 保证每个 AU 以 AUD(35) 开头，**按 AUD 切 AU**（边界③）；关键帧内联 VPS+SPS+PPS（已实测合规）。
- **关键帧**：MVP 用周期 GOP（`-g` 对齐 2 秒）；`REQUEST_KEYFRAME` 只能等下一个周期 IDR，最坏黑一个 GOP（边界④，接受）。
- **resize / 改码率**：重启 ffmpeg 子进程 + 发 `VIDEO_CONFIG`（边界⑤）。窗口 resize 时 gdigrab 需重启并换新尺寸。
- **子进程生命周期**（边界⑥，新增复杂度大头）：stderr 全程监控并记日志、非正常退出自动重启（退避）、stop 时 `taskkill /T` 确保无残留、stdout 背压（写不动就丢到下个 IDR）。
- **打包**：ffmpeg **不进** portable exe（边界⑧）。运行时按序探测 `PATH` → 用户在设置里指定的路径 → 未找到则 HQ 模式灰掉并提示。

#### 三、里程碑
- **WS-5a** 探测 + 整屏 ddagrab HQ 路径，回环自测（含 codec 协商回退验证）
- **WS-5b** 单窗口 gdigrab HQ 路径（若你采纳上面的修正）
- **WS-5c** 子进程健壮性（崩溃重启、resize 重启、背压、干净退出）
- **WS-5d** 与 Mac 跨机联调 hevc422 真流，对账画质与 CPU

#### 四、风险
1. **无余量场景**：2560×1600@60 时整条管线 speed≈1.0，若 CPU 被别的负载占满可能掉帧。缓解：HQ 模式默认 30fps，用户可调。
2. **ffmpeg 依赖**：用户没装就用不了 HQ，回退基线（不影响可用性）。
3. **gdigrab 抓不到的窗口**：与 WebCodecs 路径同样受「最小化窗口不可捕获」限制，行为保持一致（明确报错，不静默降级）。

**以上请 review，尤其是边界⑦要不要放开到单窗口。你点头我按 WS-5a 开工。**

### 2026-07-22 更新之二十七（**直连取消：两机不在同一局域网；并厘清项目定位**）

#### 诊断结论（已由用户核实）
两台机器**不在同一局域网**。此前看到的相同出口 IP `121.52.252.30` 是**运营商级 NAT（CGNAT）的巧合**，不代表可直达对方私网。

我这侧的诊断链（可作为同类问题的排查范式）：
- 我的配置：`192.168.50.40`，**PrefixLength=/16**（非常见的 /24），网关 `192.168.0.1` —— 意味着我把整个 `192.168.0.0/16` 视为同一二层网络，会**直接 ARP** 找对方而不经网关。
- `ping 192.168.50.119` 失败，且 **ping 后 ARP 表无该条目**（ARP 请求无响应）；同时 ping 网关成功、ARP 表有 3 个其它动态条目。
- **判据**：ARP 无响应 ⇒ 二层不可达。这比「ICMP 被挡」严重——若只是 macOS 挡 ping，ARP 仍会响应（链路层，防火墙一般不拦），TCP 也能通。

⚠️ **给后来者的提醒**：不要因为两端「出口 IP 相同」就断定在同一局域网，CGNAT 下大量用户共享出口 IP。判定同网要看**能否 ARP 到对方私网地址**。

#### 📌 项目定位需要厘清（已向 Mac 提出）
中转 ~300ms 对「**远程查看/演示**」完全够用，但对项目最初的目标「**把 Windows 当 Mac 的第二块显示器**」是不够的：扩展屏意味着在那块屏上拖窗口、打字、移鼠标，300ms 往返会明显滞后（交互式桌面一般要求 <50ms，游戏串流做到 5–30ms）。

**准确表述：当前实现的是低延迟远程投屏，而非可交互的扩展屏。** 这不是代码问题——直连（同局域网个位数 ms）和 USB4 网桥（<1ms）两条路径代码都已支持，只是当前两台机器的物理环境不满足。建议在 `00-README`/`01-architecture` 中区分这两种定位，避免被理解为「已实现扩展屏」。换更近的 relay 节点能把 300ms 降到几十 ms，有帮助但仍达不到扩展屏门槛。

#### 状态
直连 Sender 实例已停（47800 监听释放），中转 standby 保持待命。`--host` 直连代码保留——它对真·同网段和 USB4 场景仍然有效，只是不适用于当前这对机器。

### 2026-07-22 更新之二十六（**直连路径预验证 + v0.3.0 打包**）

趁 Mac 下线的空档，把直连测试的前置条件先踩掉，免得它上线后卡在环境问题上。

#### 直连预验证（Mac 上线即可测）
- **监听正常**：Sender 监听 `::`（双栈，IPv4 可入），非仅 127.0.0.1。
- **走内网 IP 自连 PASS**：`cli-client --direct 192.168.50.40` → HELLO_ACK 2560×1600、首帧关键帧 NAL=[7,8,5]。
  ⚠️ 但**同机自连证明不了外部可达**——即使走内网 IP，Windows 通常仍走 loopback，不过防火墙。
- **防火墙已核对匹配**：本机以太网 `NetworkCategory=Public`，现有 electron.exe 入站允许规则也是 `profile=Public`，且路径精确指向在用的 `node_modules\electron\dist\electron.exe` → **Mac 的连接应能进来**。
  注意打包版是**另一个程序路径**（临时解压目录里的 `NetDisplay.exe`），有独立规则，且解压路径每次可能变。
- **我的内网 IP：`192.168.50.40`（以太网）**。Mac 上线后 `receive --host 192.168.50.40 --port 47800` 即可。连不上时的排查顺序已写进 `windows/README.md`。

#### v0.3.0 portable exe
`dist/NetDisplay-0.3.0-portable.exe`（71 MB）。相对 v0.2.0 累积：codec 协商与拒绝路径、`requireWindow` 防静默降级、背压调参（阈值 24+连续 3 次）、背压丢帧时请求关键帧、VIDEO_CONFIG 带全字段、headless 模式、`--secret/--pairhash` 共享配对、`interop.ps1`/`chat-watch.js` 工具、以及三处日志缺口修补。冒烟通过（握手、协商 h264、首帧关键帧）。

#### 💡 一个反直觉的编码坑（与之前那条正好相反）
改 `package.json` 版本号时用了 `Set-Content -Encoding utf8`，**PowerShell 5.1 的这个开关会写 BOM**，electron-builder 直接报 `readObjectStart: expect { or n, but found ﻿`。
→ **`.json` 绝不能有 BOM；而含中文的 `.ps1` 必须有 BOM**（否则按 GBK 读会解析失败，见更新之二十一）。同一个"编码"问题在两类文件上要求完全相反，改文件时要按类型区分。正确写法：`[System.IO.File]::WriteAllText($p,$c,[System.Text.UTF8Encoding]::new($false))`。

### 2026-07-22 更新之二十五（**③ 收工：resize→VIDEO_CONFIG 全绿；根因是协议字段可选性歧义**）

#### 最终对账（逐字节一致，尺寸两侧都跟随）
| | 尺寸 | 帧 | 关键帧 | 丢帧 | 错误 | bytes |
|---|---|---|---|---|---|---|
| Win Sender | **2236×1492** | sent 7 | 3 | 1（resize 重配） | 0 | **621619** |
| Mac Receiver | **2236×1492** | recv 7 / decoded 7 | 3 | 0 | 0 | **621619** |

#### 🔍 真正的根因（Mac 定位，比我的推测更精确）
我推到「收到了但没处理」，Mac 定位到了具体环节：**它的 `VideoConfig` 结构体把 `bitrateMbps` 声明为非可选**，而我发 VIDEO_CONFIG 时只带 codec/width/height/fps → **JSONDecoder 解码失败 → guard 静默 return → 每条 VIDEO_CONFIG 都被丢弃**。它已修（改可选 + 收到就 log + 同时更新解码器/统计/窗口尺寸 + 解码失败也打日志永不静默）。

#### 我这侧的加固 + 给 Mac 的协议提议
- **发送侧带全字段**：VIDEO_CONFIG 现在附 `bitrateMbps`。协议 §5 的示例里有这个字段，任何照示例把它声明为必需的实现都会踩同样的坑；发全字段对双方都更安全，不指望对端都做成可选。
- **根子上是 02 §5 有歧义**（已在频道提议，Mac 主导修改）：§5 只给了一个示例 JSON，**没说哪些字段必需、哪些可选**。它按示例做成全必需、我按「只发变化的」少发一个，双方都不算错。建议补明确：必需 `codec/width/height`，可选 `fps/bitrateMbps`（缺省=不变），并加一条**通用规则：接收方对所有 JSON 消息应容忍未知字段与缺失可选字段，不得因多一个或少一个字段而整条丢弃**。这条规则同样适用 HELLO/HELLO_ACK/PROJECTION_STATE——后面还要加字段（hevc422、直连协商等），不定死原则就会重演。

#### 📌 沉淀：这几轮所有 bug 的共同点
**全都是回环测不出、只有跨机才暴露的**：背压误判突发到达（回环 RTT<1ms 永不积压）、VIDEO_CONFIG 字段缺失导致静默丢弃（同进程 mock 字段总是齐的）、relay 双发送端互踢（单端测不出）、最小化窗口静默降级整屏（本地测试窗口总是可见）。
→ **后续新功能一律直接跨机验，回环回归通过不作为「验证完成」的依据。**

另一条：**静默失败最难查**。Mac 的 guard 静默 return 让整条链路看起来「什么都没发生」——发送侧显示已发、TCP 有序可靠、接收侧毫无痕迹，隔着机器猜了好几轮。我这几轮也补了三处同类缺口（sender 状态日志只写 DOM、`[recv]` 连接状态、VIDEO_CONFIG 收取）。**协议里每个会改变状态或可能失败的分支，都必须留一行日志。**

#### v1.4 联调项全部通过 ✅
① Win→Mac 整屏 h264（1339/1339）｜② Mac→Win 整屏 HEVC（62/62，codec 协商真实生效）｜③ 单窗口投射 + resize→VIDEO_CONFIG（本轮）｜免码重连（十余次隐式验证）

#### 下一件：直连优化
两机同出口 `121.52.252.30`。**我的内网 IP：`192.168.50.40`（以太网）**。若同网段，直连流程：我 Sender 监听 47800（不走 relay），Mac `receive --host 192.168.50.40 --port 47800`，预计把 300–600ms 中转 RTT 砍到个位数毫秒。不同网段则回退 USB4 网桥方案（10.77.0.1/10.77.0.2，<1ms，01-architecture 的原始设计场景）。

### 2026-07-22 更新之二十四（**③ 单窗口投射 + resize→VIDEO_CONFIG 跨机验证完成**）

#### 静态部分 PASS（Mac 确认）
尺寸 1866×1216（窗口而非整屏 ✓）、`label="longlines.txt - Notepad"`、`kind=window`、codec h264、errors=0。`requireWindow` 修复端到端确认：不再有静默整屏降级。

#### resize→VIDEO_CONFIG：帧/字节精确对上，但 Mac 报「没收到 VIDEO_CONFIG」
| | 帧 | 关键帧 | 丢帧 | 错误 | bytes |
|---|---|---|---|---|---|
| Win Sender | sent 5 | 3 | 1（resize 重配丢的） | 0 | **687568** |
| Mac Receiver | recv 5 / decoded 5 | 3 | 0 | 0 | **687568** |

bytes **逐字节相同**。我侧日志 `configure encoder 1636×1222 → resize -> 2236×1492`、`resizes=1`。

**自测复现证明发送/接收路径都正常**（本机接收端连本机 standby，中途 resize）：
```
[recv] VIDEO_CONFIG: {"codec":"h264","width":1336,"height":1042,"fps":60}
RECV_STATS: {"width":1336,"height":1042,"recv":85,"decoded":85,"dropped":0,"errors":0}
```
接收端尺寸正确跟随，85 帧全解零错。

**推理结论（已发 Mac）**：Mac 的 `recv=5 / keyframes=3 / bytes` 与我 `sent=5` 逐项一致，说明它**确实收到了 resize 之后的 4 帧和 2 个关键帧**——即 resize 时它是连着的。而 VIDEO_CONFIG 在同一条 TCP 流上、写在那些帧**之前**，TCP 有序可靠，不可能收到后面的帧却丢掉前面的控制帧。所以它应是**收到了但没记录/没处理**。其 `RECV_STATS.width` 停在握手值 1636×1222 未变，正是「只重置解码器、没更新尺寸」的典型症状——**与我 91「更新之四」修过的坑完全相同**。已建议它在 0x12 分支加日志，并同时更新解码器、canvas 后备缓冲、统计尺寸三处。

#### 顺带补的可观测性
receiver 的 VIDEO_CONFIG 分支此前**不打任何日志**，排查时只能靠猜——这次加上后立刻看见。（与 sender 状态日志、`[recv]` 连接日志是同一类缺口，逐个补齐中。）

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
