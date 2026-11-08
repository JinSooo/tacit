#!/bin/sh
# 用法：./build.sh <构建号> <selfsigned|adhoc>
set -e
cd "$(dirname "$0")"
N="$1"; SIGN="${2:-selfsigned}"
APP=build/Probe.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
echo "let BUILD = \"$N\"" > build/version.swift
swiftc -O main.swift build/version.swift -o "$APP/Contents/MacOS/probe"
swiftc -O child.swift -o "$APP/Contents/MacOS/probe-child"
sed "s/BUILD/$N/g" Info.plist > "$APP/Contents/Info.plist"
if [ "$SIGN" = adhoc ]; then
  codesign --force -s - "$APP/Contents/MacOS/probe-child"; codesign --force -s - "$APP"
else
  KC="$HOME/Library/Keychains/ra-dev.keychain-db"
  security unlock-keychain -p "$(cat .keychain-pass)" "$KC"
  codesign --force --keychain "$KC" -s "Record Anything Dev" "$APP/Contents/MacOS/probe-child"
  codesign --force --keychain "$KC" -s "Record Anything Dev" "$APP"
fi
codesign -d -r- "$APP" 2>&1 | grep designated
