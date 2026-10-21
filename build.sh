#!/bin/bash
# Build + install My Flow.app into /Applications.
#
# Optional environment variables:
#   MYFLOW_SIGN_IDENTITY  Code-signing identity (default: "MyFlow Dev Signing").
#                         If it isn't in your keychain, the app is ad-hoc signed,
#                         and macOS may ask for permissions again after each rebuild.
#   MYFLOW_BUNDLE_ID      Bundle identifier (default: com.harry.myflow).
set -e
cd "$(dirname "$0")"

SIGN_IDENTITY="${MYFLOW_SIGN_IDENTITY:-MyFlow Dev Signing}"
BUNDLE_ID="${MYFLOW_BUNDLE_ID:-com.harry.myflow}"

swift build -c release

APP="/Applications/My Flow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>My Flow</string>
    <key>CFBundleDisplayName</key>       <string>My Flow</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>           <string>3.0</string>
    <key>CFBundleShortVersionString</key><string>3.0</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleExecutable</key>        <string>MyFlow</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>26.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>My Flow records your voice to transcribe it into text.</string>
</dict>
</plist>
EOF

cp .build/release/MyFlow "$APP/Contents/MacOS/MyFlow"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# A stable signing identity keeps macOS permissions (Microphone, Accessibility)
# across rebuilds. Without one, fall back to ad-hoc signing.
if security find-identity -v -p codesigning | grep -q "\"$SIGN_IDENTITY\""; then
  codesign --force -s "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  echo "Signing identity \"$SIGN_IDENTITY\" not found; using ad-hoc signing."
  codesign --force -s - --identifier "$BUNDLE_ID" "$APP"
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Installed $APP"
