#!/usr/bin/env python3
"""
Convert a .glb car model into an ARKit-compatible .usdz for the app.

Written rather than using a GUI converter so the result is reproducible and,
more importantly, so the node hierarchy survives: the app needs the body and
each wheel as separate prims in order to roll and steer them.

It also fixes up models whose wheel meshes are authored in model space with the
node origin left at zero (`--recenter-wheels`), which would otherwise make the
wheels orbit the middle of the car instead of spinning on their own axles.

Pipeline:  .glb  ->  .usda (here)  ->  .usdc (usdcat)  ->  .usdz (usdzip)

Usage:
    python3 glb_to_usdz.py <input.glb> <output.usdz> [options]

Options:
    --name <PrimName>       Root prim name (default: derived from the filename)
    --texture <file.png>    External texture to use instead of embedded ones
    --max-texture <pixels>  Downscale textures to at most this size (default 1024)
    --no-recenter-wheels    Leave wheel pivots exactly as authored
"""

from __future__ import annotations

import argparse
import json
import math
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

COMPONENT_TYPES = {
    5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2),
    5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4),
}
COMPONENT_COUNTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}

# What counts as a wheel.
#
# This has to stay in step with `CarRig.isWheel` in the app: the converter uses
# it to decide which meshes get re-centred on their hubs, and the app uses it to
# decide which prims to spin. When the two disagreed, a kart whose wheels are
# named "tire" had them re-centred by nobody and rotated by the app, so they
# swung around the middle of the model and flew off.
WHEEL_PATTERN = re.compile(r"wheel|tire|tyre", re.IGNORECASE)

# Names that merely mention a wheel. Arches, supports, fenders - and spare
# wheels bolted to a tailgate - are parts of the bodywork and must never be
# rotated or used as contact patches.
NOT_A_WHEEL = re.compile(r"support|arch|well|guard|fender|mount|cover|axle|axel|hub[_ ]?cap|spare",
                         re.IGNORECASE)


def is_wheel(name: str) -> bool:
    return bool(WHEEL_PATTERN.search(name or "")) and not NOT_A_WHEEL.search(name or "")


# --------------------------------------------------------------------------- glTF

def read_glb(path: Path):
    data = path.read_bytes()
    magic, _version, length = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67:
        raise ValueError(f"{path} is not a binary glTF (.glb) file")

    gltf, binary, offset = None, None, 12
    while offset < length:
        chunk_length, chunk_type = struct.unpack_from("<II", data, offset)
        offset += 8
        chunk = data[offset:offset + chunk_length]
        offset += chunk_length
        if chunk_type == 0x4E4F534A:
            gltf = json.loads(chunk.decode("utf-8"))
        elif chunk_type == 0x004E4942:
            binary = chunk
    if gltf is None:
        raise ValueError(f"{path} has no JSON chunk")
    return gltf, binary


def read_accessor(gltf, binary, index):
    accessor = gltf["accessors"][index]
    fmt, size = COMPONENT_TYPES[accessor["componentType"]]
    count = COMPONENT_COUNTS[accessor["type"]]
    view = gltf["bufferViews"][accessor["bufferView"]]
    base = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    stride = view.get("byteStride") or size * count

    values = []
    for i in range(accessor["count"]):
        element = struct.unpack_from("<" + fmt * count, binary, base + i * stride)
        values.append(element[0] if count == 1 else element)

    if accessor.get("normalized") and accessor["componentType"] != 5126:
        divisor = {5120: 127.0, 5121: 255.0, 5122: 32767.0, 5123: 65535.0}[accessor["componentType"]]
        values = [
            max(v / divisor, -1.0) if isinstance(v, (int, float))
            else tuple(max(c / divisor, -1.0) for c in v)
            for v in values
        ]
    return values


def extract_images(gltf, binary, out_dir: Path, max_texture: int, override: Path | None):
    """Write each glTF image to `out_dir`, returning the file name per image index."""
    names: dict[int, str] = {}
    for index, image in enumerate(gltf.get("images", [])):
        if override is not None:
            shutil.copy(override, out_dir / override.name)
            names[index] = override.name
            continue

        if "bufferView" in image:
            view = gltf["bufferViews"][image["bufferView"]]
            start = view.get("byteOffset", 0)
            data = binary[start:start + view["byteLength"]]
            suffix = ".jpg" if "jpeg" in image.get("mimeType", "") else ".png"
            name = sanitize(image.get("name") or f"texture_{index}", f"texture_{index}") + suffix
            (out_dir / name).write_bytes(data)
        elif "uri" in image and not image["uri"].startswith("data:"):
            raise ValueError(f"image {index} references external file {image['uri']}; pass --texture")
        else:
            continue

        names[index] = downscale(out_dir / name, max_texture)
    return names


