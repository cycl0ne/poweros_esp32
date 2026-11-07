// SPDX-License-Identifier: MIT
//! The H.265 decoder's host tests on whole clips: `rows.h265` and
//! `wide.h265` read by videoparse.library - made from its ROM tag on the
//! ROM's exec and utility - and their events decoded, alone and on three
//! workers, handed over a unit at a time and an access unit at a time,
//! with seeks and closes on the way.
//!
//! `rows.h265` is x265's (Main) of ffmpeg's testsrc2 at 128x128, 24
//! frames: 16x16 CTBs in three slices a picture and wavefronts, B
//! pyramids, weighted prediction, four references, open GOPs (a CRA every
//! 12 with RASL pictures before it). `wide.h265` is 8 frames of it in
//! 4:4:4 at 10 bits, with lossless CUs and transform skip. The hashes are
//! of ffmpeg's decode.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const vp = sdk.videoparse;
const utility = sdk.utility;
const host = @import("host_rom");
const kexec = host.exec;
const hevc = @import("hevccore");
const videoparse_init = @import("../../../videoparse/videoparse_init.zig");
const nal = @import("../../../videoparse/hevc/nal.zig");
const VideoParseBase = sdk.interface.videoparse.VideoParseBase;

const testing = std.testing;

/// Memory lent to exec: an HEVC parser takes some 330 KiB.
var lent: [1024 * 1024]u8 align(16) = undefined;

/// exec and utility up with memory lent, videoparse.library made and
/// opened.
const Rig = struct {
    ub: *host.utility.UtilityBase = undefined,
    region: *exec.MemHeader = undefined,
    library: *exec.Library = undefined,
    vpb: *VideoParseBase = undefined,

    fn up(rig: *Rig) !void {
        rig.ub = try host.utility.setUp();
        const sys = kexec.SysBase.iface();
        rig.region = sys.AddMemList(lent.len, exec.MEMF_ANY, 0, &lent, "lent").?;
        const lib = kexec.InitResident(kexec.SysBase, &videoparse_init.videoparse_library_tag, null) orelse return error.NoLibrary;
        rig.library = @ptrCast(@alignCast(lib));
        rig.vpb = @ptrCast(sys.OpenLibrary(vp.VIDEOPARSENAME, 1) orelse return error.NoBase);
    }

    fn down(rig: *Rig) !void {
        const sys = kexec.SysBase.iface();
        sys.CloseLibrary(rig.vpb.lib());
        _ = sys.RemLibrary(rig.library);
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        sys.Remove(&rig.region.node);
        try host.utility.tearDown(rig.ub);
        kexec.deinit();
    }
};

/// Workers on threads that wait by yielding: `sleep` returns at once,
/// as it may.
const TestCores = struct {
    cores: hevc.Cores = undefined,
    jobs: [3]usize = @splat(0),
    args: [3]usize = @splat(0),
    threads: [3]std.Thread = undefined,
    quit: bool = false,

    fn of(ctx: *anyopaque) *TestCores {
        return @ptrCast(@alignCast(ctx));
    }
    fn run(ctx: *anyopaque, worker: u32, job: *const fn (*anyopaque) void, arg: *anyopaque) void {
        const t = of(ctx);
        t.args[worker] = @intFromPtr(arg);
        @atomicStore(usize, &t.jobs[worker], @intFromPtr(job), .seq_cst);
    }
    fn arm(_: *anyopaque, _: u32) void {}
    fn sleep(_: *anyopaque, _: u32) void {
        std.Thread.yield() catch {};
    }
    fn wake(_: *anyopaque) void {}
    fn work(t: *TestCores, i: usize) void {
        while (!@atomicLoad(bool, &t.quit, .acquire)) {
            const job = @atomicRmw(usize, &t.jobs[i], .Xchg, 0, .acq_rel);
            if (job == 0) {
                std.Thread.yield() catch {};
                continue;
            }
            const f: *const fn (*anyopaque) void = @ptrFromInt(job);
            f(@ptrFromInt(t.args[i]));
        }
    }
};

