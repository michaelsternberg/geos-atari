; Atari SIO: constants shared by the GEOS SIO disk drivers (drv/siodrv-atari.s, drv/siodrv-big-atari.s)

; High speed: the first transfer asks the drive for its high speed ('?', as FujiNet and the Happy and
; US Doubler drives answer) at 19200 and then uses the POKEY divisor it gives; 40 ($28) is 19200 itself,
; and a drive that doesn't know '?' stays at 19200. FujiNet switches its speed for the whole bus after
; answering '?', and back after two command frames it can't read (another program's SIO at 19200, say).
; So a command frame without an answer is sent again at the other speed, and once back at 19200 the
; next transfer asks '?' again.

; SIO device of GEOS device 8 (1=D1:)
.ifndef SIO_UNIT
SIO_UNIT		= 1
.endif

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
SIO_CMD_HSINDEX		= $3f			; '?' - high speed index (a 1-byte data frame)

SIO_DIR_READ		= $40			; data frame from the device (Atari DSTATS)
SIO_DIR_WRITE		= $80			; data frame to the device

SIO_ACK			= $41			; 'A'
SIO_NAK			= $4e			; 'N'
SIO_COMPLETE		= $43			; 'C'
SIO_ERROR		= $45			; 'E'
