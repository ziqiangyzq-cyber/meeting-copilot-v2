#!/bin/bash
set -euo pipefail
# Run from the client root. Never installs or changes system tools.
swift build --configuration debug --scratch-path .build --cache-path .cache -Xswiftc -module-cache-path -Xswiftc .module-cache
app="$PWD/build/Meeting Copilot.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp text-mode-config.json "$app/Contents/Resources/text-mode-config.json"
cp .build/debug/MeetingCopilot "$app/Contents/MacOS/MeetingCopilot"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist >/dev/null
cp Info.plist "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app"
echo "BUILT_APP=$app"
