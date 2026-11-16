; GEOS KERNAL by Berkeley Softworks
; reverse engineered by Maciej Witkowiak, Michael Steil
;
; Machine initialization

.include "const.inc"
.include "geossym.inc"
.include "geosmac.inc"
.include "config.inc"
.include "kernal.inc"

.import InitRamTab
.import _DoFirstInitIO
.import _InitRam
.import _FillRam
.import Player0Data

.global InitGEOEnv
.global _InitMachine

.segment "init1"

ASSERT_NOT_UNDER_ROM
; InitMachine can't be under ROM (because it calls DoFirstInitIO to disable ROM)

_InitMachine:
	jsr _DoFirstInitIO
InitGEOEnv:
	; clear all sprite data; mouseOn (which InitRamTab clears) off first: the NMI's ProcessMouse draws the pointer
	; and switches it on while it's set, and one between the fill's first page (the pointer's picture) and its last
	; (the sprites' variables, curEnable) would leave a picture there that nothing knows of: a second pointer
	lda #0
	sta r2L				; fill with 0
	sta mouseOn
	sta r1L				; r1 = Player0Data (on a page)
	sta r0L				; r0 = $0400
	lda #>Player0Data
	sta r1H
	lda #>$0400
	sta r0H
	jsr _FillRam
.assert <Player0Data = 0, error, "Player0Data must start on a page"
	LoadW r0, InitRamTab
	jmp _InitRam
