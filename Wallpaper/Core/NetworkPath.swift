import Network

/// Reads the current network path once, on demand.
///
/// Deliberately not a long-lived monitor. Rotation is event-driven, so the only
/// moment the path matters is the moment a change runs: starting a monitor,
/// taking its first update and cancelling costs microseconds and leaves an idle
/// app with nothing running. That is the same rule the offline monitor follows
/// — it exists only while there is something to wait for.
enum NetworkPath {
    struct Snapshot: Sendable, Hashable {
        var isSatisfied: Bool
        /// Cellular, or a phone's Personal Hotspot.
        var isExpensive: Bool
        /// Low Data Mode.
        var isConstrained: Bool

        /// Downloading here spends the user's own data allowance.
        var isMetered: Bool { isExpensive || isConstrained }

        init(isSatisfied: Bool, isExpensive: Bool, isConstrained: Bool) {
            self.isSatisfied = isSatisfied
            self.isExpensive = isExpensive
            self.isConstrained = isConstrained
        }

        init(_ path: NWPath) {
            self.init(
                isSatisfied: path.status == .satisfied,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
        }
    }

    /// The path right now, or `nil` if the first update did not arrive in time.
    ///
    /// A `nil` answer must never be read as "metered": failing to measure the
    /// connection is not a reason to stop changing the wallpaper.
    static func current(timeout: Duration = .seconds(2)) async -> Snapshot? {
        await withTaskGroup(of: Snapshot?.self) { group in
            group.addTask {
                let monitor = NWPathMonitor()
                let updates = AsyncStream<Snapshot> { continuation in
                    monitor.pathUpdateHandler = { continuation.yield(Snapshot($0)) }
                    // Covers both the normal finish and cancellation by the
                    // timeout below, so the monitor never outlives this call.
                    continuation.onTermination = { _ in monitor.cancel() }
                    monitor.start(queue: .global(qos: .utility))
                }
                for await snapshot in updates { return snapshot }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
