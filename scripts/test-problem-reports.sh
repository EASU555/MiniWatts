#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build=$(mktemp -d)
swiftc -swift-version 6 -parse-as-library \
  MiniWatts/Core/Diagnostics/ProblemReportRecorder.swift \
  Tests/ProblemReports/RecorderTests.swift -o "$test_build/report-tests"
"$test_build/report-tests"
