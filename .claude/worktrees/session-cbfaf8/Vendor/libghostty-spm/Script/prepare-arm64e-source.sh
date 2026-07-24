#!/bin/zsh

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[-] malformed project structure"
    exit 1
fi

SOURCE_DIR=${1:-}
GLOBAL_CACHE_DIR=${2:-}

if [ -z "$SOURCE_DIR" ] || [ -z "$GLOBAL_CACHE_DIR" ]; then
    echo "Usage: $0 <source_dir> <zig_global_cache_dir>"
    exit 1
fi

if [ ! -d "$SOURCE_DIR" ]; then
    echo "[-] ghostty source directory not found: $SOURCE_DIR"
    exit 1
fi

ZIG_OBJC_URL="https://deps.files.ghostty.org/zig_objc-f356ed02833f0f1b8e84d50bed9e807bf7cdc0ae.tar.gz"
ZIG_OBJC_HASH="zig_objc-0.0.0-Ir_Sp5gTAQCvxxR7oVIrPXxXwsfKgVP7_wqoOQrZjFeK"
VENDOR_DIR="$SOURCE_DIR/.libghostty-spm/zig_objc"
VENDOR_PATCH="$(pwd)/Patches/arm64e/zig-objc/0001-arm64e-boundaries.patch"
VENDOR_PATCH_MARKER="$VENDOR_DIR/.libghostty-spm-arm64e-patched"

./Script/apply-patches.sh "$SOURCE_DIR" "$(pwd)/Patches/arm64e/ghostty"

if [ ! -f "$VENDOR_DIR/src/block.zig" ]; then
    fetched_hash=$(zig fetch --global-cache-dir "$GLOBAL_CACHE_DIR" "$ZIG_OBJC_URL")
    if [ "$fetched_hash" != "$ZIG_OBJC_HASH" ]; then
        echo "[-] zig-objc hash mismatch: expected $ZIG_OBJC_HASH, got $fetched_hash"
        exit 1
    fi

    mkdir -p "$(dirname "$VENDOR_DIR")"
    cp -R "$GLOBAL_CACHE_DIR/p/$ZIG_OBJC_HASH" "$VENDOR_DIR"
    echo "[+] vendored pinned zig-objc for arm64e"
fi

if [ ! -f "$VENDOR_PATCH_MARKER" ]; then
    patch -p1 -f -d "$VENDOR_DIR" < "$VENDOR_PATCH" >/dev/null
    touch "$VENDOR_PATCH_MARKER"
    echo "[+] applied zig-objc arm64e patch"
else
    echo "[+] zig-objc arm64e patch already applied"
fi

echo "[+] prepared arm64e pointer-authentication boundaries"
