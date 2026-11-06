/*
 * fstest: GEOS file system test for the big SIO volume (drv/siodrv-big-atari.s)
 *
 * Runs as DESK TOP on a test disk (tests/run_fstest.py): saves SEQ files of many sizes (more than one directory
 * block's worth, across track boundaries), reads them back, deletes half, checks the free block count after each
 * step, drops an allocation with GetDirHead (as a 1541 does without PutDirHead), and writes and reads back the
 * records of a VLIR file. The result goes into the SEQ file "FSTEST RESULT" (first line PASS or FAIL) and on screen;
 * then the disk is checked from the PC (tools/geosimg.py check).
 */

#include <geos.h>
#include <string.h>
#include <stdio.h>

#define NFILES 20
#define BUF ((char *)0x3000)        /* saved from and read back into here */
#define BUFSIZE 0x2c00              /* up to the C stack at $5C00 */

static char log[1024];
static unsigned logLen;
static unsigned char fails;
static char line[80];
static char name[17];

static struct fileheader hdr;

static void say(const char *s)
{
    unsigned l = strlen(s);
    if (logLen + l + 1 < sizeof(log)) {
        memcpy(log + logLen, s, l);
        logLen += l;
        log[logLen++] = 13;
    }
}

static void fail(const char *s)
{
    ++fails;
    say(s);
}

static unsigned blocksFree(void)
{
    GetDirHead();
    return CalcBlksFree();
}

/* directory blocks: a save may add one (AddDirBlock) */
static unsigned char dirBlocks(void)
{
    static char blk[256];
    struct tr_se ts;
    unsigned char n = 0;

    GetDirHead();
    ts.track = ((char *)0x8200)[0];     /* curDirHead */
    ts.sector = ((char *)0x8200)[1];
    while (ts.track && n < 200) {
        if (GetBlock(&ts, blk))
            break;
        ++n;
        ts.track = blk[0];
        ts.sector = blk[1];
    }
    return n;
}

static unsigned sizeOf(unsigned n)
{
    /* 1..~20 blocks of data, one 44 */
    if (n == 7)
        return 44u * 254u - 3u;
    return (unsigned)((n * 37u) % 21u) * 254u + n + 1u;
}

static unsigned char pat(unsigned n, unsigned i)
{
    return (unsigned char)(i * 7u + n * 13u + (i >> 8));
}

static void fill(unsigned n, unsigned len)
{
    unsigned i;
    for (i = 0; i < len; ++i)
        BUF[i] = pat(n, i);
}

static char same(unsigned n, unsigned len)
{
    unsigned i;
    for (i = 0; i < len; ++i)
        if ((unsigned char)BUF[i] != pat(n, i))
            return 0;
    return 1;
}

static void setName(unsigned n)
{
    sprintf(name, "T%02u", n);
}

static char saveData(const char *fname, char *start, unsigned len, char structure)
{
    memset(&hdr, 0, sizeof(hdr));
    hdr.n_block.track = (unsigned)fname & 0xff;     /* SaveFile takes the name's address from here */
    hdr.n_block.sector = (unsigned)fname >> 8;
    hdr.icon_desc[0] = 0x83;
    hdr.icon_desc[1] = 21;
    hdr.icon_desc[2] = 63 | 0x80;
    hdr.dostype = 0x83;     /* USR */
    hdr.type = DATA;
    hdr.structure = structure;
    hdr.load_address = (unsigned)start;
    hdr.end_address = (unsigned)start + len;
    hdr.exec_address = 0;
    strcpy(hdr.class_name, "fstest data V1.0");
    return SaveFile(0, &hdr);
}

static char readData(const char *fname, unsigned *len)
{
    char err = FindFile(fname);
    if (err)
        return err;
    err = ReadFile(&dirEntryBuf.n_block, BUF, BUFSIZE);
    /* bytes read: r7 points past the last one */
    *len = r7 - (unsigned)BUF;
    return err;
}

