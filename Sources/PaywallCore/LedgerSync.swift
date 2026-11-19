public import Foundation

/// What one pull brought back: the events past the cursor the engine asked from, the cursor to store once those events
/// are in the journal, and whether the carrier has an account to upload to at all.
public struct LedgerPull: Hashable, Sendable {
    public var events: [LedgerEvent]
    /// The carrier's position after `events`. The engine writes it with them, in one write, and passes it to the next
    /// `pull(since:)`; `nil` leaves the engine's cursor where it was.
    public var cursor: Data?
    /// `false` while the device has no account for the carrier (no iCloud account): the answer is final for now,
    /// nothing can be uploaded either, and the engine stops pushing until a pull says the account is back.
    public var accountAvailable: Bool

    public init(events: [LedgerEvent], cursor: Data? = nil, accountAvailable: Bool = true) {
        self.events = events
        self.cursor = cursor
        self.accountAvailable = accountAvailable
    }
}

/// The seam for cross-device and reinstall persistence: CloudKit plus the Keychain snapshot in
/// `ZTronPaywallCloudSync`, a server later. Carriers only add events, so no merge can remove a debit.
///
/// The engine owns the pull cursor: it stores the cursor a pull returns in `ledger.log` next to the merged events and
/// hands it to the next pull. A carrier keeps no position of its own, so a journal that lost events (a corrupt frame, a
/// reinstall) fetches them again from the cursor that survived, and a merge that failed fetches the same events again.
public protocol LedgerSync: Sendable {
    /// Uploads events and returns the ids the carrier now holds (already-present ids count as acknowledged).
    func push(_ events: [LedgerEvent]) async throws -> Set<String>
    /// Every event the carrier holds. The primitive a simple carrier implements; the engine calls `pull(since:)`.
    func pull() async throws -> [LedgerEvent]
    /// The events past `cursor` (every event for `nil`), with the cursor to store once they are durable. An answer,
    /// even an empty one, means the carrier has looked: the engine settles the Keychain baseline and the welcome grant
    /// on it, so the first pull, and the first after `requestPull()`, must really fetch. `nil` means the carrier chose
    /// not to look this time (its pull interval has not elapsed): nothing settles. A carrier that cannot look throws,
    /// and the engine waits for the next sync. The default pulls everything through `pull()` with no cursor.
    func pull(since cursor: Data?) async throws -> LedgerPull?
    /// The fast-path balance known after a reinstall, before the first pull.
    func loadSnapshot() async -> WalletSnapshot?
    func saveSnapshot(_ snapshot: WalletSnapshot) async
    /// The next `pull(since:)` should fetch even if the carrier's pull interval has not elapsed (after a purchase, a
    /// restore, a silent push, a merge that failed, or an engine's first sync).
    func requestPull() async
}

extension LedgerSync {
    public func pull(since cursor: Data?) async throws -> LedgerPull? { LedgerPull(events: try await pull()) }
    public func loadSnapshot() async -> WalletSnapshot? { nil }
    public func saveSnapshot(_ snapshot: WalletSnapshot) async {}
    public func requestPull() async {}
}
