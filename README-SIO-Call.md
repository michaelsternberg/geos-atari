# The SIO call: SIO for GEOS programs

Under GEOS on the Atari, a program can't use the OS ROM's SIO routine (SIOV):
GEOS switches the ROM out, since its kernal lives in the RAM under it. A program
with its own SIO code would compete with the disk driver for POKEY, and would
have to follow FujiNet's high speed itself. So the SIO disk drivers of this fork
(`drv/siodrv-atari.s`, `drv/siodrv-big-atari.s`) lend their SIO code
(`drv/sio-core.inc`) to programs, for any device on the bus: FujiNet's own
device, its network channels (N:), its clock, a printer. A transfer runs at the
disk's speed, with its retries.

The entry is in the disk driver, at a fixed address (`drv/sio-call.inc`). It's
there only with the SIO disk drivers: the RAM disk build (upstream's) has no
SIO, so check for it first.

| Address | | |
|---|---|---|
| `$904E` | `"SIOC"` | the signature: check it before anything else |
| `$9052` | `.byte 4` | the version: 1 SioCall, 2 and SioBack, 3 and the PROCEED byte, 4 and frames over 256 bytes |
| `$9053` | `JMP SioCall` | a command to a device, from a 12-byte block like the Atari OS's DCB |
| `$9056` | `JMP SioBack` | (version 2) copies to or from GEOS's background screen, for printer drivers |
| `$9059` | `JMP DriveB` | the kernal's: the big driver looks at D2: for drive B (the other driver returns at once) |
| `$905C` | `.word` | (version 3) the address of the byte the kernal sets when SIO's PROCEED line goes active |

Programs using it: the FujiNet programs for GEOS (FConfig, WiFi Setup, Headlines,
Weather, the GEOS Store, the FujiNet Terminal) and FujiNet Epson, a printer
driver, in [geos-fujinet](https://github.com/michaelsternberg/geos-fujinet); and
the kernal itself, which sets GEOS's date and time from FujiNet's clock at
start-up (`kernal/start/start_atari.s`).

## SioCall ($9053)

A/X: the address (low, high) of a 12-byte block:

| Offset | | |
|---|---|---|
| +0 | device | `$70` FujiNet, `$71` N1:, `$45` FujiNet's clock, `$31` D1:, `$40` P1: ... |
| +1 | unit | added to the device less 1: use 1 |
| +2 | command | |
| +3 | direction, then status | in: `$40` a data frame from the device, `$80` one to it, `$00` none; out: the status |
| +4,+5 | buffer | |
| +6 | timeout | seconds (counted in steps of about 5 s, at least one) |
| +7 | | unused |
| +8,+9 | length | of the data frame, 1-65535 (1-256 before version 4); after a read, the bytes received |
| +10,+11 | aux1, aux2 | |

Returns the status in A (and at +3), as the Atari OS has it:

| Status | |
|---|---|
| 1 | OK |
| 138 | timeout: no answer |
| 139 | NAK: the device refused the command |
| 144 | device error, or a bad data frame |

X has a GEOS error code (0: OK); Y is destroyed, r4 kept. Interrupts are off
during the transfer: the mouse stops, and keys pressed meanwhile are taken when
it ends.

- **High speed.** The disk's high speed is used for every device: FujiNet
  switches the whole bus when it's asked for its speed. A command frame without
  an answer is sent again at the other speed.
- **Short replies.** A data frame shorter than asked for is taken when its last
  byte is the checksum of the ones before it: FujiNet's replies differ in size
  between firmware versions. +8,+9 say how many came. In a frame over 256
  bytes, only a reply that ends within the first 256 is taken.
- **Long frames.** From version 4 a data frame can be longer than 256 bytes:
  FujiNet's drive slots, for one, come and go as a single frame of 304 bytes.
- **Retries.** A command the device may have run isn't sent again after an error
  in its data frame, so a write to a network channel doesn't go out twice.

### In assembler (ca65)

Reading FujiNet's clock (device `$45`, command `$93`, APETIME: day, month, year,
hour, minute, second), as the kernal does at start-up:

```asm
SIO_CALL_SIG    = $904e
SIO_CALL        = $9053

; Z=1 when the disk driver has the SIO call
HasSioCall:     ldx #3
:               lda SIO_CALL_SIG,x
                cmp sioc,x
                bne :+
                dex
                bpl :-
                inx                     ; X=0, Z=1
:               rts
sioc:           .byte "SIOC"

GetTime:        jsr HasSioCall
                bne @no                 ; no SIO call: the RAM disk build
                lda #<dcb
                ldx #>dcb
                jsr SIO_CALL
                cmp #1
                bne @no                 ; no answer (no FujiNet), or an error
                ; time: day, month, year (2 digits), hour, minute, second
@no:            rts

; FujiNet's clock, unit 1, APETIME, a data frame from it
dcb:            .byte $45, 1, $93, $40
                .word time              ; buffer
                .byte 5, 0              ; timeout (s), unused
                .word 6                 ; 6 bytes
                .byte 0, 0              ; aux1 0: FujiNet's time zone
time:           .res 6
```

### In C (cc65, `geos-cbm`)

The block as a struct, and a few lines of assembler to call the entry
(geos-fujinet's `apps/transport/atari/sio.h` and `sio.s`):

```c
typedef struct {
    unsigned char dev;      /* device ID */
    unsigned char unit;     /* 1 */
    unsigned char cmd;
    unsigned char stat;     /* in: 0x40 read, 0x80 write, 0 none;
                               out: the status (1: OK) */
    void *buf;
    unsigned char timeout;  /* seconds */
    unsigned char res;
    unsigned len;           /* 1-256; after a read: the bytes received */
    unsigned char aux1, aux2;
} fn_dcb;

unsigned char __fastcall__ fn_sio(fn_dcb *dcb);  /* the status */
unsigned char fn_present(void);     /* 1: the SIO call is there */
```

```asm
        .export _fn_sio, _fn_present

SIO_CALL_SIG    = $904e
SIO_CALL        = $9053

_fn_sio:        jsr SIO_CALL            ; A/X: the block (fastcall)
                ldx #0
                rts

_fn_present:    ldx #3
:               lda SIO_CALL_SIG,x
                cmp sig,x
                bne @no
                dex
                bpl :-
                lda #1
                ldx #0
                rts
@no:            lda #0
                tax
                rts
sig:            .byte "SIOC"
```

Then FujiNet's WiFi status (device `$70`, command `$FA`: one byte, 3 when
connected):

```c
unsigned char wifi_status(void)
{
    static unsigned char st;
    static fn_dcb dcb;

    dcb.dev = 0x70;
    dcb.unit = 1;
    dcb.cmd = 0xFA;
    dcb.stat = 0x40;        /* a data frame from FujiNet */
    dcb.buf = &st;
    dcb.timeout = 5;
    dcb.len = 1;
    dcb.aux1 = dcb.aux2 = 0;
    if (fn_sio(&dcb) != 1)
        return 0;
    return st;
}
```

FujiNet's commands are in fujinet-firmware's `include/fujiCommandID.h`;
geos-fujinet's `apps/common/fujinet.c` (FujiNet's device), `net.c` (N:) and
`http.c` use them through this call.