def downscale(path: Path, max_texture: int) -> str:
    """USDZ textures are uploaded to the GPU uncompressed, so cap their size."""
    if max_texture <= 0:
        return path.name
    probe = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
                           capture_output=True, text=True, check=True).stdout
    sizes = [int(n) for n in re.findall(r":\s*(\d+)", probe)]
    if sizes and max(sizes) > max_texture:
        subprocess.run(["sips", "-Z", str(max_texture), str(path)],
                       capture_output=True, check=True)
    return path.name


# --------------------------------------------------------------------------- USD

def sanitize(name: str, fallback: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_]", "_", name or "").strip("_")
    if not cleaned:
        return fallback
    if not (cleaned[0].isalpha() or cleaned[0] == "_"):
        cleaned = "_" + cleaned
    return cleaned


def fmt_float(value: float) -> str:
    return f"{value:.6g}"


def fmt_vec(values) -> str:
    return "(" + ", ".join(fmt_float(v) for v in values) + ")"


def fmt_array(items, per_line=6) -> str:
    lines, chunk = [], []
    for item in items:
        chunk.append(item)
        if len(chunk) == per_line:
            lines.append(", ".join(chunk))
            chunk = []
    if chunk:
        lines.append(", ".join(chunk))
    return "[" + ",\n                ".join(lines) + "]"


def quaternion_multiply(a, b):
    """glTF-order (x, y, z, w) quaternion product."""
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz)


def axis_quaternion(axis, radians):
    half = radians / 2
    s = math.sin(half)
    return (axis[0] * s, axis[1] * s, axis[2] * s, math.cos(half))


def rotate_point(quaternion, point):
    """Rotate a point by a glTF (x, y, z, w) quaternion."""
    x, y, z, w = quaternion
    px, py, pz = point
    tx, ty, tz = 2 * (y * pz - z * py), 2 * (z * px - x * pz), 2 * (x * py - y * px)
    return (px + w * tx + y * tz - z * ty,
            py + w * ty + z * tx - x * tz,
            pz + w * tz + x * ty - y * tx)


def upright_correction(size):
    """Rotate a Z-up model upright. Returns the quaternion and the new size."""
    x, y, z = size
    if y > x and y > z:
        return axis_quaternion((1, 0, 0), -math.pi / 2), [x, z, y], True
    return (0.0, 0.0, 0.0, 1.0), [x, y, z], False


def long_axis_yaw(points):
    """Yaw that puts a model's longest horizontal axis along +Z.

    Uses the principal axis of the vertices rather than comparing bounding-box
    widths: some models are authored at an angle in their own frame, and a
    bounding box cannot see that — it just reports a fat box and the car ends
    up sitting diagonally.
    """
    count = len(points)
    if count < 3:
        return 0.0
    mean_x = sum(p[0] for p in points) / count
    mean_z = sum(p[2] for p in points) / count
    sxx = sum((p[0] - mean_x) ** 2 for p in points) / count
    szz = sum((p[2] - mean_z) ** 2 for p in points) / count
    sxz = sum((p[0] - mean_x) * (p[2] - mean_z) for p in points) / count

    if sxx + szz == 0:
        return 0.0
    # Principal direction of the 2x2 covariance, in the (x, z) plane.
    angle = 0.5 * math.atan2(2 * sxz, sxx - szz)
    major = (math.cos(angle), math.sin(angle))
    # PCA gives an axis, not a direction, so the answer is only defined up to
    # 180 degrees. Pick the end pointing towards +Z and leave the front/back
    # question to the facing check, which has actual evidence for it.
    if major[1] < 0:
        major = (-major[0], -major[1])
    return -math.atan2(major[0], major[1])


def rotate(quaternion, vector):
    """Rotate `vector` by a glTF (x, y, z, w) quaternion."""
    x, y, z, w = quaternion
    vx, vy, vz = vector
    tx, ty, tz = 2 * (y * vz - z * vy), 2 * (z * vx - x * vz), 2 * (x * vy - y * vx)
    return (vx + w * tx + y * tz - z * ty,
            vy + w * ty + z * tx - x * tz,
            vz + w * tz + x * ty - y * tx)


NON_BODY = re.compile(r"wheel|tire|tyre|glass|window|windscreen", re.IGNORECASE)


