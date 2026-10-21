import Foundation

/// Test-runner scheduling only. The parent separately owns continuous native USB frames.
struct PhysicalProductionObservationSchedule {
    let uiHealthCheckIntervalSeconds: TimeInterval
    let deadline: TimeInterval
    private(set) var nextUIHealthCheckAt: TimeInterval

    init(startedAt: TimeInterval, observationSeconds: Int, longSmoke: Bool) {
        // Keep short acceptance tests unchanged. There is no caller-set cadence or
        // disable flag; only the separately admitted full-hour smoke uses 30 seconds.
        uiHealthCheckIntervalSeconds = longSmoke && observationSeconds == 3600 ? 30 : 1
        deadline = startedAt + TimeInterval(observationSeconds)
        nextUIHealthCheckAt = startedAt
    }

    mutating func beginUIHealthCheck(at uptime: TimeInterval) -> Bool {
        guard uptime < deadline, uptime >= nextUIHealthCheckAt else { return false }
        // Anchor to the actual check start. Slow accessibility calls must not cause
        // a burst of catch-up queries or extend the fixed recording deadline.
        nextUIHealthCheckAt = uptime + uiHealthCheckIntervalSeconds
        return true
    }

    func sleepNanoseconds(at uptime: TimeInterval) -> UInt64 {
        let remaining = min(deadline, nextUIHealthCheckAt) - uptime
        return UInt64(max(0, min(1, remaining)) * 1_000_000_000)
    }

    func sleepAfterUIHealthCheckNanoseconds(at uptime: TimeInterval) -> UInt64 {
        // The existing short probes sleep one full second after each query.
        // Preserve that behavior even when a short probe's query itself is slow.
        uiHealthCheckIntervalSeconds == 1 ? 1_000_000_000 : sleepNanoseconds(at: uptime)
    }
}
