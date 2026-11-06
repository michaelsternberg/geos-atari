#!/usr/bin/python3
"""File system test of the big SIO disk driver (drv/siodrv-big-atari.s), in atari800 with FujiNet-PC.

Builds tests/fstest (cc65, as DESK TOP), a disk with it and some files (tools/mkfujiatr.py), boots it in D1: of
FujiNet-PC, lets fstest run, then reads its result file from the disk and checks the disk (tools/geosimg.py).

    tests/run_fstest.py [--hsio 3] [--seconds 300] [--keep DIR]

Needs `make bigsio` first (the GEOS .XEX), cc65 and FujiNet-PC (tools/emushot.py).
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import emushot  # noqa: E402
import geosimg  # noqa: E402

BUILD = os.path.join(ROOT, "build", "atari_130_bigsio")


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--hsio", type=int, default=3, help="FujiNet's HSIO index (-1: 19200)")
    p.add_argument("--seconds", type=int, default=900, help="at most this long (real time) for fstest to finish")
    p.add_argument("--keep", help="keep the disk and screens in this directory")
    args = p.parse_args()

    xex = os.path.join(BUILD, "GEOS_BIGSIO.XEX")
    if not os.path.exists(xex):
        raise SystemExit(f"no {xex}: make bigsio")
    work = args.keep or tempfile.mkdtemp(prefix="fstest.")
    os.makedirs(work, exist_ok=True)
    src = os.path.join(ROOT, "tests", "fstest")
    cvt = os.path.join(work, "fstest.cvt")
    lbl = os.path.join(work, "fstest.lbl")
    subprocess.run(["cl65", "-t", "geos-cbm", "-O", "-Ln", lbl, "-o", cvt, "fstest.grc", "fstest.c"], cwd=src,
                   check=True)
    done = None
    for ln in open(lbl):
        f = ln.split()
        if len(f) == 3 and f[2] == "._done":
            done = int(f[1], 16)
    if done is None:
        raise SystemExit("no _done in the labels")
    for f in os.listdir(src):
        if f.endswith((".o", ".s")) or f.endswith(".grc.s"):
            os.remove(os.path.join(src, f))
    disk = os.path.join(work, "fstest.atr")
    others = [os.path.join(ROOT, "ramdisk", "cvt-320k", f) for f in ("GEODEX.CVT", "CALENDAR.CVT", "ROMA.CVT")]
    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "mkbigatr.py"), "--xex", xex, "-o", disk,
                    "--name", "FSTEST", cvt] + others, check=True, stdout=subprocess.DEVNULL)

    shots = emushot.run(disk, [], os.path.join(work, "screen"), fujinet=True, hsio=args.hsio,
                        timeout=args.seconds, until=done)
    print("screens:", " ".join(shots))

    data, vol = geosimg.load_image(disk)
    ok = True
    try:
        result = vol.to_cvt("FSTEST RESULT")
    except geosimg.GeosError:
        print("fstest left no result (still running? give it more --seconds)")
        ok = False
    else:
        text = result[508:].decode("latin-1").replace("\r", "\n").strip()
        print(text)
        ok = text.startswith("PASS")
    problems = vol.check()
    for pr in problems:
        print("disk:", pr)
    print(f"disk check: {'OK' if not problems else f'{len(problems)} problems'}, {vol.free_count()} blocks free")
    if not args.keep:
        shutil.rmtree(work)
    return 0 if ok and not problems else 1


if __name__ == "__main__":
    sys.exit(main())
