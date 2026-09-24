# MiniWatts

**English** · [简体中文](README.zh-Hans.md)

[![Build](https://github.com/EASU555/MiniWatts/actions/workflows/build.yml/badge.svg?branch=feature%2Flive-activity)](https://github.com/EASU555/MiniWatts/actions/workflows/build.yml?query=branch%3Afeature%2Flive-activity)

> **Personal Build 19 fork.** This repository is derived from
> [ResistanceTo/MiniWatts](https://github.com/ResistanceTo/MiniWatts) and keeps its
> original attribution and licence. This personal branch adds configurable Dynamic
> Island telemetry, selectable component temperatures, system thermal state and a
> Picture in Picture floating monitor. These additions are maintained independently
> and are not endorsed or supported by the upstream author.

An iPhone battery and charging monitor built on Apple's private APIs. It reads the
phone's own power-management sensors — the ones iOS uses to run the charge — and shows
what the charger is delivering, how much of it reaches the cell, the difference
(including phone power use and conversion losses), and what every temperature
sensor in the phone is doing while it happens.

| Power | Thermal | Adapter | History |
|:-:|:-:|:-:|:-:|
| <img src="docs/screenshots/power.jpg" width="200" alt="Power"> | <img src="docs/screenshots/thermal.jpg" width="200" alt="Thermal"> | <img src="docs/screenshots/adapter.jpg" width="200" alt="Adapter"> | <img src="docs/screenshots/history.jpg" width="200" alt="History"> |

The manually enabled Live Activity can put charging power, SoC temperature, battery
temperature or the hottest component in the Dynamic Island and on the Lock Screen,
whether or not a charger is currently connected. Choose the compact readout in
Settings; press and hold the Island to see all four.

Settings also has a user-started floating monitor built with system Picture in
Picture. Its generated video surface refreshes every second and can show charging
power, SoC, battery, charger and hottest-component temperatures. Power and
temperatures can be enabled independently; when both are enabled they can share one
screen or alternate as separate pages. While this window is open, its Picture in
Picture background mode keeps sensor sampling active.

Build 19 also uses a silent background-audio session to attempt frequent Live Activity
updates after the app leaves the foreground. iOS still controls scheduling and may
throttle, pause, dismiss or eventually end the activity. Keeping background sampling
active consumes additional battery; disable the Live Activity and close the floating
monitor when you no longer need them.

> **Sideload only.** Private APIs mean this can never be on the App Store — you sign
> and install it yourself. There is no network code of any kind: nothing it reads
> leaves your phone.

## Install

Download `MiniWatts-1.0.1-build19-unsigned.ipa` from this fork's
[Releases](https://github.com/EASU555/MiniWatts/releases) and sign it with your own
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

The original MiniWatts work is Copyright 2026 ZhaoHe Studio. The personal-fork
modifications and their scope are identified in [NOTICE](NOTICE) and in this
repository's commit history.

Private APIs can change or disappear in any iOS update.
