#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"
METAL_ZIG="$SOURCE_DIR/src/renderer/Metal.zig"

if [ ! -f "$METAL_ZIG" ]; then
    echo "[-] Metal.zig not found"
    exit 1
fi

if grep -q 'LIBGHOSTTY_SPM_TEXTURE_STORAGE_PATCH' "$METAL_ZIG"; then
    echo "[+] Metal texture storage already patched"
    exit 0
fi

python3 - "$METAL_ZIG" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
src = path.read_text()

replacements = [
    (
        """default_storage_mode: mtl.MTLResourceOptions.StorageMode,

/// The maximum 2D texture width and height supported by the device.
""",
        """default_storage_mode: mtl.MTLResourceOptions.StorageMode,

/// The default storage mode to use for MTLTexture resources.
default_texture_storage_mode: mtl.MTLResourceOptions.StorageMode,

/// The maximum 2D texture width and height supported by the device.
""",
    ),
    (
        """    const max_texture_size = queryMaxTextureSize(device);
    log.debug(
        "device properties default_storage_mode={} max_texture_size={}",
        .{ default_storage_mode, max_texture_size },
    );
""",
        """    // LIBGHOSTTY_SPM_TEXTURE_STORAGE_PATCH
    // MTLStorageModeShared is valid for textures on Apple GPUs, while Intel
    // and AMD macOS GPUs require managed textures even when hasUnifiedMemory is
    // true. Keep buffer storage unchanged, but choose texture storage from the
    // Metal GPU family as Apple recommends for CPU-updated textures.
    const default_texture_storage_mode: mtl.MTLResourceOptions.StorageMode = switch (comptime builtin.os.tag) {
        .ios => .shared,
        .macos => if (device.msgSend(
            bool,
            objc.sel("supportsFamily:"),
            .{mtl.MTLGPUFamily.apple1},
        )) .shared else .managed,
        else => default_storage_mode,
    };
    const max_texture_size = queryMaxTextureSize(device);
    log.debug(
        "device properties default_storage_mode={} default_texture_storage_mode={} max_texture_size={}",
        .{ default_storage_mode, default_texture_storage_mode, max_texture_size },
    );
""",
    ),
    (
        """        .default_storage_mode = default_storage_mode,
        .max_texture_size = max_texture_size,
""",
        """        .default_storage_mode = default_storage_mode,
        .default_texture_storage_mode = default_texture_storage_mode,
        .max_texture_size = max_texture_size,
""",
    ),
]

for old, new in replacements:
    if old not in src:
        print("[-] Metal.zig structure block not found")
        sys.exit(1)
    src = src.replace(old, new, 1)

old_count = src.count(".storage_mode = self.default_storage_mode")
if old_count < 4:
    print("[-] expected texture storage call sites not found")
    sys.exit(1)

src = src.replace(
    ".storage_mode = self.default_storage_mode",
    ".storage_mode = self.default_texture_storage_mode",
)

buffer_marker = """pub inline fn bufferOptions(self: Metal) bufferpkg.Options {"""
buffer_start = src.find(buffer_marker)
if buffer_start == -1:
    print("[-] bufferOptions not found")
    sys.exit(1)

src = (
    src[:buffer_start]
    + src[buffer_start:].replace(
        ".storage_mode = self.default_texture_storage_mode",
        ".storage_mode = self.default_storage_mode",
        1,
    )
)

path.write_text(src)
print("[+] patched Metal.zig: split buffer and texture storage modes")
PY
