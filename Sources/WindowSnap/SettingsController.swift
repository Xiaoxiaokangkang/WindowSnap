import AppKit
import ServiceManagement

final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

final class ShortcutButton: NSButton {
    var onRecorded: ((Shortcut) -> Bool)?
    private(set) var isRecording = false
    private var titleBeforeRecording = ""

    override var acceptsFirstResponder: Bool { true }

    func beginRecording() {
        isRecording = true
        titleBeforeRecording = title
        title = "请按新快捷键…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            isRecording = false
            title = titleBeforeRecording
            return
        }
        guard let shortcut = Shortcut.from(event: event) else {
            title = "需包含修饰键"
            return
        }
        isRecording = false
        title = onRecorded?(shortcut) == true ? shortcut.displayText : titleBeforeRecording
    }
}

final class SettingsController: NSWindowController {
    private let store: ShortcutStore
    private let onChanged: () -> Void
    private var buttons: [WindowAction: ShortcutButton] = [:]

    init(store: ShortcutStore, onChanged: @escaping () -> Void) {
        self.store = store
        self.onChanged = onChanged
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 630),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "WindowSnap 设置"
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        guard let window else { return }
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading
        root.spacing = 10; root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        root.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "快捷键")
        heading.font = .boldSystemFont(ofSize: 18)
        root.addArrangedSubview(heading)
        let note = NSTextField(wrappingLabelWithString: "点击一个快捷键按钮，然后按下新的组合键。组合键必须包含 ⌃、⌥、⇧ 或 ⌘。")
        note.textColor = .secondaryLabelColor
        root.addArrangedSubview(note)

        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let rows = FlippedStackView(); rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 6
        rows.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        rows.translatesAutoresizingMaskIntoConstraints = false
        var previousSection = ""
        for action in WindowAction.allCases where action.columnLayout == nil {
            let section = sectionTitle(for: action)
            if section != previousSection {
                let header = NSTextField(labelWithString: section)
                header.font = .boldSystemFont(ofSize: 13)
                header.textColor = .secondaryLabelColor
                if !previousSection.isEmpty { rows.setCustomSpacing(14, after: rows.arrangedSubviews.last!) }
                rows.addArrangedSubview(header)
                previousSection = section
            }
            let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY
            let label = NSTextField(labelWithString: action.title); label.widthAnchor.constraint(equalToConstant: 270).isActive = true
            let button = ShortcutButton(title: store.shortcuts[action]?.displayText ?? "未设置", target: nil, action: nil)
            button.bezelStyle = .rounded; button.widthAnchor.constraint(equalToConstant: 145).isActive = true
            button.target = self; button.action = #selector(record(_:))
            button.onRecorded = { [weak self] shortcut in
                guard let self else { return false }
                if let conflict = self.store.conflictingAction(for: shortcut, excluding: action) {
                    let alert = NSAlert()
                    alert.messageText = "快捷键已被使用"
                    alert.informativeText = "\(shortcut.displayText) 已分配给“\(conflict.title)”，请换一个组合键。"
                    alert.runModal()
                    return false
                }
                self.store.set(shortcut, for: action)
                self.onChanged()
                return true
            }
            buttons[action] = button
            row.addArrangedSubview(label); row.addArrangedSubview(button); rows.addArrangedSubview(row)
        }
        scroll.documentView = rows
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        scroll.heightAnchor.constraint(equalToConstant: 430).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 476).isActive = true
        root.addArrangedSubview(scroll)

        let dragHint = NSTextField(wrappingLabelWithString: "超宽屏：点击菜单栏图标选择 4～8 列布局；拖动窗口时按住 Option 可显示分区浮层。若同时出现 macOS 自带拼贴，请在“系统设置 → 桌面与程序坞 → 窗口”中关闭按住 Option 拖移拼贴。")
        dragHint.textColor = .secondaryLabelColor
        dragHint.widthAnchor.constraint(equalToConstant: 476).isActive = true
        root.addArrangedSubview(dragHint)

        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 12
        let reset = NSButton(title: "恢复默认快捷键", target: self, action: #selector(resetShortcuts))
        let permission = NSButton(title: "打开设备控制权限", target: self, action: #selector(openAccessibility))
        let login = NSButton(checkboxWithTitle: "登录时启动", target: self, action: #selector(toggleLogin(_:)))
        if #available(macOS 13.0, *) { login.state = SMAppService.mainApp.status == .enabled ? .on : .off }
        controls.addArrangedSubview(reset); controls.addArrangedSubview(permission); controls.addArrangedSubview(login)
        root.addArrangedSubview(controls)
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])
        window.center()
    }

    @objc private func record(_ sender: ShortcutButton) { sender.beginRecording() }

    private func sectionTitle(for action: WindowAction) -> String {
        if let column = action.columnLayout { return "\(column.count) 分屏" }
        switch action.menuGroup {
        case 0: return "半屏"
        case 1: return "四角"
        case 2: return "三分屏"
        case 3: return "窗口"
        default: return "显示器"
        }
    }

    func showRegistrationFailures(_ actions: [WindowAction]) {
        guard !actions.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "部分快捷键无法启用"
        alert.informativeText = actions.map(\.title).joined(separator: "、") + " 的快捷键可能与系统或其他应用冲突。"
        alert.runModal()
    }
    @objc private func resetShortcuts() {
        store.reset()
        for (action, button) in buttons { button.title = store.shortcuts[action]?.displayText ?? "未设置" }
        onChanged()
    }
    @objc private func openAccessibility() {
        let modern = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
        let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(modern) { NSWorkspace.shared.open(legacy) }
    }
    @objc private func toggleLogin(_ sender: NSButton) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            sender.state = sender.state == .on ? .off : .on
            let alert = NSAlert(); alert.messageText = "无法更改登录项"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
}
