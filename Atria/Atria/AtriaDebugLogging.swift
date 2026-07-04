import Foundation

enum AtriaDebugLogging {
    private static let enableFlag = "--atria-enable-debug-logs"

    static let isEnabled: Bool = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(enableFlag) {
            return true
        }

        let diagnosticPrefixes = [
            "--atria-log-",
            "--atria-export-",
            "--atria-validate-",
            "--atria-confirm-",
            "--atria-schedule-"
        ]

        let diagnosticFlags: Set<String> = [
            "--atria-write-session-backup",
            "--atria-verify-session-backup",
            "--atria-clear-reference-inputs",
            "--atria-healthkit-export",
            "--atria-healthkit-reference-audit",
            "--atria-healthkit-reset-rebuild-atria-hr",
            "--atria-analytics-calibration-audit",
            "--atria-full-protocol-mode",
            "--atria-long-wear-mode",
            "--atria-standard-hr-only",
            "--atria-active-motion-imu-check",
            "--atria-reset-protocol-diagnostics",
            "--atria-log-live-packets",
            "--atria-log-ble-frames",
            "--atria-store-ble-frames",
            "--atria-test-weekly-report-notification",
            "--atria-test-weekly-report-production-maintenance",
            "--atria-test-morning-summary-notification",
            "--atria-test-morning-summary-toggle-off",
            "--atria-seed-strength-workout-proof"
        ]

        return arguments.contains { argument in
            diagnosticFlags.contains(argument)
                || diagnosticPrefixes.contains(where: argument.hasPrefix)
        } || ProcessInfo.processInfo.environment["ATRIA_SEED_STRENGTH_WORKOUT_PROOF"] == "1"
    }()
}

func AtriaDebugLog(_ format: StaticString, _ args: CVarArg...) {
    guard AtriaDebugLogging.isEnabled else { return }
    withVaList(args) { pointer in
        NSLogv(String(describing: format), pointer)
    }
}

/// Debug-only body-evaluation counter (docs/24 §14.4 measurement protocol):
/// `let _ = AtriaBodyEvalProbe.tick("ViewName")` at the top of a body logs every
/// 25th evaluation so cross-tab rebuild claims are measurable from the console.
/// Does nothing unless debug logging is enabled.
enum AtriaBodyEvalProbe {
    private static var counts: [String: Int] = [:]

    static func tick(_ name: String) {
        guard AtriaDebugLogging.isEnabled else { return }
        counts[name, default: 0] += 1
        let count = counts[name, default: 0]
        if count == 1 || count % 25 == 0 {
            AtriaDebugLog("ATRIADBG body_eval view=%@ count=%d", name, count)
        }
    }
}
