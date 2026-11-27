#!/usr/bin/env python3
"""Cuts one region out of a country-wide Valhalla tile directory.

    tool/slice_routing.py tar  <tiles-dir> <region.poly> <valhalla.json> <build-id> <out.tar>
    tool/slice_routing.py geojson <region.poly> <out.geojson>

`tar` writes build.txt, valhalla.json and tiles/<level>/... for every graph
tile that touches the region. Tiles of all regions come from the same build,
so the app can merge several regions into one routable graph.
`geojson` converts an Osmosis .poly file for tools that want GeoJSON.
"""
import json
import os
import sys
import tarfile

LEVEL_SIZE = {0: 4.0, 1: 1.0, 2: 0.25}  # degrees per tile side
MARGIN = 0.05  # degrees: keep tiles just across the border too


def read_poly(path):
    """Returns (outer_rings, holes), each a list of [(lon, lat), ...]."""
    outer, holes, ring, hole = [], [], None, False
    with open(path) as f:
        lines = [line.strip() for line in f][1:]
    for line in lines:
        if not line:
            continue
        if line == "END":
            if ring is not None:
                (holes if hole else outer).append(ring)
                ring = None
            continue
        if ring is None:
            hole = line.startswith("!")
            ring = []
            continue
        lon, lat = line.split()[:2]
        ring.append((float(lon), float(lat)))
    return outer, holes


def in_ring(ring, x, y):
    inside = False
    j = len(ring) - 1
    for i in range(len(ring)):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def tile_bbox(level, tile_id):
    size = LEVEL_SIZE[level]
    cols = int(360 / size)
    row, col = divmod(tile_id, cols)
    west, south = col * size - 180, row * size - 90
    return west, south, west + size, south + size


def touches(outer, bbox):
    west, south, east, north = bbox
    west, south, east, north = west - MARGIN, south - MARGIN, east + MARGIN, north + MARGIN
    for ring in outer:
        # A border vertex inside the tile, or the tile inside the region.
        if any(west <= x <= east and south <= y <= north for x, y in ring):
            return True
        samples = [(west, south), (west, north), (east, south), (east, north),
                   ((west + east) / 2, (south + north) / 2)]
        if any(in_ring(ring, x, y) for x, y in samples):
            return True
    return False


def slice_tar(tiles_dir, poly, config, build_id, out):
    outer, _ = read_poly(poly)
    kept = total = 0
    with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as tar:
        def add_bytes(name, data):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o644
            tar.addfile(info, __import__("io").BytesIO(data))

        add_bytes("build.txt", (build_id + "\n").encode())
        with open(config, "rb") as f:
            add_bytes("valhalla.json", f.read())
        for level in sorted(LEVEL_SIZE):
            base = os.path.join(tiles_dir, str(level))
            for folder, _, files in sorted(os.walk(base)):
                for name in sorted(files):
                    if not name.endswith(".gph"):
                        continue
                    total += 1
                    rel = os.path.relpath(os.path.join(folder, name), tiles_dir)
                    digits = rel[len(str(level)) + 1:-4].replace(os.sep, "")
                    if touches(outer, tile_bbox(level, int(digits))):
                        info = tar.gettarinfo(os.path.join(folder, name), "tiles/" + rel.replace(os.sep, "/"))
                        info.uid = info.gid = 0
                        info.uname = info.gname = ""
                        info.mode = 0o644
                        with open(os.path.join(folder, name), "rb") as f:
                            tar.addfile(info, f)
                        kept += 1
    print(f"{os.path.basename(out)}: {kept} of {total} tiles, {os.path.getsize(out) / 1e6:.0f} MB")


def to_geojson(poly, out):
    outer, holes = read_poly(poly)
    # Holes are attached to every outer ring: fine for clipping tools.
    polygons = [[ring] + holes for ring in outer]
    with open(out, "w") as f:
        json.dump({"type": "MultiPolygon", "coordinates": polygons}, f)


if __name__ == "__main__":
    if len(sys.argv) == 7 and sys.argv[1] == "tar":
        slice_tar(*sys.argv[2:])
    elif len(sys.argv) == 4 and sys.argv[1] == "geojson":
        to_geojson(*sys.argv[2:])
    else:
        sys.exit(__doc__)
