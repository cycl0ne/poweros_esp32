// SPDX-License-Identifier: MPL-2.0
//! The ROM's exec, utility.library and intuition.library for host tests
//! outside this tree: a disk module's tests bring them up (`exec.setUp()`,
//! `utility.setUp()`, `intuition.setUp()` with everything intuition stands
//! on) the way the ROM's own tests do, through the named import `host_rom`
//! the build hands them. rtg, graphics, dos and the RAM: handler are here
//! for a module that reads files and makes fonts, and the fake display
//! board for one that opens a window and looks at what it drew.
//!
//! It sits at the root of `src/` because utility.library reaches exec by
//! path, and a module's files have to lie under its root.

pub const exec = @import("rom/libs/exec/exec.zig");
pub const utility = @import("rom/libs/utility/utility.zig");
pub const intuition = @import("rom/libs/intuition/intuition.zig");
pub const rtg = @import("rom/libs/rtg/rtg.zig");
pub const graphics = @import("rom/libs/graphics/graphics.zig");
pub const dos = @import("rom/libs/dos/dos.zig");
pub const dos_process = @import("rom/libs/dos/process/_process.zig");
pub const ram = @import("rom/handler/ram/ram.zig");
pub const fakeboard = @import("rom/libs/rtg_driver/fakeboard/fakeboard.zig");
