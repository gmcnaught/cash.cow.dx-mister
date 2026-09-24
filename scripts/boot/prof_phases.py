#!/usr/bin/env python3
"""Per-phase exclusive main-thread time by load primitive, from the cumulative
`prof` lines of a MISTER_BOOTLOG (engine >= godot43pb). The remainder of each
phase's wall time ("other") is time outside every scope: script execution
outside _ready, engine setup, waits. prof_phases.py <capture dir> [...]"""
import pathlib, re, sys

CUTS = ["end Startup:Main::Setup2", "end Startup:Load Autoloads", "end Startup:Load Game", "end Startup:Main::Start", "attract_panel.scn"]


def phases(d):
    d = pathlib.Path(d)
    T0 = float((d / "t0.txt").read_text().split()[1])
    lines = [ln.split(" ", 1) for ln in (d / "bootlog.txt").read_text().splitlines()]
    snaps = []  # (t, name, {cat: (ms, calls)})
    last_label = None
    for t, s in lines:
        t = float(t) - T0
        if s.startswith("end ") or s.startswith("load 0 "):
            last_label = s
        if s.startswith("prof "):
            v = {k: (float(ms), int(n)) for k, ms, n in re.findall(r"(\w+)=([\d.]+)/(\d+)", s)}
            snaps.append((t, last_label, v))
    out = []
    prev_t, prev_v = float(next(t for t, s in lines if "begin Startup:Main::Setup" in s)) - T0, None
    for cut in CUTS:
        hit = next((sn for sn in snaps if sn[1] and cut in sn[1]), None)
        if not hit:
            continue
        t, _, v = hit
        delta = {k: (v[k][0] - (prev_v[k][0] if prev_v else 0), v[k][1] - (prev_v[k][1] if prev_v else 0)) for k in v}
        out.append((cut.replace("end Startup:", "").replace(".scn", ""), t - prev_t, delta))
        prev_t, prev_v = t, v
    return out


for a in sys.argv[1:]:
    print(f"== {pathlib.Path(a).name}")
    ph = phases(a)
    cats = list(ph[0][2].keys())
    print(f"{'phase (ends at)':<22}{'wall':>7}" + "".join(f"{c:>12}" for c in cats) + f"{'other':>9}")
    tot = {c: 0.0 for c in cats}; wt = 0.0
    for name, wall, dl in ph:
        s = sum(ms for ms, _ in dl.values()) / 1000
        print(f"{name:<22}{wall:7.2f}" + "".join(f"{dl[c][0] / 1000:7.2f}/{dl[c][1]:<4d}" for c in cats) + f"{wall - s:9.2f}")
        for c in cats:
            tot[c] += dl[c][0] / 1000
        wt += wall
    print(f"{'total':<22}{wt:7.2f}" + "".join(f"{tot[c]:12.2f}" for c in cats) + f"{wt - sum(tot.values()):9.2f}")
