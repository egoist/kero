#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# =============================================================================
# Patch 1: IOSurfaceLayer — iOS rendering compatibility
#
# Problem: On iOS, IOSurface dimensions may differ by ±1 pixel from the
# CALayer bounds due to rounding differences between UIKit point-to-pixel
# conversion and Metal's integer pixel sizes. The upstream code does an
# exact match and silently discards the surface, causing a blank screen.
#
# Additionally, iOS doesn't have a native CALayer subclass optimized for
# IOSurface content display. Using the private CAIOSurfaceLayer class
# (available since iOS 11) provides hardware-accelerated compositing.
#
# Fix:
# - Allow ±1px tolerance on iOS when comparing surface vs layer dimensions
# - Dynamically adjust contentsScale when dimensions don't match exactly
# - Use CAIOSurfaceLayer as base class on iOS for native IOSurface compositing
# - Mark layer as opaque since terminal content fills the entire bounds
# =============================================================================
IOSURFACE_LAYER="${SOURCE_DIR}/src/renderer/metal/IOSurfaceLayer.zig"
if [ -f "$IOSURFACE_LAYER" ]; then
    if grep -q 'const log = std.log.scoped(.IOSurfaceLayer);' "$IOSURFACE_LAYER"; then
        python3 - "$IOSURFACE_LAYER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
src = path.read_text()

# Need builtin for comptime os.tag checks
src = src.replace(
    'const std = @import("std");\nconst Allocator = std.mem.Allocator;',
    'const std = @import("std");\nconst builtin = @import("builtin");\nconst Allocator = std.mem.Allocator;'
)

# The scoped log is only used in the size check we're replacing; drop it
src = src.replace('\nconst log = std.log.scoped(.IOSurfaceLayer);\n', '\n')

# Terminal surface is always fully opaque — tell the compositor
src = src.replace(
    'layer.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);\n\n    layer.setInstanceVariable',
    'layer.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);\n    layer.setProperty("opaque", true);\n\n    layer.setInstanceVariable'
)

# Replace the strict size equality check with a platform-aware version.
# On iOS, UIKit's point→pixel rounding can produce a 1px discrepancy.
# Rather than dropping the frame entirely (→ blank screen), we accept it
# and recalculate contentsScale so CoreAnimation stretches correctly.
old_block = """    if (width != surface.getWidth() or height != surface.getHeight()) {
        log.debug(
            "setSurfaceCallback(): surface is wrong size for layer, discarding. surface = {d}x{d}, layer = {d}x{d}",
            .{ surface.getWidth(), surface.getHeight(), width, height },
        );
        return;
    }"""

new_block = """    const sw = surface.getWidth();
    const sh = surface.getHeight();
    const dw: usize = if (width > sw) width - sw else sw - width;
    const dh: usize = if (height > sh) height - sh else sh - height;
    // iOS UIKit rounding can produce ±1px discrepancy; macOS must match exactly
    const max_drift: usize = if (comptime builtin.os.tag == .ios) 1 else 0;
    if (dw > max_drift or dh > max_drift) {
        if (comptime builtin.os.tag == .ios) {
            // Recalculate contentsScale so CA maps surface pixels to layer points
            const pw = bounds.size.width;
            const ph = bounds.size.height;
            if (pw > 0 and ph > 0) {
                const cs_x: f64 = @as(f64, @floatFromInt(sw)) / pw;
                const cs_y: f64 = @as(f64, @floatFromInt(sh)) / ph;
                const cs: f64 = @max(cs_x, cs_y);
                if (@abs(cs - scale) > 0.01) {
                    layer.setProperty("contentsScale", cs);
                }
            }
        } else {
            return;
        }
    }"""

if old_block not in src:
    print("[!] IOSurfaceLayer size check block not found — source may have changed")
    sys.exit(1)
src = src.replace(old_block, new_block)

# Use the system-provided CAIOSurfaceLayer on iOS; it handles
# IOSurface display natively with zero-copy compositing.
old_cls = """    const CALayer =
        objc.getClass("CALayer") orelse return error.ObjCFailed;

    var subclass =
        objc.allocateClassPair(CALayer, "IOSurfaceLayer") orelse return error.ObjCFailed;"""

new_cls = """    const parent_cls = if (comptime builtin.os.tag == .ios)
        // CAIOSurfaceLayer provides native zero-copy IOSurface compositing
        objc.getClass("CAIOSurfaceLayer") orelse
            objc.getClass("CALayer") orelse return error.ObjCFailed
    else
        objc.getClass("CALayer") orelse return error.ObjCFailed;

    var subclass =
        objc.allocateClassPair(parent_cls, "IOSurfaceLayer") orelse return error.ObjCFailed;"""

