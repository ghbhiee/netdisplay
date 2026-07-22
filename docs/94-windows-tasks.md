---
date: 2026-07-23
tags: [netdisplay, handoff, windows, tasks, github, security]
---

# 给 Windows 端的任务（GitHub 上仓 + relay token 认证）

> 仓库转**公开**了。所以中转服务器要加 **token 认证**防公网滥用，客户端两端把 **relay 地址 + token 做成可配置项**（不硬编码进仓库）。协议已升 **v1.5**（见 02 §7 + changelog）。

## 1. GitHub：上代码到同一个仓库
- 仓库（Mac 端已建，公开）：**（Mac 端 push 后把 URL 贴这里 / 或你 `gh repo list ghbhiee` 找 `netdisplay`）**。
- 你 `git clone` 后，把 Windows 端代码放到 **`windows/`**、relay 的 Go 源码放到 **`relay/`**，各自 commit push。
  - `windows/`：src/、main.js、tools/、package.json 等（**不要提交 node_modules/、dist/**，根 .gitignore 已忽略）。
  - `relay/`：`main.go`、go.mod、部署说明（**不要提交编译产物/二进制**）。
- 根 `README.md`、`docs/`（协议 SOT + 各端进展）已在仓里；协议改动先改 `docs/02-protocol.md` 记 changelog。

## 2. Relay 加 token 认证（v1.5，重要）
- relay 启动时从**环境变量/配置**读一个 `token`（**不要硬编码进仓库**）。
- `RELAY_REGISTER`/`RELAY_JOIN` 现在可带 `token` 字段：
  - relay 配置了 token → 校验，**不匹配就回 `RELAY_ERROR{"reason":"unauthorized"}` 并断开**。
  - relay 未配置 token → 放行（私网/向后兼容）。
- 15.tokencv.com 那台请配上 token 并重部署。**公开仓库前这步最好先上线**，否则公网上一个开放 relay 会被白嫖。

## 3. Windows 客户端：relay 地址 + token 可配置
- 设置界面加两项：**中转服务器地址**、**token**（持久化）。中转模式连接时把 token 放进 `RELAY_JOIN`。
- 默认不要硬编码某个具体服务器（可留 15.tokencv.com 作示例占位，但让用户能改）。

## 4.（继续之前的）待办
- v1.4 你已全做完（91 里确认）；HEVC：Mac 编不了 4:4:4，最好 4:2:2 10-bit——见 93，A/B 取舍你反馈。
- **大方向（新）**：项目要做成**不分收发、同一 App 同时能发能收、跨平台**。Windows 以后要补**发送**功能（抓屏/窗口→H.264/HEVC→按协议发）。Mac 会补**接收**。细分需求 Mac 端（我）后续在仓库里给你开 issue/需求文档。

## 优先级
**relay token 认证 + 重部署 → GitHub 上 windows/ 和 relay/ → 客户端地址/token 设置项 → 后续发送功能**。
