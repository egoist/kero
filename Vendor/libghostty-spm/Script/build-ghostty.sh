#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[*] malformed project structure"
    exit 1
fi

ROOT_DIR=$(pwd)
SOURCE_DIR=${1:-}
ZIG_TARGET=${2:-}
OUTPUT_DIR=${3:-}
ZIG_CPU=${ZIG_CPU:-}
ZIG_BUILD_EXTRA_ARGS=${ZIG_BUILD_EXTRA_ARGS:-}

if [ -z "$SOURCE_DIR" ] || [ -z "$ZIG_TARGET" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: $0 <source_dir> <zig_target> <output_dir>"
    exit 1
fi

if [ ! -d "$SOURCE_DIR" ]; then
    echo "[!] ghostty source directory not found: $SOURCE_DIR"
    exit 1
fi

if [ ! -f "$SOURCE_DIR/include/ghostty.h" ]; then
    echo "[!] ghostty header not found: $SOURCE_DIR/include/ghostty.h"
    exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
    echo "[!] zig not found"
    exit 1
fi

REQUESTED_TARGET="$ZIG_TARGET"
IS_ARM64E=0
APPLE_SDK=
APPLE_TARGET=

case "$REQUESTED_TARGET" in
    arm64e-macos)
        IS_ARM64E=1
        ZIG_TARGET="aarch64-macos"
        APPLE_SDK="macosx"
        APPLE_TARGET="arm64e-apple-macosx13.0"
        ;;
    arm64e-ios)
        IS_ARM64E=1
        ZIG_TARGET="aarch64-ios"
        APPLE_SDK="iphoneos"
        APPLE_TARGET="arm64e-apple-ios15.0"
        ;;
    arm64e-ios-macabi)
        IS_ARM64E=1
        ZIG_TARGET="aarch64-ios-macabi"
        APPLE_SDK="macosx"
        APPLE_TARGET="arm64e-apple-ios15.0-macabi"
        ;;
esac

./Script/apply-patches.sh "$SOURCE_DIR"

CACHE_ROOT="${BUILD_CACHE_ROOT:-$ROOT_DIR/build/cache}"
GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$CACHE_ROOT/zig-global}"
LOCAL_CACHE_DIR="$CACHE_ROOT/$REQUESTED_TARGET/zig-local"
MODULE_CACHE_DIR="${CLANG_MODULE_CACHE_ROOT:-$CACHE_ROOT/clang-module-cache}/$REQUESTED_TARGET"

if [ "$IS_ARM64E" -eq 1 ]; then
    if ! command -v xcrun >/dev/null 2>&1; then
        echo "[!] xcrun not found for arm64e build"
        exit 1
    fi
    ./Script/prepare-arm64e-source.sh "$SOURCE_DIR" "$GLOBAL_CACHE_DIR"
fi

echo "[*] building ghostty static library"
echo "    target: $REQUESTED_TARGET"
echo "    source: $SOURCE_DIR"
echo "    output: $OUTPUT_DIR"

rm -rf "$OUTPUT_DIR" "$LOCAL_CACHE_DIR" "$MODULE_CACHE_DIR"
mkdir -p \
    "$OUTPUT_DIR/lib" \
    "$OUTPUT_DIR/include" \
    "$GLOBAL_CACHE_DIR" \
    "$LOCAL_CACHE_DIR" \
    "$MODULE_CACHE_DIR"

rm -rf "$SOURCE_DIR/zig-out"

ZIG_BUILD_COMMAND=(
    zig build
    -Doptimize=${ZIG_OPTIMIZE:-ReleaseFast}
    -Dapp-runtime=none
    -Demit-exe=false
    -Demit-xcframework=false
    -Demit-macos-app=false
    -Demit-docs=false
    -Dsentry=false
    -Dcustom-shaders=false
    -Dinspector=false
    -Dtarget="$ZIG_TARGET"
)

if [ -n "$ZIG_CPU" ]; then
    ZIG_BUILD_COMMAND+=("-Dcpu=$ZIG_CPU")
fi

