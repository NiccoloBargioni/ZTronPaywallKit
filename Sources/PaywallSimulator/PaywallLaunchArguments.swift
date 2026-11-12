#if DEBUG
    public import Foundation

    /// The launch-argument keys, so a UI test writes `[PaywallLaunchArgument.preset.rawValue,
    /// PaywallPreset.lifetime.rawValue]` and neither side can be misspelt.
    public enum PaywallLaunchArgument: String, CaseIterable, Sendable {
        case preset = "-paywall.preset"
        case tokens = "-paywall.tokens"
        case network = "-paywall.network"
        case store = "-paywall.store"
        case tolerance = "-paywall.tolerance"
    }

    /// Maps launch arguments to a `PaywallSimulation`: the preset first, then every override, whatever the order.
    /// A known key with a bad or missing value is reported in `problems`; an unknown key is ignored, because it
    /// may belong to another framework.
    public struct PaywallLaunchArguments: Sendable, Equatable {
        public enum Problem: Equatable, Sendable {
            case invalidValue(PaywallLaunchArgument, String)
            case missingValue(PaywallLaunchArgument)
        }

        public let simulation: PaywallSimulation
        public let problems: [Problem]
        /// Whether any paywall argument was present at all.
        public let isPresent: Bool

        public init(_ arguments: [String] = ProcessInfo.processInfo.arguments) {
            var values: [PaywallLaunchArgument: String] = [:]
            var problems: [Problem] = []
            var index = 0
            while index < arguments.count {
                guard let key = PaywallLaunchArgument(rawValue: arguments[index]) else {
                    index += 1
                    continue
                }
                let next = index + 1 < arguments.count ? arguments[index + 1] : nil
                if let next, PaywallLaunchArgument(rawValue: next) == nil {
                    values[key] = next
                    index += 2
                } else {
                    problems.append(.missingValue(key))
                    index += 1
                }
            }

            var simulation = PaywallSimulation()
            if let raw = values[.preset] {
                if let preset = PaywallPreset(rawValue: raw) {
                    simulation = preset.simulation
                } else {
                    problems.append(.invalidValue(.preset, raw))
                }
            }
            for key in PaywallLaunchArgument.allCases {
                guard key != .preset, let raw = values[key] else { continue }
                switch key {
                case .preset:
                    break
                case .tokens:
                    if let n = Int(raw), n >= 0 { simulation.tokens = n } else { problems.append(.invalidValue(key, raw)) }
                case .network:
                    if let on = Self.flag(raw) { simulation.network = on } else { problems.append(.invalidValue(key, raw)) }
                case .store:
                    if let up = Self.flag(raw) { simulation.storeReachable = up } else { problems.append(.invalidValue(key, raw)) }
                case .tolerance:
                    if let s = TimeInterval(raw), s >= 0 { simulation.tolerance = s } else { problems.append(.invalidValue(key, raw)) }
                }
            }
            self.simulation = simulation
            self.problems = problems
            self.isPresent = !values.isEmpty || !problems.isEmpty
        }

        static func flag(_ raw: String) -> Bool? {
            switch raw.lowercased() {
            case "1", "true", "yes", "on", "up", "reachable": return true
            case "0", "false", "no", "off", "down", "unreachable": return false
            default: return nil
            }
        }
    }
#endif
