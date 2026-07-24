#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

MARKER="LIBGHOSTTY_SPM_INSPECTOR_DISABLE"

if grep -q "$MARKER" "$SOURCE_DIR/src/build/Config.zig" 2>/dev/null; then
    echo "[+] inspector disable patch already applied"
    exit 0
fi

python3 - "$SOURCE_DIR" "$MARKER" <<'PYEOF'
import sys
from pathlib import Path

source_dir = Path(sys.argv[1])
marker = sys.argv[2]

def patch_file(rel_path, replacements):
    path = source_dir / rel_path
    text = path.read_text()
    for old, new in replacements:
        if old not in text:
            print(f"[-] pattern not found in {rel_path}:")
            print(f"    {old[:80]}...")
            sys.exit(1)
        count = text.count(old)
        if count > 1:
            print(f"[-] pattern matched {count} times in {rel_path} (expected 1):")
            print(f"    {old[:80]}...")
            sys.exit(1)
        text = text.replace(old, new, 1)
    path.write_text(text)
    print(f"[+] patched {rel_path}")

# ──────────────────────────────────────────────────────────────────────
# 1. Config.zig — add inspector feature flag
#    (runs AFTER 0006, so custom_shaders line already exists)
# ──────────────────────────────────────────────────────────────────────
patch_file("src/build/Config.zig", [
    # Add field after custom_shaders (added by 0006)
    (
        f"custom_shaders: bool = true, // LIBGHOSTTY_SPM_TRIM_PATCH",
        f"custom_shaders: bool = true, // LIBGHOSTTY_SPM_TRIM_PATCH\n"
        f"inspector: bool = true, // {marker}",
    ),
    # Add option parsing after the custom_shaders option block (added by 0006)
    (
        '        "custom-shaders",\n'
        '        "Build with custom shader (glslang/spirv-cross) support.",\n'
        '    ) orelse true;',
        '        "custom-shaders",\n'
        '        "Build with custom shader (glslang/spirv-cross) support.",\n'
        '    ) orelse true;\n'
        '\n'
        '    config.inspector = b.option(\n'
        '        bool,\n'
        '        "inspector",\n'
        '        "Build with terminal inspector (dcimgui) support.",\n'
        '    ) orelse true;',
    ),
    # Add to addOptions after custom_shaders (added by 0006)
    (
        '    step.addOption(bool, "custom_shaders", self.custom_shaders);',
        '    step.addOption(bool, "custom_shaders", self.custom_shaders);\n'
        '    step.addOption(bool, "inspector", self.inspector);',
    ),
])

# ──────────────────────────────────────────────────────────────────────
# 2. SharedDeps.zig — gate dcimgui linking on inspector flag
# ──────────────────────────────────────────────────────────────────────
patch_file("src/build/SharedDeps.zig", [
    (
        '    // cimgui\n'
        '    if (b.lazyDependency("dcimgui", .{',
        '    // cimgui — only needed for inspector\n'
        '    if (self.config.inspector) if (b.lazyDependency("dcimgui", .{',
    ),
    # Close the extra if — find the end of the dcimgui block
    (
        '        );\n'
        '    }\n'
        '\n'
        '    // Fonts',
        '        );\n'
        '    };\n'
        '\n'
        '    // Fonts',
    ),
])

# ──────────────────────────────────────────────────────────────────────
# 3. build_config.zig — re-export inspector flag
#    (runs AFTER 0006, so custom_shaders line already exists)
# ──────────────────────────────────────────────────────────────────────
patch_file("src/build_config.zig", [
    (
        'pub const custom_shaders = options.custom_shaders;',
        'pub const custom_shaders = options.custom_shaders;\n'
        'pub const inspector = options.inspector;',
    ),
])

