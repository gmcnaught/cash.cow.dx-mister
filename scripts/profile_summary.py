#!/usr/bin/env python3
"""Summarize godot_dbg_profile.py output per physics tick.

  profile_summary.py profile.jsonl [--from F] [--to F] [--top 30] [--min-ticks N]

Ticks per frame = calls of GameInput._physics_process (one per physics tick).
Prints, per function: calls/tick, self ms/tick, total ms/tick; and the frame
time / script time totals over the selected frames.
"""
import argparse, collections, json

ap = argparse.ArgumentParser()
ap.add_argument('path'); ap.add_argument('--from', dest='f0', type=int, default=0)
ap.add_argument('--to', dest='f1', type=int, default=1 << 30)
ap.add_argument('--top', type=int, default=30); ap.add_argument('--min-ticks', type=int, default=1)
a = ap.parse_args()

calls, selft, tot = collections.Counter(), collections.Counter(), collections.Counter()
ticks = frames = 0; ft = st = pt = 0.0
for line in open(a.path):
    f = json.loads(line)
    if not (a.f0 <= f['frame'] <= a.f1):
        continue
    t = sum(s[1] for s in f['scripts'] if s[0].endswith('GameInput.gd::100::_physics_process'))
    if t < a.min_ticks:
        continue
    ticks += t; frames += 1; ft += f['frame_time']; st += f['script_time']; pt += f['physics_time']
    for name, c, s, T in f['scripts']:
        calls[name] += c; selft[name] += s; tot[name] += T
if not ticks:
    raise SystemExit('no frames with ticks')
print(f'{frames} frames, {ticks} ticks ({ticks/frames:.2f}/frame); per tick: frame {ft*1e3/ticks:.2f} ms, '
      f'physics {pt*1e3/ticks:.2f} ms, script {st*1e3/ticks:.2f} ms')
print(f"{'self ms/tick':>12} {'total':>7} {'calls/tick':>10}  function")
for name, s in selft.most_common(a.top):
    print(f'{s*1e3/ticks:12.3f} {tot[name]*1e3/ticks:7.3f} {calls[name]/ticks:10.1f}  {name}')
