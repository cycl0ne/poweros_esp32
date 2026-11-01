// SPDX-License-Identifier: MIT
//! What every codec module in LIBS:codecs/ has in common: its base - exec's
//! Library header, exec, and what it was loaded from - its init and its
//! Expunge, and its jump table: the standard four vectors, then the seven
//! calls of sdk/fd/vcodec_lib.fd, each handed on to the module's own
//! function of that name.
//!
//! A module's own file gives its tag (a `ResidentVCodec`: what it decodes)
//! and the seven functions, as `pub fn GetVCodecInfo(base: *Base, ...)`
//! and so on; `Module(revision, Calls)` makes the rest. Every opener
//! shares the one base; a decoder opened is its opener's. A decoder that
//! decodes on every core has its workers from `Team`.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const vc = sdk.videocodec;
const vcodec = sdk.vcodec;
const vec = exec.vec;
const ExecBase = sdk.interface.exec.ExecBase;

pub const Base = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
};

pub fn baseOf(lib: *exec.Library) *Base {
    return @fieldParentPtr("lib", lib);
}

/// A module's init, Expunge and jump table, over `Calls`' seven functions.
pub fn Module(comptime revision: u16, comptime Calls: type) type {
    return struct {
        /// The base filled in. Nothing else is opened: a decoder opens
        /// what it needs for itself.
        fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
            const base = baseOf(lib);
            const header = lib.*;
            base.* = .{ .lib = header, .sys_base = sys_base, .seg_list = seg_list };
            lib.revision = revision;
            return lib;
        }

        /// The module goes when nobody has it open: the base freed, and the
        /// file it was loaded from handed back.
        fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
            if (lib.open_cnt != 0) {
                lib.flags |= exec.LIBF_DELEXP;
                return null;
            }
            const base = baseOf(lib);
            const sys = base.sys_base;
            const seg_list = base.seg_list;
            sys.DetachLibrary(lib);
            const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
            sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
            return seg_list;
        }

        fn lvoGetVCodecInfo(base: *Base, decoder: *vcodec.VCodecDecoder, info: *vcodec.VCodecInfo) callconv(.c) i32 {
            return Calls.GetVCodecInfo(base, decoder, info);
        }
        fn lvoOpenVCodec(base: *Base, params: *const vcodec.VCodecParams, err: ?*i32) callconv(.c) ?*vcodec.VCodecDecoder {
            return Calls.OpenVCodec(base, params, err);
        }
        fn lvoCloseVCodec(base: *Base, decoder: ?*vcodec.VCodecDecoder) callconv(.c) void {
            return Calls.CloseVCodec(base, decoder);
        }
        fn lvoSendVCodecPacket(base: *Base, decoder: *vcodec.VCodecDecoder, packet: *const vcodec.VCodecPacket) callconv(.c) i32 {
            return Calls.SendVCodecPacket(base, decoder, packet);
        }
        fn lvoReceiveVCodecFrame(base: *Base, decoder: *vcodec.VCodecDecoder, frame: *vc.VideoFrame) callconv(.c) i32 {
            return Calls.ReceiveVCodecFrame(base, decoder, frame);
        }
        fn lvoReleaseVCodecFrame(base: *Base, decoder: *vcodec.VCodecDecoder, frame: *vc.VideoFrame) callconv(.c) void {
            return Calls.ReleaseVCodecFrame(base, decoder, frame);
        }
        fn lvoFlushVCodec(base: *Base, decoder: *vcodec.VCodecDecoder) callconv(.c) void {
            return Calls.FlushVCodec(base, decoder);
        }

        // Each wrapper is the type the SDK gives its slot.
        comptime {
            const interface = sdk.interface.vcodec;
            for (@typeInfo(interface.LVO).@"struct".decls) |d| {
                const f = @field(@This(), "lvo" ++ d.name);
                if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
                    @compileError("codec module: lvo" ++ d.name ++ " does not match the SDK's type");
                }
            }
        }

        /// The jump table, in slot order: the standard vectors, then one
        /// `lvo<Name>` per `.fd` line.
        pub const vectors = [_]*const anyopaque{
            vec(exec.libOpen),
            vec(exec.libClose),
            vec(expunge),
            vec(exec.libExtFunc),
            vec(lvoGetVCodecInfo),
            vec(lvoOpenVCodec),
            vec(lvoCloseVCodec),
            vec(lvoSendVCodecPacket),
            vec(lvoReceiveVCodecFrame),
            vec(lvoReleaseVCodecFrame),
            vec(lvoFlushVCodec),
        };

        pub const init_table = exec.InitTable{
            .data_size = @sizeOf(Base),
            .vectors = &vectors,
            .vector_count = vectors.len,
            .init = &init,
        };
    };
}

