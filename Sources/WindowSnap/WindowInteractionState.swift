import CoreGraphics

enum WindowDragMotion {
    static func confirms(origin: CGPoint, current: CGPoint, initial: CGRect, actual: CGRect) -> Bool {
        let mouseDX = current.x - origin.x
        let mouseDY = current.y - origin.y
        let windowDX = actual.minX - initial.minX
        let windowDY = actual.minY - initial.minY
        return hypot(mouseDX, mouseDY) > 2
            && hypot(windowDX, windowDY) > 2
            && abs(mouseDX - windowDX) <= 24
            && abs(mouseDY - windowDY) <= 24
            && abs(actual.width - initial.width) <= 2
            && abs(actual.height - initial.height) <= 2
    }
}

struct WindowIdentity: Hashable {
    let rawValue: Int
}

struct WindowPlacementToken: Equatable {
    let interaction: Int
    let generation: Int
    let window: WindowIdentity
}

struct WindowInteractionState {
    private(set) var interaction: Int = 0
    private(set) var candidate: WindowIdentity?
    private(set) var dragConfirmed: Bool = false

    private var generation: Int = 0
    private var activePlacement: WindowPlacementToken?

    mutating func beginInteraction() -> Int {
        interaction += 1
        candidate = nil
        dragConfirmed = false
        activePlacement = nil
        return interaction
    }

    func isCurrentInteraction(_ id: Int) -> Bool {
        interaction == id
    }

    mutating func bindCandidate(_ window: WindowIdentity, interaction id: Int) -> Bool {
        guard isCurrentInteraction(id), candidate == nil || candidate == window else { return false }
        candidate = window
        return true
    }

    mutating func confirmDrag(_ window: WindowIdentity, interaction id: Int) -> Bool {
        guard isCurrentInteraction(id), candidate == window else { return false }
        dragConfirmed = true
        return true
    }

    mutating func cancelInteraction(_ id: Int) {
        guard isCurrentInteraction(id) else { return }
        candidate = nil
        dragConfirmed = false
        activePlacement = nil
    }

    mutating func beginPlacement(for window: WindowIdentity, interaction id: Int) -> WindowPlacementToken? {
        guard isCurrentInteraction(id), candidate == window, dragConfirmed else { return nil }
        generation += 1
        let token = WindowPlacementToken(interaction: id, generation: generation, window: window)
        activePlacement = token
        candidate = nil
        dragConfirmed = false
        return token
    }

    func isCurrent(_ token: WindowPlacementToken) -> Bool {
        isCurrentInteraction(token.interaction) && activePlacement == token
    }

    @discardableResult
    mutating func finishPlacement(_ token: WindowPlacementToken) -> Bool {
        guard isCurrent(token) else { return false }
        activePlacement = nil
        return true
    }
}
