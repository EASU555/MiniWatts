# PowerLab

PowerLab is a separate, sideload-only iPhone experiment for validating whether
the power rails visible to MiniWatts can provide a trustworthy discharge-power
reading on a real device. Its bundle identifier is `com.easu555.PowerLab`, so it
can be installed beside MiniWatts without replacing it.

## Decision brief

- Track: system-like native SwiftUI.
- App shape: monitoring cockpit, not a general dashboard.
- Main object: one power number with its source, confidence and measurement mode.
- Secondary surfaces: every raw voltage/current channel, then the controlled test
  and CSV export workflow.
- States: measured, percentage-average fallback, collecting, external power,
  unavailable, recording and thermal-stop.
- Restraints: never derive watts from voltage alone; never label a percentage-rate
  average as real time; never merge experimental channel names into MiniWatts
  before a device trace confirms them.

## Estimator

1. Sample IOKit, powerd and Apple vendor HID sensors once per second.
2. Build independent power candidates from registry voltage/current, powerd
   voltage/current, the known HID battery rail, and same-rail HID pairs.
3. Reject battery-output candidates outside 2.5...5.0 V, 0.003...8 A or above 35 W.
4. Prefer registry, powerd, then the known HID battery rail.
5. Median-filter five samples and apply a three-second exponential smoother.
6. Report continuity-based confidence separately from source identity.
7. If no current survives, estimate only a multi-percent average with linear
   regression. Voltage remains diagnostic and never creates an instantaneous
   watt value.

## Device test

1. Unplug the charger and keep PowerLab in the foreground.
2. Start a recording with the **Idle baseline** marker and wait about two minutes.
3. Run the built-in 30-second CPU load.
4. Confirm whether one current channel and its power candidate rise with the load
   and return toward baseline afterward.
5. Stop the recording and share the CSV. The file contains every candidate and
   every raw HID power channel, not only the automatically selected one.

This build uses private iOS interfaces inherited from MiniWatts and is not an App
Store target.
