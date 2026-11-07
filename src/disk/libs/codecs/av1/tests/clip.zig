// SPDX-License-Identifier: MIT
//! The AV1 decoder's host tests on whole clips: IVF files read by
//! videoparse.library - made from its ROM tag on the ROM's exec and
//! utility - and its events decoded, alone and on three workers, with
//! seeks, closes and damaged temporal units on the way.
//!
//! `t1.ivf` is libaom's of ffmpeg's testsrc2 at 200x112, 24 frames, 2x2
//! tiles (palette, CfL, OBMC, local warp, skip mode). `t2.ivf`: libaom,
//! 10-bit 4:4:4, 72x56, 6 frames. `t3.ivf`: libaom, 12-bit 4:2:2, error
//! resilient, loop restoration, 96x64, 10 frames. `t4.ivf`: SVT-AV1,
//! superres and screen content (intra block copy), frames 192x112 in a
//! sequence that says 192x108 at most, 12 frames. `t5.ivf`: libaom, film
//! grain (its test table 3), 96x56, 8 frames. The hashes are of dav1d's
//! decode.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const vp = sdk.videoparse;
const utility = sdk.utility;
const host = @import("host_rom");
const kexec = host.exec;
const av1 = @import("av1core");
const videoparse_init = @import("../../../videoparse/videoparse_init.zig");
const VideoParseBase = sdk.interface.videoparse.VideoParseBase;

const testing = std.testing;

/// Memory lent to exec: an AV1 parser takes some 11 KiB.
var lent: [256 * 1024]u8 align(16) = undefined;

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
    cores: av1.Cores = undefined,
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

/// How many frames shown, how many events of the library's or the
/// decoder's not right, and FNV-1a of the frames' planes' bytes at the
/// size shown.
const Decoded = struct { shown: u32 = 0, errors: u32 = 0, hash: u64 = 0xcbf29ce484222325 };

const Way = struct {
    /// After so many temporal units: everything dropped, as for a seek,
    /// and the stream decoded from its start again.
    reset_after: ?u32 = null,
    /// After so many temporal units: the decoder closed, whatever it is
    /// doing.
    stop_after: ?u32 = null,
    /// Each temporal unit cut to this part of it, in sixteenths.
    cut: u32 = 16,
    /// Each frame taken as soon as there is one, as a program would not.
    eager: bool = false,
};

/// The frame due next, if there is one: counted and hashed.
fn take(dec: *av1.Decoder, got: *Decoded) bool {
    const s = dec.next() orelse return false;
    const f = s.frame;
    const bytes: usize = f.alloc_bytes;
    for (0..3) |p| {
        const sx: u5 = if (p > 0) f.ss_x else 0;
        const sy: u5 = if (p > 0) f.ss_y else 0;
        const w = (f.width + (@as(u32, 1) << sx) - 1) >> sx;
        const h = (f.height + (@as(u32, 1) << sy) - 1) >> sy;
        for (0..h) |r| {
            for (f.planes[p][r * f.stride[p] * bytes ..][0 .. w * bytes]) |byte| got.hash = (got.hash ^ byte) *% 0x100000001b3;
        }
    }
    got.shown += 1;
    dec.release();
    return true;
}

fn giveBack(dec: *av1.Decoder, vpb: *VideoParseBase, parser: *vp.VideoParser) void {
    while (dec.giveBack()) |slot| vpb.ReleaseVideoSlot(parser, slot);
}