## SioBack ($9056, version 2)

For printer drivers. C64 programs such as geoWrite draw what they print into
GEOS's background screen and hand the printer driver its address; on the Atari
the background screen ($6000-$7FFF) is in the 130XE's bank 0, where a printer
driver can't simply read it. SioBack copies between it and main memory.

A/X: the address of a 7-byte block:

| Offset | |
|---|---|
| +0,+1 | from |
| +2,+3 | to |
| +4,+5 | count |
| +6 | 0: from the background screen to main memory; 1: from main memory to the background screen |

The background screen is laid out as the screen is: 40 bytes a line from
`$6038`. A C64 program passes an address in the C64's layout, where card row k
(8 lines) is at `$6000+320*k`: the same 320 bytes are lines 8k to 8k+7 here,
from `$6038+320*k`. The r-registers are kept; interrupts are off during the
copy. geos-fujinet's FujiNet Epson (`apps/printer`) uses it.

## The PROCEED byte ($905C, version 3)

FujiNet pulses SIO's PROCEED line while a network channel has something to read:
data waiting, the connection closed, an error. With it a program needn't keep
asking N: for its status.

- `$905C` holds the address of a byte that the kernal sets to `$FF` when PROCEED
  goes active.
- The kernal takes the interrupt (the PIA's CA1) only while a program enables
  it: `PACTL` (`$D302`) bit 0, that is `$3D` instead of GEOS's `$3C`. Set `$3C`
  again before the program ends.
- Clear the byte before asking N: for its status: whatever comes after sets it
  again. FujiNet pulses PROCEED from about 5 ms after it was last asked for a
  status, every few tens of milliseconds while there's something to read (N:'s
  `Z` command sets the rate).
- A pulse during an SIO transfer (interrupts off) can be missed; the next one
  comes. Ask anyway now and then (the FujiNet Terminal does once a second).

```c
#define PACTL (*(volatile unsigned char *)0xd302)

static unsigned char *proceed;      /* 0: no PROCEED byte, poll */

    if (fn_present() && *(unsigned char *)0x9052 >= 3)
        proceed = *(unsigned char **)0x905c;
    ...
    if (proceed) {                  /* connected */
        *proceed = 0xff;            /* (asked at once) */
        PACTL = 0x3d;
    }
    ...
    if (!proceed || *proceed) {     /* something to read */
        if (proceed)
            *proceed = 0;
        /* N:'s status, then read */
    }
    ...
    PACTL = 0x3c;                   /* before quitting */
```

The FujiNet Terminal (geos-fujinet `apps/term/term.c`) works this way.

## Notes

- Check `"SIOC"` and the version before using an entry: a program can find
  itself on a RAM disk build, or with an older disk driver.
- The disk driver's own transfers and a program's go through the same code, one
  at a time: nothing to arbitrate.
- The 12-byte block is copied when the call starts; the buffer must stay where
  it is until it returns.
