# Useful island telemetry

## UI decision brief

- Existing branded SwiftUI instrument panel; no app/navigation redesign.
- Native display pickers retain left, right and minimal-island independence.
- New choices: cell charging watts, observed charge gain (%), system thermal
  pressure, charge-IC temperature, wireless-coil temperature. Extra component
  choices require an available reading, but an existing selection is never lost.
- Layout: compact `[left reading/icon] [right reading]`; minimal `[one complete
  value]`; expanded `[selected metric] [four original metrics] [two context rows]`.
- System typography, monospaced digits, existing metric palette, SF Symbols.
  Pressure colours follow its actual state. No numeric rolling animations added.
- Direction arrows are optional. Narrow minimal alternatives drop precision,
  then the arrow/unit before permitting number truncation. Status text can fall
  back to a thermal symbol. A missing reading is a dash, not a measured zero.
- Context rows carry power provenance/incomplete-input evidence, app sample
  receipt time, observed percentage gain, one temperature slope and thermal
  pressure. VoiceOver labels identify measurement types and units.
- Stale activities keep their paused treatment. No change to ActivityKit/PiP
  recovery, refresh cadence, hidden 0.1 pt carrier or background execution.

## Semantics

`Charge gained (%)` is **percentage points**, not relative percentage increase,
not Wh divided by nominal battery capacity, and not an integrated coulomb count.
For a first observed system level of 53% and a current system level of 61%, show
`+8%`. Consumption offsets the increase; a level below the baseline shows `+0%`.
The baseline is the current `ChargeSession`'s first available system percentage.
An app opened partway through charging cannot reconstruct the earlier gain.
Pause/resume retains that baseline; a confirmed unplug ends it. Unknown connection
or missing endpoints suppress the live gain. A force-quit starts a new observed
session on reopening, consistent with existing history recovery. Existing charge
history schema and integration remain unchanged.

`Power into battery` requires confirmed external power and a finite, nonnegative
cell-side measurement. Zero is legitimate; an absent/negative rail is unavailable,
not rectified into charging power. This is not whole-device discharge power.
`partialInputWatts` remains unscaled diagnostic evidence. No full-input wattage is
reconstructed from that partial reading.

Temperature trends use least-squares slopes over at most 120 seconds and 180
points, with at least 60 seconds and 13 observations required. Each adjacent
interval must be at most five seconds. A missing/invalid value, backwards clock,
explicit pause or source change clears the affected window. Duplicate timestamps
are ignored. Direction uses a ±0.15 °C/min deadband. HID battery medians retain
the identity set; registry precedence and a change in hottest-source identity
reset the corresponding slope. A trend is about the sensor reading, not proof
that its component mapping or absolute temperature is accurate.

Thermal pressure is directly mapped from `ProcessInfo.thermalState`. It is not
derived from a temperature threshold and is not a measurement of CPU throttling.
Sample time is app receipt time, not a sensor hardware timestamp or proof that iOS
redrew the island. The existing 30-second stale deadline is anchored to that sample
receipt time, so changing a display option cannot freshen an old sample.
The telemetry payload is optional and sample-identity checked,
so older persisted activities still decode and old summaries cannot cross ticks.

## Verification

`bash scripts/test-island-telemetry.sh` compiles production models against the
ActivityKit protocol mock, checking trend bounds/gaps/provenance, direct percentage
endpoints, cell watts, optional decoding, menu parity and payload size. The existing
recovery harness also exercises real controller publication and live option changes.
CI builds the actual app and WidgetKit targets with Apple's frameworks.

On iOS 27 / iPhone 18 Pro Max, still verify:

1. Existing left/right/minimal selections survive installation. Each new selection
   takes effect without restarting PiP, including an already hidden carrier.
2. Observe 53% → 61% as `+8%`; missing endpoints produce a dash. Pause/resume keeps
   the baseline, while unplug/replug starts a new observed session.
3. Trend warm-up, source changes and background suspension do not create spikes.
   Compare displayed direction and °C/min with exported telemetry diagnostics.
4. Compact, limited-width and two/three-activity minimal layouts remain readable
   in Chinese/English; verify large text, VoiceOver and reduced motion on device.
5. Confirm expanded/Lock Screen row height and clipping with actual iOS layouts.
   Compilation/model tests alone cannot establish these visual outcomes.
