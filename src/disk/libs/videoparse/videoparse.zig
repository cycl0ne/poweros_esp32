// SPDX-License-Identifier: MIT
//! videoparse.library: an H.264, HEVC or VP9 stream read for a decoder -
//! its parameter sets and slice headers, or its frame headers, its
//! pictures' order counts and the references each holds, the lists each
//! slice decodes from, the marking after each picture and the order the
//! pictures are shown in - and said event by event; on the disk in LIBS:.
//! It decodes no samples: that is the caller's, a chip's engine or a
//! decoder's cores.
//!
//! A parser (`parser/_parser.zig`) cuts each packet into its units as the
//! events are asked for - after start codes, or after their lengths where
//! the setup said so - and hands each to its codec's reading, which puts
//! the events it comes to on the parser's queue. H.264's (`h264/`): the
//! bit reader, the units and an avcC (`nal.zig`), the parameter sets
//! (`params.zig`), the slice header (`slice.zig`), the picture buffer
//! without its samples (`dpb.zig`: order counts, marking, lists, bumping,
//! slots) and the picture-by-picture reading over them (`_h264.zig`).
//! HEVC's (`hevc/`) is laid out the same. VP9's (`vp9/`): the
//! uncompressed header (`header.zig`) and the frame-by-frame reading -
//! superframes, the eight reference slots, the slots they hold
//! (`_vp9.zig`).
//!
//! The jump table is videoparse_lvo.zig, the ROM tag, init and expunge
//! videoparse_init.zig, the base videoparse_base.zig. Each call is a file
//! in `parser/`.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const videoparse_init = @import("videoparse_init.zig");

comptime {
    _ = &videoparse_init.videoparse_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const videoparse_library_tag = videoparse_init.videoparse_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{videoparse_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [videoparse_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = videoparse_init.LIBRARY_VERSION_STRING.*;
