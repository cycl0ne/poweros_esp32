// SPDX-License-Identifier: MPL-2.0
//! PIPE:, a pipe (FIFO) between two processes: a ROM module
//! ("pipe-handler", a ResidentHandler) built against the SDK only.
//! dos.library's init adds the "PIPE" node that names it, and GetDeviceProc
//! starts the one process on first use.
//!
//! `PIPE:[name][/bufsize][/limit]`: a name meets another program on the same
//! channel (`list >pipe:ll` in one shell, `type pipe:ll` in another).
//! Without a name every open makes a channel of its own, which therefore
//! nobody else can reach - the PIPE command names the junctions of a
//! pipeline for that reason. `bufsize` is the size
//! of the blocks it keeps the data in (default 1024), `limit` how many of
//! them at most (default 16). A channel takes one reader and one writer; a
//! second of either is ERROR_OBJECT_IN_USE.
//!
//! Packets: FINDINPUT, FINDOUTPUT, FINDUPDATE, READ, WRITE, END,
//! IS_FILESYSTEM (DOSFALSE), anything else ERROR_ACTION_NOT_KNOWN.
//!
//! What the two sides see:
//! - A READ on an empty channel waits while a writer holds it: 0 bytes means
//!   the end, so it must not be answered early. When the writer closes, the
//!   pending READs are answered (what is left, then 0).
//! - A WRITE that would go past `limit` blocks waits for the reader to take
//!   some, then goes on. Without a reader (it closed) a write ends with
//!   ERROR_BROKEN_PIPE, so a producer can't fill memory for nobody.
//!
//! A named channel lives until both sides have held it and let go, so `write PIPE:x` and a later `type PIPE:x` meet: what
//! was written waits for its reader. An unnamed one goes as soon as its
//! opens are closed, since nobody can name it again.
//!
//! A full pipe holds the writer: without a limit a runaway producer would
//! eat all of memory, so a limit is the default, not an option.
//!
//! One process serves every channel, which keeps the packets of both sides
//! pending instead of blocking a process per open; handlers are one process
//! per node, as con-handler is. No ACTION_STARTUP mountlist arguments
//! (de_NumBuffers, de_SizeBlock): the name carries them.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const DosPacket = dos.DosPacket;
const Process = dos.Process;
const MsgPort = exec.MsgPort;

pub const HANDLER_NAME = "pipe-handler";
const HANDLER_VERSION = 1;
const HANDLER_REVISION = 0;
const BUILD_DATE = "16.9.2026";
const HANDLER_VERSION_STRING =
    "\x00$VER: " ++ HANDLER_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ HANDLER_VERSION, HANDLER_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// A channel's name, without "PIPE:".
const max_name = 64;
/// Channels at once, and the packets waiting on one.
const max_channels = 8;
const max_waiting = 8;
/// Bytes per block, and blocks per channel, when the name says nothing.
const default_bufsize = 1024;
const default_limit = 16;
/// The most either may be, so a name can't ask for all of memory.
const max_bufsize = 64 * 1024;
const max_limit = 256;

/// One block of a channel's FIFO: `data[out..in]` is what it holds.
const Block = struct {
    next: ?*Block = null,
    in: u32 = 0,
    out: u32 = 0,
    /// `size` bytes follow the block in the same allocation.
    size: u32 = 0,

    fn bytes(b: *Block) [*]u8 {
        return @ptrFromInt(@intFromPtr(b) + @sizeOf(Block));
    }
    fn used(b: *const Block) u32 {
        return b.in - b.out;
    }
    fn room(b: *const Block) u32 {
        return b.size - b.in;
    }
};

