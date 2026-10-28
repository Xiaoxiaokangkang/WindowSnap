# 架构说明

WindowSnap 是 Swift/AppKit 菜单栏应用，不依赖第三方运行库。

## 主要组件

- `main.swift`：应用生命周期、菜单栏、提示和控制器组装
- `WindowManager.swift`：辅助功能窗口读取、移动、缩放、结果回读和桌面空间检测
- `LayoutEngine.swift`：纯布局计算、适配判断和重试决策
- `OptionDragController.swift`：全局拖动监听和分区浮层
- `LayoutPopoverController.swift`：4～8 列可视化选择面板
- `Shortcut.swift` / `HotKeyManager.swift`：快捷键存储与 Carbon 全局热键
- `SettingsController.swift`：设置窗口、设备控制权限入口和登录项

## 窗口放置流程

1. 记录当前外部应用和聚焦窗口。
2. 根据显示器 `visibleFrame` 计算目标矩形。
3. 通过 Accessibility API 写入位置、尺寸、位置。
4. 等待应用完成异步布局并读取实际矩形。
5. 未达到目标时，在同一次用户操作内继续校正。
6. 达到目标后结束；全部尝试耗尽后才报告真实限制。
7. 新操作会使同一窗口的旧放置任务失效，避免并发调整。

## 安全边界

- 不执行网络请求。
- 不读取窗口正文内容。
- 不保存窗口标题或用户数据。
- 只在内存中保存恢复尺寸和当前会话状态。
