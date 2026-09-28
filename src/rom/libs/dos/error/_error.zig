// SPDX-License-Identifier: MPL-2.0
//! What `ErrorReport` asks, and the two ways it can ask.
//!
//! A question goes up as a requester on the screen when there is one,
//! and as a line of text on the process's console when there is not - a
//! Shell on the serial line or over telnet has no screen, and an error
//! it can do nothing about is worse than an error it can answer. Neither
//! is possible for a process with no console and no screen, and then the
//! error goes back to the caller as it always did.
//!
//! `pr_WindowPtr` decides: -1 means this process is never to be asked
//! anything, whatever there is to ask on.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const DosBase = @import("../dos_base.zig").DosBase;
const _process = @import("../process/_process.zig");

/// `pr_WindowPtr` when the process is not to be asked.
pub const no_window: usize = ~@as(usize, 0);

/// What a code is asked about. A code with no question here is one
/// `ErrorReport` does not ask about at all.
pub const Question = struct {
    /// The words, with `%s` where the volume's name goes when there is
    /// one to name.
    text: [:0]const u8,
    /// Whether the volume's name belongs in it.
    names_volume: bool = true,
};

pub fn questionFor(code: i32) ?Question {
    return switch (code) {
        dos.ERROR_DEVICE_NOT_MOUNTED => .{ .text = "Please insert volume %s in any drive" },
        dos.ERROR_DISK_WRITE_PROTECTED => .{ .text = "Volume %s is write protected" },
        dos.ERROR_DISK_FULL => .{ .text = "Volume %s is full" },
        dos.ERROR_DISK_NOT_VALIDATED => .{ .text = "Volume %s is not validated" },
        dos.ERROR_NOT_A_DOS_DISK => .{ .text = "Volume %s is not a DOS disk" },
        dos.ERROR_NO_DISK => .{ .text = "No disk in the drive", .names_volume = false },
        dos.ABORT_DISK_ERROR => .{ .text = "Volume %s has a read/write error" },
        else => null,
    };
}

/// The volume a report is about, by the shape of what it was given.
pub fn volumeName(db: *DosBase, report_type: u32, arg: usize) ?[*:0]const u8 {
    switch (report_type) {
        dos.REPORT_INSERT => return @ptrFromInt(arg),
        dos.REPORT_VOLUME => {
            const node: ?*dos.DosList = @ptrFromInt(arg);
            return if (node) |n| n.name else null;
        },
        dos.REPORT_LOCK => {
            const lock: ?*dos.FileLock = @ptrFromInt(arg);
            const node = if (lock) |l| l.volume else null;
            return if (node) |n| n.name else null;
        },
        dos.REPORT_STREAM => {
            const fh: ?*dos.FileHandle = @ptrFromInt(arg);
            _ = fh;
            _ = db;
            return null;
        },
        else => return null,
    }
}
