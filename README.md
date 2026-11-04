# Treadmill

A minimal macOS menu-bar app for the KingSmith WalkingPad **Z1**. It replaces
the KS Fit app. The only permission it asks for is Bluetooth: no account, no
location, no cloud.

## Use

```bash
scripts/build-app.sh            # builds build/Treadmill.app
scripts/build-app.sh --install  # …and copies it to /Applications
open build/Treadmill.app
```

A walking figure appears in the menu bar. Click it to open the panel. The app
connects automatically when the treadmill is on and in range. The current
speed is shown next to the icon while you walk.

| Control | What it does |
|---|---|
| Start / Resume (space) | Start the belt, or resume after a pause |
| Pause (space) | Pause the belt; counters are kept |
| Stop | Stop the belt and end the session. The pad resets its counters. |
| − / + (↓ / ↑) | Speed in 0.1 mph (or km/h) steps; ⇧↓ / ⇧↑ for 0.5. Hold to repeat. |
| Presets | One tap to walk at 1–3.5 mph (2–6 km/h). Also starts the belt if it's stopped. |
| Standby / Wake up | Put the pad to sleep (stops the belt first) and wake it |
| Settings | Show miles, beep, indicator light, child lock, auto-stop when idle |

The live stats are time, distance, steps and calories, all as reported by the
pad. The Z1 has no "auto" mode (where the belt follows your position on the
pad); it refuses that setting.

**Only one Bluetooth connection at a time.** If the KS Fit app on your phone
is connected, close it (or turn off the phone's Bluetooth) first.

## How it works

The Z1 speaks the standard Bluetooth Fitness Machine Service (FTMS). It ignores
every command, and sends no data, until it receives an unlock frame derived
from its Bluetooth name. The full wire protocol is in
[docs/protocol.md](docs/protocol.md).

```
Sources/WalkingPadKit/Z1Protocol.swift   pure byte encoding/decoding (unit-tested)
Sources/WalkingPadKit/Treadmill.swift    CoreBluetooth client: scan, unlock, commands, telemetry
Sources/TreadmillApp/                    SwiftUI menu-bar UI
Tests/WalkingPadKitTests/                protocol tests (swift test)
```

`Z1Protocol.swift` has no Apple dependencies beyond Foundation, so it maps
1:1 to Kotlin for a future Android port.

### Debugging

```bash
log stream --level debug --predicate 'subsystem == "local.treadmill"'
```

This shows Bluetooth state, every device seen while scanning, the unlock, and
command failures.

## Credits

The protocol was reverse-engineered by
[slandau3/z1-walkingpad-mcp](https://github.com/slandau3/z1-walkingpad-mcp)
(MIT), building on [duttke.de/walkingpad](https://www.duttke.de/en/walkingpad/).
