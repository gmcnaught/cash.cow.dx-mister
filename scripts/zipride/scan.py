#!/usr/bin/env python3
"""Per-window frame cost for a zipride capture (scan_probe.gd W/E lines + frames.bin).

usage: scan.py <capture dir> [<capture dir> ...]
Prints, per window: mean physics / process / draw / present / CPU (us), frames
over 17.5 ms and frames that ran 2+ physics steps. With several dirs, one
column group per dir (A/B).
"""
import pathlib, statistics as st, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "stutter"))
import frames as fr  # noqa: E402


def windows(d):
    w, out = {}, []
    for line in (d / "zip.txt").read_text().splitlines():
        p = line.split()
        if p[0] == "W":
            w[p[1]] = int(p[2])
        elif p[0] == "E":
            out.append((p[1], w.pop(p[1]), int(p[2])))
    return out


def stats(d):
    if not (d / "engine.md5").exists():
        (d / "engine.md5").write_text("x\n")
    f = fr.load_frames(d)
    res = {}
    for label, a, b in windows(d):
        L = f[a:b]
        res[label] = dict(
            physics=st.mean(x["physics"] for x in L), process=st.mean(x["process"] for x in L),
            draw=st.mean(x["draw"] for x in L), present=st.mean(x["present"] for x in L),
            cpu=st.mean(x["cpu"] for x in L), over=sum(1 for x in L if x["cpu"] > 17500),
            multi=sum(1 for x in L if x["steps"] >= 2))
    return res


dirs = [pathlib.Path(a) for a in sys.argv[1:]]
all_ = [stats(d) for d in dirs]
print("%-28s" % "window" + "".join("| %7s %7s %7s %7s %4s %4s " % ("phys", "draw", "present", "cpu", ">17", "2st") for _ in dirs))
for label in all_[0]:
    row = "%-28s" % label
    for r in all_:
        s = r.get(label)
        row += ("| %7.0f %7.0f %7.0f %7.0f %4d %4d " % (s["physics"], s["draw"], s["present"], s["cpu"], s["over"], s["multi"])) if s else "| -"
    print(row)
