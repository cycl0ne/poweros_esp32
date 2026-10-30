// SPDX-License-Identifier: MIT
//! commodities.library: programs that watch the input stream and act on
//! it, on the disk in LIBS:.
//!
//! The library keeps a network of objects - a broker for each program
//! that takes part, a tree of filters, senders, translators and custom
//! objects under each - and a handler on input.device's chain, before
//! the windowing system, that sends every event through the network.
//! What comes out is what the windows get.
//!
//! The areas: `object/` makes, deletes and sets objects, `attach/` puts
//! them on each other's lists, `filter/` is the conditions - the words a
//! description is made of, and matching an event - `message/` the
//! messages and their routing, `input/` the handler and the events a
//! program adds, `broker/` the brokers and the commands sent to them.
//!
//! The jump table is commodities_lvo.zig, the ROM tag, init, open and
//! expunge commodities_init.zig, the base and the private shapes
//! commodities_base.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const commodities_init = @import("commodities_init.zig");

comptime {
    _ = &commodities_init.commodities_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const commodities_library_tag = commodities_init.commodities_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{commodities_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [commodities_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = commodities_init.LIBRARY_VERSION_STRING.*;
