#if DEBUG
    public import PaywallCore
    public import PaywallKit

    extension PaywallServiceProvider.Service {
        /// The fake implementation the simulator drives: `PaywallSimulator.shared` and its switches, on a fresh
        /// temporary directory, with every audit record labelled `"simulated"`.
        public static func simulated(
            _ simulation: PaywallSimulation = PaywallSimulation(),
            catalog: ProductCatalog,
            grandfathering: GrandfatheringPolicy? = nil
        ) -> Self {
            .fake(Paywall.Configuration.simulated(simulation, catalog: catalog, grandfathering: grandfathering))
        }

        /// The same from launch arguments (UI tests). Problems are logged, never fatal.
        public static func simulated(
            _ arguments: PaywallLaunchArguments,
            catalog: ProductCatalog,
            grandfathering: GrandfatheringPolicy? = nil
        ) -> Self {
            .fake(Paywall.Configuration.simulated(arguments, catalog: catalog, grandfathering: grandfathering))
        }

        /// `production` unless a `-paywall.*` launch argument is present, then the simulated fake those arguments
        /// describe, on the production catalog and grandfathering policy. The one line a debug `App.init` needs.
        public static func fromLaunchArguments(
            _ arguments: PaywallLaunchArguments = PaywallLaunchArguments(),
            production: Paywall.Configuration
        ) -> Self {
            guard arguments.isPresent else { return .production(production) }
            return .simulated(arguments, catalog: production.catalog, grandfathering: production.grandfathering)
        }
    }

    extension PaywallServiceProvider {
        /// Switches to the simulated fake (`Service.simulated`) on a fresh simulated journal. `catalog` and
        /// `grandfathering` default to the production configuration this provider saw last, else to the simulator's
        /// own defaults. To flip switches on the fake that is already running, use `PaywallSimulator.shared`.
        @discardableResult
        public func useSimulated(
            _ simulation: PaywallSimulation = PaywallSimulation(),
            catalog: ProductCatalog? = nil,
            grandfathering: GrandfatheringPolicy? = nil
        ) -> Self {
            use(
                .simulated(
                    simulation,
                    catalog: catalog ?? productionConfiguration?.catalog ?? .simulatorDefault,
                    grandfathering: grandfathering ?? productionConfiguration?.grandfathering))
        }

        /// The same from a preset: `useSimulated(.lifetime)`.
        @discardableResult
        public func useSimulated(
            _ preset: PaywallPreset,
            catalog: ProductCatalog? = nil,
            grandfathering: GrandfatheringPolicy? = nil
        ) -> Self {
            useSimulated(PaywallSimulation(preset), catalog: catalog, grandfathering: grandfathering)
        }
    }
#endif
