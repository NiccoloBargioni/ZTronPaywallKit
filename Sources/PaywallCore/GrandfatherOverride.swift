#if DEBUG
    public import Foundation

    /// The debug-menu override for testing the grandfather branch on a device, which TestFlight and the sandbox
    /// cannot reach (the sandbox reports `1.0` as the original version). Compiled out of release builds, so the
    /// only inputs that can produce a paying entitlement in a shipped app stay StoreKit transactions and the
    /// AppTransaction or receipt.
    ///
    /// It replaces what the resolver sees and nothing else: the account key, and with it the wallet, still come
    /// from the real AppTransaction.
    public struct GrandfatherOverride: Hashable, Sendable {
        public var originalAppVersion: String
        public var originalPurchaseDate: Date
        /// Reported to the resolver; `.production` so the default policy admits it.
        public var environment: StoreEnvironment

        public init(originalAppVersion: String, originalPurchaseDate: Date, environment: StoreEnvironment = .production) {
            self.originalAppVersion = originalAppVersion
            self.originalPurchaseDate = originalPurchaseDate
            self.environment = environment
        }

        /// `snapshot` with the overridden fields, or a simulated snapshot when the store gave none.
        public func apply(to snapshot: AppTransactionSnapshot?, bundleID: String) -> AppTransactionSnapshot {
            var result = snapshot
                ?? AppTransactionSnapshot(
                    bundleID: bundleID, originalAppVersion: originalAppVersion, originalPurchaseDate: originalPurchaseDate,
                    environment: environment, origin: .simulated)
            result.originalAppVersion = originalAppVersion
            result.originalPurchaseDate = originalPurchaseDate
            result.environment = environment
            return result
        }
    }
#endif
