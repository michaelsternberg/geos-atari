
; Atari SIO disk drive (D1: by default; 810/1050 style drives, XF551, SIO2PC, FujiNet...)

; Filesystem part based on Atari RAM drive by Maciej Witkowiak, 2022
; SIO part talks to POKEY directly, OS ROM is not used (GEOS Kernal lives under it)

; Disk layout:
; double density (256 bytes per sector) disk or ATR image is required
; sectors 1-3 (128 bytes each, boot sectors) are not used
; GEOS block (track, sector) maps linearly to SIO sector (track-1)*128+sector+SIO_FIRST_SECTOR
; same as RAM drive: 128 sectors per track, track 18 (DESK TOP directory) is mapped to track 1
; (1,0) - dirHead with BAM for SIO_BLOCKS blocks
; use tools/mkramdisk.py --atr to create a disk image

; XXX there is no check for max track/sector in BAM ops
; XXX there is no check for write protection, there is no high speed SIO

; number of 256-byte sectors used by GEOS, 720-3 for a standard 180K double density disk
.ifndef SIO_BLOCKS
SIO_BLOCKS		= 717
.endif
; SIO device of GEOS device 8 (1=D1:)
.ifndef SIO_UNIT
SIO_UNIT		= 1
.endif

SIO_FIRST_SECTOR	= 4			; skip over 128-byte boot sectors
SIO_DEVICE		= $31+SIO_UNIT-1	; SIO device ID for D<SIO_UNIT>:

SIO_RETRIES		= 4			; how many times to repeat failed transfer
SIO_TIMEOUT_ACK		= 3			; in frames (16ms is required)
SIO_TIMEOUT_CMPL	= 255			; in frames (drive may need to seek and retry)
SIO_TIMEOUT_BYTE	= 3			; in frames, between bytes of a data frame

; delays in scanlines (~64us each)
SIO_DELAY_T0		= 14			; COMMAND low to command frame (750-1600us)
SIO_DELAY_T1		= 12			; end of command frame to COMMAND high (650-950us)
SIO_DELAY_T3		= 20			; ACK to data frame sent by computer (min 1000us)

SIO_CMD_READ		= $52			; 'R'
SIO_CMD_PUT		= $50			; 'P' - write without verify
SIO_CMD_WRITE		= $57			; 'W' - write with verify

SIO_ACK			= $41			; 'A'
SIO_NAK			= $4e			; 'N'
SIO_COMPLETE		= $43			; 'C'
SIO_ERROR		= $45			; 'E'

RAM_DIR_TRACK		= 1
RAM_DIR_SECT_HEAD	= 0

; BAM in curDirHead
BAMLength		= (SIO_BLOCKS+7)/8

.include "inc/const.inc"
.include "inc/jumptab.inc"
.include "inc/geossym.inc"
.include "inc/geosmac.inc"
.include "inc/atari.inc"

; GEOS will fill those in
.import interrupt_lock
.import jiffyCounter

.segment "drive"

.assert * = $9000, error, "Disk driver not at $9000"

.assert OFF_TO_BAM+BAMLength <= OFF_DISK_NAME, error, "BAM overlaps disk name in disk header (SIO_BLOCKS too large)"
.assert SIO_FIRST_SECTOR+SIO_BLOCKS <= $10000, error, "SIO_BLOCKS too large"
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
;---------------------------------------
__CalcBlksFree:
		LoadW r4, 0
		LDY #OFF_TO_BAM
@loop:		LDA (r5),y
		BEQ @nxt			; fully occupied
		LDX #0
:		LSR				; sum bits
		BCC :+
		IncW r4
:		INX
		CPX #8
		BNE :--
@nxt:		INY
		CPY #BAMLength+OFF_TO_BAM
		BNE @loop
		; total number of blocks
		LoadW r3, SIO_BLOCKS
		RTS


;---------------------------------------
__SetNextFree:	MoveW r3, r6
		JSR FindBAMBit
		BNE AlloBlk0
SNF_Search:	LDA curDirHead,x
		BNE SNF_FoundByte
		INX
		CPX #BAMLength+OFF_TO_BAM
		BNE SNF_Search
		LDX #INSUFF_SPACE
		RTS

