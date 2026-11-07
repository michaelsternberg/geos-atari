; Atari SIO disk drive, big volume (up to ~16MB): GEOS 2.0's limit of 255 tracks of 256 sectors
; FujiNet (or any drive/emulator that serves large double density ATR images, MyDOS style)

; Filesystem part based on Atari RAM drive by Maciej Witkowiak, 2022
; SIO part talks to POKEY directly, OS ROM is not used (GEOS Kernal lives under it), see drv/sio-core.inc

; Disk layout:
; double density (256 bytes per sector) image, SIO sectors 1..SIO_FIRST_SECTOR-1 are left to Atari DOS
; (MyPicoDOS boot sectors, VTOC, directory and the GEOS .XEX it boots), see tools/mkfujiatr.py
; GEOS block (track, sector) maps linearly to SIO sector (track-1)*256+sector+SIO_FIRST_SECTOR
; BIG_TRACKS tracks of 256 sectors; track 18 (DESK TOP's directory track) is mapped to track 1,
; so the blocks of track 18 itself are never used (they are allocated in the BAM)
; (1,0) - dirHead: disk name, GEOS signature, border block, and in place of the 1541 BAM:
;	OFF_BIG_MAGIC	"BIG1"
;	OFF_BIG_TRACKS	number of tracks
;	OFF_BIG_BAMSEC	first BAM block on track 1
;	OFF_BIG_BAMCNT	number of BAM blocks
;	OFF_BIG_FREE	free blocks (word), kept up to date, CalcBlksFree returns it
;	OFF_BIG_TOTAL	usable blocks (word)
;	OFF_BIG_SERIAL	incremented whenever BAM blocks are written (word)
;	OFF_BIG_VOLID	random volume ID (word), with the serial tells if the BAM in memory is current
; (1,1) - first directory block, (1,2).. - BAM blocks: 32 bytes per track, bit set - block free,
;	  sector s of track t is bit s&7 of byte (t-1)*32+s/8
; the whole BAM is kept in expanded RAM (bank 1, $4000-$5FDF): read when the disk's dirHead doesn't match
; the BAM in memory, changed blocks written by PutDirHead; GetDirHead reloads changed blocks (so as
; on a 1541 changes not followed by PutDirHead are dropped)
; use tools/mkfujiatr.py (tools/geosimg.py) to create a disk image

; XXX there is no check for write protection
; FindBAMBit returns Z/r8H as usual, but X/r7H don't point into curDirHead

; SIO device of GEOS device 8 (1=D1:)
.ifndef SIO_UNIT
SIO_UNIT		= 1
.endif
; the first SIO sector used by GEOS: after MyDOS's VTOC (360) and directory (361-368)
.ifndef SIO_FIRST_SECTOR
SIO_FIRST_SECTOR	= 369
.endif

.include "drv/sio-const.inc"

.if ($10000 - SIO_FIRST_SECTOR) / 256 > 255
BIG_TRACKS		= 255
.else
BIG_TRACKS		= ($10000 - SIO_FIRST_SECTOR) / 256
.endif
BIG_USABLE		= BIG_TRACKS*256 - 256	; less track 18
BAM_SECTOR		= 2			; first BAM block on track 1
BAM_BLOCKS		= (BIG_TRACKS+7)/8	; 8 tracks per BAM block
BAM_BANK		= 1			; expanded RAM bank
BAM_ADDR		= $4000			; where the BAM is in that bank
BAM_END			= BAM_ADDR+BIG_TRACKS*32

OFF_BIG_MAGIC		= OFF_TO_BAM		; "BIG1"
OFF_BIG_TRACKS		= OFF_TO_BAM+4
OFF_BIG_BAMSEC		= OFF_TO_BAM+5
OFF_BIG_BAMCNT		= OFF_TO_BAM+6
OFF_BIG_FREE		= OFF_TO_BAM+8
OFF_BIG_TOTAL		= OFF_TO_BAM+10
OFF_BIG_SERIAL		= OFF_TO_BAM+12
OFF_BIG_VOLID		= OFF_TO_BAM+14

RAM_DIR_TRACK		= 1
RAM_DIR_SECT_HEAD	= 0

.include "inc/const.inc"
.include "inc/jumptab.inc"
.include "inc/geossym.inc"
.include "inc/geosmac.inc"
.include "inc/atari.inc"

; GEOS will fill those in
.import interrupt_lock
.import jiffyCounter
.import atari_banks

.segment "drive"


.assert * = $9000, error, "Disk driver not at $9000"
.assert BIG_TRACKS >= 18, error, "volume too small"
.assert SIO_FIRST_SECTOR+BIG_TRACKS*256 <= $10000, error, "volume past SIO sector 65535"
.assert BAM_SECTOR+BAM_BLOCKS <= 255, error, "BAM too large"
.assert SIO_UNIT >= 1 .and SIO_UNIT <= 8, error, "SIO_UNIT must be 1-8 (D1:-D8:)"

;-------------------------------------------------
_InitForIO:		.word __InitForIO		;9000
_DoneWithIO:		.word __DoneWithIO		;9002
_ExitTurbo:		.word __ExitTurbo		;9004
_PurgeTurbo:		.word __PurgeTurbo		;9006
_EnterTurbo:		.word __EnterTurbo		;9008
_ChangeDiskDevice:	.word __ChangeDiskDevice	;900a
_NewDisk:		.word __NewDisk 		;900c
_ReadBlock:		.word __ReadBlock		;900e
_WriteBlock:		.word __WriteBlock		;9010
_VerWriteBlock:		.word __VerWriteBlock		;9012
_OpenDisk:		.word __OpenDisk		;9014
_GetBlock:		.word __GetBlock		;9016
_PutBlock:		.word __PutBlock		;9018
_GetDirHead:		.word __GetDirHead		;901a
_PutDirHead:		.word __PutDirHead		;901c
_GetFreeDirBlk:		.word __GetFreeDirBlk		;901e
_CalcBlksFree:		.word __CalcBlksFree		;9020
_FreeBlock:		.word __FreeBlock		;9022
_SetNextFree:		.word __SetNextFree		;9024
_FindBAMBit:		.word __FindBAMBit		;9026
_NxtBlkAlloc:		.word __NxtBlkAlloc		;9028
_BlkAlloc:		.word __BlkAlloc		;902a
_ChkDkGEOS:		.word __ChkDkGEOS		;902c
_SetGEOSDisk:		.word __SetGEOSDisk		;902e

Get1stDirEntry:		JMP _Get1stDirEntry		;9030
GetNxtDirEntry:		JMP _GetNxtDirEntry		;9033
GetBorder:		JMP _GetBorder			;9036
AddDirBlock:		JMP _AddDirBlock		;9039
ReadBuff:		JMP _ReadBuff			;903c
WriteBuff:		JMP _WriteBuff			;903f
			JMP __I9042			;9042
			JMP GetDOSError 		;9045
AllocateBlock:		JMP _AllocateBlock		;9048
ReadLink:		JMP _ReadLink			;904b
SIO_CALL_SIG:		.byte "SIOC"			;904e
			.byte 2				;9052
			JMP SioCall			;9053
			JMP SioBack			;9056
.assert SIO_CALL_SIG = $904e, error, "SIO call entry moved"


;---------------------------------------
_Get1stDirEntry:
		MoveW curDirHead, r1			; get t&s from directory header
		JSR ReadBuff
		LoadW r5, diskBlkBuf+FRST_FILE_ENTRY
		LoadB borderFlag, 0
		RTS

;---------------------------------------
_GetNxtDirEntry:
		LDX #0
		LDY #0
		AddVW OFF_NXT_FILE, r5
		CmpWI r5, diskBlkBuf+$ff
		BCC @end				; overflow?
		LDY #$ff
		MoveW diskBlkBuf, r1
		BNE @readsect
		LDA borderFlag
		BNE @end
		LoadB borderFlag, $ff
		JSR GetBorder
		bnex @end
		TYA
		BNE @end
@readsect:	JSR ReadBuff
		LDY #0
		LoadW r5, diskBlkBuf+FRST_FILE_ENTRY
@end:		RTS

;---------------------------------------
_GetBorder:
		JSR GetDirHead
		bnex GetBord2
		LoadW r5, curDirHead
		JSR ChkDkGEOS
		BNE GetBord0
		LDY #$ff
		BNE GetBord1
GetBord0:	MoveW curDirHead+OFF_OP_TR_SC, r1
		LDY #0
GetBord1:	LDX #0
GetBord2:	RTS

;---------------------------------------
ClearAndWrite:	LDA #0
		TAY
:		STA diskBlkBuf,y
		INY
		BNE :-
		DEY
		STY diskBlkBuf+1
		JMP WriteBuff

;---------------------------------------
__CalcBlksFree:
		LDY #OFF_BIG_FREE
		LDA (r5),y
		STA r4L
		INY
		LDA (r5),y
		STA r4H
		LoadW r3, BIG_USABLE
		RTS

;---------------------------------------
; r3 - where to start looking, returns the allocated block in r3 (and r6), error code in X
__SetNextFree:	MoveW r3, r6
		JSR BamAddr
		BCC :+
		LoadB r6L, 1			; not on the disk: from the start
		LoadB r6H, 0
:		JSR __FindBAMBit
		BNE SNF_Alloc			; that one is free
		JSR BamOn			; scan the bytes from there on, then the whole BAM once more
		LoadB bamPass, 2
SNF_Scan:	JSR bamLd
		BNE SNF_Found
		INC bamLd+1
		BNE :+
		INC bamLd+2
:		LDA bamLd+1
		CMP #<BAM_END
		BNE SNF_Scan
		LDA bamLd+2
		CMP #>BAM_END
		BNE SNF_Scan
		LoadB bamLd+1, <BAM_ADDR
		LoadB bamLd+2, >BAM_ADDR
		DEC bamPass
		BNE SNF_Scan
		JSR BamOff
		LDX #INSUFF_SPACE
		RTS
SNF_Found:	STA bamTmp
		JSR BamOff
		LDY #0				; lowest free block in that byte
		LDA bamTmp
:		LSR
		BCS :+
		INY
		BNE :-
:		STY bamTmp
		; offset in BAM: track-1 = offset/32, sector = (offset%32)*8 + bit
		LDA bamLd+2
		SEC
		SBC #>BAM_ADDR
		ASL
		ASL
		ASL
		STA bamTmp2
		LDA bamLd+1
		LSR
		LSR
		LSR
		LSR
		LSR
		ORA bamTmp2
		CLC
		ADC #1
		STA r6L
		LDA bamLd+1
		AND #%00011111
		ASL
		ASL
		ASL
		ORA bamTmp
		STA r6H
SNF_Alloc:	MoveW r6, r3

;---------------------------------------
_AllocateBlock:	JSR __FindBAMBit
		BEQ AlloBlk1			; used or not on the disk
		JSR BamOn
		JSR bamLd
		EOR r8H
		JSR bamSt
		JSR BamOff
		JSR BamDirty
		LDA curDirHead+OFF_BIG_FREE
		BNE :+
		DEC curDirHead+OFF_BIG_FREE+1
:		DEC curDirHead+OFF_BIG_FREE
		LDX #0
		RTS
AlloBlk1:	LDX #BAD_BAM
		RTS

;---------------------------------------
__FreeBlock:
		JSR BamAddr
		BCS FreeBlk0			; not on the disk
		JSR __FindBAMBit
		BNE FreeBlk0			; already free
		JSR BamOn
		JSR bamLd
		ORA r8H
		JSR bamSt
		JSR BamOff
		JSR BamDirty
		IncW curDirHead+OFF_BIG_FREE
		LDX #0
		RTS
FreeBlk0:	LDX #BAD_BAM
		RTS

;---------------------------------------
; r6 - track and sector, returns Z=1 if allocated (or not on the disk), r8H - bit mask
__FindBAMBit:
		JSR BamAddr
		BCS @bad
		JSR BamOn
		JSR bamLd
		AND r8H
		STA bamTmp
		JSR BamOff
		LDX #0
		LDA bamTmp
		RTS
@bad:		LDX #INV_TRACK
		LDA #0
		RTS

;---------------------------------------
; point bamLd/bamSt at the BAM byte of block r6, its bit mask into r8H
; returns C=1 if r6 isn't on the disk, destroys A, X
BamAddr:	LDA r6L
		CMP #DIR_TRACK			; DESK TOP's directory track is track 1
		BNE :+
		LDA #1
:		CMP #1
		BCC @bad			; there is no track 0
		CMP #BIG_TRACKS+1
		BCS @bad
		SBC #0				; C=0: track-1
		PHA
		LSR
		LSR
		LSR
		CLC
		ADC #>BAM_ADDR
		STA bamLd+2
		STA bamSt+2
		PLA
		AND #%00000111
		ASL
		ASL
		ASL
		ASL
		ASL
		STA bamTmp
		LDA r6H
		LSR
		LSR
		LSR
		ORA bamTmp
		STA bamLd+1
		STA bamSt+1
		LDA r6H
		AND #%00000111
		TAX
		LDA FBBBitTab,x
		STA r8H
		CLC
		RTS
@bad:		SEC
		RTS

bamLd:		LDA BAM_ADDR
		RTS
bamSt:		STA BAM_ADDR
		RTS

;---------------------------------------
; mark the BAM block holding the byte bamLd points to as changed
BamDirty:	LDA bamLd+2
		SEC
		SBC #>BAM_ADDR
		PHA
		AND #%00000111
		TAX
		LDA FBBBitTab,x
		STA bamTmp
		PLA
		LSR
		LSR
		LSR
		TAX
		LDA bamDirty,x
		ORA bamTmp
		STA bamDirty,x
		RTS

;---------------------------------------
; map the BAM bank in at $4000-$7FFF with interrupts off and NMIs only counting frames
; BamOff restores that, both preserve X and Y
BamOn:		PHP
		PLA
		STA bamP
		SEI
		MoveB interrupt_lock, bamLock
		LoadB interrupt_lock, $ff
		MoveB PIA_PORTB, bamPB
		MoveB atari_banks+BAM_BANK, PIA_PORTB
		RTS
BamOff:		MoveB bamPB, PIA_PORTB
		MoveB bamLock, interrupt_lock
		LDA bamP
		PHA
		PLP
		RTS

;---------------------------------------
; after reading dirHead: make the BAM in memory match it, returns error code in X
BamSync:	LDX #3				; a big volume?
:		LDA curDirHead+OFF_BIG_MAGIC,x
		CMP BigMagic,x
		BNE @notbig
		DEX
		BPL :-
		BIT bamValid
		BPL @full
		LDX #3				; the same volume and BAM as in memory?
:		LDA curDirHead+OFF_BIG_SERIAL,x
		CMP bamKey,x
		BNE @full
		DEX
		BPL :-
		LDA #0				; yes, only drop the changes not written by PutDirHead
		STA bamBlk
@chg:		JSR BamBlkBit
		AND bamDirty,x
		BEQ :+
		JSR BamReadBlk
		bnex @err
:		INC bamBlk
		LDA bamBlk
		CMP #BAM_BLOCKS
		BNE @chg
		BEQ @ok
@full:		LoadB bamValid, 0
		LoadB bamBlk, 0
:		JSR BamReadBlk
		bnex @err
		INC bamBlk
		LDA bamBlk
		CMP #BAM_BLOCKS
		BNE :-
		LDX #3
:		LDA curDirHead+OFF_BIG_SERIAL,x
		STA bamKey,x
		DEX
		BPL :-
		LoadB bamValid, $ff
@ok:		JSR BamClean
		LDX #0
		BEQ @end
@notbig:	LoadB bamValid, 0		; not ours (or not formatted), nothing to keep in memory
		LDX #0
@err:
@end:		JSR SetDirHead			; GetDirHead leaves r1/r4 at dirHead
		TXA
		RTS

; changes are written into BAM blocks by PutDirHead, returns error code in X
BamFlush:	BIT bamValid
		BPL @end
		LDA #0
		STA bamBlk
		STA bamTmp2			; nothing written yet
@loop:		JSR BamBlkBit
		AND bamDirty,x
		BEQ :+
		JSR BamWriteBlk
		bnex @err
		STX bamDirtyAny			; X=0
		DEC bamTmp2
:		INC bamBlk
		LDA bamBlk
		CMP #BAM_BLOCKS
		BNE @loop
		JSR BamClean
		LDA bamTmp2
		BEQ @end
		IncW curDirHead+OFF_BIG_SERIAL	; the BAM on disk changed
		LDX #3
:		LDA curDirHead+OFF_BIG_SERIAL,x
		STA bamKey,x
		DEX
		BPL :-
@end:		LDX #0
@err:		RTS

; bit mask of BAM block bamBlk in A, its byte in bamDirty in X
BamBlkBit:	LDA bamBlk
		AND #%00000111
		TAX
		LDA FBBBitTab,x
		PHA
		LDA bamBlk
		LSR
		LSR
		LSR
		TAX
		PLA
		RTS

BamClean:	LDA #0
		LDX #3
:		STA bamDirty,x
		DEX
		BPL :-
		RTS

; read/write BAM block bamBlk directly into/from the bank, returns error code in X
BamReadBlk:	LDA #<__GetBlock
		LDX #>__GetBlock
		BNE BamIOBlk
BamWriteBlk:	LDA #<__PutBlock
		LDX #>__PutBlock
BamIOBlk:	STA @io+1
		STX @io+2
		LoadB r1L, RAM_DIR_TRACK
		LDA bamBlk
		CLC
		ADC #BAM_SECTOR
		STA r1H
		LoadB r4L, <BAM_ADDR
		LDA bamBlk
		CLC
		ADC #>BAM_ADDR
		STA r4H
		JSR BamOn
@io:		JSR $ffff
		JSR BamOff
		TXA
		RTS

BigMagic:	.byte "BIG1"

FBBBitTab:	.byte $01, $02, $04, $08
		.byte $10, $20, $40, $80
;---------------------------------------
__GetFreeDirBlk:
		PHP
		SEI
		PushB r6L
		PushW r2
		LDX r10L
		INX
		STX r6L
		MoveW curDirHead, r1			; get t&s from directory header
GFDirBlk0:	JSR ReadBuff
GFDirBlk1:	bnex GFDirBlk5
		DEC r6L
		BEQ GFDirBlk3
GFDirBlk11:	LDA diskBlkBuf
		BNE GFDirBlk2
		JSR AddDirBlock
		bra GFDirBlk1
GFDirBlk2:	STA r1L
		MoveB diskBlkBuf+1, r1H
		bra GFDirBlk0
GFDirBlk3:	LDY #FRST_FILE_ENTRY
		LDX #0
GFDirBlk4:	LDA diskBlkBuf,y
		BEQ GFDirBlk5
		TYA
		addv OFF_NXT_FILE
		TAY
		BCC GFDirBlk4
		LoadB r6L, 1
		LDX #FULL_DIRECTORY
		LDY r10L
		INY
		STY r10L
		CPY #$7f				; last sector on track (presumably DIR_TRACK)
		BCC GFDirBlk11
GFDirBlk5:	PopW r2
		PopB r6L
		PLP
		RTS

;---------------------------------------
_AddDirBlock:
		PushW r6
		LoadB r3L, 1			; start from start of the disk
		LoadB r3H, 0
		JSR SetNextFree
		bnex @end			; error
		MoveW r3, diskBlkBuf
		JSR WriteBuff
		bnex @end
		MoveW r3, r1
		JSR ClearAndWrite
@end:		PopW r6
		RTS

;---------------------------------------
__BlkAlloc:
		LDY #1
		STY r3L
		DEY
		STY r3H
__NxtBlkAlloc:	PushW r9
		PushW r3
		LoadW r3, $00fe
		LDX #r2
		LDY #r3
		JSR Ddiv
		LDA r8L
		BEQ BlkAlc0
		IncW r2
BlkAlc0:	LoadW r5, curDirHead
		JSR CalcBlksFree
		PopW r3
		LDX #INSUFF_SPACE
		CmpW r2, r4
		BEQ BlkAlc1
		BCS BlkAlc4
BlkAlc1:	MoveW r6, r4
		MoveW r2, r5
BlkAlc2:	JSR SetNextFree
		bnex BlkAlc4
		LDY #0
		LDA r3L
		STA (r4),y
		INY
		LDA r3H
		STA (r4),y
		AddVW 2, r4
		DecW r5
		LDA r5L
		ORA r5H
		BNE BlkAlc2
		LDY #0
		TYA
		STA (r4),y
		INY
		LDA r8L
		BNE BlkAlc3
		LDA #$fe
BlkAlc3:	addv 1
		STA (r4),y
		LDX #0
BlkAlc4:	PopW r9
		RTS

;---------------------------------------
;---------------------------------------
__ChangeDiskDevice:			;these are unused
		STA curDrive
		STA curDevice
__NewDisk:
__PurgeTurbo:
__ExitTurbo:
GetDOSError:
__I9042:
		LDX #0
		RTS
;---------------------------------------
__SetGEOSDisk:				; not necessary, but keep it for reference
		jsr GetDirHead
		bnex @end

		LoadW r5, curDirHead
		jsr CalcBlksFree	; any free blocks
		ldx #INSUFF_SPACE
		lda r4L
		ora r4H
		beq @end		; no space left for off-page (border) dir

		LoadB r3L, 1		; start search at (1,0)
		LoadB r3H, 0
		jsr SetNextFree
		bnex @end

		MoveW r3, r1
		jsr ClearAndWrite
		bnex @end
		MoveW r1, curDirHead+OFF_OP_TR_SC

		ldy #OFF_GS_ID+15
		ldx #15
:		lda GEOSDiskID,x
		sta curDirHead,y
		dey
		dex
		bpl :-
		jsr PutDirHead
@end:		rts
;---------------------------------------
__EnterTurbo:
		LDA curDrive
		JMP SetDevice		; needed?
;---------------------------------------
__ChkDkGEOS:
		ldy #OFF_GS_ID
		ldx #0
		LoadB isGEOS, 0

:		lda (r5),y
		cmp GEOSDiskID,x
		bne :+
		iny
		inx
		cpx #11
		bne :-
		LoadB isGEOS, $ff

:		lda isGEOS
		rts

;---------------------------------------
__OpenDisk:	;JSR NewDisk		; not needed
		;bnex :+
		JSR GetDirHead
		bnex :+
		LoadW r5, curDirHead
		JSR ChkDkGEOS
		LoadW r4, curDirHead+OFF_DISK_NAME
		LDX #r5
		JSR GetPtrCurDkNm
		LDX #r4
		LDY #r5
		LDA #18
		JSR CopyFString
:		RTS
;---------------------------------------
__PutDirHead:	JSR BamFlush
		bnex :+
		JSR SetDirHead
		bra __PutBlock
:		RTS
_WriteBuff:	JSR SetBufVector
__PutBlock:	JSR InitForIO
		JSR WriteBlock
		JMP DoneWithIO
;---------------------------------------
__GetDirHead:	JSR SetDirHead
		JSR __GetBlock
		bnex :+
		JMP BamSync
:		RTS
_ReadBuff:	JSR SetBufVector
__GetBlock:	JSR InitForIO
		JSR ReadBlock
		JMP DoneWithIO
;---------------------------------------
.include "drv/sio-core.inc"
.include "drv/sio-call.inc"
;---------------------------------------
; convert GEOS track and sector in r1 into SIO sector number in sioAux
; (track-1)*256+sector+SIO_FIRST_SECTOR, track 18 is mapped into track 1 (for DESK TOP 64)
; r1 is not changed, returns error code in X
SioSector:	LDX #INV_TRACK
		LDA r1L
		CMP #DIR_TRACK
		BNE :+
		LDA #RAM_DIR_TRACK
:		CMP #1
		BCC @end			; there is no track 0
		CMP #BIG_TRACKS+1
		BCS @end			; past the end of disk
		SBC #0				; C=0: track-1
		STA sioAux+1
		LDA r1H
		CLC
		ADC #<SIO_FIRST_SECTOR
		STA sioAux
		LDA sioAux+1
		ADC #>SIO_FIRST_SECTOR
		STA sioAux+1
		LDX #0
@end:		RTS


;---------------------------------------
SetBufVector:	LoadW r4, diskBlkBuf
		RTS
;---------------------------------------
SetDirHead:	LoadB r1L, RAM_DIR_TRACK
		LoadB r1H, RAM_DIR_SECT_HEAD
		LoadW r4, curDirHead
		RTS
;---------------------------------------
__InitForIO:
; do nothing - if that is supposed to enable OS ROM functions
; it should be part of GEOS Kernal, not the disk driver (that was required on C64/128)
; NMIs are limited to frame counting in SioBlock
		PHP
		PopB tmpPS
		SEI
		RTS
;---------------------------------------
__DoneWithIO:	; this procedure can't change X register (error code)
		SEI
		PushB tmpPS
		PLP
		RTS
;---------------------------------------

GEOSDiskID:	.byte "GEOS format V1.0",0

;---------------------------------------
borderFlag:	.res 1		; do we have border directory sector?
tmpPS:		.res 1		; CPU flags after DoneWithIO


bamValid:	.byte 0		; $ff - BAM of the volume bamKey is in the bank
bamKey:		.res 4		; OFF_BIG_SERIAL and OFF_BIG_VOLID of that BAM
bamDirty:	.res 4		; BAM blocks changed since PutDirHead, bit per block
bamDirtyAny:	.res 1
bamBlk:		.res 1		; BAM block being read/written
bamPass:	.res 1
bamTmp:		.res 1
bamTmp2:	.res 1
bamP:		.res 1		; CPU flags, interrupt_lock and PORTB before BamOn
bamLock:	.res 1
bamPB:		.res 1

.include "drv/sio-vars.inc"
