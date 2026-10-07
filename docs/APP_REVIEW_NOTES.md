# App Review notes (paste into App Store Connect → App Review Information)

Updated for the October 6 rejection of 1.0 (54), tracked in #72. Paste these
notes only with the new tested build; they do not describe rejected build 54.

Status on October 7: App Review clarification sent; resubmission remains
pending the private physical-iPhone GPS recording and replacement-build
verification. Builds 95 and 96 succeeded on GA Xcode Cloud and are available
to the existing internal TestFlight group. 290 focused unit/regression tests
passed. The Steps/Insights tap defect was traced to sparse Button-label hit
regions, not missing routes. Both card labels now define a full interaction
shape; editing/reordering and metric formulas are unchanged. A freshly built
native-iPhone Release functional test passes the complete demo navigation and
immediate erase-to-setup workflow. Functional UI tests use `-Onone`; the Cloud
distribution archive retains optimized Release settings. Follow #72 and #73
for the latest remaining-device checks and replacement-build availability.

## How to review without hardware

On the first screen, use the pinned **Demo mode** control at the bottom and tap
**Explore sample data**. It is also available throughout setup; do not choose
hardware pairing. The app loads 21 days of
labelled sample data, entirely on the device, with no account, password,
Bluetooth or internet. Every screen shows a "Sample data" mark. **Erase sample
data and return to setup** at the top returns to first-run setup.

Physical-device pairing video: attached directly to this App Review submission as
**Final video Atria 2.mov**. It is available only to App Review, not published
on the product page or a public video service. It shows the earlier app on a
physical Apple device pairing with and using a WHOOP 4.0 strap.

## October 6 review changes

- **2.5.4:** background GPS is retained for active outdoor workouts. Open
  Today → plus → Start workout, choose Walking, Running, Hiking or Cycling, grant
  Location access, and start. Route, distance, pace and elevation continue
  with the screen locked or another app open until the workout is paused or
  finished. This is user-initiated workout recording, not general tracking.
  Apple requested a physical-device recording demonstrating this feature;
  the earlier pairing video does not establish the new GPS workflow.
- **2.5.1:** Settings now identifies **Apple Health (HealthKit)** as its own
  destination. It explains optional Health reads and writes before permission
  is requested. The explanation is visible in demo mode; authorization and
  data operations are disabled while using sample data. Atria does not use
  CareKit.
- **2.1:** the hardware-free demo action is pinned at the bottom of every setup
  step, including the first screen, and verified on an iPad simulator.
- **1.4.1:** the App Store description and in-app information remind users to
  seek a doctor's advice in addition to using Atria and before making medical
  decisions. The Release build excludes the developer-only rhythm assessment
  and physician-note interface. Atria's fitness metrics are estimates; no
  regulatory approval is claimed or attached.

## Independent use of user-owned hardware (5.2.1)

Atria currently supports WHOOP 4.0 only, including unused straps owners may
have set aside after upgrading to newer hardware. No support for WHOOP 5.0,
MG, or subsequent generations is claimed. The owner voluntarily chooses to connect their own
strap. Atria does not require users to stop using or replace the manufacturer's
app or services, and does not claim superiority over the official WHOOP app.
The hardware remains the user's property; WHOOP, Inc. is its manufacturer and
seller. The WHOOP name is used to accurately identify compatibility and the
manufacturer, rather than to imply endorsement.

Atria computes its own local fitness estimates from sensor data obtained from
the user's strap. It does not retrieve the user's WHOOP account, cloud history,
paid service content or official recovery/strain scores. It communicates with
the strap directly, including requests for sensor streams and stored history.
We respectfully request reconsideration of this independent, voluntary
use of user-owned hardware and ask App Review to identify any specific content
or hardware interaction that still requires documentary authorization. We
do not claim to hold WHOOP authorization, and ownership of a strap is not
presented as documentary authorization.

## Hardware

- **Device:** WHOOP 4.0 wrist strap.
- **Manufacturer / seller:** WHOOP, Inc. (Boston, MA, USA).
- **Affiliation:** none. Atria is independent and open source, and is not
  endorsed by WHOOP.
- **Source:** the complete project and public development history are available
  at https://github.com/adidshaft/atria.
- **Connection:** Bluetooth Low Energy, with the phone as central. The user
  pairs a strap they own. No WHOOP account or cloud service is used.
- **Bluetooth privacy:** iOS presents a generic warning when an app can
  discover nearby Bluetooth devices. Atria requests that permission only to
  find and communicate with the user's compatible strap during user-initiated
  setup and normal reconnecting. Discovery data is processed on-device; Atria
  does not retain or transmit a list of nearby devices, infer location, or
  create an advertising/profile record. Sample-data mode never initializes
  Bluetooth.

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
diagnosis. Seek a doctor's advice in addition to using Atria and before making
any medical decisions. Trend alerts are optional, compare only with the user's own range,
and say "not a medical reading". The methodology and sources for each metric are
in Settings → About → Sources and in each metric's (i) sheet.

Everything is processed on-device. There is no Atria account, server-side
analytics, location profiling, or automatic research upload. The optional
research feature can only prepare an inspectable, anonymized local bundle; it
leaves the device only if the user explicitly selects a recipient through the
iOS share sheet. Sample-data mode disables that feature completely.
The developer has no remote access to the user's sensor readings, history,
journal, or local files. Apple Health access is controlled by the user's iOS
permissions, and user-initiated exports remain the user's choice.

- Privacy policy: https://atria.zookfit.in/privacy/
- Support: https://github.com/adidshaft/atria/issues