# ──────────────────────────────────────────────────────────────────────
# 4. inspector/main.zig — COMPLETE FILE REPLACEMENT with stub module
#
#    This is the key stability improvement. Instead of pattern-matching
#    downstream files, we replace the single chokepoint module with
#    stubs that satisfy all downstream type/method requirements.
#    When inspector=true, everything re-exports as before.
#    When inspector=false, stub types with no-op methods are provided
#    so Surface.zig, renderer, termio all compile without modification.
# ──────────────────────────────────────────────────────────────────────
inspector_main = source_dir / "src/inspector/main.zig"
inspector_main.write_text('''\
const build_config = @import("../build_config.zig");
const std = @import("std");
const terminal = @import("../terminal/main.zig");
const input = @import("../input.zig");
const renderer = @import("../renderer.zig");

pub const widgets = if (build_config.inspector) @import("widgets.zig") else struct {
    pub const key = struct {
        pub const Event = StubKeyEvent;
    };
    pub const renderer = struct {
        pub const Info = StubRendererInfo;
    };
    pub const surface = struct {
        pub const Mouse = StubMouse;
    };
};

pub const Inspector = if (build_config.inspector) @import("Inspector.zig") else StubInspector;
pub const KeyEvent = widgets.key.Event;

/// Stub types — these satisfy all downstream method/field accesses
/// when inspector is disabled, so no other files need patching.

const StubMouse = struct {
    last_xpos: f64 = 0,
    last_ypos: f64 = 0,
    last_point: ?terminal.Pin = null,
};

const StubRendererInfo = struct {
    pub const empty: @This() = .{};

    pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}

    pub fn overlayFeatures(
        _: *const @This(),
        _: std.mem.Allocator,
    ) std.mem.Allocator.Error![]renderer.Overlay.Feature {
        return &.{};
    }
};

const StubKeyEvent = struct {
    event: input.KeyEvent = undefined,
    binding: []const input.Binding.Action = &.{},
    pty: []const u8 = "",

    pub fn deinit(_: *const @This(), _: std.mem.Allocator) void {}
};

const StubInspector = struct {
    mouse: StubMouse = .{},

    pub fn setup() void {}
    pub fn init(_: std.mem.Allocator) !@This() { return .{}; }
    pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
    pub fn render(_: *@This(), _: anytype) void {}

    pub fn rendererInfo(_: *@This()) *StubRendererInfo {
        return &stub_renderer_info;
    }

    pub fn recordKeyEvent(
        _: *@This(),
        _: std.mem.Allocator,
        _: StubKeyEvent,
    ) std.mem.Allocator.Error!void {}

    pub fn recordPtyRead(
        _: *@This(),
        _: std.mem.Allocator,
        _: *terminal.Terminal,
        _: []const u8,
    ) !void {}

    var stub_renderer_info: StubRendererInfo = .{};
};

test {
    if (build_config.inspector) {
        @import("std").testing.refAllDecls(@This());
    }
}
''')
print("[+] replaced src/inspector/main.zig with stub module")

# ──────────────────────────────────────────────────────────────────────
# 5. input/key.zig — gate dcimgui import + imguiKey method
# ──────────────────────────────────────────────────────────────────────
patch_file("src/input/key.zig", [
    (
        'const cimgui = @import("dcimgui");',
        'const _build_config = @import("../build_config.zig");\n'
        'const cimgui = if (_build_config.inspector) @import("dcimgui") else struct {};',
    ),
    (
        '    pub fn imguiKey(self: Key) ?c_int {',
        '    pub fn imguiKey(self: Key) ?c_int {\n'
        '            if (comptime !_build_config.inspector) return null;',
    ),
])

# ──────────────────────────────────────────────────────────────────────
# 6. apprt/embedded.zig — gate Inspector struct + CoreInspector import
# ──────────────────────────────────────────────────────────────────────
embedded_path = source_dir / "src/apprt/embedded.zig"
text = embedded_path.read_text()

# 6a. Gate CoreInspector import
old = 'const CoreInspector = @import("../inspector/main.zig").Inspector;'
new = 'const CoreInspector = if (@import("../build_config.zig").inspector) @import("../inspector/main.zig").Inspector else struct {};'
assert old in text, f"pattern not found: {old}"
text = text.replace(old, new, 1)

