#if DEBUG
    public import Foundation
    public import PaywallCore

    /// A clock that moves only when told to. Sleepers wake when `advance` passes their deadline.
    @MainActor
    public final class FakeClock: PaywallClock {
        public private(set) var now: Date
        public private(set) var uptime: TimeInterval
        private var sleepers: [(id: UUID, until: Date, continuation: CheckedContinuation<Void, any Error>)] = []

        public init(now: Date = Date(timeIntervalSince1970: 1_800_000_000), uptime: TimeInterval = 1_000) {
            self.now = now
            self.uptime = uptime
        }

        /// Moves wall clock and uptime forward and wakes every sleeper whose deadline passed.
        public func advance(by seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
            uptime += max(0, seconds)
            wakeDueSleepers()
        }

        /// Moves the wall clock only (the user changed the time); uptime keeps counting forward.
        public func setWallClock(_ date: Date) {
            now = date
            wakeDueSleepers()
        }

        private func wakeDueSleepers() {
            let due = sleepers.filter { $0.until <= now }
            sleepers.removeAll { $0.until <= now }
            for sleeper in due { sleeper.continuation.resume() }
        }

        public var pendingSleepers: Int { sleepers.count }

        public func sleep(until date: Date) async throws {
            if date <= now { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    self.enqueue(id: id, until: date, continuation: continuation)
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelSleeper(id) }
            }
        }

        private func enqueue(id: UUID, until date: Date, continuation: CheckedContinuation<Void, any Error>) {
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                sleepers.append((id: id, until: date, continuation: continuation))
            }
        }

        private func cancelSleeper(_ id: UUID) {
            guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
            sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }
#endif
