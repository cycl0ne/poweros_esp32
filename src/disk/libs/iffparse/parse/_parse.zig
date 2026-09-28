// SPDX-License-Identifier: MIT
//! The walk itself: pushing and popping chunks, reading and writing
//! them.
//!
//! **The file's numbers are big-endian.** A chunk's id is four
//! characters with the first in the highest byte, and its size is a
//! 32-bit count the same way round, so both are read and written a byte
//! at a time (`readBE`, `writeBE`) rather than copied. What a program
//! puts in a chunk is its own and is never turned round.
//!
//! **Reading** pushes a chunk by reading its eight header bytes, which
//! count towards the parent's scan, and pops it by seeking past whatever
//! is left of it and the pad byte an odd-sized chunk carries.
//!
//! **Writing** pushes a chunk by writing those eight bytes, and pops it
//! by writing the pad byte and, for a chunk pushed `IFFSIZE_UNKNOWN`,
//! writing its size back over the header. A stream that cannot seek back
//! cannot be written back into, so its writes are held here as a list of
//! buffers and sent out in one go when the outermost chunk is popped;
//! the size is written into the buffer that holds it.

const sdk = @import("sdk");
const exec = sdk.exec;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _handle = @import("../handle/_handle.zig");
const _item = @import("../item/_item.zig");
const Handle = _base.Handle;
const Node = _base.Node;
const WriteBuffer = _base.WriteBuffer;
const ReadChunkBytes = @import("../chunk/readchunkbytes.zig").ReadChunkBytes;
const WriteChunkBytes = @import("../chunk/writechunkbytes.zig").WriteChunkBytes;

/// Four bytes of the file as the number they make.
pub fn readBE(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) << 24 | @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | bytes[3];
}

/// A number as the four bytes the file holds.
pub fn writeBE(value: u32, bytes: *[4]u8) void {
    bytes[0] = @truncate(value >> 24);
    bytes[1] = @truncate(value >> 16);
    bytes[2] = @truncate(value >> 8);
    bytes[3] = @truncate(value);
}

/// A chunk's size with its pad byte: chunks start on even offsets.
fn padded(size: i32) i32 {
    return (size + 1) & ~@as(i32, 1);
}

// --- reading ----------------------------------------------------------------

/// A chunk entered: its id and size read, and a context node pushed for
/// it. `first` reads the eight bytes straight from the stream, since
/// there is no chunk yet for them to count against.
pub fn pushChunkR(h: *Handle, first: bool) i32 {
    const ib = h.base;
    const top = _handle.currentChunk(h);
    if (top == null and !first) return iffparse.IFFERR_EOF;
    const parent_type: u32 = if (top) |t| t.public.type else 0;

    var header: [8]u8 = undefined;
    if (first) {
        const failed = _handle.userRead(h, &header, 8);
        if (failed != 0) return failed;
    } else if (ReadChunkBytes(ib, &h.public, &header, 8) != 8) {
        return iffparse.IFFERR_READ;
    }
    const id = readBE(header[0..4]);
    const size: i32 = @bitCast(readBE(header[4..8]));
    if (!goodID(id)) {
        return if (h.public.flags & _base.IFFFP_NEWIO != 0) iffparse.IFFERR_NOTIFF else iffparse.IFFERR_SYNTAX;
    }
    if (size < 0) return iffparse.IFFERR_MANGLED;
    if (top) |t| {
        if (size > t.public.size - t.public.scan) return iffparse.IFFERR_MANGLED;
    }

    const node = _item.allocContextNode(ib) orelse return iffparse.IFFERR_NOMEM;
    node.public.type = parent_type;
    node.public.id = id;
    node.public.size = size;
    node.public.scan = 0;
    ib.sys_base.AddHead(@ptrCast(&h.stack), @ptrCast(&node.public.node));
    h.public.depth += 1;
    return 0;
}

