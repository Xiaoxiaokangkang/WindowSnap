import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let windowManager = WindowManager()
    private let store = ShortcutStore()
    private let layoutPreferences = LayoutPreferenceStore()
    private let hotKeys = HotKeyManager()
    private var statusItem: NSStatusItem!
    private var settings: SettingsController!
    private var layoutPopover: NSPopover!
    private var optionDragController: OptionDragController!
    private var permissionAlertVisible = false
    private var operationAlertVisible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        windowManager.issueHandler = { [weak self] issue in self?.showOperationIssue(issue) }
        hotKeys.handler = { [weak self] action in self?.perform(action) }
        let initialHotKeyFailures = hotKeys.register(store.shortcuts)
        settings = SettingsController(store: store) { [weak self] in
            guard let self else { return }
            let failures = self.hotKeys.register(self.store.shortcuts)
            self.settings.showRegistrationFailures(failures)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "WindowSnap")
            button.target = self
            button.action = #selector(toggleLayoutPopover)
        }
        updateStatusItem()
        configureLayoutPopover()
        optionDragController = OptionDragController(
            preferences: layoutPreferences,
            windowManager: windowManager,
            onPermissionRequired: { [weak self] in self?.showAccessibilityHelp() }
        )
        // A menu-bar-only app otherwise appears to do nothing on first launch.
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        if UserDefaults.standard.string(forKey: "lastOnboardingVersion") != currentVersion {
            showSettings()
            UserDefaults.standard.set(currentVersion, forKey: "lastOnboardingVersion")
        }
        if !initialHotKeyFailures.isEmpty {
            statusItem.button?.toolTip = "WindowSnap：部分默认快捷键与系统冲突"
        }
        if !windowManager.hasAccessibilityPermission {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showAccessibilityHelp()
            }
        }
    }

    private func configureLayoutPopover() {
        let controller = LayoutPopoverController(
            preferences: layoutPreferences,
            onSelectColumn: { [weak self] index, count in
                guard let self, let action = WindowAction.column(index: index, count: count) else { return }
                self.layoutPopover.performClose(nil)
                self.perform(action)
            },
            onLayoutChanged: { [weak self] _ in self?.updateStatusItem() },
            permissionProvider: { [weak self] in self?.windowManager.hasAccessibilityPermission ?? false },
            onOpenSettings: { [weak self] in
                self?.layoutPopover.performClose(nil)
                self?.showSettings()
            },
            onQuit: { NSApp.terminate(nil) }
        )
        layoutPopover = NSPopover()
        layoutPopover.behavior = .transient
        layoutPopover.animates = true
        layoutPopover.contentViewController = controller
    }

    @objc private func toggleLayoutPopover() {
        guard let button = statusItem.button else { return }
        if layoutPopover.isShown {
            layoutPopover.performClose(nil)
        } else {
            layoutPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    @MainActor @objc private func showSettings() {
        settings.showWindow(nil); settings.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func perform(_ action: WindowAction) {
        switch windowManager.perform(action) {
        case .success:
            break
        case .accessibilityPermissionRequired:
            showAccessibilityHelp()
        case .noFocusedWindow:
            showSimpleOperationAlert(
                title: "没有找到可移动的窗口",
                message: "请先点击目标窗口，再从菜单栏选择分屏位置。"
            )
        case .unavailable:
            showSimpleOperationAlert(
                title: "这个窗口无法完成操作",
                message: "该窗口可能不可调整大小、处于全屏模式，或应用拒绝了移动请求。"
            )
        }
    }

    private func updateStatusItem() {
        let count = layoutPreferences.columnCount
        statusItem?.button?.title = " \(count)"
        statusItem?.button?.toolTip = "WindowSnap · 当前 \(count) 列"
    }

    private func showOperationIssue(_ issue: WindowOperationIssue) {
        switch issue {
        case let .constrained(appName, targetWidth, actualWidth, recommendedColumns):
            showSimpleOperationAlert(
                title: "\(appName) 无法放入当前列宽",
                message: "目标宽度为 \(Int(targetWidth.rounded()))，窗口实际最小宽度约为 \(Int(actualWidth.rounded()))。建议改用 \(recommendedColumns) 列或更少，否则窗口会与相邻列重叠。"
            )
        case let .desktopSpaceChanged(hiddenWindowCount):
            showSimpleOperationAlert(
                title: "检测到桌面空间切换",
                message: "已有 \(hiddenWindowCount) 个已排列窗口离开了当前桌面。它们没有被删除，请在调度中心把需要排列的窗口放到同一个桌面后再继续。"
            )
        case let .verificationFailed(appName):
            showSimpleOperationAlert(
                title: "无法确认 \(appName) 的最终位置",
                message: "应用没有返回调整后的窗口尺寸，请重新尝试；如果持续出现，说明该窗口不支持辅助功能调整。"
            )
        case let .placementRejected(appName):
            showSimpleOperationAlert(
                title: "\(appName) 没有接受目标位置",
                message: "WindowSnap 已在本次操作中连续校正窗口，但应用仍未到达所选区域。该窗口可能处于全屏、动画或特殊窗口状态。"
            )
        }
    }

    private func showSimpleOperationAlert(title: String, message: String) {
        guard !operationAlertVisible else { return }
        operationAlertVisible = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "知道了")
        alert.runModal()
        operationAlertVisible = false
    }

    private func showAccessibilityHelp() {
        guard !windowManager.hasAccessibilityPermission, !permissionAlertVisible else { return }
        permissionAlertVisible = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要开启辅助功能权限"
        alert.informativeText = "WindowSnap 只有获得辅助功能权限后，才能移动窗口并显示 Option 拖动区域。请在列表中开启 WindowSnap；如果已经开启，请先关闭再重新开启，然后重新启动 WindowSnap。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        let response = alert.runModal()
        permissionAlertVisible = false
        if response == .alertFirstButtonReturn {
            windowManager.requestAccessibilityPermission()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
