#!/usr/bin/env python3
"""build_maplibre_assets.py <data/maplibre-assets> <out dir>

Collects the region-independent files MapLibre needs offline, trimmed for the app:
  <out>/fonts/<fontstack>/<range>.pbf   glyphs of the font stacks the two styles use,
                                        only the Unicode ranges in KEEP
  <out>/sprites/{bright,dark}/sprite[@2x].{json,png}
The input directory is what spike/maplibre/make_assets.py produced (it downloads the
OpenMapTiles fonts and sprites and composites multi-font stacks). The styles themselves
are not copied: the app rewrites assets/styles/*.json at run time (pack path, these paths).
"""
import json, os, shutil, sys

# 256-codepoint blocks: 0-1535 = Latin, Latin Extended, IPA, diacritics, Greek, Cyrillic,
# Cyrillic Supplement; 8192-8703 = general punctuation, currency, letterlike, arrows.
KEEP = [(0, 1535), (8192, 8703)]


def stacks_of(style_path):
    out = set()

    def walk(v):
        if isinstance(v, dict):
            f = v.get("text-font")
            if isinstance(f, list) and all(isinstance(x, str) for x in f):
                out.add(",".join(f))
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)

    walk(json.load(open(style_path)))
    return out


def main(src, dst):
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    stacks = set()
    for name in ("bright", "dark"):
        stacks |= stacks_of(os.path.join(root, "assets", "styles", name + ".json"))
    shutil.rmtree(dst, ignore_errors=True)
    total = 0
    for stack in sorted(stacks):
        s = os.path.join(src, "fonts", stack)
        if not os.path.isdir(s):
            sys.exit("missing font stack %r in %s (run spike/maplibre/make_assets.py)" % (stack, src))
        d = os.path.join(dst, "fonts", stack)
        os.makedirs(d)
        size = 0
        for lo, hi in KEEP:
            for start in range(lo, hi + 1, 256):
                name = "%d-%d.pbf" % (start, start + 255)
                shutil.copy(os.path.join(s, name), d)
                size += os.path.getsize(os.path.join(s, name))
        total += size
        print("%-60s %6.0f kB" % (stack, size / 1024))
    for name in ("bright", "dark"):
        shutil.copytree(os.path.join(src, "sprites", name), os.path.join(dst, "sprites", name))
        total += sum(os.path.getsize(os.path.join(dst, "sprites", name, f)) for f in os.listdir(os.path.join(dst, "sprites", name)))
    print("total %.1f MB in %s" % (total / 1e6, dst))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
