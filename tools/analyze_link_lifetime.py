#!/usr/bin/env python3
"""Score strap link stability from an idevicesyslog capture.

Built 2026-07-26 to make the connected-peripheral-retainer fix measurable
against a like-for-like baseline. It attributes every disconnect to a cause
rather than counting them in aggregate, because the two populations seen on
device have different fixes:

  * ``API MISUSE: Forcing disconnection of unused peripheral`` -> CoreBluetooth
    deallocated a connected ``CBPeripheral``. App-side defect; must be zero.
  * supervision timeout after the strap negotiates a slow connection interval
    -> strap-side power saving. Not fixable from the app.

Usage:
    analyze_link_lifetime.py CAPTURE [--address E0:29:C0:AC:D2:75]
"""

from __future__ import annotations

import argparse
import re
import statistics
import sys
from datetime import datetime

DEFAULT_ADDRESS = "E0:29:C0:AC:D2:75"

TS = re.compile(r"^(\w{3} +\d+ \d{2}:\d{2}:\d{2}\.\d+)")
TOPOLOGY = re.compile(
    r"Le topology - \{adv-addr: (?P<addr>[0-9A-F:]+)-Random.*?"
    r"interval: (?P<interval>[\d.]+) ms, latency: (?P<latency>\d+), lsto: (?P<lsto>\d+)"
)
DISCONNECT = re.compile(
    r"LE ConnManager disconnection complete reason (?P<reason>\d+) "
    r"address=Random (?P<addr>[0-9A-F:]+)"
)
CONNECT = re.compile(
    r"Outgoing connection to device .* was successful with connection interval (?P<ci>\d+)"
)
ACCEPTING = re.compile(
    r"Accepting following parameters: min=(?P<min>\d+), max=(?P<max>\d+), "
    r"lat=(?P<lat>\d+), mul=(?P<mul>\d+)"
)
MISUSE = "API MISUSE: Forcing disconnection of unused peripheral"


def parse_ts(line: str):
    m = TS.match(line)
    if not m:
        return None
    # Year is absent from syslog; any fixed year works for deltas.
    return datetime.strptime("2000 " + m.group(1), "%Y %b %d %H:%M:%S.%f")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--address", default=DEFAULT_ADDRESS)
    args = ap.parse_args()

    connects: list[datetime] = []
    disconnects: list[tuple[datetime, int]] = []
    misuses: list[datetime] = []
    downgrades: list[datetime] = []
    params: dict[str, int] = {}
    requests: dict[str, int] = {}

    with open(args.capture, errors="replace") as fh:
        for line in fh:
            ts = parse_ts(line)
            if MISUSE in line and ts:
                misuses.append(ts)
                continue
            m = DISCONNECT.search(line)
            if m and m.group("addr") == args.address and ts:
                disconnects.append((ts, int(m.group("reason"))))
                continue
            m = TOPOLOGY.search(line)
            if m and m.group("addr") == args.address:
                key = (f"interval={m.group('interval')}ms "
                       f"lsto={int(m.group('lsto')) * 10}ms")
                params[key] = params.get(key, 0) + 1
                if float(m.group("interval")) > 100 and ts:
                    downgrades.append(ts)
                continue
            m = ACCEPTING.search(line)
            if m:
                key = (f"min={int(m.group('min')) * 1.25:.1f}ms "
                       f"max={int(m.group('max')) * 1.25:.1f}ms "
                       f"timeout={int(m.group('mul')) * 10}ms")
                requests[key] = requests.get(key, 0) + 1
                continue
            if CONNECT.search(line) and ts:
                connects.append(ts)

    if not connects and not disconnects:
        print("no strap link activity found — wrong address or empty capture",
              file=sys.stderr)
        return 2

    span = None
    stamps = [t for t, _ in disconnects] + connects
    if stamps:
        span = (max(stamps) - min(stamps)).total_seconds()

    print(f"capture_span_s={span:.0f}" if span else "capture_span_s=unknown")
    print(f"connects={len(connects)}")
    print(f"disconnects={len(disconnects)}")
    if span and span > 0:
        print(f"disconnects_per_min={len(disconnects) / span * 60:.2f}")

    by_reason: dict[int, int] = {}
    for _, reason in disconnects:
        by_reason[reason] = by_reason.get(reason, 0) + 1
    for reason, count in sorted(by_reason.items(), key=lambda kv: -kv[1]):
        label = {708: "supervision_timeout", 722: "local_host_terminated"}.get(
            reason, "other")
        print(f"  reason_{reason}={count} ({label})")

    print(f"api_misuse_forced_disconnects={len(misuses)}")
    if misuses:
        print("  VERDICT: FAIL — the app is deallocating connected peripherals")
    else:
        print("  VERDICT: PASS — no unreferenced-peripheral teardown")

    print("negotiated_parameters:")
    for key, count in sorted(params.items(), key=lambda kv: -kv[1]):
        print(f"  {key} x{count}")
    if requests:
        print("peripheral_requested_parameters:")
        for key, count in sorted(requests.items(), key=lambda kv: -kv[1]):
            print(f"  {key} x{count}")
    print(f"slow_interval_downgrades={len(downgrades)}")

    # Link lifetime: connect -> next disconnect.
    lifetimes = []
    pending = None
    for ts in sorted(connects + [t for t, _ in disconnects]):
        is_disconnect = any(ts == t for t, _ in disconnects)
        if is_disconnect:
            if pending is not None:
                lifetimes.append((ts - pending).total_seconds())
                pending = None
        elif pending is None:
            pending = ts
    if lifetimes:
        print(f"link_lifetime_n={len(lifetimes)}")
        print(f"link_lifetime_median_s={statistics.median(lifetimes):.1f}")
        print(f"link_lifetime_mean_s={statistics.mean(lifetimes):.1f}")
        print(f"link_lifetime_max_s={max(lifetimes):.1f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