const TestMemory = struct {
    fn alloc(_: *anyopaque, len: usize, clear: bool) ?[*]u8 {
        const m = testing.allocator.alignedAlloc(u8, .@"16", len) catch return null;
        if (clear) @memset(m, 0);
        return m.ptr;
    }
    fn free(_: *anyopaque, memory: [*]u8, len: usize) void {
        const s: []align(16) u8 = @alignCast(memory[0..len]);
        testing.allocator.free(s);
    }
};

const Decoded = struct { frames: u32 = 0, hash: u64 = 0xcbf29ce484222325 };

const Way = struct {
    /// Each access unit a packet, as an MP4's packet is.
    units_end: bool = false,
    /// After so many packets: everything dropped, as for a seek, and the
    /// stream decoded from its start again.
    reset_after: ?u32 = null,
    /// After so many packets: the decoder closed, whatever it is doing.
    stop_after: ?u32 = null,
};

/// The packets of a stream in Annex B form: a unit each, or an access
/// unit each - which begins, once a slice came, at a parameter set, an
/// access unit delimiter, a prefix SEI or a reserved unit before the
/// first slice, or a slice segment that is a picture's first.
const Packets = struct {
    data: []const u8,
    access_units: bool,
    at: usize = 0,

    fn next(it: *Packets) ?[]const u8 {
        var units = nal.AnnexB{ .data = it.data[it.at..] };
        const first = units.next() orelse {
            it.at = it.data.len;
            return null;
        };
        var end = it.data.len;
        var sliced = isSlice(first);
        while (units.next()) |u| {
            if (!it.access_units or (sliced and begins(u))) {
                end = @intFromPtr(u.ptr) - @intFromPtr(it.data.ptr) - 3;
                break;
            }
            if (isSlice(u)) sliced = true;
        }
        const packet = it.data[it.at..end];
        it.at = end;
        return packet;
    }

    fn isSlice(u: []const u8) bool {
        const h = nal.header(u) catch return false;
        return h.isSlice();
    }

    fn begins(u: []const u8) bool {
        const h = nal.header(u) catch return false;
        if (h.isSlice()) return u.len > 2 and u[2] & 0x80 != 0;
        return (h.kind >= nal.Type.vps and h.kind <= nal.Type.aud) or h.kind == nal.Type.prefix_sei or
            (h.kind >= 41 and h.kind <= 44) or (h.kind >= 48 and h.kind <= 55);
    }
};

/// The pictures due, in order: how many, and FNV-1a of their planes'
/// bytes (two a sample, low first, for a picture deeper than 8 bits), as
/// ffmpeg's rawvideo has them.
fn take(dec: *hevc.Decoder, got: *Decoded) bool {
    const s = dec.next() orelse return false;
    const size: usize = if (s.format.wide()) 2 else 1;
    for (0..3) |p| {
        for (0..s.height[p]) |r| {
            for (s.planes[p][r * s.stride[p] * size ..][0 .. s.width[p] * size]) |byte| got.hash = (got.hash ^ byte) *% 0x100000001b3;
        }
    }
    got.frames += 1;
    dec.release();
    return true;
}

fn giveBack(dec: *hevc.Decoder, vpb: *VideoParseBase, parser: *vp.VideoParser) void {
    while (dec.giveBack()) |slot| vpb.ReleaseVideoSlot(parser, slot);
}

