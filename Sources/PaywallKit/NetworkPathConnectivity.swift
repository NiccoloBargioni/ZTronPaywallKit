import Network
public import PaywallCore

/// `PaywallConnectivity` over `NWPathMonitor`'s async sequence. On iOS 15–16 and macOS 12–13 the monitor can only
/// report on a dispatch queue, which the package does not use, so there the stream stays silent, the engine
/// assumes a path, and the outbox drains on its other triggers (launch, foreground, purchase, the coalescing timer).
public struct NetworkPathConnectivity: PaywallConnectivity {
    public init() {}

    public func paths() async -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
            let task = Task {
                for await path in NWPathMonitor() {
                    continuation.yield(path.status == .satisfied)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return stream
    }
}
