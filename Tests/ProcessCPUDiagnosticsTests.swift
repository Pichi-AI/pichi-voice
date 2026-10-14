import Foundation

@main
struct ProcessCPUDiagnosticsTests {
    static func main() {
        let first = DiagnosticProcessCPUTime(userSeconds: 1, systemSeconds: 2)
        let last = DiagnosticProcessCPUTime(userSeconds: 2, systemSeconds: 3)
        precondition(first.totalMilliseconds == 3_000)
        precondition(last.milliseconds(since: first) == 2_000)
        precondition(first.milliseconds(since: first) == 0)
        precondition(DiagnosticProcessCPUTime(userSeconds: 1, systemSeconds: 4).milliseconds(since: first) == 2_000)
        precondition(DiagnosticProcessCPUTime(userSeconds: 0.125, systemSeconds: 0.125).totalMilliseconds == 250)
        precondition(first.milliseconds(since: last) == nil)
        precondition(DiagnosticProcessCPUTime(userSeconds: 0.5, systemSeconds: 10).milliseconds(since: first) == nil)
        for invalid in [
            DiagnosticProcessCPUTime(userSeconds: -1, systemSeconds: 0),
            DiagnosticProcessCPUTime(userSeconds: .nan, systemSeconds: 0),
            DiagnosticProcessCPUTime(userSeconds: 0, systemSeconds: .infinity),
            DiagnosticProcessCPUTime(userSeconds: Double(Int64.max), systemSeconds: 0),
        ] {
            precondition(invalid.totalMilliseconds == nil)
            precondition(invalid.milliseconds(since: first) == nil)
            precondition(last.milliseconds(since: invalid) == nil)
        }
        #if canImport(Darwin)
        guard let before = DiagnosticProcessCPUTime.capture(), let after = DiagnosticProcessCPUTime.capture(),
              let total = after.totalMilliseconds, let delta = after.milliseconds(since: before) else {
            preconditionFailure("The process CPU counter must be available on Darwin")
        }
        precondition(total >= 0 && delta >= 0)
        #else
        precondition(DiagnosticProcessCPUTime.capture() == nil)
        #endif
    }
}
