// SPDX-License-Identifier: MIT
//! The handle and its stream: how the library reaches the bytes.
//!
//! Every read, write and seek goes through one hook, which the program
//! chose when it said what the stream was. The hook is called with the
//! handle and an `IFFStreamCmd`, and answers 0 for done; anything else
//! is turned into the `IFFERR_` that fits what was asked, so a stream of
//! a program's own needs to know nothing about the library's error
//! codes.
//!
//! A stream that cannot seek forwards is seeked by reading and throwing
//! the bytes away, which is why reading an IFF file needs no seek at
//! all. A stream that cannot seek back cannot be written to directly,
//! because a chunk's size may have to be written back into it; those
//! writes are held in memory (`parse/_parse.zig`) until the file is
//! done.

const sdk = @import("sdk");
const exec = sdk.exec;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const IFFParseBase = _base.IFFParseBase;
const Handle = _base.Handle;

/// How much is read at a time to seek forwards on a stream that cannot.
const seek_buffer = 512;

/// One command to the stream hook: 0, or `client_err` when the hook
/// could not do it.
pub fn streamAction(h: *Handle, command: i32, client_err: i32, buf: ?[*]u8, bytes: i32) i32 {
    const hook = h.stream_hook orelse return iffparse.IFFERR_NOHOOK;
    var cmd = iffparse.IFFStreamCmd{ .command = command, .buf = buf, .bytes = bytes };
    const answer = h.base.utility_base.CallHookPkt(hook, &h.public, &cmd);
    return if (answer != 0) client_err else 0;
}

pub fn userRead(h: *Handle, buf: [*]u8, bytes: i32) i32 {
    return streamAction(h, iffparse.IFFCMD_READ, iffparse.IFFERR_READ, buf, bytes);
}

pub fn userWrite(h: *Handle, buf: [*]const u8, bytes: i32) i32 {
    return streamAction(h, iffparse.IFFCMD_WRITE, iffparse.IFFERR_WRITE, @constCast(buf), bytes);
}

/// The stream moved `bytes` from where it is. A stream that cannot seek
/// forwards is moved on by reading; one that cannot seek back cannot go
/// backwards at all.
pub fn userSeek(h: *Handle, bytes: i32) i32 {
    if (bytes < 0 and h.public.flags & iffparse.IFFF_RSEEK == 0) return iffparse.IFFERR_SEEK;
    if (bytes > 0 and h.public.flags & (iffparse.IFFF_FSEEK | iffparse.IFFF_RSEEK) == 0) {
        const sys = h.base.sys_base;
        const size: usize = @intCast(@min(bytes, seek_buffer));
        const memory = sys.AllocVec(size, exec.MEMF_ANY) orelse return iffparse.IFFERR_SEEK;
        defer sys.FreeVec(memory);
        const buf: [*]u8 = @ptrCast(memory);
        var left = bytes;
        while (left > 0) {
            const step = @min(left, @as(i32, @intCast(size)));
            const error_code = userRead(h, buf, step);
            if (error_code != 0) return error_code;
            left -= step;
        }
        return 0;
    }
    if (bytes == 0) return 0;
    return streamAction(h, iffparse.IFFCMD_SEEK, iffparse.IFFERR_SEEK, null, bytes);
}

/// The chunk the walk is in, or null before it has entered one: the
/// stack's bottom node has no id and is nobody's chunk.
pub fn currentChunk(h: *Handle) ?*_base.Node {
    const head = h.stack.head orelse return null;
    const node: *_base.Node = @ptrCast(@alignCast(head));
    if (node.public.id == 0) return null;
    return node;
}
