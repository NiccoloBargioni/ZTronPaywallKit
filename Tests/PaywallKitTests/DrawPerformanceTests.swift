import Foundation
import PaywallCore
import PaywallTesting
import XCTest

@testable import PaywallKit

/// Concurrency requirement 7: the draw path's `write(2)` plus `F_FULLFSYNC` is the only disk I/O on the main actor,
/// and a performance test bounds it. The bound is 25 ms per draw; the design states it for a device, and the
/// simulator and CI lanes hold it against the host's SSD. XCTest, because `measure` lives there.
final class DrawPerformanceTests: XCTestCase {
    static let bound: TimeInterval = 0.025

    @MainActor
    private func makeEngine(fullSync: Bool) async throws -> GateEngine {
        let engine = try GateEngine(
            directory: makeTemporaryPaywallDirectory(), catalog: catalog,
            settings: GateEngine.Settings(fullSync: fullSync), clock: FakeClock(), store: FakeStore(products: products))
        await engine.start()
        engine.grant(tokens: 100_000, reason: "perf")
        return engine
    }

    /// Every iteration uses a new gate id, so each one is a real draw: decide, frame, `write(2)`, `F_FULLFSYNC`.
    @MainActor
    func test_draw_with_full_sync_stays_under_25ms() async throws {
        let engine = try await makeEngine(fullSync: true)
        var durations: [TimeInterval] = []
        for n in 0..<60 {
            let started = ProcessInfo.processInfo.systemUptime
            _ = engine.run(.tokens(1), source: PaywallSource(id: "perf.\(n)", fileID: "perf", function: "t", line: n)) {}
            durations.append(ProcessInfo.processInfo.systemUptime - started)
        }
        let sorted = durations.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let median = sorted[sorted.count / 2]
        print("draw: median \(Int(median * 1_000_000)) µs, p95 \(Int(p95 * 1_000_000)) µs, max \(Int(sorted.last! * 1_000_000)) µs")
        XCTAssertLessThan(median, Self.bound, "median draw above the bound")
        XCTAssertLessThan(p95, Self.bound, "p95 draw above the bound (max \(sorted.last!))")
        XCTAssertEqual(engine.wallet.balance, 100_000 - 60)
    }

    /// The same path with `fsync` only, the design's latency trade-off, for comparison in the log.
    @MainActor
    func test_draw_with_fsync_only_is_measured() async throws {
        let engine = try await makeEngine(fullSync: false)
        var counter = 0
        measure(metrics: [XCTClockMetric()]) {
            counter += 1
            _ = engine.run(.tokens(1), source: PaywallSource(id: "perf.fsync.\(counter)", fileID: "perf", function: "t", line: counter)) {}
        }
        XCTAssertGreaterThan(counter, 0)
    }

