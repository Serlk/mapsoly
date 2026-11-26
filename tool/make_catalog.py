#!/usr/bin/env python3
"""Prepares built region packs for publishing.

    tool/make_catalog.py [pack-name ...]      (default: every pack in data/packs)

Writes data/publish/: one flat-named link per pack file plus catalog.json
with sizes and SHA-256 digests. Upload the whole folder to any static host
(file URLs in the catalog are relative to catalog.json); the app reads the
catalog and downloads packs from there.
"""
import hashlib
import json
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data")
FILES = ["map.pmtiles", "places.sqlite", "valhalla/tiles.tar", "valhalla/valhalla.json"]
NAMES = {"moscow": "Москва и Московская область", "kaliningrad": "Калининградская область"}


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    packs_dir = os.path.join(ROOT, "packs")
    out = os.path.join(ROOT, "publish")
    os.makedirs(out, exist_ok=True)
    names = sys.argv[1:] or sorted(os.listdir(packs_dir))
    packs = []
    for name in names:
        src = os.path.join(packs_dir, name)
        present = [f for f in FILES if os.path.isfile(os.path.join(src, f))]
        if "map.pmtiles" not in present:
            print(f"skip {name}: no map.pmtiles")
            continue
        # The pack version is the newest file's date: it changes on rebuild.
        newest = max(os.path.getmtime(os.path.join(src, f)) for f in present)
        version = __import__("time").strftime("%Y-%m-%d", __import__("time").gmtime(newest))
        files = []
        for rel in present:
            path = os.path.join(src, rel)
            flat = f"{name}-{rel.replace('/', '_')}"
            link = os.path.join(out, flat)
            if os.path.lexists(link):
                os.remove(link)
            try:
                os.link(path, link)
            except OSError:
                os.symlink(path, link)
            files.append({"path": rel, "url": flat, "size": os.path.getsize(path), "sha256": digest(path)})
            print(f"{name}: {rel} {os.path.getsize(path) / 1e6:.1f} MB")
        entry = {"id": name, "name": NAMES.get(name, name), "version": version, "files": files}
        build = os.path.join(src, "valhalla", "build.json")
        if os.path.isfile(build):
            bbox = json.load(open(build)).get("bbox")
            if bbox:
                entry["bounds"] = bbox
        packs.append(entry)
    with open(os.path.join(out, "catalog.json"), "w") as f:
        json.dump({"format": 1, "packs": packs}, f, ensure_ascii=False, indent=1)
    print(f"wrote {out}/catalog.json with {len(packs)} pack(s)")


if __name__ == "__main__":
    main()
