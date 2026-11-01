// SPDX-License-Identifier: MIT
//! A release package: what a system is installed from and brought up to
//! date against. The format of its list is `manifest.zig`; this says what
//! a package holds and where each half of it belongs on a machine.
//!
//!     manifest              every drawer and file below (`manifest.zig`)
//!     system/...            the system volume's files
//!     boot/...              what the machine's firmware reads
//!
//! Every path in the manifest begins with the half it is in, so one list
//! covers both and one walk compares them. A machine puts the `system`
//! half on its system volume and the `boot` half in the partition its
//! firmware reads.
//!
//! **What is in `boot/` is the board's business, not this one.** A
//! firmware wants a kernel, and some want a device tree, a settings file
//! or a file saying which of two partitions to start from; a package
//! carries whatever the board it was built for needs, and installing it
//! is copying each `boot/` entry into the boot partition under its own
//! name. Which unit holds that partition, and whether there are two of
//! them, a board says through expansion.library - so nothing here knows
//! one board from another.
//!
//! A package is a directory, wherever it is read from: a path on a disk,
//! a share or a stick, or an address a server answers. The same tree of
//! names in both cases, so there is one reader for the list and two for
//! the bytes.
//!
//! A machine keeps the manifest it was given as `installed_manifest`, and
//! its own copy of the boot half under `boot_store` with a list of its
//! own (`boot_manifest`), so that it can write its boot partition again -
//! and install another machine - with no network and no second machine.

pub const manifest = @import("manifest.zig");
pub const update = @import("update.zig");

/// The two halves of a package.
pub const Half = enum { system, boot };

/// Each half's drawer in the package, which is what its paths begin with.
pub const half_names = [2][]const u8{ "system", "boot" };

/// The list's own name in a package.
pub const package_manifest = "manifest";

/// The list a machine keeps of what it was given, which an update
/// compares against.
pub const installed_manifest = "SYS:System/manifest";

/// Where a machine keeps its own copy of the boot half: `SYS:Storage` is
/// a package of which only that half is there, so the drawer under it is
/// the half's own name and the paths in `boot_manifest` are the same ones
/// a fetched package uses.
pub const boot_store = "SYS:Storage/Boot";

/// The list over `boot_store`, which says which chip and board those
/// files are for: a machine that has been given another board's image
/// would otherwise write that board's kernel to its boot partition and
/// come up with no console. The build writes it onto the images of the
/// machines whose disk is in RAM.
pub const boot_manifest = "SYS:Storage/manifest";

/// A path in a package, split into the half it is in and the rest of it:
/// `system/C/List` is `.system` and `C/List`. A half's own drawer - the
/// line `drawer system`, which a list over a whole package holds - is
/// that half with nothing left: there is nothing to make for it, since
/// what it stands for is the volume a half is written to. Null for a path
/// in neither half, which is not a package's.
pub const Part = struct { half: Half, rest: []const u8 };

pub fn halfOf(path: []const u8) ?Part {
    for (half_names, 0..) |name, which| {
        if (path.len < name.len or (path.len > name.len and path[name.len] != '/')) continue;
        if (manifest.samePath(path[0..name.len], name)) {
            const rest = if (path.len == name.len) path[path.len..] else path[name.len + 1 ..];
            return .{ .half = @enumFromInt(which), .rest = rest };
        }
    }
    return null;
}

/// The bytes `join` writes for `rest` in `half`.
pub fn joinLength(half: Half, rest: []const u8) usize {
    return half_names[@intFromEnum(half)].len + 1 + rest.len;
}

/// `rest` in `half` as the path a manifest names it by, into `into`
/// (`joinLength` bytes): how many bytes.
pub fn join(half: Half, rest: []const u8, into: []u8) usize {
    const name = half_names[@intFromEnum(half)];
    @memcpy(into[0..name.len], name);
    into[name.len] = '/';
    @memcpy(into[name.len + 1 ..][0..rest.len], rest);
    return joinLength(half, rest);
}
