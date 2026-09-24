#!/usr/bin/env python3
"""Analyse a stutter capture (scripts/stutter/run.sh output directory).

  frames.py <capture dir> [--csv slow.csv]

Active gameplay = GameManager.game_state in LEVEL_ACTIVE, LEVEL_SHAKE,
BONUS_LEVEL, BOSS_FIGHT (enum in GameManager.gd). FPS = frames presented per
1-second window, windows tiled from the start of each active segment (partial
last window dropped); also the worst sliding 1-second window.

Each long frame (work > one 60 Hz period) is attributed from its own record
(main-thread CPU per phase, context switches, faults) and from the CPU0 perf
trace (who else ran on CPU0 / which IRQs during the frame).
"""
import bisect, collections, re, struct, sys, pathlib

REC = struct.Struct("<Q9I6H2I")  # MisterFrameRecord, 64 bytes
FIELDS = ("t0 gap physics process draw present pace tail delay cpu steps nvcsw nivcsw minflt majflt cpu_id nodes scan").split()
REC_V1 = struct.Struct("<Q8I6HI")  # before the pace field (capture base1)
FIELDS_V1 = [f for f in FIELDS if f not in ("pace", "scan")]
ACTIVE = {2: "LEVEL_ACTIVE", 4: "LEVEL_SHAKE", 7: "BONUS_LEVEL", 9: "BOSS_FIGHT"}
GS = "GAME_OVER LEVEL_INTRO LEVEL_ACTIVE LEVEL_PAUSE LEVEL_SHAKE LEVEL_END BONUS_LEVEL_INTRO BONUS_LEVEL BONUS_LEVEL_END BOSS_FIGHT".split()
PERIOD = 1e6 / 60
# short-lived processes forked by shell scripts, grouped under one name
LAUNCHER = {c: "shell-forks" for c in ("launch.sh", "cat", "sleep", "tr", "grep", "awk", "pidof", "busybox", "ps", "bash", "sh", "date")}


