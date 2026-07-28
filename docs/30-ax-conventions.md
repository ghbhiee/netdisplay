---
date: 2026-07-28
tags: [swift, macos, accessibility, ax, convention, testing]
---

# Swift/macOS App 的 AX 约定（可被 agent 驱动 = 可调试）

> **这是给以后所有 Swift/macOS 项目的通用约定，不只是 NetDisplay。**
> 一句话：**App 要能被「按名字」操作，而不是被「按坐标」点击。**

## 为什么

我们真实踩过的坑：agent 要验证 GUI，只能截图 + 点像素坐标。结果是——

- 布局一变、窗口一移、Retina 缩放一换，脚本就废了；
- 点击会**抢用户的鼠标和焦点**，人没法同时用这台机器；
- 最糟的一次：为了绕开 GUI，我另起了一个 **CLI 进程**去投射，结果它和用户手里的 GUI
  **抢同一个中转房间的 sender 槽**，互相顶掉，用户界面上怎么点都不对
  （见 NetDisplay 频道 #255）。**根因就是"没法驱动用户正在用的那个进程"。**

用 AX（Accessibility API）驱动就没有这些问题：语义地"按"控件，不动鼠标、不抢焦点、
驱动的就是**用户眼前那个进程**，而且能**读回界面真实状态**来断言。

顺带：这些工作同时让 App 对**真正需要辅助功能的用户**可用。不是额外负担，是本来就该做的。

## 三条硬规则

### 规则 1：所有可交互控件都要有稳定的 `accessibilityIdentifier`

```swift
extension NSView {
    @discardableResult
    func ax(_ id: String, label: String? = nil) -> Self {
        setAccessibilityIdentifier(id)
        if let label { setAccessibilityLabel(label) }
        return self
    }
}

// 用法：链式，不打断原有写法
UI.button("开始投射", …).ax("cast.start")
```

**命名用 `区域.动作` 或 `区域.类型.键`**，全小写点分：

| identifier | 含义 |
|---|---|
| `tab.cast` / `tab.recv` | 顶部分页 |
| `cast.start` / `cast.stop` | 主操作 |
| `device.add` / `device.refresh` | 设备区动作 |
| `device.row.<key>` | 列表行（key 用**稳定且非机密**的值） |
| `source.row.<tag>` | 投射源行 |
| `relay.settings` / `theme.toggle` | 底部动作 |

⚠️ **identifier 里绝不能放机密**。任何进程都能读 AX 树。
NetDisplay 里设备行用的是配对码或 deviceId 前 8 位（`PairedDevice.axKey`），
**不是 secret**。

⚠️ **别把会变的文案当 id**。`relay.settings` 这个按钮的**标题**会随中转状态变
（「中转设置」/「中转 · 可用 584ms」/「中转 · token 错误」），但 **id 恒定**。
按 id 找，不按标题找。

### 规则 2：自定义点击区必须自己声明成 AX 控件

这是最容易漏的一条。**一个裸 `NSView` + `mouseDown` 对 AX 完全不可见**——
外部驱动能看到那行的文字，却**没有任何办法激活它**，只能退回去点坐标。

NetDisplay 的行选择原本就是这样（`ClickCatcher`），修法：

```swift
final class ClickCatcher: NSView {
    private let onClick: () -> Void
    init(_ onClick: @escaping () -> Void, label: String = "", id: String = "") {
        self.onClick = onClick
        super.init(frame: .zero)
        setAccessibilityElement(true)          // ① 我是一个 AX 元素
        setAccessibilityRole(.button)          // ② 我是个按钮
        if !label.isEmpty { setAccessibilityLabel(label) }
        if !id.isEmpty { setAccessibilityIdentifier(id) }
    }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }  // ③ 能被按
}
```

**①②③ 缺一不可**：没有 ① 整个元素不出现在树里；没有 ② 驱动不知道它能按；
没有 ③ `AXPress` 会失败。

用 `NSButton` 的地方天然满足这三条，所以**优先用 NSButton**，
只有真的需要"整行可点"时才用这套。

### 规则 3：状态要能被读出来，别只画出来

驱动不只要能"按"，还要能**断言**。所以：

- 禁用状态用 `isEnabled`（AX 会暴露成 `AXEnabled`），**不要**只把按钮画灰。
  这样驱动能读到 `(disabled)`，知道是前置条件没满足，而不是自己按错了。
- 关键状态值放进 `accessibilityValue` 或控件标题，让 `dump` 能看见。
- **错误状态必须可见**。反面教材：`projectableApps()` 用 `try?` 把"没有屏幕录制权限"
  的异常吞掉、直接返回空数组，于是"没有窗口"和"不许我看"渲染成同一个结果——
  人和 agent 都判断不了，白折腾了一轮（见 `docs/95-open-items-mac.md`）。

## 驱动工具

`mac/scripts/axdrive.swift`——**纯 Swift、零依赖、不用编译，直接跑**：

```bash
swift scripts/axdrive.swift dump                 # 看有哪些控件（含 id/role/label/enabled）
swift scripts/axdrive.swift dump --all           # 连纯布局容器一起列
swift scripts/axdrive.swift press cast.start     # 按名字按下
swift scripts/axdrive.swift get   cast.start     # 读单个控件状态
swift scripts/axdrive.swift wait  recv.toggle    # 等控件出现（默认 10s）
swift scripts/axdrive.swift dump --app 别的App    # 也能驱动别的 App
```

（一开始写的是 Python 版，但系统自带的 python3 没有 `ApplicationServices` 的 pyobjc 绑定，
装依赖反而成了负担。Swift 版 `import ApplicationServices` 开箱即用，也更契合"Swift 项目"。）

**前置**：运行它的终端要在 系统设置 → 隐私与安全性 → **辅助功能** 里勾选。
没勾时脚本会明确提示，不会静默失败。

## 实测效果

```
$ swift scripts/axdrive.swift dump
AXApplication "NetDisplay"
  AXWindow "NetDisplay"
      AXButton #tab.cast "投射本机"
      AXButton #tab.recv "接收显示"
      AXButton #source.row.@screen "投射源 整块屏幕"
      AXButton #source.row.Claude "投射源 Claude"
      AXButton #cast.start "开始投射"
      AXButton #device.refresh "⟳"
      AXButton #relay.settings "中转 · 可用 584ms"

$ swift scripts/axdrive.swift press tab.recv && swift scripts/axdrive.swift get recv.toggle
pressed tab.recv
id=recv.toggle role=AXButton label="开启接收服务" value="" enabled=true
```

## 新项目起手式（checklist）

- [ ] 抄一份 `NSView.ax(_:label:)` 扩展
- [ ] 每个可交互控件 `.ax("区域.动作")`，命名进项目文档
- [ ] 自定义点击区实现 `isAccessibilityElement` + `role` + `accessibilityPerformPress`
- [ ] 禁用状态走 `isEnabled`，错误状态在界面上可见（**不要 `try?` 吞异常**）
- [ ] 拷 `axdrive.swift` 进 `scripts/`
- [ ] 写一条冒烟脚本：`dump` → `press` → `get` 断言，作为 GUI 的最小回归

## 边界

- AX **不适合**验证像素级视觉（配色、间距、圆角）——那还是得截图看。
  AX 管的是**结构与行为**，截图管**外观**，两者互补。
- 驱动方需要辅助功能权限；这是系统级授权，CI 上要预先配好。
- 被驱动的 App **不需要**任何额外权限，只需要按上面三条规则写。
