# GEOS on a big SIO disk

One ~8MB double density disk image for D1: (a FujiNet, or any drive or PC program that serves such images): it
boots GEOS (MyPicoDOS loads it, at high speed when the drive has one), and GEOS uses the rest of the same image as
a disk of 8000K: 126 tracks of 256 blocks (`BIG_TRACKS`), less track 18. Up to 254 tracks (15.8MB) can be had,
but DESK TOP's 144 files fill far less than 8MB, and a smaller disk keeps less BAM in memory and reads it faster.

    make bigsio                                     # build/atari_130_bigsio/GEOS_BIGSIO.ATR (and .XEX)
    make bigsio BIG_TRACKS=254                      # ~16MB (after rm -r build/atari_130_bigsio: the driver changes)
    make bigsio EXTRA_CVT="a.cvt b.cvt"             # more files on it (right after DESK TOP)
    make bigsio BIG_CVT="ramdisk/cvt-128k/*"        # other files than ramdisk/cvt-320k's

needs cc65 (ca65), Python 3.11+ and `dir2atr` (Hias's AtariSIO tools). Target: a 130XE (128K) or more.

Programs that use FujiNet's network on it are in [geos-fujinet](../geos-fujinet): FConfig, WiFi Setup, News,
Weather and the GEOS Store, and the server they talk to.

## The disk

    sector 1-3        MyPicoDOS 4.06 boot sectors (autorun)     \
    sector 4-...      GEOS.XEX, the MyDOS VTOC and directory     | a MyDOS disk of 32624 sectors, made by dir2atr;
    sector 369-32624  the GEOS volume                            / its VTOC has the GEOS volume as in use

It's a MyDOS disk because on a disk this big MyPicoDOS reads sector links as 16 bits: a DOS 2 disk's file numbers
in them would end GEOS.XEX early.

Booting, MyPicoDOS shows its screen for a moment; then GEOS.XEX's first part (the loader, kernal/hw/ramloader.s.in)
turns the screen off (black) while the rest loads, so the OS's text screen doesn't show GEOS's code arriving in its
memory, and GEOS turns its own display on when it starts.

The GEOS volume (`drv/siodrv-big-atari.s`, `tools/geosimg.py`): 126 tracks of 256 blocks (`BIG_TRACKS`), block
(t,s) at sector 369+(t-1)*256+s (`SIO_FIRST_SECTOR`). To DESK TOP it's a 1541 whose directory is on track 18; the
driver maps track 18 to track 1, so track 18's own blocks are never used. (1,0) is the disk header, (1,1) the first
directory block, (1,2)-(1,17) the BAM (to (1,33) at 254 tracks): a bit per block, 32 bytes per track. In place of
the 1541's BAM the header holds "BIG1", the size, a free block count (CalcBlksFree returns it) and a serial
number. The driver keeps the whole BAM (4K; 8K at 254 tracks) in the 130XE's bank 1, reads it when the header
shows another disk or serial, and writes the changed BAM blocks in PutDirHead; GetDirHead drops changes that
weren't written, as GEOS on a 1541 does. A disk of another size than the driver was built for isn't taken for a
big volume (geosimg.py reads the size from the header).

    tools/geosimg.py list|check|add|delete|extract IMAGE.ATR ...      the GEOS volume, on the PC
    tools/mkbigatr.py --xex GEOS_BIGSIO.XEX -o DISK.ATR FILE.CVT...    a bootable disk

DESK TOP shows a directory of up to 18 pages of 8 files (144).

## Two drives

With up to 128 tracks (the default 126) GEOS has a drive B: D2: (`SIO_UNIT`+1), when its disk is a big GEOS
volume of the same size (a DOS disk there isn't taken, so GEOS never writes to it). GEOS looks at D2: at start-up
and each time it returns to DESK TOP (EnterDeskTop: quitting any program), through the driver's entry at $9059:
a disk mounted in D2: after boot (on FujiNet's web page, say) is drive B after the next program quits, one taken
out is gone. It puts things as they are at boot (NUMDRV 1, drive B's type), and DESK TOP counts drive B itself
when it starts. The driver serves
both: the SIO device follows `curDrive`, and each drive keeps its own BAM in bank 1 (drive A's at $4000, B's at
$5000). An empty disk for it: `tools/mkbigatr.py --xex GEOS_BIGSIO.XEX --name DATA -o DATA.ATR`.

DESK TOP 2.0 takes a drive B only of a 1541's, 1571's or 1581's type unless there's a RAM expansion, and these
drives are RAM 1541s ($81): mkbigatr.py takes out that check (2 bytes, `DESKTOP_DRIVE_B`) when it puts DESK TOP
on such a disk, and DESK TOP then uses B as it uses a second 1541. Like GEOS's 1541 driver, the driver starts
the directory at a fixed block ((1,1), as the 1541's (18,1)), not at the one in curDirHead: copying a file to the
other drive, DESK TOP looks for it there with that drive's dirHead from its own copy, which isn't read yet the
first time. Tested in atari800 + FujiNet-PC: B's icon and window, a file duplicated on B, one copied from A to B
(the same blocks on both, both disks checked by geosimg.py).

## SIO for programs

Both SIO disk drivers (`drv/siodrv-atari.s`, `drv/siodrv-big-atari.s`) share their SIO code (`drv/sio-core.inc`)
and let programs use it for any SIO device (`drv/sio-call.inc`):

    $904E  "SIOC"        check first
    $9052  .byte 2       version
    $9053  JMP SioCall   A/X: the address of a 12-byte block like the Atari OS's DCB (device, unit, command,
                         direction/status, buffer, timeout, length, aux1, aux2); returns the status in A
    $9056  JMP SioBack   (version 2) A/X: a 7-byte block (from, to, count, direction): copies between GEOS's
                         background screen ($6000-$7FFF, in bank 0 here) and main memory, for printer drivers:
                         C64 programs print what they drew there
    $9059  JMP DriveB    (the big driver, two drives) drive B there or not, as D2:'s disk is now; the kernal's,
                         at boot and in EnterDeskTop (uses diskBlkBuf)

At start-up GEOS sets its date and time from FujiNet's clock (device $45, APETIME, in the time zone set on
FujiNet's web page; kernal/start/start_atari.s), through this entry; without an answer it keeps its own.

DeskTop's options > BASIC (GEOS's ToBASIC, also where a Panic ends) restarts the Atari, a cold start: it boots
D1: again (this disk, or FujiNet's CONFIG when FujiNet boots that). BASIC would have nothing to go back to.

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