/// A chunk left: the rest of it skipped, its node freed and the parent's
/// count moved on.
pub fn popChunkR(h: *Handle) i32 {
    const ib = h.base;
    const top = _handle.currentChunk(h) orelse return iffparse.IFFERR_EOF;
    const rsize = padded(top.public.size);
    if (top.public.scan < rsize) {
        const failed = _handle.userSeek(h, rsize - top.public.scan);
        if (failed != 0) return failed;
    }
    ib.sys_base.Remove(@ptrCast(&top.public.node));
    h.public.depth -= 1;
    _item.freeContextNode(ib, top);
    if (_handle.currentChunk(h)) |parent| parent.public.scan += rsize;
    return 0;
}

/// A generic chunk's type, which follows its header.
fn readGenericType(h: *Handle) i32 {
    const top = _handle.currentChunk(h) orelse return iffparse.IFFERR_EOF;
    var bytes: [4]u8 = undefined;
    if (ReadChunkBytes(h.base, &h.public, &bytes, 4) != 4) return iffparse.IFFERR_READ;
    top.public.type = readBE(&bytes);
    if (!goodType(top.public.type)) return iffparse.IFFERR_MANGLED;
    return 0;
}

/// The walk moved on one step: into the next chunk, or to the end of the
/// one it is in.
///
/// The three states are the file just opened, poised at the end of a
/// chunk, and inside one. Just opened, the outermost chunk is pushed and
/// must be FORM, LIST or CAT. Poised, the chunk is popped. Inside a
/// generic chunk with something left in it, the next chunk is pushed;
/// inside one that is used up, or inside a chunk that holds no others,
/// the walk is poised at its end and `IFFERR_EOC` says so.
pub fn nextState(h: *Handle) i32 {
    if (h.public.flags & _base.IFFFP_NEWIO != 0) {
        const failed = pushChunkR(h, true);
        h.public.flags &= ~(_base.IFFFP_NEWIO | _base.IFFFP_PAUSE);
        if (failed != 0) return failed;
        const top = _handle.currentChunk(h) orelse return iffparse.IFFERR_EOF;
        if (top.public.id != iffparse.ID_FORM and top.public.id != iffparse.ID_CAT and top.public.id != iffparse.ID_LIST) {
            return iffparse.IFFERR_NOTIFF;
        }
        if (top.public.size & 1 != 0) return iffparse.IFFERR_MANGLED;
        return readGenericType(h);
    }

    if (h.public.flags & _base.IFFFP_PAUSE != 0) {
        const failed = popChunkR(h);
        if (failed != 0) return failed;
        h.public.flags &= ~_base.IFFFP_PAUSE;
    }

    const top = _handle.currentChunk(h) orelse return iffparse.IFFERR_EOF;
    const top_id = top.public.id;
    if (iffparse.isGenericID(top_id)) {
        if (top.public.scan < top.public.size) {
            const failed = pushChunkR(h, false);
            if (failed != 0) return failed;
            const inner = _handle.currentChunk(h) orelse return iffparse.IFFERR_EOF;
            if (!iffparse.isGenericID(inner.public.id)) {
                // A plain chunk belongs in a FORM or a PROP and nowhere
                // else.
                if (top_id != iffparse.ID_FORM and top_id != iffparse.ID_PROP) return iffparse.IFFERR_SYNTAX;
                return 0;
            }
            // A PROP belongs in a LIST and nowhere else.
            if (inner.public.id == iffparse.ID_PROP and top_id != iffparse.ID_LIST) return iffparse.IFFERR_SYNTAX;
            return readGenericType(h);
        }
        if (top.public.scan != top.public.size) return iffparse.IFFERR_MANGLED;
    }
    h.public.flags |= _base.IFFFP_PAUSE;
    return iffparse.IFFERR_EOC;
}

// --- writing ----------------------------------------------------------------

