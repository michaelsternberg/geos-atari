# GEOS for Atari: what this fork adds

The Atari port of GEOS is [Maciej Witkowiak's
geos-atari](https://github.com/ytmytm/geos-atari), built on Michael Steil's
reverse-engineered GEOS source. [README-Atari.md](README-Atari.md) is his
description of the port and is left as he wrote it. Upstream, GEOS runs from a
RAM disk only and asks for help with SIO.

This fork adds SIO (enabling a floppy drive, SIO2PC, SIO2SD or FujiNet), an SIO
entry for GEOS programs, and a number of kernal fixes. The changes were
coordinated by Michael Sternberg and coded by Claude (Anthropic). They are
experimental: tested in atari800 with FujiNet-PC, and on real hardware with the
kits described below.

## In short

| Area | What |
|---|---|
| SIO disk driver | GEOS on a double density disk in D1: (or Dn:) instead of the RAM disk, POKEY driven directly |
| High speed SIO | the drive's own high speed (FujiNet, Happy, US Doubler), 19200 baud otherwise |
| Big SIO disk | one bootable ~8MB (up to ~16MB) disk image: MyPicoDOS boots GEOS from it, GEOS uses the rest |
| Drive B | a second big disk in D2:, found again each time a program quits |
| SIO for programs | an entry in the disk driver that GEOS programs use for any SIO device: the FujiNet apps, printer drivers |
| Kernal fixes | the keyboard (key repeat, keys typed during SIO), the fire button, text and lines on screen and on paper, DESK TOP on drive A, ToBASIC, the clock from FujiNet |
| Tools | disk images made and checked on the PC, test kits for real hardware, emulator tests |

## Three ways to build

| Build | Disk | Command |
|---|---|---|
| RAM disk (upstream's) | the RAM disk in extended memory, loaded with the XEX | `make` |
| SIO disk | a 180K (up to 280K) GEOS disk in D1: | `make SYSTEM=atari130 DRIVE=siodrv_atari` |
| Big SIO disk | one bootable ~8MB image in D1:, and drive B in D2: | `make bigsio` |

## SIO disk driver

`drv/siodrv-atari.s` is a disk driver for a double density (256 bytes per
sector) disk drive or disk image on the SIO bus: XF551, a 1050 with a double
density upgrade, SIO2PC/RespeQt, SIO2SD or FujiNet. It talks to POKEY directly,
by polling: the OS ROM can't be used, because the GEOS kernal lives in the RAM
under it.

    make SYSTEM=atari130 DRIVE=siodrv_atari

makes `build/atari_130_sio/GEOS_ATARI_130XE_SIO.XEX` and a GEOS disk image,
`build/atari_130_sio/GEOS_SIO.ATR`, with the files from `ramdisk/cvt-128k`.
Attach the ATR as D1: and run the XEX: DESK TOP loads from D1:. On real hardware
BASIC must be off (hold OPTION while booting).

The ATR is made on a PC with `tools/mkramdisk.py --atr <blocks>` (formatting
from DESK TOP doesn't work). The disk's size is fixed when building, with
`SIO_BLOCKS` (717 for a 180K disk by default, 1120 at most): the driver and the
image must agree. A 280K image (for SIO2PC, FujiNet and the like) with all the
files of the 320K RAM disk:

    make SYSTEM=atari320 DRIVE=siodrv_atari SIO_BLOCKS=1120 \
        ATR_CVT=ramdisk/cvt-320k

`SIO_UNIT=n` uses Dn: instead of D1:. Builds with another `SIO_BLOCKS` or
`SIO_UNIT` go to their own directories, e.g. `build/atari_130_sio_d2_1120`.

The disk:

- sectors 1-3 (the 128-byte boot sectors) are not used
- GEOS block (track, sector) is SIO sector `(track-1)*128+sector+4`; track 18 is
  mapped to track 1, as on the RAM disk
- the BAM is in the disk header (1,0), so the disk can't be larger than 1120
  blocks

Limits: one drive (D1:, or the one `SIO_UNIT` names) and no RAM disk with it; no
single or enhanced density (128-byte sectors); a write-protected disk isn't
detected (writing to it fails with a general error).

### High speed SIO

The first transfer asks the drive for its high speed (command `?` at 19200 baud,
which FujiNet and the Happy and US Doubler drives answer) and then uses the
POKEY divisor it gives; a drive that doesn't answer stays at 19200. FujiNet
switches the whole bus to its high speed after answering `?`, and back after two
command frames it can't read: so a command frame without an answer is sent again
at the other speed, and back at 19200 the driver asks `?` again. With FujiNet-PC
at HSIO index 3 in atari800, a 15K application loads in 4.3 s instead of 13.4 s.

The keyboard interrupt is off during a transfer, but POKEY goes on scanning the
keyboard: a key pressed meanwhile is taken from KBCODE when the transfer ends
(`SioRun` in `drv/sio-core.inc`). The same key pressed twice within one transfer
counts once.

## Big SIO disk and drive B

`make bigsio` builds one ~8MB double density disk image for D1:. MyPicoDOS boots
GEOS from it (at high speed when the drive has one), and GEOS uses the rest of
the same image as a disk of 8000K: to DESK TOP a 1541, whose directory the
driver keeps on track 1. `BIG_TRACKS=254` makes it ~16MB. The driver
(`drv/siodrv-big-atari.s`) keeps the disk's BAM in the 130XE's bank 1 and a
count of free blocks in the header.

With a second big disk of the same size in D2:, GEOS has a drive B. GEOS looks
at D2: at start-up and each time a program quits, so a disk mounted in D2: later
(on FujiNet's web page, say) is drive B after the next program quits. DESK TOP
2.0 takes such a drive as drive B once `tools/mkbigatr.py` takes out its check
for a RAM expansion (2 bytes, when it puts DESK TOP on the disk).

The disk's layout, the tools for it, the tests and the steps on real hardware:
[README-BigSIO.md](README-BigSIO.md).

## SIO for programs

Both SIO disk drivers share their SIO code (`drv/sio-core.inc`) and let GEOS
programs use it for any SIO device, at the disk's speed and with its retries: an
entry in the disk driver at `$904E` ("SIOC", a version, then `JMP SioCall` with
a block like the Atari OS's DCB), with extras for printer drivers and for
FujiNet's PROCEED signal. The entry, the block, the status codes and examples in
assembler and C: [README-SIO-Call.md](README-SIO-Call.md).

So programs don't need the OS ROM's SIO routine, which GEOS has switched out, or
their own SIO code, which would compete with the disk driver for POKEY. The
FujiNet programs for GEOS (FConfig, WiFi Setup, News, Weather, the GEOS Store,
the FujiNet Terminal) and a printer driver for FujiNet's printer use this entry;
they are in [geos-fujinet](https://github.com/michaelsternberg/geos-fujinet).

At start-up GEOS sets its date and time from FujiNet's clock (device $45,
APETIME, in the time zone set on FujiNet's web page), through this entry;
without an answer it keeps its own.

## Kernal fixes

Keyboard and joystick:

- a key held down repeats, as on the Atari OS: after half a second, then about
  12 times a second (`KEY_REPEAT_DELAY`, `KEY_REPEAT_RATE` in `inc/atari.inc`,
  in frames). The NMI handler repeats the last key while POKEY's SKSTAT says it
  is still held.
- keys pressed during an SIO transfer are not lost (see High speed SIO)
- the keyboard IRQ wrote r1H (which PutChar uses for a character's line) and set
  `interrupt_lock` to 0 whatever it was: it no longer uses r1H, and puts
  `interrupt_lock` back
- the NMI handler tested `interrupt_lock` with BIT/BEQ, which depended on A: it
  now tests the N flag
- the joystick driver reported the fire button the other way round: a press came
  as GEOS's release, so geoWrite's text selection started when the button was
  let go and never ended

Screen and printing:

- characters past column 39 continue 8 lines down, as on the C64: geoWrite
  prints a 640-dot row as two card rows of the background screen, and a
  character that starts in the left half and reaches into the right one landed
  at the start of the next line (the left margin of the printout)
- InvertLine and RecoverLine with both ends of a line in one card used the wrong
  masks (geoWrite's selection came out partly inverted); the fix is in the code
  all three line routines share
- the text prompt is drawn again after InitTextPrompt on the same line
  (geoWrite's cursor moved left or right stayed blank until the next blink)
- the screen stays black while GEOS.XEX loads, instead of showing GEOS's code
  arriving in the OS's text screen

System:

- quitting a program on drive B finds DESK TOP on drive A, instead of asking for
  a disk with DESK TOP
- DESK TOP's options > BASIC (GEOS's ToBASIC, and where a Panic ends) is a clean
  cold start: it boots D1: again (before, the OS's cold start hung on a black
  screen)
- the kernal takes the PIA's PROCEED interrupt when a program enables it (see
  SIO for programs); with it off, as GEOS leaves it, nothing changes
- after boot the SIO COMMAND line is kept inactive and the cassette motor off

## Tools

| Tool | What |
|---|---|
| `tools/mkramdisk.py --atr` | a GEOS disk image for the SIO disk driver |
| `tools/mkbigatr.py` | a bootable big SIO disk image (MyPicoDOS 4.06 with dir2atr, then the GEOS volume) |
| `tools/geosimg.py` | lists, checks, adds, deletes and extracts files of a big SIO disk image on the PC |
| `tools/mkhwkit.sh` | a test kit for real hardware (FujiNet, XF551) in `build/hwkit`; see `tools/hwkit-README.txt` |
| `tools/geoscopy` | a sector copier that writes GEOS disk images to real floppies |
| `tools/emushot.py` | runs atari800 headless, with FujiNet-PC over NetSIO if asked, and saves GEOS's screen |
| `tests/run_fstest.py` | a file system test in atari800 with FujiNet-PC, then a check of the disk |

In an emulator, turn off its SIO patch (`atari800 -nopatch`): with it, the
driver's POKEY code isn't used.

## Related

- [geos-fujinet](https://github.com/michaelsternberg/geos-fujinet): GEOS
  programs for FujiNet on this fork (FConfig, WiFi Setup, News, Weather, the
  GEOS Store, the FujiNet Terminal, CVT Install), FujiNet Epson (a printer
  driver for FujiNet's printer), geos-tnfsd (a folder on a PC as GEOS's drive B)
  and md2geowrite (Markdown as geoWrite documents).
- geoWrite for the Atari,
  [ytmytm/geowrite-atari](https://github.com/ytmytm/geowrite-atari): a fix for
  printing pictures across the whole line is on a branch of a local clone, not
  yet published.
