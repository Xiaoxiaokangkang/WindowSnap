import AppKit

final class ZoneOverlayView: NSView {
    var columnCount = 6 { didSet { needsDisplay = true } }
    var highlightedIndex: Int? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.10).setFill()
        bounds.fill()

        for index in 0..<columnCount {
            let left = floor(bounds.width * CGFloat(index) / CGFloat(columnCount))
            let right = floor(bounds.width * CGFloat(index + 1) / CGFloat(columnCount))
            // Draw the exact target bounds. The real windows are edge-to-edge, so showing
            // artificial gaps here made normal window shadows look like layout overflow.
            let rect = NSRect(x: left, y: 0, width: max(1, right - left), height: bounds.height)
            let active = highlightedIndex == index
            (active ? NSColor.controlAccentColor.withAlphaComponent(0.60) : NSColor.controlAccentColor.withAlphaComponent(0.20)).setFill()
            rect.fill()
            if index > 0 {
                NSColor.white.withAlphaComponent(0.55).setStroke()
                let separator = NSBezierPath()
                separator.move(to: NSPoint(x: left + 0.5, y: 0))
                separator.line(to: NSPoint(x: left + 0.5, y: bounds.height))
                separator.lineWidth = 1
                separator.stroke()
            }

            let label = "\(index + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: active ? 24 : 18),
                .foregroundColor: NSColor.white.withAlphaComponent(active ? 1 : 0.82)
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }
}

@MainActor
final class OptionDragController {
    private let preferences: LayoutPreferenceStore
    private let windowManager: WindowManager
    private let panel: NSPanel
    private let overlayView = ZoneOverlayView()
    private var monitors: [Any] = []
    private let onPermissionRequired: () -> Void
    private var mouseDownPoint: NSPoint?
    private var possibleWindowDrag: Bool?
    private var optionDragAttempted = false
    private var overlayVisible = false
    private var highlightedIndex: Int?
    private var highlightedScreenFrame: CGRect?

    init(preferences: LayoutPreferenceStore, windowManager: WindowManager, onPermissionRequired: @escaping () -> Void) {
        self.preferences = preferences
        self.windowManager = windowManager
        self.onPermissionRequired = onPermissionRequired
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = overlayView
        installMonitors()
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            // The clicked app may not become frontmost until after mouse-down. Resolve the
            // focused window on the first drag event instead of rejecting it too early.
            mouseDownPoint = point
            possibleWindowDrag = nil
            optionDragAttempted = false
            windowManager.cancelColumnDrag()
        case .leftMouseDragged:
            if NSEvent.modifierFlags.contains(.option) {
                optionDragAttempted = true
                guard windowManager.hasAccessibilityPermission else { return }
                if possibleWindowDrag != true {
                    let recognized = windowManager.isPointInFocusedWindowTitleBar(point)
                        || mouseDownPoint.map(windowManager.isPointInFocusedWindowTitleBar) == true
                    if recognized { possibleWindowDrag = true }
                }
                // Do not cache a negative result. Electron apps such as Doubao can take
                // several drag events to become the focused accessibility application.
                guard possibleWindowDrag == true else { return }
                updateOverlay(at: point)
            } else {
                hideOverlay()
            }
        case .flagsChanged:
            if overlayVisible && !NSEvent.modifierFlags.contains(.option) { hideOverlay() }
        case .leftMouseUp:
            let selected = overlayVisible ? highlightedIndex : nil
            let targetScreenFrame = overlayVisible ? highlightedScreenFrame : nil
            let count = preferences.columnCount
            hideOverlay()
            let needsPermission = optionDragAttempted && !windowManager.hasAccessibilityPermission
            mouseDownPoint = nil
            possibleWindowDrag = nil
            optionDragAttempted = false
            if let selected, let targetScreenFrame {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    guard let self else { return }
                    if self.windowManager.placeDraggedWindow(column: selected, count: count, in: targetScreenFrame) == .accessibilityPermissionRequired {
                        self.onPermissionRequired()
                    }
                }
            } else if needsPermission {
                windowManager.cancelColumnDrag()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.onPermissionRequired()
                }
            } else {
                windowManager.cancelColumnDrag()
            }
        default: break
        }
    }

    private func updateOverlay(at point: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return }
        let frame = screen.visibleFrame
        highlightedScreenFrame = frame
        let count = preferences.columnCount
        if panel.frame != frame || overlayView.columnCount != count {
            panel.setFrame(frame, display: true)
            overlayView.columnCount = count
        }
        let relativeX = max(0, min(frame.width - 0.001, point.x - frame.minX))
        highlightedIndex = min(count - 1, Int(relativeX / frame.width * CGFloat(count)))
        overlayView.highlightedIndex = highlightedIndex
        if !overlayVisible {
            overlayVisible = true
            panel.orderFrontRegardless()
        }
    }

    private func hideOverlay() {
        guard overlayVisible else { return }
        overlayVisible = false
        highlightedIndex = nil
        highlightedScreenFrame = nil
        overlayView.highlightedIndex = nil
        panel.orderOut(nil)
    }
}
