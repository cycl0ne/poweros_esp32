// SPDX-License-Identifier: MIT
//! Host tests of iffparse.library: a file written to memory and read
//! back, the contexts that decide which property is which, and what the
//! library refuses.
//!
//! The stream is a block of memory with a hook of the test's own, which
//! is what `InitIFF` is for. The same file is written twice, once to a
//! stream that seeks and once to one that does not, because the two take
//! different paths through the writer and must come out the same.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const iffparse = sdk.iffparse;
const host = @import("host_rom");
const kexec = host.exec;
const IFFParseBase = @import("../iffparse_base.zig").IFFParseBase;

const AllocIFF = @import("../handle/allociff.zig").AllocIFF;
const FreeIFF = @import("../handle/freeiff.zig").FreeIFF;
const InitIFF = @import("../handle/initiff.zig").InitIFF;
const OpenIFF = @import("../handle/openiff.zig").OpenIFF;
const CloseIFF = @import("../handle/closeiff.zig").CloseIFF;
const ParseIFF = @import("../parse/parseiff.zig").ParseIFF;
const PushChunk = @import("../chunk/pushchunk.zig").PushChunk;
const PopChunk = @import("../chunk/popchunk.zig").PopChunk;
const ReadChunkBytes = @import("../chunk/readchunkbytes.zig").ReadChunkBytes;
const WriteChunkBytes = @import("../chunk/writechunkbytes.zig").WriteChunkBytes;
const PropChunk = @import("../handler/propchunk.zig").PropChunk;
const PropChunks = @import("../handler/propchunks.zig").PropChunks;
const StopChunk = @import("../handler/stopchunk.zig").StopChunk;
const StopOnExit = @import("../handler/stoponexit.zig").StopOnExit;
const CollectionChunk = @import("../handler/collectionchunk.zig").CollectionChunk;
const FindProp = @import("../context/findprop.zig").FindProp;
const FindCollection = @import("../context/findcollection.zig").FindCollection;
const CurrentChunk = @import("../context/currentchunk.zig").CurrentChunk;
const ParentChunk = @import("../context/parentchunk.zig").ParentChunk;
const FindPropContext = @import("../context/findpropcontext.zig").FindPropContext;
const GoodID = @import("../id/goodid.zig").GoodID;
const GoodType = @import("../id/goodtype.zig").GoodType;
const IDtoStr = @import("../id/idtostr.zig").IDtoStr;

const testing = std.testing;
const ID = iffparse.MakeID;

test {
    _ = @import("../iffparse_lvo.zig");
}

/// A block of memory as an IFF stream, with a hook of its own.
const Memory = struct {
    bytes: [512]u8 = @splat(0),
    len: usize = 0,
    pos: usize = 0,
    hook: utility.Hook = .{},

    fn init(m: *Memory) void {
        m.hook = .{ .entry = &entry };
    }

    fn entry(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
        _ = hook;
        const iff: *iffparse.IFFHandle = @ptrCast(@alignCast(object.?));
        const cmd: *iffparse.IFFStreamCmd = @ptrCast(@alignCast(message.?));
        const m: *Memory = @ptrFromInt(iff.stream);
        const bytes: usize = @intCast(@max(cmd.bytes, 0));
        switch (cmd.command) {
            iffparse.IFFCMD_READ => {
                if (m.pos + bytes > m.len) return 1;
                @memcpy(cmd.buf.?[0..bytes], m.bytes[m.pos..][0..bytes]);
                m.pos += bytes;
                return 0;
            },
            iffparse.IFFCMD_WRITE => {
                if (m.pos + bytes > m.bytes.len) return 1;
                @memcpy(m.bytes[m.pos..][0..bytes], cmd.buf.?[0..bytes]);
                m.pos += bytes;
                m.len = @max(m.len, m.pos);
                return 0;
            },
            iffparse.IFFCMD_SEEK => {
                const at: i64 = @as(i64, @intCast(m.pos)) + cmd.bytes;
                if (at < 0 or at > @as(i64, @intCast(m.len))) return 1;
                m.pos = @intCast(at);
                return 0;
            },
            else => return 0,
        }
    }
};

