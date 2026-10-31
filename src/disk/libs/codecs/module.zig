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
//! shares the one base; a decoder opened is its opener's.

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
