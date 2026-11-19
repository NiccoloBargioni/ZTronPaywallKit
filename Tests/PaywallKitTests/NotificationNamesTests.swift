import Combine
import Foundation
import PaywallCore
import PaywallTesting
import Testing

@testable import PaywallKit

/// The dedicated notification names: one per paywall and purchase event, with the payload in `userInfo`, posted
/// next to the generic `.paywallEvent`.
@Suite("Notification names", .serialized)
@MainActor
struct NotificationNamesTests {
    /// What a dedicated notification carried, copied on the posting thread (a `Notification` is not `Sendable`).
    private struct Posted: Sendable {
        let name: Notification.Name
        let event: PaywallEvent?
        let failure: PaywallFailure?
        let productID: String?
        let source: PaywallSource?
        let transactionID: UInt64?
        let error: String?
        let entitlement: Entitlement?
        let previousEntitlement: Entitlement?
        let cause: EntitlementChangeCause?

        init(_ note: Notification) {
            let info = note.userInfo
            name = note.name
            event = info?[PaywallNotificationKey.event] as? PaywallEvent
            failure = info?[PaywallNotificationKey.failure] as? PaywallFailure
            productID = info?[PaywallNotificationKey.productID] as? String
            source = info?[PaywallNotificationKey.source] as? PaywallSource
            transactionID = info?[PaywallNotificationKey.transactionID] as? UInt64
            error = info?[PaywallNotificationKey.error] as? String
            entitlement = info?[PaywallNotificationKey.entitlement] as? Entitlement
            previousEntitlement = info?[PaywallNotificationKey.previousEntitlement] as? Entitlement
            cause = info?[PaywallNotificationKey.cause] as? EntitlementChangeCause
        }
    }

    @MainActor
    private final class Recorder {
        var posted: [Posted] = []
        var generic = 0
    }

    private static let dedicated: [Notification.Name] = [
        .paywallDenied, .paywallEntitlementChanged,
        .paywallPurchaseStarted, .paywallPurchaseCompleted, .paywallPurchasePending, .paywallPurchaseCancelled,
        .paywallPurchaseFailed, .paywallRestoreRequested, .paywallRestoreCompleted, .paywallRestoreFailed,
        .paywallPurchaseIntent,
    ]

