#if DEBUG
    public import PaywallCore

    /// A scriptable network path. Every `paths()` stream gets the current state, then each `set(_:)`.
    public actor FakeConnectivity: PaywallConnectivity {
        public private(set) var hasPath: Bool
        private var listeners: [Int: AsyncStream<Bool>.Continuation] = [:]
        private var nextID = 0

        public init(hasPath: Bool = true) { self.hasPath = hasPath }

        public func paths() -> AsyncStream<Bool> {
            let id = nextID
            nextID += 1
            let (stream, continuation) = AsyncStream<Bool>.makeStream()
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeListener(id) }
            }
            continuation.yield(hasPath)
            listeners[id] = continuation
            return stream
        }

        public func set(_ hasPath: Bool) {
            self.hasPath = hasPath
            for continuation in listeners.values { continuation.yield(hasPath) }
        }

        public var listenerCount: Int { listeners.count }

        private func removeListener(_ id: Int) { listeners[id] = nil }
    }
#endif
