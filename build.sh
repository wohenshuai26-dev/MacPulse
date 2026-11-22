#!/bin/zsh
# Builds MacPulse (Release) and installs it to /Applications.
set -euo pipefail
cd "${0:A:h}"

if [[ ! -f Config/Local.xcconfig ]]; then
  echo "找不到 Config/Local.xcconfig：請先執行"
  echo "  cp Config/Local.xcconfig.example Config/Local.xcconfig"
  echo "然後填入你的 DEVELOPMENT_TEAM（Team ID）與 MP_BUNDLE_PREFIX。"
  exit 1
fi
command -v xcodegen >/dev/null || { echo "需要 XcodeGen：brew install xcodegen"; exit 1; }

xcodegen generate --quiet
xcodebuild -project MacPulse.xcodeproj -scheme MacPulse -configuration Release \
  -derivedDataPath build -quiet build

APP=build/Build/Products/Release/MacPulse.app
osascript -e 'quit app "MacPulse"' 2>/dev/null || true
sleep 1
rm -rf /Applications/MacPulse.app
ditto "$APP" /Applications/MacPulse.app
# Keep only the installed copy registered, so Control Center loads the right extension.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
open /Applications/MacPulse.app
echo "已安裝到 /Applications/MacPulse.app"
