import CoreGraphics

struct PhysicalWindowKey: Hashable {
    let pid: Int32
    let number: UInt32
}

struct PhysicalWindowSnapshot: Equatable {
    let key: PhysicalWindowKey
    let frame: CGRect
    let isOnscreen: Bool
    let zIndex: Int
}

enum PhysicalWindowValidation: Equatable {
    case matched(PhysicalWindowKey)
    case missing
    case ambiguous
    case mismatch
}

enum PhysicalWindowEvidence {
    static func validate(
        pid: Int32,
        axNumber: UInt32?,
        axFrame: CGRect,
        expected: PhysicalWindowKey?,
        windows: [PhysicalWindowSnapshot]
    ) -> PhysicalWindowValidation {
        guard isValidFrame(axFrame) else { return .mismatch }
        let candidates = windows.filter {
            $0.isOnscreen && $0.key.pid == pid && frameMatches(axFrame, $0.frame)
        }
        guard let candidate = candidates.first else { return .missing }
        // Neither an AX number, a prior binding, nor z-order resolves overlap.
        guard candidates.count == 1 else { return .ambiguous }
        if let axNumber, axNumber != candidate.key.number { return .mismatch }
        if let expected, expected != candidate.key { return .mismatch }
        return .matched(candidate.key)
    }

    static func frameMatches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        guard isValidFrame(lhs), isValidFrame(rhs) else { return false }
        return abs(lhs.origin.x - rhs.origin.x) <= 4
            && abs(lhs.origin.y - rhs.origin.y) <= 4
            && abs(lhs.size.width - rhs.size.width) <= 4
            && abs(lhs.size.height - rhs.size.height) <= 4
    }

    private static func isValidFrame(_ frame: CGRect) -> Bool {
        !frame.isInfinite && !frame.isNull
            && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width > 0 && frame.size.height > 0
    }
}
