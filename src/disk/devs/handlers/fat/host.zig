// SPDX-License-Identifier: MIT
//! The door a tool on the host comes in by: the FAT32 format as the
//! handler lays it down, over a medium the tool hands it.
//!
//! `tools/mkstick` makes a machine's boot medium through this, so the
//! volume a firmware reads was written by the same code that reads it
//! back on the machine - the boot sector, both copies of the table, the
//! free-count sector and the root directory, with the cluster size the
//! format picks for a volume that size. There is one implementation of
//! the format, and what a tool writes is by construction what the
//! handler mounts.
//!
//! It is its own file because a module's imports have to begin inside
//! the module's own directory: these files' begin here, where `_fat.zig`
//! is a sibling rather than something above.

pub const format = @import("fat32/format.zig");
pub const layout = @import("fat32/layout.zig");

const _fat = @import("_fat.zig");

/// A volume name as the eleven characters a boot sector and the label's
/// own entry hold, or `error.InvalidName`.
pub const shortLabel = _fat.shortLabel;
/// What marks the entry that carries the volume's name.
pub const ATTR_VOLUME_LABEL = _fat.ATTR_VOLUME_LABEL;
/// What marks an entry that is a directory, and one that has been
/// written since it was last backed up - which every file written here
/// has.
pub const ATTR_DIRECTORY = _fat.ATTR_DIRECTORY;
pub const ATTR_ARCHIVE = _fat.ATTR_ARCHIVE;
/// The date and time an entry carries.
pub const Stamp = _fat.Stamp;
