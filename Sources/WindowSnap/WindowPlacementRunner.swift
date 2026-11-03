import CoreGraphics

// The AX adapter and deterministic tests drive this same retry/verification loop.
@MainActor
final class WindowPlacementRunner {
    enum Issue { case verificationFailed, placementRejected }
    typealias Schedule = (Double, @escaping @MainActor () -> Void) -> Void

    private let isCurrent: () -> Bool
    private let canPlace: () -> Bool
    private let write: (CGRect) -> Void
    private let read: () -> CGRect?
    private let finish: () -> Void
    private let report: (Issue) -> Void
    private let sample: (Int, Int, CGRect) -> Void
    private let schedule: Schedule
    private let retryDelays = [0.08, 0.10, 0.14, 0.18, 0.24, 0.32, 0.42, 0.55]

    init(
        isCurrent: @escaping () -> Bool,
        canPlace: @escaping () -> Bool,
        write: @escaping (CGRect) -> Void,
        read: @escaping () -> CGRect?,
        finish: @escaping () -> Void,
        report: @escaping (Issue) -> Void,
        sample: @escaping (Int, Int, CGRect) -> Void = { _, _, _ in },
        schedule: @escaping Schedule
    ) {
        self.isCurrent = isCurrent
        self.canPlace = canPlace
        self.write = write
        self.read = read
        self.finish = finish
        self.report = report
        self.sample = sample
        self.schedule = schedule
    }

    func start(target: CGRect, initialDelay: Double) {
        schedule(initialDelay) { self.attempt(target: target, index: 0, stableSamples: 0) }
    }

    private func attempt(target: CGRect, index: Int, stableSamples: Int) {
        guard isCurrent() else { return }
        guard canPlace() else { finish(); return }
        guard isCurrent() else { return }
        if stableSamples == 0 { write(target) }
        let delay = stableSamples > 0 ? 0.25 : retryDelays[min(index, retryDelays.count - 1)]
        schedule(delay) {
            guard self.isCurrent() else { return }
            guard let actual = self.read() else {
                if index + 1 < self.retryDelays.count {
                    self.attempt(target: target, index: index + 1, stableSamples: 0)
                } else {
                    self.complete(issue: .verificationFailed)
                }
                return
            }
            guard self.isCurrent() else { return }
            self.sample(index, stableSamples, actual)
            switch LayoutEngine.placementDecision(target: target, actual: actual, attempt: index,
                                                   maximumAttempts: self.retryDelays.count) {
            case .succeeded:
                if stableSamples >= 3 { self.complete() }
                else { self.attempt(target: target, index: index, stableSamples: stableSamples + 1) }
            case .retry:
                self.attempt(target: target, index: index + 1, stableSamples: 0)
            case .exhausted:
                self.complete(issue: .placementRejected)
            }
        }
    }

    private func complete(issue: Issue? = nil) {
        guard isCurrent() else { return }
        // Reporting is synchronous. Invalidate first so modal UI cannot revive the task.
        finish()
        if let issue { report(issue) }
    }
}
