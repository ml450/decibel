# Decibel

A macOS menu bar app (macOS 14+, SwiftUI and Swift Charts) that estimates your listening exposure for each output device, in the style of the Hearing section of Apple Health.

The menu bar shows an ear icon and the live level, coloured **green** below 80 dB, **yellow** from 80 to 90 dB and **red** above 90 dB. Clicking the icon opens a compact panel, like Dropbox's, with:

- the current device and live level
- a D/W/M/6M/Y chart with the average level and an OK/Loud status
- a 7-day dose ring
- the list of devices

The footer has calibration, launch at login and Quit. Launching Decibel from Spotlight or Finder also opens the panel.

## Install

On any Apple silicon Mac:

```bash
curl -fsSL https://raw.githubusercontent.com/ml450/decibel/main/scripts/install.sh | zsh
```

The command downloads the latest release into `/Applications` and starts it. On a new Mac, allow audio access once when macOS asks.

## Updates

The ⬇︎ button next to the gear checks [GitHub Releases](https://github.com/ml450/decibel/releases). Decibel also checks quietly when it starts and every 6 hours. When a newer version is out, the button gets a blue dot and the footer shows **Install**. Decibel then downloads `Decibel.zip`, checks that it is a correctly signed Decibel, replaces itself and relaunches. The audio permission and your data carry over.

To publish a new version:

```bash
scripts/release.sh 1.1 "What changed"
```

The script sets the version, builds, runs the self-test, zips the app, tags the commit, pushes it and creates the GitHub release.

## Build & run

```bash
open Decibel.xcodeproj        # then ⌘R
```

Or from the command line:

```bash
xcodebuild -project Decibel.xcodeproj -scheme Decibel -configuration Release -derivedDataPath build/DerivedData build
ditto build/DerivedData/Build/Products/Release/Decibel.app /Applications/Decibel.app
open /Applications/Decibel.app
```

The project uses **Sign to Run Locally** (ad-hoc signing), so it needs no Apple developer account.

### Permission

On macOS 14.2 and later, Decibel reads the system audio mix through a **Core Audio process tap**. It only needs **System Audio Recording Only** (System Settings → Privacy & Security → Screen & System Audio Recording, bottom section). Your screen is not captured, so macOS shows no screen-sharing indicator. On macOS 14.0–14.1 the app falls back to ScreenCaptureKit, which needs the full screen-recording permission.

The bundle ID is still `local.hearing.app` from the app's first name, so the permission you already granted carries over. The app is signed with a fixed designated requirement (`Signing/designated.req`: `identifier "local.hearing.app"`), so the permission survives rebuilds. If capture is ever refused even though the app is switched on, reset it and grant access again:

```bash
tccutil reset All local.hearing.app
```

### Launch at login

Launch at login is turned on automatically the first time the app runs from `/Applications`. You can toggle it in the panel's ⚙︎ menu. If the app is started at login it stays in the menu bar. If you start it yourself, the panel opens.

### Self-test

```bash
/Applications/Decibel.app/Contents/MacOS/Decibel --selftest
```

The self-test checks the A-weighting filter against IEC 61672 values, the 1 s meter and the −60 dBFS silence floor, the default device profiles, the SPL formula, the dose maths, a SQLite round-trip on a temporary database, and the calibration noise level.

## How it works

| Step | Detail |
|---|---|
| Capture | A private global process tap (`CATapDescription`, excluding Decibel's own process) inside a private aggregate device on the default output's clock. It is rebuilt when the output device changes. Audio is never stored, only levels. |
| Level | A-weighted RMS (three biquads, pre-warped bilinear transform) over each 1 s window, as `dBFS = 10·log10(mean square)`. Windows below −60 dBFS count as silence and are ignored. |
| Device | CoreAudio default output device: name, UID, transport type (built-in, Bluetooth, USB, HDMI, AirPlay…), volume scalar and mute, followed live. The device's own scalar→dB curve is used when it exposes one; otherwise `20·log10(scalar)`. Nothing is logged while the output is muted or at zero volume. |
| Estimate | `dB(A) SPL = dBFS + volume (dB below max) + device offset` |
| Profiles | Created the first time a device is seen. Default offsets: headphones (AirPods, WH-1000XM5 and similar) **100 dB**, Mac speakers **80 dB** (at about 50 cm), other speakers **85 dB**. Tap a device in the panel to change its type or offset. |
| Storage | One row per minute per device: `minutes(ts, device_uid, avg_db, seconds, energy)` in `~/Library/Application Support/Decibel/decibel.sqlite` (WAL). Written every 10 s and on quit. Data from the old "Hearing" folder is moved over automatically. |
| Dose | Weekly limit as defined by Apple/WHO: 80 dB(A) for 40 h = 100%, 3 dB exchange rate, rolling 7 days. You get a notification at 100% (re-armed once the dose drops below 95%). |
| Charts | **D** shows hourly bars. **W, M, 6M and Y** show one bar per day. Bars at 80 dB or above are orange. |

### Calibration

Open the calibration page from the dial button in the panel's footer. Set your usual volume and play pink noise at −20 dBFS RMS. Measure with an SPL meter app or Apple Watch Noise at your listening position for speakers. For headphones, measure at the ear. Enter the reading in the app. The panel stays open while you calibrate. Decibel works out the A-weighted level of the noise itself, because its own output is excluded from capture, and stores:

```
offset = measured − (A-weighted noise dBFS + volume dB)
```

## Inspect the log

```bash
sqlite3 ~/Library/Application\ Support/Decibel/decibel.sqlite \
  "select datetime(ts,'unixepoch','localtime'), device_uid, round(avg_db,1), seconds from minutes order by ts desc limit 20;"
```

```bash
/usr/bin/log show --last 10m --info --predicate 'subsystem == "local.decibel.app"' --style compact
```

## Limits

These numbers are **estimates**, not measurements. They assume the device's volume curve is accurate and that the offset matches how you actually use the device (fit, distance, EQ, noise cancelling). Calibration removes most of that error. Decibel is not a medical device.

## Project layout

```
Decibel.xcodeproj
Decibel/
  DecibelApp.swift            AppKit entry, menu bar item, panel (NSPopover)
  AppModel.swift              ties capture, devices, storage, dose and notifications together
  Updater.swift               GitHub Releases update check and in-place install
  SelfTest.swift              --selftest
  Audio/                      process tap (ScreenCaptureKit fallback), A-weighting, meter, device monitor, pink noise
  Data/                       SQLite wrapper, store/queries, models (profiles, dose, ranges)
  UI/                         panel, calibration and device pages, theme
Support/Info.plist            NSAudioCaptureUsageDescription
Signing/designated.req        stable code-signing requirement (keeps the permission across builds)
scripts/release.sh            build + GitHub release
scripts/install.sh            one-line install of the latest release
```