/// Every frame of an IVF file shown, in a decoder made for it: how many,
/// and their hash.
fn decodeAll(vpb: *VideoParseBase, ivf: []const u8, cores: ?*const av1.Cores, way: Way) !Decoded {
    var ctx: u8 = 0;
    const env: av1.Env = .{ .ctx = &ctx, .alloc = TestMemory.alloc, .free = TestMemory.free };
    const dec = av1.Decoder.create(env) orelse return error.OutOfMemory;
    defer dec.destroy();
    if (cores) |c| dec.useCores(c);
    var err: i32 = 0;
    const parser = vpb.OpenVideoParser(vp.VPCODEC_AV1, null, 0, null, &err) orelse return error.NoParser;
    defer vpb.CloseVideoParser(parser);
    const start = std.mem.readInt(u16, ivf[6..8], .little);
    var got: Decoded = .{};
    var at: usize = start;
    var count: u32 = 0;
    while (true) {
        count += 1;
        if (way.stop_after == count) return got;
        if (way.reset_after == count) {
            vpb.ResetVideoParser(parser);
            dec.reset();
            giveBack(dec, vpb, parser);
            got = .{};
            at = start;
        }
        var packet: vp.VideoPacket = .{ .time = count };
        if (at + 12 <= ivf.len) {
            const size = std.mem.readInt(u32, ivf[at..][0..4], .little);
            const data = ivf[at + 12 ..][0 .. size * way.cut / 16];
            at += 12 + size;
            packet.data = data.ptr;
            packet.bytes = @intCast(data.len);
            // An IVF frame is a temporal unit.
            packet.flags = vp.VPPKT_ACCESS_UNIT;
        } else packet.flags = vp.VPPKT_END;
        try testing.expectEqual(vp.VPERR_OK, vpb.ParseVideoPacket(parser, &packet));
        var event: vp.VideoEvent = .{};
        const ended = while (true) {
            giveBack(dec, vpb, parser);
            switch (vpb.NextVideoEvent(parser, &event)) {
                // A frame that is not right is the decoder's to pass over.
                vp.VPERR_OK => dec.event(&event, false) catch {
                    got.errors += 1;
                },
                vp.VPERR_NEED_DATA => break false,
                vp.VPERR_END => break true,
                // An OBU or a frame the library passed over.
                vp.VPERR_CORRUPT, vp.VPERR_UNSUPPORTED => got.errors += 1,
                else => return error.Unexpected,
            }
        };
        if (ended) {
            dec.flush();
            while (take(dec, &got)) {}
            return got;
        }
        while (take(dec, &got)) {
            if (!way.eager) break;
        }
    }
}

test "frames decoded as dav1d decodes them, alone and on three workers, after a seek, a close and damaged ones" {
    var rig: Rig = .{};
    try rig.up();
    defer rig.down() catch |e| std.debug.panic("down: {}", .{e});
    const vpb = rig.vpb;

    var t: TestCores = .{};
    t.cores = .{ .ctx = &t, .workers = 3, .run = TestCores.run, .arm = TestCores.arm, .sleep = TestCores.sleep, .wake = TestCores.wake };
    for (&t.threads, 0..) |*th, i| th.* = try std.Thread.spawn(.{}, TestCores.work, .{ &t, i });
    defer {
        @atomicStore(bool, &t.quit, true, .seq_cst);
        for (t.threads) |th| th.join();
    }
    const streams = [_]struct { ivf: []const u8, expect: Decoded }{
        .{ .ivf = @embedFile("t1.ivf"), .expect = .{ .shown = 24, .hash = 0x4a9ee9e57edf4494 } },
        .{ .ivf = @embedFile("t2.ivf"), .expect = .{ .shown = 6, .hash = 0xef6063783e47e4fd } },
        .{ .ivf = @embedFile("t3.ivf"), .expect = .{ .shown = 10, .hash = 0x92867b231c1cd63d } },
        .{ .ivf = @embedFile("t4.ivf"), .expect = .{ .shown = 12, .hash = 0xbdc14b8d4a731f16 } },
        .{ .ivf = @embedFile("t5.ivf"), .expect = .{ .shown = 8, .hash = 0xc0e64490c5bfaf5c } },
    };
    for (streams) |s| {
        for ([_]?*const av1.Cores{ null, &t.cores }) |cores| {
            try testing.expectEqual(s.expect, try decodeAll(vpb, s.ivf, cores, .{}));
            try testing.expectEqual(s.expect, try decodeAll(vpb, s.ivf, cores, .{ .eager = true }));
            for ([_]u32{ 3, 6 }) |at| {
                try testing.expectEqual(s.expect, try decodeAll(vpb, s.ivf, cores, .{ .reset_after = at }));
                _ = try decodeAll(vpb, s.ivf, cores, .{ .stop_after = at });
            }
            // Temporal units cut short: some frames come out, wrong;
            // nothing is caught.
            for ([_]u32{ 1, 5, 8, 15 }) |cut| _ = try decodeAll(vpb, s.ivf, cores, .{ .cut = cut });
        }
    }
}
