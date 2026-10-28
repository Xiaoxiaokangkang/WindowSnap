import AppKit
import ApplicationServices

enum WindowOperationResult {
    case success
    case accessibilityPermissionRequired
    case noFocusedWindow
    case unavailable
}

enum WindowOperationIssue {
    case constrained(appName: String, targetWidth: CGFloat, actualWidth: CGFloat, recommendedColumns: Int)
    case desktopSpaceChanged(hiddenWindowCount: Int)
    case verificationFailed(appName: String)
    case placementRejected(appName: String)
}

@MainActor
final class WindowManager: NSObject {
    private var savedFrames: [String: CGRect] = [:]
    private var lastExternalPID: pid_t?
    private var snappedWindowVisibility: [CGWindowID: Bool] = [:]
    private var placementGeneration: [String: Int] = [:]
    private var draggedWindow: WindowInfo?
    private var nextPlacementGeneration = 0
    private let placementRetryDelays: [TimeInterval] = [0.08, 0.10, 0.14, 0.18, 0.24, 0.32, 0.42, 0.55]
    var issueHandler: ((WindowOperationIssue) -> Void)?

    override init() {
        super.init()
        rememberActiveApplication()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func applicationActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalPID = app.processIdentifier
    }

    private func rememberActiveApplication() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalPID = app.processIdentifier
    }

    func requestAccessibilityPermission() {
        // The key's documented string value avoids Swift 6 treating the imported C global as shared mutable state.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    @discardableResult
    func perform(_ action: WindowAction) -> WindowOperationResult {
        guard AXIsProcessTrusted() else {
            return .accessibilityPermissionRequired
        }
        reportDesktopSpaceTransitionIfNeeded()
        guard let info = focusedWindow() else { NSSound.beep(); return .noFocusedWindow }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return .unavailable }
        let currentScreen = bestScreen(for: info.frame, screens: screens)

        if action == .restore {
            guard let saved = savedFrames[info.key] else { NSSound.beep(); return .unavailable }
            guard apply(frame: saved, to: info.element) else { return .unavailable }
            savedFrames.removeValue(forKey: info.key)
            return .success
        }

        if action == .nextDisplay || action == .previousDisplay {
            guard screens.count > 1, let index = screens.firstIndex(of: currentScreen) else { NSSound.beep(); return .unavailable }
            let offset = action == .nextDisplay ? 1 : -1
            let target = screens[(index + offset + screens.count) % screens.count]
            remember(info)
            guard apply(frame: LayoutEngine.movedFrame(info.frame, from: currentScreen.visibleFrame, to: target.visibleFrame), to: info.element) else {
                return .unavailable
            }
            return .success
        }

        if let target = LayoutEngine.frame(for: action, in: currentScreen.visibleFrame, current: info.frame) {
            remember(info)
            if action.columnLayout != nil {
                rememberSnappedWindow(info)
                beginPlacement(target: target, screenWidth: currentScreen.visibleFrame.width, info: info)
            } else if !apply(frame: target, to: info.element) {
                return .unavailable
            }
            return .success
        }
        return .unavailable
    }

    func isPointInFocusedWindowTitleBar(_ point: NSPoint) -> Bool {
        guard AXIsProcessTrusted(), let info = focusedWindow() else { return false }
        guard isPoint(point, inTitleBarOf: info) else { return false }
        draggedWindow = info
        return true
    }

    func cancelColumnDrag() {
        draggedWindow = nil
    }

    @discardableResult
    func placeDraggedWindow(column index: Int, count: Int, in visibleFrame: CGRect) -> WindowOperationResult {
        guard AXIsProcessTrusted() else {
            draggedWindow = nil
            return .accessibilityPermissionRequired
        }
        guard let info = draggedWindow else { return .noFocusedWindow }
        draggedWindow = nil
        guard let action = WindowAction.column(index: index, count: count),
              let target = LayoutEngine.frame(for: action, in: visibleFrame, current: info.frame) else {
            return .unavailable
        }
        remember(info)
        rememberSnappedWindow(info)
        beginPlacement(target: target, screenWidth: visibleFrame.width, info: info)
        return .success
    }

    private func isPoint(_ point: NSPoint, inTitleBarOf info: WindowInfo) -> Bool {
        // Unified toolbars in browsers and document apps are often taller than a classic title bar.
        let titleBarHeight = min(84, info.frame.height)
        let titleBar = CGRect(x: info.frame.minX, y: info.frame.maxY - titleBarHeight, width: info.frame.width, height: titleBarHeight)
        return titleBar.contains(point)
    }

    private func remember(_ info: WindowInfo) {
        if savedFrames[info.key] == nil { savedFrames[info.key] = info.frame }
    }

    private func focusedWindow() -> WindowInfo? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        let app: NSRunningApplication?
        if let frontmost, frontmost.processIdentifier != ownPID {
            app = frontmost
            lastExternalPID = frontmost.processIdentifier
        } else if let lastExternalPID {
            app = NSRunningApplication(processIdentifier: lastExternalPID)
        } else {
            app = nil
        }
        guard let app else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value else { return nil }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        guard let frame = getFrame(window) else { return nil }

        var numberValue: CFTypeRef?
        var suffix = String(describing: window)
        if AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &numberValue) == .success,
           let number = numberValue as? NSNumber { suffix = number.stringValue }
        let windowNumber = (numberValue as? NSNumber).map { CGWindowID($0.uint32Value) }
        return WindowInfo(
            element: window,
            frame: frame,
            key: "\(app.processIdentifier):\(suffix)",
            appName: app.localizedName ?? "当前应用",
            windowNumber: windowNumber
        )
    }

    private func getFrame(_ window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }
        return axToCocoa(CGRect(origin: point, size: size))
    }

    @discardableResult
    private func apply(frame: CGRect, to window: AXUIElement) -> Bool {
        let axFrame = cocoaToAX(frame)
        var point = axFrame.origin, size = axFrame.size
        guard let position = AXValueCreate(.cgPoint, &point),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        // AX does not offer an atomic frame write. Position-size-position works across
        // AppKit and Electron windows, and repeated calls handle their asynchronous layout.
        let firstPositionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        let finalPositionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        return sizeResult == .success && (firstPositionResult == .success || finalPositionResult == .success)
    }

    private func beginPlacement(target: CGRect, screenWidth: CGFloat, info: WindowInfo) {
        nextPlacementGeneration += 1
        let generation = nextPlacementGeneration
        placementGeneration[info.key] = generation
        runPlacementAttempt(
            target: target,
            screenWidth: screenWidth,
            info: info,
            generation: generation,
            attempt: 0
        )
    }

    private func runPlacementAttempt(
        target: CGRect,
        screenWidth: CGFloat,
        info: WindowInfo,
        generation: Int,
        attempt: Int
    ) {
        guard placementGeneration[info.key] == generation else { return }
        _ = apply(frame: target, to: info.element)
        let delay = placementRetryDelays[min(attempt, placementRetryDelays.count - 1)]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.placementGeneration[info.key] == generation else { return }
            guard let actual = self.getFrame(info.element) else {
                if attempt + 1 < self.placementRetryDelays.count {
                    self.runPlacementAttempt(
                        target: target,
                        screenWidth: screenWidth,
                        info: info,
                        generation: generation,
                        attempt: attempt + 1
                    )
                } else {
                    self.placementGeneration.removeValue(forKey: info.key)
                    self.issueHandler?(.verificationFailed(appName: info.appName))
                }
                return
            }

            switch LayoutEngine.placementDecision(
                target: target,
                actual: actual,
                attempt: attempt,
                maximumAttempts: self.placementRetryDelays.count
            ) {
            case .succeeded:
                self.placementGeneration.removeValue(forKey: info.key)
            case .retry:
                self.runPlacementAttempt(
                    target: target,
                    screenWidth: screenWidth,
                    info: info,
                    generation: generation,
                    attempt: attempt + 1
                )
            case .exhausted:
                self.placementGeneration.removeValue(forKey: info.key)
                if actual.width > target.width + 2 {
                    let recommended = LayoutEngine.maximumColumnCount(for: actual.width, screenWidth: screenWidth)
                    self.issueHandler?(.constrained(
                        appName: info.appName,
                        targetWidth: target.width,
                        actualWidth: actual.width,
                        recommendedColumns: recommended
                    ))
                } else {
                    self.issueHandler?(.placementRejected(appName: info.appName))
                }
            }
        }
    }

    private func rememberSnappedWindow(_ info: WindowInfo) {
        guard let number = info.windowNumber else { return }
        snappedWindowVisibility[number] = true
    }

    private func reportDesktopSpaceTransitionIfNeeded() {
        guard !snappedWindowVisibility.isEmpty else { return }
        let currentVisibility = windowVisibility()
        var newlyHidden = 0
        for (windowID, wasVisible) in snappedWindowVisibility {
            let isVisible = currentVisibility[windowID] ?? false
            if wasVisible && !isVisible { newlyHidden += 1 }
            snappedWindowVisibility[windowID] = isVisible
        }
        if newlyHidden > 0 {
            issueHandler?(.desktopSpaceChanged(hiddenWindowCount: newlyHidden))
        }
    }

    private func windowVisibility() -> [CGWindowID: Bool] {
        guard let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var result: [CGWindowID: Bool] = [:]
        for row in rows {
            guard let number = row[kCGWindowNumber as String] as? NSNumber else { continue }
            result[CGWindowID(number.uint32Value)] = row[kCGWindowIsOnscreen as String] as? Bool ?? false
        }
        return result
    }

    private var primaryTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
    private func axToCocoa(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.minY - rect.height, width: rect.width, height: rect.height)
    }
    private func cocoaToAX(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    private func bestScreen(for frame: CGRect, screens: [NSScreen]) -> NSScreen {
        screens.max { frame.intersection($0.frame).area < frame.intersection($1.frame).area } ?? screens[0]
    }
}

private struct WindowInfo {
    let element: AXUIElement
    let frame: CGRect
    let key: String
    let appName: String
    let windowNumber: CGWindowID?
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
