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
            "--atria-store-ble-frames"
        ]

        return arguments.contains { argument in
            diagnosticFlags.contains(argument)
                || diagnosticPrefixes.contains(where: argument.hasPrefix)
        }
    }()
}

func AtriaDebugLog(_ format: StaticString, _ args: CVarArg...) {
    guard AtriaDebugLogging.isEnabled else { return }
    withVaList(args) { pointer in
        NSLogv(String(describing: format), pointer)
    }
}