/// A write: straight out on a stream that seeks back, else held here.
pub fn deferredWrite(h: *Handle, buf: [*]const u8, size: i32) i32 {
    if (h.public.flags & iffparse.IFFF_RSEEK != 0) return _handle.userWrite(h, buf, size);
    const sys = h.base.sys_base;
    const bytes: usize = @intCast(size);
    const memory = sys.AllocVec(@sizeOf(WriteBuffer) + bytes, exec.MEMF_ANY) orelse return iffparse.IFFERR_NOMEM;
    const wb: *WriteBuffer = @ptrCast(@alignCast(memory));
    wb.* = .{ .size = size };
    const into: [*]u8 = @ptrFromInt(@intFromPtr(wb) + @sizeOf(WriteBuffer));
    @memcpy(into[0..bytes], buf[0..bytes]);
    sys.AddTail(@ptrCast(&h.write_buffers), @ptrCast(&wb.node));
    return 0;
}

/// The held writes thrown away, which is what a write that went wrong
/// leaves behind.
pub fn freeBufferedStream(h: *Handle) void {
    const sys = h.base.sys_base;
    while (sys.RemHead(@ptrCast(&h.write_buffers))) |node| sys.FreeVec(node);
}

/// The held writes sent out, oldest first, when the file is done.
fn flushBuffers(h: *Handle) i32 {
    const sys = h.base.sys_base;
    while (sys.RemHead(@ptrCast(&h.write_buffers))) |node| {
        const wb: *WriteBuffer = @ptrCast(@alignCast(node));
        const from: [*]u8 = @ptrFromInt(@intFromPtr(wb) + @sizeOf(WriteBuffer));
        const failed = _handle.userWrite(h, from, wb.size);
        sys.FreeVec(wb);
        if (failed != 0) {
            freeBufferedStream(h);
            return failed;
        }
    }
    return 0;
}

/// A size written back `back` bytes before where the stream stands: into
/// the stream itself when it seeks back, else into the buffer that holds
/// those bytes.
fn backPatch(h: *Handle, back: i32, value: i32) i32 {
    var bytes: [4]u8 = undefined;
    writeBE(@bitCast(value), &bytes);
    if (h.public.flags & iffparse.IFFF_RSEEK != 0) {
        var failed = _handle.userSeek(h, -back);
        if (failed != 0) return failed;
        failed = _handle.userWrite(h, &bytes, 4);
        if (failed != 0) return failed;
        return _handle.userSeek(h, back - 4);
    }
    // Back through the held writes until the one that holds those bytes.
    var at = h.write_buffers.tail_pred;
    var pos: i32 = 0;
    while (at) |node| : (at = node.pred) {
        if (node.pred == null) return iffparse.IFFERR_SEEK;
        const wb: *WriteBuffer = @ptrCast(@alignCast(node));
        pos += wb.size;
        if (pos >= back) {
            const into: [*]u8 = @ptrFromInt(@intFromPtr(wb) + @sizeOf(WriteBuffer));
            const offset: usize = @intCast(pos - back);
            @memcpy(into[offset .. offset + 4], &bytes);
            return 0;
        }
    }
    return iffparse.IFFERR_SEEK;
}

