#!/usr/bin/env python3
# Device: boot sampler for boot_time.sh. Every 50 ms (CLOCK_MONOTONIC, the same
# clock as the engine's MISTER_BOOTLOG and MISTER_FRAMELOG): CORENAME, launcher
# and engine pids, SD sectors read, per-CPU busy/iowait jiffies, engine
# per-thread CPU ticks. boot_poll.py <seconds> <out file>
import os, sys, time

secs, out = float(sys.argv[1]), sys.argv[2]
HZ = os.sysconf("SC_CLK_TCK")


def rd(p):
    try:
        with open(p) as f:
            return f.read()
    except OSError:
        return ""


def pid_of(comm, cmd_sub=None):
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        if rd(f"/proc/{d}/comm").strip() != comm:
            continue
        if cmd_sub and cmd_sub not in rd(f"/proc/{d}/cmdline"):
            continue
        return d
    return None


def sd_sectors():
    for ln in rd("/proc/diskstats").splitlines():
        f = ln.split()
        if len(f) > 5 and f[2] == "mmcblk0":
            return int(f[5])
    return 0


def cpus():
    r = []
    for ln in rd("/proc/stat").splitlines():
        if ln.startswith("cpu0 ") or ln.startswith("cpu1 "):
            v = list(map(int, ln.split()[1:]))
            r.append((v[0] + v[1] + v[2] + v[5] + v[6], v[4]))  # busy (user nice sys irq softirq), iowait
    return r


t_end = time.monotonic() + secs
with open(out, "w") as o:
    o.write(f"HZ {HZ}\n")
    eng = None
    lpid = None
    while time.monotonic() < t_end:
        t = time.monotonic()
        core = rd("/tmp/CORENAME").strip()
        if lpid is None or not os.path.exists(f"/proc/{lpid}"):
            lpid = pid_of("launch.sh")
        if eng is None or not os.path.exists(f"/proc/{eng}"):
            eng = pid_of("cashcowdx")
        c = cpus()
        thr = []
        rss = ""
        if eng:
            st = rd(f"/proc/{eng}/status")
            rss = ",".join(ln.split()[1] for ln in st.splitlines() if ln.startswith(("VmRSS", "VmHWM")))
            try:
                for tid in os.listdir(f"/proc/{eng}/task"):
                    s = rd(f"/proc/{eng}/task/{tid}/stat")
                    if s:
                        name = s[s.index("(") + 1:s.rindex(")")].replace(" ", "_")
                        f = s[s.rindex(")") + 2:].split()
                        thr.append(f"{tid}:{name}:{int(f[11]) + int(f[12])}:{f[36]}")
            except OSError:
                pass
        o.write(f"{t:.4f} core={core} launch={lpid} eng={eng} sd={sd_sectors()} "
                f"c0={c[0][0]},{c[0][1]} c1={c[1][0]},{c[1][1]} rss={rss or '-'} thr={' '.join(thr)}\n")
        time.sleep(max(0.0, 0.05 - (time.monotonic() - t)))
