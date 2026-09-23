# iOS 27 device validation: power, battery temperature, PiP and Live Activity

This checklist is for the personal MiniWatts build on an iPhone 18 Pro Max
(`iPhone19,7`). CI can test the app-owned state policy, but cannot prove that
iOS actually displayed a PiP window or Dynamic Island content.

## Paired high-power sample

1. Use the same cable and charger for each run. Record the charger's displayed
   watts and the MiniWatts watts at the same clock second, especially above
   30 W and again below 20 W. Note battery percentage and whether the screen is
   locked. A charger meter and a phone-internal rail may measure different
   boundaries, so a mismatch alone does not prove which one is wrong.
2. While the mismatch is visible, open **Problem report**, tap **Mark problem
   time**, then export within one minute. The report now includes 45 recent
   one-second electrical samples plus ten-second persisted checkpoints. It
   records both copies of `Charger VQ0u` and `IQ0u`, unvalidated `QQ0u` and
   `WQ0u`, the chosen input/battery-side value, and ActivityKit timings.
3. Repeat after unplugging and reseating the cable. Do not infer a replacement
   formula from one charge phase. An alternative sensor path needs multiple
   paired traces that agree across charge level and negotiated PD profile.

## Battery temperature

The current number remains the hottest battery-labelled HID sensor. The Thermal
page shows the gas-gauge range and median when repeated sensors differ by at
least 3 °C. This is a source warning, not an automatic correction. The iOS
thermal state is an independent OS verdict, not a conversion of those degrees.
Mark and export a report while the split is present; each raw sensor retains its
service-list index so same-named readings stay distinguishable.

## PiP and Live Activity coexistence

1. Turn on Live Activity and start the visible PiP. Background MiniWatts for at
   least three minutes. Confirm both surfaces remain visible and both numbers
   change when the sensor value changes. A returned ActivityKit update alone is
   not proof of a rendered island frame.
2. Repeat with the hidden 0.1 pt PiP mode. Return to MiniWatts and verify that
   stopping, restoring and restarting PiP do not disable the Live Activity.
3. Force-quit with PiP open, relaunch, and try opening PiP again. Check that the
   start control cannot spin indefinitely. Export a report immediately if it
   fails; the `coexistence` events join scene, PiP, ActivityKit and sample age.
4. End PiP while keeping Live Activity enabled. Sampling may pause in the
   background: ActivityKit does not by itself grant continuous sensor access.

Never include charger serial numbers or other private accessory data in a shared
report. The built-in report deliberately exports only an allowlist of readings.

## History safety and first-page scrolling

1. After installing the new build, open History and confirm existing sessions are
   still present. Leave the app during a charge, return and unplug; the finished
   session should persist across a full app restart. If History shows a recovery or
   write warning, export a problem report before trying a reinstall. Do not delete
   the app, because that also deletes its local Application Support history.
2. On the first page, scroll continuously for 15–20 seconds once on battery and
   once while charging/PiP is running. Export a problem report. The `scroll` events
   give median and 95th-percentile `CADisplayLink` callback gaps together with Low
   Power Mode and thermal state. They are a clue to main-run-loop stalls, not a
   measurement of actual presented frames.
3. For a real 120 Hz claim, capture a Release build on the phone with Instruments
   Core Animation and Time Profiler while repeating the same scroll. Compare
   before/after hitches, frame rate, Core Animation commits and main-thread work.
