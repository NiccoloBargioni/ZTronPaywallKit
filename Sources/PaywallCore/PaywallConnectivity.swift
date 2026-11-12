/// Whether the device has a network path. The outbox drains only while one exists, and right away when one
/// returns. Darwin hosts pass `NetworkPathConnectivity` (PaywallKit, NWPathMonitor); tests pass
/// `FakeConnectivity`. Without one the engine assumes a path and lets the carrier's own errors decide.
public protocol PaywallConnectivity: Sendable {
    /// The current state first, then every change.
    func paths() async -> AsyncStream<Bool>
}
