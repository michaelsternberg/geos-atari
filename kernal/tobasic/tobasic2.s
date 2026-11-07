; Maciej Witkowiak, 2022
; Atari code based on LNG

.include "const.inc"
.include "geossym.inc"
.include "geosmac.inc"
.include "config.inc"
.include "kernal.inc"
.include "atari.inc"

.global __ToBASIC

.segment "tobasic2"

ASSERT_IN_BANK0

__ToBASIC:
	; on the Atari a clean restart (DeskTop's "BASIC", and Panic): GEOS can't be gone back to from BASIC, and a
	; cold start boots D1: (GEOS's disk again, or FujiNet's CONFIG when it boots that). This can't be under ROM,
	; copy trampoline before running
	sei
	ldx #$ff
	txs
	inx
:	lda @tobasic,x
	sta $0100,x
	inx
	cpx #(@tobasicend-@tobasic+1)
	bne :-
	jmp $0100

@tobasic:
	; GEOS leaves the vertical blank NMI and its IRQs on, with their OS vectors (page 2) overwritten: off, or
	; they hang the OS's cold start
	lda #0
	sta ANTIC_NMIEN
	sta POKEY_IRQEN
	sta ANTIC_DMACTL
	lda #%11111111			; OS ROM in, BASIC and self-test out, main memory
	sta PIA_PORTB
	jmp $e477			; COLDSV: the OS's cold start
@tobasicend:
