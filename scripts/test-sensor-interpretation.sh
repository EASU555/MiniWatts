#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build=$(mktemp -d)
trap 'rm -rf "$test_build"' EXIT
swiftc -swift-version 6 -parse-as-library \
  MiniWatts/Core/Model/Formatting.swift \
  MiniWatts/Core/Sensors/HIDSensors.swift \
  MiniWatts/Core/Sensors/SensorCatalog.swift \
  MiniWatts/Core/Model/BatteryGaugeSummary.swift \
  MiniWatts/Core/Model/LevelRateCheck.swift \
  MiniWatts/Core/Model/PowerSnapshot.swift \
  MiniWatts/Core/Model/EnergyAccumulator.swift \
  MiniWatts/Core/Widgets/ChargeReading.swift \
  Tests/SensorInterpretation/InterpretationTests.swift -o "$test_build/interpretation-tests"
"$test_build/interpretation-tests"
