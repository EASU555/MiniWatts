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
  MiniWatts/Core/Model/PowerSnapshot.swift \
  MiniWatts/Core/Model/ChartDomain.swift \
  MiniWatts/Core/Model/TemperatureHistory.swift \
  MiniWatts/Core/Model/TemperatureHistoryStore.swift \
  MiniWatts/Core/TemperatureHistoryController.swift \
  Tests/TemperatureHistory/HistoryTests.swift -o "$test_build/temperature-history-tests"
"$test_build/temperature-history-tests"
