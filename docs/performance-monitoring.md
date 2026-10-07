# Performance pass: live monitoring without slower readings

## Decision brief

Keep the established native SwiftUI instrument panel and all controls where they
are. The primary job is still watching fresh electrical/thermal readings and
recovering Live Activity or PiP without restarting the app. This is a computation
and update-boundary pass, not a visual redesign.

```text
[version / settings]
[live power instrument]
[Live Activity and PiP controls]
[battery / power path / rolling chart]
```

Typography remains the existing rounded readouts, system UI text and monospaced
technical labels. Existing Dynamic Type, accessibility labels, missing-reading
dashes and recovery states remain. Motion budget: subtle, with no new tick-driven
animation or custom scrolling.

## Scope and invariants

- Keep one-second sensor sampling, existing Live Activity cadence and five-second
  historical samples. Do not alter sensor formulas, session continuity or energy
  accumulation to reduce CPU work.
- Prepare each chart series/domain once per body evaluation. In particular, a
  throttling marker must not rescan all samples to compute the same Y ceiling.
- Skip rebuilding the in-progress historical chart when only its live totals
  change and its recorded samples/height are unchanged.
- Store recent diagnostic traces as immutable values; defer their detailed text
  formatting to export or the existing report utility queue. Keep the same trace
  fields, retained order, capacity and persistence cadence.
- Eliminate repeated PiP option work for identical assignments and duplicate
  source layout. Retain source attachment, startup recovery, frame cadence and
  the already-gated hidden/off video rendering path.
- Stop repeating `IOPSCopyChargeStatus` after its explicit sandbox denial in
  this process. Keep the error for diagnosis; success and transient failures
  still permit reads. Registry, powerd battery/adapter and HID sampling continue.

## Verification

Use deterministic tests for chart domains, finite/missing/zero values and exact
diagnostic formatting, plus all existing sampling/history/recovery/CSV tests.
Compile the app and widget in Release and verify the downloaded artifact's build
number. Tests are not on-device performance measurements.

For a device comparison, use the same iOS 27 phone, charger, recording duration,
PiP mode and scroll gesture. Capture Time Profiler/Allocations and SwiftUI view
updates for dashboard scrolling and a long in-progress history. Compare main
thread work, frame hitches and chart updates; keep sampling/report traces to
confirm freshness. A CADisplayLink callback rate alone is not proof of rendered
120 FPS. No CPU, battery or FPS improvement is claimed without this measurement.
