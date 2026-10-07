#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build=$(mktemp -d)
trap 'rm -rf "$test_build"' EXIT
swiftc -swift-version 6 -parse-as-library \
  MiniWatts/Core/Model/EnergyAccumulator.swift \
  MiniWatts/Core/Model/ChargeSession.swift \
  MiniWatts/Core/Model/HistorySummary.swift \
  MiniWatts/Core/Model/SessionChartSeries.swift \
  MiniWatts/Core/Widgets/WidgetSnapshot.swift \
  Tests/HistoryIntegrity/HistoryTests.swift -o "$test_build/history-tests"
"$test_build/history-tests"