/// exec and utility.library up, and a base with what the calls under
/// test use: memory through exec, hooks through utility.
const Rig = struct {
    base: IFFParseBase = undefined,
    ub: *host.utility.UtilityBase = undefined,

    fn up(rig: *Rig) !void {
        rig.ub = try host.utility.setUp();
        rig.base = .{
            .lib = .{},
            .sys_base = kexec.SysBase.iface(),
            .dos_base = undefined,
            .utility_base = @ptrCast(rig.ub),
        };
    }

    fn down(rig: *Rig) !void {
        try host.utility.tearDown(rig.ub);
        try kexec.expectNoLeaks();
    }
};

/// A `FORM FTXT` holding a `CHRS` and a `FVER`, written to `m`.
fn writeText(ib: *IFFParseBase, m: *Memory, seekable: bool, text: []const u8) !void {
    const iff = AllocIFF(ib).?;
    defer FreeIFF(ib, iff);
    m.init();
    iff.stream = @intFromPtr(m);
    const flags: u32 = if (seekable) iffparse.IFFF_FSEEK | iffparse.IFFF_RSEEK else 0;
    InitIFF(ib, iff, flags, &m.hook);
    try testing.expectEqual(@as(i32, 0), OpenIFF(ib, iff, iffparse.IFFF_WRITE));
    try testing.expectEqual(@as(i32, 0), PushChunk(ib, iff, ID("FTXT"), iffparse.ID_FORM, iffparse.IFFSIZE_UNKNOWN));
    try testing.expectEqual(@as(i32, 0), PushChunk(ib, iff, 0, ID("FVER"), 4));
    try testing.expectEqual(@as(i32, 4), WriteChunkBytes(ib, iff, "v1.0", 4));
    try testing.expectEqual(@as(i32, 0), PopChunk(ib, iff));
    try testing.expectEqual(@as(i32, 0), PushChunk(ib, iff, 0, ID("CHRS"), iffparse.IFFSIZE_UNKNOWN));
    try testing.expectEqual(@as(i32, @intCast(text.len)), WriteChunkBytes(ib, iff, text.ptr, @intCast(text.len)));
    try testing.expectEqual(@as(i32, 0), PopChunk(ib, iff));
    try testing.expectEqual(@as(i32, 0), PopChunk(ib, iff));
    CloseIFF(ib, iff);
}

