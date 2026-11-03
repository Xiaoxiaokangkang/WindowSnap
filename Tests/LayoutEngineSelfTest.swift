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

    // Pure callback simulation: identities are supplied by the fixture, not AX hit testing.
    enum CallbackPhase: CaseIterable {
        case initial, retry, stable, issue
    }

    struct CallbackEffects: Equatable {
        var frames: [WindowIdentity: CGRect] = [:]
        var writes = 0
        var samples = 0
        var prompts = 0
    }

    struct PlacementCallback {
        let token: WindowPlacementToken
        let target: CGRect
        let phase: CallbackPhase

        func run(state: WindowInteractionState, effects: inout CallbackEffects) {
            // Use the production gate, never a duplicate token-validation implementation.
            guard state.isCurrent(token) else { return }
            switch phase {
            case .initial, .retry:
                effects.writes += 1
                effects.frames[token.window] = target
            case .stable:
                effects.samples += 1
            case .issue:
                effects.prompts += 1
            }
        }
    }

    static func startPlacement(
        _ state: inout WindowInteractionState,
        window: WindowIdentity
    ) -> WindowPlacementToken? {
        let interaction = state.beginInteraction()
        expect(state.bindCandidate(window, interaction: interaction), "new interaction binds candidate")
        expect(state.confirmDrag(window, interaction: interaction), "bound candidate confirms")
        let token = state.beginPlacement(for: window, interaction: interaction)
        expect(token != nil, "confirmed candidate starts placement")
        return token
    }

    static func testInteractionState() {
        var state = WindowInteractionState()
        let a = WindowIdentity(rawValue: 1)
        let b = WindowIdentity(rawValue: 2)
        expect(state.interaction == 0 && state.candidate == nil && !state.dragConfirmed, "initial interaction state")
        let first = state.beginInteraction()
        expect(first == 1 && state.isCurrentInteraction(first), "begin increments interaction")
        expect(!state.confirmDrag(a, interaction: first), "no candidate cannot confirm")
        expect(state.beginPlacement(for: a, interaction: first) == nil, "no candidate cannot place")
        expect(!state.bindCandidate(a, interaction: first - 1), "stale interaction cannot bind")
        expect(!state.bindCandidate(a, interaction: first + 1), "future interaction cannot bind")
        expect(state.candidate == nil, "wrong interaction leaves candidate empty")
        expect(state.bindCandidate(a, interaction: first), "bind first candidate")
        expect(state.bindCandidate(a, interaction: first), "same candidate binding is idempotent")
        expect(!state.bindCandidate(b, interaction: first), "bound interaction refuses another window")
        expect(!state.confirmDrag(b, interaction: first), "another window cannot confirm drag")
        expect(!state.confirmDrag(a, interaction: first - 1), "wrong interaction cannot confirm drag")
        expect(state.beginPlacement(for: a, interaction: first) == nil, "unconfirmed drag cannot place")
        expect(state.candidate == a && !state.dragConfirmed, "rejected calls preserve unconfirmed binding")
        expect(state.confirmDrag(a, interaction: first), "matching drag confirms")
        expect(state.beginPlacement(for: b, interaction: first) == nil, "wrong window cannot consume placement")
        expect(state.beginPlacement(for: a, interaction: first + 1) == nil, "wrong interaction cannot consume placement")
        expect(state.candidate == a && state.dragConfirmed, "rejected placement preserves confirmed candidate")
        guard let token = state.beginPlacement(for: a, interaction: first) else {
            expect(false, "confirmed placement returns token")
            return
        }
        expect(token.interaction == first && token.window == a && token.generation > 0, "token records interaction, window and generation")
        expect(state.candidate == nil && !state.dragConfirmed && state.isCurrent(token), "placement consumes candidate but keeps active token")
        expect(state.beginPlacement(for: a, interaction: first) == nil, "consumed candidate cannot place twice")
        let forgedTokens = [
            WindowPlacementToken(interaction: first + 1, generation: token.generation, window: a),
            WindowPlacementToken(interaction: first, generation: token.generation + 1, window: a),
            WindowPlacementToken(interaction: first, generation: token.generation, window: b)
        ]
        for forged in forgedTokens {
            expect(!state.isCurrent(forged), "all token fields must match active placement")
            expect(!state.finishPlacement(forged) && state.isCurrent(token), "forged finish cannot clear active placement")
        }

        // Rebinding the same window within one epoch still requires a new generation.
        expect(state.bindCandidate(a, interaction: first), "same epoch can bind consumed candidate")
        expect(state.confirmDrag(a, interaction: first), "same epoch can confirm next placement")
        guard let next = state.beginPlacement(for: a, interaction: first) else {
            expect(false, "same epoch creates next token")
            return
        }
        expect(next.generation > token.generation && next.interaction == token.interaction, "generation distinguishes same-window same-epoch placement")
        expect(!state.isCurrent(token) && state.isCurrent(next), "new generation invalidates old token")
        expect(!state.finishPlacement(token) && state.isCurrent(next), "old finish leaves newer generation active")
        expect(state.finishPlacement(next), "current token finishes")
        expect(!state.isCurrent(next) && !state.finishPlacement(next), "finished token stays invalid")

        guard let cancelled = startPlacement(&state, window: a) else { return }
        expect(cancelled.generation > next.generation, "generation does not reset across interactions")
        state.cancelInteraction(cancelled.interaction)
        expect(!state.isCurrent(cancelled), "cancel invalidates current token")
        expect(state.candidate == nil && !state.dragConfirmed, "cancel clears candidate and confirmation")

        guard let old = startPlacement(&state, window: a) else { return }
        let current = state.beginInteraction()
        expect(current > old.interaction && !state.isCurrentInteraction(old.interaction), "new epoch replaces old interaction")
        expect(!state.isCurrent(old) && state.candidate == nil && !state.dragConfirmed, "new epoch clears active placement and drag state")
        expect(state.bindCandidate(b, interaction: current), "new interaction binds another window")
        expect(state.confirmDrag(b, interaction: current), "new interaction confirms another window")
        state.cancelInteraction(old.interaction)
        expect(!state.finishPlacement(old), "old finish rejected during new candidate phase")
        expect(!state.bindCandidate(a, interaction: old.interaction), "old bind cannot overwrite new candidate")
        expect(!state.confirmDrag(a, interaction: old.interaction), "old confirmation cannot affect new interaction")
        expect(state.beginPlacement(for: a, interaction: old.interaction) == nil, "old interaction cannot place over new candidate")
        expect(state.candidate == b && state.dragConfirmed, "old callbacks preserve new candidate and confirmation")
        guard let active = state.beginPlacement(for: b, interaction: current) else {
            expect(false, "new candidate survives stale callbacks")
            return
        }
        state.cancelInteraction(old.interaction)
        expect(!state.finishPlacement(old) && state.isCurrent(active), "old cancel and finish preserve new active token")
        let empty = state.beginInteraction()
        expect(!state.isCurrent(active), "begin interaction immediately invalidates placement")
        expect(state.bindCandidate(a, interaction: empty), "candidate binds before cancellation")
        expect(state.confirmDrag(a, interaction: empty), "candidate confirms before cancellation")
        state.cancelInteraction(empty)
        expect(state.candidate == nil && !state.dragConfirmed, "cancel also clears pending confirmed candidate")
        expect(state.beginPlacement(for: a, interaction: empty) == nil, "cancelled candidate cannot start placement")
    }

    static func testInterruptedCallbacks() {
        let a = WindowIdentity(rawValue: 10)
        let b = WindowIdentity(rawValue: 11)
        let target = CGRect(x: 20, y: 30, width: 640, height: 1000)
        for phase in CallbackPhase.allCases {
            var state = WindowInteractionState()
            var effects = CallbackEffects()
            guard let old = startPlacement(&state, window: a) else { return }
            PlacementCallback(token: old, target: target, phase: .initial).run(state: state, effects: &effects)
            let callback = PlacementCallback(token: old, target: target.offsetBy(dx: 99, dy: 99), phase: phase)
            let snapshot = effects
            let interaction = state.beginInteraction()
            callback.run(state: state, effects: &effects)
            expect(effects == snapshot, "new interaction gates old \(phase) before candidate selection")
            expect(state.bindCandidate(b, interaction: interaction), "interruption binds new window")
            expect(state.confirmDrag(b, interaction: interaction), "interruption confirms new window")
            guard let current = state.beginPlacement(for: b, interaction: interaction) else {
                expect(false, "interruption starts new placement")
                return
            }
            for currentPhase in CallbackPhase.allCases {
                PlacementCallback(token: current, target: target, phase: currentPhase).run(state: state, effects: &effects)
            }
            expect(effects.writes == 3 && effects.samples == 1 && effects.prompts == 1, "current callback phases pass the production gate")
            let newSnapshot = effects
            callback.run(state: state, effects: &effects)
            state.cancelInteraction(old.interaction)
            expect(!state.finishPlacement(old), "old callback completion cannot finish new placement")
            expect(state.isCurrent(current) && effects == newSnapshot, "old \(phase) cannot write, sample, prompt or alter prior snapshots")
            expect(effects.frames[a] == snapshot.frames[a], "interrupted callback preserves earlier window snapshot")
        }

        // Rapid redrag of the same window must not revive any previous generation.
        var state = WindowInteractionState()
        var effects = CallbackEffects()
        guard let old = startPlacement(&state, window: a),
              let current = startPlacement(&state, window: a) else { return }
        expect(current.generation > old.generation && !state.isCurrent(old), "rapid same-window redrag invalidates old generation")
        PlacementCallback(token: current, target: target, phase: .initial).run(state: state, effects: &effects)
        let snapshot = effects
        for phase in CallbackPhase.allCases {
            PlacementCallback(token: old, target: .zero, phase: phase).run(state: state, effects: &effects)
        }
        expect(effects == snapshot, "same-window old generation cannot modify current snapshot")
        expect(state.finishPlacement(current), "redrag placement finishes")
        for phase in CallbackPhase.allCases {
            PlacementCallback(token: current, target: .zero, phase: phase).run(state: state, effects: &effects)
        }
        expect(effects == snapshot, "finished token cannot write, sample or prompt")
        guard let cancelled = startPlacement(&state, window: a) else { return }
        state.cancelInteraction(cancelled.interaction)
        for phase in CallbackPhase.allCases {
            PlacementCallback(token: cancelled, target: .zero, phase: phase).run(state: state, effects: &effects)
        }
        expect(effects == snapshot, "cancelled token cannot write, sample or prompt")
    }

    static func testSequentialColumnPlacements() {
        // These fixture windows deliberately share a PID but have distinct identities.
        // This checks state isolation only; it does not validate the AX identity registry.
        let windows = [
            (pid: 42, identity: WindowIdentity(rawValue: 101)),
            (pid: 42, identity: WindowIdentity(rawValue: 102)),
            (pid: 42, identity: WindowIdentity(rawValue: 103))
        ]
        expect(Set(windows.map(\.pid)).count == 1 && Set(windows.map(\.identity)).count == 3, "same-PID fixture uses distinct window identities")
        let screen = CGRect(x: 0, y: 25, width: 5120, height: 1415)
        for count in 4...8 {
            for column in 0..<count {
                var state = WindowInteractionState()
                var effects = CallbackEffects()
                var oldCallbacks: [PlacementCallback] = []
                var previousTokens: [WindowPlacementToken] = []
                var expectedFrames: [WindowIdentity: CGRect] = [:]
                for (windowOffset, fixture) in windows.enumerated() {
                    let action = WindowAction.column(index: (column + windowOffset) % count, count: count)!
                    let target = LayoutEngine.frame(for: action, in: screen, current: .zero)!
                    expectedFrames[fixture.identity] = target
                    guard let token = startPlacement(&state, window: fixture.identity) else { return }
                    expect(previousTokens.allSatisfy { !state.isCurrent($0) }, "\(count)-column \(column): A/B/C invalidate all earlier tokens")
                    expect(previousTokens.allSatisfy { $0.generation < token.generation }, "\(count)-column \(column): generations increase across A/B/C")
                    let beforeCurrent = effects
                    for callback in oldCallbacks {
                        callback.run(state: state, effects: &effects)
                    }
                    expect(effects == beforeCurrent, "\(count)-column \(column): earlier callbacks preserve prior window snapshots")
                    PlacementCallback(token: token, target: target, phase: .initial).run(state: state, effects: &effects)
                    PlacementCallback(token: token, target: target, phase: .retry).run(state: state, effects: &effects)
                    PlacementCallback(token: token, target: target, phase: .stable).run(state: state, effects: &effects)
                    let afterCurrent = effects
                    for callback in oldCallbacks {
                        callback.run(state: state, effects: &effects)
                    }
                    expect(effects == afterCurrent, "\(count)-column \(column): stale writes and prompts cannot alter new snapshot")
                    for phase in CallbackPhase.allCases {
                        oldCallbacks.append(PlacementCallback(token: token, target: .zero, phase: phase))
                    }
                    previousTokens.append(token)
                }
                expect(effects.frames.count == 3, "\(count)-column \(column): A/B/C each retain a snapshot")
                for fixture in windows {
                    expect(effects.frames[fixture.identity] == expectedFrames[fixture.identity], "\(count)-column \(column): window \(fixture.identity.rawValue) retains its own exact column rectangle")
                }
                expect(effects.writes == 6 && effects.samples == 3 && effects.prompts == 0, "\(count)-column \(column): only current writes and samples execute, no stale prompts")
            }
        }
    }

    static func testDragMotion() {
        let origin = CGPoint(x: 140, y: 110)
        let current = CGPoint(x: 240, y: 170)
        let mouseDownFrame = CGRect(x: 100, y: 80, width: 600, height: 400)
        let actual = mouseDownFrame.offsetBy(dx: 100, dy: 60)
        expect(WindowDragMotion.confirms(origin: origin, current: current, initial: mouseDownFrame, actual: actual), "same-direction mouse and window movement confirms drag")
        expect(!WindowDragMotion.confirms(origin: origin, current: origin, initial: mouseDownFrame, actual: mouseDownFrame), "stationary mouse and window do not confirm drag")
        expect(!WindowDragMotion.confirms(origin: origin, current: origin, initial: mouseDownFrame, actual: actual), "window movement without mouse movement does not confirm drag")
        expect(!WindowDragMotion.confirms(origin: origin, current: current, initial: mouseDownFrame, actual: mouseDownFrame), "moving mouse over wrongly selected stationary window does not confirm drag")
        expect(!WindowDragMotion.confirms(origin: origin, current: current, initial: mouseDownFrame, actual: mouseDownFrame.offsetBy(dx: -100, dy: -60)), "opposite-direction window movement does not confirm drag")
        expect(!WindowDragMotion.confirms(origin: origin, current: current, initial: mouseDownFrame, actual: mouseDownFrame.offsetBy(dx: 100, dy: -60)), "mismatched vertical direction does not confirm drag")
        var resized = actual
        resized.size.width += 3
        expect(!WindowDragMotion.confirms(origin: origin, current: current, initial: mouseDownFrame, actual: resized), "width resize is not a drag")
        resized = actual
        resized.size.height -= 3
        expect(!WindowDragMotion.confirms(origin: origin, current: current, initial: mouseDownFrame, actual: resized), "height resize is not a drag")
        let resizeOnly = CGRect(origin: mouseDownFrame.origin, size: CGSize(width: 700, height: 460))
        expect(!WindowDragMotion.confirms(origin: origin, current: current, initial: mouseDownFrame, actual: resizeOnly), "resize without window translation does not confirm drag")

        // A delayed AX candidate sample may already have moved. The baseline must
        // remain the mouse-down frame rather than that later candidate sample.
        let delayedCandidateFrame = mouseDownFrame.offsetBy(dx: 40, dy: 30)
        expect(delayedCandidateFrame != mouseDownFrame, "delayed candidate fixture differs from mouse-down frame")
        expect(WindowDragMotion.confirms(origin: origin, current: current, initial: mouseDownFrame, actual: actual), "mouse-down frame correctly confirms after delayed candidate resolution")
        expect(!WindowDragMotion.confirms(origin: origin, current: current, initial: delayedCandidateFrame, actual: actual), "late frame baseline loses earlier motion and fails correlation")
        expect(!WindowDragMotion.confirms(origin: origin, current: current, initial: actual, actual: actual), "candidate sampled at final frame cannot replace mouse-down baseline")

        let twoPointMouse = CGPoint(x: origin.x + 2, y: origin.y)
        expect(!WindowDragMotion.confirms(origin: origin, current: twoPointMouse, initial: mouseDownFrame, actual: mouseDownFrame.offsetBy(dx: 2, dy: 0)), "exactly two points does not cross motion threshold")
        expect(!WindowDragMotion.confirms(origin: origin, current: current, initial: mouseDownFrame, actual: mouseDownFrame.offsetBy(dx: 2, dy: 0)), "window must independently cross motion threshold")
        let toleranceFrame = CGRect(x: actual.minX + 24, y: actual.minY - 24, width: actual.width + 2, height: actual.height - 2)
        expect(WindowDragMotion.confirms(origin: origin, current: current, initial: mouseDownFrame, actual: toleranceFrame), "axis and size tolerance boundaries are inclusive")
        expect(!WindowDragMotion.confirms(origin: origin, current: current, initial: mouseDownFrame, actual: actual.offsetBy(dx: 25, dy: 0)), "horizontal correlation beyond tolerance is rejected")
        expect(!WindowDragMotion.confirms(origin: origin, current: current, initial: mouseDownFrame, actual: actual.offsetBy(dx: 0, dy: 25)), "vertical correlation beyond tolerance is rejected")
    }

    @MainActor
    static func main() {
        testPhysicalWindowEvidence()
        testProductionPlacementRunner()
        testDragMotion()
        testInteractionState()
        testInterruptedCallbacks()
        testSequentialColumnPlacements()
        expect(LayoutEngine.acceptsOptionRelease(elapsed: 0.1, origin: .zero, current: CGPoint(x: 3, y: 4)), "release tolerates small motion")
        expect(!LayoutEngine.acceptsOptionRelease(elapsed: 0.16, origin: .zero, current: .zero), "release timeout cancels")
        expect(!LayoutEngine.acceptsOptionRelease(elapsed: 0.1, origin: .zero, current: CGPoint(x: 13, y: 0)), "intentional movement cancels")
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
        let configurableShortcuts = WindowAction.allCases.filter(\.isShortcutConfigurable)
        expect(configurableShortcuts == [.leftThird, .centerThird, .rightThird, .four1, .four2, .four3, .four4], "only 3- and 4-column shortcuts are configurable")
        expect(!WindowAction.five1.isShortcutConfigurable, "5-column shortcuts stay disabled")

        let exactTarget = CGRect(x: 640, y: 74, width: 640, height: 1336)
        // Every slot must grow a small window and shrink a large one to the same rectangle.
        for count in 4...8 {
            for index in 0..<count {
                let action = WindowAction.column(index: index, count: count)!
                let small = CGRect(x: 100, y: 100, width: 200, height: 200)
                let large = CGRect(x: 0, y: 0, width: 4000, height: 1400)
                let expected = LayoutEngine.frame(for: action, in: ultrawide, current: small)!
                expect(LayoutEngine.frame(for: action, in: ultrawide, current: large) == expected, "slot independent of original size")
                expect(!LayoutEngine.placementFits(target: expected, actual: CGRect(origin: expected.origin, size: small.size)), "position-only placement rejected")
                expect(LayoutEngine.placementDecision(target: expected, actual: large, attempt: 1, maximumAttempts: 8) == .retry, "rebound retries")
            }
        }
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
