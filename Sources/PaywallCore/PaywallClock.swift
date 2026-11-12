public import Foundation

/// Wall clock, monotonic uptime and sleeping, injectable so leases and expiry run in tests without waiting.
/// Main-actor isolated because the engine that reads it is.
@MainActor
public protocol PaywallClock: AnyObject {
    var now: Date { get }
    /// Monotonic seconds, recorded next to `now` in every audit record to expose clock changes.
    var uptime: TimeInterval { get }
    /// Suspends until `date` (or returns at once if it passed). Throws `CancellationError` when cancelled.
    func sleep(until date: Date) async throws
}

@MainActor
public final class SystemClock: PaywallClock {
    public init() {}

    public var now: Date { Date() }

    public var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public func sleep(until date: Date) async throws {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(min(interval, 60 * 60 * 24 * 365) * 1_000_000_000))
    }
}
