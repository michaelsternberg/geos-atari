#!/usr/bin/python3
"""GEOS big volume images for drv/siodrv-big-atari.s (big SIO disks, tools/mkbigatr.py).

A volume is BIG_TRACKS tracks of 256 blocks of 256 bytes; GEOS block (t,s) is volume block (t-1)*256+s, which is
SIO sector first+(t-1)*256+s of the ATR (first: the first sector after the MyDOS part, see tools/mkfujiatr.py).
Track 18 (DESK TOP's directory track) is mapped to track 1 by the driver, so its own blocks are never used.

(1,0) is the disk header, (1,1) the first directory block, (1,2).. the BAM (32 bytes per track, bit set: free).

Usage:
    geosimg.py list IMAGE.ATR [--first N]
    geosimg.py check IMAGE.ATR [--first N]
    geosimg.py add IMAGE.ATR FILE.CVT... [--first N]      (writes the image back)
    geosimg.py extract IMAGE.ATR NAME OUT.CVT [--first N]
"""

import argparse
import hashlib
import struct
import sys

# disk header (const.inc)
OFF_TO_BAM = 4
OFF_DISK_NAME = 144
OFF_OP_TR_SC = 171
OFF_GS_ID = 173
# big volume fields in place of the 1541 BAM (drv/siodrv-big-atari.s)
OFF_BIG_MAGIC = OFF_TO_BAM
OFF_BIG_TRACKS = OFF_TO_BAM + 4
OFF_BIG_BAMSEC = OFF_TO_BAM + 5
OFF_BIG_BAMCNT = OFF_TO_BAM + 6
OFF_BIG_FREE = OFF_TO_BAM + 8
OFF_BIG_TOTAL = OFF_TO_BAM + 10
OFF_BIG_SERIAL = OFF_TO_BAM + 12
OFF_BIG_VOLID = OFF_TO_BAM + 14
BIG_MAGIC = b"BIG1"
BAM_SECTOR = 2
DIR_TRACK = 18
GEOS_ID = b"GEOS format V1.0"

# directory entry
FRST_FILE_ENTRY = 2
OFF_CFILE_TYPE = 0
OFF_DE_TR_SC = 1
OFF_FNAME = 3
OFF_GHDR_PTR = 19
OFF_GSTRUC_TYPE = 21
OFF_GFILE_TYPE = 22
OFF_SIZE = 28
DIR_ENTRY_LEN = 30
ENTRY_SPACING = 32

DEFAULT_FIRST = 369     # after MyDOS's VTOC and directory, as the driver's default SIO_FIRST_SECTOR


class GeosError(Exception):
    pass