SNF_FoundByte:	LDY #0
SNF_Search2:	LSR
		BCS SNF_FoundBit
		INY
		CPY #7
		BNE SNF_Search2

SNF_FoundBit:	TXA
		SEC
		SBC #OFF_TO_BAM
		TAX
		LSR
		LSR
		LSR
		LSR
		STA r3L
		INC r3L
		TXA
		AND #%00001111
		ASL
		ASL
		ASL
		STA r3H
		TYA
		CLC
		ADC r3H
		STA r3H
		MoveW r3, r6

_AllocateBlock:	JSR FindBAMBit
		BEQ AlloBlk1
AlloBlk0:	LDA r8H
		EOR #$ff
		AND curDirHead,x
		STA curDirHead,x
		LDX #0
		RTS
AlloBlk1:	LDX #BAD_BAM
		RTS

;---------------------------------------
__FreeBlock:
		JSR FindBAMBit
		BNE FreeBlk0
		LDA r8H
		EOR curDirHead,x
		STA curDirHead,x
		LDX #0
		RTS
FreeBlk0:	LDX #BAD_BAM
		RTS

;---------------------------------------
__FindBAMBit:
		PushW r6
		CmpBI r6L, DIR_TRACK		; is that DESK TOP trying to allocate from the middle of the disk?
		bne :+
		LoadB r6L, 1			; map it to track 1 anyway
; there is no track 0
:		DEC r6L
; convert to page address (note reversed L/H) - bring 1st bit of L into last bit of H
		ASL r6H
		LSR r6L
		ROR r6H
		; get bit number
		LDA r6H
		AND #%00000111
		TAX
		LDA FBBBitTab,x
		STA r8H
		; divide page number by 8 (reversed L/H)
		LSR r6L
		ROR r6H
		LSR r6L
		ROR r6H
		LSR r6L
		ROR r6H
		LDA r6H
		STA r7H				; offset inside BAM
		CLC
		ADC #OFF_TO_BAM
		TAX				; offset to dir header
		PopW r6
		LDA curDirHead,x
		AND r8H
		RTS

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
__PutDirHead:	JSR SetDirHead
		bra __PutBlock
_WriteBuff:	JSR SetBufVector
__PutBlock:	JSR InitForIO
		JSR WriteBlock
		JMP DoneWithIO
;---------------------------------------
__GetDirHead:	JSR SetDirHead
		bra __GetBlock
_ReadBuff:	JSR SetBufVector
__GetBlock:	JSR InitForIO
		JSR ReadBlock
		JMP DoneWithIO
;---------------------------------------
; there is no banked RAM involved, (r4) is accessed directly
_ReadLink:
__ReadBlock:	LDY #0
		LDA #SIO_CMD_READ
		BNE SioBlock
;---------------------------------------
__WriteBlock:	LDY #0
		LDA #SIO_CMD_PUT
		BNE SioBlock
;---------------------------------------
; called after WriteBlock (when verifyFlag is set), read back and compare with (r4)
__VerWriteBlock:
		LDY #$ff
		LDA #SIO_CMD_READ
;---------------------------------------
; A - SIO command, Y - $ff to compare read data with (r4) instead of storing it
; r1 - track and sector, r4 - buffer
; returns error code in X (and A)
SioBlock:	STY sioVerify
		STA sioCommand
		JSR SioSector
		bnex @end
		LoadB sioDevice, SIO_DEVICE
		PHP
		SEI
		; NMI handler will only count frames, it's needed for timeouts
		LoadB interrupt_lock, $ff
		LoadB sioRetry, SIO_RETRIES
@retry:		JSR SioTransfer
		beqx @done
		DEC sioRetry
		BNE @retry
@done:		JSR SioIdle
		LoadB interrupt_lock, 0
		PLP
@end:		TXA
		RTS

;---------------------------------------
; convert GEOS track and sector in r1 into SIO sector number in sioAux
; (track-1)*128+sector+SIO_FIRST_SECTOR, track 18 is mapped into track 1 (for DESK TOP 64)
; r1 is not changed, returns error code in X
SioSector:	LDX #INV_TRACK
		LDA r1H
		BMI @end			; sector >=128
		LDA r1L
		CMP #DIR_TRACK
		BNE :+
		LDA #RAM_DIR_TRACK
