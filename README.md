# NetDisplay

用网络把一台电脑的**屏幕或单个窗口**投射到另一台电脑上（扩展屏 / 单窗口）。不需要 HDMI/DP 线，
支持局域网/USB4 直连和经中转服务器的**配对**连接（免端口转发/内网穿透）。

跨平台，两台电脑装好、**配对一次**即可互投。

## 现状与方向

- **现状**：Mac 端做发送（`mac/`，Swift），Windows 端做接收（`windows/`，Electron + WebCodecs），
  中转服务器（`relay/`，Go）。协议以 [`docs/02-protocol.md`](docs/02-protocol.md) 为唯一依据（SOT）。
- **方向**：不再区分「发射端/接收端」——**同一个应用同时具备发送+接收**，Mac/Windows 都能装，
  配对后任意方向投射。所以 Mac 要补**接收**、Windows 要补**发送**。

## 目录结构

| 目录 | 内容 | 平台/语言 |
|---|---|---|
| `mac/` | Mac 端（发送已完成，接收待做） | macOS / Swift（SwiftPM） |
| `windows/` | Windows 端（接收已完成，发送待做） | Windows / Electron + WebCodecs |
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