def analyse_paint(gltf, binary, texture_path: Path | None):
    """Work out which material is the car's paint, and what colour it is.

    Walks the body triangles, samples either the base-colour map at each
    triangle's UV centroid or the material's flat colour, and weights by
    triangle area. The winner is the paint: it is what the player repaints.
    """
    import colorsys

    pixel = width = height = None
    if texture_path is not None and texture_path.exists():
        try:
            from paint_probe import load_pixels
            width, height, pixel = load_pixels(texture_path)
        except Exception:
            pixel = None

    materials = gltf.get("materials", [])
    area_by_material: dict[int, float] = {}
    total_body_area = 0.0
    colour_buckets: dict[tuple, list] = {}

    for node in gltf.get("nodes", []):
        if "mesh" not in node or NON_BODY.search(node.get("name", "")):
            continue
        for primitive in gltf["meshes"][node["mesh"]]["primitives"]:
            attributes = primitive["attributes"]
            material_index = primitive.get("material", 0)
            positions = read_accessor(gltf, binary, attributes["POSITION"])
            uvs = (read_accessor(gltf, binary, attributes["TEXCOORD_0"])
                   if "TEXCOORD_0" in attributes else None)
            indices = (read_accessor(gltf, binary, primitive["indices"])
                       if "indices" in primitive else list(range(len(positions))))

            for i in range(0, len(indices) - 2, 3):
                a, b, c = indices[i], indices[i + 1], indices[i + 2]
                pa, pb, pc = positions[a], positions[b], positions[c]
                u = [pb[k] - pa[k] for k in range(3)]
                v = [pc[k] - pa[k] for k in range(3)]
                cross = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
                area = 0.5 * sum(component ** 2 for component in cross) ** 0.5
                if area <= 0:
                    continue
                total_body_area += area

                if pixel is not None and uvs is not None:
                    cu = sum(uvs[idx][0] for idx in (a, b, c)) / 3
                    cv = sum(uvs[idx][1] for idx in (a, b, c)) / 3
                    r, g, bl = pixel(cu % 1.0 * width, cv % 1.0 * height)
                    rgb = (r / 255, g / 255, bl / 255)
                else:
                    factor = (materials[material_index].get("pbrMetallicRoughness", {})
                              .get("baseColorFactor", [0.8, 0.8, 0.8, 1])) if materials else [0.8, 0.8, 0.8, 1]
                    rgb = tuple(factor[:3])

                h, sat, val = colorsys.rgb_to_hsv(*rgb)
                # Greys, blacks and — importantly — pale tinted glass are never
                # the paint. Window glass on these models sits around 0.25
                # saturation, which is high enough to win on a white ambulance
                # and turn its windows whatever colour the player picked.
                if sat < 0.32 or val < 0.10:
                    continue
                area_by_material[material_index] = area_by_material.get(material_index, 0) + area
                key = (material_index, round(h, 2))
                entry = colour_buckets.setdefault(key, [0.0, 0.0, 0.0, 0.0, 0])
                entry[0] += area
                entry[1] += rgb[0]; entry[2] += rgb[1]; entry[3] += rgb[2]; entry[4] += 1

    if not area_by_material:
        return None

    paint_material = max(area_by_material, key=area_by_material.get)
    best = max((e for k, e in colour_buckets.items() if k[0] == paint_material),
               key=lambda e: e[0], default=None)
    if best is None:
        return None
    r, g, b = best[1] / best[4], best[2] / best[4], best[3] / best[4]
    h, sat, val = colorsys.rgb_to_hsv(r, g, b)
    # Share of the *whole* body, not just its saturated parts: on a grey car
    # the only saturated pixels might be its tail lights, and those are not
    # the paint.
    share = area_by_material[paint_material] / total_body_area if total_body_area else 0
    return {
        "materialIndex": paint_material,
        "areaShare": round(share, 3),
        "rgb": [round(r, 4), round(g, 4), round(b, 4)],
        "hue": round(h * 360, 1),
        "saturation": round(sat, 3),
        "brightness": round(val, 3),
        "textured": pixel is not None,
    }