def load_frames(d):
    raw = (d / "frames.bin").read_bytes()
    rec, fields = (REC, FIELDS) if (d / "engine.md5").exists() and "e60fb93f" not in (d / "engine.md5").read_text() else (REC_V1, FIELDS_V1)
    out = [dict(zip(fields, rec.unpack_from(raw, i * rec.size))) for i in range(len(raw) // rec.size)]
    for f in out:
        f.setdefault("pace", 0)
        f.setdefault("scan", 0)
    return out


def load_state(d, n):
    gs = [None] * n
    scenes = collections.defaultdict(list)
    cur, last = None, 0
    ev = []
    for line in (d / "state.txt").read_text().splitlines():
        m = re.match(r"STATE f=(\d+) gs=(\d+) ps=(\d+)", line)
        if m:
            ev.append((int(m[1]), int(m[2])))
        m = re.match(r"SCENE f=(\d+) (\S+)", line)
        if m:
            scenes[int(m[1])].append(m[2])
    j = 0
    for i in range(n):
        while j < len(ev) and ev[j][0] <= i:
            cur = ev[j][1]
            j += 1
        gs[i] = cur
    return gs, scenes


def load_cpu0(d, main_tid):
    """Returns (task intervals [(start,end,comm,tid)], irq intervals [(start,end,name)])."""
    import gzip
    p = d / "cpu0.txt"
    if not p.exists() and (d / "cpu0.txt.gz").exists():
        p.write_bytes(gzip.decompress((d / "cpu0.txt.gz").read_bytes()))
    if not p.exists():
        return [], []
    tasks, irqs = [], []
    cur, cur_t = None, None
    open_irq = {}
    rx = re.compile(r"^\s*(.+?)\s+(\d+)\s+\[(\d+)\]\s+([\d.]+):\s+(\S+):\s+(.*)$")
    for line in p.read_text(errors="replace").splitlines():
        m = rx.match(line)
        if not m:
            continue
        t = float(m[4]) * 1e6
        ev, tr = m[5], m[6]
        if ev == "sched:sched_switch":
            nm = re.search(r"next_comm=(.+?) next_pid=(\d+)", tr)
            pm = re.search(r"prev_comm=(.+?) prev_pid=(\d+)", tr)
            if cur is not None:
                tasks.append((cur_t, t, f"{cur[0]}:{cur[1]}"))
            elif pm:
                tasks.append((t, t, f"{pm[1]}:{pm[2]}"))
            cur, cur_t = (nm[1], int(nm[2])), t
        elif ev == "irq:irq_handler_entry":
            m2 = re.search(r"irq=(\d+) name=(\S+)", tr)
            open_irq["h"] = (t, f"irq{m2[1]}:{m2[2]}")
        elif ev == "irq:irq_handler_exit":
            if "h" in open_irq:
                s, n = open_irq.pop("h")
                irqs.append((s, t, n))
        elif ev == "irq:softirq_entry":
            m2 = re.search(r"action=(\S+)", tr)
            open_irq["s"] = (t, "softirq:" + m2[1])
        elif ev == "irq:softirq_exit":
            if "s" in open_irq:
                s, n = open_irq.pop("s")
                irqs.append((s, t, n))
    return tasks, irqs


def overlap(ivs, starts, a, b):
    """Sum of overlap per key within [a,b) for sorted intervals (start,end,key...)."""
    out = collections.Counter()
    i = max(0, bisect.bisect_left(starts, a) - 1)
    while i < len(ivs) and ivs[i][0] < b:
        s, e = ivs[i][0], ivs[i][1]
        o = min(e, b) - max(s, a)
        if o > 0:
            out[ivs[i][2]] += o
        i += 1
    return out


def main():
    d = pathlib.Path(sys.argv[1])
    csv = sys.argv[sys.argv.index("--csv") + 1] if "--csv" in sys.argv else None
    fr = load_frames(d)
    n = len(fr)
    gs, scenes = load_state(d, n)
    info = (d / "info.txt").read_text() if (d / "info.txt").exists() else ""
    m = re.search(r"engine pid (\d+)", info)
    main_tid = int(m[1]) if m else -1
    tasks, irqs = load_cpu0(d, main_tid)
    t_starts = [x[0] for x in tasks]
    i_starts = [x[0] for x in irqs]
    trace_span = (tasks[0][0], tasks[-1][1]) if tasks else (0, 0)

    for f in fr:
        f["work"] = f["gap"] + f["physics"] + f["process"] + f["draw"] + f["tail"]
        f["tpres"] = f["t0"] + f["physics"] + f["process"] + f["draw"]
    # active segments (contiguous frame ranges)
    segs, s = [], None
    for i in range(n):
        a = gs[i] in ACTIVE
        if a and s is None:
            s = i
        if not a and s is not None:
            segs.append((s, i)); s = None
    if s is not None:
        segs.append((s, n))

    print(f"capture {d.name}: {n} frames, {(fr[-1]['t0'] - fr[0]['t0']) / 1e6:.0f} s; "
          f"cpu0 trace {'%.0f s' % ((trace_span[1] - trace_span[0]) / 1e6) if tasks else 'none'}; main tid {main_tid}")
    cpus = collections.Counter(f["cpu_id"] for f in fr)
    print("main thread ended frames on CPU:", dict(cpus))

    # --- FPS windows ---
    wins = []  # (t_start, count, seg)
    slide_min = []
    for a, b in segs:
        tp = [fr[i]["tpres"] for i in range(a, b)]
        if len(tp) < 2 or tp[-1] - tp[0] < 1e6:
            continue
        t = tp[0]
        while t + 1e6 <= tp[-1]:
            c = bisect.bisect_left(tp, t + 1e6) - bisect.bisect_left(tp, t)
            wins.append((t, c, (a, b)))
            t += 1e6
        for j in range(len(tp)):
            if tp[j] - 1e6 >= tp[0]:
                c = j - bisect.bisect_right(tp, tp[j] - 1e6) + 1
                slide_min.append((c, tp[j]))
    act_s = sum((fr[b - 1]["tpres"] - fr[a]["tpres"]) for a, b in segs) / 1e6
    hist = collections.Counter(c for _, c, _ in wins)
    print(f"\nactive gameplay: {len(segs)} segments, {act_s:.0f} s, {len(wins)} full 1-s windows")
    print("fps per window:", dict(sorted(hist.items())))
    lo58 = sum(1 for _, c, _ in wins if c < 58)
    eq58 = sum(1 for _, c, _ in wins if c == 58)
    le58 = lo58 + eq58
    print(f"windows <58: {lo58}   ==58: {eq58}   rate of <=58: {le58 / max(act_s, 1) * 30:.2f} per 30 s   "
          f"PASS={'yes' if lo58 == 0 and le58 / max(act_s, 1) * 30 <= 1 else 'no'}")
    if slide_min:
        c, t = min(slide_min)
        print(f"worst sliding 1-s window: {c} frames (ending t={t / 1e6:.2f})")
        sh = collections.Counter(c for c, _ in slide_min)
        print("sliding-window frame counts (share of frames):", {k: f"{v / len(slide_min) * 100:.1f}%" for k, v in sorted(sh.items()) if k < 60})

    # --- displayed frames per 60 scanout boundaries (needs the scan field) ---
    dwins, dnear = [], []
    for a, b in segs:
        sc = [fr[i]["scan"] for i in range(a, b)]
        if not sc or sc[0] == 0:
            continue
        shown = set()
        for k in range(len(sc) - 1):
            if (sc[k + 1] - sc[k]) & 0xFFFFFFFF > 0 and (sc[k + 1] - sc[k]) & 0xFFFFFFFF < 1 << 31:
                shown.add(sc[k] + 1)  # snapshotted at the first boundary after its publish
        b0, b1 = sc[0] + 1, sc[-1]
        death = b < n and gs[b] == 3  # the segment ends in a player death (PLAYER_HURT -> LEVEL_PAUSE)
        for w0 in range(b0, b1 - 59, 60):
            dwins.append(sum(1 for x in range(w0, w0 + 60) if x in shown))
            dnear.append(death and b1 - (w0 + 60) < 180)
    if dwins:
        near = sum(1 for c, nd in zip(dwins, dnear) if c <= 58 and nd)
        print(f"  displayed windows <= 58 within 3 s before a death (LEVEL_PAUSE): {near} of {sum(1 for c in dwins if c <= 58)}; "
              f"share of all windows that close to a death: {sum(dnear) / len(dwins) * 100:.0f}%")
        dh = collections.Counter(dwins)
        dlo = sum(1 for c in dwins if c < 58)
        dle = sum(1 for c in dwins if c <= 58)
        dsec = len(dwins) * 60 / 59.9228
        print(f"DISPLAYED new frames per 60 scanout frames: {dict(sorted(dh.items()))}  <58: {dlo}  <=58: {dle} "
              f"({dle / max(dsec, 1) * 30:.2f} per 30 s)  repeated scanout frames: {sum(60 - c for c in dwins)} of {len(dwins) * 60}  "
              f"PASS={'yes' if dlo == 0 and dle / max(dsec, 1) * 30 <= 1 else 'no'}")

    act = [i for a, b in segs for i in range(a, b)]
    per = [fr[i + 1]["t0"] - fr[i]["t0"] for i in act if i + 1 < n]
    print(f"\nactive frame periods: n={len(per)}  >17.5ms {sum(p > 17500 for p in per)}  >20 {sum(p > 20000 for p in per)}  "
          f">25 {sum(p > 25000 for p in per)}  >33.4 {sum(p > 33400 for p in per)}  max {max(per) / 1000:.1f} ms")
    works = sorted(fr[i]["work"] for i in act)
    q = lambda p: works[min(len(works) - 1, int(p * len(works)))] / 1000
    print(f"active work (gap+phys+proc+draw+tail) ms: p50 {q(.5):.2f} p90 {q(.9):.2f} p99 {q(.99):.2f} p99.9 {q(.999):.2f} max {works[-1] / 1000:.2f}")
    avg = lambda k: sum(fr[i][k] for i in act) / len(act) / 1000
    print("active means ms: " + " ".join(f"{k}={avg(k):.2f}" for k in ("gap", "physics", "process", "draw", "present", "tail", "delay", "cpu"))
          + f" steps={sum(fr[i]['steps'] for i in act) / len(act):.2f}")

    # --- long frames: attribution ---
    long_ = [i for i in act if fr[i]["work"] > PERIOD]
    cat = collections.Counter()
    ext = collections.Counter()
    rows = []
    for i in long_:
        f = fr[i]
        a, b = f["t0"] - f["gap"], f["t0"] + f["physics"] + f["process"] + f["draw"] + f["tail"]
        on = overlap(tasks, t_starts, a, b) if tasks else {}
        others = {k: v for k, v in on.items() if k != f"cashcowdx:{main_tid}" and not k.endswith(":0")}
        irq = overlap(irqs, i_starts, a, b) if irqs else {}
        offcpu = max(0, (b - a) - f["gap"] - f["cpu"])  # cpu excludes gap, delay is ~0 cpu
        idle = sum(v for k, v in on.items() if k.endswith(":0"))
        excess = f["work"] - PERIOD
        # dominant cause
        phases = {"physics": f["physics"], "process": f["process"], "draw": f["draw"], "tail": f["tail"], "gap": f["gap"]}
        byc = collections.Counter()
        for k, v in others.items():
            c = k.rsplit(":", 1)[0]
            byc[LAUNCHER.get(c, c.split("/")[0] if c.startswith("kworker") else c)] += v
        others = byc
        if f["cpu"] >= PERIOD:
            cause = "cpu:" + max(phases, key=phases.get)
        elif f["present"] >= 0.5 * excess:
            cause = "present(fabric wait/pace)"
        elif sum(others.values()) >= max(0.5 * excess, 1000):
            cause = "preempted:" + max(others, key=others.get)
        elif sum(irq.values()) >= max(0.5 * excess, 2000):
            cause = "irq:" + max(irq, key=irq.get)
        elif offcpu > 0.5 * excess and (tasks or f["nivcsw"] <= 2):
            # off CPU and nobody else ran on CPU0 (idle): the main thread waited
            cause = "blocked(%s)" % ("majflt" if f["majflt"] else "sleep/lock")
        elif offcpu > 0.5 * excess:
            cause = "offcpu(no trace; nivcsw=%d)" % f["nivcsw"]
        else:
            cause = "cpu:" + max(phases, key=phases.get)
        cat[cause] += 1
        for k, v in others.items():
            ext[k] += v
        for k, v in irq.items():
            ext[k] += v
        rows.append((i, f, cause, others, irq, offcpu, idle))
    print(f"\nlong frames (work > 16.67 ms) in active play: {len(long_)} ({len(long_) / max(act_s, 1):.2f}/s)")
    for k, v in cat.most_common():
        print(f"  {v:5d}  {k}")
    if ext:
        print("CPU0 time taken by others during long frames (ms):", ", ".join(f"{k} {v / 1000:.1f}" for k, v in ext.most_common(10)))

    # windows <= 58: what happened
    bad = [w for w in wins if w[1] <= 58]
    print(f"\nwindows <= 58 fps: {len(bad)}")
    for t, c, _ in bad[:40]:
        idx = [i for i in act if t <= fr[i]["tpres"] < t + 1e6]
        worst = sorted(idx, key=lambda i: -fr[i]["work"])[:3]
        desc = []
        for i in worst:
            r = next((r for r in rows if r[0] == i), None)
            f = fr[i]
            desc.append(f"f{i} {f['work'] / 1000:.1f}ms[ph{f['physics'] / 1000:.1f}/{f['steps']} pr{f['process'] / 1000:.1f} dr{f['draw'] / 1000:.1f} "
                        f"g{f['gap'] / 1000:.1f} cpu{f['cpu'] / 1000:.1f} iv{f['nivcsw']} v{f['nvcsw']} mf{f['majflt']}] {r[2] if r else ''}"
                        + (f" scenes={scenes[i]}" if scenes.get(i) else ""))
        print(f"  t={t / 1e6:.1f} fps={c} {GS[gs[idx[0]]] if idx else ''}: " + "; ".join(desc))

    if csv:
        with open(csv, "w") as o:
            o.write("frame,t0,state,work,gap,physics,steps,process,draw,present,tail,cpu,nvcsw,nivcsw,minflt,majflt,nodes,cause,others,irq,scenes\n")
            for i, f, cause, others, irq, offcpu, idle in rows:
                o.write(f"{i},{f['t0'] / 1e6:.4f},{GS[gs[i]]},{f['work']},{f['gap']},{f['physics']},{f['steps']},{f['process']},{f['draw']},"
                        f"{f['present']},{f['tail']},{f['cpu']},{f['nvcsw']},{f['nivcsw']},{f['minflt']},{f['majflt']},{f['nodes']},{cause},"
                        f"\"{dict((k, round(v)) for k, v in others.items())}\",\"{dict((k, round(v)) for k, v in irq.items())}\",\"{' '.join(scenes.get(i, []))}\"\n")
        print("wrote", csv)


if __name__ == "__main__" and "--prof" not in sys.argv:
    main()


def prof_main(d, fr, gs):
    """--prof: main-thread samples (prof.txt.gz) split by frame class and phase."""
    import gzip
    p = d / "prof.txt.gz"
    if not p.exists():
        print("no prof.txt.gz")
        return
    t0s = [f["t0"] for f in fr]
    cls_sym = collections.defaultdict(collections.Counter)
    cls_frames = collections.defaultdict(set)
    for line in gzip.decompress(p.read_bytes()).decode(errors="replace").splitlines():
        m = re.match(r"\s*([\d.]+):\s+([0-9a-f]+)\s*(.*)$", line)
        if not m:
            continue
        t = float(m[1]) * 1e6
        sym = re.sub(r"\+0x[0-9a-f]+$", "", m[3].strip()) or "?"
        i = bisect.bisect_right(t0s, t) - 1
        if i < 0 or gs[i] not in ACTIVE:
            continue
        f = fr[i]
        off = t - f["t0"]
        ph = ("physics" if off < f["physics"] else "process" if off < f["physics"] + f["process"]
              else "draw" if off < f["physics"] + f["process"] + f["draw"] else "other")
        cls = "long" if f["cpu"] >= PERIOD else "normal"
        cls_sym[(cls, ph)][sym] += 1
        cls_frames[cls].add(i)
    for cls in ("long", "normal"):
        nf = max(1, len(cls_frames[cls]))
        print(f"\n== {cls} frames: {len(cls_frames[cls])} (1 sample = 1 ms; per-frame ms)")
        for ph in ("physics", "process", "draw", "other"):
            c = cls_sym[(cls, ph)]
            tot = sum(c.values())
            if not tot:
                continue
            print(f"  {ph}: {tot / nf:.2f} ms/frame; top: " + ", ".join(f"{s} {v / nf:.2f}" for s, v in c.most_common(12)))


if __name__ == "__main__" and "--prof" in sys.argv:
    _d = pathlib.Path(sys.argv[1])
    _fr = load_frames(_d)
    _gs, _ = load_state(_d, len(_fr))
    prof_main(_d, _fr, _gs)