/// Every picture of an Annex B stream without cropping, in the order
/// shown.
fn decodeAll(vpb: *VideoParseBase, stream: []const u8, cores: ?*const hevc.Cores, way: Way) !Decoded {
    var ctx: u8 = 0;
    const env: hevc.Env = .{ .ctx = &ctx, .alloc = TestMemory.alloc, .free = TestMemory.free };
    const dec = hevc.Decoder.create(env) orelse return error.OutOfMemory;
    defer dec.destroy();
    if (cores) |c| dec.useCores(c);
    var err: i32 = 0;
    const tags = [_]utility.TagItem{ .{ .tag = vp.VPA_Slots, .data = hevc.own_slots }, .{} };
    const parser = vpb.OpenVideoParser(vp.VPCODEC_HEVC, null, 0, &tags, &err) orelse return error.NoParser;
    defer vpb.CloseVideoParser(parser);
    var got: Decoded = .{};
    var packets: Packets = .{ .data = stream, .access_units = way.units_end };
    var count: u32 = 0;
    var ended = false;
    while (!ended) {
        count += 1;
        if (way.stop_after == count) return got;
        if (way.reset_after == count) {
            vpb.ResetVideoParser(parser);
            dec.reset();
            giveBack(dec, vpb, parser);
            got = .{};
            packets = .{ .data = stream, .access_units = way.units_end };
        }
        var packet: vp.VideoPacket = .{};
        if (packets.next()) |bytes| {
            packet.data = bytes.ptr;
            packet.bytes = @intCast(bytes.len);
            if (way.units_end) packet.flags = vp.VPPKT_ACCESS_UNIT;
        } else packet.flags = vp.VPPKT_END;
        try testing.expectEqual(vp.VPERR_OK, vpb.ParseVideoPacket(parser, &packet));
        var event: vp.VideoEvent = .{};
        while (true) {
            giveBack(dec, vpb, parser);
            switch (vpb.NextVideoEvent(parser, &event)) {
                vp.VPERR_OK => try dec.event(&event),
                vp.VPERR_NEED_DATA => break,
                vp.VPERR_END => {
                    dec.endOfStream();
                    ended = true;
                    break;
                },
                // The workers' stores, then a picture waiting taken.
                vp.VPERR_FULL => if (!dec.makeRoom() and !take(dec, &got)) return error.Stuck,
                else => return error.Unexpected,
            }
        }
        while (take(dec, &got)) {}
    }
    return got;
}

test "pictures decoded on three workers come out as decoded alone, as ffmpeg decodes them; a seek and a close on the way" {
    var rig: Rig = .{};
    try rig.up();
    defer rig.down() catch |e| std.debug.panic("down: {}", .{e});
    const vpb = rig.vpb;

    const Case = struct { stream: []const u8, frames: u32, hash: u64 };
    const cases = [_]Case{
        .{ .stream = @embedFile("rows.h265"), .frames = 24, .hash = 0x31cd9a7a1c508cfd },
        .{ .stream = @embedFile("wide.h265"), .frames = 8, .hash = 0xce63a1782168d8b9 },
    };
    var t: TestCores = .{};
    t.cores = .{ .ctx = &t, .workers = 3, .run = TestCores.run, .arm = TestCores.arm, .sleep = TestCores.sleep, .wake = TestCores.wake };
    for (&t.threads, 0..) |*th, i| th.* = try std.Thread.spawn(.{}, TestCores.work, .{ &t, i });
    defer {
        @atomicStore(bool, &t.quit, true, .seq_cst);
        for (t.threads) |th| th.join();
    }
    for (cases) |case| {
        const alone = try decodeAll(vpb, case.stream, null, .{});
        try testing.expectEqual(case.frames, alone.frames);
        try testing.expectEqual(case.hash, alone.hash);
        try testing.expectEqual(alone, try decodeAll(vpb, case.stream, null, .{ .units_end = true }));
        for (0..4) |round| try testing.expectEqual(alone, try decodeAll(vpb, case.stream, &t.cores, .{ .units_end = round & 1 != 0 }));
        // A seek and a close with pictures on the workers, at many places.
        var at: u32 = 5;
        while (at < 110) : (at += 7) {
            try testing.expectEqual(alone, try decodeAll(vpb, case.stream, &t.cores, .{ .reset_after = at }));
            _ = try decodeAll(vpb, case.stream, &t.cores, .{ .stop_after = at, .units_end = at & 1 != 0 });
        }
    }
}
