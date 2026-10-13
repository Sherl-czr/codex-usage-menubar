#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p .build
swiftc Sources/UsageCore.swift Tests/CoreTests.swift -o .build/CoreTests -module-cache-path /private/tmp/codex-usage-swift-cache
.build/CoreTests
