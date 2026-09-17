#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Checking property lists and string catalogs"
plutil -lint MiniWatts-Info.plist
plutil -lint MiniWattsLiveActivity/Info.plist

echo "Checking app and extension release metadata"
grep -q '<string>$(MARKETING_VERSION)</string>' MiniWatts-Info.plist
grep -q '<string>$(CURRENT_PROJECT_VERSION)</string>' MiniWatts-Info.plist
grep -q '<string>$(MARKETING_VERSION)</string>' MiniWattsLiveActivity/Info.plist
grep -q '<string>$(CURRENT_PROJECT_VERSION)</string>' MiniWattsLiveActivity/Info.plist
grep -q '<key>NSSupportsLiveActivities</key>' MiniWatts-Info.plist

app_targets=$(grep -c 'IPHONEOS_DEPLOYMENT_TARGET = 17.0;' MiniWatts.xcodeproj/project.pbxproj)
if [ "$app_targets" -lt 4 ]; then
  echo "Expected the project and both targets to retain their explicit deployment target."
  exit 1
fi

echo "Checking Simplified Chinese coverage for user-facing strings"
python3 - <<'PY'
import json
from pathlib import Path

for path in [Path("MiniWatts/Localizable.xcstrings"),
             Path("MiniWattsLiveActivity/Localizable.xcstrings")]:
    data = json.loads(path.read_text(encoding="utf-8"))
    missing = []
    for key, value in data.get("strings", {}).items():
        if not key or value.get("shouldTranslate") is False:
            continue
        unit = value.get("localizations", {}).get("zh-Hans", {}).get("stringUnit", {})
        if not unit.get("value"):
            missing.append(key)
    if missing:
        print(f"{path}: missing zh-Hans translations:")
        for key in missing:
            print(f"  - {key}")
        raise SystemExit(1)

print("Quality checks passed")
PY
