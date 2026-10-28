import CoreGraphics
import Darwin

@main
struct LayoutEngineSelfTest {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        let screen = CGRect(x: 0, y: 20, width: 1200, height: 780)
        let current = CGRect(x: 100, y: 100, width: 600, height: 400)

        expect(LayoutEngine.frame(for: .leftHalf, in: screen, current: current) == CGRect(x: 0, y: 20, width: 600, height: 780), "left half")
        expect(LayoutEngine.frame(for: .rightHalf, in: screen, current: current) == CGRect(x: 600, y: 20, width: 600, height: 780), "right half")
        expect(LayoutEngine.frame(for: .centerThird, in: screen, current: current) == CGRect(x: 400, y: 20, width: 400, height: 780), "center third")

        let target = CGRect(x: 1200, y: 0, width: 600, height: 400)
        let moved = LayoutEngine.movedFrame(current, from: screen, to: target)
        expect(abs(moved.width - 300) < 0.001, "display move width")
        expect(abs(moved.height - 400 * 400 / 780) < 0.001, "display move height")
        expect(moved.minX >= target.minX && moved.maxX <= target.maxX, "display move bounds")

        let ultrawide = CGRect(x: 0, y: 25, width: 5120, height: 1415)
        let groups: [[WindowAction]] = [
            [.four1, .four2, .four3, .four4],
            [.five1, .five2, .five3, .five4, .five5],
            [.six1, .six2, .six3, .six4, .six5, .six6],
            [.seven1, .seven2, .seven3, .seven4, .seven5, .seven6, .seven7],
            [.eight1, .eight2, .eight3, .eight4, .eight5, .eight6, .eight7, .eight8]
        ]
        for actions in groups {
            let frames = actions.compactMap { LayoutEngine.frame(for: $0, in: ultrawide, current: current) }
            expect(frames.count == actions.count, "\(actions.count)-column frame count")
            expect(frames.first?.minX == ultrawide.minX, "\(actions.count)-column left edge")
            expect(frames.last?.maxX == ultrawide.maxX, "\(actions.count)-column right edge")
            expect(frames.allSatisfy { $0.minY == ultrawide.minY && $0.height == ultrawide.height }, "\(actions.count)-column height")
            for index in 1..<frames.count {
                expect(frames[index - 1].maxX == frames[index].minX, "\(actions.count)-column boundary \(index)")
            }
        }
        expect(WindowAction.column(index: 0, count: 4) == .four1, "4-column first action lookup")
        expect(WindowAction.column(index: 3, count: 4) == .four4, "4-column last action lookup")
        expect(WindowAction.column(index: 4, count: 4) == nil, "4-column out-of-range lookup")

        let exactTarget = CGRect(x: 640, y: 74, width: 640, height: 1336)
        expect(LayoutEngine.placementFits(target: exactTarget, actual: exactTarget), "exact placement fits")
        expect(LayoutEngine.placementFits(target: exactTarget, actual: exactTarget.offsetBy(dx: 2, dy: -1)), "placement tolerance")
        expect(!LayoutEngine.placementFits(target: exactTarget, actual: CGRect(x: 640, y: 74, width: 853, height: 1336)), "minimum-width overflow detected")
        expect(LayoutEngine.maximumColumnCount(for: 640, screenWidth: 5120) == 8, "640 point window supports 8 columns")
        expect(LayoutEngine.maximumColumnCount(for: 853, screenWidth: 5120) == 6, "853 point window supports 6 columns")
        expect(LayoutEngine.maximumColumnCount(for: 900, screenWidth: 5120) == 5, "900 point window supports 5 columns")
        let wideActual = CGRect(x: 0, y: 74, width: 1220, height: 1336)
        expect(LayoutEngine.placementDecision(target: exactTarget, actual: wideActual, attempt: 0, maximumAttempts: 8) == .retry, "wide first result retries")
        expect(LayoutEngine.placementDecision(target: exactTarget, actual: exactTarget, attempt: 1, maximumAttempts: 8) == .succeeded, "later successful resize completes same operation")
        expect(LayoutEngine.placementDecision(target: exactTarget, actual: wideActual, attempt: 7, maximumAttempts: 8) == .exhausted, "constraint reported only after final attempt")

        if failures == 0 {
            print("PASS: all layout self-tests")
        } else {
            print("FAILED: \(failures) layout self-test(s)")
            exit(1)
        }
    }
}
