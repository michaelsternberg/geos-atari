#!/bin/sh
# Build build/hwkit - files for testing the SIO disk driver on real hardware:
#  GEOSBOOT.ATR  - bootable MyPicoDos menu disk with GEOS180.XEX, GEOS280.XEX, GEOSCOPY.XEX
#  GEOS180.ATR   - 180K GEOS disk (single sided double density, 717 blocks) with DeskTop and apps
#  GEOS280.ATR   - 280K GEOS disk (1120 blocks) for double sided double density disk or FujiNet
# GEOS*.XEX use D2: (SIO_UNIT=2), D1: is the boot disk.
# Needs cc65 and dir2atr (from AtariSIO) in PATH.

set -e
cd "$(dirname "$0")/.."

OUT=build/hwkit
TMP=build/hwkit.tmp
rm -rf "$OUT" "$TMP"
mkdir -p "$OUT/boot" "$TMP/cvt180"

# 180K disk: files from 320K RAM disk, without geoWrite, GeoTile and two fonts, so there
# is free space left for desk accessory SWAP FILE (GeoDex needs 80 blocks)
cp ramdisk/cvt-320k/* "$TMP/cvt180/"
rm "$TMP/cvt180/geoWrite-patched-for-Atari.cvt" "$TMP/cvt180/GEOTILE.CVT" "$TMP/cvt180/ROMA.CVT" "$TMP/cvt180/UNIVERSI.CVT"

rm -rf build/atari_130_sio_d2 build/atari_130_sio_d2_1120 kernal/kernal_atari.cfg.out
make SYSTEM=atari130 DRIVE=siodrv_atari SIO_UNIT=2 SIO_BLOCKS=717 ATR_CVT="$TMP/cvt180"
make SYSTEM=atari130 DRIVE=siodrv_atari SIO_UNIT=2 SIO_BLOCKS=1120 ATR_CVT=ramdisk/cvt-320k
rm -f kernal/kernal_atari.cfg.out

cp build/atari_130_sio_d2/GEOS_ATARI_130XE_SIO.XEX "$OUT/boot/GEOS180.XEX"
cp build/atari_130_sio_d2/GEOS_SIO.ATR "$OUT/GEOS180.ATR"
cp build/atari_130_sio_d2_1120/GEOS_ATARI_130XE_SIO.XEX "$OUT/boot/GEOS280.XEX"
cp build/atari_130_sio_d2_1120/GEOS_SIO.ATR "$OUT/GEOS280.ATR"

ca65 -t atari tools/geoscopy/geoscopy.s -o "$TMP/geoscopy.o"
ld65 -C atari-asm-xex.cfg -o "$OUT/boot/GEOSCOPY.XEX" "$TMP/geoscopy.o"

dir2atr -d -b MyPicoDos406 720 "$OUT/GEOSBOOT.ATR" "$OUT/boot"
rm -rf "$OUT/boot" "$TMP"

cp tools/hwkit-README.txt "$OUT/README.TXT"
ls -l "$OUT"
