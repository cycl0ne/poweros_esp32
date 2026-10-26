// SPDX-License-Identifier: MIT
//! A pack read in place, from wherever it is (a file, memory): an
//! entry's head, its body inflated a piece at a time - how many
//! compressed bytes it took, which the pack says nowhere, and their
//! CRC-32 - and whole objects with their deltas applied.
//!
//! **A delta chain** is walked down without recursion - the offsets of
//! the deltas on the way kept in a list - to the object at its bottom,
//! and applied on the way back up, one delta at a time: two objects and
//! a delta in memory at once, however long the chain. A REF_DELTA's base
//! comes from the lookup the pack was given (the store), the pack's own
//! idx first.

const sdk = @import("sdk");
const exec = sdk.exec;
const compression = sdk.compression;
const ExecBase = sdk.interface.exec.ExecBase;
const CompressionBase = sdk.interface.compression.CompressionBase;
const _git = @import("_git.zig");
const object = @import("object.zig");
const pack = @import("pack.zig");
const Id = _git.Id;
const Type = object.Type;

/// Where a pack's bytes come from.
pub const Source = struct {
    context: *anyopaque,
    /// The pack's bytes from `offset` into `into`: how many - fewer only
    /// at the pack's end - or below 0 when reading failed.
    read: *const fn (context: *anyopaque, offset: u64, into: []u8) i32,
};

pub const Failure = enum {
    none,
    /// The source could not be read.
    read,
    /// An entry's head is none, or a body's stream is broken.
    entry,
    /// A delta does not fit its base.
    delta,
    /// A delta's base is not to be had.
    base,
    /// No memory for an object.
    memory,
};

/// An object read whole: its bytes in memory of their own (`free`).
pub const Object = struct {
    kind: Type,
    data: []u8,

    pub fn free(object_read: *Object, sys: *ExecBase) void {
        if (object_read.data.len != 0) sys.FreeVec(object_read.data.ptr);
        object_read.data = &.{};
    }
};

/// A REF_DELTA's base by its id; null when there is none.
pub const LookupFn = *const fn (context: *anyopaque, id: *const Id) ?Object;

const input_bytes = 8192;

/// One entry's body inflated as it is read.
pub const BodyReader = struct {
    zb: *CompressionBase,
    source: Source,
    stream: compression.Stream = .{},
    /// Where in the pack the next read of input goes.
    next_read: u64 = 0,
    /// The source has no more.
    input_ended: bool = false,
    ended: bool = false,
    /// The CRC-32 of the compressed bytes taken, after what it was
    /// started with.
    crc: u32 = 0,
    input: [input_bytes]u8 = undefined,

    /// The stream at `offset` set up, the CRC-32 starting from `crc`:
    /// false when there is no memory for its state.
    pub fn start(reader: *BodyReader, offset: u64, crc: u32) bool {
        reader.stream = .{};
        reader.next_read = offset;
        reader.input_ended = false;
        reader.ended = false;
        reader.crc = crc;
        return reader.zb.InitInflate(&reader.stream, compression.FORMAT_ZLIB) == compression.COMPRESS_OK;
    }

    pub fn finish(reader: *BodyReader) void {
        reader.zb.EndInflate(&reader.stream);
    }

    /// The compressed bytes taken so far.
    pub fn taken(reader: *const BodyReader) u64 {
        return reader.stream.total_in;
    }

    /// Up to `into.len` inflated bytes: how many, 0 at the stream's end;
    /// null when the source failed or the stream is broken or cut short.
    pub fn read(reader: *BodyReader, into: []u8) ?usize {
        if (reader.ended) return 0;
        while (true) {
            if (reader.stream.avail_in == 0 and !reader.input_ended) {
                const got = reader.source.read(reader.source.context, reader.next_read, &reader.input);
                if (got < 0) return null;
                if (got == 0) reader.input_ended = true;
                reader.next_read += @intCast(got);
                reader.stream.next_in = &reader.input;
                reader.stream.avail_in = @intCast(got);
            }
            const before: u32 = reader.stream.avail_in;
            const from = reader.stream.next_in;
            reader.stream.next_out = into.ptr;
            reader.stream.avail_out = @intCast(into.len);
            const result = reader.zb.Inflate(&reader.stream, if (reader.input_ended) compression.FLUSH_FINISH else compression.FLUSH_NONE);
            const consumed = before - reader.stream.avail_in;
            if (consumed != 0) reader.crc = reader.zb.Crc32(reader.crc, from, consumed);
            const produced = into.len - reader.stream.avail_out;
            if (result == compression.COMPRESS_END) {
                reader.ended = true;
                return produced;
            }
            if (result != compression.COMPRESS_OK) return null;
            if (produced != 0) return produced;
            // Input left, room left, and nothing done: no stream.
            if (consumed == 0 and reader.stream.avail_in != 0) return null;
            if (into.len == 0 or (reader.input_ended and consumed == 0)) return null;
        }
    }

    /// Exactly `into.len` bytes, the stream ending with them: false when
    /// it is shorter, longer or broken.
    pub fn readExact(reader: *BodyReader, into: []u8) bool {
        var filled: usize = 0;
        while (filled < into.len) {
            const got = reader.read(into[filled..]) orelse return false;
            if (got == 0) return false;
            filled += got;
        }
        var extra: [1]u8 = undefined;
        const more = reader.read(&extra) orelse return false;
        return more == 0;
    }
};

/// The head of the entry at `offset`.
pub fn readHead(source: Source, offset: u64) ?pack.EntryHead {
    var bytes: [32]u8 = undefined;
    const got = source.read(source.context, offset, &bytes);
    if (got <= 0) return null;
    return switch (pack.parseEntryHead(bytes[0..@intCast(got)])) {
        .head => |head| head,
        .err => null,
    };
}

