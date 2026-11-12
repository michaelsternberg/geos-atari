; GEOS KERNAL by Berkeley Softworks
; reverse engineered by Maciej Witkowiak, Michael Steil
;
; IRQ/NMI handlers for Atari by Maciej Witkowiak, 2022

.include "const.inc"
.include "geossym.inc"
.include "geosmac.inc"
.include "config.inc"
.include "kernal.inc"
.include "atari.inc"

; keyboard.s
.import _DoKeyboardScan

; var.s
.import KbdQueFlag
.import KbdNextKey
.import KbdDBncTab
.import KbdScanHelp2
.import KbdQueTail
.import KbdQueue
.import alarmWarnFlag
.import tempIRQAcc
.import interrupt_lock
.import jiffyCounter
.import _DoUpdateTime

.import CallRoutine

; used by boot.s
.global _IRQHandler
.global _NMIHandler
.global _BRKHandler
; used by _DoKeyboardScan (possibly more than once)?
.global tmpPOKEY_IRQST

.segment "spritebuf"
tmpPOKEY_IRQST:	.res 1				; shadow register

.segment "irq"

kbdLastTail = KbdDBncTab			; the queue's tail the key repeat saw last (C64 GEOS's debounce table,
kbdRepCode = KbdDBncTab+1			; unused on the Atari), and the key's KBCODE
; SIO's PROCEED line (the PIA's CA1) seen: $ff. A program that enables its interrupt (PIA_PACTL bit 0) clears it and
; waits for it to be set again; FujiNet pulls PROCEED when a network channel has something for the computer. Its
; address is in the SIO call area (drv/sio-call.inc, version 3). With the interrupt off (as GEOS leaves it) it's
; never set: nothing else in GEOS uses PROCEED.
sioProceed = KbdDBncTab+2
.export sioProceed

	; IRQ from the keyboard or BRK; or PROCEED (the PIA's CA1), when a program has enabled it
_IRQHandler:
	cld
	sta tempIRQAcc
	pla
	pha
	and #%00010000				; was that BRK?
	beq :+
	pla					; why they (BSW) put it here? with that - Panic shows correct address, but without it BRKVector can return with simple RTI to caller (providing there is a NOP after BRK)
	jmp (BRKVector)
:	lda POKEY_IRQST				; was that break/keyboard irq? (bit=0 means 'yes')
	sta tmpPOKEY_IRQST
	eor #$ff				; cleared bits are set
	and #%11000000				; our sources are set?
	beq :+					; no?
	lda #0
	sta POKEY_IRQEN				; ack interrupts
	lda #%11000000
	sta POKEY_IRQEN				; re-enable interrupts from keyboard/break key
	txa
	pha
	tya
	pha
	lda tmpPOKEY_IRQST			; bit 7=0 is BREAK, bmi over and take mapped POKEY_KBCODE
	jsr _DoKeyboardScan
	pla
	tay
	pla
	tax
:	bit PIA_PACTL				; bit 7: CA1 (PROCEED) seen; an IRQ only when a program enabled it
	bpl :+
	lda PIA_PORTA				; acknowledged (reading PORTA clears bit 7)
	lda #$ff
	sta sioProceed
:	lda tempIRQAcc
	rti

_BRKHandler:					; in principle this is Panic
	rti

	; main interrupt called on every frame
_NMIHandler:
	sta ANTIC_NMIRES			; ack interrupt
	inc jiffyCounter			; time update
	bit interrupt_lock			; $ff when banked RAM is mapped in, test N because A is not loaded here
	bpl :+
	rti
:	pha
	txa
	pha
	tya
	pha
	PushW CallRLo
	PushW returnAddress

	ldx #0
:	lda r0,x
	pha
	inx
	cpx #32
	bne :-

	lda dblClickCount
	beq :+
	dec dblClickCount

	; key repeat: a new key in the queue (its tail moved: the keyboard interrupt, or a key the SIO driver caught)
	; is the one to repeat, after KEY_REPEAT_DELAY frames, then every KEY_REPEAT_RATE frames while POKEY says a
	; key is still held. KbdQueFlag counts the frames; run out it wraps round to 255, and a key held then is one
	; whose arrival set the count again.
:	lda KbdQueTail
	cmp kbdLastTail
	beq @held
	sta kbdLastTail
	tax
	dex				; the key before the tail
	bpl :+
	ldx #15
:	lda KbdQueue,x
	sta KbdNextKey
	MoveB POKEY_KBCODE, kbdRepCode	; its key, which must still be the one held
	LoadB KbdQueFlag, KEY_REPEAT_DELAY
	bne @repdone			; (always)
@held:	dec KbdQueFlag
	bne @repdone
	lda POKEY_SKSTAT
	and #%00000100			; 0: a key is held
	bne @repdone
	lda POKEY_KBCODE		; that key (not another, pressed while it was let go, whose press got lost)
	cmp kbdRepCode
	bne @repdone
	LoadB KbdQueFlag, KEY_REPEAT_RATE
	lda KbdNextKey
	jsr KbdScanHelp2
	MoveB KbdQueTail, kbdLastTail	; (not a new key)
@repdone:

:;	jsr _DoKeyboardScan			; keyboard is processed only from keyboard IRQ
	lda alarmWarnFlag
	beq :+
	dec alarmWarnFlag

:	lda intTopVector
	ldx intTopVector+1
	jsr CallRoutine
	lda intBotVector
	ldx intBotVector+1
	jsr CallRoutine

	ldx #31
:	pla
	sta r0,x
	dex
	bpl :-

	PopW returnAddress
	PopW CallRLo
	pla
	tay
	pla
	tax
	pla
	rti
