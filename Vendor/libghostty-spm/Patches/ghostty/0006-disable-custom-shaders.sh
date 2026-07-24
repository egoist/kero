#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

MARKER="LIBGHOSTTY_SPM_TRIM_PATCH"

# Skip if already applied
if grep -q "$MARKER" "$SOURCE_DIR/src/build/Config.zig" 2>/dev/null; then
    echo "[+] trim patch already applied"
    exit 0
fi

python3 - "$SOURCE_DIR" "$MARKER" <<'PYEOF'
import sys
from pathlib import Path

source_dir = Path(sys.argv[1])
marker = sys.argv[2]

# ──────────────────────────────────────────────────────────────────────
# 1. Config.zig — add custom_shaders feature flag
# ──────────────────────────────────────────────────────────────────────
config_path = source_dir / "src/build/Config.zig"
text = config_path.read_text()

# Add field
text = text.replace(
    "sentry: bool = true,",
    f"sentry: bool = true,\ncustom_shaders: bool = true, // {marker}",
)

# Add option parsing after sentry block
sentry_end = """    ) orelse sentry: {
        switch (target.result.os.tag) {
            .macos, .ios => break :sentry true,

            // Note its false for linux because the crash reports on Linux
            // don't have much useful information.
            else => break :sentry false,
        }
    };"""

new_options = sentry_end + """

    config.custom_shaders = b.option(
        bool,
        "custom-shaders",
        "Build with custom shader (glslang/spirv-cross) support.",
    ) orelse true;"""

text = text.replace(sentry_end, new_options)

# Add to addOptions
text = text.replace(
    'step.addOption(bool, "sentry", self.sentry);',
    'step.addOption(bool, "sentry", self.sentry);\n'
    '    step.addOption(bool, "custom_shaders", self.custom_shaders);',
)

config_path.write_text(text)
print("[+] patched Config.zig")

# ──────────────────────────────────────────────────────────────────────
# 2. SharedDeps.zig — gate glslang + spirv-cross on custom_shaders
# ──────────────────────────────────────────────────────────────────────
shared_path = source_dir / "src/build/SharedDeps.zig"
text = shared_path.read_text()

# Gate glslang — wrap with custom_shaders check
text = text.replace(
    '    // Glslang\n    if (b.lazyDependency("glslang", .{',
    '    // Glslang — only needed for custom shaders\n    if (self.config.custom_shaders) if (b.lazyDependency("glslang", .{',
)
# Close the extra if at end of glslang block
text = text.replace(
    """            step.linkLibrary(glslang_dep.artifact("glslang"));
            try static_libs.append(
                b.allocator,
                glslang_dep.artifact("glslang").getEmittedBin(),
            );
        }
    }

    // Spirv-cross""",
    """            step.linkLibrary(glslang_dep.artifact("glslang"));
            try static_libs.append(
                b.allocator,
                glslang_dep.artifact("glslang").getEmittedBin(),
            );
        }
    };

    // Spirv-cross""",
)

# Gate spirv-cross — wrap with custom_shaders check
text = text.replace(
    '    // Spirv-cross\n    if (b.lazyDependency("spirv_cross", .{',
    '    // Spirv-cross — only needed for custom shaders\n    if (self.config.custom_shaders) if (b.lazyDependency("spirv_cross", .{',
)
text = text.replace(
    """            step.linkLibrary(spirv_cross_dep.artifact("spirv_cross"));
            try static_libs.append(
                b.allocator,
                spirv_cross_dep.artifact("spirv_cross").getEmittedBin(),
            );
        }
    }

    // Sentry""",
    """            step.linkLibrary(spirv_cross_dep.artifact("spirv_cross"));
            try static_libs.append(
                b.allocator,
                spirv_cross_dep.artifact("spirv_cross").getEmittedBin(),
            );
        }
    };

    // Sentry""",
)

shared_path.write_text(text)
print("[+] patched SharedDeps.zig")

# ──────────────────────────────────────────────────────────────────────
# 3. build_config.zig — re-export custom_shaders flag
# ──────────────────────────────────────────────────────────────────────
bc_path = source_dir / "src/build_config.zig"
text = bc_path.read_text()

if "custom_shaders" not in text:
    text = text.replace(
        'const options = @import("build_options");',
        'const options = @import("build_options");\npub const custom_shaders = options.custom_shaders;',
    )
    bc_path.write_text(text)
    print("[+] patched build_config.zig")

# ──────────────────────────────────────────────────────────────────────
# 4. global.zig — conditional glslang init
#    (global.zig already imports build_config)
# ──────────────────────────────────────────────────────────────────────
global_path = source_dir / "src/global.zig"
text = global_path.read_text()

text = text.replace(
    'const glslang = @import("glslang");',
    'const glslang = if (build_config.custom_shaders) @import("glslang") else struct {\n'
    '    pub fn init() !void {}\n'
    '};',
)

global_path.write_text(text)
print("[+] patched global.zig")

# ──────────────────────────────────────────────────────────────────────
# 5. renderer/shadertoy.zig — gate shader imports and loadFromFile
#    When custom_shaders is disabled, loadFromFile is unreachable
#    so glslang/spirv_cross are never semantically analyzed
# ──────────────────────────────────────────────────────────────────────
shader_path = source_dir / "src/renderer/shadertoy.zig"
text = shader_path.read_text()

# Make imports conditional — these won't be analyzed if never reached
text = text.replace(
    'const glslang = @import("glslang");',
    'const build_config = @import("../build_config.zig");\n'
    'const glslang = @import("glslang");',
)

# Add early return in loadFromFiles when custom_shaders is disabled
# This prevents loadFromFile (and thus spirvFromGlsl etc) from being analyzed
text = text.replace(
    """pub fn loadFromFiles(
    alloc_gpa: Allocator,
    paths: configpkg.RepeatablePath,
    target: Target,
) ![]const [:0]const u8 {
    var list: std.ArrayList([:0]const u8) = .empty;""",
    """pub fn loadFromFiles(
    alloc_gpa: Allocator,
    paths: configpkg.RepeatablePath,
    target: Target,
) ![]const [:0]const u8 {
    if (comptime !build_config.custom_shaders) return &.{};
    var list: std.ArrayList([:0]const u8) = .empty;""",
)

shader_path.write_text(text)
print("[+] patched renderer/shadertoy.zig")

print(f"[+] all trim patches complete ({marker})")
PYEOF

echo "[+] trim patch applied"