static void testSeq(void)
{
    unsigned n, f0, f1, len, got;
    unsigned char d0;
    char err;

    for (n = 0; n < NFILES; ++n) {
        setName(n);
        len = sizeOf(n);
        d0 = dirBlocks();
        f0 = blocksFree();
        fill(n, len);
        err = saveData(name, BUF, len, SEQUENTIAL);
        if (err) {
            sprintf(line, "save %s: error %u", name, err);
            fail(line);
            return;
        }
        f1 = blocksFree();
        d0 = dirBlocks() - d0;
        FindFile(name);
        if (f0 - f1 != dirEntryBuf.size + d0) {
            sprintf(line, "save %s: free %u -> %u, file %u blocks, %u new dir blocks", name, f0, f1,
                    dirEntryBuf.size, d0);
            fail(line);
        }
    }
    for (n = 0; n < NFILES; ++n) {
        setName(n);
        err = readData(name, &got);
        len = sizeOf(n);
        if (err) {
            sprintf(line, "read %s: error %u", name, err);
            fail(line);
        } else if (got != len || !same(n, len)) {
            sprintf(line, "read %s: %u bytes, %u saved, %s", name, got, len,
                    same(n, got < len ? got : len) ? "same" : "different");
            fail(line);
        }
    }
    for (n = 0; n < NFILES; n += 2) {
        setName(n);
        f0 = blocksFree();
        FindFile(name);
        len = dirEntryBuf.size;
        err = DeleteFile(name);
        f1 = blocksFree();
        if (err || f1 - f0 != len) {
            sprintf(line, "delete %s: error %u, free %u -> %u, file %u blocks", name, err, f0, f1, len);
            fail(line);
        }
        if (FindFile(name) != FILE_NOT_FOUND) {
            sprintf(line, "delete %s: still there", name);
            fail(line);
        }
    }
    /* the odd ones are still there and the same */
    for (n = 1; n < NFILES; n += 2) {
        setName(n);
        len = sizeOf(n);
        if (readData(name, &got) || got != len || !same(n, len)) {
            sprintf(line, "after deletes %s: different", name);
            fail(line);
        }
    }
    say("seq files done");
}

static void testDrop(void)
{
    /* an allocation without PutDirHead is dropped by the next GetDirHead */
    struct tr_se ts, got;
    unsigned f0, f1;

    f0 = blocksFree();
    ts.track = 1;
    ts.sector = 0;
    got = SetNextFree(&ts);
    f1 = CalcBlksFree();
    if (f1 != f0 - 1) {
        sprintf(line, "SetNextFree: free %u -> %u", f0, f1);
        fail(line);
    }
    if (FindBAMBit(&got)) {
        sprintf(line, "SetNextFree: (%u,%u) still free", got.track, got.sector);
        fail(line);
    }
    GetDirHead();
    if (!FindBAMBit(&got) || CalcBlksFree() != f0) {
        sprintf(line, "GetDirHead kept (%u,%u)", got.track, got.sector);
        fail(line);
    }
    /* SetNextFree past the end of the disk: none (no track 0 or past the last) */
    ts.track = 255;
    ts.sector = 255;
    got = SetNextFree(&ts);
    GetDirHead();
    if (CalcBlksFree() != f0) {
        sprintf(line, "SetNextFree from (255,255): free changed");
        fail(line);
    }
    say("drop done");
}

static void testVlir(void)
{
    static const char vname[] = "FSTEST VLIR";
    static const unsigned rlen[4] = { 100, 3000, 1, 9000 };
    char err;
    unsigned r, got, f0;

    memset(BUF, 0, 254);
    f0 = blocksFree();
    err = saveData(vname, BUF, 0, VLIR);
    if (err) {
        sprintf(line, "save VLIR: error %u", err);
        fail(line);
        return;
    }
    err = OpenRecordFile(vname);
    if (err) {
        sprintf(line, "open VLIR: error %u", err);
        fail(line);
        return;
    }
    for (r = 0; r < 4; ++r) {
        err = AppendRecord();
        fill(100 + r, rlen[r]);
        if (!err)
            err = WriteRecord(BUF, rlen[r]);
        if (err) {
            sprintf(line, "VLIR record %u: error %u", r, err);
            fail(line);
        }
    }
    CloseRecordFile();
    err = OpenRecordFile(vname);
    for (r = 0; !err && r < 4; ++r) {
        err = PointRecord(r);
        if (!err)
            err = ReadRecord(BUF, BUFSIZE);
        got = r7 - (unsigned)BUF;
        if (err || got != rlen[r] || !same(100 + r, rlen[r])) {
            sprintf(line, "VLIR record %u: error %u, %u bytes of %u", r, err, got, rlen[r]);
            fail(line);
        }
    }
    CloseRecordFile();
    FindFile(vname);
    if (f0 - blocksFree() != dirEntryBuf.size) {
        sprintf(line, "VLIR: free count off");
        fail(line);
    }
    say("vlir done");
}

static void writeResult(void)
{
    static const char rname[] = "FSTEST RESULT";
    char head[40];
    unsigned l;

    sprintf(head, "%s %u free %u", fails ? "FAIL" : "PASS", fails, blocksFree());
    l = strlen(head);
    memmove(log + l + 1, log, logLen);
    memcpy(log, head, l);
    log[l] = 13;
    logLen += l + 1;
    saveData(rname, log, logLen, SEQUENTIAL);
    PutString(head, 60, 10);
}

/* the test runner stops the emulator here (a breakpoint on _done) */
void done(void)
{
    for (;;)
        ;
}

void main(void)
{
    UseSystemFont();
    PutString("fstest running", 40, 10);
    say("fstest");
    testSeq();
    testDrop();
    testVlir();
    writeResult();
    PutString("fstest done", 80, 10);
    done();
}
