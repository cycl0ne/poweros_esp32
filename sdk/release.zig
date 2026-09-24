// SPDX-License-Identifier: MIT
//! What the system calls itself, which SDK this is, and where a program
//! finds the release it is running on.
//!
//! The SDK's version is the ABI's: the structures, constants and jump
//! tables a program is built against. It moves when they do, and not when
//! the system has a release of its own - that number is the system's, kept
//! in its ROM, and a program asks the running system for it rather than
//! building one in: `FindResident(RELEASE_RESIDENT)` answers the ROM tag
//! whose version is the release's and whose ID string says it in full.

const std = @import("std");

/// The system's name.
pub const NAME = "PowerOS";

/// The SDK's version and revision: the ABI's. build.zig.zon's `version`
/// says the same.
pub const SDK_VERSION = 0;
pub const SDK_REVISION = 1;

/// "0.1".
pub const SDK_VERSION_STRING = std.fmt.comptimePrint("{d}.{d}", .{ SDK_VERSION, SDK_REVISION });

/// The ROM tag the running system's release is in: `version` is the
/// release's version, and `id_string` names the system, the release and
/// its date ("PowerOS 0.1 (24.9.2026)").
pub const RELEASE_RESIDENT = "release";
