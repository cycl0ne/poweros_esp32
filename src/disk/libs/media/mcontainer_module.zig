// SPDX-License-Identifier: MIT
//! What every container module in LIBS:codecs/ has in common: its base -
//! exec's Library header, exec, and what it was loaded from - its init and
//! its Expunge, and its jump table: the standard four vectors, then the
//! calls of sdk/fd/mcontainer_lib.fd, each handed on to the kind's own
//! function.
//!
//! A kind's file gives `open`, `read` and `seek`, and `free` where it has
//! it; `Module(revision, Kind)` makes the rest. Every opener shares the one
//! base; a file is its opener's.

const sdk = @import("sdk");
const exec = sdk.exec;
const media = sdk.media;
const mcontainer = sdk.mcontainer;
const vec = exec.vec;
const ExecBase = sdk.interface.exec.ExecBase;
const File = mcontainer.MediaContainerFile;

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
pub fn Module(comptime revision: u16, comptime Kind: type) type {
    return struct {
        /// The base filled in. Nothing else is opened: the file has the
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

        fn lvoOpenContainer(_: *Base, file: *File, check: bool) callconv(.c) i32 {
            if (file.layout != mcontainer.MCONTAINER_LAYOUT) return media.MERR_UNSUPPORTED;
            return Kind.open(file, check);
        }
        fn lvoCloseContainer(_: *Base, file: *File) callconv(.c) void {
            const state = file.state orelse return;
            if (@hasDecl(Kind, "free")) Kind.free(file);
            file.base.sys_base.FreeVec(state);
            file.state = null;
        }
        fn lvoReadContainerPacket(_: *Base, file: *File, track: u32, packet: *media.MediaPacket) callconv(.c) i32 {
            return Kind.read(file, &file.tracks[track], packet);
        }
        fn lvoSeekContainer(_: *Base, file: *File, track: u32, time: i64) callconv(.c) i32 {
            return Kind.seek(file, &file.tracks[track], time);
        }

        /// The jump table, in slot order: the standard vectors, then one
        /// `lvo<Name>` per `.fd` line.
        pub const vectors = [_]*const anyopaque{
            vec(exec.libOpen),
            vec(exec.libClose),
            vec(expunge),
            vec(exec.libExtFunc),
            vec(lvoOpenContainer),
            vec(lvoCloseContainer),
            vec(lvoReadContainerPacket),
            vec(lvoSeekContainer),
        };

        pub const init_table = exec.InitTable{
            .data_size = @sizeOf(Base),
            .vectors = &vectors,
            .vector_count = vectors.len,
            .init = &init,
        };

        // The table is the SDK's, slot by slot.
        comptime {
            const LVO = sdk.interface.mcontainer.LVO;
            if (vectors.len != 4 + @typeInfo(LVO).@"struct".decls.len) @compileError("container module: the jump table is not the .fd's");
        }
    };
}