/// A channel: its FIFO, the two sides, and the packets waiting on it.
const Channel = struct {
    /// Empty: the slot is free. A channel without a name is "".
    name: [max_name]u8 = @splat(0),
    named: bool = false,
    in_use: bool = false,
    bufsize: u32 = default_bufsize,
    limit: u32 = default_limit,
    head: ?*Block = null,
    tail: ?*Block = null,
    blocks: u32 = 0,
    /// The handles of the one reader and the one writer.
    reader: ?*dos.FileHandle = null,
    writer: ?*dos.FileHandle = null,
    /// Whether each side was ever there: a READ before any writer waits
    /// (one may still be starting),
    /// and a channel only goes once both have come and gone.
    ever_writer: bool = false,
    ever_reader: bool = false,
    /// READs with nothing to give yet, and WRITEs with no room.
    reads: [max_waiting]?*DosPacket = @splat(null),
    writes: [max_waiting]?*DosPacket = @splat(null),
    /// How much of a waiting WRITE has gone in already.
    written: [max_waiting]u32 = @splat(0),

    fn bytesReady(c: *const Channel) u32 {
        var n: u32 = 0;
        var b = c.head;
        while (b) |block| : (b = block.next) n += block.used();
        return n;
    }
};

pub fn Handler(comptime Io: type) type {
    return struct {
        const Self = @This();

        io: *Io,
        channels: [max_channels]Channel = @splat(.{}),

        pub fn init(io: *Io) Self {
            return .{ .io = io };
        }

        pub fn packet(h: *Self, pkt: *DosPacket) void {
            switch (pkt.getAction()) {
                .findinput => h.open(pkt, false),
                .findoutput, .findupdate => h.open(pkt, true),
                .read => h.read(pkt),
                .write => h.write(pkt),
                .end => h.end(pkt),
                .is_filesystem => h.io.reply(pkt, dos.DOSFALSE, 0),
                else => h.io.reply(pkt, dos.DOSFALSE, dos.ERROR_ACTION_NOT_KNOWN),
            }
        }

        // --- Opening ---

        /// FINDINPUT/FINDOUTPUT: the channel the name asks for, made if it
        /// isn't there. The handle's key is the channel.
        fn open(h: *Self, pkt: *DosPacket, writing: bool) void {
            const fh = pkt.args.find.fh orelse return h.io.reply(pkt, dos.DOSFALSE, dos.ERROR_INVALID_LOCK);
            var spec: Spec = undefined;
            if (!parseName(pkt.args.find.name, &spec)) return h.io.reply(pkt, dos.DOSFALSE, dos.ERROR_BAD_STREAM_NAME);

            const c = h.channelFor(&spec) orelse return h.io.reply(pkt, dos.DOSFALSE, dos.ERROR_NO_FREE_STORE);
            const side = if (writing) &c.writer else &c.reader;
            if (side.* != null) {
                h.freeIfUnused(c);
                return h.io.reply(pkt, dos.DOSFALSE, dos.ERROR_OBJECT_IN_USE);
            }
            side.* = fh;
            if (writing) c.ever_writer = true else c.ever_reader = true;
            fh.key = c;
            h.io.reply(pkt, dos.DOSTRUE, 0);
            // A reader that was waiting for a writer to appear can go on.
            if (writing) h.serveReads(c);
        }

        /// The channel of that name, or a free slot for it.
        fn channelFor(h: *Self, spec: *const Spec) ?*Channel {
            if (spec.named) {
                for (&h.channels) |*c| {
                    if (c.in_use and c.named and std.mem.eql(u8, span(&c.name), span(&spec.name))) return c;
                }
            }
            for (&h.channels) |*c| {
                if (c.in_use) continue;
                c.* = .{
                    .in_use = true,
                    .named = spec.named,
                    .bufsize = spec.bufsize,
                    .limit = spec.limit,
                };
                @memcpy(c.name[0..spec.name.len], &spec.name);
                return c;
            }
            return null;
        }

        // --- Reading ---

        fn read(h: *Self, pkt: *DosPacket) void {
            const c = channelOf(pkt.args.io.fh) orelse return h.io.reply(pkt, -1, dos.ERROR_INVALID_LOCK);
            if (pkt.args.io.length <= 0 or pkt.args.io.buffer == null) return h.io.reply(pkt, 0, 0);
            for (&c.reads) |*slot| {
                if (slot.* != null) continue;
                slot.* = pkt;
                h.serveReads(c);
                return;
            }
            h.io.reply(pkt, -1, dos.ERROR_NO_FREE_STORE);
        }

        /// Every waiting READ that can be answered now: what the channel
        /// holds, or 0 once no writer can come.
        fn serveReads(h: *Self, c: *Channel) void {
            for (&c.reads) |*slot| {
                const pkt = slot.* orelse continue;
                const want: u32 = @intCast(pkt.args.io.length);
                const got = h.take(c, pkt.args.io.buffer.?, want);
                if (got == 0 and c.writer != null) continue; // more may come
                if (got == 0 and !c.ever_writer) continue; // the writer may still be starting
                slot.* = null;
                h.io.reply(pkt, @intCast(got), 0);
            }
            // Room again: a held WRITE can go on.
            h.serveWrites(c);
        }

        /// Up to `want` bytes out of the channel into `buffer`.
        fn take(h: *Self, c: *Channel, buffer: [*]u8, want: u32) u32 {
            var done: u32 = 0;
            while (done < want) {
                const block = c.head orelse break;
                const n = @min(block.used(), want - done);
                if (n == 0) {
                    c.head = block.next;
                    if (c.head == null) c.tail = null;
                    c.blocks -= 1;
                    h.io.free(block, @sizeOf(Block) + block.size);
                    continue;
                }
                @memcpy(buffer[done..][0..n], block.bytes()[block.out..][0..n]);
                block.out += n;
                done += n;
            }
            return done;
        }

        // --- Writing ---

        fn write(h: *Self, pkt: *DosPacket) void {
            const c = channelOf(pkt.args.io.fh) orelse return h.io.reply(pkt, -1, dos.ERROR_INVALID_LOCK);
            const length = pkt.args.io.length;
            if (length <= 0 or pkt.args.io.buffer == null) return h.io.reply(pkt, 0, 0);
            if (c.reader == null and !h.putRoom(c)) {
                // Nobody will ever read it, so it is not buffered.
                return h.io.reply(pkt, -1, dos.ERROR_BROKEN_PIPE);
            }
            const done = h.put(c, pkt.args.io.buffer.?, @intCast(length), 0);
            if (done == @as(u32, @intCast(length))) {
                h.io.reply(pkt, length, 0);
                h.serveReads(c);
                return;
            }
            // Full: keep the packet until the reader has taken some.
            for (&c.writes, &c.written) |*slot, *written| {
                if (slot.* != null) continue;
                slot.* = pkt;
                written.* = done;
                h.serveReads(c);
                return;
            }
            h.io.reply(pkt, @intCast(done), dos.ERROR_NO_FREE_STORE);
        }

        /// Whether another block may be allocated.
        fn putRoom(h: *Self, c: *Channel) bool {
            _ = h;
            return c.blocks < c.limit;
        }

        /// `bytes[from..]` into the channel, as far as its limit allows; how
        /// much of the whole went in.
        fn put(h: *Self, c: *Channel, bytes: [*]const u8, length: u32, from: u32) u32 {
            var done = from;
            while (done < length) {
                var block = c.tail;
                if (block == null or block.?.room() == 0) {
                    if (!h.putRoom(c)) break;
                    const made = h.newBlock(c) orelse break;
                    block = made;
                }
                const b = block.?;
                const n = @min(b.room(), length - done);
                @memcpy(b.bytes()[b.in..][0..n], bytes[done..][0..n]);
                b.in += n;
                done += n;
            }
            return done;
        }

        fn newBlock(h: *Self, c: *Channel) ?*Block {
            const block: *Block = @ptrCast(@alignCast(h.io.alloc(@sizeOf(Block) + c.bufsize) orelse return null));
            block.* = .{ .size = c.bufsize };
            if (c.tail) |t| t.next = block else c.head = block;
            c.tail = block;
            c.blocks += 1;
            return block;
        }

        /// Every held WRITE that fits now.
        fn serveWrites(h: *Self, c: *Channel) void {
            for (&c.writes, &c.written) |*slot, *written| {
                const pkt = slot.* orelse continue;
                const length: u32 = @intCast(pkt.args.io.length);
                const done = h.put(c, pkt.args.io.buffer.?, length, written.*);
                written.* = done;
                if (done < length and c.reader != null) continue; // still full
                slot.* = null;
                if (done < length) {
                    h.io.reply(pkt, @intCast(done), dos.ERROR_BROKEN_PIPE); // the reader went
                } else {
                    h.io.reply(pkt, @intCast(done), 0);
                }
            }
        }

        // --- Closing ---

        fn end(h: *Self, pkt: *DosPacket) void {
            const fh = pkt.args.file.fh;
            const c = channelOf(fh) orelse return h.io.reply(pkt, dos.DOSTRUE, 0);
            if (c.reader == fh) {
                c.reader = null;
                // Its waiting READs go, and a writer with nobody to write to
                // is let go as well.
                for (&c.reads) |*slot| {
                    const waiting = slot.* orelse continue;
                    slot.* = null;
                    h.io.reply(waiting, 0, 0);
                }
                h.serveWrites(c);
            }
            if (c.writer == fh) {
                c.writer = null;
                h.serveReads(c); // what is left, then the end (0)
            }
            h.io.reply(pkt, dos.DOSTRUE, 0);
            h.freeIfUnused(c);
        }

        /// A channel nobody holds any more. A named one stays until both sides have held it and let go, so what a
        /// writer left waits for its reader; an unnamed one goes at once,
        /// since nobody can name it again.
        fn freeIfUnused(h: *Self, c: *Channel) void {
            if (c.reader != null or c.writer != null) return;
            if (c.named and !(c.ever_reader and c.ever_writer)) return;
            var b = c.head;
            while (b) |block| {
                b = block.next;
                h.io.free(block, @sizeOf(Block) + block.size);
            }
            c.* = .{};
        }
    };
}

