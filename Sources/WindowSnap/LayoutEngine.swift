import CoreGraphics

enum PlacementAttemptDecision: Equatable {
    case succeeded
    case retry
    case exhausted
}

enum WindowAction: String, CaseIterable, Codable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird
    case maximize, center, restore, nextDisplay, previousDisplay
    case four1, four2, four3, four4
    case five1, five2, five3, five4, five5
    case six1, six2, six3, six4, six5, six6
    case seven1, seven2, seven3, seven4, seven5, seven6, seven7
    case eight1, eight2, eight3, eight4, eight5, eight6, eight7, eight8

    var title: String {
        switch self {
        case .leftHalf: "左半屏"
        case .rightHalf: "右半屏"
        case .topHalf: "上半屏"
        case .bottomHalf: "下半屏"
        case .topLeft: "左上角"
        case .topRight: "右上角"
        case .bottomLeft: "左下角"
        case .bottomRight: "右下角"
        case .leftThird: "左侧三分之一"
        case .centerThird: "中间三分之一"
        case .rightThird: "右侧三分之一"
        case .maximize: "最大化"
        case .center: "居中"
        case .restore: "恢复原尺寸"
        case .nextDisplay: "移到下一台显示器"
        case .previousDisplay: "移到上一台显示器"
        case .four1: "4 分屏 · 第 1 列"
        case .four2: "4 分屏 · 第 2 列"
        case .four3: "4 分屏 · 第 3 列"
        case .four4: "4 分屏 · 第 4 列"
        case .five1: "5 分屏 · 第 1 列"
        case .five2: "5 分屏 · 第 2 列"
        case .five3: "5 分屏 · 第 3 列"
        case .five4: "5 分屏 · 第 4 列"
        case .five5: "5 分屏 · 第 5 列"
        case .six1: "6 分屏 · 第 1 列"
        case .six2: "6 分屏 · 第 2 列"
        case .six3: "6 分屏 · 第 3 列"
        case .six4: "6 分屏 · 第 4 列"
        case .six5: "6 分屏 · 第 5 列"
        case .six6: "6 分屏 · 第 6 列"
        case .seven1: "7 分屏 · 第 1 列"
        case .seven2: "7 分屏 · 第 2 列"
        case .seven3: "7 分屏 · 第 3 列"
        case .seven4: "7 分屏 · 第 4 列"
        case .seven5: "7 分屏 · 第 5 列"
        case .seven6: "7 分屏 · 第 6 列"
        case .seven7: "7 分屏 · 第 7 列"
        case .eight1: "8 分屏 · 第 1 列"
        case .eight2: "8 分屏 · 第 2 列"
        case .eight3: "8 分屏 · 第 3 列"
        case .eight4: "8 分屏 · 第 4 列"
        case .eight5: "8 分屏 · 第 5 列"
        case .eight6: "8 分屏 · 第 6 列"
        case .eight7: "8 分屏 · 第 7 列"
        case .eight8: "8 分屏 · 第 8 列"
        }
    }

    /// Zero-based column index and total column count for ultrawide layouts.
    var columnLayout: (index: Int, count: Int)? {
        switch self {
        case .four1: (0, 4); case .four2: (1, 4); case .four3: (2, 4); case .four4: (3, 4)
        case .five1: (0, 5); case .five2: (1, 5); case .five3: (2, 5); case .five4: (3, 5); case .five5: (4, 5)
        case .six1: (0, 6); case .six2: (1, 6); case .six3: (2, 6); case .six4: (3, 6); case .six5: (4, 6); case .six6: (5, 6)
        case .seven1: (0, 7); case .seven2: (1, 7); case .seven3: (2, 7); case .seven4: (3, 7); case .seven5: (4, 7); case .seven6: (5, 7); case .seven7: (6, 7)
        case .eight1: (0, 8); case .eight2: (1, 8); case .eight3: (2, 8); case .eight4: (3, 8); case .eight5: (4, 8); case .eight6: (5, 8); case .eight7: (6, 8); case .eight8: (7, 8)
        default: nil
        }
    }

    static func column(index: Int, count: Int) -> WindowAction? {
        allCases.first { $0.columnLayout?.index == index && $0.columnLayout?.count == count }
    }

    var isShortcutConfigurable: Bool {
        switch self {
        case .leftThird, .centerThird, .rightThird,
             .four1, .four2, .four3, .four4:
            true
        default:
            false
        }
    }

    var menuGroup: Int {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: 0
        case .topLeft, .topRight, .bottomLeft, .bottomRight: 1
        case .leftThird, .centerThird, .rightThird: 2
        case .maximize, .center, .restore: 3
        case .nextDisplay, .previousDisplay: 4
        default: 5
        }
    }
}

