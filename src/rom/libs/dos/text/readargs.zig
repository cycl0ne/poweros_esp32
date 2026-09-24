// SPDX-License-Identifier: MPL-2.0
//! ReadArgs: a command line parsed by a template.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _text = @import("_text.zig");
const storeArg = _text.storeArg;
const nextSlot = _text.nextSlot;
const readRest = _text.readRest;
const REST = _text.REST;
const DONE = _text.DONE;
const TRUE_SLOT = _text.TRUE_SLOT;
const SWITCH = _text.SWITCH;
const unreadChar = _text.unreadChar;
const prompt = _text.prompt;
const LF = _text.LF;
const settle = _text.settle;
const readChar = _text.readChar;
const finish = _text.finish;
const rdItem = _text.rdItem;
const fail = _text.fail;
const initKeys = _text.initKeys;
const State = _text.State;
const link = _text.link;
const VECSIZE = _text.VECSIZE;
const rd = dos.rdargs;
const gimmeAVec = _text.gimmeAVec;
const RDArgs = rd.RDArgs;

/// Parses a command line by a template into the caller's slots.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadArgs(db: *DosBase, template: [*:0]const u8, argv: [*]usize, rdargs: ?*dos.RDArgs) ?*dos.RDArgs
/// ```
///
/// SINCE: 1.0. LVO -456.
///
/// INPUTS:
/// - `template` - the items, comma-separated, e.g. "FROM/M/A,TO/A,Q=QUIET/S":
///   '=' joins aliases; /A required, /K only after its keyword, /S a switch,
///   /N a number, /T a toggle (YES, NO, ON, OFF), /M many, /F the rest of
///   the line.
/// - `argv` - one pointer-sized slot per item, set to its default by the
///   caller. Filled with a string, an i32's address (/N), DOSTRUE (/S, /T
///   on) or 0 (/T off), or a null-terminated array of strings or i32
///   addresses (/M).
/// - `rdargs` - a CSource to read instead of Input(), an ExtHelp and
///   RDAF_* flags (AllocDosObject(DOS_RDARGS) makes a cleared one); null
///   makes one.
///
/// RESULT:
/// The RDArgs, to give to `FreeArgs` once the slots are no longer needed;
/// null on failure, with IoErr: ERROR_REQUIRED_ARG_MISSING,
/// ERROR_TOO_MANY_ARGS, ERROR_KEY_NEEDS_ARG, ERROR_BAD_NUMBER,
/// ERROR_BAD_TEMPLATE, ERROR_LINE_TOO_LONG, ERROR_NO_FREE_STORE.
///
/// BEHAVIOR:
/// A keyword fills its own item; any other item fills the next one that
/// is free and not /K, /S or /T, and a /M collects all of them. At the end
/// an empty /A takes the last /M item when the /M has two or more. A lone
/// '?' at the end of the line (unless RDAF_NOPROMPT) prints the template -
/// ExtHelp the second time - to Output() and reads the line again from
/// Input(). The line's end is read; after a failure the rest of the line is
/// skipped.
///
/// CONTEXT:
/// - Waits: yes, when it reads Input().
/// - Interrupts: no.
/// - Forbid: never under Forbid.
/// - Process: a Process for Input(); a Task will do with a CSource.
///
/// OWNERSHIP:
/// Strings, numbers and /M arrays are in the RDArgs' buffer, which the
/// call allocates (unless RDAF_NOALLOC) and `FreeArgs` frees; the slots
/// point into it until then. A null `rdargs` makes an RDArgs that
/// `FreeArgs` frees too.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeArgs`, `ReadItem`, `FindArg`, `StrToLong`
///
/// EXAMPLES:
/// ```zig
/// var argv = [_]usize{ 0, 0, 0 };
/// const rda = dos_lib.ReadArgs("FROM/M/A,TO/A,Q=QUIET/S", &argv, null) orelse return dos_lib.IoErr();
/// defer dos_lib.FreeArgs(rda);
/// const from: [*]const ?[*:0]const u8 = @ptrFromInt(argv[0]);
/// ```
pub fn ReadArgs(db: *DosBase, template: [*:0]const u8, argv: [*]usize, rdargs: ?*dos.RDArgs) ?*dos.RDArgs {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    var rda: *RDArgs = undefined;
    if (rdargs) |r| {
        rda = r;
        r.da_list = null;
        if (r.buffer == null) {
            r.buffer = gimmeAVec(db, r, VECSIZE) orelse {
                _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
                return null;
            };
            r.buf_siz = VECSIZE;
        }
    } else {
        // The RDArgs and a first buffer in one block, on its own DAList.
        const block = sys.AllocVec(link + @sizeOf(RDArgs) + VECSIZE, exec.MEMF_CLEAR) orelse {
            _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
            return null;
        };
        rda = @ptrFromInt(@intFromPtr(block) + link);
        rda.* = .{
            .da_list = block,
            .buffer = @ptrFromInt(@intFromPtr(rda) + @sizeOf(RDArgs)),
            .buf_siz = VECSIZE,
        };
    }
    const buffer = rda.buffer.?;
    var st: State = .{
        .db = db,
        .rda = rda,
        .cs = &rda.source,
        .keys = template,
        .argv = argv,
        .w = buffer,
        .end = buffer + @as(usize, @intCast(@max(rda.buf_siz, 0))),
    };

    const bad = initKeys(&st);
    if (bad != 0) return fail(&st, bad);

    while (true) {
        st.argno = -1;
        st.lastitem = rdItem(&st);
        if (st.lastitem == rd.ITEM_NOTHING) {
            const code = finish(&st);
            if (code != 0) return fail(&st, code);
            _ = readChar(db, st.cs); // the line's end
            settle(&rda.source);
            return rda;
        }
        if (st.lastitem == rd.ITEM_UNQUOTED) {
            const found = dos_lib.FindArg(template, st.text());
            if (found < 0) {
                // Not a keyword: a lone '?' at the line's end asks.
                const c = readChar(db, st.cs);
                if (c >= 0) {
                    if (c == LF and st.w[0] == '?' and st.w[1] == 0 and rda.flags & rd.RDAF_NOPROMPT == 0) {
                        prompt(&st);
                        continue;
                    }
                    unreadChar(db, st.cs);
                }
            } else {
                st.argno = found;
                const item_type = st.argimage[@intCast(found)];
                if (item_type & SWITCH != 0) {
                    st.argv[@intCast(found)] = TRUE_SLOT;
                    st.argimage[@intCast(found)] |= DONE;
                    continue;
                }
                if (item_type & REST != 0) {
                    // KEYWORD=the rest of the line, quotes and all.
                    if (!readRest(&st, 0)) return fail(&st, dos.ERROR_NO_FREE_STORE);
                    unreadChar(db, st.cs);
                } else {
                    var item = rdItem(&st);
                    if (item == rd.ITEM_EQUAL) item = rdItem(&st);
                    if (item == rd.ITEM_NOTHING) return fail(&st, dos.ERROR_KEY_NEEDS_ARG);
                    if (item < 0) return fail(&st, dos.ERROR_LINE_TOO_LONG);
                }
            }
        } else if (st.lastitem != rd.ITEM_QUOTED) {
            // ITEM_ERROR, or a '=' where an item should be.
            return fail(&st, dos.ERROR_LINE_TOO_LONG);
        }

        if (st.argno < 0) {
            const slot = nextSlot(&st);
            if (slot > 0) return fail(&st, slot);
            if (slot < 0) {
                // The /F is next: this item, a space unless it was quoted,
                // and the rest of the line.
                var count = db.utility_base.Strlen(st.text());
                if (st.lastitem != rd.ITEM_QUOTED) {
                    st.w[count] = ' ';
                    count += 1;
                }
                if (!readRest(&st, count)) return fail(&st, dos.ERROR_NO_FREE_STORE);
                unreadChar(db, st.cs);
            }
        }
        const code = storeArg(&st);
        if (code != 0) return fail(&st, code);
    }
}
