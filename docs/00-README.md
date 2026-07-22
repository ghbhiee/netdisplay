---
date: 2026-07-21
tags: [netdisplay, handoff, mac, windows, streaming]
---

# NetDisplay — Mac 网络扩展屏 Handoff 总览

> **这是给 Mac 端 Claude 的 handoff 文档入口。** 请先完整阅读本文件，再按顺序阅读 01–05。
> 你的任务：**实现 Mac 端发送程序（Swift）**。Windows 端接收器和中转服务器由 Windows 端的 Claude 负责，不需要你实现，但你必须严格遵守 `02-protocol.md` 中的协议规范，两端才能互通。

## 项目目标

开发一套软件，把 Mac 的画面**扩展**（不是镜像）到一台 Windows 电脑上，把 Windows 电脑变成 Mac 的第二块显示器。不用 HDMI/DP 线，通过网络串流实现。

支持两种连接方式：

1. **直连模式**：两台电脑在同一网络（USB4 线直连组网 / 局域网），Windows 端直接 TCP 连接 Mac 端。延迟最低。
2. **中转模式**：两台电脑不在同一网络时，通过用户自己的服务器（15.tokencv.com，下称"15 服务器"）中转。**两端都主动向服务器发起出站连接，用配对码配对**，不需要公网 IP、不需要端口转发/内网穿透配置。

## 参考项目

**必读**：[peetzweg/opendisplay](https://github.com/peetzweg/opendisplay)（GPL-3.0）。请先 `git clone https://github.com/peetzweg/opendisplay` 通读其 `Mac/` 和 `Shared/` 目录。它实现了 Mac → iPhone/iPad 的同类功能，技术栈与本项目 Mac 端完全一致：

| opendisplay 文件 | 对本项目的参考价值 |
|---|---|
| `Mac/CGVirtualDisplayPrivate.h` | CGVirtualDisplay 私有 API 头文件声明，**可直接复用** |
| `Mac/VirtualDisplay.swift` | 虚拟显示器创建的核心逻辑（分辨率、HiDPI、模式设置） |
| `Mac/MacSender.swift` | ScreenCaptureKit 捕获 + VideoToolbox 编码 + TCP 发送主流程 |
| `Mac/InputInjector.swift` | 用 CGEvent 注入远端传回的键鼠事件（Phase 2 用） |
| `Mac/DisplayArrangement.swift` | 虚拟屏在系统显示排列中的定位 |
| `Shared/Protocol.swift` | 它的线上协议定义——**注意：本项目协议以 `02-protocol.md` 为准，不沿用它的** |

注意 GPL-3.0：如果直接复制它的代码，本项目也需以 GPL-3.0 发布。本项目为个人自用，可接受；`CGVirtualDisplayPrivate.h` 这类 API 声明头文件建议直接复用，其余代码建议参考思路后自行实现。

## 三个组件与分工

| 组件 | 平台/语言 | 负责方 | 文档 |
|---|---|---|---|
| **Sender（发送端）** | macOS / Swift | **Mac 端 Claude（你）** | `03-mac-sender.md` |
| **Receiver（接收端）** | Windows / Electron + WebCodecs | Windows 端 Claude | `04-windows-receiver.md` |
| **Relay（中转服务器）** | Linux / Go，部署在 15 服务器 | Windows 端 Claude 部署 | `05-relay-server.md` |

**协议规范 `02-protocol.md` 是两端互通的唯一依据（source of truth）**，任何一端想改协议，必须先更新该文档并在文档顶部的 changelog 里记录，另一端跟进。

## 已确认的环境信息

- **Windows 端**：联想拯救者 Y7000P IAX10（2025），Core Ultra 7 255HX，Windows 11 Home 25H2（build 26200）。设备管理器已确认存在 "USB4 主机路由器"，支持 USB4 host-to-host 组网。屏幕分辨率以 Receiver 运行时上报为准。
- **Mac 端**：型号待你在实现时确认（`system_profiler SPHardwareDataType`）。要求 Apple Silicon、macOS 14+。
- **USB4 直连**：两台电脑用雷电 4/USB4 线连接后，Mac 端出现"雷雳网桥"、Windows 端出现 USB4 网络适配器。约定静态 IP：**Mac = 10.77.0.1/24，Windows = 10.77.0.2/24**。
- **15 服务器**：15.tokencv.com，用户自有 VPS，已运行 nginx。Relay 监听 **TCP 47700**（直接暴露端口，不经 nginx）。部署由 Windows 端完成，你只需按协议实现客户端逻辑。

## 开发里程碑（两端对齐）

| 里程碑 | 内容 | 验收标准 |
|---|---|---|
| **M1** | Mac 端：虚拟屏 + 捕获 + H.264 编码 + TCP 监听（含 ffplay 调试模式） | 在 Mac 本机或局域网另一台机器上用 `ffplay` 能看到虚拟屏画面，延迟目测 < 100ms |
| **M2** | Windows 端：直连模式接收、解码、全屏渲染 | USB4/局域网直连，Windows 全屏显示 Mac 虚拟屏，拖窗口流畅 |
| **M3** | Relay 部署 + 两端中转模式 + 配对码 | 两台电脑各自在不同网络下，输入 6 位配对码后完成串流 |
| **M4** | 输入回传（Windows 键鼠控制 Mac）、持久配对、自适应码率、HEVC | 体验打磨 |

**你现在的目标是 M1**，完成后把结果写回 handoff 目录（见下节），Windows 端再开始 M2。

## Handoff 回写约定

你在开发过程中，把进展和两端需要对齐的信息写到本目录的 `90-mac-progress.md`（自建），包括：

- 当前完成到哪个里程碑、代码仓库位置（Mac 上的路径或 git 远程）
- 实际监听端口、启动方式、依赖安装步骤
- 对协议的任何疑问或修改提案
- 已知问题和 macOS 版本相关的坑

Windows 端会同样维护 `91-windows-progress.md`。双方通过这两个文件 + `02-protocol.md` 异步协作。

## 文档目录

- `00-README.md` — 本文件
- `01-architecture.md` — 整体架构与两种连接模式的详细设计
- `02-protocol.md` — **线上协议规范（source of truth）**
- `03-mac-sender.md` — Mac 端实现指南（你的主要工作文档）
- `04-windows-receiver.md` — Windows 端接收器规范（了解对端即可）
- `05-relay-server.md` — 中转服务器设计与部署（了解配对流程即可）
