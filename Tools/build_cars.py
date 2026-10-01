#!/usr/bin/env python3
"""
Build every playable car: convert the source models and generate CarCatalog.swift.

Run from the project root:
    python3 Tools/build_cars.py

The table below is the only hand-authored part. Everything else - geometry,
paint colour, orientation - is measured from the models themselves, so a car's
handling can never drift away from the shape the player is looking at.

`flip` marks models authored facing -Z. It was determined by rendering every
car head-on from +Z and checking whether the tile showed headlights and a
grille or tail lights and a number plate — side-on thumbnails turned out to be
too easy to misread, which is how a supercar ended up driving backwards.

Display names follow the source models, because generic ones made people think
cars were missing from the roster. Several of these depict real, trademarked
vehicles: the Creative Commons licences cover the 3D models, not the
manufacturers' marks, so that still needs clearing before any public release.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "vr" / "Resources"
DOWNLOADS = Path.home() / "Downloads"
KIT = DOWNLOADS / "kenney_car-kit" / "Models" / "GLB format"
COLORMAP = KIT / "Textures" / "colormap.png"



# asset, source, display name, tagline, class, length(m), flip
CARS = [
    ("SedanSports", KIT / "sedan-sports.glb", "Sports Sedan",
     "Even-handed. Good place to start.", "sedan", 0.42, False),
    ("HotHatch", KIT / "hatchback-sports.glb", "Hot Hatch",
     "Loose rear end. Built to slide.", "drift", 0.40, False),
    ("Racer", KIT / "race.glb", "Open Wheeler",
     "Fastest thing here. Hates tight corners.", "openWheel", 0.46, False),
    ("Supercar", DOWNLOADS / "CAR Model by Ignition Labs - 5zUWP5UsLg-.glb", "Apex GT",
     "Enormous power. Respect it.", "supercar", 0.44, False),

    ("EightiesWedge", DOWNLOADS / "80s Car by Nick Ladd - 7tPSW5UYD20.glb", "80s Car",
     "All angles and attitude.", "sports", 0.44, True),
    ("Ambulance", DOWNLOADS / "Ambulance by Poly by Google - beDwEv9UB7x.glb", "Ambulance",
     "Tall, heavy, surprisingly willing.", "van", 0.50, False),
    ("RustBucket", DOWNLOADS / "Broken Car by Quaternius - Y67erogmR9.glb", "Rust Bucket",
     "Held together by optimism.", "classic", 0.45, True),
    ("MuscleCoupe", DOWNLOADS / "Camaro ZL1 2017 by Kris Tong - 7bF7UVAoYRG.glb", "Muscle Coupe",
     "Straight-line monster.", "sports", 0.46, True),
    ("MiniHatch", DOWNLOADS / "Car Hatchback by Kay Lousberg - BG0KAhmGDt.glb", "Mini Hatch",
     "Tiny, eager, forgiving.", "compact", 0.36, False),
    ("Runabout", DOWNLOADS / "Car by Quaternius - Cz6yDaUcM9.glb", "Runabout",
     "Cheerful little thing.", "compact", 0.40, False),
    ("BeachBuggy", DOWNLOADS / "Car by jeremy - bTcqWpYqeeM.glb", "Beach Buggy",
     "Open top, loose grip.", "offroad", 0.42, True),
    ("PonyCar", DOWNLOADS / "Chevrolet Camaro by PuKkBuMXDD - kVcKsd2dEk.glb", "Pony Coupe",
     "Long bonnet, short patience.", "sports", 0.46, False),
    ("Roadster", DOWNLOADS / "Convertible by Poly by Google - 8ACz9InIO0c.glb", "Roadster",
     "Light and neat through corners.", "sports", 0.43, False),
    ("GrandTourer", DOWNLOADS / "Convertible by Poly by Google - dggOiBLYyuR.glb", "Grand Tourer",
     "Fast in a relaxed sort of way.", "sports", 0.45, False),
    ("EightiesIcon", DOWNLOADS / "DREAM FERRARI F40 by Alexander Schick - 6-j7kD0viYB.glb", "Wedge Racer",
     "Wing the size of a table.", "supercar", 0.45, False),
    ("FieldTruck", DOWNLOADS / "Humvee by madtrollstudio - Ebryot9iKM.glb", "Field Truck",
     "Goes anywhere, slowly.", "offroad", 0.50, False),
    ("TrailJeep", DOWNLOADS / "Jeep by Zsky - AcSdGGrgYP.glb", "Trail Runner",
     "Tall and tippy. Great fun.", "offroad", 0.42, False),
    ("RotaryCoupe", DOWNLOADS / "Mazda RX-7 by IvOfficial - SnIoWlh7S2.glb", "Drift Coupe",
     "The drifter's drifter.", "drift", 0.44, False),
    ("VintageSaloon", DOWNLOADS / "Old Car by Attila Dobák - 3knnxGlixiJ.glb", "Vintage Saloon",
     "Skinny tyres, big ideas.", "classic", 0.44, True),
    ("PatrolCar", DOWNLOADS / "Police Car by Quaternius - BwwnUrWGmV.glb", "Police Car",
     "Planted and quick.", "sedan", 0.45, False),
    ("Estate4x4", DOWNLOADS / "Range Rover by IvOfficial - 8zk4o6nALW.glb", "Estate 4x4",
     "Heavy, composed, unhurried.", "offroad", 0.48, False),
    ("Limousine", DOWNLOADS / "Rolls Royce by David Sirera - 3DtJTlxgO_U.glb", "Luxury Limo",
     "Long. Very long.", "classic", 0.52, False),
    ("TrackCoupe", DOWNLOADS / "Sports Car by Quaternius - 1mkmFkAz5v.glb", "Track Coupe",
     "Sharp and predictable.", "sports", 0.44, False),
    ("CityTaxi", DOWNLOADS / "Taxi by Poly by Google - fet47VieV0L.glb", "City Taxi",
     "Soft springs, sliding tail.", "sedan", 0.45, False),
    ("WorkPickup", DOWNLOADS / "Toyota Hilux 97 by Muhammad Reyhan - 8-0nFArehjd.glb", "Work Pickup",
     "Empty bed, loose back end.", "truck", 0.48, True),
    ("AngularTruck", DOWNLOADS / "Truck by sugamo - fbDxapxkwY9.glb", "Angular Truck",
     "Made entirely of straight lines.", "truck", 0.52, False),
    ("FamilyVan", DOWNLOADS / "Van by Poly by Google - aT_24cDaW1a.glb", "Family Van",
     "Leans like a boat. Endearing.", "van", 0.46, False),
    ("BananaKart", DOWNLOADS / "cartoon banana car by Felipe Lujan-Bear - 1RjuCX8gI9w.glb", "Banana Kart",
     "Exactly as silly as it looks.", "novelty", 0.40, False),
]


def kebab(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z0-9])", "-", name).lower().replace("--", "-")


def swift_string(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    RESOURCES.mkdir(parents=True, exist_ok=True)
    for stale in RESOURCES.glob("*.usdz"):
        stale.unlink()
    for stale in list(RESOURCES.glob("*.png")) + list(RESOURCES.glob("*.jpg")):
        stale.unlink()

    entries = []
    for asset, source, display, tagline, car_class, length, flip in CARS:
        if not source.exists():
            print(f"MISSING {source}")
            continue
        command = ["python3", str(ROOT / "Tools" / "glb_to_usdz.py"), str(source),
                   str(RESOURCES / f"{asset}.usdz"), "--name", asset]
        if source.parent == KIT:
            command += ["--texture", str(COLORMAP)]
        if flip:
            command.append("--flip")

        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"FAIL {asset}: {result.stderr.strip().splitlines()[-1][:120]}")
            continue
        report = json.loads(result.stdout.strip().splitlines()[-1])

        # Namespace the loose base-colour map so cars cannot collide in the bundle.
        texture_name = texture_ext = None
        for name in report["textures"]:
            original = RESOURCES / name
            if not original.exists():
                continue
            texture_ext = original.suffix.lstrip(".")
            texture_name = f"{asset}Paint"
            original.rename(RESOURCES / f"{texture_name}.{texture_ext}")

        paint = report.get("paint") or {}
        # A tiny saturated area is a tail light or a badge, not the paint, and
        # a washed-out one is glass. Cars failing either test simply keep the
        # colours they were authored with.
        if paint.get("areaShare", 0) < 0.16 or paint.get("saturation", 0) < 0.38:
            paint = {}
        entries.append({
            "id": kebab(asset), "asset": asset, "display": display, "tagline": tagline,
            "class": car_class, "length": length,
            "texture": texture_name, "textureExt": texture_ext,
            "paint": paint, "report": report,
        })
        print(f"{asset:16s} {report['triangles']:6d} tris  {report['sizeKB']:5d} KB  "
              f"wheels={len(report['wheels'])}  paint hue={paint.get('hue')}  "
              f"{','.join(report['orientation']) or 'as authored'}")

    (ROOT / "Tools" / "cars.json").write_text(json.dumps(entries, indent=2))
    write_catalog(entries)
    total = sum(e["report"]["sizeKB"] for e in entries)
    print(f"\n{len(entries)} cars, {total} KB of usdz")


def write_catalog(entries):
    lines = [
        "//",
        "//  CarCatalog.swift",
        "//  vr",
        "//",
        "//  GENERATED by Tools/build_cars.py — do not edit by hand.",
        "//  Geometry, paint colour and orientation are measured from the models;",
        "//  names, taglines and vehicle class come from the table in that script.",
        "//",
        "",
        "import Foundation",
        "",
        "extension CarCatalog {",
        "",
        "    static let generated: [CarDefinition] = [",
    ]
    for e in entries:
        paint = e["paint"] or {}
        hue = paint.get("hue", 0.0)
        tolerance = 26 if paint.get("textured") else 40
        if not paint:
            texture = "CarDefinition.PaintSource.fixed"
        elif e["texture"] and paint.get("textured"):
            texture = (f'CarDefinition.PaintSource.texture(name: {swift_string(e["texture"])}, '
                       f'fileExtension: {swift_string(e["textureExt"])})')
        else:
            texture = "CarDefinition.PaintSource.materialColour"
        lines += [
            "        CarDefinition(",
            f"            id: {swift_string(e['id'])},",
            f"            displayName: {swift_string(e['display'])},",
            f"            tagline: {swift_string(e['tagline'])},",
            f"            assetName: {swift_string(e['asset'])},",
            f"            carClass: .{e['class']},",
            f"            length: {e['length']},",
            f"            paintSource: {texture},",
            f"            paintHue: {hue},",
            f"            paintHueTolerance: {tolerance},",
            f"            paintSaturation: {paint.get('saturation', 0.7)},",
            f"            paintBrightness: {paint.get('brightness', 0.9)}",
            "        ),",
        ]
    lines += ["    ]", "}", ""]
    (ROOT / "vr" / "Car" / "CarCatalogGenerated.swift").write_text("\n".join(lines))


if __name__ == "__main__":
    sys.exit(main())
