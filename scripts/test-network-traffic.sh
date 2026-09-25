#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build=$(mktemp -d)
trap 'rm -rf "$test_build"' EXIT
swiftc -swift-version 6 -parse-as-library \
  MiniWatts/Core/Sensors/NetworkTrafficReader.swift \
  Tests/NetworkTraffic/TrafficTests.swift -o "$test_build/network-tests"
"$test_build/network-tests"
