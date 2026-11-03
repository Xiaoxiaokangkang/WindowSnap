import AppKit
import OSLog

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
    private let logger = Logger(subsystem: "com.local.windowsnap", category: "Drag")
    private let preferences: LayoutPreferenceStore
    private let windowManager: WindowManager
    private let panel: NSPanel
    private let overlayView = ZoneOverlayView()
    private var monitors: [Any] = []
    private let onPermissionRequired: () -> Void
    private var interaction: Int?
    private var possibleWindowDrag = false
    private var optionDragAttempted = false
    private var overlayVisible = false
    private var highlightedIndex: Int?
    private var highlightedScreenFrame: CGRect?
    private var optionReleasedAt: TimeInterval?
    private var optionReleasePoint: NSPoint?
    private var releaseGeneration = 0

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
            // AppKit delivers event monitor callbacks on the main thread.
            MainActor.assumeIsolated { self?.handle(event) }
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
        let point = screenPoint(for: event)
        let timestamp = event.timestamp
        let optionPressed = event.modifierFlags.contains(.option)
        switch event.type {
        case .leftMouseDown:
            hideOverlay()
            interaction = windowManager.beginWindowInteraction(at: point, timestamp: timestamp)
            possibleWindowDrag = false
            optionDragAttempted = false
            optionReleasedAt = nil
            optionReleasePoint = nil
            releaseGeneration += 1
        case .leftMouseDragged:
            guard let interaction, let point, windowManager.isCurrentInteraction(interaction) else {
                hideOverlay()
                return
            }
            possibleWindowDrag = windowManager.observeWindowDrag(at: point, timestamp: timestamp, interaction: interaction)
            if optionPressed {
                optionReleasedAt = nil
                optionReleasePoint = nil
                releaseGeneration += 1
                optionDragAttempted = true
                guard windowManager.hasAccessibilityPermission else { return }
                guard possibleWindowDrag else { return }
                updateOverlay(at: point)
            } else {
                if !acceptsRelease(at: point, timestamp: timestamp) { hideOverlay() }
            }
        case .flagsChanged:
            guard let interaction, windowManager.isCurrentInteraction(interaction) else { return }
            if optionPressed {
                optionReleasedAt = nil
                optionReleasePoint = nil
                releaseGeneration += 1
            } else if overlayVisible && optionReleasedAt == nil {
                guard let point else { hideOverlay(); return }
                optionReleasedAt = timestamp
                optionReleasePoint = point
                releaseGeneration += 1
                let generation = releaseGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                    guard let self, self.releaseGeneration == generation,
                          self.windowManager.isCurrentInteraction(interaction) else { return }
                    self.hideOverlay()
                }
            }
        case .leftMouseUp:
            logger.notice("Mouse up overlay=\(self.overlayVisible) recognized=\(self.possibleWindowDrag == true) permission=\(self.windowManager.hasAccessibilityPermission)")
            guard let interaction else { hideOverlay(); return }
            let releaseAccepted = point.map { optionPressed || acceptsRelease(at: $0, timestamp: timestamp) } ?? false
            if let point, releaseAccepted, windowManager.isCurrentInteraction(interaction) {
                // Slow apps may only publish their moved frame just before mouse-up.
                possibleWindowDrag = windowManager.observeWindowDrag(at: point, timestamp: timestamp, interaction: interaction)
                if possibleWindowDrag { updateOverlay(at: point) }
            }
            let selected = overlayVisible && possibleWindowDrag && releaseAccepted && windowManager.isCurrentInteraction(interaction) ? highlightedIndex : nil
            let targetScreenFrame = overlayVisible ? highlightedScreenFrame : nil
            let count = preferences.columnCount
            hideOverlay()
            let needsPermission = optionDragAttempted && !windowManager.hasAccessibilityPermission
            self.interaction = nil
            possibleWindowDrag = false
            optionDragAttempted = false
            optionReleasedAt = nil
            optionReleasePoint = nil
            releaseGeneration += 1
            if let selected, let targetScreenFrame {
                if windowManager.placeDraggedWindow(column: selected, count: count, in: targetScreenFrame, interaction: interaction) == .accessibilityPermissionRequired {
                    onPermissionRequired()
                }
            } else if needsPermission {
                windowManager.cancelColumnDrag(interaction: interaction)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, self.windowManager.isCurrentInteraction(interaction) else { return }
                    self.onPermissionRequired()
                }
            } else {
                windowManager.cancelColumnDrag(interaction: interaction)
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

    private func screenPoint(for event: NSEvent) -> NSPoint? {
        if let location = event.cgEvent?.location, let primary = NSScreen.screens.first {
            return NSPoint(x: location.x, y: primary.frame.maxY - location.y)
        }
        if event.type != .flagsChanged, let window = event.window {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return nil
    }

    private func acceptsRelease(at point: NSPoint, timestamp: TimeInterval) -> Bool {
        guard let releasedAt = optionReleasedAt, let origin = optionReleasePoint else { return false }
        return LayoutEngine.acceptsOptionRelease(elapsed: timestamp - releasedAt, origin: origin, current: point)
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
