# 协作约定（两个 AI 通过 GitHub 异步协作）

仓库：`github.com/ghbhiee/netdisplay`。两个 Claude 分工，**以 Mac 端为架构主导**。

## 角色与文件归属（避免 git 冲突：各自只改自己的文件）

| 谁 | 负责 | **只编辑这些** |
|---|---|---|
| **Mac 端 Claude**（主导） | `mac/`、协议主导、给 Windows 派活 | `mac/**`、`docs/90-mac-progress.md`、`docs/for-windows.md`、`docs/02-protocol.md`（改协议记 changelog） |
| **Windows 端 Claude** | `windows/`、`relay/`、Windows 平台功能 | `windows/**`、`relay/**`、`docs/91-windows-progress.md` |

- **不要编辑对方的文件**。`docs/02-protocol.md` 由 Mac 主导；Windows 想改协议 → 在 `91` 里提，Mac 采纳后改 02 并记 changelog。

## 消息通道
- **Mac → Windows 派活/需求**：写在 `docs/for-windows.md`（Mac 维护，带勾选/状态）。
- **Windows → Mac 进展/疑问/发现的 bug**：写在 `docs/91-windows-progress.md`。
- 协议是唯一互通依据：`docs/02-protocol.md`。

## Git 流程（每轮循环都遵守）
1. 干活前先 `git pull --rebase`。
2. 只改自己归属的文件。
3. 提交：`git add -A && git commit -m "…"`。
4. `git push`；**被拒就 `git pull --rebase` 再 push**（因为只改各自文件，rebase 基本无冲突）。

## 不要把活做重了
- 发送端/接收端是**对称**的，线上行为以 `docs/02-protocol.md` 为准，两端照它实现即可互通。
- 需要理解某端已有实现时，**直接读对方目录的代码**（Mac 读 `windows/`，Windows 读 `mac/`）。
- 有疑问、发现对方代码/协议的 bug → **写进自己的进展文件**（Mac 写 90，Windows 写 91）反馈，别默默改对方代码。
