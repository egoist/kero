#!/usr/bin/env python3
"""Build the dev (Debug) app icon set from a recolored master image.

The orange recolor itself is produced with the `gpt-image` CLI (see the command
in RELEASING-style docstring below). gpt-image can't emit transparency, so its
output is a fully-opaque square. This script transplants the *original* icon's
alpha channel — which defines the exact rounded-rect silhouette and its padding
— onto the recolored RGB, then renders every size the asset catalog needs.

    # 1. recolor with gpt-image (OAuth via Codex login or OPENAI_API_KEY):
    bunx gpt-image edit "recolor green -> orange, keep everything else identical" \
        -i kero/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png \
        -o /tmp/dev-master.png --size 1024x1024 --quality high

    # 2. assemble AppIcon-Dev.appiconset from that master:
    python3 scripts/make-dev-icon.py /tmp/dev-master.png

Pure standard library (zlib) + `sips` for resampling — no third-party packages.
"""

import json
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "kero" / "Assets.xcassets"
SRC = ASSETS / "AppIcon.appiconset"
DST = ASSETS / "AppIcon-Dev.appiconset"
ALPHA_REF = SRC / "icon_512x512@2x.png"  # 1024x1024 production master (has alpha)

PNG_SIG = b"\x89PNG\r\n\x1a\n"


def load_png(path):
    """Decode an 8-bit PNG to (width, height, RGBA bytearray)."""
    data = Path(path).read_bytes()
    assert data[:8] == PNG_SIG, f"{path} is not a PNG"
    off, width, height, color_type, interlace, idat = 8, 0, 0, 0, 0, bytearray()
    while off < len(data):
        (length,) = struct.unpack(">I", data[off : off + 4])
        ctype = data[off + 4 : off + 8]
        cdata = data[off + 8 : off + 8 + length]
        off += 12 + length
        if ctype == b"IHDR":
            width, height, bit_depth, color_type, _c, _f, interlace = struct.unpack(
                ">IIBBBBB", cdata
            )
            assert bit_depth == 8 and interlace == 0, f"{path}: unsupported PNG"
        elif ctype == b"IDAT":
            idat += cdata
        elif ctype == b"IEND":
            break

    channels = {2: 3, 6: 4}[color_type]  # truecolor / truecolor+alpha
    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    flat = bytearray(height * stride)
    pos = 0
    for y in range(height):
        ftype = raw[pos]
        pos += 1
        line = raw[pos : pos + stride]
        pos += stride
        ro, po = y * stride, (y - 1) * stride
        for i in range(stride):
            x = line[i]
            a = flat[ro + i - channels] if i >= channels else 0
            b = flat[po + i] if y > 0 else 0
            c = flat[po + i - channels] if (y > 0 and i >= channels) else 0
            if ftype == 0:
                r = x
            elif ftype == 1:
                r = x + a
            elif ftype == 2:
                r = x + b
            elif ftype == 3:
                r = x + ((a + b) >> 1)
            elif ftype == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                r = x + (a if (pa <= pb and pa <= pc) else (b if pb <= pc else c))
            else:
                raise ValueError(f"bad filter {ftype}")
            flat[ro + i] = r & 0xFF

    if channels == 4:
        return width, height, flat
    rgba = bytearray(width * height * 4)  # pad opaque RGB -> RGBA
    for px in range(width * height):
        rgba[px * 4 : px * 4 + 3] = flat[px * 3 : px * 3 + 3]
        rgba[px * 4 + 3] = 255
    return width, height, rgba


def save_png(path, width, height, rgba):
    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter: None
        raw += rgba[y * stride : (y + 1) * stride]

    def chunk(ctype, cdata):
        return (
            struct.pack(">I", len(cdata))
            + ctype
            + cdata
            + struct.pack(">I", zlib.crc32(ctype + cdata) & 0xFFFFFFFF)
        )

    Path(path).write_bytes(
        PNG_SIG
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def sips_resize(src, dst, size):
    subprocess.run(
        ["sips", "-z", str(size), str(size), str(src), "--out", str(dst)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: make-dev-icon.py <recolored-master.png>")
    master_src = sys.argv[1]
    DST.mkdir(exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)

        # Normalize the recolored master to the alpha reference's dimensions so
        # the two align pixel-for-pixel, then swap in the original's alpha.
        aw, ah, alpha_rgba = load_png(ALPHA_REF)
        norm = tmp / "master-norm.png"
        sips_resize(master_src, norm, aw)  # square icons: one dimension suffices
        _, _, rgb = load_png(norm)
        for px in range(aw * ah):
            rgb[px * 4 + 3] = alpha_rgba[px * 4 + 3]
        master = tmp / "master-rgba.png"
        save_png(master, aw, ah, rgb)

        # Render every filename declared in the production Contents.json at its
        # true pixel size (size * scale).
        contents = json.loads((SRC / "Contents.json").read_text())
        for img in contents["images"]:
            side = int(img["size"].split("x")[0]) * int(img["scale"].rstrip("x"))
            sips_resize(master, DST / img["filename"], side)
            print(f"  {img['filename']}  ({side}x{side})")

    (DST / "Contents.json").write_text((SRC / "Contents.json").read_text())
    print(f"Wrote dev icon set -> {DST}")


if __name__ == "__main__":
    main()