enum LayoutEngine {
    static func placementDecision(
        target: CGRect,
        actual: CGRect,
        attempt: Int,
        maximumAttempts: Int
    ) -> PlacementAttemptDecision {
        if placementFits(target: target, actual: actual) { return .succeeded }
        return attempt + 1 < maximumAttempts ? .retry : .exhausted
    }

    static func placementFits(target: CGRect, actual: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(target.minX - actual.minX) <= tolerance
            && abs(target.minY - actual.minY) <= tolerance
            && abs(target.width - actual.width) <= tolerance
            && abs(target.height - actual.height) <= tolerance
    }

    static func maximumColumnCount(
        for minimumWidth: CGFloat,
        screenWidth: CGFloat,
        limit: Int = 8,
        tolerance: CGFloat = 2
    ) -> Int {
        guard minimumWidth > 0, screenWidth > 0 else { return 1 }
        for count in stride(from: max(1, limit), through: 1, by: -1) {
            let narrowestSlot = floor(screenWidth / CGFloat(count))
            if minimumWidth <= narrowestSlot + tolerance { return count }
        }
        return 1
    }

    static func frame(for action: WindowAction, in visible: CGRect, current: CGRect) -> CGRect? {
        let x = visible.minX, y = visible.minY, w = visible.width, h = visible.height
        if let column = action.columnLayout {
            // Derive both edges from the same origin so fractional divisions remain contiguous.
            let left = x + floor(w * CGFloat(column.index) / CGFloat(column.count))
            let right = x + floor(w * CGFloat(column.index + 1) / CGFloat(column.count))
            return CGRect(x: left, y: y, width: right - left, height: h)
        }
        switch action {
        case .leftHalf: return CGRect(x: x, y: y, width: w / 2, height: h)
        case .rightHalf: return CGRect(x: x + w / 2, y: y, width: w / 2, height: h)
        case .topHalf: return CGRect(x: x, y: y + h / 2, width: w, height: h / 2)
        case .bottomHalf: return CGRect(x: x, y: y, width: w, height: h / 2)
        case .topLeft: return CGRect(x: x, y: y + h / 2, width: w / 2, height: h / 2)
        case .topRight: return CGRect(x: x + w / 2, y: y + h / 2, width: w / 2, height: h / 2)
        case .bottomLeft: return CGRect(x: x, y: y, width: w / 2, height: h / 2)
        case .bottomRight: return CGRect(x: x + w / 2, y: y, width: w / 2, height: h / 2)
        case .leftThird: return CGRect(x: x, y: y, width: w / 3, height: h)
        case .centerThird: return CGRect(x: x + w / 3, y: y, width: w / 3, height: h)
        case .rightThird: return CGRect(x: x + 2 * w / 3, y: y, width: w / 3, height: h)
        case .maximize: return visible
        case .center:
            let nw = min(current.width, w * 0.72)
            let nh = min(current.height, h * 0.78)
            return CGRect(x: x + (w - nw) / 2, y: y + (h - nh) / 2, width: nw, height: nh)
        case .restore, .nextDisplay, .previousDisplay: return nil
        default: return nil // Column layouts are handled above.
        }
    }

    static func movedFrame(_ current: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let widthRatio = min(current.width / source.width, 1)
        let heightRatio = min(current.height / source.height, 1)
        let relativeX = source.width > current.width ? (current.minX - source.minX) / (source.width - current.width) : 0.5
        let relativeY = source.height > current.height ? (current.minY - source.minY) / (source.height - current.height) : 0.5
        let newSize = CGSize(width: target.width * widthRatio, height: target.height * heightRatio)
        let nx = target.minX + max(0, min(1, relativeX)) * (target.width - newSize.width)
        let ny = target.minY + max(0, min(1, relativeY)) * (target.height - newSize.height)
        return CGRect(origin: CGPoint(x: nx, y: ny), size: newSize)
    }
}
