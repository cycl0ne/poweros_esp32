// SPDX-License-Identifier: MIT
//! ParseIFF: the walk through the file.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _handle = @import("../handle/_handle.zig");
const _item = @import("../item/_item.zig");
const _parse = @import("_parse.zig");
const IFFParseBase = _base.IFFParseBase;

/// Walks on through the file.
///
/// SYNOPSIS:
/// ```zig
/// fn ParseIFF(ib: *IFFParseBase, iff: *iffparse.IFFHandle, control: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `iff` - a handle opened `IFFF_READ`.
/// - `control` - `IFFPARSE_SCAN` to walk on until a chunk the program
///   asked to stop at, `IFFPARSE_STEP` to walk one chunk with the
///   handlers run, `IFFPARSE_RAWSTEP` to walk one chunk with none run.
///
/// RESULT:
/// 0 when the walk stopped where it was asked to - at a `StopChunk`, at
/// one step of `STEP` or `RAWSTEP` - and the chunk it stopped at is
/// `CurrentChunk`. Otherwise a negative `IFFERR_`: `IFFERR_EOF` at the
/// end of the file, `IFFERR_EOC` when a step ended at the end of a
/// chunk, `IFFERR_NOTIFF` for a file that does not begin `FORM`, `LIST`
/// or `CAT `, `IFFERR_MANGLED` or `IFFERR_SYNTAX` for a file whose
/// chunks do not add up, `IFFERR_READ`, `IFFERR_NOMEM`, or whatever a
/// handler of the program's own answered.
///
/// BEHAVIOR:
/// Each step enters the next chunk or reaches the end of the one it is
/// in, and runs the handler for that - the entry handler on the way in,
/// the exit handler on the way out. `PropChunk`, `StopChunk`,
/// `CollectionChunk` and `StopOnExit` are handlers of the library's own,
/// so a `SCAN` walks the file keeping what was asked for and stops where
/// it was asked to.
///
/// Where it stops, the chunk is entered and nothing of it has been read:
/// `CurrentChunk` says which it is and `ReadChunkBytes` reads it.
///
/// CONTEXT:
/// - Waits: whatever the stream hook waits for, and for memory.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do unless the stream needs a Process, which a
///   file does.
///
/// OWNERSHIP:
/// What the walk keeps - stored properties, collections - belongs to the
/// chunk it was found in and goes when the walk leaves that chunk.
///
/// NOTES:
/// A file is read by asking for what is wanted before the first call:
/// the properties to keep, the chunks to stop at. Walking with `STEP`
/// and looking at every chunk works too, and is what a program does when
/// it does not know what it will find.
///
/// SEE ALSO:
/// `StopChunk`, `PropChunk`, `CollectionChunk`, `CurrentChunk`
///
/// EXAMPLES:
/// ```zig
/// _ = ip.PropChunk(iff, ip.MakeID("ILBM"), ip.MakeID("BMHD"));
/// _ = ip.StopChunk(iff, ip.MakeID("ILBM"), ip.MakeID("BODY"));
/// while (true) {
///     const answer = ip.ParseIFF(iff, ip.IFFPARSE_SCAN);
///     if (answer == ip.IFFERR_EOF) break;
///     if (answer != 0) return;
///     // at a BODY, with the BMHD already kept
/// }
/// ```
pub fn ParseIFF(ib: *IFFParseBase, iff: *iffparse.IFFHandle, control: i32) i32 {
    const h = _base.handleOf(iff);
    var eoc: i32 = 0;
    while (true) {
        eoc = _parse.nextState(h);
        if (eoc != 0 and eoc != iffparse.IFFERR_EOC) return eoc;
        if (control == iffparse.IFFPARSE_RAWSTEP) break;
        const top = _handle.currentChunk(h) orelse return iffparse.IFFERR_EOF;
        const leaving = eoc != 0;
        const ident = if (leaving) iffparse.IFFLCI_EXITHANDLER else iffparse.IFFLCI_ENTRYHANDLER;
        if (_item.findItem(h, top.public.type, top.public.id, ident)) |item| {
            const handler: *_base.ChunkHandler = @ptrCast(@alignCast(_item.dataOf(item)));
            var command: i32 = if (leaving) iffparse.IFFCMD_EXIT else iffparse.IFFCMD_ENTRY;
            const answer: i32 = @truncate(@as(isize, @bitCast(ib.utility_base.CallHookPkt(handler.hook, handler.object, &command))));
            if (answer == iffparse.IFF_RETURN2CLIENT) return 0;
            if (answer != 0) return answer;
        }
        if (control == iffparse.IFFPARSE_STEP) break;
    }
    return eoc;
}
