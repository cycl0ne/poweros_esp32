// SPDX-License-Identifier: MIT
//! C:Install's parts as one module, for a program that runs an install
//! its own way - SYS:Installer's window, which asks in a window what the
//! command takes as arguments and runs the same steps on a process of
//! its own: the run and its helpers (`shared`, with the `Watcher` that
//! is told what the run says), the units and which one the running
//! system is on, the disk's table, partitions and file systems, and the
//! files copied onto them.

pub const shared = @import("_install.zig");
pub const units = @import("units.zig");
pub const disk = @import("disk.zig");
pub const files = @import("files.zig");