if [ -n "$ZIG_BUILD_EXTRA_ARGS" ]; then
    # shellcheck disable=SC2206
    EXTRA_ARGS=($ZIG_BUILD_EXTRA_ARGS)
    ZIG_BUILD_COMMAND+=("${EXTRA_ARGS[@]}")
fi

(
    cd "$SOURCE_DIR"
    env \
        CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
        ZIG_GLOBAL_CACHE_DIR="$GLOBAL_CACHE_DIR" \
        ZIG_LOCAL_CACHE_DIR="$LOCAL_CACHE_DIR" \
        "${ZIG_BUILD_COMMAND[@]}"
)

find_built_library() {
    local preferred_name="$1"
    find "$LOCAL_CACHE_DIR/o" -type f -name "$preferred_name" -print 2>/dev/null | sort | tail -n 1
}

LIBRARY_PATH=

if [ -f "$SOURCE_DIR/zig-out/lib/libghostty.a" ]; then
    LIBRARY_PATH="$SOURCE_DIR/zig-out/lib/libghostty.a"
fi

if [ -z "$LIBRARY_PATH" ]; then
    LIBRARY_PATH=$(find_built_library "libghostty-fat.a")
fi

if [ -z "$LIBRARY_PATH" ]; then
    LIBRARY_PATH=$(find_built_library "libghostty.a")
fi

if [ -z "$LIBRARY_PATH" ]; then
    echo "[!] failed to locate built libghostty archive in $LOCAL_CACHE_DIR"
    if [[ "$ZIG_TARGET" == *macos* || "$ZIG_TARGET" == *ios* || "$ZIG_TARGET" == *tvos* || "$ZIG_TARGET" == *visionos* || "$ZIG_TARGET" == *watchos* ]]; then
        echo "[!] note: upstream Ghostty does not install Darwin libghostty for app-runtime=none unless extra build wiring is triggered"
        echo "[!] try again with ZIG_BUILD_EXTRA_ARGS='-Demit-xcframework=true' if you want to force Darwin libghostty build graph execution"
    fi
    find "$LOCAL_CACHE_DIR" -maxdepth 3 -type f | sort | tail -n 50
    exit 1
fi

# Resolve std::__1::__libcpp_verbose_abort inside the archive: the Apple
# system libc++ only exports it since iOS 16.3 / macOS 13.3 / tvOS 16.3, and
# Zig's bundled libc++ headers reference it strongly (no availability markup),
# which crashes consumers at launch on older OS versions.
COMPAT_SOURCE="$ROOT_DIR/Script/support/libcxx-verbose-abort-compat.c"
COMPAT_OBJECT="$LOCAL_CACHE_DIR/libcxx-verbose-abort-compat.o"
zig cc -target "$ZIG_TARGET" -Os -fno-sanitize=undefined -c "$COMPAT_SOURCE" -o "$COMPAT_OBJECT"

