#!/bin/sh
# Build DropHon.app (universal: Apple silicon + Intel), install to ~/Applications, zip to dist/
set -e
cd "$(dirname "$0")"
APP="DropHon.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
rm -rf "$APP" build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14.0 main.swift -o build/DropHon-$arch
done
lipo -create build/DropHon-arm64 build/DropHon-x86_64 -output "$APP/Contents/MacOS/DropHon"
"$APP/Contents/MacOS/DropHon" --selftest
cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"
xattr -cr "$APP"  # strip extended attributes so the zip has no ._ files
codesign -s - --force "$APP"
mkdir -p ~/Applications dist
rm -rf ~/Applications/"$APP" ~/Applications/"Hon Shelf.app"
cp -R "$APP" ~/Applications/
ditto -c -k --norsrc --noextattr --keepParent "$APP" "dist/DropHon-$VERSION.zip"
echo "installed: ~/Applications/$APP · package: dist/DropHon-$VERSION.zip"
