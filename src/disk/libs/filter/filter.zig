// SPDX-License-Identifier: MIT
//! filter.library: a packet filter, on the disk in LIBS:. It puts two
//! hooks in bsdsocket.library's chains (AddPacketHook) and answers for
//! every packet from a rule set loaded as text - the language is
//! sdk.filter's. C:net/Filter loads the rules from ENVARC:Sys/net/filter,
//! shows them with their counts, and takes them out again.
//!
//! **What a packet coming in gets**: a segment of a TCP connection the
//! stack has passes, and so does an answer to a UDP datagram or an echo
//! this machine sent (`flows/`); then the first rule that matches decides
//! (`rules/`), then the default of its interface, and an interface with
//! none is open. What goes out is only noted, for those answers.
//!
//! **While rules are in force the library stays**: bsdsocket.library calls
//! its code, so Expunge declines until ClearFilterRules has taken the
//! hooks out. The hooks are added with PH_Keep, each load and clear
//! opening bsdsocket.library for the length of the call on its caller's
//! task.
//!
//! The jump table is filter_lvo.zig, the ROM tag, init and expunge
//! filter_init.zig, the base filter_base.zig. The calls are under
//! `rules/` and `flows/`; the hooks' code is `hook/`.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const filter_init = @import("filter_init.zig");

comptime {
    _ = &filter_init.filter_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const filter_library_tag = filter_init.filter_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{filter_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [filter_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = filter_init.LIBRARY_VERSION_STRING.*;
