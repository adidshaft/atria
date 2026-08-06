# Physical process-health checkpoint

Date: 2026-07-30 (Asia/Kolkata)

This checkpoint distinguishes resource reports produced by earlier installed
binaries from the exact Release installed after `c44d9132`.

## Earlier reports retained as regression evidence

- `Atria.cpu_resource_fatal-2026-07-30-200515.ips`
  - bundle container: `2368D2B3-F73E-4CBB-9400-42EBEADA7239`
  - executable UUID: `A3832503-9B75-3F74-A79E-44CEF8EA5AF8`
  - outcome: iOS killed the process after 48 CPU seconds in 57 seconds.
- `Atria.diskwrites_resource-2026-07-30-223120.ips`
  - bundle container: `6C36FE6A-4BAF-4567-800B-B80519E80D0F`
  - executable UUID: `06DFC290-290F-36D4-96EB-07DAA0010875`
  - outcome: advisory report for 4,294.97 MB of file-backed dirtying during
    the preceding 14,452 seconds; iOS did not kill the process.

Both reports predate the current install and refer to different bundle
containers than the exact current Release.

## Current exact Release observation

- installed executable SHA-256:
  `b0438f794f0c32c5fe99a41f3e777e58660edcae859be82b28460ffd982c7222`
- current bundle container:
  `D1DA4797-B449-4058-9822-4757AD7EE77F`
- Atria PID remained `4581` across the observation.
- accepted live strap state remained `live`; packet age was 0.375 seconds in
  the closing preference snapshot.
- a fresh `systemCrashLogs` listing at 23:42 IST contained no Atria report
  newer than the current install.
- focused battery truth/transport/presentation XCTest run:
  `AtriaStrapPowerPolicyTests`,
  `AtriaBLEBatteryTransportPolicyStructureTests`, and
  `AtriaLiveTabAccessoryTests` — `** TEST SUCCEEDED **`.

This is a non-disruptive foreground process-health pass. It does not replace
the still-open long locked/background CPU acceptance in GitHub issue #24.
