#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/swiftpm-module-cache}"

format_output() {
    if command -v xcbeautify >/dev/null 2>&1; then
        xcbeautify
    else
        cat
    fi
}

test_build() {
    local scheme="$1"
    local destination="$2"
    local architecture=${3:-}
    local command=(
        xcodebuild
        -scheme "$scheme"
        -destination "$destination"
    )

    if [ -n "$architecture" ]; then
        command+=("ARCHS=$architecture" "ONLY_ACTIVE_ARCH=YES")
    fi
    command+=(build)

    echo "[*] build scheme=$scheme destination=$destination architecture=${architecture:-default}"
    "${command[@]}" 2>&1 | format_output
    local exit_code=${PIPESTATUS[0]}
    if [ "$exit_code" -ne 0 ]; then
        echo "[!] failed scheme=$scheme destination=$destination"
        exit "$exit_code"
    fi
}

test_build "GhosttyKit" "generic/platform=macOS"
test_build "GhosttyKit" "generic/platform=iOS"
test_build "GhosttyKit" "generic/platform=iOS Simulator"
test_build "GhosttyTerminal" "generic/platform=macOS"
test_build "GhosttyTerminal" "generic/platform=macOS,variant=Mac Catalyst"
test_build "GhosttyTerminal" "generic/platform=iOS"
test_build "GhosttyTerminal" "generic/platform=iOS Simulator"
test_build "GhosttyKit" "generic/platform=macOS" "arm64e"
test_build "GhosttyKit" "generic/platform=macOS,variant=Mac Catalyst" "arm64e"
test_build "GhosttyKit" "generic/platform=iOS" "arm64e"
test_build "GhosttyTerminal" "generic/platform=macOS" "arm64e"
test_build "GhosttyTerminal" "generic/platform=macOS,variant=Mac Catalyst" "arm64e"
test_build "GhosttyTerminal" "generic/platform=iOS" "arm64e"

echo "[*] all tests passed"
