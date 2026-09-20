#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build=$(mktemp -d)
# The mock frameworks are confined to this temporary test executable. The iOS
# build continues to link Apple's real ActivityKit and UIKit frameworks.
swiftc -swift-version 6 -emit-module -emit-library -module-name ActivityKit \
  Tests/LiveActivityRecovery/ActivityKit.swift -o "$test_build/libActivityKit.dylib" \
  -emit-module-path "$test_build/ActivityKit.swiftmodule"
swiftc -swift-version 6 -emit-module -emit-library -module-name UIKit \
  Tests/LiveActivityRecovery/UIKit.swift -o "$test_build/libUIKit.dylib" \
  -emit-module-path "$test_build/UIKit.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$test_build" -L "$test_build" \
  -lActivityKit -lUIKit -Xlinker -rpath -Xlinker "$test_build" \
  MiniWatts/Core/LiveActivity/MiniWattsActivityAttributes.swift \
  MiniWatts/Core/LiveActivity/ChargingLiveActivityController.swift \
  Tests/LiveActivityRecovery/RecoveryTests.swift -o "$test_build/recovery-tests"
"$test_build/recovery-tests"