# 6b. Gate the Inspector struct definition using brace-depth counting
# Find the struct opening
struct_marker = 'pub const Inspector = struct {\n    const cimgui = @import("dcimgui");'
assert struct_marker in text, f"Inspector struct marker not found"

struct_start_idx = text.index('pub const Inspector = struct {\n    const cimgui = @import("dcimgui");')
# Find the opening brace
brace_start = text.index('{', struct_start_idx)
# Count braces to find the matching close
depth = 0
i = brace_start
while i < len(text):
    if text[i] == '{':
        depth += 1
    elif text[i] == '}':
        depth -= 1
        if depth == 0:
            break
    i += 1
# i now points to the closing }
# The struct ends with `};` — we want to capture up to and including `}`
# but NOT the `;` since the semicolon will come after the else branch
struct_end_brace = i + 1  # position after closing }
# Check for trailing semicolon to know where to resume after replacement
struct_end = struct_end_brace
if struct_end < len(text) and text[struct_end] == ';':
    struct_end += 1  # skip the original ; in the replacement range

# Extract the original struct content (up to } but not ;)
original_struct = text[struct_start_idx:struct_end_brace]

# Wrap: replace opening with comptime conditional
new_struct = original_struct.replace(
    'pub const Inspector = struct {',
    'pub const Inspector = if (@import("../build_config.zig").inspector) struct {',
    1,
)

# Add else branch after closing };
stub = """ else struct {
    surface: *Surface = undefined,
    pub fn init(_: *Surface) !@This() { return .{}; }
    pub fn deinit(_: *@This()) void {}
};"""
new_struct = new_struct + stub

text = text[:struct_start_idx] + new_struct + text[struct_end:]

# 6c. Gate initInspector body
old_init = """    pub fn initInspector(self: *Surface) !*Inspector {
        if (self.inspector) |v| return v;

        const alloc = self.app.core_app.alloc;
        const inspector = try alloc.create(Inspector);
        errdefer alloc.destroy(inspector);
        inspector.* = try .init(self);
        self.inspector = inspector;
        return inspector;
    }"""
new_init = """    pub fn initInspector(self: *Surface) !*Inspector {
        if (comptime !@import("../build_config.zig").inspector) return error.InspectorUnavailable;
        if (self.inspector) |v| return v;

        const alloc = self.app.core_app.alloc;
        const inspector = try alloc.create(Inspector);
        errdefer alloc.destroy(inspector);
        inspector.* = try .init(self);
        self.inspector = inspector;
        return inspector;
    }"""
assert old_init in text, "initInspector pattern not found"
text = text.replace(old_init, new_init, 1)

# 6d. Gate freeInspector body
old_free = """    pub fn freeInspector(self: *Surface) void {
        if (self.inspector) |v| {
            v.deinit();
            self.app.core_app.alloc.destroy(v);
            self.inspector = null;
        }
    }"""
new_free = """    pub fn freeInspector(self: *Surface) void {
        if (comptime !@import("../build_config.zig").inspector) return;
        if (self.inspector) |v| {
            v.deinit();
            self.app.core_app.alloc.destroy(v);
            self.inspector = null;
        }
    }"""
assert old_free in text, "freeInspector pattern not found"
text = text.replace(old_free, new_free, 1)