def analyse_facing(gltf, binary, converter, quaternion, texture_path, paint_material):
    """Work out which end of the car is the front, from its tail lights.

    Nearly every car model has red lights at the back and clear or amber ones
    at the front, and that holds whatever the author's axis convention was.
    Comparing how much *red* area sits in each half of the car is therefore a
    far better test than guessing from a bounding box - which is what put a
    supercar on the road backwards.

    The car's own paint is excluded first, so a red car does not vote for
    itself.
    """
    import colorsys

    pixel = width = height = None
    if texture_path is not None and texture_path.exists():
        try:
            from paint_probe import load_pixels
            width, height, pixel = load_pixels(texture_path)
        except Exception:
            pixel = None

    materials = gltf.get("materials", [])
    scene = gltf["scenes"][gltf.get("scene", 0)]
    front_red = rear_red = 0.0
    zs = []

    triangles = []
    for node, world in converter.mesh_nodes(scene):
        if NON_BODY.search(node.get("name", "")):
            continue
        for primitive in gltf["meshes"][node["mesh"]]["primitives"]:
            material_index = primitive.get("material", 0)
            attributes = primitive["attributes"]
            positions = read_accessor(gltf, binary, attributes["POSITION"])
            uvs = (read_accessor(gltf, binary, attributes["TEXCOORD_0"])
                   if "TEXCOORD_0" in attributes else None)
            indices = (read_accessor(gltf, binary, primitive["indices"])
                       if "indices" in primitive else list(range(len(positions))))
            world_positions = [converter.transform(world, p) for p in positions]
            rotated = [rotate_point(quaternion, p) for p in world_positions]
            zs.extend(p[2] for p in rotated)
            triangles.append((material_index, rotated, uvs, indices))

    if not zs:
        return {"suggestFlip": False, "confidence": 0.0}
    centre_z = (min(zs) + max(zs)) / 2

    for material_index, rotated, uvs, indices in triangles:
        _ = paint_material
        for i in range(0, len(indices) - 2, 3):
            a, b, c = indices[i], indices[i + 1], indices[i + 2]
            pa, pb, pc = rotated[a], rotated[b], rotated[c]
            u = [pb[k] - pa[k] for k in range(3)]
            v = [pc[k] - pa[k] for k in range(3)]
            cross = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
            area = 0.5 * sum(component ** 2 for component in cross) ** 0.5
            if area <= 0:
                continue

            if pixel is not None and uvs is not None:
                cu = sum(uvs[idx][0] for idx in (a, b, c)) / 3
                cv = sum(uvs[idx][1] for idx in (a, b, c)) / 3
                r, g, bl = pixel(cu % 1.0 * width, cv % 1.0 * height)
                rgb = (r / 255, g / 255, bl / 255)
            elif materials:
                factor = (materials[material_index].get("pbrMetallicRoughness", {})
                          .get("baseColorFactor", [1, 1, 1, 1]))
                rgb = tuple(factor[:3])
            else:
                continue

            h, sat, val = colorsys.rgb_to_hsv(*rgb)
            degrees = h * 360
            # Tail-light red: a narrow band either side of pure red, saturated
            # and not too dark. Amber indicators sit further round and are
            # fitted at both ends, so they are left out.
            if not (degrees < 14 or degrees > 350) or sat < 0.55 or val < 0.18:
                continue
            centroid_z = (pa[2] + pb[2] + pc[2]) / 3
            if centroid_z > centre_z:
                front_red += area
            else:
                rear_red += area

    total = front_red + rear_red
    if total <= 0:
        return {"frontRed": 0.0, "rearRed": 0.0, "suggestFlip": False, "confidence": 0.0}
    balance = (front_red - rear_red) / total
    return {
        "frontRed": round(front_red, 6),
        "rearRed": round(rear_red, 6),
        # Positive balance means the red is at the +Z end, which means +Z is
        # currently the back and the model needs turning round.
        "suggestFlip": balance > 0.25,
        "confidence": round(abs(balance), 3),
    }


