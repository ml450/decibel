# Decibel

A macOS menu bar app (macOS 14+, SwiftUI and Swift Charts) that estimates your listening exposure for each output device, in the style of the Hearing section of Apple Health.

The menu bar shows an ear icon and the live level, coloured **green** (or your accent colour) below 80 dB, **yellow** from 80 to 90 dB and **red** above 90 dB. Clicking the icon opens a compact panel, like Dropbox's, with two tabs:

- **Hearing:** the live level and volume slider for the current device, what's playing in Spotify or Music (with controls), a D/W/M/6M/Y chart of average levels, and per-device time and averages.
- **Loudness:** a LUFS meter (ITU-R BS.1770 / EBU R128) with momentary, short-term and true-peak bars, integrated loudness and loudness range, measured against −14 LUFS (social media), −23 LUFS (broadcast) or your own named targets, for all audio or a single app.

The gear opens **Settings**: launch at login, the level in the menu bar, the accent colour (presets or a colour wheel), updates, sharing, uninstall and quit. Launching Decibel from Spotlight or Finder also opens the panel.

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

The self-test checks the A-weighting filter against IEC 61672 values, the 1 s meter and the −60 dBFS silence floor, the default device profiles, the SPL formula, the dose maths, a SQLite round-trip on a temporary database, the loudness meter against EBU Tech 3341/3342 cases, true peak, and update version comparison.

## How it works

| Step | Detail |
|---|---|
| Capture | A private global process tap (`CATapDescription`, excluding Decibel's own process) inside a private aggregate device on the default output's clock. It is rebuilt when the output device changes. Audio is never stored, only levels. |
| Level | A-weighted RMS (three biquads, pre-warped bilinear transform) over each 1 s window, as `dBFS = 10·log10(mean square)`. Windows below −60 dBFS count as silence and are ignored. |
| Device | CoreAudio default output device: name, UID, transport type (built-in, Bluetooth, USB, HDMI, AirPlay…), volume scalar and mute, followed live. The device's own scalar→dB curve is used when it exposes one; otherwise `20·log10(scalar)`. Nothing is logged while the output is muted or at zero volume. |
| Estimate | `dB(A) SPL = dBFS + volume (dB below max) + device offset` |
| Profiles | Created the first time a device is seen. Default offsets (dB(A) for a full-scale signal at max volume): headphones (AirPods, WH-1000XM5 and similar) **100 dB**, Mac speakers **95 dB** (music at max ≈ 80 dB at about 50 cm), other speakers **100 dB** (music at max ≈ 85 dB). Estimates under 10 dB count as silence. Click a device in the panel to change its type or offset by hand. |
| Storage | One row per minute per device: `minutes(ts, device_uid, avg_db, seconds, energy)` in `~/Library/Application Support/Decibel/decibel.sqlite` (WAL). Written every 10 s and on quit. Data from the old "Hearing" folder is moved over automatically. |
| Dose | Weekly limit as defined by Apple/WHO: 80 dB(A) for 40 h = 100%, 3 dB exchange rate, rolling 7 days, tracked in the background. You get a notification at 100% (re-armed once the dose drops below 95%). |
| Charts | **D** shows hourly bars. **W, M, 6M and Y** show one bar per day. Bars at 80 dB or above are orange. |

## Inspect the log

```bash
sqlite3 ~/Library/Application\ Support/Decibel/decibel.sqlite \
  "select datetime(ts,'unixepoch','localtime'), device_uid, round(avg_db,1), seconds from minutes order by ts desc limit 20;"
```

```bash
/usr/bin/log show --last 10m --info --predicate 'subsystem == "local.decibel.app"' --style compact
```

## Limits

These numbers are **estimates**, not measurements. They assume the device's volume curve is accurate and that the default offset matches how you actually use the device (fit, distance, EQ, noise cancelling); real levels can differ by several dB. Decibel is not a medical device.

## Project layout

```
Decibel.xcodeproj
Decibel/
  DecibelApp.swift            AppKit entry, menu bar item, panel (NSPopover)
  AppModel.swift              ties capture, devices, storage, dose and notifications together
  Updater.swift               GitHub Releases update check and in-place install
  SelfTest.swift              --selftest
  NowPlaying.swift            Spotify / Music track and controls (AppleScript)
  Audio/                      process taps (ScreenCaptureKit fallback), A-weighting, level and loudness meters, device monitor
  Data/                       SQLite wrapper, store/queries, models (profiles, dose, ranges)
  UI/                         panel, tiles, Loudness tab, Settings, device page, theme
Support/Info.plist            NSAudioCaptureUsageDescription
Signing/designated.req        stable code-signing requirement (keeps the permission across builds)
scripts/release.sh            build + GitHub release
scripts/install.sh            one-line install of the latest release
```
