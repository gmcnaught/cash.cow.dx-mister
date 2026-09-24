#!/usr/bin/env python3
"""Boot timeline from a boot_time.sh capture.
  boot_report.py <capture dir> [more dirs: a summary row each]
Times are seconds after T0 (the load_core command), CLOCK_MONOTONIC."""
import collections, gzip, pathlib, re, struct, sys

REC = struct.Struct("<Q9I6H2I")
FIELDS = "t0 gap physics process draw present pace tail delay cpu steps nvcsw nivcsw minflt majflt cpu_id nodes scan".split()


def load(d):
    d = pathlib.Path(d)
    T0 = float((d / "t0.txt").read_text().split()[1])
    poll = []
    hz = 100
    for ln in (d / "poll.txt").read_text().splitlines():
        if ln.startswith("HZ"):
            hz = int(ln.split()[1]); continue
        f = ln.split(" thr=")
        head = f[0].split()
        r = {"t": float(head[0]) - T0}
        for kv in head[1:]:
            k, v = kv.split("=", 1)
            r[k] = v
        r["thr"] = {}
        for tok in (f[1].split() if len(f) > 1 else []):
            tid, name, ticks, cpu = tok.split(":")
            r["thr"][tid] = (name, int(ticks), int(cpu))
        poll.append(r)
    boot = []
    if (d / "bootlog.txt").exists():
        for ln in (d / "bootlog.txt").read_text().splitlines():
            t, rest = ln.split(" ", 1)
            boot.append((float(t) - T0, rest))
    frames = []
    if (d / "frames.bin").exists():
        raw = (d / "frames.bin").read_bytes()
        frames = [dict(zip(FIELDS, REC.unpack_from(raw, i * REC.size))) for i in range(len(raw) // REC.size)]
    state = (d / "state.txt").read_text().splitlines() if (d / "state.txt").exists() else []
    return d, T0, hz, poll, boot, frames, state


def first(poll, pred):
    for r in poll:
        if pred(r):
            return r["t"]
    return None


def milestones(d, T0, hz, poll, boot, frames, state):
    m = collections.OrderedDict()
    m["core CashCowDX"] = first(poll, lambda r: r["core"] == "CashCowDX")
    m["launch.sh running"] = first(poll, lambda r: r["launch"] != "None")
    m["engine exec"] = first(poll, lambda r: r["eng"] != "None")
    for t, s in boot:
        if s.startswith(("begin Startup:", "end Startup:")):
            m[s.replace("Startup:", "")] = t
    if frames:
        m["first iteration"] = frames[0]["t0"] / 1e6 - T0
        fp = next((f for f in frames if f["present"] > 0), None)
        if fp:
            m["first fabric present"] = fp["t0"] / 1e6 - T0
    for ln in state:
        mm = re.match(r"STATE f=(\d+)", ln)
        if mm and frames and int(mm.group(1)) < len(frames):
            m["first STATE (GameManager live)"] = frames[int(mm.group(1))]["t0"] / 1e6 - T0
            break
    for ln in state:
        mm = re.match(r"SCENE f=(\d+) attract_panel", ln)
        if mm and frames and int(mm.group(1)) < len(frames):
            m["attract_panel instantiated"] = frames[int(mm.group(1))]["t0"] / 1e6 - T0
            break
    pcm = [t for t, s in boot if s.startswith("pcm ")]
    if pcm:
        m[f"PCM cache: {len(pcm)} clips done"] = pcm[-1]
    return m


def at(poll, t, key):
    best = None
    for r in poll:
        if r["t"] <= t:
            best = r
    return best


def report(args):
    d, T0, hz, poll, boot, frames, state = args
    print(f"== {d.name}  ({(d / 'info.txt').read_text().strip() if (d / 'info.txt').exists() else ''})")
    ms = milestones(*args)
    pts = sorted((v, k) for k, v in ms.items() if v is not None)
    prev_t, prev_r = 0.0, poll[0]
    print(f"{'t (s)':>7} {'+dt':>6} {'SD MB':>6} {'cpu0 %':>6} {'cpu1 %':>6} {'iow %':>5}  milestone")
    for t, k in pts:
        r = at(poll, t, None) or poll[0]
        dt = t - prev_t
        sd = (int(r["sd"]) - int(prev_r["sd"])) * 512 / 1e6
        c = []
        for key in ("c0", "c1"):
            b1, w1 = map(int, r[key].split(",")); b0, w0 = map(int, prev_r[key].split(","))
            span = max(r["t"] - prev_r["t"], 1e-9) * hz
            c.append(((b1 - b0) / span * 100, (w1 - w0) / span * 100))
        print(f"{t:7.2f} {dt:6.2f} {sd:6.1f} {c[0][0]:6.0f} {c[1][0]:6.0f} {c[0][1] + c[1][1]:5.0f}  {k}")
        prev_t, prev_r = t, r
    # engine threads: CPU seconds by the end of the capture
    last = poll[-1]["thr"]
    agg = collections.Counter()
    for name, ticks, _ in last.values():
        agg[name] += ticks / hz
    if agg:
        print("engine thread CPU s (whole capture):", ", ".join(f"{k} {v:.1f}" for k, v in agg.most_common(6)))
    hwm = [int(r["rss"].split(",")[0]) for r in poll if r.get("rss", "-") not in ("-", "")]
    if hwm:
        print(f"engine VmHWM at end of capture: {hwm[-1] / 1024:.0f} MB")
    loads = [(float(s.split()[2]), int(s.split()[1]), s.split(None, 3)[3], t) for t, s in boot if s.startswith("load ")]
    if loads:
        top = sorted((l for l in loads if l[1] == 0), reverse=True)[:12]
        print(f"top-level resource loads: {sum(1 for l in loads if l[1] == 0)}, {sum(l[0] for l in loads if l[1] == 0) / 1000:.2f} s total; largest:")
        for ms_, _, p, t in top:
            print(f"  {ms_:8.1f} ms  @{t:6.2f}  {p}")
        byext = collections.Counter()
        for ms_, dep, p, _ in loads:
            byext[p.rsplit(".", 1)[-1]] += 1
        print("  loads by extension (all depths):", dict(byext.most_common(8)))
    if (d / "perf.txt.gz").exists():
        prof(d, T0, ms)
    print()
    return ms


def prof(d, T0, ms):
    """perf samples (both CPUs) split into boot phases, top dso/symbols per phase."""
    edges = sorted((v, k) for k, v in ms.items() if v is not None)
    buckets = collections.defaultdict(collections.Counter)
    for ln in gzip.open(d / "perf.txt.gz", "rt", errors="replace"):
        m = re.match(r"\s*(\S+)\s+(\d+)\s+\[(\d+)\]\s+([\d.]+):\s+(\S+)\s+(.*?)\s+\((.*)\)\s*$", ln)
        if not m:
            continue
        comm, tid, cpu, ts, ip, sym, dso = m.groups()
        t = float(ts) - T0
        ph = "before T0"
        for et, ek in edges:
            if t >= et:
                ph = ek
        buckets[ph][(comm, pathlib.Path(dso).name, sym.split("+")[0])] += 1
    print("perf (500 Hz, both CPUs) by phase, from milestone:")
    for et, ek in edges:
        c = buckets.get(ek)
        if not c:
            continue
        n = sum(c.values())
        print(f"  [{ek}] {n} samples")
        for (comm, dso, sym), k in c.most_common(8):
            print(f"      {k / n * 100:5.1f}%  {comm:<14} {dso:<22} {sym[:60]}")


if __name__ == "__main__":
    for a in sys.argv[1:]:
        report(load(a))
