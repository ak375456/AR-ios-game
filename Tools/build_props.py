#!/usr/bin/env python3
"""
Builds the course props' USDZ files from their original glTF downloads.

    python3 Tools/build_props.py cone ~/Downloads/low_poly_traffic_cone.glb
    python3 Tools/build_props.py tyre "~/Downloads/Tires by Poly by Google - 0yByYjelrMb.glb"

Every prop goes through the same steps, and each step is checked rather than
assumed:

1. Every node's full matrix is baked into the points and normals (normals
   through the inverse transpose, renormalised).
2. Each triangle's winding is checked against its baked normals; any that come
   out inside-out are flipped, and the script refuses to continue unless every
   one agrees. Props are drawn with back-face culling on, and a knocked-over
   prop shows sides nobody looked at when it was authored.
3. The parts that are kept must be watertight together, so single-sided
   rendering cannot open a hole from any angle.
4. The prop is stood on y = 0, centred on its footprint and scaled to its
   real-world size. The app measures the file and scales it to the same 1:10
   the cars use, so that size is documentation, not a dependency.
5. The author's materials are kept exactly (glTF and UsdPreviewSurface are both
   linear); unused UV sets are dropped.
   The result must pass `usdchecker --arkit`.

**The cone.** Sketchfab's own USDZ of it fails `usdchecker --arkit` (materials
bound without `MaterialBindingAPI`), is authored in centimetres, and hangs every
mesh under a node with a *negative* Y scale. A mirror flips triangle winding;
that export only looks right because `doubleSided` hides the inside-out faces,
and RealityKit ignores `doubleSided`. The model is authored inside-out in its
own space and the mirror turns it right, so baking the mirror is the whole fix.

**The tyre.** The download is two tyres, one lying flat and one propped against
it. A course prop has to be one loose object, so only the flat one is kept:
the model is split into its connected pieces, each wheel nut and hub goes with
the nearest tread, and the tyre whose axle is closest to vertical is levelled
exactly — axle up, wheel nuts on top — and centred on its axle.
"""

from __future__ import annotations

import math
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from glb_to_usdz import fmt_array, fmt_float, fmt_vec, read_accessor, read_glb  # noqa: E402

RESOURCES = Path(__file__).resolve().parent.parent / "vr" / "Resources"


@dataclass
class Recipe:
    output: str
    root: str
    #: Which glTF name identifies a part: its mesh's or its material's.
    part_key: str
    #: That name -> (prim name, material name). Named for what they are.
    parts: dict
    #: "height" or "diameter", and the real-world size in metres.
    size: tuple
    metadata: dict
    #: Keep one of several objects in the file, levelled; see `keep_flattest`.
    keep_flattest: bool = False
    #: Part whose centroid marks the top face once levelled.
    top_part: str | None = None


RECIPES = {
    "cone": Recipe(
        output="TrafficCone.usdz",
        root="TrafficCone",
        part_key="mesh",
        parts={
            "Object_0": ("Shell", "ConeOrange"),
            "Object_1": ("Base", "ConeBase"),
            "Object_2": ("Band", "ReflectiveBand"),
        },
        # A standard 70 cm road cone.
        size=("height", 0.70),
        metadata={},
    ),
    "tyre": Recipe(
        output="Tyre.usdz",
        root="Tyre",
        part_key="material",
        parts={
            "19___Default": ("Tread", "Rubber"),
            "09___Default": ("Wheel", "Wheel"),
            "08___Default": ("Nuts", "WheelNuts"),
        },
        # 0.70 m across: a 255/55 R19, and the median wheel on the cars.
        size=("diameter", 0.70),
        metadata={},
        keep_flattest=True,
        top_part="Nuts",
    ),
}


# --------------------------------------------------------------------------- matrices