test "iffparse: a form written and read back, and the same bytes either way the stream seeks" {
    var rig = Rig{};
    try rig.up();
    const ib = &rig.base;

    var seeking = Memory{};
    var buffered = Memory{};
    const text = "Hello, IFF";
    try writeText(ib, &seeking, true, text);
    try writeText(ib, &buffered, false, text);

    // A stream that cannot seek back holds the whole file and writes the
    // sizes into what it held: the bytes come out the same.
    try testing.expectEqual(seeking.len, buffered.len);
    try testing.expectEqualSlices(u8, seeking.bytes[0..seeking.len], buffered.bytes[0..buffered.len]);

    // FORM, size, FTXT, then the two chunks. An odd-sized chunk carries
    // a pad byte that its size does not count.
    try testing.expectEqualSlices(u8, "FORM", seeking.bytes[0..4]);
    try testing.expectEqualSlices(u8, "FTXT", seeking.bytes[8..12]);
    const form_size = @as(u32, seeking.bytes[4]) << 24 | @as(u32, seeking.bytes[5]) << 16 |
        @as(u32, seeking.bytes[6]) << 8 | seeking.bytes[7];
    try testing.expectEqual(seeking.len - 8, form_size);

    // Read it back: the version kept as a property, the text stopped at.
    const iff = AllocIFF(ib).?;
    seeking.pos = 0;
    iff.stream = @intFromPtr(&seeking);
    InitIFF(ib, iff, iffparse.IFFF_FSEEK | iffparse.IFFF_RSEEK, &seeking.hook);
    try testing.expectEqual(@as(i32, 0), OpenIFF(ib, iff, iffparse.IFFF_READ));
    try testing.expectEqual(@as(i32, 0), PropChunk(ib, iff, ID("FTXT"), ID("FVER")));
    try testing.expectEqual(@as(i32, 0), StopChunk(ib, iff, ID("FTXT"), ID("CHRS")));
    try testing.expectEqual(@as(i32, 0), ParseIFF(ib, iff, iffparse.IFFPARSE_SCAN));

    const chunk = CurrentChunk(ib, iff).?;
    try testing.expectEqual(ID("CHRS"), chunk.id);
    try testing.expectEqual(ID("FTXT"), chunk.type);
    try testing.expectEqual(@as(i32, @intCast(text.len)), chunk.size);
    // The chunk it is in is the FORM, which is also the property context.
    const parent = ParentChunk(ib, chunk).?;
    try testing.expectEqual(iffparse.ID_FORM, parent.id);
    try testing.expectEqual(parent, FindPropContext(ib, iff).?);

    const version = FindProp(ib, iff, ID("FTXT"), ID("FVER")).?;
    try testing.expectEqual(@as(i32, 4), version.size);
    try testing.expectEqualSlices(u8, "v1.0", version.data.?[0..4]);

    var into: [32]u8 = undefined;
    try testing.expectEqual(@as(i32, @intCast(text.len)), ReadChunkBytes(ib, iff, &into, @intCast(text.len)));
    try testing.expectEqualSlices(u8, text, into[0..text.len]);
    // The chunk is used up: nothing more comes out of it.
    try testing.expectEqual(@as(i32, 0), ReadChunkBytes(ib, iff, &into, 1));
    // And then the end of the file.
    try testing.expectEqual(iffparse.IFFERR_EOF, ParseIFF(ib, iff, iffparse.IFFPARSE_SCAN));
    CloseIFF(ib, iff);
    FreeIFF(ib, iff);
    try rig.down();
}

