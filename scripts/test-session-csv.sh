#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build=$(mktemp -d)
trap 'rm -rf "$test_build"' EXIT
swiftc -swift-version 6 -parse-as-library \
  MiniWatts/Core/Model/EnergyAccumulator.swift \
  MiniWatts/Core/Model/ChargeSession.swift \
  MiniWatts/Core/Model/SessionCSVExporter.swift \
  Tests/SessionCSV/SessionCSVTests.swift -o "$test_build/session-csv-tests"
# UTC timestamps and numeric output must not depend on the host's locale or zone.
TZ=Pacific/Honolulu LANG=de_DE.UTF-8 "$test_build/session-csv-tests"
