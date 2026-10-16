#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build=$(mktemp -d)
trap 'rm -rf "$test_build"' EXIT
swiftc -swift-version 6 -emit-module -emit-library -module-name ActivityKit \
  Tests/LiveActivityRecovery/ActivityKit.swift -o "$test_build/libActivityKit.dylib" \
  -emit-module-path "$test_build/ActivityKit.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$test_build" -L "$test_build" \
  -lActivityKit -Xlinker -rpath -Xlinker "$test_build" \
  MiniWatts/Core/LiveActivity/MiniWattsActivityAttributes.swift \
  MiniWatts/Core/Model/Formatting.swift \
  MiniWatts/Core/Sensors/HIDSensors.swift \
  MiniWatts/Core/Sensors/SensorCatalog.swift \
  MiniWatts/Core/Model/BatteryGaugeSummary.swift \
  MiniWatts/Core/Model/PowerSnapshot.swift \
  MiniWatts/Core/Model/EnergyAccumulator.swift \
  MiniWatts/Core/Model/ChargeSession.swift \
  MiniWatts/Core/Model/TemperatureTrendWindow.swift \
  MiniWatts/Core/Model/IslandTelemetryTracker.swift \
  Tests/IslandTelemetry/TelemetryTests.swift -o "$test_build/telemetry-tests"
"$test_build/telemetry-tests"