test "iffparse: a property of a form hides the list's, and a collection keeps every chunk" {
    var rig = Rig{};
    try rig.up();
    const ib = &rig.base;

    // LIST ABCD { PROP ABCD { DFLT "list" NOTE "p" }
    //             FORM ABCD { NOTE "a" NOTE "b" }
    //             FORM ABCD { DFLT "form" NOTE "c" } }
    var m = Memory{};
    {
        const iff = AllocIFF(ib).?;
        defer FreeIFF(ib, iff);
        m.init();
        iff.stream = @intFromPtr(&m);
        InitIFF(ib, iff, iffparse.IFFF_FSEEK | iffparse.IFFF_RSEEK, &m.hook);
        try testing.expectEqual(@as(i32, 0), OpenIFF(ib, iff, iffparse.IFFF_WRITE));
        _ = PushChunk(ib, iff, ID("ABCD"), iffparse.ID_LIST, iffparse.IFFSIZE_UNKNOWN);
        _ = PushChunk(ib, iff, ID("ABCD"), iffparse.ID_PROP, iffparse.IFFSIZE_UNKNOWN);
        _ = PushChunk(ib, iff, 0, ID("DFLT"), 4);
        _ = WriteChunkBytes(ib, iff, "list", 4);
        _ = PopChunk(ib, iff);
        _ = PushChunk(ib, iff, 0, ID("NOTE"), 1);
        _ = WriteChunkBytes(ib, iff, "p", 1);
        _ = PopChunk(ib, iff);
        _ = PopChunk(ib, iff);
        _ = PushChunk(ib, iff, ID("ABCD"), iffparse.ID_FORM, iffparse.IFFSIZE_UNKNOWN);
        for ([_][]const u8{ "a", "b" }) |one| {
            _ = PushChunk(ib, iff, 0, ID("NOTE"), 1);
            _ = WriteChunkBytes(ib, iff, one.ptr, 1);
            _ = PopChunk(ib, iff);
        }
        _ = PopChunk(ib, iff);
        _ = PushChunk(ib, iff, ID("ABCD"), iffparse.ID_FORM, iffparse.IFFSIZE_UNKNOWN);
        _ = PushChunk(ib, iff, 0, ID("DFLT"), 4);
        _ = WriteChunkBytes(ib, iff, "form", 4);
        _ = PopChunk(ib, iff);
        _ = PushChunk(ib, iff, 0, ID("NOTE"), 1);
        _ = WriteChunkBytes(ib, iff, "c", 1);
        _ = PopChunk(ib, iff);
        _ = PopChunk(ib, iff);
        try testing.expectEqual(@as(i32, 0), PopChunk(ib, iff));
        CloseIFF(ib, iff);
    }

    const iff = AllocIFF(ib).?;
    m.pos = 0;
    iff.stream = @intFromPtr(&m);
    InitIFF(ib, iff, iffparse.IFFF_FSEEK | iffparse.IFFF_RSEEK, &m.hook);
    try testing.expectEqual(@as(i32, 0), OpenIFF(ib, iff, iffparse.IFFF_READ));
    const wanted = [_]u32{ ID("ABCD"), ID("DFLT") };
    try testing.expectEqual(@as(i32, 0), PropChunks(ib, iff, &wanted, 1));
    try testing.expectEqual(@as(i32, 0), CollectionChunk(ib, iff, ID("ABCD"), ID("NOTE")));
    try testing.expectEqual(@as(i32, 0), StopOnExit(ib, iff, ID("ABCD"), iffparse.ID_FORM));

    // The first form has no DFLT of its own, so the list's is what it
    // sees, and the two notes it gathered are newest first. A stop at
    // the end of a chunk says so with IFFERR_EOC.
    try testing.expectEqual(iffparse.IFFERR_EOC, ParseIFF(ib, iff, iffparse.IFFPARSE_SCAN));
    var value = FindProp(ib, iff, ID("ABCD"), ID("DFLT")).?;
    try testing.expectEqualSlices(u8, "list", value.data.?[0..4]);
    // Newest first, and on past this form's own to the one the list
    // gathered, which every form in it sees.
    var note = FindCollection(ib, iff, ID("ABCD"), ID("NOTE")).?;
    try testing.expectEqualSlices(u8, "b", note.data.?[0..1]);
    note = note.next.?;
    try testing.expectEqualSlices(u8, "a", note.data.?[0..1]);
    note = note.next.?;
    try testing.expectEqualSlices(u8, "p", note.data.?[0..1]);
    try testing.expect(note.next == null);

    // The second has a DFLT of its own, which hides the list's. The two
    // notes of the first form went with it; the list's is still there.
    try testing.expectEqual(iffparse.IFFERR_EOC, ParseIFF(ib, iff, iffparse.IFFPARSE_SCAN));
    value = FindProp(ib, iff, ID("ABCD"), ID("DFLT")).?;
    try testing.expectEqualSlices(u8, "form", value.data.?[0..4]);
    note = FindCollection(ib, iff, ID("ABCD"), ID("NOTE")).?;
    try testing.expectEqualSlices(u8, "c", note.data.?[0..1]);
    try testing.expectEqualSlices(u8, "p", note.next.?.data.?[0..1]);
    try testing.expect(note.next.?.next == null);

    try testing.expectEqual(iffparse.IFFERR_EOF, ParseIFF(ib, iff, iffparse.IFFPARSE_SCAN));
    CloseIFF(ib, iff);
    FreeIFF(ib, iff);
    try rig.down();
}

