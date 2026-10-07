# Monitoring UX iteration (B86)

## UX decision brief

- Job: check live power/temperature and start off-screen monitoring without hunting through diagnostics.
- User: returning, daily iPhone user; preferences are reversible, history deletion is destructive.
- Pattern: instrument dashboard with a priority stack and progressive disclosure.
- Path: existing dial and battery readings → Live Activity/PiP controls → actual runtime feedback.
- Recovery: retry beside the failed presentation; export evidence without force-quitting first.
- States: no sample, fresh/delayed/old sample, disabled permission, idle/starting/stopping/failed presentation, preparing/ready/failed report, unreadable history.
- Constraints: retain all personal options and B85 lifecycle handling; do not change sensor formulas, sample cadence, or stored data.

## UI decision brief

- Track: existing branded native SwiftUI, iOS 27 first. Retain the measurement grid, dial, palette, tabs and SF Symbols.
- Composition: instrument panel. Readings remain first; frequently used presentation controls precede charts and raw diagnostics.
- Layout: dial + freshness → battery → Live Activity status/toggle → PiP status/start/hide → power path/charts/history → collapsed battery diagnostics.
- Hierarchy: one normal start/stop action per panel; configuration and long explanations disclose on demand. Recovery remains available and is prominent on failure.
- Type: system text styles for controls/statuses, monospaced measurements. Larger accessibility text stacks picker labels above selections.
- Motion: minimal native disclosure/navigation only. No tick-triggered animation; Reduce Motion disables the existing backdrop glow transition.
- Distinctive anchor: the existing calibrated power dial. No new artwork, web-style chrome, or dependency.
- Trust: activity acceptance does not prove Dynamic Island visibility; freshness describes receipt of a sample, not calibration accuracy or rendered FPS.

## Validation

Build the app/extension and run existing policy, recovery, recorder, storage and energy checks. Check new Simplified Chinese keys. On-device QA still needed for large text/VoiceOver, Live Activity + PiP coexistence, and hidden-window restoration; do not claim these passed from a Windows host.
