import AppKit

final class LayoutPopoverController: NSViewController {
    private let preferences: LayoutPreferenceStore
    private let onSelectColumn: (Int, Int) -> Void
    private let onLayoutChanged: (Int) -> Void
    private let permissionProvider: () -> Bool
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    private let preview = NSStackView()
    private var layoutControl: NSSegmentedControl!
    private var titleLabel: NSTextField!
    private var permissionLabel: NSTextField!

    init(
        preferences: LayoutPreferenceStore,
        onSelectColumn: @escaping (Int, Int) -> Void,
        onLayoutChanged: @escaping (Int) -> Void,
        permissionProvider: @escaping () -> Bool,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.onSelectColumn = onSelectColumn
        self.onLayoutChanged = onLayoutChanged
        self.permissionProvider = permissionProvider
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 390, height: 214)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 214))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .boldSystemFont(ofSize: 15)
        stack.addArrangedSubview(titleLabel)

        layoutControl = NSSegmentedControl(labels: ["5 列", "6 列", "7 列", "8 列"], trackingMode: .selectOne, target: self, action: #selector(layoutChanged(_:)))
        layoutControl.selectedSegment = preferences.columnCount - 5
        layoutControl.widthAnchor.constraint(equalToConstant: 358).isActive = true
        stack.addArrangedSubview(layoutControl)

        preview.orientation = .horizontal
        preview.alignment = .centerY
        preview.distribution = .fillEqually
        preview.spacing = 4
        preview.widthAnchor.constraint(equalToConstant: 358).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 54).isActive = true
        stack.addArrangedSubview(preview)

        permissionLabel = NSTextField(labelWithString: "")
        permissionLabel.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(permissionLabel)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        let hint = NSTextField(labelWithString: "Option + 拖动也可选择区域")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let settingsButton = NSButton(title: "设置…", target: self, action: #selector(openSettings))
        settingsButton.bezelStyle = .inline
        let quitButton = NSButton(title: "退出", target: self, action: #selector(quit))
        quitButton.bezelStyle = .inline
        footer.addArrangedSubview(hint)
        footer.addArrangedSubview(settingsButton)
        footer.addArrangedSubview(quitButton)
        footer.widthAnchor.constraint(equalToConstant: 358).isActive = true
        stack.addArrangedSubview(footer)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
        refreshState()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshState()
    }

    @objc private func layoutChanged(_ sender: NSSegmentedControl) {
        preferences.columnCount = sender.selectedSegment + 5
        onLayoutChanged(preferences.columnCount)
        refreshState()
    }

    private func refreshState() {
        let count = preferences.columnCount
        layoutControl?.selectedSegment = count - 5
        titleLabel?.stringValue = "当前布局：\(count) 列 · 选择窗口位置"
        let allowed = permissionProvider()
        permissionLabel?.stringValue = allowed ? "辅助功能权限：已开启" : "辅助功能权限：未开启，窗口无法移动"
        permissionLabel?.textColor = allowed ? .systemGreen : .systemRed
        rebuildPreview()
    }

    private func rebuildPreview() {
        preview.arrangedSubviews.forEach { view in
            preview.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let count = preferences.columnCount
        for index in 0..<count {
            let button = NSButton(title: "\(index + 1)", target: self, action: #selector(columnSelected(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.toolTip = "移到第 \(index + 1) 列"
            preview.addArrangedSubview(button)
        }
    }

    @objc private func columnSelected(_ sender: NSButton) {
        onSelectColumn(sender.tag, preferences.columnCount)
    }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func quit() { onQuit() }
}
