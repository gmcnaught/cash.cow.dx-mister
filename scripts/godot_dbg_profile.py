#!/usr/bin/env python3
"""Headless stand-in for the Godot 4.3 editor's remote profiler.

Listens for a game started with `--remote-debug tcp://<host>:<port>`, enables
the servers+scripts profiler ("profiler:servers"), auto-continues script-error
breaks (the expected steam_manager parse error), and writes one JSON line per
"servers:profile_frame" with function signatures resolved.

Wire format (core/debugger/remote_debugger_peer.cpp): uint32 LE length +
encode_variant(Array[msg:String, thread_id:int, data:Array]).

usage: godot_dbg_profile.py OUT.jsonl [--port 6008] [--seconds 150]
"""
import argparse, json, socket, struct, sys, time

F64 = 1 << 16
MAIN_ID = 1  # Thread::MAIN_ID; incoming messages are routed by thread id
# Fixed payload sizes for real_t=float builds (arm32 template).
FIXED = {5: 8, 6: 8, 7: 16, 8: 16, 9: 12, 10: 12, 11: 24, 12: 16, 13: 16, 14: 16,
         15: 16, 16: 24, 17: 36, 18: 48, 19: 64, 20: 16, 23: 8}


def _str(b, o):
    n = struct.unpack_from('<I', b, o)[0]
    s = b[o + 4:o + 4 + n].decode('utf-8', 'replace')
    return s, o + 4 + ((n + 3) & ~3)


def dec(b, o=0):
    h = struct.unpack_from('<I', b, o)[0]; o += 4
    t = h & 0xFF
    if t == 0: return None, o
    if t == 1: return bool(struct.unpack_from('<I', b, o)[0]), o + 4
    if t == 2:
        return (struct.unpack_from('<q', b, o)[0], o + 8) if h & F64 else (struct.unpack_from('<i', b, o)[0], o + 4)
    if t == 3:
        return (struct.unpack_from('<d', b, o)[0], o + 8) if h & F64 else (struct.unpack_from('<f', b, o)[0], o + 4)
    if t in (4, 21): return _str(b, o)
    if t in FIXED:
        n = FIXED[t] * (2 if (h & F64 and t not in (6, 8, 10, 13, 23)) else 1)
        return None, o + n
    if t == 24:  # object encoded as id
        if h & F64: return None, o + 8
        raise ValueError('full object')
    if t == 27:
        n = struct.unpack_from('<I', b, o)[0] & 0x7FFFFFFF; o += 4; d = {}
        for _ in range(n):
            k, o = dec(b, o); v, o = dec(b, o)
            d[k if isinstance(k, (str, int, float, bool, type(None))) else str(k)] = v
        return d, o
    if t == 28:
        n = struct.unpack_from('<I', b, o)[0] & 0x7FFFFFFF; o += 4; a = []
        for _ in range(n):
            v, o = dec(b, o); a.append(v)
        return a, o
    if t in (29, 30, 31, 32, 33):
        n = struct.unpack_from('<I', b, o)[0]; o += 4
        w = {29: 1, 30: 4, 31: 8, 32: 4, 33: 8}[t]
        return None, o + ((n * w + 3) & ~3)
    if t == 34:
        n = struct.unpack_from('<I', b, o)[0]; o += 4; a = []
        for _ in range(n):
            s, o = _str(b, o); a.append(s)
        return a, o
    raise ValueError(f'type {t}')


def enc(v):
    if isinstance(v, bool): return struct.pack('<II', 1, int(v))
    if isinstance(v, int): return struct.pack('<Iq', 2 | F64, v)
    if isinstance(v, str):
        d = v.encode(); return struct.pack('<II', 4, len(d)) + d + b'\0' * ((4 - len(d) % 4) % 4)
    if isinstance(v, list): return struct.pack('<II', 28, len(v)) + b''.join(enc(x) for x in v)
    raise TypeError(type(v))


def send(c, msg, tid, data):
    p = enc([msg, tid, data]); c.sendall(struct.pack('<I', len(p)) + p)


def recv_exact(c, n):
    buf = b''
    while len(buf) < n:
        chunk = c.recv(n - len(buf))
        if not chunk: raise EOFError
        buf += chunk
    return buf


def parse_frame(d, sigs):
    f = dict(frame=d[0], frame_time=d[1], process_time=d[2], physics_time=d[3],
             physics_frame_time=d[4], script_time=d[5], servers={}, scripts=[])
    i = 7
    for _ in range(d[6]):
        name = d[i]; n = d[i + 1]; i += 2
        f['servers'][name] = {d[i + k]: d[i + k + 1] for k in range(0, n, 2)}; i += n
    n = d[i]; i += 1
    for k in range(0, n, 5):
        sid, calls, self_t, total_t, internal_t = d[i + k:i + k + 5]
        f['scripts'].append([sigs.get(sid, str(sid)), calls, self_t, total_t])
    return f


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out'); ap.add_argument('--port', type=int, default=6008)
    ap.add_argument('--seconds', type=float, default=150)
    ap.add_argument('--native', action='store_true', help='also profile native (engine) calls made from scripts')
    a = ap.parse_args()
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('0.0.0.0', a.port)); srv.listen(1)
    print(f'listening on :{a.port}', flush=True)
    c, addr = srv.accept(); print('connected', addr, flush=True)
    send(c, 'profiler:servers', MAIN_ID, [True, [512, a.native]])
    sigs, frames, t0 = {}, 0, time.time()
    seen, errors = {}, {}
    with open(a.out, 'w') as out:
        while time.time() - t0 < a.seconds:
            n = struct.unpack('<I', recv_exact(c, 4))[0]
            raw = recv_exact(c, n)
            try:
                m, _ = dec(raw)
            except Exception as e:
                errors[str(e)] = errors.get(str(e), 0) + 1
                continue
            msg, tid, data = m[0], m[1], m[2]
            seen[msg] = seen.get(msg, 0) + 1
            if msg == 'servers:function_signature':
                sigs[data[1]] = data[0]
            elif msg == 'servers:profile_frame':
                out.write(json.dumps(parse_frame(data, sigs)) + '\n'); frames += 1
            elif msg == 'debug_enter':
                print('break:', data[1] if len(data) > 1 else data, '-> continue', flush=True)
                send(c, 'continue', tid, [])
            elif msg == 'debug_exit':
                send(c, 'profiler:servers', MAIN_ID, [True, [512, a.native]])
    send(c, 'profiler:servers', MAIN_ID, [False])
    print('messages:', seen); print('decode errors:', errors)
    print(f'{frames} frames, {len(sigs)} signatures -> {a.out}')


if __name__ == '__main__':
    main()