class Converter:

    def __init__(self, gltf, binary, root, image_names, recenter_wheels, paint_material=None):
        self.gltf = gltf
        self.binary = binary
        self.root = root
        self.image_names = image_names
        self.recenter_wheels = recenter_wheels
        self.paint_material = paint_material
        self.orientation = None
        self.orientation_notes: list[str] = []
        self.lines: list[str] = []
        self.triangles = 0
        self.material_names: dict[int, str] = {}
        self.base_colour_images: list[str] = []
        self.wheel_report: list[dict] = []
        self.bounds_report: dict = {}

    # -- materials --------------------------------------------------------

    def emit_materials(self):
        out = self.lines.append
        out('    def Scope "Materials"')
        out("    {")

        materials = self.gltf.get("materials", []) or [{"name": "default"}]
        for index, material in enumerate(materials):
            name = sanitize(material.get("name"), f"material_{index}")
            # USD prim names must be unique within the scope.
            while name in self.material_names.values():
                name += "_"
            self.material_names[index] = name

            pbr = material.get("pbrMetallicRoughness", {})
            factor = pbr.get("baseColorFactor", [1, 1, 1, 1])
            texture_index = pbr.get("baseColorTexture", {}).get("index")
            image_name = None
            if texture_index is not None:
                source = self.gltf["textures"][texture_index].get("source")
                image_name = self.image_names.get(source)
                if image_name and image_name not in self.base_colour_images:
                    self.base_colour_images.append(image_name)

            opacity = factor[3] if len(factor) > 3 else 1.0
            if material.get("alphaMode", "OPAQUE") == "OPAQUE":
                opacity = 1.0
            metallic = pbr.get("metallicFactor", 1.0)
            roughness = pbr.get("roughnessFactor", 1.0)
            if "metallicRoughnessTexture" in pbr:
                # The map itself is dropped to keep the bundle small; these
                # scalars stand in for it and read well on a small AR car.
                metallic, roughness = 0.1, 0.45
            elif image_name is not None and roughness >= 1.0:
                # glTF's default of fully rough looks flat under AR lighting.
                roughness = 0.55

            path = f"/{self.root}/Materials/{name}"
            out(f'        def Material "{name}"')
            out("        {")
            out(f"            token outputs:surface.connect = <{path}/Surface.outputs:surface>")
            out("")
            out('            def Shader "Surface"')
            out("            {")
            out('                uniform token info:id = "UsdPreviewSurface"')
            if image_name:
                out(f"                color3f inputs:diffuseColor.connect = <{path}/DiffuseTexture.outputs:rgb>")
            else:
                out(f"                color3f inputs:diffuseColor = {fmt_vec(factor[:3])}")
            out(f"                float inputs:metallic = {fmt_float(metallic)}")
            out(f"                float inputs:roughness = {fmt_float(roughness)}")
            if opacity < 1.0:
                out(f"                float inputs:opacity = {fmt_float(opacity)}")
            out("                int inputs:useSpecularWorkflow = 0")
            out("                token outputs:surface")
            out("            }")
            if image_name:
                out("")
                out('            def Shader "DiffuseTexture"')
                out("            {")
                out('                uniform token info:id = "UsdUVTexture"')
                out(f"                asset inputs:file = @{image_name}@")
                out(f"                float2 inputs:st.connect = <{path}/UVReader.outputs:result>")
                out('                token inputs:wrapS = "repeat"')
                out('                token inputs:wrapT = "repeat"')
                out("                float3 outputs:rgb")
                out("            }")
                out("")
                out('            def Shader "UVReader"')
                out("            {")
                out('                uniform token info:id = "UsdPrimvarReader_float2"')
                out('                string inputs:varname = "st"')
                out("                float2 inputs:fallback = (0, 0)")
                out("                float2 outputs:result")
                out("            }")
            out("        }")
        out("    }")

    # -- geometry ---------------------------------------------------------

    def primitive_bounds(self, mesh_index):
        lo = [math.inf] * 3
        hi = [-math.inf] * 3
        for primitive in self.gltf["meshes"][mesh_index]["primitives"]:
            accessor = self.gltf["accessors"][primitive["attributes"]["POSITION"]]
            for axis in range(3):
                lo[axis] = min(lo[axis], accessor["min"][axis])
                hi[axis] = max(hi[axis], accessor["max"][axis])
        return lo, hi

    def emit_primitive(self, primitive, indent, prim_name, offset):
        attributes = primitive["attributes"]
        positions = read_accessor(self.gltf, self.binary, attributes["POSITION"])
        if offset != (0, 0, 0):
            positions = [(p[0] - offset[0], p[1] - offset[1], p[2] - offset[2]) for p in positions]

        normals = read_accessor(self.gltf, self.binary, attributes["NORMAL"]) if "NORMAL" in attributes else []
        uvs = []
        if "TEXCOORD_0" in attributes:
            # glTF's V axis points down, USD's st points up.
            uvs = [(u, 1.0 - v) for u, v in read_accessor(self.gltf, self.binary, attributes["TEXCOORD_0"])]

        if "indices" in primitive:
            indices = read_accessor(self.gltf, self.binary, primitive["indices"])
        else:
            indices = list(range(len(positions)))

        face_counts = [3] * (len(indices) // 3)
        self.triangles += len(face_counts)

        lo = [min(p[axis] for p in positions) for axis in range(3)]
        hi = [max(p[axis] for p in positions) for axis in range(3)]

        material_index = primitive.get("material", 0)
        material_name = self.material_names.get(material_index, next(iter(self.material_names.values())))
        material = self.gltf.get("materials", [{}])[material_index] if self.gltf.get("materials") else {}

        pad = " " * indent
        out = self.lines.append
        out(f'{pad}def Mesh "{prim_name}" (')
        out(f'{pad}    prepend apiSchemas = ["MaterialBindingAPI"]')
        out(f"{pad})")
        out(f"{pad}{{")
        out(f"{pad}    uniform bool doubleSided = {1 if material.get('doubleSided') else 0}")
        out(f'{pad}    uniform token subdivisionScheme = "none"')
        out(f"{pad}    float3[] extent = [{fmt_vec(lo)}, {fmt_vec(hi)}]")
        out(f"{pad}    int[] faceVertexCounts = {fmt_array([str(c) for c in face_counts], 24)}")
        out(f"{pad}    int[] faceVertexIndices = {fmt_array([str(i) for i in indices], 24)}")
        out(f"{pad}    point3f[] points = {fmt_array([fmt_vec(p) for p in positions], 4)}")
        if normals:
            out(f"{pad}    normal3f[] normals = {fmt_array([fmt_vec(n) for n in normals], 4)} (")
            out(f'{pad}        interpolation = "vertex"')
            out(f"{pad}    )")
        if uvs:
            out(f"{pad}    texCoord2f[] primvars:st = {fmt_array([fmt_vec(t) for t in uvs], 6)} (")
            out(f'{pad}        interpolation = "vertex"')
            out(f"{pad}    )")
        out(f"{pad}    rel material:binding = </{self.root}/Materials/{material_name}>")
        out(f"{pad}}}")

    def emit_node(self, node_index, indent):
        node = self.gltf["nodes"][node_index]
        prim_name = sanitize(node.get("name"), f"node_{node_index}")
        pad = " " * indent
        out = self.lines.append

        translation = list(node.get("translation", [0, 0, 0]))
        offset = (0, 0, 0)

        # Wheels must spin about their own axle. If the mesh is authored away
        # from its node origin, move the geometry onto the origin and push the
        # difference into the node's transform - the car looks identical, but
        # the pivot ends up where a wheel hub actually is.
        if self.recenter_wheels and "mesh" in node and is_wheel(node.get("name", "")):
            lo, hi = self.primitive_bounds(node["mesh"])
            centre = tuple((lo[axis] + hi[axis]) / 2 for axis in range(3))
            self.wheel_report.append({
                "name": node.get("name", ""),
                "recentred": any(abs((lo[i] + hi[i]) / 2) > 1e-6 for i in range(3)),
                "centre": [round(v, 5) for v in ((lo[i] + hi[i]) / 2 + translation[i] for i in range(3))],
                "radius": round(max(hi[1] - lo[1], hi[2] - lo[2]) / 2, 5),
                "width": round(hi[0] - lo[0], 5),
            })
            if any(abs(c) > 1e-6 for c in centre):
                offset = centre
                shift = centre
                if "scale" in node:
                    shift = tuple(shift[axis] * node["scale"][axis] for axis in range(3))
                if "rotation" in node:
                    shift = rotate(node["rotation"], shift)
                translation = [translation[axis] + shift[axis] for axis in range(3)]

        out(f'{pad}def Xform "{prim_name}"')
        out(f"{pad}{{")

        ops = []
        if any(abs(v) > 1e-9 for v in translation):
            out(f"{pad}    double3 xformOp:translate = {fmt_vec(translation)}")
            ops.append("xformOp:translate")
        if "rotation" in node:
            x, y, z, w = node["rotation"]
            out(f"{pad}    quatf xformOp:orient = {fmt_vec((w, x, y, z))}")
            ops.append("xformOp:orient")
        if "scale" in node:
            out(f"{pad}    float3 xformOp:scale = {fmt_vec(node['scale'])}")
            ops.append("xformOp:scale")
        if ops:
            names = ", ".join('"' + op + '"' for op in ops)
            out(f"{pad}    uniform token[] xformOpOrder = [{names}]")

        if "mesh" in node:
            for number, primitive in enumerate(self.gltf["meshes"][node["mesh"]]["primitives"]):
                out("")
                # Prims carrying the paint material are named so the app can
                # repaint exactly those and leave trim, glass and tyres alone.
                is_paint = (self.paint_material is not None
                            and primitive.get("material", 0) == self.paint_material
                            and not is_wheel(node.get("name", "")))
                stem = "paint" if is_paint else "geo"
                self.emit_primitive(primitive, indent + 4,
                                    stem if number == 0 else f"{stem}_{number}", offset)
        for child in node.get("children", []):
            out("")
            self.emit_node(child, indent + 4)
        out(f"{pad}}}")

    def mesh_nodes(self, scene):
        """Yields (node, world matrix) for every node carrying a mesh."""
        def node_matrix(node):
            if "matrix" in node:
                m = node["matrix"]
                return [[m[0], m[4], m[8], m[12]], [m[1], m[5], m[9], m[13]],
                        [m[2], m[6], m[10], m[14]], [m[3], m[7], m[11], m[15]]]
            t = node.get("translation", [0, 0, 0])
            x, y, z, w = node.get("rotation", [0, 0, 0, 1])
            sc = node.get("scale", [1, 1, 1])
            rot = [
                [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
            ]
            return [[rot[r][c] * sc[c] for c in range(3)] + [t[r]] for r in range(3)] + [[0, 0, 0, 1]]

        def multiply(a, b):
            return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]

        identity = [[1 if i == j else 0 for j in range(4)] for i in range(4)]
        out = []

        def walk(index, parent):
            node = self.gltf["nodes"][index]
            world = multiply(parent, node_matrix(node))
            if "mesh" in node:
                out.append((node, world))
            for child in node.get("children", []):
                walk(child, world)

        for index in scene["nodes"]:
            walk(index, identity)
        return out

    @staticmethod
    def transform(matrix, point):
        return tuple(sum(matrix[i][k] * point[k] for k in range(3)) + matrix[i][3] for i in range(3))

    def sample_points(self, scene, stride: int = 7):
        """A subsample of the model's vertices in its own world space."""
        points = []
        for node, world in self.mesh_nodes(scene):
            for primitive in self.gltf["meshes"][node["mesh"]]["primitives"]:
                positions = read_accessor(self.gltf, self.binary, primitive["attributes"]["POSITION"])
                for i in range(0, len(positions), stride):
                    points.append(self.transform(world, positions[i]))
        return points

    def measure_scene(self, scene):
        """World-space bounds of the whole model.

        Node transforms have to be composed properly, not just accumulated as
        translations: plenty of these models carry a rotation on an inner node
        (a Z-up rig converted at export, say), and ignoring it puts the axes in
        the wrong order and makes the orientation fix rotate a car that was
        already upright onto its side.
        """
        lo = [math.inf] * 3
        hi = [-math.inf] * 3

        def node_matrix(node):
            t = node.get("translation", [0, 0, 0])
            r = node.get("rotation", [0, 0, 0, 1])
            sc = node.get("scale", [1, 1, 1])
            if "matrix" in node:
                m = node["matrix"]      # glTF stores column-major
                return [[m[0], m[4], m[8], m[12]],
                        [m[1], m[5], m[9], m[13]],
                        [m[2], m[6], m[10], m[14]],
                        [m[3], m[7], m[11], m[15]]]
            x, y, z, w = r
            rot = [
                [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
            ]
            return [[rot[row][col] * sc[col] for col in range(3)] + [t[row]] for row in range(3)] \
                + [[0, 0, 0, 1]]

        def multiply(a, b):
            return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]

        def apply(m, p):
            return [sum(m[i][k] * p[k] for k in range(3)) + m[i][3] for i in range(3)]

        identity = [[1 if i == j else 0 for j in range(4)] for i in range(4)]

        def walk(node_index, parent):
            node = self.gltf["nodes"][node_index]
            world = multiply(parent, node_matrix(node))
            if "mesh" in node:
                mesh_lo, mesh_hi = self.primitive_bounds(node["mesh"])
                for corner in range(8):
                    point = [mesh_hi[axis] if corner >> axis & 1 else mesh_lo[axis] for axis in range(3)]
                    moved = apply(world, point)
                    for axis in range(3):
                        lo[axis] = min(lo[axis], moved[axis])
                        hi[axis] = max(hi[axis], moved[axis])
            for child in node.get("children", []):
                walk(child, world)

        for node_index in scene["nodes"]:
            walk(node_index, identity)
        if math.isinf(lo[0]):
            return
        self.bounds_report = {
            "min": [round(v, 5) for v in lo],
            "max": [round(v, 5) for v in hi],
            "size": [round(hi[i] - lo[i], 5) for i in range(3)],
        }

    def build(self) -> str:
        out = self.lines.append
        out("#usda 1.0")
        out("(")
        out(f'    defaultPrim = "{self.root}"')
        out("    metersPerUnit = 1")
        out('    upAxis = "Y"')
        out(")")
        out("")
        out(f'def Xform "{self.root}" (')
        out('    kind = "component"')
        out(")")
        out("{")
        if self.orientation is not None:
            x, y, z, w = self.orientation
            out(f"    quatf xformOp:orient = {fmt_vec((w, x, y, z))}")
            out('    uniform token[] xformOpOrder = ["xformOp:orient"]')
        self.emit_materials()

        scene = self.gltf["scenes"][self.gltf.get("scene", 0)]
        for node_index in scene["nodes"]:
            out("")
            self.emit_node(node_index, 4)
        out("}")
        return "\n".join(self.lines) + "\n"


# --------------------------------------------------------------------------- main

def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("input")
    parser.add_argument("output")
    parser.add_argument("--name")
    parser.add_argument("--texture")
    parser.add_argument("--max-texture", type=int, default=1024)
    parser.add_argument("--no-recenter-wheels", action="store_true")
    parser.add_argument("--report", help="write a JSON summary to this path")
    parser.add_argument("--flip", action="store_true",
                        help="source model faces -Z; turn it 180 degrees")
    args = parser.parse_args(argv[1:])

    glb_path = Path(args.input).expanduser()
    # usdzip runs with the temp directory as its cwd, so the destination
    # has to be absolute.
    usdz_path = Path(args.output).expanduser().resolve()
    override = Path(args.texture).expanduser() if args.texture else None

    gltf, binary = read_glb(glb_path)
    root = sanitize(args.name or glb_path.stem.title().replace("-", "").replace("_", ""), "Model")

    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = Path(tmp)
        image_names = extract_images(gltf, binary, tmp_dir, args.max_texture, override)

        paint = analyse_paint(gltf, binary,
                              (tmp_dir / next(iter(image_names.values()))) if image_names else None)
        converter = Converter(gltf, binary, root, image_names, not args.no_recenter_wheels,
                              paint_material=paint["materialIndex"] if paint else None)

        # Measure in the source's own frame, then bake a single corrective
        # rotation onto the root so every shipped car is Y-up facing +Z.
        scene = gltf["scenes"][gltf.get("scene", 0)]
        converter.measure_scene(scene)
        raw_size = converter.bounds_report.get("size", [1, 1, 1])
        notes = []

        quat, size_after_up, was_z_up = upright_correction(raw_size)
        if was_z_up:
            notes.append("Z-up")

        points = [rotate_point(quat, p) for p in converter.sample_points(scene)]
        yaw = long_axis_yaw(points)
        if abs(yaw) > 0.02:
            quat = quaternion_multiply(axis_quaternion((0, 1, 0), yaw), quat)
            notes.append(f"yawed {math.degrees(yaw):.0f}deg")

        facing = analyse_facing(gltf, binary, converter, quat,
                                (tmp_dir / next(iter(image_names.values()))) if image_names else None,
                                paint["materialIndex"] if paint else None)
        # Advisory only: the flip comes from the table in build_cars.py, which
        # was verified against front-on renders of every car.
        needs_flip = args.flip
        if needs_flip:
            quat = quaternion_multiply(axis_quaternion((0, 1, 0), math.pi), quat)
            notes.append("flipped")

        if any(abs(v) > 1e-6 for v in quat[:3]):
            converter.orientation = quat
        converter.orientation_notes = notes
        rotated = [rotate_point(quat, p) for p in converter.sample_points(scene)]
        converter.bounds_report["orientedSize"] = [
            round(max(p[axis] for p in rotated) - min(p[axis] for p in rotated), 5) for axis in range(3)
        ]

        usda_file = tmp_dir / f"{usdz_path.stem}.usda"
        usdc_file = tmp_dir / f"{usdz_path.stem}.usdc"
        usda_file.write_text(converter.build())

        subprocess.run(["usdcat", "--flattenLayerStack", "-o", str(usdc_file), str(usda_file)], check=True)
        usdz_path.parent.mkdir(parents=True, exist_ok=True)
        usdz_path.unlink(missing_ok=True)
        subprocess.run(["usdzip", "--arkitAsset", str(usdc_file), str(usdz_path)], check=True, cwd=tmp_dir)

        # Hand back the base-colour maps too: the app recolours the car by
        # rebuilding that map at runtime, so it needs the originals loose.
        for name in dict.fromkeys(converter.base_colour_images):
            shutil.copy(tmp_dir / name, usdz_path.parent / name)

    report = {
        "source": glb_path.name,
        "asset": usdz_path.stem,
        "nodes": len(gltf.get("nodes", [])),
        "triangles": converter.triangles,
        "materials": len(converter.material_names),
        "textures": list(dict.fromkeys(converter.base_colour_images)),
        "wheels": converter.wheel_report,
        "bounds": converter.bounds_report,
        "sizeKB": usdz_path.stat().st_size // 1024,
        "paint": paint,
        "orientation": converter.orientation_notes,
        "facing": facing,
    }
    if args.report:
        Path(args.report).write_text(json.dumps(report, indent=2))
    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
