#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build=$(mktemp -d)
trap 'rm -rf "$test_build"' EXIT
swiftc -swift-version 6 -parse-as-library \
  MiniWatts/Core/Model/ChargeSession.swift \
  Tests/SessionStore/SessionStoreTests.swift -o "$test_build/session-store-tests"
"$test_build/session-store-tests"
