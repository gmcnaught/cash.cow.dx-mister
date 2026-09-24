#!/usr/bin/env python3
"""Engine main-thread samples from a PERF=1 boot capture, split by boot phase
(MISTER_BOOTLOG marks) and grouped by function family. boot_prof.py <capture dir>"""
import collections, gzip, pathlib, re, sys

d = pathlib.Path(sys.argv[1])
T0 = float((d / "t0.txt").read_text().split()[1])
marks = {}
for ln in (d / "bootlog.txt").read_text().splitlines():
    t, s = ln.split(" ", 1)
    marks.setdefault(s, float(t) - T0)
frames_first = None
state = (d / "state.txt").read_text()
PH = [("Setup (servers, scene types)", marks["begin Startup:Main::Setup"], marks["end Startup:Main::Setup2"]),
      ("Load Autoloads", marks["begin Startup:Load Autoloads"], marks["end Startup:Load Autoloads"]),
      ("Load Game (game.scn + patches)", marks["begin Startup:Load Game"], marks["end Startup:Load Game"])]
atr = [float(ln.split()[0]) - T0 for ln in (d / "bootlog.txt").read_text().splitlines() if ln.endswith("attract_panel.scn")]
if atr:
    PH.append(("Main::Start end -> attract_panel", marks["end Startup:Main::Start"], atr[0]))
GROUPS = [
    ("GDScript parse/analyze/compile", r"^GDScript|^GDScriptParser|^GDScriptAnalyzer|^GDScriptCompiler|^GDScriptTokenizer|^GDScriptByteCode|^GDScriptCache|^GDScriptFunction|^GDScriptLanguage"),
    ("String/StringName/CowData", r"^String|^CowData|^StringName|^Vector<String|^_to_lower|^is_ascii|^char32|^CharString|^operator\+"),
    ("Variant/Array/Dictionary", r"^Variant|^Array|^Dictionary|^_VariantCall"),
    ("Object/ClassDB/Node/Scene", r"^Object|^ClassDB|^Node|^SceneState|^PackedScene|^MethodBind|^Control|^CanvasItem|^Callable|^Signal|^Resource"),
    ("Vorbis/Ogg decode", r"vorbis|^ogg|mdct|res\d_|mapping0|floor1|^_decode_pcm|OggVorbis|lrintf"),
    ("WebP / image", r"NEON|^Predictor|DecodeImage|^VP8|WebP|^Image|ReadHuffman|^Emit|^ExtractAlpha|^Transform|^Convert"),
    ("zstd/compression", r"ZSTD|^zstd|^HUF|^FSE|^Compression|inflate"),
    ("basisu init", r"basis"),
    ("malloc/free/memcpy (libc)", r"^malloc|^cfree|^free|^realloc|^calloc|^__libc|^memcpy|^memset|^memmove|^_int_|^strlen|^Memory::"),
    ("HashMap/containers", r"^HashMap|^RBMap|^List<|^Vector<|^LocalVector|^HashSet|^SelfList|^hash_"),
    ("kernel", r"."),  # placeholder, matched by dso below
]
rx = re.compile(r"\s*(.+?)\s+(\d+)\s+\[(\d+)\]\s+([\d.]+):\s+(\S+)\s+(.*?)\s+\((.*)\)\s*$")
per = {p[0]: collections.Counter() for p in PH}
syms = {p[0]: collections.Counter() for p in PH}
main_tid = None
rows = []
for ln in gzip.open(d / "perf.txt.gz", "rt", errors="replace"):
    m = rx.match(ln)
    if m and m.group(1) == "cashcowdx":
        rows.append(m.groups())
tid_n = collections.Counter(r[1] for r in rows)
main_tid = tid_n.most_common(1)[0][0]
for c, tid, cpu, ts, ip, s, dso in rows:
    if tid != main_tid:
        continue
    t = float(ts) - T0
    for name, a, b in PH:
        if a <= t < b:
            s0 = s.split("+")[0]
            g = "other"
            if "kernel" in dso:
                g = "kernel (faults, syscalls, I/O)"
            elif s0 == "[unknown]":
                g = f"unresolved ({pathlib.Path(dso).name})"
            else:
                for gname, pat in GROUPS[:-1]:
                    if re.search(pat, s0):
                        g = gname
                        break
            per[name][g] += 1
            syms[name][s0] += 1
for name, a, b in PH:
    n = sum(per[name].values())
    print(f"[{name}] {b - a:.2f} s, main thread {n / 500:.2f} s CPU ({n / 500 / (b - a) * 100:.0f}%)")
    for g, k in per[name].most_common(9):
        print(f"    {k / n * 100:5.1f}%  {g}")
    print("    top symbols:", ", ".join(f"{s[:40]} {k / n * 100:.1f}%" for s, k in syms[name].most_common(6)))
