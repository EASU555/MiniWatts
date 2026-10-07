#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build=$(mktemp -d)
trap 'rm -rf "$test_build"' EXIT
swiftc -swift-version 6 -parse-as-library \
  MiniWatts/Core/Model/SensorSamplingPolicy.swift \
  MiniWatts/Core/Model/BatteryGaugeSummary.swift \
  MiniWatts/Core/Model/PowerSnapshot.swift \
  MiniWatts/Core/Widgets/ChargeReading.swift \
  Tests/SamplingPolicy/SensorStubs.swift \
  Tests/SamplingPolicy/SamplingTests.swift -o "$test_build/sampling-tests"
"$test_build/sampling-tests"