/// A slot no frame lent out holds, of the first `held`.
pub fn freeSlot(lent: []const bool, held: u32) ?u32 {
    for (lent[0..@min(held, lent.len)], 0..) |taken, slot| {
        if (!taken) return @intCast(slot);
    }
    return null;
}

/// The slot a frame was lent in, by what `private` holds - the slot
/// after 1, and the module's mark - or null for one that is not lent.
pub fn slotOf(lent: []const bool, frame: *const vc.VideoFrame, mark: u32) ?u32 {
    if (frame.private[1] != mark) return null;
    const slot = frame.private[0];
    if (slot == 0 or slot > lent.len or !lent[slot - 1]) return null;
    return slot - 1;
}

/// Workers at most, and each one's stack: the standard task stack.
const most_workers = 8;
const worker_stack: usize = if (@sizeOf(usize) == 8) 32 * 1024 else 16 * 1024;

/// A decoder's workers, when it decodes on every core: a task on each
/// core, a step below the caller's priority - which gets a core at once
/// to hand over packets and take pictures - each waiting by a waitable of
/// its own, the workers' and then the caller's, and a bit in `armed`
/// while it looks whether to wait. `Cores` is the decoder's way to them,
/// which each decoder here declares alike: `ctx`, `workers`, `run`,
/// `arm`, `sleep`, `wake`.
pub fn Team(comptime Cores: type) type {
    return struct {
        const T = @This();

        /// A worker task: the job it is handed - its code and what it
        /// works on, 0 while there is none - and the message its end is
        /// told by.
        const Worker = struct {
            task: exec.Task = .{},
            ended: exec.Message = .{},
            team: *T = undefined,
            index: u32 = 0,
            job: usize = 0,
            arg: usize = 0,
            stack: ?*anyopaque = null,
        };

        sys: *ExecBase = undefined,
        cores: Cores = undefined,
        workers: [most_workers]Worker = @splat(.{}),
        count: u32 = 0,
        waitables: [most_workers + 1]exec.Waitable = @splat(.{}),
        armed: u32 = 0,
        quit: bool = false,
        ends: ?*exec.MsgPort = null,

        fn ofCtx(ctx: *anyopaque) *T {
            return @ptrCast(@alignCast(ctx));
        }

        fn run(ctx: *anyopaque, worker: u32, job: *const fn (*anyopaque) void, arg: *anyopaque) void {
            const team = ofCtx(ctx);
            const w = &team.workers[worker];
            w.arg = @intFromPtr(arg);
            @atomicStore(usize, &w.job, @intFromPtr(job), .seq_cst);
            team.sys.SignalWaitable(&team.waitables[worker]);
        }

        fn arm(ctx: *anyopaque, who: u32) void {
            const team = ofCtx(ctx);
            team.sys.ResetWaitable(&team.waitables[who]);
            _ = @atomicRmw(u32, &team.armed, .Or, @as(u32, 1) << @intCast(who), .seq_cst);
        }

        fn sleep(ctx: *anyopaque, who: u32) void {
            const team = ofCtx(ctx);
            const one = [1]*exec.Waitable{&team.waitables[who]};
            _ = team.sys.WaitForAny(&one, 1, exec.WAIT_FOREVER);
        }

        fn wake(ctx: *anyopaque) void {
            const team = ofCtx(ctx);
            var armed = @atomicRmw(u32, &team.armed, .Xchg, 0, .seq_cst);
            while (armed != 0) : (armed &= armed - 1) team.sys.SignalWaitable(&team.waitables[@ctz(armed)]);
        }

        /// A worker named `name` on each core, when there are more than
        /// one; `count` says how many there are.
        pub fn start(team: *T, sys: *ExecBase, name: [*:0]const u8) void {
            team.sys = sys;
            var cores: u32 = 0;
            var times: exec.CoreTimes = .{};
            while (cores < most_workers and sys.ReadCoreTimes(cores, &times)) cores += 1;
            if (cores < 2) return;
            const ends = sys.CreateMsgPort() orelse return;
            team.ends = ends;
            // A step below the caller, which wants a core at once when it
            // has packets to hand over or a picture to take.
            const pri = sys.FindTask(null).?.node.pri -| 1;
            for (team.workers[0..cores], 0..) |*w, i| {
                const stack = sys.AllocVec(worker_stack, exec.MEMF_ANY) orelse break;
                w.* = .{ .team = team, .index = @intCast(i), .stack = stack };
                w.task = .{
                    .node = .{ .type = .task, .pri = pri, .name = name },
                    .sp_lower = @intFromPtr(stack),
                    .sp_upper = @intFromPtr(stack) + worker_stack,
                };
                w.ended.reply_port = ends;
                w.task.end_msg = &w.ended;
                _ = sys.AddTask(&w.task, &work, null);
                team.count += 1;
            }
            team.cores = .{ .ctx = team, .workers = team.count, .run = run, .arm = arm, .sleep = sleep, .wake = wake };
        }

        /// The workers ended, once nothing runs on their stacks any more.
        pub fn stop(team: *T) void {
            const ends = team.ends orelse return;
            const sys = team.sys;
            @atomicStore(bool, &team.quit, true, .seq_cst);
            for (team.waitables[0..team.count]) |*w| sys.SignalWaitable(w);
            for (0..team.count) |_| {
                _ = sys.WaitPort(ends);
                _ = sys.GetMsg(ends);
            }
            for (team.workers[0..team.count]) |*w| sys.FreeVec(w.stack);
            sys.DeleteMsgPort(ends);
            team.ends = null;
            team.count = 0;
        }

        /// A worker's code: the jobs it is handed, until it is told to
        /// end.
        fn work(sys: *ExecBase) callconv(.c) void {
            const w: *Worker = @fieldParentPtr("task", sys.FindTask(null).?);
            const team = w.team;
            while (true) {
                arm(team, w.index);
                const job = @atomicRmw(usize, &w.job, .Xchg, 0, .acq_rel);
                if (job != 0) {
                    const code: *const fn (*anyopaque) void = @ptrFromInt(job);
                    code(@ptrFromInt(w.arg));
                    continue;
                }
                if (@atomicLoad(bool, &team.quit, .acquire)) return;
                sleep(team, w.index);
            }
        }
    };
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "a module's jump table: the standard four, then the seven calls in the .fd's order" {
    const Calls = struct {
        fn GetVCodecInfo(_: *Base, _: *vcodec.VCodecDecoder, _: *vcodec.VCodecInfo) i32 {
            return 0;
        }
        fn OpenVCodec(_: *Base, _: *const vcodec.VCodecParams, _: ?*i32) ?*vcodec.VCodecDecoder {
            return null;
        }
        fn CloseVCodec(_: *Base, _: ?*vcodec.VCodecDecoder) void {}
        fn SendVCodecPacket(_: *Base, _: *vcodec.VCodecDecoder, _: *const vcodec.VCodecPacket) i32 {
            return 0;
        }
        fn ReceiveVCodecFrame(_: *Base, _: *vcodec.VCodecDecoder, _: *vc.VideoFrame) i32 {
            return 0;
        }
        fn ReleaseVCodecFrame(_: *Base, _: *vcodec.VCodecDecoder, _: *vc.VideoFrame) void {}
        fn FlushVCodec(_: *Base, _: *vcodec.VCodecDecoder) void {}
    };
    const M = Module(0, Calls);
    const LVO = sdk.interface.vcodec.LVO;
    try testing.expectEqual(@as(usize, 4 + @typeInfo(LVO).@"struct".decls.len), M.vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(M, "lvo" ++ d.name)), M.vectors[index]);
    }
}

test "the slots of the frames lent: the first free, and a frame's back by its mark" {
    var lent = [_]bool{ true, false, true, false };
    try testing.expectEqual(@as(?u32, 1), freeSlot(&lent, 4));
    try testing.expectEqual(@as(?u32, null), freeSlot(&lent, 1));
    var frame: vc.VideoFrame = .{};
    frame.private = .{ 3, 0x1234, 0 };
    try testing.expectEqual(@as(?u32, 2), slotOf(&lent, &frame, 0x1234));
    try testing.expectEqual(@as(?u32, null), slotOf(&lent, &frame, 0x4321));
    frame.private[0] = 2;
    try testing.expectEqual(@as(?u32, null), slotOf(&lent, &frame, 0x1234));
}
