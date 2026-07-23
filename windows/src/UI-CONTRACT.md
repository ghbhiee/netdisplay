# Windows 端 UI ↔ 引擎 IPC 契约

设计（docs/design/）要求接收画面走独立窗口，而网络/解码/采集原本都在主窗口的 renderer 里。
拆引擎风险太高（连接升级、背压补关键帧这些是实测调出来的），所以反过来：

- **engine 窗口** = 原来的 `index.html` + `renderer.js`。保留网络、协议、WebCodecs 解码、canvas、
  sender 采集。平时隐藏；对方投过来时它**就是**设计里那个「接收显示窗口」。
- **panel 窗口** = 新的 `panel.html` + `panel.js`。纯界面，不碰 socket。
- **tray 弹窗** = 新的 `tray.html` + `tray.js`。无边框置顶，贴托盘图标弹出，失焦即关。

三者互不直接通信，全部经 main.js 中转。engine 是**唯一状态源**，panel/tray 只渲染 + 发命令。

## 状态：engine → main → panel/tray

engine 每次状态变化 `ipcRenderer.send("nd-state", state)`；main 存一份并广播给 panel/tray。
panel/tray 启动时 `ipcRenderer.invoke("nd-state-get")` 拿当前快照，之后监听 `nd-state` 增量覆盖。

```js
{
  role: "standby" | "switching" | "casting" | "receiving",
  recvSvc: "off" | "waiting",

  devices: [{
    id:        String,   // deviceId，身份唯一依据
    name:      String,   // 显示名：本机别名优先，否则对端 HELLO.name，否则 deviceId 前 8 位
    online:    Boolean,  // 最近一次接触到过
    conn:      "off" | "connecting" | "on",
    transport: "direct" | "relay" | null,  // conn==="on" 时才有意义
    rttMs:     Number | null,
  }],
  selectedId: String | null,

  sources:  [{ id, name, kind: "desktop" | "window" }],  // 按最近使用排序
  pickSel:  String,   // "" = 整块屏幕；否则 source id

  quality: { res: String, scale: String, fps: String, rate: String },
  relay:   { addr, token, forceRelay: Boolean, status: "ok"|"unset"|"error", rttMs: Number|null },

  localName:      String,
  peerName:       String,  // 当前对端显示名，无对端时空串
  castSourceName: String,  // 正在投的内容名
  theme:          "light" | "dark",
}
```

`role` 与 `recvSvc` 的迁移规则以 docs/design/README.md 的「Interactions & Behavior」为准。
注意 **接收中点主按钮 = 只断开投屏、recvSvc 保持 waiting**，是四态循环不是三态。

## 命令：panel/tray → main → engine

`ipcRenderer.send("nd-cmd", { cmd, ...args })`，main 原样转给 engine。

| cmd | 参数 | 含义 |
|---|---|---|
| `start-cast` | — | 开始投射（隐式建连所选设备） |
| `stop` | — | 停止投射 / 回到待命 |
| `recv-svc` | `on: Boolean` | 开/关接收服务 |
| `drop-stream` | — | 只断开投屏，接收服务保持 waiting |
| `select-device` | `id` | 选中设备 |
| `connect` / `disconnect` | `id` | 托盘第三节的连/断（主面板没有连接按钮） |
| `rename` | `id, name` | 本机给对方起别名 |
| `unpair` | `id` | 解除配对 |
| `pair` | `code, addr` | 配对：6 位码 +（可选）对方地址 |
| `pick-source` | `id` | 选投射内容，`""` = 整块屏幕 |
| `quality` | `key, value` | key ∈ res / scale / fps / rate，**value 用下表的内部值** |
| `relay-save` | `addr, token, forceRelay` | 中转设置（高级设置与中转弹窗共用） |
| `local-name` | `name` | 改本机名称 |
| `theme` | `v: "light"\|"dark"` | 切主题 |
| `open-panel` / `quit` | — | 托盘尾部两项 |

### 画质取值表

**界面上显示中文标签，发出去和存回来的一律是内部值。** 别把中文标签当值发——
`res` 最终要被 `split("x")` 拆成编码宽高，收到「1920×1080」（全角 ×）会解析出 NaN，
而 NaN 一路走到编码器才炸，报错信息和真正的原因隔了十万八千里。

| key | 内部值 | 界面标签 |
|---|---|---|
| `res` | `auto` / `1920x1080` / `2560x1440` | 跟随对方 / 1920×1080 / 2560×1440 |
| `scale` | `1` / `1.5` / `2` | 100% / 150% / 200% |
| `fps` | `30` / `60` | 30 fps / 60 fps |
| `rate` | `auto` / `10` / `20` | 自动 / 10 Mbps / 20 Mbps |

`res` 的分隔符是**半角小写 `x`**。`rate` 的单位是 Mbps，`auto` 表示不带
`bitrateMbps` 字段让对端自己定。状态里回传的也是这套内部值，UI 自己映射成标签。

## 提示：engine → panel/tray

`nd-toast`，payload 是一个字符串。设计要求所有反馈都走 toast（屏幕底部居中，2.6s 自动消失），
文案一律人话。失败态必须给下一步怎么办，不能只报「失败」。
