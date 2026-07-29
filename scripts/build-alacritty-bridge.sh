#!/bin/zsh
# Builds the Rust static library behind Kero's Alacritty backend and stages a
# single archive at a stable path for the linker.
#
# Xcode runs this as a build phase ahead of Compile Sources. It builds one
# slice per architecture in $ARCHS and lipos them together, so a universal
# release build gets a universal archive.
#
# ENABLE_USER_SCRIPT_SANDBOXING is on for this project, so a script phase may
# write only to its declared outputs and to TARGET_TEMP_DIR — not to SRCROOT,
# and not to DERIVED_FILE_DIR. Cargo opens Cargo.lock for write even under
# --locked, so the crate is copied into TARGET_TEMP_DIR and built from the
# copy; SRCROOT is only ever read.

set -euo pipefail

CRATE_DIR="${SRCROOT}/Vendor/alacritty-bridge"
OUTPUT_DIR="${BUILT_PRODUCTS_DIR}/alacritty-bridge"
OUTPUT="${OUTPUT_DIR}/libkero_alacritty.a"
WORK_DIR="${TARGET_TEMP_DIR}/alacritty-bridge"
BUILD_DIR="${WORK_DIR}/crate"

# Kept out of the declared output directory so a clean of the products tree
# does not silently discard the incremental cargo cache.
export CARGO_TARGET_DIR="${WORK_DIR}/target"

if ! command -v cargo > /dev/null 2>&1; then
  # Rustup and Homebrew installs are not on Xcode's stripped PATH.
  for candidate in "${HOME}/.cargo/bin" /opt/homebrew/bin /usr/local/bin; do
    [[ -x "${candidate}/cargo" ]] && export PATH="${candidate}:${PATH}"
  done
fi

if ! command -v cargo > /dev/null 2>&1; then
  echo "error: cargo not found. Kero's Alacritty backend needs a Rust toolchain — install it from https://rustup.rs and build again." >&2
  exit 1
fi

mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}"
# Copy rather than symlink: cargo resolves the manifest's real path, and a
# symlinked manifest lands back in the read-only source tree.
cp "${CRATE_DIR}/Cargo.toml" "${CRATE_DIR}/Cargo.lock" "${BUILD_DIR}/"
rm -rf "${BUILD_DIR}/src"
cp -R "${CRATE_DIR}/src" "${BUILD_DIR}/src"

slices=()
for arch in ${=ARCHS}; do
  case "${arch}" in
    arm64) target="aarch64-apple-darwin" ;;
    x86_64) target="x86_64-apple-darwin" ;;
    *) echo "error: unsupported architecture ${arch}" >&2; exit 1 ;;
  esac

  if ! rustup target list --installed 2>/dev/null | grep -qx "${target}"; then
    # Installing writes to ~/.rustup, which the script sandbox forbids, so say
    # so here instead of failing later with an unexplained linker error.
    echo "error: Rust target ${target} is not installed. Run: rustup target add ${target}" >&2
    exit 1
  fi

  # Always release: this is a terminal renderer's hot path, and a debug build
  # of the VT parser is slow enough to feel while typing.
  cargo build --release --locked --manifest-path "${BUILD_DIR}/Cargo.toml" --target "${target}"
  slices+=("${CARGO_TARGET_DIR}/${target}/release/libkero_alacritty.a")
done

if [[ ${#slices[@]} -eq 1 ]]; then
  cp "${slices[1]}" "${OUTPUT}"
else
  lipo -create "${slices[@]}" -output "${OUTPUT}"
fi

echo "[+] staged ${OUTPUT} (${ARCHS})"
