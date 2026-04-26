# Feature Request: 菜单栏常驻时隐藏 Dock 图标

## 状态

✅ **已实现**（2026-04-26）

## 需求描述

当应用进入**菜单栏常驻模式**（关闭主窗口，仅保留菜单栏图标运行）时，Dock 栏不应显示应用图标。

打开主窗口时，Dock 图标应正常显示，方便用户通过 Cmd+Tab 切换回来。

## 预期行为

| 状态 | Dock 图标 | Cmd+Tab |
|---|---|---|
| 主窗口打开 | ✅ 显示 | ✅ 可切换 |
| 仅菜单栏运行 | ❌ 隐藏 | ❌ 不可切换 |

## 实现方案

### Dock 策略控制

macOS 上通过 `NSApp.activationPolicy` 动态控制：

```swift
// 仅菜单栏运行时：隐藏 Dock
NSApp.setActivationPolicy(.accessory)

// 打开主窗口时：显示 Dock
NSApp.setActivationPolicy(.regular)
```

### 窗口关闭检测

通过 `NotificationCenter` 监听 `NSWindow.willCloseNotification`，延迟 0.1s 后检查 `NSApp.windows` 中是否还有可见的非 `NSPanel` 窗口（排除 `MenuBarExtra` 的窗口），没有则切换到 `.accessory`。

### 打开主窗口

从菜单栏点击「打开主窗口」时，先切回 `.regular`，再调用 `NSApp.activate(ignoringOtherApps:)` 并前置所有非 Panel 窗口。

### 相关改动文件

- `ReminderScreenSync/AppModel.swift`
  - 新增 `hideDockWhenMenuBarOnly: Bool`（UserDefaults 持久化）
  - 新增 `updateDockPolicy()` — 根据窗口状态切换 activationPolicy
  - 新增 `showDockAndActivate()` — 菜单栏打开主窗口时调用
  - 新增 `observeWindows()` — 监听窗口关闭通知
  - `bootstrap()` 启动时调用 `updateDockPolicy()`

- `ReminderScreenSync/MenuBarView.swift`
  - 修改 `openMainWindow()` → 调用 `model.showDockAndActivate()`
  - 新增 `settingsSection` — 三个设置开关（开机自启 / 启动自动同步 / 隐藏 Dock）

### 附：同步启动相关开关

本次实现**一并补上了**两个此前仅有代码但无 UI 的功能：

| 开关 | 说明 | 代码位置 |
|---|---|---|
| 开机自动启动 | 使用 `SMAppService.mainApp` 注册系统登录项 | `AppModel.setLaunchAtLogin(_:)` |
| 启动时自动同步 | `autoStartSync`（已有代码，现补 UI） | `AppModel.bootstrap()` |

## 优先级

低 — 纯体验优化，不影响核心同步功能。