:		CMP #1
		BCC @end			; there is no track 0
		SBC #1				; (C=1)
		LSR				; lowest bit of track-1 goes into bit 7 of low byte
		STA sioAux+1
		LDA #0
		ROR
		ORA r1H
		CLC
		ADC #<SIO_FIRST_SECTOR
		STA sioAux
		LDA sioAux+1
		ADC #>SIO_FIRST_SECTOR
		STA sioAux+1
		; past the end of disk?
		LDA sioAux
		CMP #<(SIO_FIRST_SECTOR+SIO_BLOCKS)
		LDA sioAux+1
		SBC #>(SIO_FIRST_SECTOR+SIO_BLOCKS)
		BCS @end
		LDX #0
@end:		RTS

;---------------------------------------
; single attempt of SIO command from sioFrame, returns error code in X
SioTransfer:
		; 19200 baud
		LoadB POKEY_AUDCTL, POKEY_AUDCTL_SIO
		LoadB POKEY_AUDF3, POKEY_SIO_19200
		LoadB POKEY_AUDF4, 0
		LDA #$a0			; pure tone, no volume
		STA POKEY_AUDC3
		STA POKEY_AUDC4

		; command frame
		LoadB PIA_PBCTL, PIA_CTL_CMD
		LDY #SIO_DELAY_T0
		JSR SioDelay
		JSR SioSendStart
		LDY #0
:		LDA sioFrame,y
		JSR SioPutByte
		INY
		CPY #4
		BNE :-
		LDA sioChksum
		JSR SioPutByte
		JSR SioSendEnd
		JSR SioRecvStart		; be ready before the device can answer
		LDY #SIO_DELAY_T1
		JSR SioDelay
		LoadB PIA_PBCTL, PIA_CTL_IDLE

		LDX #DEV_NOT_FOUND		; no answer, no device
		LDA #SIO_TIMEOUT_ACK
		JSR SioGetByte
		BCS @end
		LDX #INV_TRACK			; NAK - command or sector rejected
		CMP #SIO_ACK
		BNE @end

		LDA sioCommand
		CMP #SIO_CMD_READ
		BEQ SioReadData

		; write: send data frame
		LDY #SIO_DELAY_T3
		JSR SioDelay
		JSR SioSendStart
		LDY #0
:		LDA (r4),y
		JSR SioPutByte
		INY
		BNE :-
		LDA sioChksum
		JSR SioPutByte
		JSR SioSendEnd
		JSR SioRecvStart
		LDX #WR_VER_ERR
		LDA #SIO_TIMEOUT_ACK		; data frame accepted?
		JSR SioGetByte
		BCS @end
		CMP #SIO_ACK
		BNE @end
		LDA #SIO_TIMEOUT_CMPL		; written?
		JSR SioGetByte
		BCS @end
		CMP #SIO_COMPLETE
		BNE @end
		LDX #0
@end:		RTS

SioReadData:	LDX #DAT_CHKSUM_ERR
		LDA #SIO_TIMEOUT_CMPL		; complete or error, then data frame
		JSR SioGetByte
		BCS @end
		STA sioStatus
		LDA #0
		STA sioChksum			; checksum covers only the data
		STA sioMismatch
		LDY #0
@loop:		LDA #SIO_TIMEOUT_BYTE
		JSR SioGetByte
		BCS @end
		BIT sioVerify
		BMI @verify
		STA (r4),y
		INY
		BNE @loop
		BEQ @chksum
@verify:	CMP (r4),y
		BEQ :+
		STX sioMismatch			; any nonzero value
:		INY
		BNE @loop
@chksum:	MoveB sioChksum, sioStatus+1
		LDA #SIO_TIMEOUT_BYTE
		JSR SioGetByte
		BCS @end
		CMP sioStatus+1
		BNE @end
		LDA POKEY_SKSTAT		; framing error or overrun? (active low)
		AND #%11000000
		CMP #%11000000
		BNE @end
		LDA sioStatus
		CMP #SIO_COMPLETE
		BNE @end
		LDX #WR_VER_ERR
		LDA sioMismatch
		BNE @end
		LDX #0
@end:		RTS