src = src.replace(old_cls, new_cls)

path.write_text(src)
print("[+] patched IOSurfaceLayer: iOS size tolerance + CAIOSurfaceLayer")
PY
    else
        echo "[+] IOSurfaceLayer already patched"
    fi
fi

# =============================================================================
# Patch 2: Metal.zig — iOS first-frame display + synchronous present
#
# Problem 1: On iOS the IOSurfaceLayer is added as a sublayer of the UIView's
# backing layer. By the time the renderer registers its display callback the
# sublayer already has its bounds set, so no "display" message is generated.
# The first frame never renders.
#
# Problem 2: The async present path dispatches to the main thread via GCD.
# On iOS the render loop already runs on the main thread, so the async
# dispatch adds an unnecessary runloop turn of latency and can cause ordering
# issues with UIKit layout.
#
# Fix:
# - Call setNeedsDisplay after registering the display callback on iOS
# - On iOS, always use the synchronous present path (setSurface checks
#   isMainThread internally and runs inline when true)
# =============================================================================
METAL_ZIG="${SOURCE_DIR}/src/renderer/Metal.zig"
if [ -f "$METAL_ZIG" ]; then
    if ! grep -q 'setNeedsDisplay' "$METAL_ZIG"; then
        python3 - "$METAL_ZIG" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
src = path.read_text()

# Kick the first display cycle after callback registration on iOS
old_cb = """        @ptrCast(&displayCallback),
        @ptrCast(renderer),
    );
}"""

new_cb = """        @ptrCast(&displayCallback),
        @ptrCast(renderer),
    );

    // iOS: sublayer bounds are already set before the callback is wired up,
    // so no display message fires automatically. Kick the first frame.
    if (comptime builtin.os.tag == .ios) {
        self.layer.layer.msgSend(void, objc.sel("setNeedsDisplay"), .{});
    }
}"""

if old_cb not in src:
    print("[!] Metal loopEnter callback not found")
    sys.exit(1)
src = src.replace(old_cb, new_cb)

# iOS render loop is main-thread; skip the async dispatch path entirely.
old_present = """pub inline fn present(self: *Metal, target: Target, sync: bool) !void {
    if (sync) {
        self.layer.setSurfaceSync(target.surface);
    } else {
        try self.layer.setSurface(target.surface);
    }
}"""

new_present = """pub inline fn present(self: *Metal, target: Target, sync: bool) !void {
    // iOS: always present synchronously — the render loop already runs on
    // the main thread, so the async GCD hop is unnecessary overhead.
    if (comptime builtin.os.tag == .ios) {
        try self.layer.setSurface(target.surface);
        return;
    }
    if (sync) {
        self.layer.setSurfaceSync(target.surface);
    } else {
        try self.layer.setSurface(target.surface);
    }
}"""

if old_present not in src:
    print("[!] Metal present function not found")
    sys.exit(1)
src = src.replace(old_present, new_present)

path.write_text(src)
print("[+] patched Metal.zig: iOS first-frame trigger + sync present")
PY
    else
        echo "[+] Metal.zig already patched"
    fi
fi

# =============================================================================
# Patch 3: coretext.zig — Skip CF release thread on iOS
#
# Problem: The CoreText font shaper spawns a background thread that uses
# libxev's kqueue event loop to asynchronously release CoreFoundation
# objects. On iOS, kqueue's Mach port allocation fails (sandbox restrictions
# + simulator incompatibility), crashing the thread and potentially stalling
# font shaping operations.
#
# Fix: Make the CF release thread optional. On iOS, skip thread creation
# entirely and release CF objects synchronously in endFrame(). This is
# acceptable because iOS devices have fast enough CF release performance
# and the terminal doesn't produce the same volume of shaped text as a
# desktop compositor.
# =============================================================================
CORETEXT="${SOURCE_DIR}/src/font/shaper/coretext.zig"
if [ -f "$CORETEXT" ]; then
    if grep -q 'cf_release_thread: \*CFReleaseThread,' "$CORETEXT"; then
        python3 - "$CORETEXT" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
src = path.read_text()

# Make the struct fields optional so nil can represent "no thread"
src = src.replace(
    'cf_release_thread: *CFReleaseThread,\n    cf_release_thr: std.Thread,',
    'cf_release_thread: ?*CFReleaseThread,\n    cf_release_thr: ?std.Thread,'
)

# Guard thread creation behind a comptime platform check
old_create = """        // Create the CF release thread.
        var cf_release_thread = try alloc.create(CFReleaseThread);
        errdefer alloc.destroy(cf_release_thread);
        cf_release_thread.* = try .init(alloc);
        errdefer cf_release_thread.deinit();

        // Start the CF release thread.
        var cf_release_thr = try std.Thread.spawn(
            .{},
            CFReleaseThread.threadMain,
            .{cf_release_thread},
        );
        cf_release_thr.setName("cf_release") catch {};

        return .{"""

