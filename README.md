# MiniWatts

**English** · [简体中文](README.zh-Hans.md)

[![Build](https://github.com/ResistanceTo/MiniWatts/actions/workflows/build.yml/badge.svg)](https://github.com/ResistanceTo/MiniWatts/actions/workflows/build.yml)

An iPhone battery and charging monitor built on Apple's private APIs. It reads the
phone's own power-management sensors — the ones iOS uses to run the charge — and shows
what the charger is delivering, how much of it reaches the cell, where the rest goes as
heat, and what every temperature sensor in the phone is doing while it happens.

| Power | Thermal | Adapter | History |
|:-:|:-:|:-:|:-:|
| <img src="docs/screenshots/power.jpg" width="200" alt="Power"> | <img src="docs/screenshots/thermal.jpg" width="200" alt="Thermal"> | <img src="docs/screenshots/adapter.jpg" width="200" alt="Adapter"> | <img src="docs/screenshots/history.jpg" width="200" alt="History"> |

While a charger is connected, a Live Activity can put charging power, SoC
temperature, battery temperature or the hottest component in the Dynamic Island and
on the Lock Screen. Choose the compact readout in Settings; press and hold the Island
to see all four.

Settings also has a user-started floating monitor built with system Picture in
Picture. Its generated video surface refreshes every second and can show charging
power, SoC, battery, charger and hottest-component temperatures. Power and
temperatures can be enabled independently; when both are enabled they can share one
screen or alternate as separate pages. While this window is open, its Picture in
Picture background mode keeps sensor sampling active. Otherwise sensor access stops
when iOS suspends the app and the Live Activity marks old data as paused.

> **Sideload only.** Private APIs mean this can never be on the App Store — you sign
> and install it yourself. There is no network code of any kind: nothing it reads
> leaves your phone.

## Install

Download the latest `MiniWatts-unsigned.ipa` from
[Releases](https://github.com/ResistanceTo/MiniWatts/releases) and sign it with your own
Apple ID — [Sideloadly](https://sideloadly.io), [AltStore](https://altstore.io),
[SideStore](https://sidestore.io) and Xcode all do this. A free Apple ID works; the app
then expires after seven days and you re-sign it.

Requires iPhone, iOS 17 or later.

## What it can't do

Only what iOS actually hands a sandboxed app. Battery health and cycle count are
filtered out of the registry; accessory batteries (Watch, AirPods) come back empty;
wireless charging exposes no input current, so on MagSafe you only see what reaches the
cell; discharge power has no sensor and is estimated from the percentage. Charging holds
can only be inferred, and the app labels them `inferred` when that is what happened.

## Build

Xcode 26 or later, iOS 17 deployment target, no dependencies.

```bash
./scripts/build-ipa.sh                             # unsigned, what Releases ships
TEAM_ID=ABCDE12345 ./scripts/build-ipa.sh signed   # signed, for your own device
```

[`CLAUDE.md`](CLAUDE.md) is the engineering notebook: which APIs the sandbox blocks and
how that was established, what each sensor turned out to be, and the Swift 6 isolation
traps this project has already fallen into.

## Licence

Apache 2.0 — see [LICENSE](LICENSE). The method for reading the PMU is derived from
[ios-charging-monitor](https://github.com/gregsramblings/ios-charging-monitor) (MIT);
`BatteryCenterBridge` owes two details to [Batsie](https://github.com/leptos-null/Batsie).
Both are credited in [NOTICE](NOTICE), which carries the upstream MIT notice.

Private APIs can change or disappear in any iOS update.
