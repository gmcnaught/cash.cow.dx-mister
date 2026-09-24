#!/usr/bin/env python3
"""Exclusive (self) time per resource type from a MISTER_BOOTLOG: each `load d ms path`
line is written when the load ends, so a load's direct children are the depth d+1
lines logged since the previous line at depth <= d. load_self.py <bootlog.txt>"""
import collections, sys

rows = []
for ln in open(sys.argv[1]):
    f = ln.split(None, 4)
    if len(f) == 5 and f[1] == "load":
        rows.append((int(f[2]), float(f[3]), f[4].strip()))
pending = collections.defaultdict(float)  # depth -> sum of finished children's inclusive ms
by = collections.Counter(); cnt = collections.Counter(); top = []
for d, ms, p in rows:
    self_ms = ms - pending.pop(d + 1, 0.0)
    pending[d] += ms
    ext = p.rsplit(".", 1)[-1]
    by[ext] += self_ms; cnt[ext] += 1
    top.append((self_ms, p))
tot = sum(by.values())
print(f"self time, all loads: {tot / 1000:.2f} s")
for ext, v in by.most_common():
    print(f"  {ext:<14} {cnt[ext]:4d} loads  {v / 1000:6.2f} s  ({v / tot * 100:4.1f}%)")
print("largest self times:")
for ms, p in sorted(top, reverse=True)[:15]:
    print(f"  {ms:7.1f} ms  {p.split('/')[-1]}")
