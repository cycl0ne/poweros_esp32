// SPDX-License-Identifier: MIT
//! update.library's structures and constants: an installed system brought
//! up to date from a release package (`sdk.install`), taking from it
//! exactly what differs and leaving what was changed on the machine
//! alone. The calls are in `sdk.interface.update`.
//!
//! **A run** is made for one package (`CreateUpdate`, `UPD_Source`): a
//! directory on a volume, or an address a server answers (with `://` in
//! it). `DoUpdate` compares it with the system - `UPD_Check` to only say
//! what would happen, `UPD_Boot` for the firmware's partition too,
//! `UPD_Force` for the package's own over files changed here - and may be
//! called again on the same run; `GetUpdateInfo` says what the last one
//! came to, and `DeleteUpdate` lets the run go. `ConfirmUpdate` is the
//! step a system that came up on a tried partition takes to keep it.
//!
//! **What a run says** goes to the caller's output, or with `UPD_Hook` to
//! a hook instead, as an `UpdateMessage`: a line of prose, a path with
//! what happens to it, or a file put in place. The hook is called on the
//! caller's task, which is the task a run checks for Ctrl-C between
//! files - so a program that runs it on a process of its own stops it by
//! signalling that process.

const utility = @import("../utility/utility.zig");

/// The library's name, for OpenLibrary.
pub const UPDATENAME = "update.library";

/// A run of the update, made by CreateUpdate; the library's own.
pub const Update = opaque {};

pub const UPD_Dummy = utility.TAG_USER + 0x61000;
/// `[*:0]const u8` (CreateUpdate): the package - a path, or an address
/// with `://` in it. Left out, what `ENVARC:Sys/update.prefs` names as
/// SOURCE, else where the system was installed from.
pub const UPD_Source = UPD_Dummy + 1;
/// `*utility.Hook` (CreateUpdate, ConfirmUpdate): where what a run says
/// goes, an `UpdateMessage` at a time, in place of the caller's output.
pub const UPD_Hook = UPD_Dummy + 2;
/// bool (CreateUpdate, ConfirmUpdate): only failures to the output. A
/// hook is told everything either way.
pub const UPD_Quiet = UPD_Dummy + 3;
/// bool (DoUpdate, ConfirmUpdate): what would happen said, and nothing
/// written.
pub const UPD_Check = UPD_Dummy + 4;
/// bool (DoUpdate): the files the firmware reads written too, into the
/// partition it reads them from, after the system volume's.
pub const UPD_Boot = UPD_Dummy + 5;
/// bool (DoUpdate): the package's own written over files changed on the
/// machine, and over a package built for another board.
pub const UPD_Force = UPD_Dummy + 6;

// What an `UpdateMessage` says.

/// A line of prose, its newline left off.
pub const UPDM_LINE: u32 = 1;
/// A path, and what happens to it.
pub const UPDM_PATH: u32 = 2;
/// A file written whole and put in place.
pub const UPDM_WROTE: u32 = 3;

/// What a hook given with `UPD_Hook` is handed as its message; its object
/// is the run (null for ConfirmUpdate's). Valid for the call only.
pub const UpdateMessage = extern struct {
    /// UPDM_LINE, UPDM_PATH or UPDM_WROTE.
    kind: u32 = UPDM_LINE,
    /// UPDM_LINE: 1 for the line a run that cannot finish ends with.
    failed: u32 = 0,
    /// UPDM_LINE: the line. UPDM_PATH: the path. UPDM_WROTE: the path.
    text: [*:0]const u8 = "",
    /// UPDM_PATH: what happens to it - `new` for a file the build has
    /// begun to ship, `newer` for one it changed, `again` for one that
    /// was not there, `kept` for one changed on the machine, `gone` for
    /// one the build dropped, `drawer` for a drawer made, `list` for the
    /// package's list written as the machine's own, `back to` for the
    /// system volume's snapshot; in the firmware's partition `slot` for
    /// the partition written, `boot` for a file written into it, `same`
    /// for one already there, `tried` for the file that has the firmware
    /// try it.
    what: [*:0]const u8 = "",
    /// UPDM_PATH: the bytes written for it, 0 where none are.
    /// UPDM_WROTE: the file's length.
    bytes: u64 align(4) = 0,
};

/// What a run came to, from GetUpdateInfo.
pub const UpdateInfo = extern struct {
    /// The package read: a path, or an address. The run's own.
    source: [*:0]const u8 = "",
    /// What the package holds, from its list's first line.
    files: u32 = 0,
    bytes: u64 align(4) = 0,
    /// Files written or to be written, and their bytes.
    written: u32 = 0,
    written_bytes: u64 align(4) = 0,
    /// Paths the build dropped, deleted or to be.
    deleted: u32 = 0,
    /// Files changed on the machine and kept as they are.
    kept: u32 = 0,
    /// Drawers made or to be.
    made: u32 = 0,
    /// The files the firmware reads that the package holds, and how many
    /// of them were written or are to be.
    boot: u32 = 0,
    boot_written: u32 = 0,
    /// The partition the firmware was told to try at the next start, 0
    /// where none was: a restart that asks for it starts the new kernel.
    tried: u32 = 0,
};

/// Whether a run changes the system: anything written, deleted or made.
pub fn changes(info: *const UpdateInfo) bool {
    return info.written != 0 or info.deleted != 0 or info.made != 0;
}

/// `bytes` as a short, round number of them, NUL-terminated in `into`
/// (16 bytes are enough): 1K, 18.8M, 2G - the way a run says sizes.
pub fn bytesAsText(into: *[16:0]u8, bytes: u64) void {
    const names = [_][]const u8{ "", "K", "M", "G", "T" };
    var size = bytes;
    var tenths: u64 = 0;
    var which: usize = 0;
    while (size >= 1024 and which + 1 < names.len) : (which += 1) {
        tenths = (size % 1024) * 10 / 1024;
        size /= 1024;
    }
    var at = decimal(into, size);
    if (which != 0 and size < 100 and tenths != 0) {
        into[at] = '.';
        at += 1;
        at += decimal(into[at..], tenths);
    }
    for (names[which]) |c| {
        into[at] = c;
        at += 1;
    }
    into[at] = 0;
}

/// `value` as digits into `into`: how many bytes.
pub fn decimal(into: []u8, value: u64) usize {
    if (value == 0) {
        if (into.len != 0) into[0] = '0';
        return 1;
    }
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var left = value;
    while (left != 0) : (left /= 10) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
    }
    var at: usize = 0;
    while (at < count and at < into.len) : (at += 1) into[at] = digits[count - 1 - at];
    return count;
}