if [ "$IS_ARM64E" -eq 1 ]; then
    RAW_ARCHIVE="$LOCAL_CACHE_DIR/libghostty-arm64.a"
    CONVERTED_ARCHIVE="$LOCAL_CACHE_DIR/libghostty-arm64e.a"
    CORE_OBJECT="$LOCAL_CACHE_DIR/libghostty-arm64e-core.o"
    ARM64E_COMPAT_OBJECT="$LOCAL_CACHE_DIR/arm64e-compat.o"

    xcrun libtool -static -no_warning_for_no_symbols -o "$RAW_ARCHIVE" "$LIBRARY_PATH" "$COMPAT_OBJECT"
    python3 "$ROOT_DIR/Script/convert-archive-arm64e.py" "$RAW_ARCHIVE" "$CONVERTED_ARCHIVE"

    xcrun --sdk "$APPLE_SDK" clang \
        -target "$APPLE_TARGET" \
        -r \
        -nostdlib \
        "-Wl,-force_load,$CONVERTED_ARCHIVE" \
        -Wl,-alias,_ghostty_app_new,_ghostty_arm64e_core_app_new \
        -Wl,-unexported_symbol,_ghostty_app_new \
        -Wl,-alias,_ghostty_surface_new,_ghostty_arm64e_core_surface_new \
        -Wl,-unexported_symbol,_ghostty_surface_new \
        -o "$CORE_OBJECT"

    xcrun --sdk "$APPLE_SDK" clang \
        -target "$APPLE_TARGET" \
        -Os \
        -fno-sanitize=undefined \
        -I "$SOURCE_DIR/include" \
        -c "$ROOT_DIR/Script/support/arm64e-compat.c" \
        -o "$ARM64E_COMPAT_OBJECT"

    xcrun libtool -static -no_warning_for_no_symbols \
        -o "$OUTPUT_DIR/lib/libghostty.a" \
        "$CORE_OBJECT" \
        "$ARM64E_COMPAT_OBJECT"

    if [ "$(lipo -archs "$OUTPUT_DIR/lib/libghostty.a")" != "arm64e" ]; then
        echo "[!] built archive is not a single arm64e slice"
        exit 1
    fi

    SYMBOLS=$(nm -gjU "$OUTPUT_DIR/lib/libghostty.a" | sort -u)
    for symbol in \
        _ghostty_app_new \
        _ghostty_surface_new \
        _ghostty_arm64e_core_app_new \
        _ghostty_arm64e_core_surface_new \
        _pa_pthread_cr \
        _pa_qs; do
        if ! grep -Fxq "$symbol" <<<"$SYMBOLS"; then
            echo "[!] arm64e archive missing symbol: $symbol"
            exit 1
        fi
    done

    CORE_IMPORTS=$(nm -u "$CORE_OBJECT" | sort -u)
    for symbol in _pa_pthread_cr _pa_qs; do
        if ! grep -Fxq "$symbol" <<<"$CORE_IMPORTS"; then
            echo "[!] arm64e core missing redirected import: $symbol"
            exit 1
        fi
    done
    for symbol in _pthread_create _qsort; do
        if grep -Fxq "$symbol" <<<"$CORE_IMPORTS"; then
            echo "[!] arm64e core contains unsigned callback import: $symbol"
            exit 1
        fi
    done
    echo "[*] built pointer-authenticated arm64e archive"
else
    ARM64E_COMPAT_OBJECT="$LOCAL_CACHE_DIR/arm64e-compat.o"
    case "$ZIG_TARGET" in
        *-ios-simulator) COMPAT_SDK="iphonesimulator" ;;
        *-ios-macabi | *-macos) COMPAT_SDK="macosx" ;;
        *-ios) COMPAT_SDK="iphoneos" ;;
        *-tvos-simulator) COMPAT_SDK="appletvsimulator" ;;
        *-tvos) COMPAT_SDK="appletvos" ;;
        *-visionos-simulator) COMPAT_SDK="xrsimulator" ;;
        *-visionos) COMPAT_SDK="xros" ;;
        *-watchos-simulator) COMPAT_SDK="watchsimulator" ;;
        *-watchos) COMPAT_SDK="watchos" ;;
        *)
            echo "[!] unsupported compatibility target: $ZIG_TARGET"
            exit 1
            ;;
    esac
    COMPAT_SDK_PATH=$(xcrun --sdk "$COMPAT_SDK" --show-sdk-path)
    zig cc \
        -target "$ZIG_TARGET" \
        -Os \
        -fno-sanitize=undefined \
        -isystem "$COMPAT_SDK_PATH/usr/include" \
        -I "$SOURCE_DIR/include" \
        -c "$ROOT_DIR/Script/support/arm64e-compat.c" \
        -o "$ARM64E_COMPAT_OBJECT"
    xcrun libtool -static -no_warning_for_no_symbols \
        -o "$OUTPUT_DIR/lib/libghostty.a" \
        "$LIBRARY_PATH" \
        "$COMPAT_OBJECT" \
        "$ARM64E_COMPAT_OBJECT"
    echo "[*] appended compatibility objects"
fi

cp "$SOURCE_DIR/include/ghostty.h" "$OUTPUT_DIR/include/ghostty.h"
cat >"$OUTPUT_DIR/include/module.modulemap" <<'EOF'
module libghostty {
    umbrella header "ghostty.h"
    export *
}
EOF

echo "[*] built archive: $OUTPUT_DIR/lib/libghostty.a"
