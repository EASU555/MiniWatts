#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build=$(mktemp -d)
trap 'rm -rf "$test_build"' EXIT
swiftc -swift-version 6 -parse-as-library \
  MiniWatts/Core/Model/EnergyAccumulator.swift \
  Tests/EnergyAccumulator/AccumulatorTests.swift -o "$test_build/energy-tests"
"$test_build/energy-tests"
