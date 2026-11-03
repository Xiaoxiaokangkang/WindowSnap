import CoreGraphics

extension LayoutEngineSelfTest {
    static func testPhysicalWindowEvidence() {
        let a = PhysicalWindowKey(pid: 42, number: 101)
        let b = PhysicalWindowKey(pid: 42, number: 102)
        let otherPID = PhysicalWindowKey(pid: 99, number: 101)
        let frameA = CGRect(x: -600, y: 74, width: 600, height: 900)
        let frameB = CGRect(x: 0, y: 74, width: 600, height: 900)
        let windowA = PhysicalWindowSnapshot(key: a, frame: frameA, isOnscreen: true, zIndex: 9)
        let windowB = PhysicalWindowSnapshot(key: b, frame: frameB, isOnscreen: true, zIndex: 0)
        let windows = [windowA, windowB]

        func validate(
            _ frame: CGRect,
            number: UInt32? = nil,
            expected: PhysicalWindowKey? = nil,
            snapshots: [PhysicalWindowSnapshot] = windows,
            pid: Int32 = 42
        ) -> PhysicalWindowValidation {
            PhysicalWindowEvidence.validate(
                pid: pid, axNumber: number, axFrame: frame,
                expected: expected, windows: snapshots
            )
        }

        expect(validate(frameA) == .matched(a), "no AX number: same-PID window A maps by unique geometry")
        expect(validate(frameB) == .matched(b), "no AX number: same-PID window B maps by unique geometry")
        expect(validate(frameA, number: a.number, expected: a) == .matched(a), "matching explicit number and prior key validate")
        expect(validate(frameA, number: b.number) == .mismatch, "explicit AX number cannot override unique geometry")
        expect(validate(frameA, expected: b) == .mismatch, "proxy jumping to old window cannot change expected key")
        expect(validate(frameA, number: a.number, expected: b) == .mismatch, "matching AX number does not override expected key")
        expect(validate(frameA, expected: otherPID) == .mismatch, "same number with different expected PID is a mismatch")
        expect(a != otherPID && Set([a, b, otherPID]).count == 3, "physical key includes both PID and number")

        let overlapB = PhysicalWindowSnapshot(key: b, frame: frameA, isOnscreen: true, zIndex: -1)
        for snapshots in [[windowA, overlapB], [overlapB, windowA]] {
            expect(validate(frameA, snapshots: snapshots) == .ambiguous, "complete overlap stays ambiguous regardless of z-order")
            expect(validate(frameA, number: a.number, snapshots: snapshots) == .ambiguous, "AX number cannot resolve overlapping geometry")
            expect(validate(frameA, expected: a, snapshots: snapshots) == .ambiguous, "prior binding cannot resolve overlapping geometry")
            expect(validate(frameA, number: a.number, expected: a, snapshots: snapshots) == .ambiguous, "number and expected together cannot guess through overlap")
            expect(validate(frameA, number: 999, expected: otherPID, snapshots: snapshots) == .ambiguous, "multiple geometry candidates take precedence over identity hints")
        }
        let foreignWindow = PhysicalWindowSnapshot(key: otherPID, frame: frameA, isOnscreen: true, zIndex: -10)
        expect(validate(frameA, snapshots: [foreignWindow, windowA]) == .matched(a), "different-PID overlap does not introduce ambiguity")
        expect(validate(frameA, snapshots: [foreignWindow]) == .missing, "different-PID geometry cannot supply evidence")
        expect(validate(frameA, snapshots: [foreignWindow, windowA], pid: 99) == .matched(otherPID), "PID filter maps only requested process")
        expect(validate(frameA, expected: a, snapshots: [foreignWindow], pid: 99) == .mismatch, "unique candidate from requested PID must still match expected PID")

        let hiddenA = PhysicalWindowSnapshot(key: a, frame: frameA, isOnscreen: false, zIndex: 0)
        expect(validate(frameA, snapshots: []) == .missing, "disappeared window has no physical evidence")
        expect(validate(frameA, number: a.number, expected: a, snapshots: []) == .missing, "identity hints cannot resurrect disappeared window")
        expect(validate(frameA, snapshots: [hiddenA, windowB]) == .missing, "offscreen window cannot supply evidence")
        expect(validate(frameA, snapshots: [hiddenA, overlapB]) == .matched(b), "offscreen overlap does not introduce ambiguity")

        let boundary = CGRect(x: frameA.origin.x + 4, y: frameA.origin.y - 4,
                              width: frameA.size.width + 4, height: frameA.size.height - 4)
        expect(PhysicalWindowEvidence.frameMatches(frameA, boundary), "all four component tolerance boundaries are inclusive")
        expect(PhysicalWindowEvidence.frameMatches(boundary, frameA), "frame matching is symmetric")
        expect(validate(boundary) == .matched(a), "four-point component differences validate")
        for component in 0..<4 {
            for delta: CGFloat in [-4.001, 4.001] {
                var outside = frameA
                switch component {
                case 0: outside.origin.x += delta
                case 1: outside.origin.y += delta
                case 2: outside.size.width += delta
                default: outside.size.height += delta
                }
                expect(!PhysicalWindowEvidence.frameMatches(frameA, outside), "component \(component) beyond four points is rejected")
                expect(validate(outside) == .missing, "out-of-tolerance component \(component) supplies no geometry candidate")
            }
        }

        var invalidFrames: [CGRect] = [.zero, .null, .infinite]
        for component in 0..<4 {
            for invalid: CGFloat in [.nan, .infinity, -.infinity] {
                var frame = frameA
                switch component {
                case 0: frame.origin.x = invalid
                case 1: frame.origin.y = invalid
                case 2: frame.size.width = invalid
                default: frame.size.height = invalid
                }
                invalidFrames.append(frame)
            }
        }
        for invalid: CGFloat in [0, -1] {
            invalidFrames.append(CGRect(x: 0, y: 74, width: invalid, height: 900))
            invalidFrames.append(CGRect(x: 0, y: 74, width: 600, height: invalid))
        }
        for (index, invalid) in invalidFrames.enumerated() {
            expect(!PhysicalWindowEvidence.frameMatches(frameA, invalid), "invalid frame \(index) cannot match as right operand")
            expect(!PhysicalWindowEvidence.frameMatches(invalid, frameA), "invalid frame \(index) cannot match as left operand")
            expect(validate(invalid) == .mismatch, "invalid AX frame \(index) is an explicit mismatch")
            let invalidSnapshot = PhysicalWindowSnapshot(key: a, frame: invalid, isOnscreen: true, zIndex: 0)
            expect(validate(frameA, snapshots: [invalidSnapshot]) == .missing, "invalid CG frame \(index) is not a geometry candidate")
        }
        let tiny = CGRect(x: -10, y: -20, width: 0.1, height: 0.1)
        expect(PhysicalWindowEvidence.frameMatches(tiny, tiny), "positive fractional sizes and negative coordinates are valid")
        expect(PhysicalWindowEvidence.frameMatches(frameA, frameA), "exact geometry matches")

        // Pure post-write fixture: AX claims its target while CG still shows the old frame.
        let claimedTarget = CGRect(x: 700, y: 74, width: 600, height: 900)
        expect(validate(claimedTarget, number: b.number, expected: b) == .missing, "AX-only write success without CG movement is not verified")
        expect(validate(frameA, number: b.number, expected: b) == .mismatch, "AX fake success at old window geometry conflicts with bound identity")
        expect(validate(frameA, expected: b) == .mismatch, "AX fake success is rejected even without an AX number")
        let movedB = PhysicalWindowSnapshot(key: b, frame: claimedTarget, isOnscreen: true, zIndex: 0)
        expect(validate(claimedTarget, number: b.number, expected: b, snapshots: [windowA, movedB]) == .matched(b), "post-write success requires matching physical CG evidence")
        print("PASS: physical window evidence identity, ambiguity, PID isolation, geometry and post-write checks")
    }
}
