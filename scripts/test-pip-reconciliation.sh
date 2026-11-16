#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build=$(mktemp -d)
trap 'rm -rf "$test_build"' EXIT
swiftc -swift-version 6 -parse-as-library \
  MiniWatts/Core/Model/PictureInPictureReconciliationPolicy.swift \
  Tests/PictureInPictureRecovery/ReconciliationTests.swift -o "$test_build/pip-reconciliation-tests"
"$test_build/pip-reconciliation-tests"
