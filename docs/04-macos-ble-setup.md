# macOS BLE Setup (exploration tooling)

Python + [bleak](https://github.com/hbldh/bleak) is used on macOS to explore the
device before/while building the iOS app.

## Setup

```bash
python3 -m venv .venv
.venv/bin/pip install bleak
```

## Scripts

| Script | Purpose |
|---|---|
| `scan.py` | Scan for BLE devices; confirm the WHOOP + its advertised services. |
| `enumerate.py` | Connect and dump the full GATT map (services, characteristics, values). |
| `listen.py` | Subscribe to all notify characteristics and log raw frames + parsed HR. |

## ⚠️ The macOS Bluetooth permission gotcha

Running a bleak script **directly from a shell launched inside an app** (e.g. an
IDE/agent) aborts immediately with **`SIGABRT` (exit 134)** and the message:

> *This app has crashed because it attempted to access privacy-sensitive data
> without a usage description … NSBluetoothAlwaysUsageDescription.*

Why: macOS TCC attributes the Bluetooth check to the **responsible app** hosting
the shell, and that attribution doesn't satisfy the subprocess. Repackaging the
Python interpreter into a signed `.app` bundle does **not** fix it.

### Working solution: run it from Terminal.app

Launch the script through a `.command` file so **Terminal.app** is the responsible
app — Terminal gets its own Bluetooth grant (approve once), and output is teed to a
log file:

```bash
echo "scan.py" > which_script.txt   # which script to run
open whoop_run.command              # opens Terminal, prompts for Bluetooth once
cat whoop_log.txt                    # read results
```

`whoop_run.command` reads the script name from `which_script.txt`, runs it with the
venv Python, and logs to `whoop_log.txt`. (It quotes the name, so bake parameters
into the script's defaults rather than passing args.)

> The iOS app has none of this pain — CoreBluetooth permission is just an
> `Info.plist` usage string the app declares natively.
