import Foundation

enum AtriaDebugLogging {
    private static let enableFlag = "--whoop-enable-debug-logs"

    static let isEnabled: Bool = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(enableFlag) {
            return true
        }

        let diagnosticPrefixes = [
            "--whoop-log-",
            "--whoop-export-",
            "--whoop-validate-",
            "--whoop-confirm-",
            "--whoop-schedule-"
        ]

        let diagnosticFlags: Set<String> = [
            "--whoop-write-session-backup",
            "--whoop-verify-session-backup",
            "--whoop-clear-reference-inputs",
            "--whoop-healthkit-export",
            "--whoop-healthkit-reference-audit",
            "--whoop-healthkit-reset-rebuild-atria-hr",
            "--whoop-full-protocol-mode",
            "--whoop-long-wear-mode",
            "--whoop-standard-hr-only",
            "--whoop-active-motion-imu-check",
            "--whoop-reset-protocol-diagnostics",
            "--whoop-log-live-packets",
            "--whoop-log-ble-frames",
            "--whoop-store-ble-frames"
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
