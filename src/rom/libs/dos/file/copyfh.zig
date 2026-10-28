// SPDX-License-Identifier: MPL-2.0
//! CopyFH: bytes from one open file into another, copied by their
//! handler.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const packets = @import("../packet/_packet.zig");
const failWith = _file.failWith;
const FileHandle = dos.FileHandle;

/// Copies bytes from one open file into another on the same handler,
/// without passing them through the caller.
///
/// SYNOPSIS:
/// ```zig
/// fn CopyFH(db: *DosBase, to: ?*FileHandle, from: ?*FileHandle, length: i64) i64
/// ```
///
/// SINCE: 1.13. LVO -608.
///
/// INPUTS:
/// - `to` - the handle written to, from its position.
/// - `from` - the handle read from, from its position.
/// - `length` - how many bytes at most; 64 bits on every machine.
///
/// RESULT:
/// The bytes copied - fewer than `length` when `from` ends first, 0 when
/// it is at its end - or -1 with `IoErr()` set. `ERROR_ACTION_NOT_KNOWN`
/// says the bytes cannot be copied this way: the handles are on two
/// handlers, or theirs has no `ACTION_COPY_FH`. Then the caller copies
/// them itself, with Read and Write.
///
/// BEHAVIOR:
/// Both handles' buffers are flushed first, so the handler's positions are
/// the caller's. Then `ACTION_COPY_FH` goes to the handler, in `CopyArgs`;
/// it answers DOSTRUE with the count in its `answer`, or DOSFALSE with the
/// error. Both positions move on by the bytes copied.
///
/// A handler may copy fewer bytes than asked for and still not be at the
/// end, as Read may; the caller asks again for the rest.
///
/// CONTEXT:
/// - Waits: yes: it sends the handler a packet and waits for the answer,
///   which may take as long as the copy does.
/// - Interrupts: no. It waits.
/// - Locks: none taken; no spinlock may be held around it: it waits.
/// - Process: a Task will do; the answer comes back on a port of its own.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// - A file system on a server (smb-handler) has the server copy the
///   bytes, so they cross the network not at all; one on a local disk may
///   leave the packet to the caller.
/// - Ask in pieces - some MiB - where progress is shown or a copy is to be
///   stoppable: the packet is not answered before its piece is done.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Read`, `Write`, `Seek`
///
/// EXAMPLES:
/// ```zig
/// const copied = dos_lib.CopyFH(out, in, 16 << 20);
/// if (copied < 0 and dos_lib.IoErr() == dos.ERROR_ACTION_NOT_KNOWN) {
///     // copy with Read and Write
/// }
/// ```
pub fn CopyFH(db: *DosBase, to: ?*FileHandle, from: ?*FileHandle, length: i64) i64 {
    const out = to orelse return failWith(db, dos.ERROR_INVALID_LOCK, -1);
    const in = from orelse return failWith(db, dos.ERROR_INVALID_LOCK, -1);
    const port = out.task orelse return failWith(db, dos.ERROR_INVALID_LOCK, -1);
    if (in.task == null) return failWith(db, dos.ERROR_INVALID_LOCK, -1);
    if (length < 0) return failWith(db, dos.ERROR_BAD_NUMBER, -1);
    if (in.task != port) return failWith(db, dos.ERROR_ACTION_NOT_KNOWN, -1);
    if (length == 0) return 0;
    if (!_file.flush(db, in) or !_file.flush(db, out)) return -1;
    var sent: dos.PacketArgs = .{ .raw = @splat(0) };
    sent.copy = .{ .to = out, .from = in, .length = @intCast(length) };
    const answer = packets.exchangeArgs(db.sys_base, port, @intFromEnum(dos.ActionCode.copy_fh), sent) orelse
        return failWith(db, dos.ERROR_NO_FREE_STORE, -1);
    if (answer.res1 == dos.DOSFALSE) return failWith(db, answer.res2, -1);
    const back: dos.PacketArgs = .{ .raw = answer.args };
    return @intCast(back.copy.answer);
}
