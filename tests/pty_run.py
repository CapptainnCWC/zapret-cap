#!/usr/bin/env python3
"""Runs a program in a pseudo terminal and types keys with pauses: pty_run.py PROGRAM LOG KEY...
The zapret menu drops keys pressed ahead of time, so they cannot be sent all at once."""
import os
import pty
import select
import signal
import sys
import time

program, log, keys = sys.argv[1], sys.argv[2], sys.argv[3:]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm"
    os.execv(program, [program])

alive = True
with open(log, "wb") as out:
    def drain(seconds):
        global alive
        end = time.time() + seconds
        while alive and time.time() < end:
            if select.select([fd], [], [], max(0, end - time.time()))[0]:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    data = b""
                if not data:
                    alive = False
                    break
                out.write(data)
                out.flush()

    for key in keys:
        drain(0.7)
        if not alive:
            break
        os.write(fd, (key + "\n").encode())
    drain(10)

if alive:
    os.kill(pid, signal.SIGKILL)
    sys.exit("program did not exit after the last key")
os.waitpid(pid, 0)
