#!/usr/bin/env python3
"""Prints TCP/UDP packets on an interface for a few seconds: wire.py IFACE SECONDS [PORT...]
Written instead of using tcpdump because AppArmor forbids signalling it in a sandbox."""
import select
import socket
import struct
import sys
import time

iface, seconds = sys.argv[1], float(sys.argv[2])
ports = {int(p) for p in sys.argv[3:]} or {80, 443}
sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
sock.bind((iface, 0))
print("ready", flush=True)
end = time.time() + seconds
base = {}
while True:
    left = end - time.time()
    if left <= 0 or not select.select([sock], [], [], left)[0]:
        break
    frame, addr = sock.recvfrom(65535)
    if frame[12:14] != b"\x08\x00":
        continue
    ip = frame[14:]
    ihl = (ip[0] & 15) * 4
    proto, total = ip[9], struct.unpack("!H", ip[2:4])[0]
    ip_id = struct.unpack("!H", ip[4:6])[0]
    l4 = ip[ihl:total]
    sport, dport = struct.unpack("!HH", l4[:4])
    if sport not in ports and dport not in ports:
        continue
    direction = "out" if addr[2] == socket.PACKET_OUTGOING else "in "
    if proto == 17:
        print(f"{direction} udp {sport}>{dport} len={len(l4) - 8} id={ip_id} {l4[8:24].hex()}", flush=True)
        continue
    if proto != 6:
        continue
    seq, ack, off_flags = struct.unpack("!IIH", l4[4:14])
    hlen = (off_flags >> 12) * 4
    flags = "".join(c for c, b in zip("FSRPA", (1, 2, 4, 8, 16)) if off_flags & b)
    tsval, first_opt = None, None
    opts = l4[20:hlen]
    i = 0
    while i < len(opts):
        kind = opts[i]
        if kind == 0:
            break
        if kind == 1:
            i += 1
            continue
        if first_opt is None:
            first_opt = kind
        size = opts[i + 1]
        if kind == 8:
            tsval = struct.unpack("!I", opts[i + 2:i + 6])[0]
        i += size
    key = (sport, dport) if direction == "out" else (dport, sport)
    state = base.setdefault(key, {})
    index = "seq" if direction == "out" else "rseq"
    state.setdefault(index, seq)
    state.setdefault("ts" + direction, tsval)
    payload = l4[hlen:]
    print(f"{direction} {flags:5} rel={(seq - state[index]) & 0xffffffff:<6} len={len(payload):<5} "
          f"ts={(tsval or 0) - (state['ts' + direction] or 0):<8} opt1={first_opt} id={ip_id:<6} {payload[:24]!r}", flush=True)
