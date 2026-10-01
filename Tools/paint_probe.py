#!/usr/bin/env python3
"""
Report the dominant body paint colour of a .glb car.

The app recolours a car by rewriting the hue of its base-colour map, and to do
that it needs to know which hue counts as "the paint" - the Kenney cars sample a
single flat swatch out of a shared palette atlas, while the supercar uses a
painted texture. Both are found the same way here: walk the body triangles,
sample the texture at each triangle's UV centroid, and weight by triangle area.

Usage:
    python3 paint_probe.py <input.glb> [--texture <file.png>]
"""

from __future__ import annotations

import argparse
import colorsys
import re
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from glb_to_usdz import read_glb, read_accessor  # noqa: E402

NON_BODY = re.compile(r"wheel|tire|tyre|glass|window", re.IGNORECASE)


# --------------------------------------------------------------------- images

def load_pixels(path: Path):
    """Return (width, height, getpixel) for any image macOS can read."""
    with tempfile.TemporaryDirectory() as tmp:
        png = Path(tmp) / "probe.png"
        subprocess.run(["sips", "-s", "format", "png", str(path), "--out", str(png)],
                       capture_output=True, check=True)
        return decode_png(png.read_bytes())


def decode_png(data: bytes):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")

    offset, idat, palette = 8, bytearray(), None
    width = height = depth = colour_type = 0
    while offset < len(data):
        (length,) = struct.unpack_from(">I", data, offset)
        kind = data[offset + 4:offset + 8]
        chunk = data[offset + 8:offset + 8 + length]
        offset += 12 + length
        if kind == b"IHDR":
            width, height, depth, colour_type = struct.unpack(">IIBB", chunk[:10])
        elif kind == b"PLTE":
            palette = chunk
        elif kind == b"IDAT":
            idat += chunk
        elif kind == b"IEND":
            break

    if depth != 8:
        raise ValueError(f"unsupported bit depth {depth}")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colour_type]
    stride = width * channels
    raw = zlib.decompress(bytes(idat))

    # Undo the per-scanline PNG filters.
    out = bytearray(stride * height)
    previous = bytearray(stride)
    pos = 0
    for y in range(height):
        filter_type = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos + stride]); pos += stride
        for x in range(stride):
            a = line[x - channels] if x >= channels else 0
            b = previous[x]
            c = previous[x - channels] if x >= channels else 0
            value = line[x]
            if filter_type == 1:   value += a
            elif filter_type == 2: value += b
            elif filter_type == 3: value += (a + b) >> 1
            elif filter_type == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                value += a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = value & 0xFF
        out[y * stride:(y + 1) * stride] = line
        previous = line

    def pixel(x, y):
        x = min(max(int(x), 0), width - 1)
        y = min(max(int(y), 0), height - 1)
        i = y * stride + x * channels
        if colour_type == 3:
            j = out[i] * 3
            return palette[j], palette[j + 1], palette[j + 2]
        if channels >= 3:
            return out[i], out[i + 1], out[i + 2]
        return out[i], out[i], out[i]

    return width, height, pixel


# --------------------------------------------------------------------- probe

def probe(glb_path: Path, texture: Path | None):
    gltf, binary = read_glb(glb_path)

    if texture is None:
        image = gltf.get("images", [{}])[0]
        if "bufferView" not in image:
            raise SystemExit("model has no embedded texture; pass --texture")
        view = gltf["bufferViews"][image["bufferView"]]
        start = view.get("byteOffset", 0)
        suffix = ".jpg" if "jpeg" in image.get("mimeType", "") else ".png"
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as handle:
            handle.write(binary[start:start + view["byteLength"]])
            texture = Path(handle.name)

    width, height, pixel = load_pixels(texture)
    buckets: dict[tuple[int, int, int], list] = {}

    for node in gltf["nodes"]:
        if "mesh" not in node or NON_BODY.search(node.get("name", "")):
            continue
        for primitive in gltf["meshes"][node["mesh"]]["primitives"]:
            attributes = primitive["attributes"]
            if "TEXCOORD_0" not in attributes:
                continue
            positions = read_accessor(gltf, binary, attributes["POSITION"])
            uvs = read_accessor(gltf, binary, attributes["TEXCOORD_0"])
            indices = (read_accessor(gltf, binary, primitive["indices"])
                       if "indices" in primitive else list(range(len(positions))))

            for i in range(0, len(indices) - 2, 3):
                a, b, c = (indices[i], indices[i + 1], indices[i + 2])
                pa, pb, pc = positions[a], positions[b], positions[c]
                u = [pb[k] - pa[k] for k in range(3)]
                v = [pc[k] - pa[k] for k in range(3)]
                cross = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
                area = 0.5 * sum(component ** 2 for component in cross) ** 0.5
                if area <= 0:
                    continue

                cu = sum(uvs[idx][0] for idx in (a, b, c)) / 3
                cv = sum(uvs[idx][1] for idx in (a, b, c)) / 3
                r, g, bl = pixel(cu % 1.0 * width, cv % 1.0 * height)
                h, s, val = colorsys.rgb_to_hsv(r / 255, g / 255, bl / 255)
                if s < 0.25 or val < 0.15:
                    continue                      # greys, blacks, glass
                key = (r >> 3, g >> 3, bl >> 3)
                entry = buckets.setdefault(key, [0.0, 0, 0, 0, 0])
                entry[0] += area
                entry[1] += r; entry[2] += g; entry[3] += bl; entry[4] += 1

    if not buckets:
        raise SystemExit("no saturated paint found on the body")

    ranked = sorted(buckets.values(), key=lambda e: -e[0])
    total = sum(e[0] for e in ranked)
    print(f"{glb_path.name}")
    for entry in ranked[:4]:
        r, g, b = entry[1] // entry[4], entry[2] // entry[4], entry[3] // entry[4]
        h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
        print(f"  #{r:02X}{g:02X}{b:02X}  hue {h*360:6.1f}°  sat {s:.2f}  val {v:.2f}"
              f"   {entry[0]/total*100:5.1f}% of painted area")


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("--texture")
    args = parser.parse_args(argv[1:])
    probe(Path(args.input).expanduser(), Path(args.texture).expanduser() if args.texture else None)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
