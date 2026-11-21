#!/usr/bin/env python3
"""Extract App Store screenshots from one or more .xcresult bundles.

Exports XCTAttachments named `<locale>__<device>__<name>` (for example
`en-US__iphone__01-change-page`) into:

    appstore/screenshots/<locale>/<device>/<name>.png

Converts RGBA PNGs to opaque RGB PNGs losslessly (App Store Connect rejects
transparency) without resizing any image, then prints a pixel-size table.

Usage:
    scripts/extract-appstore-screenshots.py [--out appstore/screenshots] <bundle.xcresult> [...]
"""

import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

PNG_SIG = b"\x89PNG\r\n\x1a\n"
NAME_RE = re.compile(r"^(en-US|zh-Hans|zh-Hant)__(iphone|ipad)__([0-9]{2}-[a-z0-9-]+)")


def paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def strip_png_alpha_lossless(src_path: str, dst_path: str) -> tuple[int, int, bool]:
    """Copy a PNG to dst_path, stripping alpha losslessly if color_type == 6 (RGBA).

    Returns (width, height, stripped_alpha). Never resizes.
    """
    with open(src_path, "rb") as fh:
        data = fh.read()
    if data[:8] != PNG_SIG:
        raise ValueError(f"{src_path} is not a PNG file")

    pos = 8
    chunks = []
    width = height = bit_depth = color_type = None
    idat_parts = []
    while pos < len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        ctype = data[pos + 4 : pos + 8]
        cdata = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            width, height, bit_depth, color_type, comp, filt, interlace = struct.unpack(">IIBBBBB", cdata)
            if comp != 0 or filt != 0 or interlace != 0:
                raise ValueError(f"Unsupported PNG IHDR in {src_path}")
        elif ctype == b"IDAT":
            idat_parts.append(cdata)
        elif ctype not in (b"IEND", b"tRNS"):
            chunks.append((ctype, cdata))

    if width is None or height is None:
        raise ValueError(f"Missing IHDR in {src_path}")

    if color_type == 2:
        shutil.copyfile(src_path, dst_path)
        return width, height, False

    if color_type != 6 or bit_depth != 8:
        raise ValueError(f"Unsupported PNG format (color_type={color_type}, bit_depth={bit_depth}) in {src_path}")

    raw = zlib.decompress(b"".join(idat_parts))
    bpp = 4
    stride = width * bpp
    rgb_rows = bytearray()
    prev = bytes(stride)
    offset = 0

    for _ in range(height):
        ftype = raw[offset]
        offset += 1
        row = bytearray(raw[offset : offset + stride])
        offset += stride

        if ftype == 1:  # Sub
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif ftype == 2:  # Up
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 0xFF
        elif ftype == 3:  # Average
            for i in range(stride):
                left = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:  # Paeth
            for i in range(stride):
                left = row[i - bpp] if i >= bpp else 0
                up = prev[i]
                up_left = prev[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + paeth(left, up, up_left)) & 0xFF
        elif ftype != 0:
            raise ValueError(f"Unknown PNG filter type {ftype} in {src_path}")

        prev = bytes(row)
        # Drop the alpha byte (every 4th byte), keeping RGB untouched; filter 0.
        rgb_rows.append(0)
        # Fast slice extraction of R, G, B bytes.
        rgb = bytearray(width * 3)
        rgb[0::3] = row[0::4]
        rgb[1::3] = row[1::4]
        rgb[2::3] = row[2::4]
        rgb_rows.extend(rgb)

    def make_chunk(ctype: bytes, payload: bytes) -> bytes:
        crc = zlib.crc32(ctype)
        crc = zlib.crc32(payload, crc) & 0xFFFFFFFF
        return struct.pack(">I", len(payload)) + ctype + payload + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    compressed = zlib.compress(bytes(rgb_rows), level=6)

    out = bytearray(PNG_SIG)
    out.extend(make_chunk(b"IHDR", ihdr))
    for ctype, cdata in chunks:
        out.extend(make_chunk(ctype, cdata))
    out.extend(make_chunk(b"IDAT", compressed))
    out.extend(make_chunk(b"IEND", b""))

    with open(dst_path, "wb") as fh:
        fh.write(out)
    return width, height, True


def export_bundle(bundle_path: str, tmpdir: str) -> list[tuple[str, str]]:
    """Run xcresulttool export attachments and return [(suggested_name, file_path)]."""
    export_dir = os.path.join(tmpdir, f"export-{abs(hash(bundle_path))}")
    os.makedirs(export_dir, exist_ok=True)
    subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "export",
            "attachments",
            "--path",
            bundle_path,
            "--output-path",
            export_dir,
        ],
        check=True,
    )
    manifest_path = os.path.join(export_dir, "manifest.json")
    if not os.path.isfile(manifest_path):
        return []
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)

    results = []
    for entry in manifest:
        for att in entry.get("attachments", []):
            suggested = att.get("suggestedHumanReadableName", "")
            exported = att.get("exportedFileName", "")
            if not suggested or not exported:
                continue
            full = os.path.join(export_dir, exported)
            if os.path.isfile(full):
                results.append((suggested, full))
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract App Store screenshots from .xcresult bundles.")
    parser.add_argument("--out", default="appstore/screenshots", help="Destination screenshots directory")
    parser.add_argument("bundles", nargs="+", help="One or more .xcresult bundle paths")
    args = parser.parse_args()

    extracted = []
    with tempfile.TemporaryDirectory(prefix="wuko-shots-") as tmpdir:
        for bundle in args.bundles:
            if not os.path.exists(bundle):
                print(f"ERROR: bundle not found: {bundle}", file=sys.stderr)
                return 2
            for suggested, src_path in export_bundle(bundle, tmpdir):
                m = NAME_RE.match(suggested)
                if not m:
                    continue
                locale, device, shot_name = m.group(1), m.group(2), m.group(3)
                dst_dir = os.path.join(args.out, locale, device)
                os.makedirs(dst_dir, exist_ok=True)
                dst_path = os.path.join(dst_dir, f"{shot_name}.png")
                w, h, stripped = strip_png_alpha_lossless(src_path, dst_path)
                extracted.append((locale, device, f"{shot_name}.png", w, h, stripped, os.path.getsize(dst_path)))

    if not extracted:
        print("ERROR: no matching screenshot attachments found.", file=sys.stderr)
        return 1

    extracted.sort()
    print(f"{'Locale':<8} {'Device':<7} {'File':<28} {'Pixels':<11} {'Alpha':<8} {'Size'}")
    print("-" * 76)
    for locale, device, fname, w, h, stripped, size in extracted:
        alpha_str = "stripped" if stripped else "opaque"
        print(f"{locale:<8} {device:<7} {fname:<28} {w}x{h:<6} {alpha_str:<8} {size // 1024} KB")
    print(f"\nExtracted {len(extracted)} screenshots into {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