fn channelOf(fh: ?*dos.FileHandle) ?*Channel {
    const handle = fh orelse return null;
    return @ptrCast(@alignCast(handle.key orelse return null));
}

fn span(buf: []const u8) []const u8 {
    return buf[0 .. std.mem.indexOfScalar(u8, buf, 0) orelse buf.len];
}

/// What a name asks for.
const Spec = struct {
    name: [max_name]u8,
    named: bool,
    bufsize: u32,
    limit: u32,
};

/// "PIPE:[name][/bufsize][/limit]". The device part is
/// already gone when the handler sees it, so this parses what is left. False
/// on a name that doesn't fit or a number that isn't one.
fn parseName(name: ?[*:0]const u8, spec: *Spec) bool {
    spec.* = .{ .name = @splat(0), .named = false, .bufsize = default_bufsize, .limit = default_limit };
    const text = if (name) |n| std.mem.span(n) else "";
    var parts = std.mem.splitScalar(u8, text, '/');
    const channel = parts.first();
    if (channel.len >= max_name) return false;
    if (channel.len != 0) {
        @memcpy(spec.name[0..channel.len], channel);
        spec.named = true;
    }
    if (parts.next()) |size| {
        if (size.len != 0) spec.bufsize = std.fmt.parseInt(u32, size, 10) catch return false;
    }
    if (parts.next()) |limit| {
        if (limit.len != 0) spec.limit = std.fmt.parseInt(u32, limit, 10) catch return false;
    }
    if (parts.next() != null) return false;
    if (spec.bufsize == 0 or spec.bufsize > max_bufsize) return false;
    if (spec.limit == 0 or spec.limit > max_limit) return false;
    return true;
}

