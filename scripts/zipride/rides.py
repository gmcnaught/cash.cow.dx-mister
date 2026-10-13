#!/usr/bin/env python3
"""Per-ride display summary for zip_probe.gd captures (zip.txt + frames.bin).

usage: rides.py <capture dir> [...]
Window: the ride's first frame to 60 frames after the eject. scanout = core
scanout periods elapsed, presented = frames published; repeats = scanout -
presented (scanout frames that showed an old frame).
"""
import pathlib, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "stutter"))
import frames as fr  # noqa: E402

for arg in sys.argv[1:]:
    d = pathlib.Path(arg)
    if not (d / "engine.md5").exists():
        (d / "engine.md5").write_text("x\n")
    F = fr.load_frames(d)
    rides = {}
    for line in (d / "zip.txt").read_text().splitlines():
        p = line.split()
        if p[0] != "F":
            continue
        pf = int(next(x for x in p if x.startswith("pf="))[3:])
        rides.setdefault(int(p[1]), []).append((pf, int(p[5]), p[7] if ":" in p[7] else ""))
    print(d.name)
    for r, L in rides.items():
        a = L[0][0]
        off = [pf for pf, on, _ in L if on == 0]
        b = off[0] + 60 if off else L[-1][0]
        W = F[a:b]
        cpu = [f["cpu"] for f in W]
        scans = W[-1]["scan"] - W[0]["scan"]
        inst = sum(1 for pf, _, i in L if a <= pf < b and i)
        print(f"  ride {r}: scanout {scans} presented {len(W) - 1} repeats {scans - len(W) + 1} "
              f"cpu>16.7ms {sum(c > 16700 for c in cpu)} max_cpu {max(cpu)} frames_with_inst {inst}")
