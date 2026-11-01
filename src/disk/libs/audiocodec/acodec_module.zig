// SPDX-License-Identifier: MIT
//! What every sound module in LIBS:codecs/ has in common: its base - exec's
//! Library header, exec, and what it was loaded from - its init and its
//! Expunge, and its jump table: the standard four vectors, then the calls
//! of sdk/fd/acodec_lib.fd, each handed on to the kind's own function.
//!
//! A kind's file gives `open`, `decode` and `seek`, and `openTrack` and
//! `free` where it has them; `Module(revision, Kind, State)` makes the
//! rest, with the stream's `state` taken as a `State`. Every opener shares
//! the one base; a stream is its opener's.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ac = sdk.audiocodec;
const acodec = sdk.acodec;
const media = sdk.media;
const vec = exec.vec;
const ExecBase = sdk.interface.exec.ExecBase;
const Stream = acodec.ACodecStream;

pub const Base = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
};

fn baseOf(lib: *exec.Library) *Base {
    return @fieldParentPtr("lib", lib);
}

/// A module's init, Expunge and jump table, over `Kind`'s functions.
pub fn Module(comptime revision: u16, comptime Kind: type, comptime State: type) type {
    return struct {
        /// The base filled in. Nothing else is opened: the stream has the
        /// libraries it is read through.
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

        fn stateOf(stream: *Stream) *State {
            return @ptrCast(@alignCast(stream.state.?));
        }

        fn lvoOpenACodec(_: *Base, stream: *Stream) callconv(.c) i32 {
            if (stream.layout != acodec.ACODEC_LAYOUT) return ac.ACERR_UNSUPPORTED;
            return Kind.open(stream);
        }
        fn lvoOpenACodecTrack(_: *Base, stream: *Stream, track: *const media.MediaTrack) callconv(.c) i32 {
            if (stream.layout != acodec.ACODEC_LAYOUT) return ac.ACERR_UNSUPPORTED;
            if (!@hasDecl(Kind, "openTrack")) return ac.ACERR_UNSUPPORTED;
            return Kind.openTrack(stream, track);
        }
        fn lvoCloseACodec(_: *Base, stream: *Stream) callconv(.c) void {
            const state = stream.state orelse return;
            if (@hasDecl(Kind, "free")) Kind.free(stream, stateOf(stream));
            stream.base.sys_base.FreeVec(state);
            stream.state = null;
        }
        fn lvoDecodeACodec(_: *Base, stream: *Stream, out: [*]i16, frames: u32) callconv(.c) i32 {
            return Kind.decode(stream, stateOf(stream), out, frames);
        }
        fn lvoSeekACodec(_: *Base, stream: *Stream, frame: u32) callconv(.c) i32 {
            return Kind.seek(stream, stateOf(stream), frame);
        }

        /// The jump table, in slot order: the standard vectors, then one
        /// `lvo<Name>` per `.fd` line.
        pub const vectors = [_]*const anyopaque{
            vec(exec.libOpen),
            vec(exec.libClose),
            vec(expunge),
            vec(exec.libExtFunc),
            vec(lvoOpenACodec),
            vec(lvoOpenACodecTrack),
            vec(lvoCloseACodec),
            vec(lvoDecodeACodec),
            vec(lvoSeekACodec),
        };

        pub const init_table = exec.InitTable{
            .data_size = @sizeOf(Base),
            .vectors = &vectors,
            .vector_count = vectors.len,
            .init = &init,
        };

        // The table is the SDK's, slot by slot.
        comptime {
            const LVO = sdk.interface.acodec.LVO;
            if (vectors.len != 4 + @typeInfo(LVO).@"struct".decls.len) @compileError("sound module: the jump table is not the .fd's");
        }
    };
}
