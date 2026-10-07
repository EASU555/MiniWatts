# Functional reliability iteration (B88)

## Scope and UI decision brief

- Job: keep one charging record through temporary sensor failures, and let the user inspect/export what was actually measured.
- Track: retain the existing branded native SwiftUI instrument dashboard, iOS 27 first. No visual redesign or new framework.
- Main object: the completed charging session; its readings and measured coverage remain the source of truth.
- Layout: History → existing session detail and curves → toolbar CSV share action → system share sheet.
- Hierarchy: export is a secondary action, separate from confirmed deletion. A preparing state prevents duplicate work; a local failure explains that export did not complete.
- Typography/materials: retain system text styles, SF Symbols, existing semantic palette and native toolbar. Missing readings use a muted dash, never a fabricated zero.
- Motion: native navigation/share transitions only; no new tick-driven animation.
- Restraints: no automatic upload, no new power/temperature formula, no inference of missing readings, no changes to the personal Live Activity/PiP lifecycle.

## Data contracts

- External power is observed as connected, disconnected, or unknown. Only explicit disconnection ends a session. Unknown readings break integration continuity instead of extrapolating over the failure.
- Pausing disables all sampling entry points before cancelling the tick. Late callbacks/results cannot publish until the next explicit start.
- Session/sample battery percentages can be absent. The first valid reading establishes the percentage baseline; an unavailable endpoint has no known percentage gain.
- Total coverage counts the union of measured intervals, once per interval. Per-channel coverage and paired energy remain separate.
- History summaries distinguish unmeasured energy from a measured zero. Old non-optional percentages still decode; previously fabricated data cannot be retrospectively recovered.
- CSV contains session metadata and the saved curve, not a claim of continuous 1 Hz raw evidence. Blank numeric cells mean unavailable; pauses and retained-sample gaps are not interpolated.

## Validation

Run existing recovery/report/sensor/network/storage checks plus new sampling, percentage/summary and CSV tests, then build both app and extension. Check Simplified Chinese copy and bundle build metadata. Device-only checks remain: a short sensor dropout must not split a charging session; explicitly unplugging must still close it; exports must share correctly; paused background callbacks must not advance sampling. No on-device success is claimed from the Windows host.