/// A chunk started for writing: its header written and a context node
/// pushed for it.
pub fn pushChunkW(h: *Handle, form_type: u32, id: u32, size: i32) i32 {
    const ib = h.base;
    const top = _handle.currentChunk(h);
    var first = false;
    var parent_type: u32 = 0;
    if (top) |t| {
        parent_type = t.public.type;
    } else if (h.public.flags & _base.IFFFP_NEWIO != 0) {
        first = true;
    } else return iffparse.IFFERR_EOF;

    // Everything that can be checked is checked before a byte is
    // written, so that a file refused is a file not started.
    if (!goodID(id)) return iffparse.IFFERR_SYNTAX;
    if (first) {
        if (id != iffparse.ID_FORM and id != iffparse.ID_CAT and id != iffparse.ID_LIST) return iffparse.IFFERR_NOTIFF;
    } else if (id == iffparse.ID_PROP) {
        if (top.?.public.id != iffparse.ID_LIST) return iffparse.IFFERR_SYNTAX;
    } else if (iffparse.isGenericID(id)) {
        if (!goodType(form_type)) return iffparse.IFFERR_NOTIFF;
    } else if (top.?.public.id != iffparse.ID_FORM and top.?.public.id != iffparse.ID_PROP) {
        return iffparse.IFFERR_SYNTAX;
    }

    // Past every check: the file has started, and a chunk refused above
    // has left it where it was.
    if (first) h.public.flags &= ~_base.IFFFP_NEWIO;

    var header: [8]u8 = undefined;
    writeBE(id, header[0..4]);
    writeBE(@bitCast(size), header[4..8]);
    if (first) {
        const failed = deferredWrite(h, &header, 8);
        if (failed != 0) return failed;
    } else if (WriteChunkBytes(ib, &h.public, &header, 8) != 8) {
        return iffparse.IFFERR_WRITE;
    }

    const node = _item.allocContextNode(ib) orelse return iffparse.IFFERR_NOMEM;
    node.public.id = id;
    node.public.size = size;
    node.public.scan = 0;
    node.public.type = parent_type;
    ib.sys_base.AddHead(@ptrCast(&h.stack), @ptrCast(&node.public.node));
    h.public.depth += 1;

    if (iffparse.isGenericID(id)) {
        var kind: [4]u8 = undefined;
        writeBE(form_type, &kind);
        if (WriteChunkBytes(ib, &h.public, &kind, 4) != 4) return iffparse.IFFERR_WRITE;
        node.public.type = form_type;
    }
    return 0;
}

/// A chunk ended: the pad byte written, the size written back when it
/// was not known, and the parent's count moved on. Popping the outermost
/// chunk sends out whatever was held back.
pub fn popChunkW(h: *Handle) i32 {
    const ib = h.base;
    const top = _handle.currentChunk(h) orelse return iffparse.IFFERR_EOF;
    var size = top.public.size;
    const unknown = size == iffparse.IFFSIZE_UNKNOWN;
    if (unknown) {
        size = top.public.scan;
    } else if (size != top.public.scan) {
        return iffparse.IFFERR_MANGLED;
    }
    const rsize = padded(size);
    if (rsize > size) {
        const pad = [_]u8{0};
        const failed = deferredWrite(h, &pad, 1);
        if (failed != 0) return failed;
    }
    ib.sys_base.Remove(@ptrCast(&top.public.node));
    h.public.depth -= 1;
    _item.freeContextNode(ib, top);

    if (unknown) {
        const failed = backPatch(h, rsize + 4, size);
        if (failed != 0) return failed;
    }
    const parent = _handle.currentChunk(h) orelse return flushBuffers(h);
    parent.public.scan += rsize;
    if (parent.public.size != iffparse.IFFSIZE_UNKNOWN and parent.public.scan > parent.public.size) {
        return iffparse.IFFERR_MANGLED;
    }
    return 0;
}

// --- what an id may be ------------------------------------------------------

/// Printable characters, and no leading space except for ID_NULL.
pub fn goodID(id: u32) bool {
    if (id >> 24 == ' ' and id != iffparse.ID_NULL) return false;
    var shift: u5 = 24;
    while (true) : (shift -= 8) {
        const c: u8 = @truncate(id >> shift);
        if (c < ' ' or c > '~') return false;
        if (shift == 0) return true;
    }
}

/// A good id of upper case, digits and spaces only.
pub fn goodType(form_type: u32) bool {
    if (!goodID(form_type)) return false;
    var shift: u5 = 24;
    while (true) : (shift -= 8) {
        const c: u8 = @truncate(form_type >> shift);
        const ok = (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == ' ';
        if (!ok) return false;
        if (shift == 0) return true;
    }
}