test "iffparse: what it refuses - not IFF, a size that does not fit, a chunk out of place" {
    var rig = Rig{};
    try rig.up();
    const ib = &rig.base;

    // A file that does not begin FORM, LIST or CAT.
    {
        var m = Memory{};
        m.init();
        @memcpy(m.bytes[0..12], "JUNK\x00\x00\x00\x04ABCD");
        m.len = 12;
        const iff = AllocIFF(ib).?;
        defer FreeIFF(ib, iff);
        iff.stream = @intFromPtr(&m);
        InitIFF(ib, iff, iffparse.IFFF_FSEEK | iffparse.IFFF_RSEEK, &m.hook);
        _ = OpenIFF(ib, iff, iffparse.IFFF_READ);
        try testing.expectEqual(iffparse.IFFERR_NOTIFF, ParseIFF(ib, iff, iffparse.IFFPARSE_SCAN));
        CloseIFF(ib, iff);
    }

    // A chunk that says it is bigger than the form it is in.
    {
        var m = Memory{};
        m.init();
        @memcpy(m.bytes[0..24], "FORM\x00\x00\x00\x10ABCDNOTE\x00\x00\x00\x40abcd");
        m.len = 24;
        const iff = AllocIFF(ib).?;
        defer FreeIFF(ib, iff);
        iff.stream = @intFromPtr(&m);
        InitIFF(ib, iff, iffparse.IFFF_FSEEK | iffparse.IFFF_RSEEK, &m.hook);
        _ = OpenIFF(ib, iff, iffparse.IFFF_READ);
        try testing.expectEqual(iffparse.IFFERR_MANGLED, ParseIFF(ib, iff, iffparse.IFFPARSE_SCAN));
        CloseIFF(ib, iff);
    }

    // Writing: a PROP outside a LIST, and a plain chunk as the whole
    // file.
    {
        var m = Memory{};
        m.init();
        const iff = AllocIFF(ib).?;
        defer FreeIFF(ib, iff);
        iff.stream = @intFromPtr(&m);
        InitIFF(ib, iff, iffparse.IFFF_FSEEK | iffparse.IFFF_RSEEK, &m.hook);
        _ = OpenIFF(ib, iff, iffparse.IFFF_WRITE);
        try testing.expectEqual(iffparse.IFFERR_NOTIFF, PushChunk(ib, iff, 0, ID("NOTE"), 4));
        try testing.expectEqual(@as(i32, 0), PushChunk(ib, iff, ID("ABCD"), iffparse.ID_FORM, iffparse.IFFSIZE_UNKNOWN));
        try testing.expectEqual(iffparse.IFFERR_SYNTAX, PushChunk(ib, iff, ID("ABCD"), iffparse.ID_PROP, 4));
        // A size that is said and then not written is a file that does
        // not add up.
        try testing.expectEqual(@as(i32, 0), PushChunk(ib, iff, 0, ID("NOTE"), 8));
        try testing.expectEqual(@as(i32, 2), WriteChunkBytes(ib, iff, "ab", 2));
        try testing.expectEqual(iffparse.IFFERR_MANGLED, PopChunk(ib, iff));
        CloseIFF(ib, iff);
    }
    try rig.down();
}

test "iffparse: what four characters may be, and how they read" {
    var rig = Rig{};
    try rig.up();
    const ib = &rig.base;

    try testing.expect(GoodID(ib, ID("FORM")));
    try testing.expect(GoodID(ib, ID("body")));
    try testing.expect(GoodID(ib, iffparse.ID_NULL));
    try testing.expect(!GoodID(ib, ID(" FOO")));
    try testing.expect(!GoodID(ib, 0));

    try testing.expect(GoodType(ib, ID("ILBM")));
    try testing.expect(GoodType(ib, ID("8SVX")));
    try testing.expect(!GoodType(ib, ID("ilbm")));
    try testing.expect(!GoodType(ib, ID("IL-M")));

    var buf: [5]u8 = undefined;
    try testing.expectEqualStrings("CAT ", std.mem.span(IDtoStr(ib, iffparse.ID_CAT, &buf)));
    try rig.down();
}
