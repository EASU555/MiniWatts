# Temperature curves

## UI decision brief

- Existing branded native SwiftUI instrument panel, using Swift Charts. iOS 27
  remains the runtime priority. Do not change navigation, probes or AVKit hosting.
- Put the temperature curve directly after system state and CPU on the Thermal
  page, before the schematic map. History remains accessible without live sensors.
- Layout: `[component picker] [10m / 1h / 6h / 24h] [compare toggle] [temperature
  chart + time selection] [min / max / endpoint change] [recording/storage status]`.
- Five representative channels match the island: battery, SoC, charge IC, wireless
  coil and hottest. Keep one selected channel prominent; comparison is optional.
- Native pickers/toggles and chart selection; SF type, tabular digits, existing
  semantic palette. Series use labels and distinct dashes, not colour alone.
- No per-sample animation. Chart preparation is off the main actor and only while
  visible; bounded peak/valley-preserving plot reduction avoids huge mark counts.
- Show missing, loading, paused, failed-read, failed-write and recovered states.
  Clear history requires confirmation. Retry does not erase corrupt files.

## Data contract

The same existing one-second sensor tick supplies the history; there is no extra
sensor client, timer or background execution. Record an observed frame at most
every five seconds and retain the latest 24 hours (at most 20,000 frames). Never
interpolate missing readings into storage. Both charging and non-charging periods
are eligible. A missing power-connection observation alone is not missing thermal
data. Actual pauses, missed samples, missing component readings and source changes
break that component's line, including interruptions between stored frames.

History is a separate, versioned line-delimited JSON journal in Application Support.
Load, validation, encoding and primary/safety-copy checkpoints happen on a serial
utility queue. Each checkpoint appends only new frames, flushing the primary before
the safety copy. A torn append falls back to the complete safety copy, never a
silently accepted partial line. Initial creation, recovery, clear and at-most-hourly
expired-frame compaction replace both files atomically. The visible memory window
is 24 hours; expired disk frames can remain until hourly compaction (roughly 25
hours on disk, also bounded by the 20,000-frame cap). Do not write until a valid load;
merge any new observations recorded
while loading. Checkpoint every 30 seconds and on explicit sampling pause. A force
quit can lose the newest uncheckpointed frames; iOS suspension cannot be undone by
this chart feature. Old B95 three-minute samples cannot reconstruct older history.

Plot straight lines between continuous measured points, not smoothed overshoots.
Reduce display density per continuous segment/time bucket, keeping first/last,
minimum and maximum in timestamp order. Any pathological hard-cap reduction uses
isolated points, never a line bridging discarded segments. Summary statistics use
the unreduced valid observations. Selection is matched to an actual record within
five seconds; a selection in an unsampled gap must say so. The latest °C/min rate
comes from B95's existing live trend algorithm, not a second fitted history slope.

## Verification

The new model/store tests cover five-second cadence, source identity, interruptions
between stored frames, app restart, retention, merge-before-save, gaps, peak/valley
reduction, truthful statistics, gap selection and storage recovery/failures. The
existing island/recovery/sensor suites and actual app/extension Release build remain
in CI. Physical layout, native chart gestures, VoiceOver and iOS 27 background
sampling still require device verification.

Native chart selection reference: [Apple chartXSelection(value:)](https://developer.apple.com/documentation/swiftui/view/chartxselection(value:)).
