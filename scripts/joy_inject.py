#!/usr/bin/env python3
"""Drive the engine's MiSTer joypad from a script (runs on the device).

Run the engine with MISTER_JOY=1 MISTER_JOY_BASE=0x3A0C0000 (a DDR page the
Donut Dodo core does not touch), then:

  python3 joy_inject.py 'wait 12; start; wait 3; a; wait 2; a; wait 3; hold right 2; a; ...'

Steps (separated by ';'):
  wait S           sleep S seconds
  <btn>            tap: press 0.1 s, release, 0.2 s gap
  hold <btn> S     press for S seconds
  play S           S seconds of pseudo-random running/jumping (seeded)
Buttons: right left down up a b x y start select l r (word bits 0..11,
the core's J1 order: Jump/OK, Back, Unused, Options, Start, Select, L, R).
"""
import mmap, os, random, struct, sys, time

BITS = dict(right=0, left=1, down=2, up=3, a=4, b=5, x=6, y=7, start=8, select=9, l=10, r=11)
base = int(os.environ.get("JOY_BASE", "0x3A0C0000"), 0)
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=base)


def put(word):
    struct.pack_into("<I", m, 0x08, word)
    print(f"{time.monotonic():.2f} joy=0x{word:03x}", flush=True)


put(0)
rng = random.Random(1)
for step in sys.argv[1].split(";"):
    w = step.split()
    if not w:
        continue
    if w[0] == "wait":
        time.sleep(float(w[1]))
    elif w[0] == "hold":
        put(1 << BITS[w[1]]); time.sleep(float(w[2])); put(0)
    elif w[0] == "play":
        end = time.monotonic() + float(w[1])
        while time.monotonic() < end:
            d = rng.choice([BITS["right"], BITS["left"], BITS["right"]])
            word = 1 << d
            if rng.random() < 0.5:
                word |= 1 << BITS["a"]
            put(word); time.sleep(rng.uniform(0.2, 0.8))
            put(1 << d); time.sleep(rng.uniform(0.1, 0.4))
        put(0)
    else:
        put(1 << BITS[w[0]]); time.sleep(0.1); put(0); time.sleep(0.2)
put(0)