def tracks_for(first):
    return min(255, (0x10000 - first) // 256)


# --- ATR (double density, 3 boot sectors of 128 bytes) ---

def atr_offset(sector):
    if sector <= 3:
        return 16 + (sector - 1) * 128
    return 16 + 3 * 128 + (sector - 4) * 256


def atr_header(sectors):
    size = 3 * 128 + (sectors - 3) * 256
    par = size // 16
    h = bytearray(16)
    h[0:2] = b"\x96\x02"
    h[2] = par & 0xff
    h[3] = (par >> 8) & 0xff
    h[4:6] = b"\x00\x01"
    h[6] = (par >> 16) & 0xff
    return h


def atr_sectors(data):
    if data[0:2] != b"\x96\x02":
        raise GeosError("not an ATR image")
    if struct.unpack_from("<H", data, 4)[0] != 256:
        raise GeosError("not a double density ATR image")
    size = len(data) - 16
    return 3 + (size - 3 * 128) // 256


class Volume:
    """A big GEOS volume in memory."""

    def __init__(self, tracks, data=None):
        self.tracks = tracks
        self.data = bytearray(tracks * 256 * 256) if data is None else bytearray(data)
        if len(self.data) < tracks * 256 * 256:
            self.data.extend(bytes(tracks * 256 * 256 - len(self.data)))

    # block access
    def index(self, t, s):
        if t == DIR_TRACK:
            t = 1
        if not 1 <= t <= self.tracks or not 0 <= s <= 255:
            raise GeosError(f"block ({t},{s}) is not on the disk")
        return (t - 1) * 256 + s

    def ts(self, index):
        return (index // 256 + 1, index % 256)

    def block(self, t, s):
        i = self.index(t, s) * 256
        return self.data[i:i + 256]

    def put(self, t, s, buf):
        assert len(buf) == 256
        i = self.index(t, s) * 256
        self.data[i:i + 256] = buf

    @property
    def header(self):
        return self.block(1, 0)

    def bam_blocks(self):
        return (self.tracks + 7) // 8

    # BAM (bit set: free), its blocks follow each other on track 1: byte (t-1)*32+s/8 is at
    # BAM_SECTOR*256 + (t-1)*32 + s/8 in the volume
    def is_free(self, index):
        return bool(self.data[BAM_SECTOR * 256 + index // 8] & (1 << (index % 8)))

    def set_free(self, index, free):
        i = BAM_SECTOR * 256 + index // 8
        if free:
            self.data[i] |= 1 << (index % 8)
        else:
            self.data[i] &= ~(1 << (index % 8)) & 0xff

    def free_count(self):
        bam = self.data[BAM_SECTOR * 256:BAM_SECTOR * 256 + self.tracks * 32]
        return sum(bin(b).count("1") for b in bam)

    def usable(self):
        return self.tracks * 256 - 256

    def set_header_field(self, off, value):
        h = self.header
        struct.pack_into("<H", h, off, value)
        self.put(1, 0, h)

    def get_header_field(self, off):
        return struct.unpack_from("<H", self.header, off)[0]

    def update_free(self):
        self.set_header_field(OFF_BIG_FREE, self.free_count())

    # allocation, linear from a cursor (like SetNextFree)
    def alloc(self, start=None):
        n = self.tracks * 256
        i0 = self.cursor if start is None else start
        for k in range(n):
            i = (i0 + k) % n
            if self.is_free(i):
                self.set_free(i, False)
                self.cursor = i + 1
                return self.ts(i)
        raise GeosError("disk full")

    @classmethod
    def format(cls, tracks, name="GEOS", volid=0x1234, diskid=b"BS"):
        if tracks < 18:
            raise GeosError("volume too small")
        v = cls(tracks)
        h = bytearray(256)
        h[0:2] = b"\x01\x01"            # first directory block
        h[2] = 0x41                     # 'A' as a 1541
        h[OFF_BIG_MAGIC:OFF_BIG_MAGIC + 4] = BIG_MAGIC
        h[OFF_BIG_TRACKS] = tracks
        h[OFF_BIG_BAMSEC] = BAM_SECTOR
        h[OFF_BIG_BAMCNT] = v.bam_blocks()
        struct.pack_into("<H", h, OFF_BIG_TOTAL, v.usable())
        struct.pack_into("<H", h, OFF_BIG_SERIAL, 0)
        struct.pack_into("<H", h, OFF_BIG_VOLID, volid & 0xffff)
        h[OFF_DISK_NAME:OFF_DISK_NAME + 29] = b"\xa0" * 29
        nm = name.encode("ascii")[:16]
        h[OFF_DISK_NAME:OFF_DISK_NAME + len(nm)] = nm
        h[OFF_DISK_NAME + 18:OFF_DISK_NAME + 20] = diskid[:2]
        h[OFF_DISK_NAME + 21:OFF_DISK_NAME + 23] = b"2A"
        h[OFF_GS_ID:OFF_GS_ID + len(GEOS_ID)] = GEOS_ID
        v.put(1, 0, h)
        # BAM: all blocks of all tracks free, but track 18
        for i in range(tracks * 256):
            if i // 256 + 1 != DIR_TRACK:
                v.set_free(i, True)
        system = [(1, 0), (1, 1)] + [(1, BAM_SECTOR + k) for k in range(v.bam_blocks())]
        for t, s in system:
            v.set_free(v.index(t, s), False)
        empty = bytearray(256)
        empty[1] = 0xff
        v.put(1, 1, empty)
        # border block
        v.cursor = v.index(1, BAM_SECTOR + v.bam_blocks())
        border = v.alloc()
        v.put(*border, empty)
        h = v.header
        h[OFF_OP_TR_SC:OFF_OP_TR_SC + 2] = bytes(border)
        v.put(1, 0, h)
        v.update_free()
        return v

    def check_big(self):
        h = self.header
        if h[OFF_BIG_MAGIC:OFF_BIG_MAGIC + 4] != BIG_MAGIC:
            raise GeosError("not a big GEOS volume (no BIG1 in the disk header)")
        if h[OFF_BIG_TRACKS] != self.tracks:
            raise GeosError(f"volume has {h[OFF_BIG_TRACKS]} tracks, image room for {self.tracks}")

    # directory
    def dir_blocks(self):
        t, s = self.header[0], self.header[1]
        seen = set()
        while t != 0:
            if (t, s) in seen:
                raise GeosError(f"directory chain loops at ({t},{s})")
            seen.add((t, s))
            yield (t, s)
            b = self.block(t, s)
            t, s = b[0], b[1]

    def entries(self, border=True):
        """(block ts, slot offset, entry bytes) of used entries."""
        blocks = list(self.dir_blocks())
        h = self.header
        if border and h[OFF_GS_ID:OFF_GS_ID + len(GEOS_ID)] == GEOS_ID and h[OFF_OP_TR_SC] != 0:
            blocks.append((h[OFF_OP_TR_SC], h[OFF_OP_TR_SC + 1]))
        for ts in blocks:
            b = self.block(*ts)
            for k in range(8):
                off = FRST_FILE_ENTRY + k * ENTRY_SPACING
                e = b[off:off + DIR_ENTRY_LEN]
                if e[OFF_CFILE_TYPE] != 0:
                    yield ts, off, e

    def free_slot(self):
        last = None
        for ts in self.dir_blocks():
            last = ts
            b = self.block(*ts)
            for k in range(8):
                off = FRST_FILE_ENTRY + k * ENTRY_SPACING
                if b[off + OFF_CFILE_TYPE] == 0:
                    return ts, off
        # add a directory block (as AddDirBlock: first free block from (1,0))
        new = self.alloc(start=0)
        b = self.block(*last)
        b[0:2] = bytes(new)
        self.put(*last, b)
        empty = bytearray(256)
        empty[1] = 0xff
        self.put(*new, empty)
        return new, FRST_FILE_ENTRY

    def find(self, name):
        for ts, off, e in self.entries():
            if entry_name(e) == name:
                return ts, off, e
        return None

    def chain(self, t, s):
        """Blocks of a chain and the last byte index of its last block."""
        out = []
        seen = set()
        while True:
            i = self.index(t, s)
            if i in seen:
                raise GeosError(f"chain loops at ({t},{s})")
            seen.add(i)
            out.append(i)
            b = self.block(t, s)
            if b[0] == 0:
                return out, b[1]
            t, s = b[0], b[1]

    def file_blocks(self, e):
        """All blocks of a file from its directory entry."""
        blocks = []
        ht, hs = e[OFF_GHDR_PTR], e[OFF_GHDR_PTR + 1]
        if ht:
            blocks.append(self.index(ht, hs))
        t, s = e[OFF_DE_TR_SC], e[OFF_DE_TR_SC + 1]
        if e[OFF_GSTRUC_TYPE] == 1:     # VLIR: index block, then a chain per record
            blocks.append(self.index(t, s))
            idx = self.block(t, s)
            for r in range(127):
                rt, rs = idx[2 + 2 * r], idx[3 + 2 * r]
                if rt:
                    blocks += self.chain(rt, rs)[0]
        elif t:
            blocks += self.chain(t, s)[0]
        return blocks

    # files
    def write_chain(self, data):
        """Write data as a chain of blocks, return its first block (and the number of blocks)."""
        chunks = [data[i:i + 254] for i in range(0, len(data), 254)] or [b""]
        blocks = [self.alloc() for _ in chunks]
        for n, (ts, chunk) in enumerate(zip(blocks, chunks)):
            b = bytearray(256)
            if n + 1 < len(chunks):
                b[0:2] = bytes(blocks[n + 1])
            else:
                b[0] = 0
                b[1] = len(chunk) + 1
            b[2:2 + len(chunk)] = chunk
            self.put(*ts, b)
        return blocks[0], len(blocks)

    def add_cvt(self, cvt, replace=False):
        entry, header, kind, payload = parse_cvt(cvt)
        name = entry_name(entry)
        old = self.find(name)
        if old:
            if not replace:
                raise GeosError(f"{name} is already on the disk")
            self.delete(name)
        nblocks = 1
        hts, _ = self.write_chain(header[0:254])       # header block: link (0,$ff)
        hb = self.block(*hts)
        hb[0:2] = b"\x00\xff"
        self.put(*hts, hb)
        if kind == "VLIR":
            records, recdata = payload
            idx_ts = self.alloc()
            idx = bytearray(256)
            idx[1] = 0xff
            nblocks += 1
            for r, (count, last, data) in enumerate(records):
                if count == 0:
                    idx[2 + 2 * r:4 + 2 * r] = bytes([0, last])
                    continue
                first, n = self.write_chain(data)
                # fix the last block's last byte as given by the convert file
                blocks, _ = self.chain(*first)
                b = self.block(*self.ts(blocks[-1]))
                b[1] = last
                self.put(*self.ts(blocks[-1]), b)
                idx[2 + 2 * r:4 + 2 * r] = bytes(first)
                nblocks += n
            self.put(*idx_ts, idx)
            first = idx_ts
        else:
            first, n = self.write_chain(payload)
            nblocks += n
        e = bytearray(entry[0:DIR_ENTRY_LEN])
        e[OFF_DE_TR_SC:OFF_DE_TR_SC + 2] = bytes(first)
        e[OFF_GHDR_PTR:OFF_GHDR_PTR + 2] = bytes(hts)
        struct.pack_into("<H", e, OFF_SIZE, nblocks)
        ts, off = self.free_slot()
        b = self.block(*ts)
        b[off:off + DIR_ENTRY_LEN] = e
        self.put(*ts, b)
        self.update_free()
        return name, nblocks

    def delete(self, name):
        found = self.find(name)
        if not found:
            raise GeosError(f"no {name} on the disk")
        ts, off, e = found
        for i in self.file_blocks(e):
            self.set_free(i, True)
        b = self.block(*ts)
        b[off + OFF_CFILE_TYPE] = 0
        self.put(*ts, b)
        self.update_free()

    def to_cvt(self, name):
        found = self.find(name)
        if not found:
            raise GeosError(f"no {name} on the disk")
        _, _, e = found
        out = bytearray(e)
        kind = {0: b"SEQ", 1: b"PRG"}.get(e[OFF_GSTRUC_TYPE], b"PRG")
        sig = kind + b" formatted GEOS file V1.0"
        out += bytearray(254 - len(out))
        out[30:30 + len(sig)] = sig
        h = self.block(e[OFF_GHDR_PTR], e[OFF_GHDR_PTR + 1])
        out += h[2:256]
        t, s = e[OFF_DE_TR_SC], e[OFF_DE_TR_SC + 1]
        if e[OFF_GSTRUC_TYPE] == 1:
            idx = self.block(t, s)
            recs = bytearray(254)
            body = bytearray()
            for r in range(127):
                rt, rs = idx[2 + 2 * r], idx[3 + 2 * r]
                if rt == 0:
                    recs[2 * r:2 * r + 2] = bytes([0, rs])
                    continue
                blocks, last = self.chain(rt, rs)
                recs[2 * r:2 * r + 2] = bytes([len(blocks), last])
                for i in blocks:
                    body += self.data[i * 256 + 2:i * 256 + 256]
            out += recs + body
        else:
            blocks, last = self.chain(t, s)
            for n, i in enumerate(blocks):
                b = self.data[i * 256:i * 256 + 256]
                out += b[2:last + 1] if n + 1 == len(blocks) else b[2:256]
        return bytes(out)

    def check(self):
        """Consistency check, returns a list of problems (empty if none)."""
        problems = []
        self.check_big()
        h = self.header
        used = {}

        def mark(i, what):
            if i in used:
                problems.append(f"block {self.ts(i)} used by {used[i]} and {what}")
            used[i] = what

        mark(self.index(1, 0), "disk header")
        for k in range(self.bam_blocks()):
            mark(self.index(1, BAM_SECTOR + k), "BAM")
        try:
            for ts in self.dir_blocks():
                mark(self.index(*ts), "directory")
        except GeosError as ex:
            problems.append(str(ex))
        if h[OFF_OP_TR_SC]:
            mark(self.index(h[OFF_OP_TR_SC], h[OFF_OP_TR_SC + 1]), "border block")
        names = set()
        for ts, off, e in self.entries():
            name = entry_name(e)
            if name in names:
                problems.append(f"{name} is on the disk twice")
            names.add(name)
            try:
                blocks = self.file_blocks(e)
            except GeosError as ex:
                problems.append(f"{name}: {ex}")
                continue
            for i in blocks:
                mark(i, name)
            size = struct.unpack_from("<H", e, OFF_SIZE)[0]
            if size != len(blocks):
                problems.append(f"{name}: size {size} in directory, {len(blocks)} blocks")
        for i in range(self.tracks * 256):
            t = i // 256 + 1
            free = self.is_free(i)
            if t == DIR_TRACK:
                if free:
                    problems.append(f"block {self.ts(i)} of track 18 is free in the BAM")
            elif i in used and free:
                problems.append(f"block {self.ts(i)} ({used[i]}) is free in the BAM")
            elif i not in used and not free:
                problems.append(f"block {self.ts(i)} is allocated but not used")
        nfree = self.free_count()
        if self.get_header_field(OFF_BIG_FREE) != nfree:
            problems.append(f"free count {self.get_header_field(OFF_BIG_FREE)} in header, {nfree} in BAM")
        if self.get_header_field(OFF_BIG_TOTAL) != self.usable():
            problems.append(f"total {self.get_header_field(OFF_BIG_TOTAL)} in header, should be {self.usable()}")
        return problems


def entry_name(e):
    return bytes(e[OFF_FNAME:OFF_FNAME + 16]).split(b"\xa0")[0].decode("latin-1")


def parse_cvt(cvt):
    """Convert (.cvt) file: (dir entry, header block (254), 'SEQ' data | 'VLIR' (records, None))."""
    if len(cvt) < 508:
        raise GeosError("too short for a convert file")
    entry = bytearray(cvt[0:254])
    if entry[33:53] != b" formatted GEOS file":
        raise GeosError("not a GEOS convert file")
    header = bytearray(cvt[254:508])
    rest = cvt[508:]
    if entry[OFF_GSTRUC_TYPE] == 1:
        recblk = rest[0:254]
        data = rest[254:]
        records = []
        pos = 0
        for r in range(127):
            count, last = recblk[2 * r], recblk[2 * r + 1]
            if count == 0:
                records.append((0, last, b""))
                continue
            chunk = data[pos:pos + count * 254]
            if len(chunk) < (count - 1) * 254 + 1:
                raise GeosError(f"record {r} is cut short")
            # the last block holds last-1 bytes
            body = chunk[0:(count - 1) * 254] + chunk[(count - 1) * 254:(count - 1) * 254 + last - 1]
            records.append((count, last, body))
            pos += count * 254
        return entry, header, "VLIR", (records, None)
    return entry, header, "SEQ", bytes(rest)


# --- images ---

def load_image(path, first=DEFAULT_FIRST):
    data = open(path, "rb").read()
    n = atr_sectors(data)
    tracks = tracks_for(first)
    start = atr_offset(first)
    vol = Volume(tracks, data[start:start + tracks * 256 * 256])
    return data, vol


def save_image(path, data, vol, first=DEFAULT_FIRST):
    data = bytearray(data)
    start = atr_offset(first)
    end = start + vol.tracks * 256 * 256
    if len(data) < end:
        data.extend(bytes(end - len(data)))
        data[0:16] = atr_header(first + vol.tracks * 256 - 1)
    data[start:end] = vol.data
    open(path, "wb").write(data)


def main(argv=None):
    p = argparse.ArgumentParser(description="GEOS big volume images (big SIO disks)")
    p.add_argument("--first", type=int, default=DEFAULT_FIRST, help="first SIO sector of the GEOS volume")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list").add_argument("image")
    sub.add_parser("check").add_argument("image")
    a = sub.add_parser("add")
    a.add_argument("image")
    a.add_argument("files", nargs="+")
    a.add_argument("--replace", action="store_true")
    d = sub.add_parser("delete")
    d.add_argument("image")
    d.add_argument("name")
    x = sub.add_parser("extract")
    x.add_argument("image")
    x.add_argument("name")
    x.add_argument("out")
    args = p.parse_args(argv)
    try:
        data, vol = load_image(args.image, args.first)
        vol.check_big()
        if args.cmd == "list":
            h = vol.header
            print(f'"{bytes(h[OFF_DISK_NAME:OFF_DISK_NAME + 16]).split(b"\xa0")[0].decode()}"'
                  f'  {vol.tracks} tracks, {vol.get_header_field(OFF_BIG_FREE)} of {vol.usable()} blocks free')
            for ts, off, e in vol.entries():
                print(f"{struct.unpack_from('<H', e, OFF_SIZE)[0]:6}  {entry_name(e):16}  type {e[OFF_GFILE_TYPE]:3}"
                      f"  {'VLIR' if e[OFF_GSTRUC_TYPE] == 1 else 'SEQ '}  dir {ts}")
        elif args.cmd == "check":
            problems = vol.check()
            for pr in problems:
                print(pr)
            print(f"{args.image}: {'OK' if not problems else f'{len(problems)} problems'}, "
                  f"{sum(1 for _ in vol.entries())} files, {vol.free_count()} blocks free")
            return 1 if problems else 0
        elif args.cmd == "add":
            vol.cursor = 0
            for f in args.files:
                name, n = vol.add_cvt(open(f, "rb").read(), args.replace)
                print(f"{name}: {n} blocks")
            save_image(args.image, data, vol, args.first)
        elif args.cmd == "delete":
            vol.delete(args.name)
            save_image(args.image, data, vol, args.first)
        elif args.cmd == "extract":
            open(args.out, "wb").write(vol.to_cvt(args.name))
    except GeosError as ex:
        print(f"{args.image}: {ex}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