// --- The handler's process ---

/// Io on the real system: replies through dos, memory through exec.
const SystemIo = struct {
    sys: *ExecBase,
    dl: *DosBase,

    pub fn reply(io: *SystemIo, pkt: *DosPacket, res1: isize, res2: i32) void {
        io.dl.ReplyPkt(pkt, res1, res2);
    }
    pub fn alloc(io: *SystemIo, size: u32) ?*anyopaque {
        return io.sys.AllocMem(size, exec.MEMF_ANY);
    }
    pub fn free(io: *SystemIo, block: *anyopaque, size: u32) void {
        io.sys.FreeMem(block, size);
    }
};

const State = struct {
    io: SystemIo,
    handler: Handler(SystemIo),
};

/// The handler process: STARTUP, then packets until the system goes down.
pub fn pipeHandler(sb: *ExecBase) callconv(.c) void {
    const lib = sb.OpenLibrary(dos.DOSNAME, 0) orelse return;
    const dl: *DosBase = @ptrCast(lib);
    const startup = dl.WaitPkt() orelse return;
    if (startup.getAction() != .startup) {
        dl.ReplyPkt(startup, dos.DOSFALSE, dos.ERROR_ACTION_NOT_KNOWN);
        return;
    }
    const me: *Process = @fieldParentPtr("task", sb.FindTask(null).?);
    const block = sb.AllocVec(@sizeOf(State), exec.MEMF_CLEAR) orelse
        return dl.ReplyPkt(startup, dos.DOSFALSE, dos.ERROR_NO_FREE_STORE);
    const st: *State = @ptrCast(@alignCast(block));
    st.io = .{ .sys = sb, .dl = dl };
    st.handler = Handler(SystemIo).init(&st.io);
    const node: ?*dos.DosList = @ptrFromInt(@as(usize, @bitCast(startup.args.raw[2])));
    if (node) |n| n.task = &me.msg_port;
    dl.ReplyPkt(startup, dos.DOSTRUE, 0);

    while (true) {
        const pkt = dl.WaitPkt() orelse continue;
        st.handler.packet(pkt);
    }
}

