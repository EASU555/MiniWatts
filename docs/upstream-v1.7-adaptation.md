# Upstream v1.7 adaptation

This personal fork selectively adapts work from ResistanceTo/MiniWatts v1.7.0
([0b519fd](https://github.com/ResistanceTo/MiniWatts/commit/0b519fda61dfd7b766d4be05fdaa2114f295d5e4)),
Copyright 2026 ZhaoHe Studio, Apache License 2.0. The original licence and
attribution remain in LICENSE and NOTICE.

- The charging forecast uses the upstream taper weights. A separate tracker
  requires two observed level changes, and clears its estimate on an uncertain
  connection, a charging interruption, a source change or a sampling gap.
- Sensor classification recognizes upstream's CPU-cluster and joined-name
  categories. Historical temperature sources retain their existing gap markers.
- The iPad schematic borrows the upstream illustrative zone positions; iOS does
  not report physical sensor coordinates. Responsive two-column pages use lazy
  rows, while the customized home page keeps its existing control arrangement.
- Same-key sensor averaging is diagnostic only. The report includes the raw
  services and a candidate average without changing power, temperature, history,
  or Live Activity values. It does not infer or double an unmeasured rail.
- Fahrenheit is not included in this adaptation.
