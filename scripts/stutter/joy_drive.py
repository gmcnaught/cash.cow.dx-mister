#!/usr/bin/env python3
"""State-aware scripted input for stutter captures (runs on the device).

  joy_drive.py <seconds> [engine log]

Like joy_inject.py's `play` (seeded random running/jumping), but it follows the
game's state from the STATE lines state_probe.gd prints to the engine log:
  - active play (LEVEL_ACTIVE, LEVEL_SHAKE, BONUS_LEVEL, BOSS_FIGHT): random play
  - GAME_OVER for 2 s (game over screen, high-score initials, title, mode
    select, attract demo): OK x5, then start + OK x4, repeated until play resumes
  - anything else (intro, hurt pause, level end): no input
so a run spends its time in play instead of idling on the title screen after the
last life is lost. Needs the engine started with MISTER_JOY_BASE=0x3A0C0000.
"""
import mmap, os, random, re, struct, sys, time

BITS = dict(right=0, left=1, down=2, up=3, a=4, b=5, x=6, y=7, start=8, select=9, l=10, r=11)
ACTIVE = {2, 4, 7, 9}
GAME_OVER = 0
secs = float(sys.argv[1])
log = sys.argv[2] if len(sys.argv) > 2 else "/media/fat/logs/CashCowDX/cashcowdx.log"
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=int(os.environ.get("JOY_BASE", "0x3A0C0000"), 0))
rng = random.Random(1)
rx = re.compile(rb"STATE f=\d+ gs=(\d+)")


def put(word):
    struct.pack_into("<I", m, 0x08, word)


def tap(b, hold=0.1, gap=0.2):
    put(1 << BITS[b]); time.sleep(hold); put(0); time.sleep(gap)


pos, gs = 0, None


def state():
    """Latest game state from the log (reads only what was appended)."""
    global pos, gs
    try:
        with open(log, "rb") as f:
            f.seek(0, 2)
            end = f.tell()
            if end < pos:
                pos = 0  # log rotated
            f.seek(pos)
            data = f.read(end - pos)
            pos = end
        for g in rx.findall(data):
            gs = int(g)
    except OSError:
        pass
    return gs


put(0)
t_end = time.monotonic() + secs
over_since = None
last_start = 0.0
n_starts = 0
while time.monotonic() < t_end:
    s = state()
    if s in ACTIVE:
        over_since = None
        last_start = 0.0
        d = rng.choice([BITS["right"], BITS["left"], BITS["right"]])
        w = 1 << d
        if rng.random() < 0.5:
            w |= 1 << BITS["a"]
        put(w); time.sleep(rng.uniform(0.2, 0.8))
        put(1 << d); time.sleep(rng.uniform(0.1, 0.4))
        put(0)
    elif s == GAME_OVER or s is None:
        put(0)
        over_since = over_since or time.monotonic()
        if time.monotonic() - over_since >= 2.0:
            # Game-over / high-score initials screens: OK x5 (1 s apart). Then the
            # sequence that starts a game from the title (as the first launch):
            # start, OK x4 (3 s apart). Checked again after the level has loaded.
            if last_start == 0.0:
                n_starts += 1
                last_start = time.monotonic()
            print(f"{time.monotonic():.2f} menu sequence (game #{n_starts})", flush=True)
            # Stop as soon as the state leaves GAME_OVER: start would pause a game.
            seq = [("a", 0.9)] * 5 + [("start", 3.0)] + [("a", 3.0)] * 4
            for b, gap in seq:
                if state() not in (GAME_OVER, None):
                    break
                tap(b, 0.1, gap)
            else:
                time.sleep(6)
            over_since = time.monotonic() - 2.0  # re-check at once next loop
        else:
            time.sleep(0.2)
    else:
        over_since = None
        put(0)
        time.sleep(0.2)
put(0)
print(f"{time.monotonic():.2f} done, {n_starts} new games", flush=True)
