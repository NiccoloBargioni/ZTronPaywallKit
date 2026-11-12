#if DEBUG
    public import Foundation
    public import PaywallCore

    /// The named states a developer, a UI test or a preview can put the paywall in. A misspelt case fails to
    /// compile; a misspelt launch-argument value is reported by `PaywallLaunchArguments`, never fatal.
    public enum PaywallPreset: String, CaseIterable, Sendable {
        case free, trial, weekly, monthly, yearly, lifetime, grandfathered
        case tokens5 = "tokens-5"
        case broke, offline
        case storeDown = "store-down"

        /// One exhaustive switch: a new case does not compile until it says what it simulates.
        public var simulation: PaywallSimulation {
            var simulation = PaywallSimulation()
            switch self {
            case .free:
                break
            case .trial:
                simulation.entitlement = .subscription(.weekly, isTrial: true)
            case .weekly:
                simulation.entitlement = .subscription(.weekly)
            case .monthly:
                simulation.entitlement = .subscription(.monthly)
            case .yearly:
                simulation.entitlement = .subscription(.yearly)
            case .lifetime:
                simulation.entitlement = .lifetime(.purchase(transactionID: PaywallSimulation.lifetimeTransactionID))
            case .grandfathered:
                simulation.entitlement = .lifetime(.grandfathered(originalAppVersion: PaywallSimulation.grandfatheredVersion))
            case .tokens5:
                simulation.tokens = 5
            case .broke:
                simulation.tokens = 0
                simulation.purchaseOutcome = .failed
            case .offline:
                simulation.network = false
            case .storeDown:
                simulation.storeReachable = false
                simulation.network = false
            }
            return simulation
        }
    }

    /// The paywall screen's four purchase outcomes, without App Store Connect.
    public enum SimulatedPurchaseOutcome: String, CaseIterable, Sendable {
        case success, cancelled, pending, failed
    }

    public enum SimulatedRefund: String, CaseIterable, Sendable {
        case subscription, lifetime, lastTokenPack
    }

    /// Every switch the simulator exposes. Subscriptions without `expiresAt` run one period from the moment the
    /// simulation is applied, so presets compare equal.
    public struct PaywallSimulation: Sendable, Equatable {
        public static let lifetimeTransactionID: UInt64 = 1
        public static let grandfatheredVersion = "1"

        /// `.subscription(.weekly, isTrial:, expiresAt:)`, `.lifetime(.purchase(...))`, `.lifetime(.grandfathered(...))`.
        public var entitlement: Entitlement = .free
        /// The ledger balance.
        public var tokens = 0
        /// `false`: resolution fails and, without a snapshot, gates answer `entitlementUnavailable`.
        public var storeReachable = true
        /// `false`: `products()` fails (cached prices, buy disabled) and the outbox stays queued.
        public var network = true
        public var purchaseOutcome: SimulatedPurchaseOutcome = .success
        public var introOfferEligible = true
        /// Overrides `S`.
        public var tolerance: TimeInterval?

        /// A free user with nothing.
        public init() {}

        public init(_ preset: PaywallPreset) {
            self = preset.simulation
        }
    }
#endif
