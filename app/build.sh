#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
app_dir="$repo_dir/dist/Cookie 的小日子.app"
resources="$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/MacOS" "$resources" \
  "$repo_dir/.build/swift-cache" "$repo_dir/.build/clang-cache"

export SWIFT_MODULE_CACHE_PATH="$repo_dir/.build/swift-cache"
export CLANG_MODULE_CACHE_PATH="$repo_dir/.build/clang-cache"
swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "$(uname -m)-apple-macosx26.0" -parse-as-library \
  "$repo_dir/app/CookieCompanion.swift" \
  -o "$app_dir/Contents/MacOS/CookieCompanion"
cp "$repo_dir/app/Info.plist" "$app_dir/Contents/Info.plist"
cp "$repo_dir/app/agent-response.schema.json" "$resources/"
cp "$repo_dir/assets/"*.png "$resources/"
cp "$repo_dir/assets/Xiaolai-Regular.ttf" "$repo_dir/assets/Xiaolai-OFL.txt" "$resources/"
codesign --force --deep --sign - "$app_dir"
print "Built: $app_dir"
