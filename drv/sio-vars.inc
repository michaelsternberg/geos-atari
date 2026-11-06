; Atari SIO: variables of drv/sio-core.inc

sioState:			; the command being run, saved while asking for high speed
sioFrame:			; command frame, without checksum
sioDevice:	.res 1
sioCommand:	.res 1
sioAux:		.res 2		; sector number (aux1/aux2)
sioVerify:	.res 1		; $ff - compare data with (r4) instead of storing it
sioDir:		.res 1		; SIO_DIR_READ, SIO_DIR_WRITE or 0 for no data frame
sioLen:		.res 1		; bytes in the data frame, 0 for 256
sioCmplRep:	.res 1		; wait for complete this many times SIO_TIMEOUT_CMPL frames
sioRetry:	.res 1		; remaining attempts
sioAnyErr:	.res 1		; $ff - attempt again after any error, 0 - only when the command frame got no answer
SIO_STATE_LEN	= * - sioState
sioSave:	.res SIO_STATE_LEN

sioMismatch:	.res 1		; nonzero if compare failed
sioStatus:	.res 2		; complete/error byte, data checksum
sioChksum:	.res 1		; checksum of current frame
sioTxBusy:	.res 1		; $ff if SEROUT got a byte in current frame
sioTicks:	.res 1		; timeout in frames
sioTicks2:	.res 1		; remaining SIO_TIMEOUT_CMPL periods
sioJiffy:	.res 1		; last seen frame counter
sioReply:	.res 1		; the answer to '?'
sioDiv:		.byte POKEY_SIO_19200	; POKEY divisor in use: 19200 or sioHsDiv
sioHsDiv:	.byte $ff	; the drive's high speed divisor, $ff before asking
