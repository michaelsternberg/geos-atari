# GEOS on a big SIO disk

One ~16MB double density disk image for D1: (a FujiNet, or any drive or PC program that serves such images): it
boots GEOS (MyPicoDOS loads it, at high speed when the drive has one), and GEOS uses the rest of the same image as
a disk of 15.8MB, GEOS 2.0's limit: 255 tracks of 256 blocks less the boot part.

    make bigsio                                     # build/atari_130_bigsio/GEOS_BIGSIO.ATR (and .XEX)
    make bigsio EXTRA_CVT="a.cvt b.cvt"             # more files on it (right after DESK TOP)
    make bigsio BIG_CVT="ramdisk/cvt-128k/*"        # other files than ramdisk/cvt-320k's

needs cc65 (ca65), Python 3.11+ and `dir2atr` (Hias's AtariSIO tools). Target: a 130XE (128K) or more.

Programs that use FujiNet's network on it are in [geos-fujinet](../geos-fujinet): FConfig, WiFi Setup, News,
Weather and the GEOS Store, and the server they talk to.

## The disk

    sector 1-3        MyPicoDOS 4.06 boot sectors (autorun)     \
    sector 4-...      GEOS.XEX, the MyDOS VTOC and directory     | a MyDOS disk of 65392 sectors, made by dir2atr;
    sector 369-65392  the GEOS volume                            / its VTOC has the GEOS volume as in use

It's a MyDOS disk because on a disk this big MyPicoDOS reads sector links as 16 bits: a DOS 2 disk's file numbers
in them would end GEOS.XEX early.

The GEOS volume (`drv/siodrv-big-atari.s`, `tools/geosimg.py`): 254 tracks of 256 blocks, block (t,s) at sector
369+(t-1)*256+s (`SIO_FIRST_SECTOR`). To DESK TOP it's a 1541 whose directory is on track 18; the driver maps track
18 to track 1, so track 18's own blocks are never used. (1,0) is the disk header, (1,1) the first directory
block, (1,2)-(1,33) the BAM: a bit per block, 32 bytes per track. In place of the 1541's BAM the header holds
"BIG1", the size, a free block count (CalcBlksFree returns it) and a serial number. The driver keeps the whole
BAM (8K) in the 130XE's bank 1, reads it when the header shows another disk or serial, and writes the changed BAM
blocks in PutDirHead; GetDirHead drops changes that weren't written, as GEOS on a 1541 does.

    tools/geosimg.py list|check|add|delete|extract IMAGE.ATR ...      the GEOS volume, on the PC
    tools/mkbigatr.py --xex GEOS_BIGSIO.XEX -o DISK.ATR FILE.CVT...    a bootable disk

DESK TOP shows a directory of up to 18 pages of 8 files (144).

## SIO for programs

Both SIO disk drivers (`drv/siodrv-atari.s`, `drv/siodrv-big-atari.s`) share their SIO code (`drv/sio-core.inc`)
and let programs use it for any SIO device (`drv/sio-call.inc`):

    $904E  "SIOC"        check first
    $9052  .byte 1       version
    $9053  JMP SioCall   A/X: the address of a 12-byte block like the Atari OS's DCB (device, unit, command,
                         direction/status, buffer, timeout, length, aux1, aux2); returns the status in A

The disk's high speed (asked with '?') is used for the other devices too, since FujiNet switches the whole bus;
a command frame without an answer is sent again at the other speed. A reply shorter than asked for is taken when
its last byte is the checksum of the ones before it (FujiNet's replies differ in size between firmware versions).

## Testing

    python3 tools/geosimg.py check build/atari_130_bigsio/GEOS_BIGSIO.ATR
    tests/run_fstest.py --hsio -1      # tests/fstest as DESK TOP in atari800 + FujiNet-PC: saves, reads, deletes,
                                       # VLIR records, more directory blocks, dropped allocations; then checks the
                                       # disk (~20 minutes at 19200)

`tools/emushot.py` runs atari800 headless, with FujiNet-PC over NetSIO if asked, and saves GEOS's screen as PNG.

What the emulator can't show:

- atari800's own disk drive reads only the first 32768 sectors of an image (the boot hangs): use FujiNet-PC.
- atari800 with NetSIO stalls in MyPicoDOS's high speed boot unless the monitor steps it frame by frame (as
  `emushot.py --at` does); the fstest runs without stepping, so at 19200. High speed needs real hardware.

## On real hardware

1. Put GEOS_BIGSIO.ATR on the FujiNet's SD card (or a TNFS server), mount it in D1: read/write, boot.
   With the HSIO index set (FujiNet's web page, e.g. 3) MyPicoDOS and GEOS load at high speed.
2. DESK TOP shows ~15.9MB free. Copy a file, delete it, Validate.
3. Back on a PC: `tools/geosimg.py check` the image.
