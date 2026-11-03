# 架构说明

WindowSnap 是 Swift/AppKit 菜单栏应用，不依赖第三方运行库。

## 主要组件

- `main.swift`：应用生命周期、同标识实例检测、菜单栏、提示和控制器组装
- `WindowManager.swift`：AX 窗口读取、CG 窗口绑定、移动缩放适配和诊断采样
- `LayoutEngine.swift`：纯布局计算、容差和重试决策
- `WindowInteractionState.swift`：交互 epoch、候选窗口、放置令牌及运动确认
- `WindowPlacementRunner.swift`：生产与测试共用的有限重试、稳定回读执行器
- `PhysicalWindowEvidence.swift`：PID、窗口编号与唯一几何对应关系校验
- `WindowEvidenceRecorder.swift`：有大小限制的本地元数据诊断记录
- `OptionDragController.swift`：事件自身坐标/时间/修饰键处理与分区浮层
- `LayoutPopoverController.swift`：4～8 列可视化选择面板
- `Shortcut.swift` / `HotKeyManager.swift`：快捷键存储与 Carbon 全局热键
- `SettingsController.swift` / `AppBuild.swift`：设置、版本、运行路径与登录项

## 窗口放置流程

1. 新交互立即使旧放置令牌失效。Option 拖动按鼠标命中绑定实际窗口，不用焦点窗口兜底。
2. 用 PID、系统窗口编号及 AX/CG 唯一几何对应关系确认物理窗口；有歧义时拒绝操作。
3. 锁定浮层所在显示器，根据其 `visibleFrame` 计算完整目标列矩形。
4. 放置前再次校验身份，经 AX 写入尺寸、位置、尺寸。拖动松手后等待 120 ms 再开始。
5. 执行器等待并回读结果，未匹配时有限重试，到位后继续稳定采样。
6. 新操作、身份失效、完成或重试耗尽均终止旧任务；拒绝写入不等于真实最小宽度证据。
7. 本地诊断同时观察当前和先前已放置窗口，不自动恢复、隐藏或重排其他窗口。

## 安全与隐私边界

- 不执行网络请求，不上传诊断数据。
- 不读取或记录窗口标题、正文或截图。
- 恢复尺寸、AX 对象与会话状态保存在内存中。
- 本地 JSONL 日志位于 `~/Library/Logs/WindowSnap/`，记录进程号、系统窗口编号、矩形、可见性与层级等排障元数据。
- 当前日志超过约 2 MB 后滚动，仅保留当前和上一份；可退出应用后删除。
- 取证观察不等于故障归因；纯执行器测试不替代 AX/CG 真实桌面验收。
