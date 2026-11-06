; Atari SIO: public entry point for GEOS applications, part of the SIO disk drivers
;
; At SIO_CALL_SIG ($904e) in the disk driver:
;	$904e	"SIOC"		signature, check it before calling
;	$9052	.byte 1		version
;	$9053	JMP SioCall	A/X - address (low/high) of a 12-byte device control block like the Atari OS DCB:
;		+0	device ID ($70 FujiNet, $71 N1:, $31 D1:...)
;		+1	unit, added to the device ID less 1 (use 1)
;		+2	command
;		+3	in: $40 data frame from the device, $80 to the device, $00 none; out: status as Atari OS:
;			1 OK, 138 timeout (no answer), 139 NAK, 144 device error or bad data frame
;		+4,+5	buffer
;		+6	timeout in seconds (rounded up to ~5s steps, at least ~5s)
;		+7	unused
;		+8,+9	data frame length, 1-256; after reading: the bytes received (a shorter frame is accepted
;			when its last byte is the checksum of the ones before it)
;		+10,+11	aux1, aux2
;	returns status in A, GEOS error code in X (0 OK), Y destroyed
;	r4 is kept, interrupts are off and the mouse stops during the transfer
;	the disk drive's high speed is used for all devices: FujiNet switches the whole bus

SioCall:	STA @get+1
		STX @get+2
		STA @put+1
		STX @put+2
		LDY #11
@get:		LDA $ffff,y
		STA sioDcb,y
		DEY
		BPL @get
		LDA sioDcb+0			; device + unit - 1
		CLC
		ADC sioDcb+1
		SEC
		SBC #1
		STA sioDevice
		MoveB sioDcb+2, sioCommand
		MoveB sioDcb+10, sioAux
		MoveB sioDcb+11, sioAux+1
		LDA sioDcb+3
		AND #SIO_DIR_READ|SIO_DIR_WRITE
		STA sioDir
		MoveB sioDcb+8, sioLen		; 256 is 0
		LDA sioDcb+6			; seconds to ~5s periods: (s+4)/5, at least 1
		CLC
		ADC #4
		LDX #0
:		CMP #5
		BCC :+
		SBC #5
		INX
		BNE :-
:		TXA
		BNE :+
		LDA #1
:		STA sioCmplRep
		LoadB sioVerify, 0
		LoadB sioAnyErr, 0		; don't repeat commands the device may have run
		LoadB sioRetry, SIO_RETRIES
		PushW r4
		MoveW sioDcb+4, r4
		JSR SioRun
		PopW r4
		LDA #1				; GEOS error to Atari status
		CPX #0
		BEQ @st
		LDA #138
		CPX #DEV_NOT_FOUND
		BEQ @st
		LDA #139
		CPX #INV_TRACK
		BEQ @st
		LDA #144
@st:		PHA
		LDY #3
		JSR @put
		LDA sioLen			; bytes received (or sent)
		LDY #8
		JSR @put
		CMP #1				; 0 is 256
		LDA #0
		ROL
		EOR #1
		INY
		JSR @put
		PLA
		RTS
@put:		STA $ffff,y
		RTS

sioDcb:		.res 12
