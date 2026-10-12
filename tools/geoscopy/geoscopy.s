; GEOSCOPY - copy a GEOS (or any) double density disk sector by sector
; between two SIO drives, e.g. from a FujiNet mounted ATR to a real XF551 floppy.
; Atari DOS can't do that, it only copies sectors that are in use according to DOS VTOC.
; Optionally formats the destination disk (single or double sided double density) first.
;
; runs under Atari OS (uses CIO and SIOV), build with:
; ca65 -t atari geoscopy.s && ld65 -C atari-asm-xex.cfg -o GEOSCOPY.XEX geoscopy.o

.include "atari.inc"

.export start

ZPTR		= $80				; string pointer for Print

CMD_READ	= $52
CMD_WRITE	= $57				; write with verify
CMD_FORMAT	= $21
CMD_PERCOM_PUT	= $4f

DSTATS_READ	= $40
DSTATS_WRITE	= $80

.segment "CODE"

start:		ldx #$10			; IOCB #1 for keyboard
		lda #CLOSE
		sta ICCOM,x
		jsr CIOV
		ldx #$10
		lda #OPEN
		sta ICCOM,x
		lda #<kname
		sta ICBAL,x
		lda #>kname
		sta ICBAH,x
		lda #4				; read
		sta ICAX1,x
		lda #0
		sta ICAX2,x
		jsr CIOV

menu:		ldy #<txtTitle
		lda #>txtTitle
		jsr Print

		ldy #<txtSource
		lda #>txtSource
		jsr Print
		jsr GetDrive
		sta srcUnit

		ldy #<txtDest
		lda #>txtDest
		jsr Print
		jsr GetDrive
		sta dstUnit
		cmp srcUnit
		bne :+
		ldy #<txtSame
		lda #>txtSame
		jsr Print
		jmp menu

:		ldy #<txtFormat
		lda #>txtFormat
		jsr Print
@fmtkey:	jsr GetKey
		ldx #0				; sides-1 for PERCOM
		cmp #'S'
		beq @fmt
		inx
		cmp #'D'
		beq @fmt
		cmp #'N'
		bne @fmtkey
		ldx #$ff			; don't format
@fmt:		stx formatSides
		jsr PutChar
		jsr NewLine

		; confirm
		ldy #<txtConfirm1
		lda #>txtConfirm1
		jsr Print
		lda srcUnit
		jsr PrintDrive
		ldy #<txtConfirm2
		lda #>txtConfirm2
		jsr Print
		lda dstUnit
		jsr PrintDrive
		ldy #<txtConfirm3
		lda #>txtConfirm3
		jsr Print
		jsr GetKey
		cmp #'Y'
		beq :+
		jmp menu
:		jsr PutChar
		jsr NewLine

		lda formatSides
		bmi @copy
		jsr Format
		bcc @copy
		jsr Failed
		jmp menu

@copy:		jsr Copy
		jmp menu

;---------------------------------------
; format destination as double density, formatSides: 0 - single sided, 1 - double sided
Format:		ldy #<txtFormatting
		lda #>txtFormatting
		jsr Print
		lda formatSides
		sta percom+4
		lda dstUnit
		sta DUNIT
		lda #CMD_PERCOM_PUT
		sta DCOMND
		lda #DSTATS_WRITE
		sta DSTATS
		lda #<percom
		sta DBUFLO
		lda #>percom
		sta DBUFHI
		lda #12
		ldx #0
		jsr SioCall
		bcs @end
		lda dstUnit
		sta DUNIT
		lda #CMD_FORMAT
		sta DCOMND
		lda #DSTATS_READ
		sta DSTATS
		jsr SetBuffer
		lda #0				; 256 bytes (list of bad sectors)
		ldx #1
		ldy #$e0			; formatting takes long
		jsr SioCallTimeout
@end:		rts

;---------------------------------------
; copy all sectors from srcUnit to dstUnit until source can't be read anymore
Copy:		ldy #<txtCopying
		lda #>txtCopying
		jsr Print
		lda #1
		sta sector
		lda #0
		sta sector+1

@loop:		lda srcUnit
		sta DUNIT
		lda #CMD_READ
		sta DCOMND
		lda #DSTATS_READ
		sta DSTATS
		jsr SetBuffer
		jsr SectorSize
		jsr SioCall
		bcc @write
		; can't read - that is the end of source disk (or a real error)
		sty lastError
		jsr NewLine
		jsr PrintCount
		ldy #<txtEnd
		lda #>txtEnd
		jsr Print
		lda lastError
		jsr PrintHex
		ldy #<txtEnd2
		lda #>txtEnd2
		jsr Print
		jmp WaitKey

@write:		lda dstUnit
		sta DUNIT
		lda #CMD_WRITE
		sta DCOMND
		lda #DSTATS_WRITE
		sta DSTATS
		jsr SetBuffer
		jsr SectorSize
		jsr SioCall
		bcc @next
		sty lastError
		jsr NewLine
		ldy #<txtWriteErr
		lda #>txtWriteErr
		jsr Print
		lda lastError
		jsr PrintHex
		jsr NewLine
		jsr PrintCount
		ldy #<txtCopied
		lda #>txtCopied
		jsr Print
		jmp WaitKey

@next:		lda sector			; progress dot every 16 sectors
		and #$0f
		bne :+
		lda #'.'
		jsr PutChar
:		inc sector
		bne :+
		inc sector+1
		beq :++				; wrapped around 65535
:		jmp @loop
:		rts

;---------------------------------------
; A/X - DBYT, sector number into DAUX
SectorSize:	lda sector+1
		bne @dd
		lda sector
		cmp #4
		bcs @dd
		lda #128			; boot sectors 1-3 are always 128 bytes
		ldx #0
		beq @aux
