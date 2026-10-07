#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build=$(mktemp -d)
trap 'rm -rf "$test_build"' EXIT
swiftc -swift-version 6 -parse-as-library \
  MiniWatts/Core/Model/ChartDomain.swift \
  MiniWatts/Core/Sensors/ChargeStatusReadPolicy.swift \
  Tests/PerformancePolicy/PerformancePolicyTests.swift -o "$test_build/performance-tests"
"$test_build/performance-tests"