new_create = """        // On iOS the kqueue-based event loop used by the release thread
        // crashes due to Mach port sandbox restrictions. Skip it entirely
        // and fall through to synchronous release in endFrame.
        var cf_release_thread: ?*CFReleaseThread = null;
        var cf_release_thr: ?std.Thread = null;
        if (comptime builtin.os.tag != .ios) {
            const thr_obj = try alloc.create(CFReleaseThread);
            errdefer alloc.destroy(thr_obj);
            thr_obj.* = try .init(alloc);
            errdefer thr_obj.deinit();
            const thr = try std.Thread.spawn(.{}, CFReleaseThread.threadMain, .{thr_obj});
            thr.setName("cf_release") catch {};
            cf_release_thread = thr_obj;
            cf_release_thr = thr;
        }

        return .{"""

if old_create not in src:
    print("[!] coretext CF release thread creation block not found")
    sys.exit(1)
src = src.replace(old_create, new_create)

# Deinit: only join/stop the thread if it was created
old_deinit = """        // Stop the CF release thread
        {
            self.cf_release_thread.stop.notify() catch |err|
                log.err("error notifying cf release thread to stop, may stall err={}", .{err});
            self.cf_release_thr.join();
        }
        self.cf_release_thread.deinit();
        self.alloc.destroy(self.cf_release_thread);"""

new_deinit = """        // Stop the CF release thread (nil on iOS)
        if (self.cf_release_thread) |thr_obj| {
            thr_obj.stop.notify() catch |err|
                log.err("error notifying cf release thread to stop, may stall err={}", .{err});
            self.cf_release_thr.?.join();
            thr_obj.deinit();
            self.alloc.destroy(thr_obj);
        }"""

if old_deinit not in src:
    print("[!] coretext CF release thread deinit block not found")
    sys.exit(1)
src = src.replace(old_deinit, new_deinit)

# endFrame: guard the mailbox push behind an optional check.
# When nil (iOS), fall through to the synchronous release below.
old_end = """        // Send the items. If the send succeeds then we wake up the
        // thread to process the items. If the send fails then do a manual
        // cleanup.
        if (self.cf_release_thread.mailbox.push(.{ .release = .{
            .refs = items,
            .alloc = self.alloc,
        } }, .{ .forever = {} }) != 0) {
            self.cf_release_thread.wakeup.notify() catch |err| {
                log.warn(
                    "error notifying cf release thread to wake up, may stall err={}",
                    .{err},
                );
            };
            return;
        }

        for (items) |ref| macos.foundation.CFRelease(ref);"""

new_end = """        // Offload to the background release thread when available.
        // On iOS cf_release_thread is nil, so we fall through to sync release.
        if (self.cf_release_thread) |thr_obj| {
            if (thr_obj.mailbox.push(.{ .release = .{
                .refs = items,
                .alloc = self.alloc,
            } }, .{ .forever = {} }) != 0) {
                thr_obj.wakeup.notify() catch |err| {
                    log.warn(
                        "error notifying cf release thread to wake up, may stall err={}",
                        .{err},
                    );
                };
                return;
            }
        }

        for (items) |ref| macos.foundation.CFRelease(ref);"""

if old_end not in src:
    print("[!] coretext endFrame mailbox block not found")
    sys.exit(1)
src = src.replace(old_end, new_end)

path.write_text(src)
print("[+] patched coretext.zig: CF release thread disabled on iOS")
PY
    else
        echo "[+] coretext.zig already patched"
    fi
fi

# =============================================================================
# Patch 4: iosurface.zig — Explicit row byte alignment
#
# Problem: When creating an IOSurface without specifying bytesPerRow, the
# system picks whatever alignment it wants. Metal textures created from
# these surfaces may have mismatched row strides, causing corrupted or
# shifted glyph rendering (especially visible on font atlas textures).
#
# Fix: Calculate 64-byte-aligned row bytes and pass kIOSurfaceBytesPerRow
# when creating the IOSurface. Also suppress unused return value warnings
# from IOSurfaceLock/Unlock.
# =============================================================================
IOSURFACE="${SOURCE_DIR}/pkg/macos/iosurface/iosurface.zig"
if [ -f "$IOSURFACE" ]; then
    if ! grep -q 'kIOSurfaceBytesPerRow' "$IOSURFACE"; then
        python3 - "$IOSURFACE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
src = path.read_text()

