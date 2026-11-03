import CoreGraphics

@MainActor
final class PlacementTestClock {
    var now = 0.0
    var queue: [(time: Double, order: Int, action: @MainActor () -> Void)] = []
    private var order = 0

    func schedule(_ delay: Double, _ action: @escaping @MainActor () -> Void) {
        order += 1
        queue.append((now + delay, order, action))
    }

    func step() {
        queue.sort { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        now = next.time
        next.action()
    }

    func drain() {
        var steps = 0
        while !queue.isEmpty && steps < 500 { step(); steps += 1 }
        LayoutEngineSelfTest.expect(queue.isEmpty, "placement queue terminates")
    }
}

@MainActor
final class PlacementTestHarness {
    let clock = PlacementTestClock()
    var state = WindowInteractionState()
    var frames: [WindowIdentity: CGRect] = [:]
    var writes: [WindowIdentity] = []
    var prompts = 0
    var writeCount = 0
    var rebound = false
    var missingReads = 0
    var rejects = false

    func start(_ window: WindowIdentity, target: CGRect) {
        let epoch = state.beginInteraction()
        _ = state.bindCandidate(window, interaction: epoch)
        _ = state.confirmDrag(window, interaction: epoch)
        let token = state.beginPlacement(for: window, interaction: epoch)!
        writeCount = 0
        let runner = WindowPlacementRunner(
            isCurrent: { self.state.isCurrent(token) }, canPlace: { true },
            write: { frame in
                self.writes.append(window)
                self.writeCount += 1
                if !self.rejects && self.writeCount > 1 { self.frames[window] = frame }
            },
            read: {
                if self.missingReads > 0 { self.missingReads -= 1; return nil }
                return self.frames[window]
            },
            finish: { self.state.finishPlacement(token) },
            report: { _ in self.prompts += 1 },
            sample: { _, stable, _ in
                if self.rebound && stable == 0 {
                    self.rebound = false
                    self.frames[window] = target.offsetBy(dx: 90, dy: 0)
                }
            },
            schedule: { self.clock.schedule($0, $1) }
        )
        runner.start(target: target, initialDelay: 0.12)
    }
}

extension LayoutEngineSelfTest {
    @MainActor
    static func testProductionPlacementRunner() {
        let screen = CGRect(x: 0, y: 74, width: 5120, height: 1336)
        var scenarios = 0
        for count in 4...8 {
            let forward = Array(0..<count)
            let reverse = Array(forward.reversed())
            let alternating = stride(from: 0, to: count, by: 2).map { $0 } + stride(from: 1, to: count, by: 2).map { $0 }
            let shuffled = Array(forward.dropFirst(count / 2)) + Array(forward.prefix(count / 2).reversed())
            for order in [forward, reverse, alternating, shuffled] {
                let test = PlacementTestHarness()
                var snapshots: [WindowIdentity: CGRect] = [:]
                for column in order {
                    let window = WindowIdentity(rawValue: column + 1)
                    test.frames[window] = CGRect(x: 150, y: 200, width: 1400, height: 700)
                    let action = WindowAction.column(index: column, count: count)!
                    let target = LayoutEngine.frame(for: action, in: screen, current: .zero)!
                    let previousWrites = test.writes.count
                    test.rebound = true
                    test.missingReads = 1
                    test.start(window, target: target)
                    while !test.clock.queue.isEmpty {
                        test.clock.step()
                        for (old, frame) in snapshots {
                            expect(test.frames[old] == frame, "\(count) columns \(order): previous window \(old.rawValue) frame unchanged")
                        }
                    }
                    expect(test.frames[window] == target, "\(count) columns \(order): current window reaches own slot")
                    expect(test.writes.dropFirst(previousWrites).allSatisfy { $0 == window }, "\(count) columns \(order): production runner writes only current identity")
                    expect(test.prompts == 0, "lag/rebound recovered without error")
                    snapshots[window] = target
                }
                scenarios += 1
            }
        }
        // Interrupt at initial delay, retry, and stability sampling. Execute every old closure.
        for steps in [0, 1, 2, 3, 4] {
            let test = PlacementTestHarness()
            let a = WindowIdentity(rawValue: 1), b = WindowIdentity(rawValue: 2)
            let target = CGRect(x: 0, y: 74, width: 1024, height: 1336)
            test.frames[a] = .zero
            test.frames[b] = .zero
            test.start(a, target: target)
            for _ in 0..<steps { test.clock.step() }
            let snapshot = test.frames[a]
            let before = test.writes.count
            test.start(b, target: target.offsetBy(dx: 1024, dy: 0))
            test.clock.drain()
            expect(test.frames[a] == snapshot, "interrupt stage \(steps): previous frame not rewritten")
            expect(test.writes.dropFirst(before).allSatisfy { $0 == b }, "interrupt stage \(steps): old runner cannot write")
            expect(test.prompts == 0, "interrupt stage \(steps): stale issues suppressed")
        }
        let failed = PlacementTestHarness()
        let id = WindowIdentity(rawValue: 7)
        failed.frames[id] = .zero
        failed.rejects = true
        failed.start(id, target: screen)
        failed.clock.drain()
        expect(failed.writes.count == 8 && failed.prompts == 1, "refused placement has finite retries and one issue")
        print("PASS: production placement runner, \(scenarios) complete forward/reverse/interleaved layout sequences plus interruption/failure cases")
    }
}