export const pipe_handler_tag: exec.ResidentHandler linksection(".resident") = .{
    .resident = .{
        .match_tag = &pipe_handler_tag.resident,
        .version = HANDLER_VERSION,
        .type = .handler,
        .pri = -121,
        .name = HANDLER_NAME,
        .id_string = HANDLER_VERSION_STRING[1..], // past the NUL: a C string
    },
    .handler = &pipeHandler,
};

// --- For the tests -----------------------------------------------------------

/// Handler's Io without a system: replies counted, memory from the test's
/// allocator.
pub const TestIo = struct {
    replies: usize = 0,
    last: ?*DosPacket = null,
    live: usize = 0,

    pub fn reply(io: *TestIo, pkt: *DosPacket, res1: isize, res2: i32) void {
        pkt.res1 = res1;
        pkt.res2 = res2;
        io.replies += 1;
        io.last = pkt;
    }
    pub fn alloc(io: *TestIo, size: u32) ?*anyopaque {
        const block = std.testing.allocator.alignedAlloc(u8, .of(Block), size) catch return null;
        io.live += 1;
        return block.ptr;
    }
    pub fn free(io: *TestIo, block: *anyopaque, size: u32) void {
        const p: [*]align(@alignOf(Block)) u8 = @ptrCast(@alignCast(block));
        std.testing.allocator.free(p[0..size]);
        io.live -= 1;
    }
};

const testing = std.testing;

