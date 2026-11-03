import AppKit
import ApplicationServices
import OSLog

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
    private let logger = Logger(subsystem: "com.local.windowsnap", category: "Placement")
    private var savedFrames: [WindowIdentity: CGRect] = [:]
    private var lastExternalPID: pid_t?
    private var snappedWindowVisibility: [CGWindowID: Bool] = [:]
    private var interactions = WindowInteractionState()
    private var windowIdentities: [(element: AXUIElement, identity: WindowIdentity)] = []
    private var nextWindowIdentity = 0
    private var draggedWindow: WindowInfo?
    private var dragOrigin: CGPoint?
    private var dragAnchor: DragWindowAnchor?
    private var dragInitialFrame: CGRect?
    private var dragStartedAt: TimeInterval = 0
    private let evidence = WindowEvidenceRecorder()
    private var physicalWindows: [WindowIdentity: PhysicalWindowKey] = [:]
    private var placedWindows: [PhysicalWindowKey: WindowInfo] = [:]
    private var evidenceSession: WindowEvidenceSession?
    private var evidenceBaseline: [PhysicalWindowSnapshot]?
    private var lastDragEvidenceAt: TimeInterval = 0
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
        let interaction = beginWindowInteraction(at: nil, timestamp: 0)
        reportDesktopSpaceTransitionIfNeeded()
        guard interactions.isCurrentInteraction(interaction),
              let info = focusedWindow() else { NSSound.beep(); return .noFocusedWindow }
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
            if action.columnLayout != nil || action.isShortcutConfigurable {
                guard interactions.bindCandidate(info.key, interaction: interaction),
                      interactions.confirmDrag(info.key, interaction: interaction) else { return .unavailable }
                beginPlacement(target: target, info: info, interaction: interaction)
            } else if !apply(frame: target, to: info.element) {
                return .unavailable
            }
            return .success
        }
        return .unavailable
    }

    @discardableResult
    func beginWindowInteraction(at point: NSPoint?, timestamp: TimeInterval) -> Int {
        // A new user interaction owns all future writes. Never keep settling an old window.
        let interaction = interactions.beginInteraction()
        draggedWindow = nil
        dragOrigin = point
        dragAnchor = nil
        dragInitialFrame = nil
        dragStartedAt = timestamp
        evidenceSession = nil
        evidenceBaseline = physicalSnapshots()
        lastDragEvidenceAt = 0
        guard let point, AXIsProcessTrusted() else { return interaction }
        dragAnchor = windowAnchor(at: point)
        dragInitialFrame = dragAnchor?.frame
        var allowRetry = true
        if let info = windowAtPoint(point, allowRetry: &allowRetry), isPoint(point, inTitleBarOf: info) {
            if matchesDragAnchor(info), interactions.bindCandidate(info.key, interaction: interaction) {
                draggedWindow = info
                dragInitialFrame = info.frame
                startEvidence(info: info, interaction: interaction)
                logger.notice("Bound interaction=\(interaction) identity=\(info.key.rawValue)")
            } else {
                startEvidence(info: info, interaction: interaction)
                if let session = evidenceSession {
                    captureEvidence("binding-rejected", session: session, detail: "AX hit does not uniquely match mouse-down CG window")
                }
                dragAnchor = nil
            }
        } else if !allowRetry {
            // A resolved but ineligible hit (sheet, content, own UI) is not an AX delay.
            dragAnchor = nil
        }
        return interaction
    }

    func isCurrentInteraction(_ interaction: Int) -> Bool {
        interactions.isCurrentInteraction(interaction)
    }

    func cancelColumnDrag(interaction: Int) {
        guard interactions.isCurrentInteraction(interaction) else { return }
        if let session = evidenceSession { captureEvidence("cancel", session: session) }
        interactions.cancelInteraction(interaction)
        draggedWindow = nil
        dragOrigin = nil
        dragAnchor = nil
    }

    func observeWindowDrag(at point: NSPoint, timestamp: TimeInterval, interaction: Int) -> Bool {
        guard interactions.isCurrentInteraction(interaction), AXIsProcessTrusted(),
              let origin = dragOrigin else { return false }
        if draggedWindow == nil {
            // Retry only the window number captured at mouse-down. Re-hit-testing the old
            // point after C moves could pick A underneath it, even within the same app.
            guard timestamp >= dragStartedAt, timestamp - dragStartedAt <= 0.5,
                  let anchor = dragAnchor,
                  CGRect(x: anchor.frame.minX, y: anchor.frame.maxY - min(84, anchor.frame.height),
                         width: anchor.frame.width, height: min(84, anchor.frame.height)).contains(origin),
                  let info = windowMatching(anchor),
                  isPoint(point, inTitleBarOf: info),
                  interactions.bindCandidate(info.key, interaction: interaction) else { return false }
            draggedWindow = info
            startEvidence(info: info, interaction: interaction)
        }
        if let session = evidenceSession, timestamp - lastDragEvidenceAt >= 0.15 {
            lastDragEvidenceAt = timestamp
            captureEvidence("drag", session: session)
        }
        guard let info = draggedWindow, let initial = dragInitialFrame,
              let actual = getFrame(info.element) else { return false }
        if interactions.dragConfirmed { return true }
        guard WindowDragMotion.confirms(origin: origin, current: point, initial: initial, actual: actual) else { return false }
        return interactions.confirmDrag(info.key, interaction: interaction)
    }

    @discardableResult
    func placeDraggedWindow(column index: Int, count: Int, in visibleFrame: CGRect, interaction: Int) -> WindowOperationResult {
        guard AXIsProcessTrusted() else {
            cancelColumnDrag(interaction: interaction)
            return .accessibilityPermissionRequired
        }
        guard interactions.isCurrentInteraction(interaction), interactions.dragConfirmed,
              let info = draggedWindow else { return .noFocusedWindow }
        if let session = evidenceSession { captureEvidence("mouse-up", session: session) }
        guard canPlace(info), validatePhysicalWindow(info, stage: "mouse-up") else {
            cancelColumnDrag(interaction: interaction)
            return .unavailable
        }
        draggedWindow = nil
        dragOrigin = nil
        dragAnchor = nil
        guard let action = WindowAction.column(index: index, count: count),
              let target = LayoutEngine.frame(for: action, in: visibleFrame, current: info.frame) else {
            interactions.cancelInteraction(interaction)
            return .unavailable
        }
        remember(info, originalFrame: dragInitialFrame)
        dragInitialFrame = nil
        rememberSnappedWindow(info)
        // Keep the captured AX object; never resolve focus again after mouse-up.
        beginPlacement(target: target, info: info, interaction: interaction, initialDelay: 0.12)
        return .success
    }

    private func isPoint(_ point: NSPoint, inTitleBarOf info: WindowInfo) -> Bool {
        // Unified toolbars in browsers and document apps are often taller than a classic title bar.
        let titleBarHeight = min(84, info.frame.height)
        let titleBar = CGRect(x: info.frame.minX, y: info.frame.maxY - titleBarHeight, width: info.frame.width, height: titleBarHeight)
        return titleBar.contains(point)
    }

    private func remember(_ info: WindowInfo, originalFrame: CGRect? = nil) {
        if savedFrames[info.key] == nil { savedFrames[info.key] = originalFrame ?? info.frame }
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
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return windowInfo(unsafeDowncast(value, to: AXUIElement.self))
    }

    private func windowInfo(_ window: AXUIElement) -> WindowInfo? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier,
              stringAttribute(kAXRoleAttribute, of: window) == kAXWindowRole,
              let frame = getFrame(window), frame.width > 0, frame.height > 0,
              frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else { return nil }
        let identity: WindowIdentity
        if let existing = windowIdentities.first(where: { CFEqual($0.element, window) }) {
            identity = existing.identity
        } else {
            nextWindowIdentity += 1
            identity = WindowIdentity(rawValue: nextWindowIdentity)
            windowIdentities.append((window, identity))
        }
        return WindowInfo(element: window, frame: frame, key: identity, pid: pid,
                          appName: NSRunningApplication(processIdentifier: pid)?.localizedName ?? "当前应用",
                          windowNumber: (attribute("AXWindowNumber", of: window) as? NSNumber).map { CGWindowID($0.uint32Value) })
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        attribute(name, of: element) as? String
    }

    private func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func windowAtPoint(_ point: CGPoint, allowRetry: inout Bool) -> WindowInfo? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(primaryTop - point.y), &hit) == .success,
              let hit else { return nil }
        var current: AXUIElement? = hit
        var visited: [AXUIElement] = []
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hit, &hitPID) == .success else { return nil }
        if hitPID == ProcessInfo.processInfo.processIdentifier {
            allowRetry = false
            return nil
        }
        for _ in 0..<32 {
            guard let element = current, !visited.contains(where: { CFEqual($0, element) }) else { return nil }
            visited.append(element)
            let role = stringAttribute(kAXRoleAttribute, of: element)
            if role == kAXSheetRole || role == kAXDrawerRole {
                allowRetry = false
                return nil
            }
            if role == kAXWindowRole {
                guard let info = windowInfo(element) else { return nil }
                allowRetry = false
                guard info.pid == hitPID else { return nil }
                return info
            }
            current = elementAttribute(kAXParentAttribute, of: element)
        }
        return nil
    }

    private func windowAnchor(at point: CGPoint) -> DragWindowAnchor? {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let axPoint = CGPoint(x: point.x, y: primaryTop - point.y)
        for row in rows {
            guard let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(axPoint),
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let number = row[kCGWindowNumber as String] as? NSNumber else { continue }
            return DragWindowAnchor(pid: pid.int32Value, number: number.uint32Value, frame: axToCocoa(frame))
        }
        return nil
    }

    private func matchesDragAnchor(_ info: WindowInfo) -> Bool {
        guard let anchor = dragAnchor, let windows = physicalSnapshots() else { return false }
        let expected = PhysicalWindowKey(pid: anchor.pid, number: anchor.number)
        guard case .matched(let key) = PhysicalWindowEvidence.validate(
            pid: info.pid, axNumber: info.windowNumber, axFrame: info.frame, expected: expected, windows: windows
        ) else { return false }
        physicalWindows[info.key] = key
        return true
    }

    private func windowMatching(_ anchor: DragWindowAnchor) -> WindowInfo? {
        let app = AXUIElementCreateApplication(anchor.pid)
        guard let windows = attribute(kAXWindowsAttribute, of: app) as? [AXUIElement] else { return nil }
        guard let physical = physicalSnapshots() else { return nil }
        let expected = PhysicalWindowKey(pid: anchor.pid, number: anchor.number)
        let matches = windows.compactMap { element -> WindowInfo? in
            guard let info = windowInfo(element),
                  case .matched = PhysicalWindowEvidence.validate(pid: info.pid, axNumber: info.windowNumber,
                      axFrame: info.frame, expected: expected, windows: physical) else { return nil }
            return info
        }
        guard matches.count == 1 else { return nil }
        physicalWindows[matches[0].key] = expected
        return matches[0]
    }

    private func canPlace(_ info: WindowInfo) -> Bool {
        guard NSRunningApplication(processIdentifier: info.pid)?.isTerminated == false,
              (attribute(kAXMinimizedAttribute, of: info.element) as? Bool) != true,
              (attribute("AXFullScreen", of: info.element) as? Bool) != true else { return false }
        var position: DarwinBoolean = false, size: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(info.element, kAXPositionAttribute as CFString, &position) == .success
            && AXUIElementIsAttributeSettable(info.element, kAXSizeAttribute as CFString, &size) == .success
            && position.boolValue && size.boolValue
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
    private func apply(frame: CGRect, to window: AXUIElement, evidenceStep: ((String) -> Void)? = nil) -> Bool {
        let axFrame = cocoaToAX(frame)
        var point = axFrame.origin, size = axFrame.size
        guard let position = AXValueCreate(.cgPoint, &point),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        AXUIElementSetMessagingTimeout(window, 0.25)
        let firstSizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        evidenceStep?("after-size-1")
        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        evidenceStep?("after-position")
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        evidenceStep?("after-size-2")
        logger.notice("AX write size1=\(firstSizeResult.rawValue) position=\(positionResult.rawValue) size2=\(sizeResult.rawValue)")
        return sizeResult == .success && positionResult == .success
    }

    private func beginPlacement(target: CGRect, info: WindowInfo, interaction: Int, initialDelay: TimeInterval = 0) {
        guard let token = interactions.beginPlacement(for: info.key, interaction: interaction) else { return }
        if evidenceSession == nil { startEvidence(info: info, interaction: interaction) }
        let session = evidenceSession
        rememberSnappedWindow(info)
        if let session { captureEvidence("placement-scheduled", session: session, detail: "target=" + NSStringFromRect(target)) }
        let number = physicalWindows[info.key].map { String($0.number) } ?? "unavailable"
        logger.notice("Begin interaction=\(interaction) generation=\(token.generation) identity=\(info.key.rawValue) pid=\(info.pid) window=\(number, privacy: .public) target=\(NSStringFromRect(target), privacy: .public)")
        let runner = WindowPlacementRunner(
            isCurrent: { [weak self] in self?.interactions.isCurrent(token) == true },
            canPlace: { [weak self] in
                guard let self else { return false }
                return self.canPlace(info) && self.validatePhysicalWindow(info, stage: "before-attempt")
            },
            write: { [weak self] frame in
                guard let self, self.interactions.isCurrent(token) else { return }
                guard self.validatePhysicalWindow(info, stage: "before-write") else {
                    self.interactions.finishPlacement(token)
                    return
                }
                if let session { self.captureEvidence("before-write", session: session) }
                self.logger.notice("Write interaction=\(interaction) generation=\(token.generation) identity=\(info.key.rawValue) pid=\(info.pid)")
                _ = self.apply(frame: frame, to: info.element) { stage in
                    if let session { self.captureEvidence(stage, session: session, includeAX: false) }
                }
                if let session { self.captureEvidence("after-write", session: session) }
            },
            read: { [weak self] in
                guard let self else { return nil }
                if let session { self.captureEvidence("readback", session: session) }
                guard self.validatePhysicalWindow(info, stage: "readback") else {
                    self.interactions.finishPlacement(token)
                    return nil
                }
                return self.getFrame(info.element)
            },
            finish: { [weak self] in
                guard let self else { return }
                if let session { self.captureEvidence("finished", session: session) }
                self.interactions.finishPlacement(token)
                if let session {
                    for delay in [0.5, 2.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            self?.captureEvidence("post-finish-\(delay)", session: session)
                        }
                    }
                }
            },
            report: { [weak self] issue in
                self?.issueHandler?(issue == .verificationFailed
                    ? .verificationFailed(appName: info.appName) : .placementRejected(appName: info.appName))
            },
            sample: { [weak self] attempt, stable, actual in
                self?.logger.notice("Read interaction=\(interaction) generation=\(token.generation) identity=\(info.key.rawValue) attempt=\(attempt) stable=\(stable) actual=\(NSStringFromRect(actual), privacy: .public)")
            },
            schedule: { delay, action in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
            }
        )
        runner.start(target: target, initialDelay: initialDelay)
    }

    private func rememberSnappedWindow(_ info: WindowInfo) {
        guard let key = physicalWindows[info.key] else { return }
        placedWindows[key] = info
        snappedWindowVisibility[key.number] = true
    }

    private func physicalSnapshots() -> [PhysicalWindowSnapshot]? {
        guard let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return rows.enumerated().compactMap { index, row in
            guard (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let number = row[kCGWindowNumber as String] as? NSNumber,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            let converted = axToCocoa(frame)
            guard converted.minX.isFinite, converted.minY.isFinite,
                  converted.width.isFinite, converted.height.isFinite,
                  converted.width > 0, converted.height > 0 else { return nil }
            return PhysicalWindowSnapshot(key: PhysicalWindowKey(pid: pid.int32Value, number: number.uint32Value),
                                          frame: converted, isOnscreen: row[kCGWindowIsOnscreen as String] as? Bool ?? false,
                                          zIndex: index)
        }
    }

    private func startEvidence(info: WindowInfo, interaction: Int) {
        let windows = physicalSnapshots()
        let anchorKey = dragAnchor.map { PhysicalWindowKey(pid: $0.pid, number: $0.number) }
        if physicalWindows[info.key] == nil, let windows,
           case .matched(let key) = PhysicalWindowEvidence.validate(pid: info.pid, axNumber: info.windowNumber,
                  axFrame: info.frame, expected: anchorKey, windows: windows) {
            physicalWindows[info.key] = key
        }
        let target = anchorKey ?? physicalWindows[info.key]
        // Keep a small set of already placed windows, not every window on the desktop.
        let previous = placedWindows.keys.sorted { $0.pid == $1.pid ? $0.number < $1.number : $0.pid < $1.pid }
        var watched = Array(previous.prefix(8))
        if let target, !watched.contains(target) { watched.append(target) }
        let baseline = Dictionary((evidenceBaseline ?? windows ?? []).filter { watched.contains($0.key) }
            .map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let session = WindowEvidenceSession(interaction: interaction, target: target,
                                            watched: watched, baseline: baseline, info: info)
        evidenceSession = session
        captureEvidence("mouse-down", session: session, snapshots: evidenceBaseline)
        captureEvidence("bound", session: session, snapshots: windows)
    }

    private func captureEvidence(_ stage: String, session: WindowEvidenceSession,
                                 snapshots: [PhysicalWindowSnapshot]? = nil, detail: String = "", includeAX: Bool = true) {
        let current = snapshots ?? physicalSnapshots()
        var axRows: [[String: Any]] = []
        var infos = session.watched.compactMap { placedWindows[$0] }
        infos.removeAll { $0.key == session.info.key }
        infos.append(session.info)
        for info in includeAX ? infos : [] {
            AXUIElementSetMessagingTimeout(info.element, 0.05)
            var row: [String: Any] = ["identity": info.key.rawValue, "pid": info.pid]
            if let key = physicalWindows[info.key] { row["physicalWindow"] = key.number }
            if let frame = getFrame(info.element), frame.minX.isFinite, frame.minY.isFinite,
               frame.width.isFinite, frame.height.isFinite {
                row["frame"] = [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]
            }
            row["minimized"] = attribute(kAXMinimizedAttribute, of: info.element) as? Bool
            row["appHidden"] = NSRunningApplication(processIdentifier: info.pid)?.isHidden
            axRows.append(row)
        }
        evidence.record(stage: stage, interaction: session.interaction, currentInteraction: interactions.interaction,
                        target: session.target, watched: session.watched, baseline: session.baseline,
                        snapshots: current, ax: axRows, detail: detail)
    }

    private func validatePhysicalWindow(_ info: WindowInfo, stage: String) -> Bool {
        guard let expected = physicalWindows[info.key], let windows = physicalSnapshots(),
              let frame = getFrame(info.element) else {
            if let session = evidenceSession { captureEvidence("identity-rejected", session: session, detail: stage + ": unavailable") }
            return false
        }
        let number = (attribute("AXWindowNumber", of: info.element) as? NSNumber)?.uint32Value
        let result = PhysicalWindowEvidence.validate(pid: info.pid, axNumber: number, axFrame: frame,
                                                    expected: expected, windows: windows)
        guard case .matched = result else {
            if let session = evidenceSession {
                captureEvidence("identity-rejected", session: session, snapshots: windows,
                                detail: stage + ": " + String(describing: result))
            }
            return false
        }
        return true
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

private struct WindowEvidenceSession {
    let interaction: Int
    let target: PhysicalWindowKey?
    let watched: [PhysicalWindowKey]
    let baseline: [PhysicalWindowKey: PhysicalWindowSnapshot]
    let info: WindowInfo
}

private struct DragWindowAnchor {
    let pid: pid_t
    let number: CGWindowID
    let frame: CGRect
}

private struct WindowInfo {
    let element: AXUIElement
    let frame: CGRect
    let key: WindowIdentity
    let pid: pid_t
    let appName: String
    let windowNumber: CGWindowID?
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