def node_matrix(node):
    """Row-major 4x4 from a glTF node (matrix or TRS)."""
    if "matrix" in node:
        m = node["matrix"]
        return [[m[c * 4 + r] for c in range(4)] for r in range(4)]
    t = node.get("translation", [0, 0, 0])
    x, y, z, w = node.get("rotation", [0, 0, 0, 1])
    s = node.get("scale", [1, 1, 1])
    r = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
         [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
         [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
    return [[r[i][0] * s[0], r[i][1] * s[1], r[i][2] * s[2], t[i]] for i in range(3)] + [[0, 0, 0, 1]]


def multiply(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def determinant3(m):
    return (m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]))


def normal_matrix(m):
    """Inverse transpose of the upper 3x3."""
    det = determinant3(m)
    a = [[m[r][c] for c in range(3)] for r in range(3)]
    cof = [[(a[(r + 1) % 3][(c + 1) % 3] * a[(r + 2) % 3][(c + 2) % 3]
             - a[(r + 1) % 3][(c + 2) % 3] * a[(r + 2) % 3][(c + 1) % 3]) for c in range(3)] for r in range(3)]
    return [[cof[r][c] / det for c in range(3)] for r in range(3)]


def world_matrices(gltf):
    nodes = gltf["nodes"]
    parent = {child: index for index, node in enumerate(nodes) for child in node.get("children", [])}
    result = {}
    for index, node in enumerate(nodes):
        if "mesh" not in node:
            continue
        matrix, walk = node_matrix(node), index
        while walk in parent:
            walk = parent[walk]
            matrix = multiply(node_matrix(nodes[walk]), matrix)
        result[index] = matrix
    return result


# --------------------------------------------------------------------------- baking

def bake(gltf, binary, recipe):
    parts = []
    for node_index, matrix in world_matrices(gltf).items():
        node = gltf["nodes"][node_index]
        mesh = gltf["meshes"][node["mesh"]]
        for primitive in mesh["primitives"]:
            attributes = primitive["attributes"]
            points = read_accessor(gltf, binary, attributes["POSITION"])
            normals = read_accessor(gltf, binary, attributes["NORMAL"])
            indices = read_accessor(gltf, binary, primitive["indices"])
            n_matrix = normal_matrix(matrix)

            baked_points = [tuple(sum(matrix[r][k] * p[k] for k in range(3)) + matrix[r][3] for r in range(3))
                            for p in points]
            baked_normals = []
            for n in normals:
                v = [sum(n_matrix[r][k] * n[k] for k in range(3)) for r in range(3)]
                length = math.sqrt(sum(c * c for c in v)) or 1
                baked_normals.append(tuple(c / length for c in v))

            triangles = [tuple(indices[i:i + 3]) for i in range(0, len(indices), 3)]
            rewound = winding_agreement(baked_points, baked_normals, triangles) < 0.5
            if rewound:
                triangles = [(a, c, b) for a, b, c in triangles]
            agree = winding_agreement(baked_points, baked_normals, triangles)

            material = gltf["materials"][primitive["material"]]
            source = mesh["name"] if recipe.part_key == "mesh" else material["name"]
            parts.append({
                "source": source,
                "determinant": determinant3(matrix),
                "points": baked_points,
                "normals": baked_normals,
                "triangles": triangles,
                "agreement": agree,
                "rewound": rewound,
                "colour": material["pbrMetallicRoughness"].get("baseColorFactor", [1, 1, 1, 1])[:3],
                "roughness": material["pbrMetallicRoughness"].get("roughnessFactor", 1.0),
                "metallic": material["pbrMetallicRoughness"].get("metallicFactor", 1.0),
            })
    return parts


def winding_agreement(points, normals, triangles):
    """Fraction of triangles whose right-handed face normal agrees with their vertex normals."""
    agree = 0
    for a, b, c in triangles:
        pa, pb, pc = points[a], points[b], points[c]
        u = [pb[k] - pa[k] for k in range(3)]
        v = [pc[k] - pa[k] for k in range(3)]
        face = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
        vertex = [normals[a][k] + normals[b][k] + normals[c][k] for k in range(3)]
        if sum(face[k] * vertex[k] for k in range(3)) > 0:
            agree += 1
    return agree / max(len(triangles), 1)


def boundary_edges(parts):
    """Edges used by exactly one triangle, welding by position across all parts."""
    keys, edges = {}, Counter()
    for part in parts:
        ids = [keys.setdefault(tuple(round(c, 4) for c in p), len(keys)) for p in part["points"]]
        for tri in part["triangles"]:
            for k in range(3):
                a, b = ids[tri[k]], ids[tri[(k + 1) % 3]]
                edges[(min(a, b), max(a, b))] += 1
    return sum(1 for count in edges.values() if count == 1), sum(1 for count in edges.values() if count > 2)


# --------------------------------------------------------------------------- one object of several

def components(parts):
    """Connected pieces across every part, as lists of (part index, triangle index)."""
    keys, parent = {}, []

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    welded = []
    for part in parts:
        ids = [keys.setdefault(tuple(round(c, 4) for c in p), len(keys)) for p in part["points"]]
        parent.extend(range(len(parent), len(keys)))
        welded.append(ids)
    for p_index, part in enumerate(parts):
        ids = welded[p_index]
        for tri in part["triangles"]:
            a = find(ids[tri[0]])
            for vertex in tri[1:]:
                b = find(ids[vertex])
                if a != b:
                    parent[b] = a
    groups = defaultdict(list)
    for p_index, part in enumerate(parts):
        for t_index, tri in enumerate(part["triangles"]):
            groups[find(welded[p_index][tri[0]])].append((p_index, t_index))
    return list(groups.values())


def piece_points(parts, piece):
    return [parts[p]["points"][v] for p, t in piece for v in parts[p]["triangles"][t]]


def centroid(points):
    return [sum(p[k] for p in points) / len(points) for k in range(3)]


def smallest_axis(points):
    """Direction of least spread (a tyre's axle), by Jacobi eigen-decomposition."""
    mean = centroid(points)
    c = [[sum((p[i] - mean[i]) * (p[j] - mean[j]) for p in points) / len(points) for j in range(3)] for i in range(3)]
    vectors = [[1.0 if i == j else 0.0 for j in range(3)] for i in range(3)]
    for _ in range(50):
        i, j = max(((0, 1), (0, 2), (1, 2)), key=lambda ij: abs(c[ij[0]][ij[1]]))
        if abs(c[i][j]) < 1e-12:
            break
        theta = 0.5 * math.atan2(2 * c[i][j], c[j][j] - c[i][i])
        cs, sn = math.cos(theta), math.sin(theta)
        for k in range(3):
            cik, cjk = c[i][k], c[j][k]
            c[i][k], c[j][k] = cs * cik - sn * cjk, sn * cik + cs * cjk
        for k in range(3):
            cki, ckj = c[k][i], c[k][j]
            c[k][i], c[k][j] = cs * cki - sn * ckj, sn * cki + cs * ckj
        for k in range(3):
            vki, vkj = vectors[k][i], vectors[k][j]
            vectors[k][i], vectors[k][j] = cs * vki - sn * vkj, sn * vki + cs * vkj
    smallest = min(range(3), key=lambda k: c[k][k])
    axis = [vectors[k][smallest] for k in range(3)]
    length = math.sqrt(sum(a * a for a in axis))
    return [a / length for a in axis]


def rotation_onto_up(axis):
    """3x3 rotation taking unit `axis` onto +Y (Rodrigues), about axis x up."""
    x, y, z = axis
    # axis x (0, 1, 0) = (-z, 0, x): its length is the sine of the angle
    # between them, and y is the cosine.
    kx, kz, s, c = -z, x, math.hypot(x, z), y
    if s < 1e-9:
        rotation = [[1, 0, 0], [0, 1, 0], [0, 0, 1]] if c > 0 else [[1, 0, 0], [0, -1, 0], [0, 0, -1]]
    else:
        kx, kz = kx / s, kz / s
        k = [[0, -kz, 0], [kz, 0, -kx], [0, kx, 0]]  # cross-product matrix of (kx, 0, kz)
        k2 = [[sum(k[i][m] * k[m][j] for m in range(3)) for j in range(3)] for i in range(3)]
        rotation = [[(1 if i == j else 0) + s * k[i][j] + (1 - c) * k2[i][j] for j in range(3)] for i in range(3)]
    up = [sum(rotation[r][k] * axis[k] for k in range(3)) for r in range(3)]
    if abs(up[0]) > 1e-6 or abs(up[2]) > 1e-6 or up[1] < 1 - 1e-6:
        raise SystemExit(f"levelling rotation is wrong: axle went to {up}")
    return rotation


def keep_flattest(parts, recipe):
    """Keeps the one object in the file whose axle is nearest vertical, levelled."""
    pieces = components(parts)
    pieces.sort(key=len, reverse=True)
    tread_part = next(i for i, p in enumerate(parts) if recipe.parts[p["source"]][0] == "Tread")
    treads = [piece for piece in pieces if all(p == tread_part for p, _ in piece)][:2]
    if len(treads) < 1:
        raise SystemExit("no tread found")
    centres = [centroid(piece_points(parts, piece)) for piece in treads]

    # Every other piece — wheel, hub, each nut — belongs to the nearest tread.
    owner = defaultdict(list)
    for piece in pieces:
        c = centroid(piece_points(parts, piece))
        nearest = min(range(len(centres)), key=lambda k: sum((c[i] - centres[k][i]) ** 2 for i in range(3)))
        owner[nearest].extend(piece)

    axes = [smallest_axis(piece_points(parts, tread)) for tread in treads]
    chosen = max(range(len(treads)), key=lambda k: abs(axes[k][1]))
    tilt = math.degrees(math.acos(min(abs(axes[chosen][1]), 1)))
    print(f"  {len(treads)} tyres in the file; keeping the flattest, {tilt:.1f}° off level")

    keep = defaultdict(set)
    for p, t in owner[chosen]:
        keep[p].add(t)

    # Axle up, with the wheel nuts on the top face.
    axis = axes[chosen]
    top = next((i for i, p in enumerate(parts) if recipe.parts[p["source"]][0] == recipe.top_part), None)
    if top is not None:
        nuts = [parts[top]["points"][v] for t in keep[top] for v in parts[top]["triangles"][t]]
        if nuts:
            lean = [centroid(nuts)[k] - centres[chosen][k] for k in range(3)]
            if sum(lean[k] * axis[k] for k in range(3)) < 0:
                axis = [-a for a in axis]
    rotation = rotation_onto_up(axis)

    def rotate(v):
        return tuple(sum(rotation[r][k] * v[k] for k in range(3)) for r in range(3))

    kept = []
    for index, part in enumerate(parts):
        triangles = [part["triangles"][t] for t in sorted(keep[index])]
        used = sorted({v for tri in triangles for v in tri})
        remap = {old: new for new, old in enumerate(used)}
        part = dict(part)
        part["points"] = [rotate(part["points"][v]) for v in used]
        part["normals"] = [rotate(part["normals"][v]) for v in used]
        part["triangles"] = [tuple(remap[v] for v in tri) for tri in triangles]
        if part["triangles"]:
            kept.append(part)
    # Rotation preserves winding, but say so from the data.
    for part in kept:
        part["agreement"] = winding_agreement(part["points"], part["normals"], part["triangles"])
    return kept, treads, chosen


# --------------------------------------------------------------------------- placing

def normalise(parts, recipe):
    """Stand on y = 0, centre on the footprint, real-world size."""
    every = [p for part in parts for p in part["points"]]
    bottom = min(p[1] for p in every)
    top = max(p[1] for p in every)
    if recipe.size[0] == "height":
        footprint = [p for p in every if p[1] < bottom + 1e-3]
        span = top - bottom
    else:
        footprint = every
        span = max(max(p[0] for p in every) - min(p[0] for p in every),
                   max(p[2] for p in every) - min(p[2] for p in every))
    centre_x = (min(p[0] for p in footprint) + max(p[0] for p in footprint)) / 2
    centre_z = (min(p[2] for p in footprint) + max(p[2] for p in footprint)) / 2
    scale = recipe.size[1] / span
    for part in parts:
        part["points"] = [((p[0] - centre_x) * scale, (p[1] - bottom) * scale, (p[2] - centre_z) * scale)
                          for p in part["points"]]
    return scale, (centre_x, bottom, centre_z)


def emit(parts, recipe) -> str:
    root = recipe.root
    out = ["#usda 1.0", "("]
    out.append("    customLayerData = {")
    for key, value in recipe.metadata.items():
        out.append(f'        string {key} = "{value}"')
    out.append("    }")
    out += [f'    defaultPrim = "{root}"', "    metersPerUnit = 1", '    upAxis = "Y"', ")", ""]
    out += [f'def Xform "{root}" (', '    kind = "component"', ")", "{"]

    out.append('    def Scope "Materials"')
    out.append("    {")
    for part in parts:
        _, material = recipe.parts[part["source"]]
        out += [f'        def Material "{material}"', "        {",
                f"            token outputs:surface.connect = </{root}/Materials/{material}/Surface.outputs:surface>",
                '            def Shader "Surface"', "            {",
                '                uniform token info:id = "UsdPreviewSurface"',
                f"                color3f inputs:diffuseColor = {fmt_vec(part['colour'])}",
                f"                float inputs:metallic = {fmt_float(part['metallic'])}",
                f"                float inputs:roughness = {fmt_float(part['roughness'])}",
                "                int inputs:useSpecularWorkflow = 0",
                "                token outputs:surface", "            }", "        }"]
    out.append("    }")

    for part in parts:
        prim, material = recipe.parts[part["source"]]
        points = part["points"]
        lo = [min(p[k] for p in points) for k in range(3)]
        hi = [max(p[k] for p in points) for k in range(3)]
        out += ["", f'    def Mesh "{prim}" (', '        prepend apiSchemas = ["MaterialBindingAPI"]', "    )", "    {",
                "        uniform bool doubleSided = 0",
                f"        float3[] extent = [{fmt_vec(lo)}, {fmt_vec(hi)}]",
                f"        int[] faceVertexCounts = {fmt_array(['3'] * len(part['triangles']), 24)}",
                f"        int[] faceVertexIndices = {fmt_array([str(i) for t in part['triangles'] for i in t], 24)}",
                f"        rel material:binding = </{root}/Materials/{material}>",
                f"        normal3f[] normals = {fmt_array([fmt_vec(n) for n in part['normals']], 4)} (",
                '            interpolation = "vertex"', "        )",
                f"        point3f[] points = {fmt_array([fmt_vec(p) for p in points], 4)}",
                '        uniform token orientation = "rightHanded"',
                '        uniform token subdivisionScheme = "none"', "    }"]
    out.append("}")
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------- main

def main(argv):
    if len(argv) != 3 or argv[1] not in RECIPES:
        print(__doc__)
        return 2
    recipe = RECIPES[argv[1]]
    source = Path(argv[2]).expanduser()
    gltf, binary = read_glb(source)

    parts = bake(gltf, binary, recipe)
    unknown = [p["source"] for p in parts if p["source"] not in recipe.parts]
    if unknown or len(parts) != len(recipe.parts):
        raise SystemExit(f"unexpected parts in {source.name}: {[p['source'] for p in parts]}")

    for part in parts:
        mirrored = "mirrored" if part["determinant"] < 0 else "not mirrored"
        mirrored += ", triangles flipped" if part["rewound"] else ", winding kept"
        print(f"  {recipe.parts[part['source']][0]:6} {len(part['triangles']):4} triangles, {mirrored}, "
              f"winding agrees with normals on {part['agreement'] * 100:.0f}%")

    if recipe.keep_flattest:
        parts, _, _ = keep_flattest(parts, recipe)
        for part in parts:
            print(f"  kept {recipe.parts[part['source']][0]:6} {len(part['triangles']):4} triangles")

    if any(part["agreement"] < 0.999 for part in parts):
        raise SystemExit("winding still disagrees with the normals after baking")

    open_edges, non_manifold = boundary_edges(parts)
    print(f"  open edges {open_edges}, non-manifold edges {non_manifold}")
    if open_edges or non_manifold:
        raise SystemExit("not watertight; single-sided rendering would show holes")

    scale, offset = normalise(parts, recipe)
    every = [p for part in parts for p in part["points"]]
    size = [max(p[k] for p in every) - min(p[k] for p in every) for k in range(3)]
    print(f"  source {recipe.size[0]} {recipe.size[1] / scale:.3f} units, re-based by "
          f"({offset[0]:.3f}, {offset[1]:.3f}, {offset[2]:.3f}); now "
          f"{size[0]:.3f} x {size[1]:.3f} x {size[2]:.3f} m (w x h x d)")

    output = RESOURCES / recipe.output
    with tempfile.TemporaryDirectory() as work:
        usda = Path(work) / f"{recipe.root}.usda"
        usdc = Path(work) / f"{recipe.root}.usdc"
        usda.write_text(emit(parts, recipe))
        subprocess.run(["usdcat", str(usda), "-o", str(usdc)], check=True)
        output.unlink(missing_ok=True)
        subprocess.run(["usdzip", str(output), usdc.name], check=True, cwd=work, capture_output=True)

    check = subprocess.run(["usdchecker", "--arkit", str(output)], capture_output=True, text=True)
    verdict = "passes" if check.returncode == 0 else "FAILS"
    print(f"  wrote {output.relative_to(output.parent.parent.parent)} "
          f"({output.stat().st_size / 1024:.1f} KB), {verdict} usdchecker --arkit")
    if check.returncode != 0:
        print(check.stdout, check.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
