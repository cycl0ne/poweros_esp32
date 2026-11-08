// SPDX-License-Identifier: MIT
//! ConfirmUpdate: the partition the firmware was told to try kept, on the
//! system that came up on it.

const sdk = @import("sdk");
const dos = sdk.dos;
const rdb = sdk.rdb;
const prefs = sdk.prefs;
const update = sdk.update;
const utility = sdk.utility;
const RDBBase = sdk.interface.rdb.RDBBase;
const UpdateBase = @import("../update_base.zig").UpdateBase;
const _run = @import("../run/_run.zig");
const Run = _run.Run;
const _boot = @import("_boot.zig");

/// Keeps the partition the firmware was told to try as the one it starts
/// from.
///
/// SYNOPSIS:
/// ```zig
/// fn ConfirmUpdate(base: *UpdateBase, tags: ?[*]const TagItem) i32
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `tags` - may be null:
///   - `UPD_Check` (bool): whether there is one to keep said, nothing
///     written.
///   - `UPD_Hook` (`*Hook`): where what it says goes, an `UpdateMessage`
///     at a time, in place of the output; the message's object is null.
///   - `UPD_Quiet` (bool): only failures on the output.
///
/// RESULT:
/// - `RETURN_OK`: kept; or nothing to keep - a firmware that reads one
///   partition, or none being tried.
/// - `RETURN_WARN`: with `UPD_Check`, one being tried that would be kept.
/// - `RETURN_FAIL`: the reason said as a failure - `install.prefs` not a
///   line of settings, rdb.library 1 not there,
///   the disk's table not read, the partitions not found or not mounted,
///   `autoboot.txt` not written. With no memory for the call, nothing is
///   said (`IoErr` ERROR_NO_FREE_STORE).
///
/// BEHAVIOR:
/// Where the firmware starts from either of two partitions, DoUpdate with
/// `UPD_Boot` writes the one not in use and has `autoboot.txt` in the
/// first of them try it for one start. The system that came up on it
/// calls this: the two numbers in `autoboot.txt` change places, so the
/// next start is on this partition with no flag set. A system that never
/// comes up never calls it, and the start after the tried one is back on
/// the partition that worked. The partitions are found through
/// rdb.library by the names `install.prefs` gives them, and one mounted
/// for the call is taken off the device list again after it.
///
/// CONTEXT:
/// - Waits: yes - for the disk and dos's packets.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Process.
///
/// OWNERSHIP:
/// Nothing is left allocated.
///
/// BUGS:
/// Both the check and the keeping go by `autoboot.txt` alone, not by the
/// partition this system was started from: a system that wrote a
/// partition to try and was not restarted yet, or one the firmware came
/// back to after a try that did not come up, is answered the same as the
/// system on the tried partition - and keeping there makes the tried
/// partition the one the firmware starts from.
///
/// SEE ALSO:
/// `DoUpdate`, `GetUpdateInfo`, `sdk.install.autoboot`
///
/// EXAMPLES:
/// ```zig
/// const check = [_]utility.TagItem{ .{ .tag = update.UPD_Check, .data = 1 }, .{} };
/// if (upd.ConfirmUpdate(&check) == dos.RETURN_WARN) {
///     // a tried partition is running: offer to keep it
///     _ = upd.ConfirmUpdate(null);
/// }
/// ```
pub fn ConfirmUpdate(base: *UpdateBase, tags: ?[*]const utility.TagItem) i32 {
    const run = _run.make(base, tags) orelse return dos.RETURN_FAIL;
    defer _run.free(run);
    run.check = base.utility_base.GetTagData(update.UPD_Check, 0, tags) != 0;
    return keep(run);
}

/// The two numbers in `autoboot.txt` the other way round, so the next
/// start is on the partition that was tried without a flag.
fn keep(run: *Run) i32 {
    const sys = run.sys;
    const settings = &run.settings;
    const device: [*:0]const u8 = @ptrCast(&settings.device);
    const boot: [*:0]const u8 = @ptrCast(&settings.boot);
    const boot_b: [*:0]const u8 = @ptrCast(&settings.boot_b);
    if (boot_b[0] == 0) {
        _run.say(run, "This machine's firmware reads one partition, so there is nothing to keep.\n", .{});
        return dos.RETURN_OK;
    }

    const rdb_lib = sys.OpenLibrary(rdb.RDBNAME, _boot.rdb_version) orelse {
        return _run.fail(run, "%s 1 or later is not there\n", .{rdb.RDBNAME});
    };
    defer sys.CloseLibrary(rdb_lib);
    const rb: *RDBBase = @ptrCast(rdb_lib);
    var err: i32 = rdb.RDBERR_OK;
    const handle = rb.OpenRDB(device, settings.unit, &err) orelse {
        return _run.fail(run, "%s unit %d: the disk's table cannot be read\n", .{ device, settings.unit });
    };
    defer rb.CloseRDB(handle);

    var first: _boot.Slot = .{};
    defer _boot.unmount(run, rb, handle, &first);
    var lowest: u32 = 0;
    for ([_][*:0]const u8{ boot, boot_b }) |name| {
        const part = _boot.named(run, rb, handle, name) orelse continue;
        if (lowest == 0 or part.number < lowest) {
            lowest = part.number;
            first = .{ .part = part, .number = part.number };
        }
    }
    if (lowest == 0) {
        return _run.fail(run, "the GPT on %s unit %d has neither %s nor %s\n", .{ device, settings.unit, boot, boot_b });
    }
    if (_boot.mount(run, rb, handle, &first)) |code| return code;

    const now = _boot.readAutoboot(run, &first);
    if (now.tried == 0) {
        _run.say(run, "Nothing is being tried: the firmware starts from partition %d either way.\n", .{if (now.normal != 0) now.normal else first.number});
        return dos.RETURN_OK;
    }
    if (run.check) {
        _run.say(run, "Would be: partition %d kept as the one the firmware starts from, %d the one to try.\n", .{ now.tried, now.normal });
        return dos.RETURN_WARN;
    }
    if (_boot.writeAutoboot(run, &first, now.swapped())) |failed| return failed;
    _run.say(run, "Partition %d is the one the firmware starts from now, %d the one to try.\n", .{ now.tried, now.normal });
    return dos.RETURN_OK;
}
