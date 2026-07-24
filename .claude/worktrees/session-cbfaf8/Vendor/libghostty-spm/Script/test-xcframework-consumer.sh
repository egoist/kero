#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f .root ]; then
    echo "[*] malformed project structure"
    exit 1
fi

XCFRAMEWORK_PATH=${1:-BinaryTarget/GhosttyKit.xcframework}

if [ ! -d "$XCFRAMEWORK_PATH" ]; then
    echo "[!] xcframework not found: $XCFRAMEWORK_PATH"
    exit 1
fi

format_output() {
    if command -v xcbeautify >/dev/null 2>&1; then
        xcbeautify
    else
        cat
    fi
}

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/Consumer/BinaryTarget" "$WORK_DIR/Consumer/Sources/Consumer"
ditto "$XCFRAMEWORK_PATH" "$WORK_DIR/Consumer/BinaryTarget/GhosttyKit.xcframework"

cat >"$WORK_DIR/Consumer/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Consumer",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .macCatalyst(.v15),
    ],
    products: [
        .library(name: "Consumer", targets: ["Consumer"]),
    ],
    targets: [
        .binaryTarget(
            name: "libghostty",
            path: "BinaryTarget/GhosttyKit.xcframework"
        ),
        .target(
            name: "Consumer",
            dependencies: ["libghostty"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
    ]
)
EOF

cat >"$WORK_DIR/Consumer/Sources/Consumer/Consumer.swift" <<'EOF'
import libghostty

public func passThroughPlatform(_ platform: ghostty_platform_e) -> ghostty_platform_e {
    platform
}
EOF

ARM64E_LINK_SOURCE="$WORK_DIR/arm64e-link.c"
cat >"$ARM64E_LINK_SOURCE" <<'EOF'
#include "ghostty.h"

#include <pthread.h>
#include <ptrauth.h>
#include <stdlib.h>

extern int pa_pthread_cr(
    pthread_t *,
    const pthread_attr_t *,
    void *(*)(void *),
    void *);
extern void pa_qs(
    void *,
    size_t,
    size_t,
    int (*)(const void *, const void *));

static void wakeup(void *userdata) {
    (void)userdata;
}

static void *thread_main(void *context) {
    int *value = context;
    *value = 42;
    return NULL;
}

static int compare_ints(const void *lhs, const void *rhs) {
    const int left = *(const int *)lhs;
    const int right = *(const int *)rhs;
    return (left > right) - (left < right);
}

int main(void) {
    if (ghostty_init(0, NULL) != GHOSTTY_SUCCESS) {
        return 1;
    }

    ghostty_config_t config = ghostty_config_new();
    if (config == NULL) {
        return 2;
    }
    ghostty_config_finalize(config);

    ghostty_runtime_config_s runtime = {0};
    runtime.wakeup_cb = wakeup;
    ghostty_app_t app = ghostty_app_new(&runtime, config);
    if (app == NULL) {
        ghostty_config_free(config);
        return 3;
    }

    int thread_value = 0;
    pthread_t thread;
    void *(*raw_thread_main)(void *) =
        ptrauth_strip(&thread_main, ptrauth_key_function_pointer);
    if (pa_pthread_cr(&thread, NULL, raw_thread_main, &thread_value) != 0) {
        return 4;
    }
    if (pthread_join(thread, NULL) != 0 || thread_value != 42) {
        return 5;
    }

    int values[] = {3, 1, 2};
    int (*raw_compare)(const void *, const void *) =
        ptrauth_strip(&compare_ints, ptrauth_key_function_pointer);
    pa_qs(values, 3, sizeof(values[0]), raw_compare);
    if (values[0] != 1 || values[1] != 2 || values[2] != 3) {
        return 6;
    }

    ghostty_app_free(app);
    ghostty_config_free(config);
    return 0;
}
EOF

find_slice_paths() {
    local platform="$1"
    local platform_variant="$2"

    python3 - "$XCFRAMEWORK_PATH" "$platform" "$platform_variant" <<'PY'
import os
import plistlib
import sys

xcframework, expected_platform, expected_variant = sys.argv[1:]
expected_variant = expected_variant or None

with open(os.path.join(xcframework, "Info.plist"), "rb") as handle:
    libraries = plistlib.load(handle)["AvailableLibraries"]

for library in libraries:
    if library.get("SupportedPlatform") != expected_platform:
        continue
    if library.get("SupportedPlatformVariant") != expected_variant:
        continue

    root = os.path.join(xcframework, library["LibraryIdentifier"])
    print(os.path.join(root, library["LibraryPath"]))
    print(os.path.join(root, library["HeadersPath"]))
    break
else:
    raise SystemExit(
        f"[!] xcframework slice not found: {expected_platform}/{expected_variant}"
    )
PY
}

link_arm64e() {
    local name="$1"
    local sdk="$2"
    local target="$3"
    local platform="$4"
    local platform_variant="$5"
    local slice_paths
    local library_path
    local headers_path
    local output_path="$WORK_DIR/arm64e-link-$name"
    local command

    slice_paths=$(find_slice_paths "$platform" "$platform_variant")
    library_path=${slice_paths%%$'\n'*}
    headers_path=${slice_paths#*$'\n'}
    command=(
        xcrun --sdk "$sdk" clang
        -target "$target"
        "$ARM64E_LINK_SOURCE"
        -I "$headers_path"
        "-Wl,-force_load,$library_path"
        -lc++
        -framework Foundation
        -framework CoreFoundation
        -framework CoreGraphics
        -framework CoreText
        -framework CoreVideo
        -framework QuartzCore
        -framework IOSurface
        -framework Metal
        -framework MetalKit
    )

    case "$name" in
        macos)
            command+=(-framework Carbon)
            ;;
        ios)
            command+=(-framework UIKit)
            ;;
        maccatalyst)
            local sdk_path
            sdk_path=$(xcrun --sdk macosx --show-sdk-path)
            command+=(
                -F "$sdk_path/System/iOSSupport/System/Library/Frameworks"
                -L "$sdk_path/System/iOSSupport/usr/lib"
                -framework UIKit
            )
            ;;
    esac

    command+=(-o "$output_path")
    echo "[*] full link platform=$name architecture=arm64e"
    "${command[@]}"

    if [ "$(lipo -archs "$output_path")" != "arm64e" ]; then
        echo "[!] linked executable is not a single arm64e slice: $output_path"
        exit 1
    fi

    if [ "$name" = "macos" ] && [ "$(uname -m)" = "arm64" ]; then
        echo "[*] runtime smoke platform=macos architecture=arm64e"
        "$output_path"
    fi
}

