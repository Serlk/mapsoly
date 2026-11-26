#!/usr/bin/env python3
"""analyze.py <run-dir> [...]  -- summarises bench.csv + samples.txt of run_bench.sh"""
import csv, re, sys, statistics as st
from collections import defaultdict

HZ = 100.0  # CLK_TCK


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * p))]


def frames(path):
    rows = list(csv.DictReader(open(path)))
    for r in rows:
        for k in r:
            if k != "seg":
                r[k] = float(r[k])
    return rows


def frame_table(rows):
    segs, order = defaultdict(list), []
    for r in rows:
        if r["seg"] not in segs:
            order.append(r["seg"])
        segs[r["seg"]].append(r)
    moving = [s for s in order if not s.startswith(("load", "jump", "end"))]
    # niri throttles frame callbacks of a non-visible window to 1 Hz: a segment with
    # ~1 s frames means somebody switched windows on the phone -> not a renderer result.
    bad = {s for s in moving if any(r["interval_ms"] > 600 for r in segs[s][1:])}
    groups = [("ALL valid moving segments", [r for s in moving if s not in bad for r in segs[s]])]
    groups += [(s + (" (INVALID: window hidden)" if s in bad else ""), segs[s]) for s in moving]
    print("| segment | frames | avg FPS | median ms | p99 ms | 1% low FPS | worst ms | >20 ms | >33 ms | >50 ms | CPU render ms avg/p99 | draw calls |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for name, rs in groups:
        iv = [r["interval_ms"] for r in rs[1:]]
        if not iv:
            continue
        cpu = [r["enc_ms"] + r["rend_ms"] for r in rs]
        worst1 = sorted(iv)[-max(1, len(iv) // 100):]
        print("| %s | %d | %.1f | %.1f | %.1f | %.1f | %.1f | %d | %d | %d | %.1f / %.1f | %d |" % (
            name, len(iv), 1000 * len(iv) / sum(iv), st.median(iv), pct(iv, 0.99), 1000 / st.mean(worst1), max(iv),
            sum(x > 20 for x in iv), sum(x > 33.4 for x in iv), sum(x > 50 for x in iv),
            st.mean(cpu), pct(cpu, 0.99), st.mean(r["drawcalls"] for r in rs)))


def samples(path):
    out, cur = [], None
    for line in open(path):
        if line.startswith("T "):
            p = line.split()
            cur = {"t": float(p[1]), "gpu": float(p[2]) / 1e6, "rss": float(p[3]) / 1024 if len(p) > 3 else 0, "th": {}, "x": {}}
            out.append(cur)
            continue
        ext = line.startswith("X ")
        m = re.match(r"(?:X \d+ )?(\d+) \((.*)\) \S (.*)", line)
        if not m or cur is None:
            continue
        f = m.group(3).split()
        ticks = int(f[10]) + int(f[11])  # utime + stime
        (cur["x"] if ext else cur["th"])[(m.group(1), m.group(2))] = ticks
    return out


def cpu_table(smp, rows):
    t_lo = min(r["boot_ms"] for r in rows if not r["seg"].startswith(("load", "jump", "end"))) / 1000
    t_hi = max(r["boot_ms"] for r in rows if not r["seg"].startswith(("load", "jump", "end"))) / 1000
    per, tot, gpu, rss, ext = defaultdict(list), [], [], [], defaultdict(list)
    for a, b in zip(smp, smp[1:]):
        if a["t"] < t_lo or b["t"] > t_hi:
            continue
        dt = b["t"] - a["t"]
        s = 0
        for k, v in b["th"].items():
            d = (v - a["th"].get(k, v)) / HZ / dt * 100
            per[k].append(d); s += d
        for k, v in b["x"].items():
            if k in a["x"]:
                ext[k[1]].append((v - a["x"][k]) / HZ / dt * 100)
        tot.append(s); gpu.append(b["gpu"]); rss.append(b["rss"])
    if not tot:
        print("no samples in window"); return
    n = len(tot)
    print("CPU during moving segments (%d samples of ~0.5 s; %% of one core):" % n)
    print("| thread | mean % | max % |\n|---|---|---|")
    print("| **process total** | %.0f | %.0f |" % (st.mean(tot), max(tot)))
    names = defaultdict(lambda: [0.0, 0.0, 0])
    main_tid = min(int(k[0]) for k in per)
    for k, v in per.items():
        name = "main/render thread (%s)" % k[1] if int(k[0]) == main_tid else k[1]
        names[name][0] += sum(v) / n; names[name][1] = max(names[name][1], max(v)); names[name][2] += 1
    for name, (mean, mx, cnt) in sorted(names.items(), key=lambda x: -x[1][0]):
        if mean >= 0.5:
            print("| %s%s | %.0f | %.0f (single thread) |" % (name, " x%d (sum)" % cnt if cnt > 1 else "", mean, mx))
    for k, v in ext.items():
        print("| other process: %s | %.0f | %.0f |" % (k, st.mean(v), max(v)))
    print("\nGPU freq MHz: mean %.0f, min %.0f, max %.0f; share of samples at max (>=1040): %.0f%%; at min (265): %.0f%%" % (
        st.mean(gpu), min(gpu), max(gpu), 100 * sum(g >= 1040 for g in gpu) / n, 100 * sum(g <= 266 for g in gpu) / n))
    allrss = [s["rss"] for s in smp if s["rss"]]
    print("RSS MB: mean %.0f during moving segments, peak %.0f over whole run" % (st.mean(rss), max(allrss)))


if __name__ == "__main__":  # importable by spike/maplibre_flutter/analyze.py
    for d in sys.argv[1:]:
        print("\n### %s\n" % d)
        rows = frames(d + "/bench.csv")
        frame_table(rows)
        print()
        for line in open(d + "/log.txt", errors="replace"):
            if line.startswith("BENCH load"):
                print("-", line.strip()[6:])
        print()
        try:
            cpu_table(samples(d + "/samples.txt"), rows)
        except FileNotFoundError:
            pass
