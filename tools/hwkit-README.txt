GEOS SIO driver - real hardware test kit
========================================

Files
-----
GEOSBOOT.ATR  bootable disk (MyPicoDos menu) with:
              GEOS180.XEX  - GEOS for 130XE, uses 180K GEOS disk in D2:
              GEOS280.XEX  - GEOS for 130XE, uses 280K GEOS disk in D2:
              GEOSCOPY.XEX - copies a disk sector by sector between drives
GEOS180.ATR   180K GEOS disk (720 sectors, single sided double density)
GEOS280.ATR   280K GEOS disk (1123 sectors, needs double sided DD floppy or FujiNet)

GEOS180.XEX only works with a 180K GEOS disk, GEOS280.XEX only with a 280K one.
GEOS always uses drive D2:, D1: is the boot disk.
GEOS disks are not DOS disks - DOS will report them as unformatted, that's OK.

Hold OPTION while the computer boots (BASIC must be off). The clock in the
menu bar runs about 20% fast on NTSC computers - that's expected.


Test 1 - FujiNet only
---------------------
1. FujiNet slot 1: GEOSBOOT.ATR
   FujiNet slot 2: GEOS180.ATR, mounted READ/WRITE (otherwise writes fail)
2. Boot (hold OPTION), choose GEOS180.XEX in the MyPicoDos menu.
3. Expected: DeskTop with "SIODISK" window: 19 files, 137 Kbytes used,
   42 Kbytes free.
4. Open GeoTacToe (application), then quit back to DeskTop.
   Note how many seconds the return to DeskTop takes.
5. Open GeoDex (desk accessory), close it again.
6. Writing: select a small file (e.g. HEX-DEC-BIN), file menu -> duplicate.
   Then rename the copy. Reboot, check the copy is still there.
   Drag it to the trash to delete it.


Test 2 - XF551 (or other double density drive)
----------------------------------------------
Prepare the floppy:
1. Set the XF551 to drive 2 (switches on the back).
   FujiNet slot 1: GEOSBOOT.ATR
   FujiNet slot 2: EMPTY (the XF551 must answer as D2:)
   FujiNet slot 3: GEOS180.ATR
2. Boot, choose GEOSCOPY.XEX.
   Source: 3, destination: 2, format: S (single sided DD), start: Y
3. Expected: "720 sectors copied. Source ended at next sector with
   status $xx - normal at end of disk."
   (For GEOS280.ATR use format D and expect 1123 sectors.)
   If the format fails, format the disk as double density with another
   DOS (e.g. MyDOS 4.5 or DOS XE) and answer N to the format question.

Use it:
4. Reboot (hold OPTION), choose GEOS180.XEX.
5. Repeat steps 3-6 of test 1. Expect it to be slower than FujiNet.


Test 3 - no disk (error handling)
---------------------------------
Boot GEOS180.XEX with nothing in D2: (empty FujiNet slot 2, XF551 off).
GEOS can't load DeskTop then - note what happens (error box, hang...).


What to report
--------------
- which steps worked, exact text of any error boxes
- seconds for returning to DeskTop from an application (FujiNet, XF551)
- GEOSCOPY messages
- a photo of the screen when something looks wrong
