#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p 'Codex用量.app/Contents/MacOS'
cp AppTemplate/Info.plist 'Codex用量.app/Contents/Info.plist'
mkdir -p .build
build_archs=(${=CODEX_USAGE_ARCHS:-arm64 x86_64})
for arch in $build_archs; do
  swiftc -O Sources/UsageCore.swift Sources/main.swift -target "${arch}-apple-macos13.0" -o ".build/CodexUsage-${arch}" -framework AppKit -framework SwiftUI -framework ServiceManagement -module-cache-path /private/tmp/codex-usage-swift-cache
done
build_inputs=()
for arch in $build_archs; do build_inputs+=(".build/CodexUsage-${arch}"); done
lipo -create $build_inputs -output 'Codex用量.app/Contents/MacOS/CodexUsage'
codesign --force --sign - 'Codex用量.app'