# Compute aligned row stride before creating the Number objects
old_start = """    pub fn init(properties: Properties) Allocator.Error!*IOSurface {
        var w = try foundation.Number.create(.int, &properties.width);"""

new_start = """    pub fn init(properties: Properties) Allocator.Error!*IOSurface {
        // Ensure row stride is 64-byte aligned for Metal texture compatibility.
        const aligned_stride: c_int = @intCast(
            (properties.width * properties.bytes_per_element + 63) & ~@as(c_int, 63),
        );
        var w = try foundation.Number.create(.int, &properties.width);"""

if old_start not in src:
    print("[!] iosurface init start not found")
    sys.exit(1)
src = src.replace(old_start, new_start)

# Create a Number for the stride and include it in the dictionary
old_dict_setup = """        var bpe = try foundation.Number.create(.int, &properties.bytes_per_element);
        defer bpe.release();

        var properties_dict = try foundation.Dictionary.create("""

new_dict_setup = """        var bpe = try foundation.Number.create(.int, &properties.bytes_per_element);
        defer bpe.release();

        var stride_num = try foundation.Number.create(.int, &aligned_stride);
        defer stride_num.release();

        var properties_dict = try foundation.Dictionary.create("""

if old_dict_setup not in src:
    print("[!] iosurface bpe block not found")
    sys.exit(1)
src = src.replace(old_dict_setup, new_dict_setup)

# Extend the dictionary keys/values arrays
old_dict = """            &[_]?*const anyopaque{
                c.kIOSurfaceWidth,
                c.kIOSurfaceHeight,
                c.kIOSurfacePixelFormat,
                c.kIOSurfaceBytesPerElement,
            },
            &[_]?*const anyopaque{ w, h, pf, bpe },"""

new_dict = """            &[_]?*const anyopaque{
                c.kIOSurfaceWidth,
                c.kIOSurfaceHeight,
                c.kIOSurfacePixelFormat,
                c.kIOSurfaceBytesPerElement,
                c.kIOSurfaceBytesPerRow,
            },
            &[_]?*const anyopaque{ w, h, pf, bpe, stride_num },"""

if old_dict not in src:
    print("[!] iosurface dictionary keys not found")
    sys.exit(1)
src = src.replace(old_dict, new_dict)

# Silence unused return value from IOSurfaceLock/Unlock
src = src.replace(
    '        c.IOSurfaceLock(\n            @ptrCast(self),\n            0,\n            null,\n        );',
    '        _ = c.IOSurfaceLock(\n            @ptrCast(self),\n            0,\n            null,\n        );'
)
src = src.replace(
    '        c.IOSurfaceUnlock(\n            @ptrCast(self),\n            0,\n            null,\n        );',
    '        _ = c.IOSurfaceUnlock(\n            @ptrCast(self),\n            0,\n            null,\n        );'
)

path.write_text(src)
print("[+] patched iosurface.zig: 64-byte stride alignment for Metal")
PY
    else
        echo "[+] iosurface.zig already patched"
    fi
fi

# =============================================================================
# Patch 5: build.zig.zon — Update libxev to fix iOS kqueue mach port panic
#
# Problem: The bundled libxev uses mach ports for async wakeup on Darwin.
# Its kqueue backend checks `os.tag != .macos` and returns null for mach port
# kevents on non-macOS Darwin (iOS). The caller then unwraps null with `.?`
# causing a panic. A newer libxev version fixes this by properly supporting
# iOS as a Darwin target.
#
# Fix: Update the libxev dependency URL and hash to a version that handles
# iOS mach ports correctly.
# =============================================================================
BUILD_ZON="${SOURCE_DIR}/build.zig.zon"
if [ -f "$BUILD_ZON" ]; then
    if ! grep -q '7e7d2f2ab4700544657f8ec268715c8ef320d839' "$BUILD_ZON"; then
        sed -i '' 's|"https://deps.files.ghostty.org/libxev-34fa50878aec6e5fa8f532867001ab3c36fae23e.tar.gz"|"https://github.com/mitchellh/libxev/archive/7e7d2f2ab4700544657f8ec268715c8ef320d839.tar.gz"|' "$BUILD_ZON"
        sed -i '' 's|"libxev-0.0.0-86vtc4IcEwCqEYxEYoN_3KXmc6A9VLcm22aVImfvecYs"|"libxev-0.0.0-86vtcwE9EwB942iWRnaNMXHv3n0BeLAs_tVhrs5cT8cQ"|' "$BUILD_ZON"
        echo "[+] patched build.zig.zon: updated libxev for iOS mach port fix"
    else
        echo "[+] libxev already updated"
    fi
fi

echo "[+] all ios metal rendering patches applied"
