#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build=$(mktemp -d)
trap 'rm -rf "$test_build"' EXIT
swiftc -swift-version 6 -parse-as-library \
  MiniWatts/Core/Model/BatteryGaugeSummary.swift \
  MiniWatts/Core/Model/BackgroundSamplingPolicy.swift \
  Tests/SensorEvidence/PolicyTests.swift -o "$test_build/policy-tests"
"$test_build/policy-tests"
