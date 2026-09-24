// SPDX-License-Identifier: MPL-2.0
//! The ROM's exec and utility.library for host tests outside this tree:
//! a disk module's tests bring them up (`exec.setUp()`,
//! `utility.setUp()`) the way the ROM's own tests do, through the named
//! import `host_rom` the build hands them.
//!
//! It sits at the root of `src/` because utility.library reaches exec by
//! path, and a module's files have to lie under its root.

pub const exec = @import("rom/libs/exec/exec.zig");
pub const utility = @import("rom/libs/utility/utility.zig");
