#!/usr/bin/python3
"""Build a bootable big SIO disk: one double density ATR of up to ~16MB for D1: (FujiNet, or any drive that
serves such images).

The whole disk is a MyDOS disk made by dir2atr with MyPicoDOS 4.06 in autorun mode and GEOS's .XEX in its first
sectors: booting it loads GEOS (at high speed when FujiNet's HSIO index is set). Its VTOC marks sectors first..
as used, so that a DOS writing to the disk can't touch GEOS's volume. From sector `first` on is a big GEOS volume
(tools/geosimg.py, drv/siodrv-big-atari.s) with the given .cvt files, DESK TOP first.

    mkbigatr.py --xex GEOS_BIGSIO.XEX -o GEOS_BIGSIO.ATR [--first 369] [--name GEOS] FILE.CVT...
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import geosimg  # noqa: E402

VTOC = 360
DIR_FIRST, DIR_LAST = 361, 368
VTOC_BITS0 = (256 - 10) * 8     # sector 360 has the bitmap from byte 10, then sectors 359, 358.. 2048 each


def sector(atr, n):
    o = geosimg.atr_offset(n)
    return atr[o:o + (128 if n <= 3 else 256)]


def vtoc_bit(n):
    """ATR offset and mask of sector n's bit in MyDOS's VTOC (set: free)."""
    if n < VTOC_BITS0:
        return geosimg.atr_offset(VTOC) + 10 + n // 8, 0x80 >> (n % 8)
    k = n - VTOC_BITS0
    return geosimg.atr_offset(VTOC - 1 - k // 2048) + (k % 2048) // 8, 0x80 >> (k % 8)


def front_part(xex, first, last, dir2atr, boot):
    """dir2atr's bootable MyDOS disk of `last` sectors with xex as GEOS.XEX, sectors first.. allocated."""
    with tempfile.TemporaryDirectory() as tmp:
        d = os.path.join(tmp, "boot")
        os.mkdir(d)
        shutil.copy(xex, os.path.join(d, "GEOS.XEX"))
        out = os.path.join(tmp, "front.atr")
        # MyDOS format: on a disk this big MyPicoDOS reads sector links as 16 bits (no DOS 2 file numbers)
        subprocess.run([dir2atr, "-d", "-m", "-a", "-b", boot, str(last), out, d], check=True,
                       stdout=subprocess.DEVNULL)
        atr = bytearray(open(out, "rb").read())
    if geosimg.atr_sectors(atr) != last:
        raise SystemExit(f"dir2atr made a disk of {geosimg.atr_sectors(atr)} sectors, not {last}")
    # all of DOS's files and its VTOC below the GEOS volume?
    for n in range(first, last + 1):
        o, m = vtoc_bit(n)
        if not atr[o] & m:
            raise SystemExit(f"sector {n} is in use by DOS, past the GEOS volume's start {first}")
    for n in range(DIR_FIRST, DIR_LAST + 1):
        s = sector(atr, n)
        for k in range(0, 128, 16):
            flag = s[k]
            if flag == 0 or flag & 0x80:
                continue
            name = bytes(s[k + 5:k + 16]).decode("latin-1")
            nxt = s[k + 3] | s[k + 4] << 8
            seen = 0
            while nxt:
                if nxt >= first:
                    raise SystemExit(f"{name.strip()} reaches sector {nxt}, past the GEOS volume's start {first}")
                b = sector(atr, nxt)
                nxt = b[253] << 8 | b[254]
                seen += 1
                if seen > first:
                    raise SystemExit(f"{name.strip()}: sector chain loops")
    # VTOC: the GEOS volume is in use
    for n in range(first, last + 1):
        o, m = vtoc_bit(n)
        atr[o] &= ~m & 0xff
    free = 0
    for n in range(1, last + 1):
        o, m = vtoc_bit(n)
        if atr[o] & m:
            free += 1
    vo = geosimg.atr_offset(VTOC)
    atr[vo + 3] = free & 0xff
    atr[vo + 4] = free >> 8
    return atr


def main(argv=None):
    p = argparse.ArgumentParser(description="Build a bootable ~16MB GEOS ATR (big SIO disk)")
    p.add_argument("files", nargs="*", help=".cvt files for the GEOS volume")
    p.add_argument("--xex", required=True, help="GEOS .XEX (make DRIVE=siodrv_big_atari)")
    p.add_argument("-o", "--out", required=True)
    p.add_argument("--first", type=int, default=geosimg.DEFAULT_FIRST,
                   help="first SIO sector of the GEOS volume (the driver's SIO_FIRST_SECTOR)")
    p.add_argument("--name", default="GEOS", help="disk name")
    p.add_argument("--dir2atr", default="dir2atr")
    p.add_argument("--boot", default="MyPicoDos406")
    args = p.parse_args(argv)

    if not DIR_LAST < args.first <= 4096:
        raise SystemExit(f"--first must be {DIR_LAST + 1}..4096")
    tracks = geosimg.tracks_for(args.first)
    last = args.first + tracks * 256 - 1
    front = front_part(args.xex, args.first, last, args.dir2atr, args.boot)

    files = []
    for f in args.files:
        cvt = open(f, "rb").read()
        try:
            entry, *_ = geosimg.parse_cvt(cvt)
        except geosimg.GeosError as ex:
            raise SystemExit(f"{f}: {ex}")
        files.append((geosimg.entry_name(entry), f, cvt))
    files.sort(key=lambda x: (x[0] != "DESK TOP",))       # DESK TOP first, the rest as given
    volid = int.from_bytes(hashlib.sha1(b"".join(c for _, _, c in files) + open(args.xex, "rb").read()).digest()[:2],
                           "little")

    vol = geosimg.Volume.format(tracks, args.name, volid)
    for name, f, cvt in files:
        try:
            _, n = vol.add_cvt(cvt)
        except geosimg.GeosError as ex:
            raise SystemExit(f"{f}: {ex}")
        print(f"{name:16} {n:5} blocks")
    problems = vol.check()
    if problems:
        raise SystemExit("\n".join(problems))

    out = front
    out[geosimg.atr_offset(args.first):] = vol.data
    with open(args.out, "wb") as f:
        f.write(out)
    print(f"{args.out}: {last} sectors, GEOS volume from sector {args.first}: {tracks} tracks, "
          f"{vol.free_count()} of {vol.usable()} blocks free")


if __name__ == "__main__":
    main()
