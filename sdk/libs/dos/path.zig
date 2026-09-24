// SPDX-License-Identifier: MIT
//! ParsePath's result: a path split into its device or volume and the
//! rest. The name limit is 30 characters, as GetDeviceProc has it.

/// The longest device or volume name, without the colon.
pub const MAX_DEVICE_NAME = 30;

/// What kind of path ParsePath found.
pub const PathType = enum(u32) {
    /// No colon: from the current directory ("c/dir").
    relative,
    /// A leading colon: from the current volume's root (":c").
    root,
    /// A device or volume: "DH0:s/startup".
    absolute,
};

pub const ParsedPath = extern struct {
    /// The device or volume name, without the colon; empty unless absolute.
    volume: [MAX_DEVICE_NAME + 1]u8 = @splat(0),
    /// What follows the colon, or the whole path when relative: a pointer
    /// into the path.
    remainder: [*:0]const u8 = "",
    path_type: PathType = .relative,
};
