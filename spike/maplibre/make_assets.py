#!/usr/bin/env python3
"""Builds fully-offline MapLibre assets for the mapsoly styles.

  spike/maplibre/make_assets.py [--out data/maplibre-assets]
        [--root /abs/dir/on/device/assets] [--pmtiles /abs/path/moscow.pmtiles]

Downloads (no accounts / keys):
  * glyph PBFs:  https://github.com/openmaptiles/fonts/releases/download/v2.0/v2.0.zip
  * sprites:     https://openmaptiles.github.io/{osm-bright,dark-matter}-gl-style/sprite[@2x].{json,png}
Produces under --out:
  fonts/<fontstack>/<range>.pbf   every font stack the styles reference. MapLibre
                                  Native asks for the comma-joined stack as ONE
                                  resource ("Metropolis Light,Noto Sans Regular"),
                                  so multi-font stacks are composited here
                                  (first font wins per glyph id), like a font server would.
  sprites/<style>/sprite[@2x].{json,png}
  styles/<style>.json             copies of assets/styles/*.json with source url,
                                  glyphs and sprite rewritten to pmtiles://file:// and file://
                                  URLs below --root (the directory as seen on the device).
"""
import argparse, json, os, shutil, subprocess, zipfile

FONTS_URL = "https://github.com/openmaptiles/fonts/releases/download/v2.0/v2.0.zip"
SPRITES = {"bright": "https://openmaptiles.github.io/osm-bright-gl-style/sprite",
           "dark": "https://openmaptiles.github.io/dark-matter-gl-style/sprite"}
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))


def fetch(url, dst):
    if not os.path.exists(dst):
        subprocess.check_call(["curl", "-fsSL", "--retry", "3", "-o", dst + ".part", url])
        os.rename(dst + ".part", dst)


# --- minimal protobuf helpers (glyphs.proto: glyphs{repeated fontstack stacks=1},
#     fontstack{name=1, range=2, repeated glyph glyphs=3}, glyph{id=1,...}) ---
def varint(b, i):
    r = s = 0
    while True:
        c = b[i]; i += 1
        r |= (c & 0x7F) << s; s += 7
        if not c & 0x80:
            return r, i


def enc_varint(v):
    out = bytearray()
    while True:
        c = v & 0x7F; v >>= 7
        out.append(c | (0x80 if v else 0))
        if not v:
            return bytes(out)


def fields(b):
    i = 0
    while i < len(b):
        key, i = varint(b, i)
        f, wt = key >> 3, key & 7
        if wt == 0:
            v, i = varint(b, i)
        elif wt == 2:
            n, i = varint(b, i); v = b[i:i + n]; i += n
        elif wt == 5:
            v = b[i:i + 4]; i += 4
        elif wt == 1:
            v = b[i:i + 8]; i += 8
        else:
            raise ValueError("wire type %d" % wt)
        yield f, wt, v


def ld(f, payload):
    return enc_varint(f << 3 | 2) + enc_varint(len(payload)) + payload


def glyphs_of(pbf):
    """-> {glyph id: raw glyph message bytes}"""
    out = {}
    for f, _, stack in fields(pbf):
        if f != 1:
            continue
        for g, _, gv in fields(stack):
            if g == 3:
                gid = next(v for k, _, v in fields(gv) if k == 1)
                out.setdefault(gid, gv)
    return out


def composite(name, rng, pbfs):
    merged = {}
    for p in pbfs:
        for gid, raw in glyphs_of(p).items():
            merged.setdefault(gid, raw)
    stack = ld(1, name.encode()) + ld(2, rng.encode())
    for gid in sorted(merged):
        stack += ld(3, merged[gid])
    return ld(1, stack)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(REPO, "data", "maplibre-assets"))
    ap.add_argument("--root", default="/home/serlk/mapsoly-maplibre/assets")
    ap.add_argument("--pmtiles", default="/home/serlk/.local/share/dev.mapsoly.mapsoly/packs/moscow/map.pmtiles")
    a = ap.parse_args()
    dl = os.path.join(a.out, "dl"); os.makedirs(dl, exist_ok=True)
    fetch(FONTS_URL, os.path.join(dl, "fonts-v2.0.zip"))
    zf = zipfile.ZipFile(os.path.join(dl, "fonts-v2.0.zip"))
    names = set(zf.namelist())

    stacks = set()
    for style, sprite in SPRITES.items():
        src = json.load(open(os.path.join(REPO, "assets", "styles", style + ".json")))
        for layer in src["layers"]:
            tf = layer.get("layout", {}).get("text-font")
            if tf is None:
                continue
            assert isinstance(tf, list) and all(isinstance(x, str) for x in tf), tf
            stacks.add(tuple(tf))
        sd = os.path.join(a.out, "sprites", style); os.makedirs(sd, exist_ok=True)
        for suffix in ("", "@2x"):
            for ext in (".json", ".png"):
                fetch(sprite + suffix + ext, os.path.join(sd, "sprite" + suffix + ext))
        src["sources"]["openmaptiles"] = {"type": "vector", "url": "pmtiles://file://" + a.pmtiles}
        src["glyphs"] = "file://" + a.root + "/fonts/{fontstack}/{range}.pbf"
        src["sprite"] = "file://" + a.root + "/sprites/" + style + "/sprite"
        os.makedirs(os.path.join(a.out, "styles"), exist_ok=True)
        json.dump(src, open(os.path.join(a.out, "styles", style + ".json"), "w"), ensure_ascii=False, indent=1)

    for stack in sorted(stacks):
        name = ",".join(stack)
        d = os.path.join(a.out, "fonts", name)
        shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
        size = 0
        for start in range(0, 65536, 256):
            rng = "%d-%d" % (start, start + 255)
            pbfs = [zf.read("%s/%s.pbf" % (f, rng)) for f in stack if "%s/%s.pbf" % (f, rng) in names]
            data = pbfs[0] if len(stack) == 1 else composite(name, rng, pbfs)
            open(os.path.join(d, rng + ".pbf"), "wb").write(data); size += len(data)
        print("%-45s %6.1f MB" % (name, size / 1e6))


if __name__ == "__main__":
    main()
