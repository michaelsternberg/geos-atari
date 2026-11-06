; Atari SIO: polled POKEY transport shared by the GEOS SIO disk drivers
; (drv/siodrv-atari.s, drv/siodrv-big-atari.s)
;
; The including driver provides:
;   SIO_DEVICE	- SIO device ID of the disk drive ($31 for D1:)
;   SioSector	- GEOS track/sector in r1 to SIO sector number in sioAux, error code in X
; and includes drv/sio-vars.inc for the variables.
;
; Besides disk blocks, SioCall gives GEOS applications access to any SIO device (FujiNet's $70 and N: $71,
; printers...) through the same code, at the same (high) speed and with the same speed recovery, see
; drv/sio-call.inc for the entry point.

;---------------------------------------
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
		LDX #SIO_DIR_READ
		LDA sioCommand
		CMP #SIO_CMD_PUT
		BNE :+
		LDX #SIO_DIR_WRITE
:		STX sioDir
		LoadB sioLen, 0			; 256 bytes
		LoadB sioCmplRep, 1
		LoadB sioRetry, SIO_RETRIES
		LoadB sioAnyErr, $ff		; a disk block can be transferred again after any error
		JSR SioRun
@end:		TXA
		RTS

;---------------------------------------
; run the command set up in sioFrame/sioDir/sioLen/sioCmplRep/sioRetry/sioAnyErr with (r4) as buffer
; with interrupts off and NMIs only counting frames, switching to high speed first when the drive has one
; returns error code in X
SioRun:		PHP
		SEI
		LDA interrupt_lock		; keep the caller's lock (BAM access in banked RAM holds it)
		PHA
		; NMI handler will only count frames, it's needed for timeouts
		LoadB interrupt_lock, $ff
		LDA sioDiv			; at 19200 while the drive may have high speed?
		CMP #POKEY_SIO_19200
		BNE @retry
		CMP sioHsDiv
		BEQ @retry
		JSR SioHighSpeed
@retry:		JSR SioTransfer
		beqx @done
		CPX #DEV_NOT_FOUND		; no answer: the device may be at the other speed
		BNE :+
		JSR SioToggle
		JMP @again
:		BIT sioAnyErr			; otherwise only disk blocks are sent again
		BPL @done
@again:		DEC sioRetry
		BNE @retry
@done:		JSR SioIdle
		PLA
		STA interrupt_lock
		PLP
		RTS

;---------------------------------------
; ask the drive for its high speed ('?'), set sioHsDiv and sioDiv to it, or to 19200 without one
; the command being run (sioState) and r4 are kept
SioHighSpeed:	LDY #SIO_STATE_LEN-1
:		LDA sioState,y
		STA sioSave,y
		DEY
		BPL :-
		PushW r4
		LoadW r4, sioReply
		LoadB sioDevice, SIO_DEVICE
		LoadB sioCommand, SIO_CMD_HSINDEX
		LoadB sioVerify, 0
		LoadB sioDir, SIO_DIR_READ
		LoadB sioLen, 1
		LoadB sioCmplRep, 1
		LoadB sioRetry, SIO_RETRIES
@retry:		JSR SioTransfer
		beqx @got
		CPX #DEV_NOT_FOUND		; FujiNet still at high speed takes two frames to come back
		BNE @none			; NAK: no high speed
		DEC sioRetry
		BNE @retry
@none:		LDA #POKEY_SIO_19200
		BNE :+
@got:		LDA sioReply
:		STA sioHsDiv
		STA sioDiv
		PopW r4
		LDY #SIO_STATE_LEN-1
:		LDA sioSave,y
		STA sioState,y
		DEY
		BPL :-
		RTS

;---------------------------------------
; switch sioDiv between 19200 and high speed, preserves X
SioToggle:	LDA #POKEY_SIO_19200
		CMP sioDiv
		BNE :+
		LDA sioHsDiv
:		STA sioDiv
		RTS

;---------------------------------------
; single attempt of SIO command from sioFrame, returns error code in X
SioTransfer:
		LoadB POKEY_AUDCTL, POKEY_AUDCTL_SIO
		MoveB sioDiv, POKEY_AUDF3	; 19200 or high speed
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

		BIT sioDir
		BVS SioReadData			; read (or '?')
		BMI @write
		; no data frame: wait for complete
		LDX #WR_VER_ERR
		JMP @complete

		; write: send data frame
@write:		LDY #SIO_DELAY_T3
		JSR SioDelay
		JSR SioSendStart
		LDY #0
:		LDA (r4),y
		JSR SioPutByte
		INY
		CPY sioLen
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
@complete:	JSR SioGetCmpl			; done?
		BCS @end
		CMP #SIO_COMPLETE
		BNE @end
		LDX #0
@end:		RTS

SioReadData:	LDX #DAT_CHKSUM_ERR
		JSR SioGetCmpl			; complete or error, then data frame
		BCS @end
		STA sioStatus
		LDA #0
		STA sioChksum			; checksum covers only the data
		STA sioMismatch
		LDY #0
@loop:		LDA #SIO_TIMEOUT_BYTE
		JSR SioGetByte
		BCS @short
		BIT sioVerify
		BMI @verify
		STA (r4),y
		INY
		CPY sioLen
		BNE @loop
		BEQ @chksum
@verify:	CMP (r4),y
		BEQ :+
		STX sioMismatch			; any nonzero value
:		INY
		CPY sioLen
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
; the device stopped early: for SioCall (not disk blocks) a shorter frame whose last byte is the checksum of
; the others is the answer (FujiNet's replies differ in size between firmware versions), sioLen is set to it
@short:		BIT sioAnyErr
		BMI @end
		CPY #2
		BCC @end
		DEY
		STY sioLen			; the data, less the checksum byte
		LDA #0				; checksum of the data
		LDY #0
:		CLC
		ADC (r4),y
		ADC #0
		INY
		CPY sioLen
		BNE :-
		CMP (r4),y
		BNE @end
		LDA sioStatus
		CMP #SIO_COMPLETE
		BNE @end
		LDX #0
		RTS

;---------------------------------------
; wait for complete/error byte, sioCmplRep times SIO_TIMEOUT_CMPL frames (a drive may seek and retry,
; FujiNet may wait for the network), returns C=1 on timeout, preserves X and Y
SioGetCmpl:	MoveB sioCmplRep, sioTicks2
:		LDA #SIO_TIMEOUT_CMPL
		JSR SioGetByte
		BCC :+
		DEC sioTicks2
		BNE :-
		SEC
:		RTS

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