    /// A long history must not slow the draw: the derivations are maintained as events arrive, so 20k events cost a
    /// draw the same as none. Seeds the journal directly, opens the engine on it (the launch path), lets `start()`
    /// checkpoint it, opens a second engine on the checkpoint, and measures real draws with `F_FULLFSYNC` against the
    /// same bound. The two init times and the two log sizes go to the log: what the checkpoint buys a launch.
    @MainActor
    func test_draw_bound_holds_on_a_long_history() async throws {
        let directory = makeTemporaryPaywallDirectory()
        let device = "perf-device"
        try Data(device.utf8).write(to: directory.appendingPathComponent("device.id"))
        let journal = try Journal(directory: directory)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func event(_ id: String, at: Date, source: PaywallSource?, kind: LedgerEvent.Kind) -> JournalEntry {
            .event(
                LedgerEvent(id: id, at: at, deviceID: device, accountKey: unboundAccountKey, source: source, previousHash: paywallGenesisHash, kind: kind),
                uploaded: true)
        }
        var entries = [event("grant:seed", at: base, source: nil, kind: .grant(tokens: 1_000_000, reason: "seed"))]
        for i in 1..<20_000 {
            let at = base.addingTimeInterval(Double(i))
            if i % 7 == 0 {
                entries.append(event("extend:\(i)", at: at, source: nil, kind: .leaseExtended(debitID: "debit:\(i - 1)", until: at.addingTimeInterval(300))))
            } else {
                let source = PaywallSource(id: "gate.\(i % 50)", fileID: "perf", function: "t", line: i % 50)
                entries.append(event("debit:\(i)", at: at, source: source, kind: .debit(tokens: 1, leaseUntil: at.addingTimeInterval(300))))
            }
            if entries.count == 5_000 {
                try journal.append(contentsOf: entries)
                entries = []
            }
        }
        try journal.append(contentsOf: entries)
        let log = directory.appendingPathComponent(Journal.fileName)
        func logSize() throws -> Int { try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int ?? 0 }
        let fullSize = try logSize()

        let opened = ProcessInfo.processInfo.systemUptime
        let first = try GateEngine(
            directory: directory, catalog: catalog, settings: GateEngine.Settings(fullSync: true), clock: FakeClock(),
            store: FakeStore(products: products))
        let fullReplay = ProcessInfo.processInfo.systemUptime - opened
        print("long history: engine init \(Int(fullReplay * 1_000)) ms for \(first.ledger.events.count) events, ledger.log \(fullSize / 1024) KB")
        await first.start()
        XCTAssertEqual(first.ledger.events.count, 20_000)
        XCTAssertEqual(first.ledger.leases(for: first.accountKey).count, 50)
        first.shutdown()
        // `start()` found 20k events behind no checkpoint: it wrote one and dropped every event it covers.
        let checkpointSize = try logSize()
        XCTAssertLessThan(checkpointSize, fullSize / 2, "the checkpoint should be far smaller than the events it stands for")

        let reopened = ProcessInfo.processInfo.systemUptime
        let engine = try GateEngine(
            directory: directory, catalog: catalog, settings: GateEngine.Settings(fullSync: true), clock: FakeClock(),
            store: FakeStore(products: products))
        let checkpointReplay = ProcessInfo.processInfo.systemUptime - reopened
        print("long history: engine init \(Int(checkpointReplay * 1_000)) ms from the checkpoint, ledger.log \(checkpointSize / 1024) KB")
        XCTAssertTrue(engine.ledger.events.isEmpty, "nothing to replay after the checkpoint")
        XCTAssertTrue(engine.ledger.contains("debit:1") && engine.ledger.contains("grant:seed"))
        XCTAssertEqual(engine.ledger.leases(for: engine.accountKey).count, 50)
        XCTAssertEqual(engine.ledger.leases(for: engine.accountKey), first.ledger.leases(for: first.accountKey))
        XCTAssertEqual(engine.ledger.balance(for: engine.accountKey), 1_000_000 - 17_142)
        XCTAssertEqual(engine.ledger.head(for: device), first.ledger.head(for: device))
        XCTAssertLessThan(checkpointReplay, fullReplay, "the checkpoint should make the launch faster than the full replay")
        await engine.start()

        // The derivations every draw pays: constant, not proportional to the history.
        let derived = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 {
            _ = engine.ledger.leases(for: engine.accountKey)
            _ = engine.ledger.balance(for: engine.accountKey)
        }
        XCTAssertLessThan((ProcessInfo.processInfo.systemUptime - derived) / 100, 0.001, "leases + balance above 1 ms on 20k events")

        var durations: [TimeInterval] = []
        for n in 0..<60 {
            let started = ProcessInfo.processInfo.systemUptime
            _ = engine.run(.tokens(1), source: PaywallSource(id: "fresh.\(n)", fileID: "perf", function: "t", line: n)) {}
            durations.append(ProcessInfo.processInfo.systemUptime - started)
        }
        let sorted = durations.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        print("draw on 20k events: median \(Int(sorted[30] * 1_000_000)) µs, p95 \(Int(p95 * 1_000_000)) µs, max \(Int(sorted.last! * 1_000_000)) µs")
        XCTAssertLessThan(sorted[30], Self.bound, "median draw above the bound on a long history")
        XCTAssertLessThan(p95, Self.bound, "p95 draw above the bound on a long history")
        XCTAssertEqual(engine.wallet.balance, 1_000_000 - 17_142 - 60)
        XCTAssertEqual(engine.ledger.events.count, 60)
        engine.shutdown()
    }

    /// A lease hit must cost no I/O at all: it is the common case inside the S window. The journal does not grow,
    /// and the call stays far below one draw (the loose bound keeps the sanitizer lane honest, not fast).
    @MainActor
    func test_leased_re_entry_costs_no_io() async throws {
        let engine = try await makeEngine(fullSync: true)
        _ = engine.run(.tokens(1), source: PaywallSource(id: "leased", fileID: "perf", function: "t", line: 1)) {}
        let journal = engine.directory.appendingPathComponent(Journal.fileName)
        let sizeBefore = try FileManager.default.attributesOfItem(atPath: journal.path)[.size] as? Int
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1_000 {
            _ = engine.run(.tokens(1), source: PaywallSource(id: "leased", fileID: "perf", function: "t", line: 1)) {}
        }
        let perCall = (ProcessInfo.processInfo.systemUptime - started) / 1_000
        print("leased re-entry: \(Int(perCall * 1_000_000)) µs per call")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: journal.path)[.size] as? Int, sizeBefore, "a leased re-entry wrote to the journal")
        XCTAssertLessThan(perCall, Self.bound / 2)
        XCTAssertEqual(engine.wallet.balance, 100_000 - 1)
    }
}
