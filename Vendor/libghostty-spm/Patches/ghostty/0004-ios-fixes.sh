#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# Patch 1: cf_release_thread — ignore loop.run errors on iOS
# The kqueue-based event loop panics on iOS simulator due to mach port issues
CF_RELEASE="${SOURCE_DIR}/src/os/cf_release_thread.zig"
if [ -f "$CF_RELEASE" ]; then
    if grep -q 'try self.loop.run(.until_done);' "$CF_RELEASE"; then
        sed -i '' 's/try self\.loop\.run(\.until_done);/self.loop.run(.until_done) catch |err| { log.warn("cf release loop failed err={}", .{err}); return; };/' "$CF_RELEASE"
        echo "[+] patched cf_release_thread to ignore loop errors"
    else
        echo "[+] cf_release_thread already patched"
    fi
fi

# Patch 2: Disable private window blur API (App Store compliance)
EMBEDDED="${SOURCE_DIR}/src/apprt/embedded.zig"
if [ -f "$EMBEDDED" ]; then
    if grep -q 'CGSSetWindowBackgroundBlurRadius' "$EMBEDDED"; then
        python3 - "$EMBEDDED" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old_fn = """    export fn ghostty_set_window_background_blur(
        app: *App,
        window: *anyopaque,
    ) void {
        // This is only supported on macOS
        if (comptime builtin.target.os.tag != .macos) return;

        const config = &app.config;

        // Do nothing if we don't have background transparency enabled
        if (config.@"background-opacity" >= 1.0) return;

        const nswindow = objc.Object.fromId(window);
        _ = CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(),
            nswindow.msgSend(usize, objc.sel("windowNumber"), .{}),
            @intCast(config.@"background-blur".cval()),
        );
    }

    /// See ghostty_set_window_background_blur
    extern "c" fn CGSSetWindowBackgroundBlurRadius(*anyopaque, usize, c_int) i32;
    extern "c" fn CGSDefaultConnectionForThread() *anyopaque;"""

new_fn = """    export fn ghostty_set_window_background_blur(
        app: *App,
        window: *anyopaque,
    ) void {
        _ = app;
        _ = window;
        return;
    }"""

if old_fn not in text:
    print("[+] blur patch already applied or source changed")
else:
    path.write_text(text.replace(old_fn, new_fn))
    print("[+] patched: disabled private blur API")
PY
    else
        echo "[+] blur patch already applied"
    fi
fi

# Patch 3: Link Metal frameworks
BUILD_ZIG="${SOURCE_DIR}/pkg/macos/build.zig"
if [ -f "$BUILD_ZIG" ]; then
    if ! grep -q 'lib.linkFramework("Metal")' "$BUILD_ZIG"; then
        perl -0pi -e 's/lib\.linkFramework\("IOSurface"\);/lib.linkFramework("IOSurface");\n    lib.linkFramework("Metal");\n    lib.linkFramework("MetalKit");/g' "$BUILD_ZIG"
        perl -0pi -e 's/module\.linkFramework\("IOSurface", \.\{\}\);/module.linkFramework("IOSurface", .{});\n        module.linkFramework("Metal", .{});\n        module.linkFramework("MetalKit", .{});/g' "$BUILD_ZIG"
        echo "[+] patched: linked Metal frameworks"
    else
        echo "[+] Metal frameworks already linked"
    fi
fi

# Patch 4: Lower iOS deployment target to 15.0
CONFIG_ZIG="${SOURCE_DIR}/src/build/Config.zig"
if [ -f "$CONFIG_ZIG" ]; then
    if grep -q '\.ios => \.{ \.semver = \.{' "$CONFIG_ZIG"; then
        perl -0pi -e 's/\.ios => \.{ \.semver = \.{\n\s*\.major = \d+,\n\s*\.minor = \d+,\n\s*\.patch = \d+,/.ios => .{ .semver = .{\n            .major = 15,\n            .minor = 0,\n            .patch = 0,/s' "$CONFIG_ZIG"
        echo "[+] patched: iOS deployment target -> 15.0"
    else
        echo "[+] iOS deployment target already patched"
    fi
fi

echo "[+] all ios-fixes patches applied"
