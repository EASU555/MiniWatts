#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build=$(mktemp -d)
trap 'rm -rf "$test_build"' EXIT
swiftc -swift-version 6 -parse-as-library \
  MiniWatts/Core/Model/ChargeForecast.swift \
  Tests/ChargeForecast/ForecastTests.swift -o "$test_build/forecast-tests"
"$test_build/forecast-tests"
