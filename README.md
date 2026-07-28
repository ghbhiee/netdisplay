**中文** · [English](README.en.md)

# NetDisplay

**把一台电脑当成另一台电脑的第二显示屏**，用网络连接——不需要 HDMI/DP 线。既能投**整个屏幕**（扩展屏），
也能只投**某个程序窗口**到另一台电脑上。支持局域网 / USB4 直连，和经中转服务器的**配对**连接（免端口转发/内网穿透）。

**通用、对称、跨平台**：任意两台电脑之间——Mac↔Windows、Windows↔Windows、Mac↔Mac——**谁发谁收都行**，
装好后**配对一次**即可互投。

## 使用场景与延迟（重要）

- **主场景是局域网**：同一局域网 RTT 个位数毫秒、USB4 直连 <1ms——此时是**可交互的扩展屏**体验
  （在那块屏上拖窗口、打字、移鼠标都跟手）。
- **跨公网（经中转）也能用**：延迟取决于中转节点位置（境外节点实测约 300ms），此时更接近**低延迟远程投屏/演示/查看**——
  看画面很流畅，但不适合把它当作实时交互的桌面。换个近的中转节点可把延迟降到几十毫秒。
- 一句话：**局域网 = 真扩展屏；跨公网 = 远程投屏**。都由同一套代码支持，区别只在网络。
- ⚠️ 两台机器「出口 IP 相同」**不代表能直连**（运营商级 NAT/CGNAT 的巧合，二层未必可达）——直连要真的在同一局域网或 USB4 直连。

## 下载安装