;---------------------------------------
; restore POKEY and PIA state for keyboard scanning, preserves X
SioIdle:	LoadB POKEY_SKCTL, POKEY_SKCTL_KBD
		LoadB POKEY_IRQEN, POKEY_IRQ_KBD
		LoadB PIA_PBCTL, PIA_CTL_IDLE
		LDA #0
		STA POKEY_AUDC3
		STA POKEY_AUDC4
		STA POKEY_AUDCTL
		RTS

;---------------------------------------
; wait Y scanlines
SioDelay:	STA ANTIC_WSYNC
		DEY
		BNE SioDelay
		RTS

;---------------------------------------
; prepare POKEY for sending a frame, clear checksum
SioSendStart:	LDA #POKEY_SKCTL_TX
		STA POKEY_SKCTL
		STA POKEY_SKREST
		LDA #POKEY_IRQ_KBD
		STA POKEY_IRQEN
		LDA #POKEY_IRQ_KBD|POKEY_IRQ_SEROR|POKEY_IRQ_SEROC
		STA POKEY_IRQEN
		LDA #0
		STA sioChksum
		STA sioTxBusy
		RTS

;---------------------------------------
; send byte from A, add it to checksum, preserves X and Y
SioPutByte:	PHA
		CLC
		ADC sioChksum
		ADC #0
		STA sioChksum
		BIT sioTxBusy			; first byte goes straight to SEROUT
		BPL @put
:		LDA POKEY_IRQST			; wait until previous byte moves to shift register
		AND #POKEY_IRQ_SEROR
		BNE :-
		LDA #POKEY_IRQ_KBD|POKEY_IRQ_SEROC
		STA POKEY_IRQEN
		LDA #POKEY_IRQ_KBD|POKEY_IRQ_SEROR|POKEY_IRQ_SEROC
		STA POKEY_IRQEN
@put:		PLA
		STA POKEY_SEROUT
		LoadB sioTxBusy, $ff
		RTS

;---------------------------------------
; wait until the last byte is sent out
SioSendEnd:
:		LDA POKEY_IRQST			; last byte moved to shift register
		AND #POKEY_IRQ_SEROR
		BNE :-
:		LDA POKEY_IRQST			; and shifted out
		AND #POKEY_IRQ_SEROC
		BNE :-
		RTS

;---------------------------------------
; prepare POKEY for receiving bytes
SioRecvStart:	LDA #POKEY_SKCTL_RX
		STA POKEY_SKCTL
		STA POKEY_SKREST
		LDA #POKEY_IRQ_KBD
		STA POKEY_IRQEN
		LDA #POKEY_IRQ_KBD|POKEY_IRQ_SERIN
		STA POKEY_IRQEN
		RTS

;---------------------------------------
; receive byte into A, A on input is timeout in frames
; returns C=1 on timeout, adds byte to checksum, preserves X and Y
SioGetByte:	STA sioTicks
		LDA jiffyCounter
		STA sioJiffy
@wait:		LDA POKEY_IRQST
		AND #POKEY_IRQ_SERIN
		BEQ @got
		LDA jiffyCounter
		CMP sioJiffy
		BEQ @wait
		STA sioJiffy
		DEC sioTicks
		BNE @wait
		SEC
		RTS
@got:		LDA #POKEY_IRQ_KBD
		STA POKEY_IRQEN
		LDA #POKEY_IRQ_KBD|POKEY_IRQ_SERIN
		STA POKEY_IRQEN
		LDA POKEY_SERIN
		PHA
		CLC
		ADC sioChksum
		ADC #0
		STA sioChksum
		PLA
		CLC
		RTS

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

sioFrame:			; command frame, without checksum
sioDevice:	.res 1
sioCommand:	.res 1
sioAux:		.res 2		; sector number

sioVerify:	.res 1		; $ff - compare data with (r4) instead of storing it
sioMismatch:	.res 1		; nonzero if compare failed
sioRetry:	.res 1		; remaining attempts
sioStatus:	.res 2		; complete/error byte, data checksum
sioChksum:	.res 1		; checksum of current frame
sioTxBusy:	.res 1		; $ff if SEROUT got a byte in current frame
sioTicks:	.res 1		; timeout in frames
sioJiffy:	.res 1		; last seen frame counter

