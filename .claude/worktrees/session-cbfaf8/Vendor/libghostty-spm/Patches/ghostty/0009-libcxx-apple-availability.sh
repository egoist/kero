#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# Zig's bundled libc++ headers ship with Apple vendor availability annotations
# disabled, so C++ code references runtime symbols that the Apple system
# libc++.1.dylib may not export at our deployment floors (e.g.
# std::__1::__libcpp_verbose_abort, exported only since iOS 16.3 /
# macOS 13.3 / tvOS 16.3). Forcing the annotations on makes libc++ headers
# degrade gracefully below those floors (exactly like Apple SDK clang) and
# turns any hard dependency on a too-new symbol into a compile error instead
# of a dyld crash at app launch.
#
# -Wno-macro-redefined: zig predefines the macro to 0 on its own command
# line; our -D override redefines it.

# Patch 1: highway flags (hwy/abort.cc et al reference __libcpp_verbose_abort
# through the -fno-exceptions throw helpers)
HIGHWAY_BUILD="${SOURCE_DIR}/pkg/highway/build.zig"
if [ ! -f "$HIGHWAY_BUILD" ]; then
    echo "[-] missing: $HIGHWAY_BUILD; upstream changed, update this patch"
    exit 1
fi
if ! grep -q '_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS' "$HIGHWAY_BUILD"; then
    perl -0pi -e 's/try flags\.appendSlice\(b\.allocator, &\.\{\n/try flags.appendSlice(b.allocator, &.{\n        "-D_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS=1",\n        "-Wno-macro-redefined",\n/' "$HIGHWAY_BUILD"
    grep -q '_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS' "$HIGHWAY_BUILD" || {
        echo "[-] highway flags block not found; upstream changed, update this patch"
        exit 1
    }
    echo "[+] patched: highway libc++ availability annotations"
else
    echo "[+] highway libc++ availability already patched"
fi

# Patch 2: simdutf flags
SIMDUTF_BUILD="${SOURCE_DIR}/pkg/simdutf/build.zig"
if [ ! -f "$SIMDUTF_BUILD" ]; then
    echo "[-] missing: $SIMDUTF_BUILD; upstream changed, update this patch"
    exit 1
fi
if ! grep -q '_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS' "$SIMDUTF_BUILD"; then
    perl -0pi -e 's/try flags\.appendSlice\(b\.allocator, &\.\{\n/try flags.appendSlice(b.allocator, &.{\n        "-D_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS=1",\n        "-Wno-macro-redefined",\n/' "$SIMDUTF_BUILD"
    grep -q '_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS' "$SIMDUTF_BUILD" || {
        echo "[-] simdutf flags block not found; upstream changed, update this patch"
        exit 1
    }
    echo "[+] patched: simdutf libc++ availability annotations"
else
    echo "[+] simdutf libc++ availability already patched"
fi

# Patch 3: ghostty's own C++ SIMD sources (src/simd/*.cpp)
SHARED_DEPS="${SOURCE_DIR}/src/build/SharedDeps.zig"
if [ ! -f "$SHARED_DEPS" ]; then
    echo "[-] missing: $SHARED_DEPS; upstream changed, update this patch"
    exit 1
fi
if grep -q 'HWY_NO_LIBCXX' "$SHARED_DEPS" &&
    grep -q 'SIMDUTF_NO_LIBCXX' "$SHARED_DEPS"; then
    echo "[+] src/simd already builds without libc++"
elif ! grep -q '_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS' "$SHARED_DEPS"; then
    python3 - "$SHARED_DEPS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old_flags = """            .flags = if (target.result.cpu.arch == .x86_64) &.{
                b.fmt("-DHWY_DISABLED_TARGETS={}", .{HWY_DISABLED_TARGETS}),
            } else &.{},"""

new_flags = """            .flags = if (target.result.cpu.arch == .x86_64) &.{
                "-D_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS=1",
                "-Wno-macro-redefined",
                b.fmt("-DHWY_DISABLED_TARGETS={}", .{HWY_DISABLED_TARGETS}),
            } else &.{
                "-D_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS=1",
                "-Wno-macro-redefined",
            },"""

if old_flags not in text:
    print("[-] src/simd flags block not found; upstream changed, update this patch")
    sys.exit(1)

path.write_text(text.replace(old_flags, new_flags))
print("[+] patched: src/simd libc++ availability annotations")
PY
else
    echo "[+] src/simd libc++ availability already patched"
fi

echo "[+] all libcxx-apple-availability patches applied"
