#!/bin/zsh

set -euo pipefail

SOURCE_DIR=${1:-}

if [ -z "$SOURCE_DIR" ]; then
    echo "[-] missing source_dir"
    exit 1
fi

BUILD_ZIG="$SOURCE_DIR/build.zig"
MARKER="libghostty static install for Darwin"

if [ ! -f "$BUILD_ZIG" ]; then
    echo "[-] build.zig not found: $BUILD_ZIG"
    exit 1
fi

if grep -Fq "$MARKER" "$BUILD_ZIG"; then
    echo "[+] patch already applied: 0001-darwin-libghostty-install"
    exit 0
fi

if grep -Fq "const lib_shared = try buildpkg.GhosttyLib.initShared" "$BUILD_ZIG"; then
    sed -i '' \
        '/We shouldn'\''t have this guard but we don'\''t currently/,/^        }$/c\
        // libghostty static install for Darwin:\
        // upstream only wires this for non-Darwin today, but we need the\
        // static archive for our own XCFramework assembly pipeline.\
        lib_shared.installHeader();\
        if (config.target.result.os.tag.isDarwin()) {\
            lib_static.install("libghostty.a");\
        } else if (config.target.result.os.tag == .windows) {\
            lib_shared.install("ghostty-internal.dll");\
            lib_static.install("ghostty-internal-static.lib");\
        } else {\
            lib_shared.install("ghostty-internal.so");\
            lib_static.install("ghostty-internal.a");\
        }' \
        "$BUILD_ZIG"
else
    sed -i '' \
        '/We shouldn'\''t have this guard but we don'\''t currently/,/^        }$/c\
        // libghostty static install for Darwin:\
        // upstream only wires this for non-Darwin today, but we need the\
        // static archive for our own XCFramework assembly pipeline.\
        libghostty_shared.installHeader(); // Only need one header\
        if (!config.target.result.os.tag.isDarwin()) {\
            libghostty_shared.install("libghostty.so");\
        }\
        libghostty_static.install("libghostty.a");' \
        "$BUILD_ZIG"
fi

if ! grep -Fq "$MARKER" "$BUILD_ZIG"; then
    echo "[-] failed to apply patch: 0001-darwin-libghostty-install"
    exit 1
fi

echo "[+] applied patch: 0001-darwin-libghostty-install"
