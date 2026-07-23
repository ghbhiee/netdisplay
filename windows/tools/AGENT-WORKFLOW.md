# Agent 工作方式：Monitor（事件唤醒）与 Loop（定时唤醒）

> 给下一个 session 的自己 / 给用户的速查。这套机制不属于 NetDisplay 功能本身，
> 但决定了跨会话协作的节奏和成本，换个会话就会忘，所以写下来。

## 一、两种唤醒机制

| | **Monitor** | **Loop（cron）** |
|---|---|---|
| 本质 | 一个真的后台进程 | 调度器里的一条记录，**无进程** |
| 触发 | 进程每打一行 stdout = 一次唤醒 | 到点自动执行一段 prompt |
| 在哪看 | background tasks 列表 | `CronList`（**不在** tasks 列表里） |
| 空闲成本 | **零**（进程在等，不调模型） | 每次唤醒 = 一次带全历史的模型调用 |
| 延迟 | 事件到达即唤醒 | 最长一个周期 |
| 存活 | 到 TaskStop 或会话结束 | session-only，7 天过期；跨会话要用 `/schedule` |
| 适合 | **有明确信号源**：消息、日志、文件变动 | **无信号源的巡检**：定期拉仓库看有没有变化 |

## 二、分工与配合

```
Monitor = 被动响应：对方主动通知我
Loop    = 主动巡检：对方没通知，但世界可能变了
```

本项目的实际配置：
- **Monitor 盯 agent-chat** → Mac 一发消息秒级唤醒（主力）
- **Loop 定时 git pull** → 兜底「Mac 只 push 代码没在频道说话」的情况（真发生过多次）

**实测经验**：有 Monitor 覆盖时，5 分钟的 Loop 绝大多数唤醒都是空转——因为消息到达时 Monitor 已经先叫醒了。**间隔拉到 20–30 分钟更合适**。

### 反模式
| 别这么做 | 原因 |
|---|---|
| 用 Loop 轮询有信号源的东西 | Monitor 零成本且更快 |
| 用 Monitor 做定时巡检 | 它是事件驱动，没事件不响 |
| Loop 间隔比 Monitor 还密 | 纯浪费 |
| 让 Loop 干重活 | 每次唤醒带全历史，重活该交给子 agent |

## 三、Monitor 的三条铁律（都踩过）

**① stdout 才是事件，stderr 静音**
```js
console.log("有新消息")    // → 唤醒 agent
console.error("启动完成")  // → 只进输出文件，不打扰
```
诊断信息一律走 stderr。`chat-watch.js` 最初把启动横幅写成 `console.log`，白白唤醒一次。

**② 过滤要严，但不能只过滤「好消息」**
```bash
# 错：进程崩了完全没声音，静默看起来和正常运行一样
tail -f run.log | grep --line-buffered "完成"
# 对：成功与失败都覆盖
tail -f run.log | grep -E --line-buffered "完成|Error|Traceback|FAILED|Killed"
```
事件过多的 Monitor 会被自动掐掉。

**③ 管道每一级都要行缓冲**
`grep` 加 `--line-buffered`、`awk` 用 `fflush()`；**`head` 无法刷新**（`| head -5` 会攒够 5 条才吐）。忘了加会以为监控坏了。

**④ 改了被监视的脚本，必须重启 Monitor** —— 旧进程还跑着老代码。

## 四、选 Monitor 还是后台任务

| 想要 | 用 |
|---|---|
| **一次**通知（"编译完叫我"） | 后台 Bash + 会自行退出的命令（`until ...; do sleep 1; done`） |
| **每次发生都通知** | Monitor |

用 `tail -f` 做一次性通知是典型错误：事件发生后它仍挂着不退。

## 五、本项目的现成工具

```bash
# agent-chat 消息守望（只在真有新消息时输出一行）
node windows/tools/chat-watch.js --since <上次最大id> --self windows-claude,win-coordinator
```
挂上去的方式：让 agent 用 Monitor 跑它，`persistent: true`。

## 六、在新 session 里怎么开口

不用记语法，说人话即可：
- 「挂个 monitor 盯 agent-chat，Mac 发消息就叫我」
- 「每 20 分钟 pull 一下仓库看有没有新任务」
- 「停掉那个 monitor / 把 loop 改成 30 分钟」