到 [Releases](https://github.com/ghbhiee/netdisplay/releases) 下载：

| 平台 | 文件 | 说明 |
|---|---|---|
| macOS 14+ | `NetDisplay-macOS.zip` | 解压得 `NetDisplay.app`，拖进「应用程序」。菜单栏出现图标。 |
| Windows 10/11 | `NetDisplay-<版本>-portable.exe` | 免安装，双击即用。 |

**macOS 首次运行**：因为是自签名，会提示「无法验证开发者」——右键点 App →「打开」→ 再点「打开」即可。
另外需要在「系统设置 → 隐私与安全性 → **屏幕录制**」里勾选 NetDisplay（投射画面必需）。

**两端都要装**：投射方和接收方都装同一个 App，谁投谁收在界面上选。

## 快速开始（配对 → 投射）

1. 两台电脑都打开 NetDisplay。
2. 任一台点「**＋ 添加设备**」，选配对方式：
   - **经中转（配对码）**——不在同一局域网时用。一端点「随机生成」得到 6 位码，另一端输入**相同的码**，
     **两端都点「配对」**，撮合成功才算配对（服务器只做撮合，不存任何数据）。
     ⚠️ 用中转必须先填好「**中转设置**」（见下一节），中转不可用时「配对」按钮是灰的。
   - **直连（对方 IP）**——在同一局域网时用，**不经服务器**。两端填**相同的配对码**＋对方的局域网 IP，各自点「配对」。
3. 配好后在「**投射本机**」页选投射内容（整块屏幕 / 某个程序窗口），点「**开始投射**」。
   对方需要先开「**接收显示**」里的接收服务。

### 投射画质（只在投射方设置）

画质由**投射方**决定，接收方不需要（也没有）画质设置：

| 你选的 | 串流分辨率 | 对方怎么显示 |
|---|---|---|
| **跟随对方屏幕**（默认） | 对方显示器的分辨率 | 第二显示器 / 全屏 |
| **指定分辨率** | 你选的值，**超过对方屏幕会自动修正**到不超过 | 窗口 |
| **投射某个窗口** | 窗口自身尺寸，同样不超过对方屏幕（**等比缩小，不变形、不放大**） | 窗口 |

投射过程中改分辨率/帧率会**实时生效**（重建画面源并通知对方），不用断开重连。

## 中转服务（Relay）——什么时候需要、怎么装、怎么用

### 需要它吗？

**同一局域网不需要**——用「直连（对方 IP）」即可，画面点对点走，延迟最低。

**两台机器不在同一网络时需要**（例如家里的 Mac 投给公司的 Windows）。中转服务器只做两件事：
**撮合配对**（把用同一个码的两端牵到一起）和**转发字节**（配对后双向透明转发）。
它**不解析视频、不存储任何数据、没有用户系统**——所以自己搭一个很轻量。

> 想直接用而不自建？在「中转设置」里填任何一台你信任的、跑着本服务的机器地址即可。
> 本项目**不提供公共服务器**，请自建（下面 5 分钟搞定）。

### 自己部署（Linux + Go 1.19+）

```bash
git clone https://github.com/ghbhiee/netdisplay.git
cd netdisplay/relay
go build -o netdisplay-relay .
sudo cp netdisplay-relay /usr/local/bin/
```

设置访问 Token（**强烈建议**，否则端口暴露在公网上谁都能用）并作为 systemd 服务常驻：

```bash
sudo cp netdisplay-relay.service /etc/systemd/system/
sudo mkdir -p /etc/systemd/system/netdisplay-relay.service.d
printf '[Service]\nEnvironment=NETDISPLAY_RELAY_TOKEN=%s\n' "$(openssl rand -hex 24)" \
  | sudo tee /etc/systemd/system/netdisplay-relay.service.d/token.conf
sudo systemctl daemon-reload
sudo systemctl enable --now netdisplay-relay
sudo journalctl -u netdisplay-relay -f     # 看日志确认「listening on :47700」
```

放行防火墙的 **TCP 47700**（直接暴露，不要套 nginx——裸 TCP 长连接转发不适合走反代）：

```bash
sudo ufw allow 47700/tcp
```

把刚才生成的 token 记下来（`cat /etc/systemd/system/netdisplay-relay.service.d/token.conf`）。

### 在 App 里使用

两端都打开「**中转设置**」，填**同样的**：

- **中转服务器地址**：`你的域名或IP:47700`
- **访问 Token**：上面生成的那串（留空 = 不鉴权，只建议内网自用）

填完会立刻显示「中转 · 可用 XXms」。只有显示可用，配对界面的「配对」才能点。

**安全性**：服务器只转发密文之外的原始字节流，不解析内容；配对码只在两端**同时**处于配对界面时才可能撮合成功，
关掉窗口即失效，不会被别人拿码蹭连。

## Windows 投「整个屏幕」：装虚拟显示器（VDD）

**只有把 Windows 当作「投射方」、并且想投出一块「新的扩展屏」时才需要。**

Windows 本身没有系统级的虚拟显示器 API（Mac 有 `CGVirtualDisplay`，所以 **Mac 不需要装任何东西**）。
不装 VDD 时，Windows 投「整个屏幕」只能把**现有的某块屏复制**过去（镜像）——你在那块屏上看到的和本机一样。
装了 VDD 会多出一块**系统认为真实存在**的显示器，把它投射出去，才是真正的**扩展屏**（可以往上拖窗口、放不同内容）。

- 装在哪台：**要投射出去的那台 Windows**（发送方）。**接收方不用装。**
- 项目地址：**https://github.com/VirtualDrivers/Virtual-Display-Driver**
  （IddCx 间接显示驱动，Windows 10/11，MIT，开源免费）
- **驱动是已签名的**（SignPath Foundation 提供的免费签名），**不需要**关闭「驱动程序强制签名」。
  网上一些老教程要你进测试模式/禁用签名强制——对这个驱动**不必要**，也不该那么做。

### 安装步骤

1. 装 [Microsoft Visual C++ 运行库](https://aka.ms/vs/17/release/vc_redist.x64.exe)（依赖 `vcruntime140`，缺了会报错）。
2. 下载 VDD，二选一：
   ```powershell
   winget install --id=VirtualDrivers.Virtual-Display-Driver -e
   ```
   或到 [Releases](https://github.com/VirtualDrivers/Virtual-Display-Driver/releases) 下载压缩包解压
   （免安装便携版）。**ARM64** 设备需要用官方说明里的手动安装方式。
3. 以**管理员**身份运行 **Virtual Driver Control (VDC)**，点 **Install**。
4. 在「设置 → 系统 → 显示」里会多出一块显示器；把它设为「**扩展这些显示器**」（**不要**选「复制」）。
   这块虚拟屏的分辨率/刷新率可以在 VDC 里加或调整。
5. 打开 NetDisplay →「投射本机」→ 投射内容的「整块屏幕」下会多出 `Screen 1 / Screen 2`——
   选**那块虚拟屏** → 开始投射。

装好后，往那块虚拟屏拖窗口，对面就能看到——这才是「多一块显示器」而不是「复制一块」。

> ⚠️ **升级显卡/芯片组驱动前，先在 VDC 里卸载 VDD**，否则可能出现黑屏或显示优先级冲突。
> 万一真黑屏：进**安全模式** → 设备管理器 → 卸载该虚拟显示适配器。

## 目录结构

| 目录 | 内容 | 平台/语言 |
|---|---|---|
| `mac/` | Mac 端（发送 + 接收，菜单栏 App） | macOS / Swift（SwiftPM） |
| `windows/` | Windows 端（发送 + 接收） | Windows / Electron + WebCodecs |
| `relay/` | 中转服务器（配对撮合 + 字节转发） | Linux / Go |
| `docs/` | 协议规范（SOT）、架构、各端进展/任务 | Markdown |

## 从源码构建

- **Mac**：`cd mac && swift build -c release`，或 `bash scripts/make-app.sh release` 出菜单栏 App。
- **Windows**：见 `windows/`（`npm install && npm start`，或 `npm run dist` 出 portable exe）。
- **协议**：改动前先读 [`docs/02-protocol.md`](docs/02-protocol.md)（唯一依据 / SOT）。

## 协作方式

两个 AI（Mac 端 / Windows 端）分别负责各自平台，**以 Mac 端为架构主导**；通过本仓库同步代码与需求，
协议改动先改 `docs/02-protocol.md` 并记 changelog。

## 作者

guohongbo · <guohongbo@outlook.com> · <https://github.com/ghbhiee/netdisplay>

## License

参考 [peetzweg/opendisplay](https://github.com/peetzweg/opendisplay)（GPL-3.0）的私有 CGVirtualDisplay 头文件，
本项目个人自用，沿用 GPL-3.0。