@dd:		lda #0
		ldx #1
@aux:		pha
		lda sector
		sta DAUX1
		lda sector+1
		sta DAUX2
		pla
		rts

SetBuffer:	lda #<buffer
		sta DBUFLO
		lda #>buffer
		sta DBUFHI
		rts

;---------------------------------------
; DDEVIC/DCOMND/DSTATS/DUNIT/DBUF set, A/X - length
; returns C=1 on error, Y - status
SioCall:	ldy #7
SioCallTimeout:	sta DBYTLO
		stx DBYTHI
		sty DTIMLO
		lda #$31
		sta DDEVIC
		jsr SIOV
		cpy #$80
		rts

;---------------------------------------
Failed:		sty lastError
		jsr NewLine
		ldy #<txtFailed
		lda #>txtFailed
		jsr Print
		lda lastError
		jsr PrintHex
		jsr NewLine
WaitKey:	ldy #<txtAnyKey
		lda #>txtAnyKey
		jsr Print
		jmp GetKey

;---------------------------------------
; ask for drive 1-8, returns 1-8 in A
GetDrive:	jsr GetKey
		cmp #'1'
		bcc GetDrive
		cmp #'9'
		bcs GetDrive
		jsr PutChar
		pha
		jsr NewLine
		pla
		sec
		sbc #'0'
		rts

GetKey:		ldx #$10
		lda #GETCHR
		sta ICCOM,x
		lda #0
		sta ICBLL,x
		sta ICBLH,x
		jsr CIOV
		cmp #'a'			; to upper case
		bcc :+
		cmp #'z'+1
		bcs :+
		and #$df
:		rts

;---------------------------------------
PrintDrive:	pha
		lda #'D'
		jsr PutChar
		pla
		ora #'0'
		jsr PutChar
		lda #':'
		jmp PutChar

; "nnnnn sectors"
PrintCount:	lda sector			; number of sectors done = sector-1
		sec
		sbc #1
		sta num
		lda sector+1
		sbc #0
		sta num+1
		jsr PrintDec
		ldy #<txtSectors
		lda #>txtSectors
		jmp Print

; print num as decimal (16 bit)
PrintDec:	ldx #4
@digit:		lda #0
		ldy #16				; num /= 10, remainder in A
@div:		asl num
		rol num+1
		rol
		cmp #10
		bcc :+
		sbc #10
		inc num
:		dey
		bne @div
		sta digits,x
		dex
		bpl @digit
		ldx #0				; skip leading zeros
:		lda digits,x
		bne @out
		inx
		cpx #4
		bne :-
@out:		lda digits,x
		ora #'0'
		stx num
		jsr PutChar
		ldx num
		inx
		cpx #5
		bne @out
		rts

PrintHex:	pha
		lda #'$'
		jsr PutChar
		pla
		pha
		lsr
		lsr
		lsr
		lsr
		jsr @nibble
		pla
		and #$0f
@nibble:	cmp #10
		bcc :+
		adc #'A'-'0'-10-1
:		adc #'0'
		jmp PutChar

NewLine:	lda #EOL
PutChar:	ldx #0				; IOCB #0 is screen editor
		pha
		lda #PUTCHR
		sta ICCOM,x
		lda #0
		sta ICBLL,x
		sta ICBLH,x
		pla
		pha
		jsr CIOV
		pla
		rts

; print zero terminated string at A/Y (hi/lo)
Print:		sty ZPTR
		sta ZPTR+1
		ldy #0
:		lda (ZPTR),y
		beq :+
		sty savey
		jsr PutChar
		ldy savey
		iny
		bne :-
:		rts

;---------------------------------------
.segment "RODATA"

kname:		.byte "K:", EOL

txtTitle:	.byte CLS, "GEOS disk copier", EOL
		.byte "Copies every sector of a double", EOL
		.byte "density disk to another drive.", EOL, EOL, 0
txtSource:	.byte "SOURCE drive (1-8)? ", 0
txtDest:	.byte "DESTINATION drive (1-8)? ", 0
txtSame:	.byte "Drives must be different!", EOL, 0
txtFormat:	.byte "Format destination first?", EOL
		.byte " S - single sided DD (180K)", EOL
		.byte " D - double sided DD (360K)", EOL
		.byte " N - no, already formatted DD", EOL
		.byte "? ", 0
txtConfirm1:	.byte EOL, "Copy ", 0
txtConfirm2:	.byte " to ", 0
txtConfirm3:	.byte EOL, "ALL DATA ON DESTINATION WILL BE LOST!", EOL
		.byte "Start (Y/N)? ", 0
txtFormatting:	.byte "Formatting...", EOL, 0
txtCopying:	.byte "Copying", 0
txtSectors:	.byte " sectors", 0
txtEnd:		.byte " copied.", EOL
		.byte "Source ended at next sector with", EOL
		.byte "status ", 0
txtEnd2:	.byte " - normal at end of disk.", EOL
		.byte "180K GEOS disk: 720 sectors,", EOL
		.byte "280K GEOS disk: 1123 sectors.", EOL, 0
txtWriteErr:	.byte "Write error, status ", 0
txtCopied:	.byte " copied before the error.", EOL, 0
txtFailed:	.byte "Format failed, status ", 0
txtAnyKey:	.byte EOL, "Press any key.", EOL, 0

; PERCOM block for 40 tracks, 18 sectors per track, 256 bytes per sector (MFM)
percom:		.byte 40, 1, 0, 18, 0, 4, 1, 0, $ff, 0, 0, 0

.segment "BSS"

srcUnit:	.res 1
dstUnit:	.res 1
formatSides:	.res 1				; $ff - no format
sector:		.res 2
lastError:	.res 1
num:		.res 2
digits:		.res 5
savey:		.res 1
buffer:		.res 256
