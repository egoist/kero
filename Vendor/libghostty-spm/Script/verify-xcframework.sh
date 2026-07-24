#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f .root ]; then
    echo "[*] malformed project structure"
    exit 1
fi

INPUT_PATH=${1:-}

if [ -z "$INPUT_PATH" ]; then
    echo "Usage: $0 <xcframework_or_zip>"
    exit 1
fi

if [ ! -e "$INPUT_PATH" ]; then
    echo "[!] not found: $INPUT_PATH"
    exit 1
fi

TEMP_DIR=
XCFRAMEWORK_PATH="$INPUT_PATH"

cleanup() {
    if [ -n "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

if [[ "$INPUT_PATH" == *.zip ]]; then
    TEMP_DIR=$(mktemp -d)
    ditto -x -k "$INPUT_PATH" "$TEMP_DIR"
    XCFRAMEWORK_PATH=$(find "$TEMP_DIR" -maxdepth 1 -name "*.xcframework" -type d | head -1)
fi

if [ -z "$XCFRAMEWORK_PATH" ] || [ ! -d "$XCFRAMEWORK_PATH" ]; then
    echo "[!] xcframework not found in input: $INPUT_PATH"
    exit 1
fi

python3 - "$XCFRAMEWORK_PATH" <<'PY'
import os
import plistlib
import subprocess
import sys

xcframework = sys.argv[1]
info_path = os.path.join(xcframework, "Info.plist")

if not os.path.isfile(info_path):
    raise SystemExit(f"[!] missing xcframework Info.plist: {info_path}")

for root, dirs, _ in os.walk(xcframework):
    for directory in dirs:
        if directory.endswith(".framework"):
            raise SystemExit(f"[!] framework wrapper is not allowed in static-library xcframework: {os.path.join(root, directory)}")

with open(info_path, "rb") as handle:
    info = plistlib.load(handle)

libraries = info.get("AvailableLibraries")
if not isinstance(libraries, list) or not libraries:
    raise SystemExit("[!] AvailableLibraries is empty or missing")

for library in libraries:
    identifier = library.get("LibraryIdentifier")
    library_path = library.get("LibraryPath")
    binary_path = library.get("BinaryPath")
    headers_path = library.get("HeadersPath")
    platform = library.get("SupportedPlatform")
    platform_variant = library.get("SupportedPlatformVariant")
    declared_architectures = set(library.get("SupportedArchitectures", []))

    if not identifier:
        raise SystemExit("[!] library entry missing LibraryIdentifier")
    if platform not in {"ios", "macos", "tvos", "watchos", "xros"}:
        raise SystemExit(f"[!] unsupported platform in {identifier}: {platform}")
    if library_path != "libghostty.a" or binary_path != "libghostty.a":
        raise SystemExit(f"[!] {identifier} must reference libghostty.a, got LibraryPath={library_path!r} BinaryPath={binary_path!r}")
    if headers_path != "Headers":
        raise SystemExit(f"[!] {identifier} must use HeadersPath=Headers, got {headers_path!r}")

    variant_dir = os.path.join(xcframework, identifier)
    archive_path = os.path.join(variant_dir, library_path)
    headers_dir = os.path.join(variant_dir, headers_path)
    header_path = os.path.join(headers_dir, "ghostty.h")
    modulemap_path = os.path.join(headers_dir, "module.modulemap")

    for required_path in (archive_path, header_path, modulemap_path):
        if not os.path.exists(required_path):
            raise SystemExit(f"[!] {identifier} missing required file: {required_path}")

    actual_architectures = set(
        subprocess.check_output(["lipo", "-archs", archive_path], text=True).split()
    )
    if actual_architectures != declared_architectures:
        raise SystemExit(
            f"[!] {identifier} architecture metadata mismatch: "
            f"plist={sorted(declared_architectures)} archive={sorted(actual_architectures)}"
        )

    expected_architectures = {
        ("macos", None): {"arm64", "arm64e", "x86_64"},
        ("ios", None): {"arm64", "arm64e"},
        ("ios", "maccatalyst"): {"arm64", "arm64e", "x86_64"},
        ("ios", "simulator"): {"arm64", "x86_64"},
    }.get((platform, platform_variant))
    if expected_architectures is not None and actual_architectures != expected_architectures:
        raise SystemExit(
            f"[!] {identifier} architectures must be {sorted(expected_architectures)}, "
            f"got {sorted(actual_architectures)}"
        )

    with open(modulemap_path, "r", encoding="utf-8") as handle:
        modulemap = handle.read()
    if "framework module libghostty" in modulemap:
        raise SystemExit(f"[!] {identifier} module map must not declare a framework module")
    if "module libghostty" not in modulemap:
        raise SystemExit(f"[!] {identifier} module map does not declare module libghostty")

print(f"[*] verified static-library xcframework layout and architectures: {xcframework}")
PY