test "PIPE: a writer and a reader, what is written comes out, the end is 0" {
    var io: TestIo = .{};
    var h = Handler(TestIo).init(&io);
    var writer: dos.FileHandle = .{};
    var reader: dos.FileHandle = .{};

    var out = DosPacket.init(.findoutput, .{ .find = .{ .fh = &writer, .lock = null, .name = "one" } });
    h.packet(&out);
    try testing.expectEqual(dos.DOSTRUE, out.res1);
    var in = DosPacket.init(.findinput, .{ .find = .{ .fh = &reader, .lock = null, .name = "one" } });
    h.packet(&in);
    try testing.expectEqual(dos.DOSTRUE, in.res1);
    // The name is what brings the two sides together.
    try testing.expectEqual(channelOf(&writer).?, channelOf(&reader).?);
    // Two opens without a name are two channels, so they never meet.
    var lonely_a: dos.FileHandle = .{};
    var lonely_b: dos.FileHandle = .{};
    var anon_a = DosPacket.init(.findoutput, .{ .find = .{ .fh = &lonely_a, .lock = null, .name = "" } });
    h.packet(&anon_a);
    var anon_b = DosPacket.init(.findinput, .{ .find = .{ .fh = &lonely_b, .lock = null, .name = "" } });
    h.packet(&anon_b);
    try testing.expect(channelOf(&lonely_a).? != channelOf(&lonely_b).?);
    for ([_]*dos.FileHandle{ &lonely_a, &lonely_b }) |fh| {
        var close = DosPacket.init(.end, .{ .file = .{ .fh = fh } });
        h.packet(&close);
    }

    var write = DosPacket.init(.write, .{ .io = .{ .fh = &writer, .buffer = @constCast("hello"), .length = 5 } });
    h.packet(&write);
    try testing.expectEqual(@as(isize, 5), write.res1);

    var buffer: [8]u8 = undefined;
    var read = DosPacket.init(.read, .{ .io = .{ .fh = &reader, .buffer = &buffer, .length = 8 } });
    h.packet(&read);
    try testing.expectEqual(@as(isize, 5), read.res1);
    try testing.expectEqualStrings("hello", buffer[0..5]);

    // Nothing there: the READ waits while the writer is open.
    const before = io.replies;
    h.packet(&read);
    try testing.expectEqual(before, io.replies);
    // The writer closes: the waiting READ ends with 0.
    var close_w = DosPacket.init(.end, .{ .file = .{ .fh = &writer } });
    h.packet(&close_w);
    try testing.expectEqual(@as(isize, 0), read.res1);

    var close_r = DosPacket.init(.end, .{ .file = .{ .fh = &reader } });
    h.packet(&close_r);
    try testing.expectEqual(@as(usize, 0), io.live); // every block freed
}

test "PIPE: a named channel meets, a second reader is refused" {
    var io: TestIo = .{};
    var h = Handler(TestIo).init(&io);
    var writer: dos.FileHandle = .{};
    var reader: dos.FileHandle = .{};
    var other: dos.FileHandle = .{};

    var out = DosPacket.init(.findoutput, .{ .find = .{ .fh = &writer, .lock = null, .name = "ll" } });
    h.packet(&out);
    var in = DosPacket.init(.findinput, .{ .find = .{ .fh = &reader, .lock = null, .name = "ll" } });
    h.packet(&in);
    try testing.expectEqual(channelOf(&writer).?, channelOf(&reader).?);

    var again = DosPacket.init(.findinput, .{ .find = .{ .fh = &other, .lock = null, .name = "ll" } });
    h.packet(&again);
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, again.res2);

    // A different name is a different channel.
    var third = DosPacket.init(.findinput, .{ .find = .{ .fh = &other, .lock = null, .name = "other" } });
    h.packet(&third);
    try testing.expectEqual(dos.DOSTRUE, third.res1);
    try testing.expect(channelOf(&other).? != channelOf(&reader).?);

    for ([_]*dos.FileHandle{ &writer, &reader, &other }) |fh| {
        var close = DosPacket.init(.end, .{ .file = .{ .fh = fh } });
        h.packet(&close);
    }
    try testing.expectEqual(@as(usize, 0), io.live);
}

test "PIPE: a named channel keeps what was written until a reader comes" {
    var io: TestIo = .{};
    var h = Handler(TestIo).init(&io);
    var writer: dos.FileHandle = .{};

    var out = DosPacket.init(.findoutput, .{ .find = .{ .fh = &writer, .lock = null, .name = "keep" } });
    h.packet(&out);
    var write = DosPacket.init(.write, .{ .io = .{ .fh = &writer, .buffer = @constCast("kept"), .length = 4 } });
    h.packet(&write);
    var close_w = DosPacket.init(.end, .{ .file = .{ .fh = &writer } });
    h.packet(&close_w);
    try testing.expect(io.live > 0); // no reader has been: it waits, with its data

    var reader: dos.FileHandle = .{};
    var in = DosPacket.init(.findinput, .{ .find = .{ .fh = &reader, .lock = null, .name = "keep" } });
    h.packet(&in);
    var buffer: [8]u8 = undefined;
    var read = DosPacket.init(.read, .{ .io = .{ .fh = &reader, .buffer = &buffer, .length = 8 } });
    h.packet(&read);
    try testing.expectEqual(@as(isize, 4), read.res1);
    try testing.expectEqualStrings("kept", buffer[0..4]);
    var close_r = DosPacket.init(.end, .{ .file = .{ .fh = &reader } });
    h.packet(&close_r);
    try testing.expectEqual(@as(usize, 0), io.live); // both sides have been: it goes
}

