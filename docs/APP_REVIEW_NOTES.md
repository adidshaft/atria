# App Review notes (paste into App Store Connect → App Review Information)

Draft for #72. Keep it factual and in step with the build being submitted.

## How to review without hardware

On the first screen tap **Explore sample data**. The app loads 21 days of
labelled sample data, entirely on the device, with no account, password,
Bluetooth or internet. Every screen shows a "Sample data" mark. **Erase sample
data and return to setup** at the top returns to first-run setup.

Physical-device pairing video: https://atria.zookfit.in/review/atria-hardware-pairing-demo.mov

## Hardware

- **Device:** WHOOP 4.0 wrist strap.
- **Manufacturer / seller:** WHOOP, Inc. (Boston, MA, USA).
- **Affiliation:** none. Atria is independent and open source, and is not
  endorsed by WHOOP.
- **Connection:** Bluetooth Low Energy, with the phone as central. The user
  pairs a strap they own. No WHOOP account or cloud service is used.

## Signals read

| Signal | Source | Used for |
|---|---|---|
| Heart rate + beat-to-beat (RR) intervals | Standard BLE Heart Rate service (0x180D / 0x2A37) | HR, HRV, resting HR, sleep, strain, recovery |
| Battery level | Standard Battery service (0x2A19) | Strap battery |
| Motion (accelerometer/gyro frames) and stored history records | Strap's own data service, requested with its start/stop and history commands | Steps, sleep/wake, workout detection, catching up after time away |
| Skin-temperature field | Strap history records | **Relative** overnight change against the user's own nights only, never degrees |

**Not available:** blood oxygen (SpO₂; the decoder is unverified, so it is never
shown), ECG, blood pressure, irregular-rhythm or AFib detection, and absolute
body temperature.

## Health and safety

Atria gives wellness estimates and is not a medical device. It makes no
diagnosis. Trend alerts are optional, compare only with the user's own range,
and say "not a medical reading". The methodology and sources for each metric are
in Settings → About → Sources and in each metric's (i) sheet. Everything is
processed on the device. There is no server and no analytics.

- Privacy policy: https://atria.zookfit.in/privacy/
- Support: https://github.com/adidshaft/atria/issues
