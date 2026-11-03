#!/bin/sh
# Builds an unsigned Stick.ipa for a GitHub release. Sideloading tools
# (AltStore, SideStore, Sideloadly) sign it with the installer's own Apple ID
# and rewrite the app group, which the app and its keyboard share.
set -eu
cd "$(dirname "$0")/.."
out="${1:-build}"
archive="$out/Stick.xcarchive"

xcodegen generate -q
xcodebuild archive -project StickDictation.xcodeproj -scheme DuoDictate \
  -destination 'generic/platform=iOS' -archivePath "$archive" -quiet \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

rm -rf "$out/Payload" "$out/Stick.ipa"
mkdir -p "$out/Payload"
cp -R "$archive/Products/Applications/Stick.app" "$out/Payload/"
(cd "$out" && zip -qry Stick.ipa Payload && rm -rf Payload)
echo "$out/Stick.ipa"