    /// Observes the dedicated names and counts the generic one. Returns the tokens to remove at the end.
    private func observe(_ center: NotificationCenter, into recorder: Recorder) -> [any NSObjectProtocol] {
        var observers = Self.dedicated.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { note in
                let posted = Posted(note)
                MainActor.assumeIsolated { recorder.posted.append(posted) }
            }
        }
        observers.append(center.addObserver(forName: .paywallEvent, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { recorder.generic += 1 }
        })
        return observers
    }

    @Test func dedicated_names_carry_their_payload() async throws {
        let (paywall, store, _) = await makePaywall()
        let center = NotificationCenter()
        let recorder = Recorder()
        let observers = observe(center, into: recorder)
        let bridge = paywall.bridgeToNotificationCenter(center)
        defer {
            bridge.cancel()
            for observer in observers { center.removeObserver(observer) }
        }
        func since(_ count: Int) -> [Posted] { Array(recorder.posted.dropFirst(count)) }

        // A denial carries the failure; a token grant has no dedicated name.
        let failure = try #require(paywall.evaluate(.paid, id: "pro").failure)
        #expect(recorder.posted.map(\.name) == [.paywallDenied])
        #expect(recorder.posted.last?.failure == failure)
        #expect(recorder.posted.last?.event == .gateDenied(failure))
        paywall.grant(tokens: 1, reason: "welcome")
        #expect(recorder.posted.count == 1)

        // A pack: started and completed, with the source on both and the transaction id on completed only.
        var mark = recorder.posted.count
        let listed = try await paywall.products()
        let pack = try #require(listed.first { $0.id == "tokens.10" })
        let source = PaywallSource(id: "export", fileID: "f", function: "g", line: 1)
        guard case .purchased(let transactionID) = try await paywall.purchase(pack, source: source) else {
            Issue.record("expected a purchase")
            return
        }
        var notes = since(mark)
        #expect(notes.map(\.name) == [.paywallPurchaseStarted, .paywallPurchaseCompleted])
        #expect(notes.first?.productID == "tokens.10")
        #expect(notes.first?.source == source)
        #expect(notes.first?.transactionID == nil)
        #expect(notes.last?.transactionID == transactionID)

        // Lifetime, without a source: the entitlement changes between started and completed.
        mark = recorder.posted.count
        guard case .purchased(let lifetimeID) = try await paywall.purchase(products[3]) else {
            Issue.record("expected a purchase")
            return
        }
        notes = since(mark)
        #expect(notes.map(\.name) == [.paywallPurchaseStarted, .paywallEntitlementChanged, .paywallPurchaseCompleted])
        #expect(notes.first?.source == nil)
        let changed = try #require(notes.count == 3 ? notes[1] : nil)
        #expect(changed.previousEntitlement == .free)
        #expect(changed.entitlement == .lifetime(.purchase(transactionID: lifetimeID)))
        #expect(changed.cause == .purchase)

        // Pending, cancelled and failed each end their own way; failed carries the store's error.
        mark = recorder.posted.count
        await store.setNextPurchase(.pending)
        _ = try await paywall.purchase(pack)
        await store.setNextPurchase(.cancel)
        _ = try await paywall.purchase(pack)
        await store.setNextPurchase(.fail)
        await #expect(throws: FakeStore.Failure.purchaseFailed) { _ = try await paywall.purchase(pack) }
        notes = since(mark)
        #expect(notes.map(\.name) == [
            .paywallPurchaseStarted, .paywallPurchasePending,
            .paywallPurchaseStarted, .paywallPurchaseCancelled,
            .paywallPurchaseStarted, .paywallPurchaseFailed,
        ])
        #expect(notes.last?.error == String(describing: FakeStore.Failure.purchaseFailed))

        // Restore: requested then completed; without a network, requested then failed with the error.
        mark = recorder.posted.count
        try await paywall.restorePurchases()
        await store.setNetwork(false)
        await #expect(throws: FakeStore.Failure.network) { try await paywall.restorePurchases() }
        notes = since(mark)
        #expect(notes.map(\.name) == [.paywallRestoreRequested, .paywallRestoreCompleted, .paywallRestoreRequested, .paywallRestoreFailed])
        #expect(notes.last?.error == String(describing: FakeStore.Failure.network))

        // A promoted product tapped on the App Store.
        mark = recorder.posted.count
        await store.deliverPurchaseIntent(productID: "pro.yearly")
        for _ in 0..<50 where paywall.pendingPurchaseIntent == nil { await settle() }
        notes = since(mark)
        #expect(notes.map(\.name) == [.paywallPurchaseIntent])
        #expect(notes.last?.productID == "pro.yearly")

        // Every event went out under the generic name too, dedicated or not.
        #expect(recorder.generic > recorder.posted.count)
    }

    @Test func the_configuration_keeps_a_bridge_for_the_facade_lifetime() async {
        let center = NotificationCenter()
        let recorder = Recorder()
        let observers = observe(center, into: recorder)
        defer { for observer in observers { center.removeObserver(observer) } }
        let paywall = Paywall()
        var configuration = Paywall.Configuration(catalog: catalog)
        configuration.fileKeyStore = InMemoryFileKeyStore()
        configuration.store = FakeStore(products: products)
        configuration.clock = FakeClock()
        configuration.storageDirectory = makeTemporaryPaywallDirectory()
        configuration.includesDefaultAudit = false
        configuration.connectivity = nil
        configuration.notificationCenter = center
        paywall.configure(configuration)
        await paywall.waitUntilStarted()
        _ = paywall.evaluate(.paid, id: "pro")
        // Live from the launch resolution on: the entitlement change came before the denial.
        #expect(recorder.posted.map(\.name) == [.paywallEntitlementChanged, .paywallDenied])
        #expect(recorder.generic > 0)
        // Reconfigured without a center, the bridge is gone.
        let generic = recorder.generic
        configuration.notificationCenter = nil
        paywall.configure(configuration)
        await paywall.waitUntilStarted()
        _ = paywall.evaluate(.paid, id: "pro")
        #expect(recorder.posted.count == 2)
        #expect(recorder.generic == generic)
    }
}
