#!/usr/bin/env python3
"""analyze.py <run-dir> [...]           -- full report for runs of phone/run_bench.sh
analyze.py --table <run-dir> [...]   -- one comparison row per run (also reads the
                                        standalone spike runs of phone/run_standalone.sh;
                                        median/p99/low/>33/>50 are of "shown" frames when
                                        there is such a stream, else of rendered frames)

Four event streams, each as frame-interval statistics over the moving segments:
  map rendered   bench.frames.csv   MapLibre finished a frame (GPU done)       [MapLibre side]
  map shown      bench.consume.csv  Flutter's raster thread picked a NEW map frame up
  flutter raster bench.flutter.csv  FrameTiming rasterFinish (only frames with a build)
  gtk paint      bench.paint.csv    GdkFrameClock after-paint = wl_surface commit
plus build/raster durations, hand-over latency and the CPU/GPU table of the spike.
"""
import csv, os, sys, statistics as st

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "maplibre"))
import analyze as spike  # noqa: E402  (prints nothing on import: guarded below)


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * p))]


def row(name, iv):
    if len(iv) < 2:
        return "| %s | - |" % name
    worst1 = sorted(iv)[-max(1, len(iv) // 100):]
    return "| %s | %d | %.1f | %.1f | %.1f | %.1f | %.1f | %d (%.1f %%) | %d | %d |" % (
        name, len(iv), 1000 * len(iv) / sum(iv), st.median(iv), pct(iv, 0.99), 1000 / st.mean(worst1), max(iv),
        sum(x > 33.4 for x in iv), 100 * sum(x > 33.4 for x in iv) / len(iv), sum(x > 50 for x in iv),
        sum(x > 100 for x in iv))


HEAD = ("| stream | frames | avg FPS | median ms | p99 ms | 1% low FPS | worst ms | >33 ms | >50 ms | >100 ms |\n"
        "|---|---|---|---|---|---|---|---|---|---|")


def intervals(ts_ms, windows):
    """intervals between consecutive events, only inside the given [lo, hi] windows"""
    out = []
    for lo, hi in windows:
        t = [x for x in ts_ms if lo <= x <= hi]
        out += [b - a for a, b in zip(t, t[1:])]
    return out


def main(d):
    print("\n### %s\n" % d)
    frames = spike.frames(d + "/bench.frames.csv")
    moving = [r for r in frames if not r["seg"].startswith(("load", "jump", "end"))]
    segs, order = {}, []
    for r in moving:
        if r["seg"] not in segs:
            order.append(r["seg"]); segs[r["seg"]] = []
        segs[r["seg"]].append(r)
    # windows in boot-ms; consume/paint/flutter use CLOCK_MONOTONIC us -> offset from consume.csv
    cons = list(csv.DictReader(open(d + "/bench.consume.csv")))
    off = st.median(int(c["mono_us"]) / 1000 - int(c["boot_ms"]) for c in cons) if cons else 0
    win = [(segs[s][0]["boot_ms"], segs[s][-1]["boot_ms"]) for s in order]
    hidden = [s for s in order if any(r["interval_ms"] > 600 for r in segs[s][1:])]
    # focus.txt: "<uptime s> <title of the focused window>" once a second. A segment during
    # which another window (or none: a shell overlay) had the focus is not a valid measurement.
    try:
        lost = [float(l.split(" ", 1)[0]) * 1000 for l in open(d + "/focus.txt")
                if " " in l and l.split(" ", 1)[1].strip() != "MlnFlutterSpike"]
    except FileNotFoundError:
        lost = []
    hidden += [s for s, (lo, hi) in zip(order, win) if s not in hidden and any(lo - 1100 <= t <= hi + 1100 for t in lost)]
    if hidden:
        print("**INVALID segments (window hidden or not focused): %s** - excluded\n" % ", ".join(hidden))
        win = [w for s, w in zip(order, win) if s not in hidden]
        order = [s for s in order if s not in hidden]
    c_ms = [int(c["mono_us"]) / 1000 - off for c in cons]
    paint = [int(l) / 1000 - off for l in open(d + "/bench.paint.csv").read().split()[1:]]
    fl = list(csv.DictReader(open(d + "/bench.flutter.csv")))
    fl_fin = [int(r["raster_finish_us"]) / 1000 - off for r in fl]

    print(HEAD)
    print(row("map rendered (MapLibre)", [r["interval_ms"] for s in order for r in segs[s][1:]]))
    print(row("map shown (picked up by Flutter raster)", intervals(c_ms, win)))
    print(row("Flutter rasterFinish (FrameTiming)", intervals(fl_fin, win)))
    print(row("GTK paint (surface commit)", intervals(paint, win)))
    print()
    print("Per segment, map frames picked up by Flutter:\n")
    print(HEAD.replace("stream", "segment"))
    for s, w in zip(order, win):
        print(row(s, intervals(c_ms, [w])))
    print()

    inwin = lambda t: any(lo <= t <= hi for lo, hi in win)
    lat = [float(c["latency_ms"]) for c, t in zip(cons, c_ms) if inwin(t)]
    gw = [r["gpuwait_ms"] for s in order for r in segs[s]]
    fm = [r["frame_ms"] for s in order for r in segs[s]]
    cpu = [r["enc_ms"] + r["rend_ms"] for s in order for r in segs[s]]
    print("| per-frame cost, ms | mean | median | p99 | max |\n|---|---|---|---|---|")
    for name, v in (("MapLibre render() wall incl. GPU wait", fm), ("  of which MapLibre encode+render (CPU)", cpu),
                    ("  of which wait for GPU (fence)", gw), ("hand-over: map frame finished -> picked up by Flutter", lat)):
        if v:
            print("| %s | %.1f | %.1f | %.1f | %.1f |" % (name, st.mean(v), st.median(v), pct(v, 0.99), max(v)))
    flw = [r for r, t in zip(fl, fl_fin) if inwin(t)]
    if flw:
        for name, k in (("Flutter build (UI thread)", "build_us"), ("Flutter raster", "raster_us"),
                        ("Flutter vsync -> rasterFinish", "total_us")):
            v = [int(r[k]) / 1000 for r in flw]
            print("| %s (%d frames) | %.1f | %.1f | %.1f | %.1f |" % (name, len(v), st.mean(v), st.median(v), pct(v, 0.99), max(v)))
        r16 = sum(int(r["raster_us"]) > 16667 for r in flw); b16 = sum(int(r["build_us"]) > 16667 for r in flw)
        print("\nFlutter frames with raster > 16.7 ms: %d, build > 16.7 ms: %d (of %d)" % (r16, b16, len(flw)))
    print()
    for line in open(d + "/log.txt", errors="replace"):
        if line.startswith("BENCH load"):
            print("-", line.strip()[6:])
    print()
    try:
        valid = [r for s in order for r in segs[s]]
        smp = [x for x in spike.samples(d + "/samples.txt") if any(lo / 1000 <= x["t"] <= hi / 1000 for lo, hi in win)]
        # cpu_table() pairs consecutive samples: drop pairs that straddle an excluded gap
        spike.cpu_table([x for i, x in enumerate(smp) if i == 0 or x["t"] - smp[i - 1]["t"] < 1.5] if not hidden else smp, valid)
        if hidden:
            print("(CPU/GPU table: samples from valid segments only; a pair spanning an excluded segment can inflate one sample)")
    except FileNotFoundError:
        pass
    try:
        titles = [l.split(" ", 1)[1].strip() for l in open(d + "/focus.txt") if " " in l]
        other = [t for t in titles if t != "MlnFlutterSpike"]
        print("\nFocus samples (1/s): %d, not on the test window: %d %s" % (len(titles), len(other), sorted(set(other)) or ""))
    except FileNotFoundError:
        pass


def summary(d):
    """one table row per run; works for the standalone spike layout (bench.csv) too"""
    flutter = os.path.exists(d + "/bench.frames.csv")
    frames = spike.frames(d + ("/bench.frames.csv" if flutter else "/bench.csv"))
    segs, order = {}, []
    for r in frames:
        if r["seg"].startswith(("load", "jump", "end")):
            continue
        if r["seg"] not in segs:
            order.append(r["seg"]); segs[r["seg"]] = []
        segs[r["seg"]].append(r)
    win = {s: (segs[s][0]["boot_ms"], segs[s][-1]["boot_ms"]) for s in order}
    own = ("MlnFlutterSpike",) if flutter else ("",)  # the GLFW window has an empty app id
    try:
        lost = [float(l.split(" ", 1)[0]) * 1000 for l in open(d + "/focus.txt")
                if " " in l and l.split(" ", 1)[1].strip() not in own]
    except FileNotFoundError:
        lost = []
    bad = [s for s in order if any(r["interval_ms"] > 600 for r in segs[s][1:])
           or any(win[s][0] - 1100 <= t <= win[s][1] + 1100 for t in lost)]
    ok = [s for s in order if s not in bad]
    iv = [r["interval_ms"] for s in ok for r in segs[s][1:]]
    shown = None
    if flutter and os.path.getsize(d + "/bench.consume.csv") > 40:
        cons = list(csv.DictReader(open(d + "/bench.consume.csv")))
        shown = intervals([int(c["boot_ms"]) + (int(c["mono_us"]) % 1000) / 1000 for c in cons], [win[s] for s in ok])
    smp = [x for x in spike.samples(d + "/samples.txt") if any(win[s][0] / 1000 <= x["t"] <= win[s][1] / 1000 for s in ok)]
    cpu, gpu = {}, []
    # whole-system busy jiffies ("C cpu user nice system idle iowait irq softirq ...") per sample time
    sysbusy = {}
    t_cur = None
    for line in open(d + "/samples.txt"):
        if line.startswith("T "):
            t_cur = float(line.split()[1])
        elif line.startswith("C cpu") and t_cur is not None:
            f = [int(x) for x in line.split()[2:10]]
            sysbusy[t_cur] = sum(f) - f[3] - f[4]
    for a, b in zip(smp, smp[1:]):
        dt = b["t"] - a["t"]
        if dt > 1.5:
            continue
        gpu.append(b["gpu"])
        tot = 0
        main_tid = min(int(k[0]) for k in b["th"])
        for k, v in b["th"].items():
            dd = (v - a["th"].get(k, v)) / spike.HZ / dt * 100
            tot += dd
            name = "main" if int(k[0]) == main_tid else k[1]
            cpu.setdefault(name, []).append(dd)
        cpu.setdefault("total", []).append(tot)
        ext = 0
        for k, v in b["x"].items():
            if k in a["x"]:
                dd = (v - a["x"][k]) / spike.HZ / dt * 100
                ext += dd
                cpu.setdefault("x:" + k[1], []).append(dd)
        if a["t"] in sysbusy and b["t"] in sysbusy:  # everything that is neither this app nor niri
            cpu.setdefault("others", []).append((sysbusy[b["t"]] - sysbusy[a["t"]]) / spike.HZ / dt * 100 - tot - ext)
    n = max(1, len(gpu))
    m = lambda k: sum(cpu.get(k, [0])) / n
    use = shown if shown else iv
    w1 = sorted(use)[-max(1, len(use) // 100):]
    secs = sum(win[s][1] - win[s][0] for s in ok) / 1000
    others = "%.0f" % st.mean(cpu["others"]) if cpu.get("others") else "n/a"
    return "| %s | %d/9 (%.0f s) | %.1f | %s | %.1f | %.1f | %.1f | %.1f %% | %d | %.0f | %.0f | %.0f | %.0f | %.0f | %s | %.0f | %.0f %% |" % (
        os.path.basename(d), len(ok), secs, 1000 * len(iv) / sum(iv), "%.1f" % (1000 * len(shown) / sum(shown)) if shown else "=",
        st.median(use), pct(use, 0.99), 1000 / st.mean(w1), 100 * sum(x > 33.4 for x in use) / len(use), sum(x > 50 for x in use),
        m("total"), m("mln-map") if flutter else m("main"), m("main") if flutter else 0, m("io.flutter.rast"), m("x:niri"), others,
        st.mean(gpu) if gpu else 0, 100 * sum(g >= 1040 for g in gpu) / n)


SUMMARY_HEAD = ("| run | valid segs | map FPS rendered | map FPS shown | median ms | p99 ms | 1% low FPS | >33 ms | >50 ms "
                "| CPU total % | map render thread % | GTK main thread % | Flutter raster % | niri % | other procs % | GPU MHz | GPU at max |\n"
                "|" + "---|" * 17)

if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "--table":  # compact comparison, one row per run directory
        print(SUMMARY_HEAD)
        for d in args[1:]:
            try:
                print(summary(d.rstrip("/")))
            except Exception as e:  # incomplete run directory
                print("| %s | error: %s |" % (os.path.basename(d.rstrip("/")), e))
    else:
        for d in args:
            main(d.rstrip("/"))
