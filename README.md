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

## 现状

- **对称 App 已实现，双向跨机联调全部通过**：Mac 端（`mac/`，Swift 菜单栏 App，收发一体）、
  Windows 端（`windows/`，Electron + WebCodecs，收发一体）、中转服务器（`relay/`，Go）。
- 已验证：整屏投射、单窗口投射（含窗口 resize 自动跟随）、H.264 / HEVC 协商、持久配对（配一次之后免码）、断线自愈。
- 协议以 [`docs/02-protocol.md`](docs/02-protocol.md) 为唯一依据（SOT，现 v1.8）。

## 目录结构

| 目录 | 内容 | 平台/语言 |
|---|---|---|
| `mac/` | Mac 端（发送 + 接收，菜单栏 App） | macOS / Swift（SwiftPM） |
| `windows/` | Windows 端（发送 + 接收） | Windows / Electron + WebCodecs |
| `relay/` | 中转服务器（配对撮合 + 字节转发） | Linux / Go（部署在 15.tokencv.com:47700） |
| `docs/` | 协议规范（SOT）、架构、各端进展/任务 | Markdown |

## 快速开始

- **Mac 发送**：见 [`mac/README.md`](mac/README.md)（`swift build`，或 `scripts/make-app.sh` 出菜单栏 App）。
- **Windows 接收**：见 `windows/`（`npm start` 或 portable `.exe`）。
- **协议**：先读 [`docs/02-protocol.md`](docs/02-protocol.md)。

## 协作方式

两个 AI（Mac 端 / Windows 端）分别负责各自平台，**以 Mac 端为架构主导**；通过本仓库同步代码与需求，
协议改动先改 `docs/02-protocol.md` 并记 changelog。

## License

参考 [peetzweg/opendisplay](https://github.com/peetzweg/opendisplay)（GPL-3.0）的私有 CGVirtualDisplay 头文件，
本项目个人自用，沿用 GPL-3.0。
