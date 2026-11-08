#!/usr/bin/python3
"""Headless atari800 (a PAL 130XE) run of a GEOS disk with screen dumps, for tests.

atari800 starts in its monitor with a breakpoint on a scanline (once a frame) and is continued frame by frame;
at the given seconds after power on GEOS's screen bitmap is saved as a PNG (and the CPU state goes to the log).

    emushot.py --disk build/atari_130_bigsio/GEOS_BIGSIO.ATR --at 20 40 -o /tmp/shot
        -> /tmp/shot-020.png, /tmp/shot-040.png

The disk is used as it is (GEOS writes to it): pass a copy. atari800 runs on a copy of ~/.atari800.cfg (it
rewrites its config file on exit) with the SIO patch off, so GEOS's own SIO code talks to the emulated drive.
"""

import argparse
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

SCREEN = 0xA038         # 200 lines of 40 bytes (README-Atari.md: front buffer shifted by 56 bytes)
LINES, BYTES = 200, 40


def png(path, bitmap, scale=2):
    """1-bit bitmap (a set bit black) to a grayscale PNG."""
    w, h = BYTES * 8 * scale, LINES * scale
    raw = bytearray()
    for y in range(LINES):
        row = bytearray([0])
        for x in range(BYTES * 8):
            on = bitmap[y * BYTES + x // 8] & (0x80 >> (x % 8))
            row += bytes([0 if on else 255]) * scale
        for _ in range(scale):
            raw += row

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(chunk(b"IEND", b""))


def nmi_address(lbl):
    for line in open(lbl):
        m = re.match(r"al ([0-9A-Fa-f]+) \._NMIHandler$", line.strip())
        if m:
            return int(m.group(1), 16)
    raise SystemExit(f"no _NMIHandler in {lbl}")


FUJINET_DIR = os.path.expanduser("~/Nextcloud/Projects/computers/atari8/emulators/fujisan-portable/bin/fujinet-pc")


def start_fujinet(tmp, disk, hsio, instance, fndir, ini=(), disk2=None):
    """FujiNet-PC on NetSIO port 9997+instance with a copy of disk in D1: (and of disk2 in D2:; written back by
    stop_fujinet)."""
    sd = os.path.join(tmp, "sd")
    os.mkdir(sd)
    shutil.copy(disk, os.path.join(sd, "disk.atr"))
    if disk2:
        shutil.copy(disk2, os.path.join(sd, "disk2.atr"))
    out = []
    section = None
    for ln in open(os.path.join(fndir, "fnconfig.ini")).read().splitlines():
        if ln.startswith("["):
            section = ln
        if section and re.match(r"\[Mount\d+\]", section):
            continue
        if ln.startswith("configenabled="):
            ln = "configenabled=0"
        elif ln.startswith("boot_mode="):
            ln = "boot_mode=0"
        elif ln.startswith("hsioindex="):
            ln = f"hsioindex={hsio}"
        elif section == "[BOIP]" and ln.startswith("port="):
            ln = f"port={9997 + instance}"
        out.append(ln)
    out += ["", "[Mount1]", "hostslot=1", "path=/disk.atr", "mode=w"]
    if disk2:
        out += ["", "[Mount2]", "hostslot=1", "path=/disk2.atr", "mode=w"]
    out += list(ini)
    cfg = os.path.join(tmp, "fnconfig.ini")
    open(cfg, "w").write("\n".join(out) + "\n")
    log = open(os.path.join(tmp, "fujinet.log"), "wb")
    # FujiNet-PC exits with 75 to be restarted (when the Atari resets it over NetSIO)
    loop = (f'while :; do rc=0; ./fujinet -c "{cfg}" -s "{sd}" -u http://127.0.0.1:{8000 + instance} || rc=$?; '
            '[ $rc -eq 75 ] || break; done')
    proc = subprocess.Popen(["sh", "-c", loop], cwd=fndir, stdout=log, stderr=subprocess.STDOUT,
                            start_new_session=True)
    import time
    time.sleep(2)
    return proc


def stop_fujinet(proc, tmp, disk, disk2=None):
    import signal
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(5)
    except (subprocess.TimeoutExpired, ProcessLookupError):
        os.killpg(proc.pid, signal.SIGKILL)
    import time
    time.sleep(0.5)
    shutil.copy(os.path.join(tmp, "sd", "disk.atr"), disk)
    if disk2:
        shutil.copy(os.path.join(tmp, "sd", "disk2.atr"), disk2)


def run(disk, at, out, lbl=None, fps=50, extra_cmds=None, timeout=900, fujinet=False, hsio=-1, instance=7,
        fndir=FUJINET_DIR, dump_mem=False, until=None, fn_ini=(), before_stop=None, basic=False, disk2=None, each_stop=()):
    """fn_ini: more lines for FujiNet-PC's fnconfig.ini (e.g. a [Printer1] section); before_stop(web_url): called
    while FujiNet-PC still runs, after atari800 has quit (e.g. to fetch its printer's output); basic: the XL/XE's
    BASIC there (atari800 -basic; it's switched off, as with OPTION held at power-up, either way); disk2: a disk for
    FujiNet-PC's D2: (written back too); each_stop: monitor commands after every stop (e.g. HISTORY, to see what
    led to a BPC set in extra_cmds)"""
    with tempfile.TemporaryDirectory() as tmp:
        fn = start_fujinet(tmp, disk, hsio, instance, fndir, fn_ini, disk2) if fujinet else None
        cfg = os.path.join(tmp, "atari800.cfg")
        src = os.path.expanduser("~/.atari800.cfg")
        lines = open(src).read().splitlines() if os.path.exists(src) else []
        lines = [ln for ln in lines if not ln.startswith(("ENABLE_SIO_PATCH=", "ENABLE_H_PATCH=", "ENABLE_P_PATCH="))]
        lines += ["ENABLE_SIO_PATCH=0", "ENABLE_H_PATCH=0", "ENABLE_P_PATCH=0"]
        open(cfg, "w").write("\n".join(lines) + "\n")
        frame = 0
        dumps = []
        extra = dict(extra_cmds or {})
        if until is not None:
            # no breaks until the program reaches `until` (breaking every frame upsets high speed SIO over
            # NetSIO, FujiNet-PC keeps sending while the emulation stops), then one screen
            cmds = [f"BPC {until:04X}", "CONT"]
            at = []
            path = os.path.join(tmp, "dump000.bin")
            cmds += ["SHOW", f"WRITE {SCREEN:04X} {SCREEN + LINES * BYTES - 1:04X} {path}"]
            dumps.append((0, path))
        else:
            cmds = ["BLINE 100"]
        for sec in sorted(at):
            target = int(sec * fps)
            while frame < target:
                frame += 1
                cmds += ["BLINE 200", "CONT", *each_stop, "BLINE 100", "CONT", *each_stop]  # each stops once a frame
                for c in extra.get(frame, []):
                    cmds.append(c)
            if dump_mem:
                cmds.append(f"WRITE 0000 BFFF {os.path.join(tmp, f'mem{sec:03}.bin')}")
            path = os.path.join(tmp, f"dump{sec:03}.bin")
            cmds.append("SHOW")
            cmds.append(f"WRITE {SCREEN:04X} {SCREEN + LINES * BYTES - 1:04X} {path}")
            dumps.append((sec, path))
        cmds += ["QUIT", "Y"]
        script = os.path.join(tmp, "monitor.txt")
        open(script, "w").write("\n".join(cmds) + "\n")
        env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
        with open(script) as stdin, open(os.path.join(tmp, "atari800.log"), "wb") as log:
            media = ["-netsio", str(9997 + instance)] if fujinet else [disk]
            try:
                subprocess.run(["atari800", "-config", cfg, "-xe", "-pal", "-basic" if basic else "-nobasic", "-nosound",
                                "-windowed", "-monitor"] + ([] if fujinet else ["-turbo"]) + media,
                               stdin=stdin, stdout=log, stderr=subprocess.STDOUT, env=env, timeout=timeout)
            except subprocess.TimeoutExpired:
                print("atari800 timed out", file=sys.stderr)
            finally:
                if fn:
                    if before_stop:
                        try:
                            before_stop(f"http://127.0.0.1:{8000 + instance}")
                        except Exception as e:    # the screens and the disk are still wanted
                            print(f"before_stop: {e}", file=sys.stderr)
                    stop_fujinet(fn, tmp, disk, disk2)
                    shutil.copy(os.path.join(tmp, "fujinet.log"), f"{out}-fujinet.log")
        made = []
        if dump_mem:
            for sec, _ in dumps:
                m = os.path.join(tmp, f"mem{sec:03}.bin")
                if os.path.exists(m):
                    shutil.copy(m, f"{out}-mem{sec:03}.bin")
        for sec, path in dumps:
            if os.path.exists(path):
                p = f"{out}-{sec:03}.png"
                png(p, open(path, "rb").read())
                made.append(p)
            else:
                print(f"no screen at {sec}s (GEOS not running?)", file=sys.stderr)
        log = open(os.path.join(tmp, "atari800.log"), "rb").read()
        open(f"{out}-atari800.log", "wb").write(log if each_stop else log[-200000:])
        lines = log.decode("latin-1").splitlines()
        shows = [lines[i + 1] for i, ln in enumerate(lines[:-1]) if ln.strip() == "> SHOW"]
        for (sec, _), ln in zip(dumps, shows):
            print(f"{sec:5}s {ln.strip()}", file=sys.stderr)
        return made


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--disk", required=True)
    p.add_argument("--at", type=float, nargs="+", required=True, help="seconds after GEOS's start")
    p.add_argument("-o", "--out", required=True, help="PNG name prefix")
    p.add_argument("--fujinet", action="store_true", help="the disk in D1: of FujiNet-PC (NetSIO), not atari800's")
    p.add_argument("--hsio", type=int, default=-1, help="FujiNet's HSIO index (-1 off)")
    p.add_argument("--timeout", type=int, default=900)
    args = p.parse_args()
    for f in run(args.disk, args.at, args.out, fujinet=args.fujinet, hsio=args.hsio, timeout=args.timeout):
        print(f)


if __name__ == "__main__":
    main()