pub const Pack = struct {
    sys: *ExecBase,
    reader: BodyReader,
    lookup: ?LookupFn = null,
    lookup_context: *anyopaque = undefined,
    failure: Failure = .none,
    /// The offsets of a chain's deltas, from the one asked for down.
    chain: []u64 = &.{},

    /// A pack read from `source`, ready.
    pub fn init(reading: *Pack, sys: *ExecBase, zb: *CompressionBase, source: Source) void {
        reading.sys = sys;
        reading.reader = .{ .zb = zb, .source = source };
        reading.lookup = null;
        reading.failure = .none;
        reading.chain = &.{};
    }

    pub fn deinit(reading: *Pack) void {
        if (reading.chain.len != 0) reading.sys.FreeVec(reading.chain.ptr);
        reading.chain = &.{};
    }

    /// The body of the entry at `offset`, whose head is `head`, inflated
    /// into memory of its own.
    pub fn body(reading: *Pack, offset: u64, head: *const pack.EntryHead) ?[]u8 {
        const size: usize = @intCast(head.size);
        const memory: []u8 = if (size == 0) &.{} else blk: {
            const block = reading.sys.AllocVec(size, exec.MEMF_ANY) orelse {
                _ = reading.fail(.memory);
                return null;
            };
            break :blk @as([*]u8, @ptrCast(block))[0..size];
        };
        if (!reading.reader.start(offset + head.length, 0)) {
            if (size != 0) reading.sys.FreeVec(memory.ptr);
            _ = reading.fail(.memory);
            return null;
        }
        const whole = reading.reader.readExact(memory);
        reading.reader.finish();
        if (!whole) {
            if (size != 0) reading.sys.FreeVec(memory.ptr);
            _ = reading.fail(.entry);
            return null;
        }
        return memory;
    }

    /// The object whose entry starts at `offset`, its deltas applied.
    pub fn readObject(reading: *Pack, offset: u64) ?Object {
        // Down the chain to an object that is no delta.
        var depth: usize = 0;
        var at = offset;
        var bottom: Object = undefined;
        while (true) {
            const head = readHead(reading.reader.source, at) orelse {
                _ = reading.fail(.entry);
                return null;
            };
            switch (head.kind) {
                .ofs_delta => {
                    if (head.base_distance == 0 or head.base_distance > at) {
                        _ = reading.fail(.entry);
                        return null;
                    }
                    if (!reading.push(depth, at)) return null;
                    depth += 1;
                    at -= head.base_distance;
                },
                .ref_delta => {
                    const lookup = reading.lookup orelse {
                        _ = reading.fail(.base);
                        return null;
                    };
                    if (!reading.push(depth, at)) return null;
                    depth += 1;
                    bottom = lookup(reading.lookup_context, &head.base_id) orelse {
                        _ = reading.fail(.base);
                        return null;
                    };
                    break;
                },
                else => {
                    bottom = .{ .kind = head.kind, .data = reading.body(at, &head) orelse return null };
                    break;
                },
            }
        }
        // Back up, a delta at a time.
        var current = bottom;
        while (depth > 0) {
            depth -= 1;
            const delta_at = reading.chain[depth];
            const head = readHead(reading.reader.source, delta_at).?;
            const delta = reading.body(delta_at, &head) orelse {
                current.free(reading.sys);
                return null;
            };
            defer if (delta.len != 0) reading.sys.FreeVec(delta.ptr);
            const result = applied(reading, current.data, delta) orelse {
                current.free(reading.sys);
                return null;
            };
            current.free(reading.sys);
            current = .{ .kind = current.kind, .data = result };
        }
        return current;
    }

    /// The `depth`th offset of the chain kept, the list grown as needed.
    fn push(reading: *Pack, depth: usize, offset: u64) bool {
        if (depth == reading.chain.len) {
            const larger = if (reading.chain.len == 0) 64 else reading.chain.len * 2;
            const block = reading.sys.AllocVec(larger * @sizeOf(u64), exec.MEMF_ANY) orelse return reading.fail(.memory);
            const grown = @as([*]u64, @ptrCast(@alignCast(block)))[0..larger];
            @memcpy(grown[0..reading.chain.len], reading.chain);
            if (reading.chain.len != 0) reading.sys.FreeVec(reading.chain.ptr);
            reading.chain = grown;
        }
        reading.chain[depth] = offset;
        return true;
    }

    fn fail(reading: *Pack, failure: Failure) bool {
        if (reading.failure == .none) reading.failure = failure;
        return false;
    }
};

/// `delta` applied to `base`, into memory of its own: null, with the
/// pack's failure set, when it does not fit or there is no memory.
pub fn applied(reading: *Pack, base: []const u8, delta: []const u8) ?[]u8 {
    const sizes = pack.deltaSizes(delta) orelse {
        _ = reading.fail(.delta);
        return null;
    };
    if (sizes.base != base.len or sizes.result > 0x7FFF_FFFF) {
        _ = reading.fail(.delta);
        return null;
    }
    const size: usize = @intCast(sizes.result);
    const result: []u8 = if (size == 0) &.{} else blk: {
        const block = reading.sys.AllocVec(size, exec.MEMF_ANY) orelse {
            _ = reading.fail(.memory);
            return null;
        };
        break :blk @as([*]u8, @ptrCast(block))[0..size];
    };
    if (!pack.applyDelta(base, delta, result)) {
        if (size != 0) reading.sys.FreeVec(result.ptr);
        _ = reading.fail(.delta);
        return null;
    }
    return result;
}
