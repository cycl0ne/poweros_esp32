// SPDX-License-Identifier: MIT
//! A command buffer's recording: commands one after another as bytes, in
//! chunks of memory, played back in the order they were written.
//!
//! A command is a head - what it is and how many bytes it takes, a
//! multiple of 8 - and the command's own fields after it, then the array
//! it carries, if any: the regions of a copy, the buffers bound. What a
//! command names - a buffer, an image, a pipeline - it keeps the address
//! of: as in Vulkan, the object has to last until the work recorded is
//! done. Everything else is copied in as the command is recorded, so the
//! caller's arrays may go at once.
//!
//! The chunks are kept when the buffer is reset, and written over by the
//! next recording, unless the reset gives them back.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const ExecBase = sdk.interface.exec.ExecBase;

/// What a command is.
pub const Op = enum(u16) {
    barrier,
    copy_buffer_to_image,
    copy_buffer,
    begin_render_pass,
    end_render_pass,
    bind_pipeline,
    bind_vertex_buffers,
    bind_index_buffer,
    bind_descriptor_sets,
    push_constants,
    set_viewport,
    set_scissor,
    draw,
    draw_indexed,
    _,
};

/// The start of every command.
pub const Head = extern struct {
    op: Op,
    pad: u16 = 0,
    /// Its bytes, head included, a multiple of 8: where the next starts.
    bytes: u32 = 0,
};

/// The bytes of a chunk, its own head apart, unless a command needs more.
const chunk_bytes = 4096 - @sizeOf(Chunk);

/// Aligned to 8, so that its size is a multiple of 8 and the commands
/// after it start on 8 - with 4-byte pointers too. AllocVec's blocks are
/// aligned to MEM_BLOCKSIZE, 8 at least.
const Chunk = struct {
    next: ?*Chunk align(8) = null,
    /// The bytes written, and the bytes there are room for.
    used: u32 = 0,
    size: u32,

    fn bytes(chunk: *Chunk) [*]align(8) u8 {
        return @ptrFromInt(@intFromPtr(chunk) + @sizeOf(Chunk));
    }
};

pub const Stream = struct {
    first: ?*Chunk = null,
    /// The chunk written into now.
    last: ?*Chunk = null,
    /// A command did not fit in memory: the recording is not whole.
    failed: bool = false,

    /// Command `command` written, with `carried` after its fields; nothing,
    /// and the recording failed, when memory runs out.
    pub fn put(stream: *Stream, sys: *ExecBase, command: anytype, comptime Item: type, carried: []const Item) void {
        const T = @TypeOf(command);
        comptime std.debug.assert(@alignOf(T) <= 8 and @alignOf(Item) <= 8 and @sizeOf(T) % @alignOf(Item) == 0);
        const bytes = std.mem.alignForward(usize, @sizeOf(T) + carried.len * @sizeOf(Item), 8);
        const at = stream.room(sys, bytes) orelse return;
        const into: *T = @ptrCast(at);
        into.* = command;
        into.head = .{ .op = T.op, .bytes = @intCast(bytes) };
        const after: [*]Item = @ptrCast(@alignCast(at + @sizeOf(T)));
        @memcpy(after[0..carried.len], carried);
    }

    /// `bytes` more in the stream, a multiple of 8; null when memory runs
    /// out.
    fn room(stream: *Stream, sys: *ExecBase, bytes: usize) ?[*]align(8) u8 {
        if (stream.failed) return null;
        if (stream.last) |chunk| {
            if (chunk.size - chunk.used >= bytes) return stream.take(chunk, bytes);
        }
        // The next chunk kept from an earlier recording, the first after a
        // reset, if it is large enough.
        const kept = if (stream.last) |chunk| chunk.next else stream.first;
        if (kept) |next| {
            if (next.size >= bytes) {
                stream.last = next;
                return stream.take(next, bytes);
            }
        }
        const size = @max(chunk_bytes, bytes);
        const memory = sys.AllocVec(@sizeOf(Chunk) + size, exec.MEMF_ANY) orelse {
            stream.failed = true;
            return null;
        };
        const chunk: *Chunk = @ptrCast(@alignCast(memory));
        chunk.* = .{ .next = kept, .size = @intCast(size) };
        if (stream.last) |last| last.next = chunk else stream.first = chunk;
        stream.last = chunk;
        return stream.take(chunk, bytes);
    }

    fn take(_: *Stream, chunk: *Chunk, bytes: usize) [*]align(8) u8 {
        const at = chunk.bytes() + chunk.used;
        chunk.used += @intCast(bytes);
        return @alignCast(at);
    }

    /// Back to nothing recorded: the chunks kept for the next recording,
    /// or given back with `release`.
    pub fn reset(stream: *Stream, sys: *ExecBase, release: bool) void {
        if (release) return stream.free(sys);
        var chunk = stream.first;
        while (chunk) |each| : (chunk = each.next) each.used = 0;
        stream.last = null;
        stream.failed = false;
    }

    /// Every chunk given back.
    pub fn free(stream: *Stream, sys: *ExecBase) void {
        var chunk = stream.first;
        while (chunk) |each| {
            chunk = each.next;
            sys.FreeVec(each);
        }
        stream.* = .{};
    }

    /// The commands, in the order they were recorded.
    pub fn commands(stream: *const Stream) Reader {
        return .{ .chunk = if (stream.last != null) stream.first else null, .last = stream.last };
    }
};

/// The commands of a stream, one after the other: from its first chunk to
/// the one written last, the chunks after it kept from an earlier
/// recording.
pub const Reader = struct {
    chunk: ?*Chunk,
    last: ?*Chunk,
    at: u32 = 0,

    pub fn next(reader: *Reader) ?*const Head {
        while (reader.chunk) |chunk| {
            if (reader.at < chunk.used) {
                const head: *const Head = @ptrCast(@alignCast(chunk.bytes() + reader.at));
                reader.at += head.bytes;
                return head;
            }
            reader.chunk = if (chunk == reader.last) null else chunk.next;
            reader.at = 0;
        }
        return null;
    }
};

/// The command of type `T` that `head` starts.
pub fn as(comptime T: type, head: *const Head) *const T {
    return @ptrCast(@alignCast(head));
}

/// The array a command of type `T` carries after its fields: `count`
/// items of `Item`.
pub fn items(comptime T: type, comptime Item: type, command: *const T, count: usize) []const Item {
    const after: [*]const Item = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(command)) + @sizeOf(T)));
    return after[0..count];
}