test_build() {
    local destination="$1"
    local architecture=${2:-}
    local command=(
        xcodebuild
        -scheme Consumer
        -destination "$destination"
        -derivedDataPath "$WORK_DIR/DerivedData"
        -packageCachePath "$WORK_DIR/PackageCache"
    )

    if [ -n "$architecture" ]; then
        command+=("ARCHS=$architecture" "ONLY_ACTIVE_ARCH=YES")
    fi
    command+=(build)

    echo "[*] consumer build destination=$destination architecture=${architecture:-default}"
    "${command[@]}" 2>&1 | format_output
    local exit_code=${PIPESTATUS[0]}
    if [ "$exit_code" -ne 0 ]; then
        echo "[!] consumer build failed destination=$destination"
        exit "$exit_code"
    fi
}

(
    cd "$WORK_DIR/Consumer"
    test_build "generic/platform=macOS"
    test_build "generic/platform=macOS,variant=Mac Catalyst"
    test_build "generic/platform=iOS"
    test_build "generic/platform=iOS Simulator"
    test_build "generic/platform=macOS" "arm64e"
    test_build "generic/platform=macOS,variant=Mac Catalyst" "arm64e"
    test_build "generic/platform=iOS" "arm64e"
)

link_arm64e "macos" "macosx" "arm64e-apple-macosx13.0" "macos" ""
link_arm64e "ios" "iphoneos" "arm64e-apple-ios15.0" "ios" ""
link_arm64e "maccatalyst" "macosx" "arm64e-apple-ios15.0-macabi" "ios" "maccatalyst"

echo "[*] xcframework consumer tests passed"