# 6e. Gate CAPI inspector functions that call methods on Inspector
# These functions take *Inspector and call methods that don't exist on the stub struct.
# We add comptime early-returns so the method calls are never analyzed.
capi_guards = [
    ('    export fn ghostty_inspector_set_size(ptr: *Inspector, w: u32, h: u32) void {\n'
     '        ptr.updateSize(w, h);',
     '    export fn ghostty_inspector_set_size(ptr: *Inspector, w: u32, h: u32) void {\n'
     '        if (comptime !@import("../build_config.zig").inspector) return;\n'
     '        ptr.updateSize(w, h);'),
    ('    export fn ghostty_inspector_set_content_scale(ptr: *Inspector, x: f64, y: f64) void {\n'
     '        ptr.updateContentScale(x, y);',
     '    export fn ghostty_inspector_set_content_scale(ptr: *Inspector, x: f64, y: f64) void {\n'
     '        if (comptime !@import("../build_config.zig").inspector) return;\n'
     '        ptr.updateContentScale(x, y);'),
    ('        ptr.mouseButtonCallback(\n'
     '            action,\n'
     '            button,',
     '        if (comptime !@import("../build_config.zig").inspector) return;\n'
     '        ptr.mouseButtonCallback(\n'
     '            action,\n'
     '            button,'),
    ('    export fn ghostty_inspector_mouse_pos(ptr: *Inspector, x: f64, y: f64) void {\n'
     '        ptr.cursorPosCallback(x, y);',
     '    export fn ghostty_inspector_mouse_pos(ptr: *Inspector, x: f64, y: f64) void {\n'
     '        if (comptime !@import("../build_config.zig").inspector) return;\n'
     '        ptr.cursorPosCallback(x, y);'),
    ('        ptr.scrollCallback(\n'
     '            x,\n'
     '            y,',
     '        if (comptime !@import("../build_config.zig").inspector) return;\n'
     '        ptr.scrollCallback(\n'
     '            x,\n'
     '            y,'),
    ('        ptr.keyCallback(\n'
     '            action,\n'
     '            key,',
     '        if (comptime !@import("../build_config.zig").inspector) return;\n'
     '        ptr.keyCallback(\n'
     '            action,\n'
     '            key,'),
    ('    export fn ghostty_inspector_text(\n'
     '        ptr: *Inspector,\n'
     '        str: [*:0]const u8,\n'
     '    ) void {\n'
     '        ptr.textCallback(std.mem.sliceTo(str, 0));',
     '    export fn ghostty_inspector_text(\n'
     '        ptr: *Inspector,\n'
     '        str: [*:0]const u8,\n'
     '    ) void {\n'
     '        if (comptime !@import("../build_config.zig").inspector) return;\n'
     '        ptr.textCallback(std.mem.sliceTo(str, 0));'),
    ('    export fn ghostty_inspector_set_focus(ptr: *Inspector, focused: bool) void {\n'
     '        ptr.focusCallback(focused);',
     '    export fn ghostty_inspector_set_focus(ptr: *Inspector, focused: bool) void {\n'
     '        if (comptime !@import("../build_config.zig").inspector) return;\n'
     '        ptr.focusCallback(focused);'),
    ('        export fn ghostty_inspector_metal_init(ptr: *Inspector, device: objc.c.id) bool {\n'
     '            return ptr.initMetal(.fromId(device));',
     '        export fn ghostty_inspector_metal_init(ptr: *Inspector, device: objc.c.id) bool {\n'
     '            if (comptime !@import("../build_config.zig").inspector) return false;\n'
     '            return ptr.initMetal(.fromId(device));'),
    ('            return ptr.renderMetal(\n'
     '                .fromId(command_buffer),',
     '            if (comptime !@import("../build_config.zig").inspector) return;\n'
     '            return ptr.renderMetal(\n'
     '                .fromId(command_buffer),'),
    ('        export fn ghostty_inspector_metal_shutdown(ptr: *Inspector) void {\n'
     '            if (ptr.backend) |v| {',
     '        export fn ghostty_inspector_metal_shutdown(ptr: *Inspector) void {\n'
     '            if (comptime !@import("../build_config.zig").inspector) return;\n'
     '            if (ptr.backend) |v| {'),
]
for old_capi, new_capi in capi_guards:
    assert old_capi in text, f"CAPI pattern not found: {old_capi[:60]}..."
    text = text.replace(old_capi, new_capi, 1)

embedded_path.write_text(text)
print("[+] patched apprt/embedded.zig")

print(f"[+] all inspector patches complete ({marker})")
PYEOF

echo "[+] inspector disable patch applied"
