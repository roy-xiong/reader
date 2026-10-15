#!/usr/bin/env bash
set -euo pipefail
app='build/macos/Build/Products/Release/Reader.app'
mkdir -p dist
# 统一重新做 ad-hoc 签名，供个人测试；不会读取或上传开发者证书。
codesign --force --deep --sign - --entitlements macos/Runner/Release.entitlements "$app"
codesign --verify --deep --strict "$app"
lipo -archs "$app/Contents/MacOS/Reader"
# Flutter 默认 macOS Release 配置生成 arm64 + x86_64 通用二进制。
lipo "$app/Contents/MacOS/Reader" -verify_arch arm64 x86_64
ditto -c -k --sequesterRsrc --keepParent "$app" dist/Reader-macOS-universal.zip
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/Reader.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname Reader -srcfolder "$staging" -ov -format UDZO dist/Reader-macOS-universal.dmg
shasum -a 256 dist/Reader-macOS-universal.zip dist/Reader-macOS-universal.dmg > dist/Reader-macOS.sha256
