# Selective v1.5.1 sensor interpretation on the personal B92 base

## UI decision brief

Keep the branded native SwiftUI instrument panel, system tabs, native disclosure
controls and the existing rounded readouts/system body/monospaced evidence. The
job is to distinguish a representative temperature or usable power reading from
raw sensor evidence, not to make the numbers look cooler or larger.

```text
[existing power instrument / monitoring controls]
[power path + conditional incomplete-input explanation]
[thermal map: representative battery temperature]
[indexed sensor rows / excluded-reading disclosure]
[local export: raw values + interpretation reasons]
```

No new tick animation, typography redesign or PiP/ActivityKit lifecycle changes.
Explanations wrap with Dynamic Type; sensor evidence is disclosed on demand.
Missing values remain dashes and no percentage is calculated from voltage.

## Source and scope

Adapt the sensor interpretation in ResistanceTo/MiniWatts commit
`3a27d400b1e180172e78dc46ebe3ae3974254e1a` (v1.5.1). Retain upstream attribution.
This is not a Git merge or wholesale replacement of the personal fork.

- Battery-zone HID representative becomes the median of eligible live readings.
  A valid registry temperature retains precedence on systems that expose it.
  The map/header/readout share that representative. The maximum remains an actual
  indexed source in the raw list and hottest-component ranking.
- When cell watts exceed sensed input by both 20% and 1.5 W, retain that product
  as partial evidence, not usable input. Battery-side fallback is labelled as such;
  integration and input-derived shares/utilisation receive nil, never doubled watts.
  This contradiction check cannot detect every incomplete measurement.
- Apply upstream's provisional temperature heuristics (zero, very cold tdev,
  unsupported high charge-die reading) to summaries, not raw storage. Surface the
  indexed raw readings and reasons in the Thermal page and exported report. These
  rules and the median are not a device-specific temperature calibration.
- Drop zero/negative/0xFFFF adapter profile dimensions, including the negotiated
  fallback. Retain the untouched adapter dictionary for diagnostics.
- Clarify port/coil versus battery power and system thermal pressure wording.

Do not import the upstream charger-bound Activity lifecycle, throttling, history
schema, pause-time rate retention, tab destruction or iPad changes in this pass.
The private input-sign convention, CPU/network counter baselines, direct system
battery percentage and B92 rendering optimizations remain unchanged.

## Verification

Compile tests against the actual snapshot, HID reading/catalog, compact reading
and energy accumulator types. Cover odd/even/single battery medians, retained hot
outliers, map/registry consistency, every exclusion with same-rail corroboration,
partial/ordinary/negative/zero power, margins, paired integration gaps, unknown
connection semantics and valid/invalid profiles. Run all prior suites, compile app
and extension, verify the unsigned artifact, and keep symbols for device crashes.

No iPhone is attached: raw-fixture tests and a successful build are not real-device
validation of iPhone 18 Pro Max sensor meanings or complete high-power input.
