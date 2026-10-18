import Foundation

@main
struct PhysicalProductionObservationScheduleTests {
    static func main() {
        for seconds in [45, 180] {
            for optIn in [false, true] {
                var short = PhysicalProductionObservationSchedule(
                    startedAt: 100, observationSeconds: seconds, longSmoke: optIn)
                precondition(short.uiHealthCheckIntervalSeconds == 1)
                let checks = (0...seconds).filter { short.beginUIHealthCheck(at: 100 + Double($0)) }
                precondition(checks.count == seconds && checks.last == seconds - 1)
                precondition(short.deadline == 100 + Double(seconds))
                precondition(short.sleepAfterUIHealthCheckNanoseconds(at: 112.5) == 1_000_000_000)
                precondition(short.sleepAfterUIHealthCheckNanoseconds(at: 100 + Double(seconds)) == 1_000_000_000)
            }
        }

        var hour = PhysicalProductionObservationSchedule(startedAt: 500.25, observationSeconds: 3600, longSmoke: true)
        var observations: [Int] = []
        for second in 0...3600 {
            if hour.beginUIHealthCheck(at: 500.25 + Double(second)) { observations.append(second) }
            precondition(hour.sleepNanoseconds(at: 500.25 + Double(second)) <= 1_000_000_000)
        }
        precondition(hour.uiHealthCheckIntervalSeconds == 30)
        precondition(observations.count == 120 && observations.first == 0 && observations.last == 3570)
        precondition(zip(observations, observations.dropFirst()).allSatisfy { $1 - $0 == 30 })
        precondition(hour.deadline == 4100.25 && hour.sleepNanoseconds(at: 4100.25) == 0)

        var delayed = PhysicalProductionObservationSchedule(startedAt: 100, observationSeconds: 3600, longSmoke: true)
        precondition(delayed.beginUIHealthCheck(at: 100))
        precondition(!delayed.beginUIHealthCheck(at: 129.999))
        precondition(delayed.beginUIHealthCheck(at: 130))
        // Simulate a slow query crossing several scheduled slots. It gets one
        // health check, not a catch-up burst; the recording deadline stays fixed.
        precondition(delayed.beginUIHealthCheck(at: 225))
        precondition(!delayed.beginUIHealthCheck(at: 225.001))
        precondition(delayed.nextUIHealthCheckAt == 255 && delayed.deadline == 3700)
        precondition(delayed.sleepAfterUIHealthCheckNanoseconds(at: 225) == 1_000_000_000)
        precondition(delayed.sleepAfterUIHealthCheckNanoseconds(at: 260) == 0)
        precondition(delayed.sleepNanoseconds(at: 254.5) == 500_000_000)
        precondition(delayed.beginUIHealthCheck(at: 3699.75))
        precondition(delayed.sleepNanoseconds(at: 3699.875) == 125_000_000)
        precondition(!delayed.beginUIHealthCheck(at: 3700))
        precondition(delayed.sleepNanoseconds(at: 3701) == 0)

        print("Physical production observation schedule passed: short cadence, 120 sparse hour checks, slow-query isolation, fixed deadline and bounded sleep.")
    }
}
