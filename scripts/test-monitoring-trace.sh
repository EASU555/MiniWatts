#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build=$(mktemp -d)
trap 'rm -rf "$test_build"' EXIT
swiftc -swift-version 6 -parse-as-library \
  MiniWatts/Core/Model/MonitoringTrace.swift \
  MiniWatts/Core/Diagnostics/ProblemReportRecorder.swift \
  Tests/MonitoringTrace/MonitoringTraceTests.swift -o "$test_build/monitoring-trace-tests"
"$test_build/monitoring-trace-tests"