test "PIPE: a full channel holds the writer until the reader takes some" {
    var io: TestIo = .{};
    var h = Handler(TestIo).init(&io);
    var writer: dos.FileHandle = .{};
    var reader: dos.FileHandle = .{};

    // Two blocks of eight bytes: sixteen fit, no more.
    var out = DosPacket.init(.findoutput, .{ .find = .{ .fh = &writer, .lock = null, .name = "small/8/2" } });
    h.packet(&out);
    try testing.expectEqual(dos.DOSTRUE, out.res1);
    var in = DosPacket.init(.findinput, .{ .find = .{ .fh = &reader, .lock = null, .name = "small/8/2" } });
    h.packet(&in);

    const twenty = "12345678901234567890";
    var write = DosPacket.init(.write, .{ .io = .{ .fh = &writer, .buffer = @constCast(twenty), .length = 20 } });
    const before = io.replies;
    h.packet(&write);
    try testing.expectEqual(before, io.replies); // held: only 16 fit

    var buffer: [16]u8 = undefined;
    var read = DosPacket.init(.read, .{ .io = .{ .fh = &reader, .buffer = &buffer, .length = 16 } });
    h.packet(&read);
    try testing.expectEqual(@as(isize, 16), read.res1);
    try testing.expectEqualStrings("1234567890123456", &buffer);
    // Room again: the writer was answered with the whole length.
    try testing.expectEqual(@as(isize, 20), write.res1);
    try testing.expectEqual(@as(i32, 0), write.res2);

    var rest = DosPacket.init(.read, .{ .io = .{ .fh = &reader, .buffer = &buffer, .length = 16 } });
    h.packet(&rest);
    try testing.expectEqual(@as(isize, 4), rest.res1);
    try testing.expectEqualStrings("7890", buffer[0..4]);

    for ([_]*dos.FileHandle{ &writer, &reader }) |fh| {
        var close = DosPacket.init(.end, .{ .file = .{ .fh = fh } });
        h.packet(&close);
    }
    try testing.expectEqual(@as(usize, 0), io.live);
}

test "PIPE: a write with no reader ends, a bad name is refused" {
    var io: TestIo = .{};
    var h = Handler(TestIo).init(&io);
    var writer: dos.FileHandle = .{};

    // Unnamed ("PIPE://1"), so it goes when its opens are closed.
    var out = DosPacket.init(.findoutput, .{ .find = .{ .fh = &writer, .lock = null, .name = "/8/1" } });
    h.packet(&out);
    // Eight bytes fit; the rest has nobody to go to.
    var write = DosPacket.init(.write, .{ .io = .{ .fh = &writer, .buffer = @constCast("0123456789"), .length = 10 } });
    h.packet(&write);
    try testing.expectEqual(dos.ERROR_BROKEN_PIPE, write.res2);
    var close = DosPacket.init(.end, .{ .file = .{ .fh = &writer } });
    h.packet(&close);
    try testing.expectEqual(@as(usize, 0), io.live);

    var fh: dos.FileHandle = .{};
    var bad = DosPacket.init(.findinput, .{ .find = .{ .fh = &fh, .lock = null, .name = "x/notanumber" } });
    h.packet(&bad);
    try testing.expectEqual(dos.ERROR_BAD_STREAM_NAME, bad.res2);
    var toomany = DosPacket.init(.findinput, .{ .find = .{ .fh = &fh, .lock = null, .name = "x/8/2/3" } });
    h.packet(&toomany);
    try testing.expectEqual(dos.ERROR_BAD_STREAM_NAME, toomany.res2);
}
