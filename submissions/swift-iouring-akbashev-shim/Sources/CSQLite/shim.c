// SQLite's amalgamation compiled in this one file, its internal functions left `static` (SQLITE_PRIVATE as
// SQLite defines it), so the compiler inlines and specializes them; the B-tree functions the Swift code calls
// are exported as thin wrappers named bt_<function>, which BTree declares with `@_extern(c)`.
#include "sqlite3.c"

Btree *bt_sqlite3DbNameToBtree(sqlite3 *db, const char *name) { return sqlite3DbNameToBtree(db, name); }
int bt_sqlite3BtreeCursorSize(void) { return sqlite3BtreeCursorSize(); }
void bt_sqlite3BtreeCursorZero(BtCursor *c) { sqlite3BtreeCursorZero(c); }
int bt_sqlite3BtreeBeginTrans(Btree *b, int write, int *schema) { return sqlite3BtreeBeginTrans(b, write, schema); }
int bt_sqlite3BtreeCursor(Btree *b, Pgno root, int write, KeyInfo *keys, BtCursor *c) { return sqlite3BtreeCursor(b, root, write, keys, c); }
int bt_sqlite3BtreeCloseCursor(BtCursor *c) { return sqlite3BtreeCloseCursor(c); }
int bt_sqlite3BtreeTableMoveto(BtCursor *c, i64 key, int bias, int *res) { return sqlite3BtreeTableMoveto(c, key, bias, res); }
int bt_sqlite3BtreeIndexMoveto(BtCursor *c, UnpackedRecord *key, int *res) { return sqlite3BtreeIndexMoveto(c, key, res); }
int bt_sqlite3BtreeFirst(BtCursor *c, int *empty) { return sqlite3BtreeFirst(c, empty); }
int bt_sqlite3BtreeNext(BtCursor *c, int flags) { return sqlite3BtreeNext(c, flags); }
int bt_sqlite3BtreeEof(BtCursor *c) { return sqlite3BtreeEof(c); }
const void *bt_sqlite3BtreePayloadFetch(BtCursor *c, u32 *local) { return sqlite3BtreePayloadFetch(c, local); }
u32 bt_sqlite3BtreePayloadSize(BtCursor *c) { return sqlite3BtreePayloadSize(c); }
KeyInfo *bt_sqlite3KeyInfoAlloc(sqlite3 *db, int keys, int extra) { return sqlite3KeyInfoAlloc(db, keys, extra); }
void bt_sqlite3KeyInfoUnref(KeyInfo *k) { sqlite3KeyInfoUnref(k); }
UnpackedRecord *bt_sqlite3VdbeAllocUnpackedRecord(KeyInfo *k) { return sqlite3VdbeAllocUnpackedRecord(k); }
void bt_sqlite3VdbeRecordUnpack(int n, const void *record, UnpackedRecord *r) { sqlite3VdbeRecordUnpack(n, record, r); }
void bt_sqlite3DbFreeNN(sqlite3 *db, void *p) { sqlite3DbFreeNN(db, p); }
