// SPDX-License-Identifier: MIT
//! DoUpdate: the package compared with the system and the system brought
//! up to it - the whole of a run, once CreateUpdate has made it ready.

const sdk = @import("sdk");
const dos = sdk.dos;
const install = sdk.install;
const manifest = install.manifest;
const prefs = sdk.prefs;
const update = sdk.update;
const utility = sdk.utility;
const UpdateBase = @import("../update_base.zig").UpdateBase;
const _run = @import("_run.zig");
const Run = _run.Run;
const _package = @import("../package/_package.zig");
const _system = @import("../system/_system.zig");
const _boot = @import("../boot/_boot.zig");

/// Compares the package with the system and brings the system up to it.
///
/// SYNOPSIS:
/// ```zig
/// fn DoUpdate(base: *UpdateBase, run: *Run, tags: ?[*]const TagItem) i32
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `run` - from CreateUpdate, on the task that made it.
/// - `tags` - may be null:
///   - `UPD_Check` (bool): what would happen said, nothing written.
///   - `UPD_Boot` (bool): the files the firmware reads written too, into
///     the partition it reads them from, after the system volume's.
///   - `UPD_Force` (bool): the package's own written over files changed
///     on the machine, and taken from a package built for another board.
///
/// RESULT:
/// - `RETURN_OK`: nothing to do, or all of it done.
/// - `RETURN_WARN`: `UPD_Check` found something to do, or the run was
///   stopped with Ctrl-C between two files.
/// - `RETURN_FAIL`: it could not finish. Ctrl-C in the middle of a file
///   read from an address is said as the break it was; anything else is
///   said as a failure - no `SYS:Storage/installed.manifest`, the package or its list
///   not to be read or not sound, a package for another chip or (without
///   `UPD_Force`) another board, a file that did not arrive whole, a
///   volume that took no write; with `UPD_Boot`, the firmware's partition
///   not found or not mounted.
///
/// BEHAVIOR:
/// The run's counts start again at 0 (GetUpdateInfo reads them). The
/// package's list is read whole and held against the list the machine was
/// given, path by path, both sorted alike; the file itself is read only
/// where the two disagree. For each path that something happens to, a row
/// is said: `new`, `newer`, `again`, `kept`, `gone`, `drawer`, then
/// `list` once the package's list is the machine's own.
///
/// The machine's list is read from `SYS:Storage/installed.manifest`, or,
/// where a system was installed with it at `SYS:System/manifest`, from
/// there: a run that is not a check then writes it to its own place even
/// with nothing else to do, says `list` for it, and deletes the old one.
///
/// ### Written
/// Each file is fetched to a name of its own on its volume, held against
/// the list's length and CRC-32, and renamed into place - a hook hears
/// `UPDM_WROTE` for it. What the build dropped goes after everything
/// else, in reverse; the package's list is written last. Before the first
/// file the system volume is given a snapshot, where it keeps them.
///
/// ### UPD_Boot
/// The firmware's partition is found through rdb.library, by the name
/// `install.prefs` gives it, and mounted for the run. Where the firmware
/// starts from either of two, the one not in use is written and
/// `autoboot.txt` pointed at it for one start (GetUpdateInfo's `tried`);
/// where it reads one, each file replaced is kept as `<name>.old`.
///
/// CONTEXT:
/// - Waits: yes - for dos's packets, the network, the disks.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: the Process that made the run.
///
/// OWNERSHIP:
/// Nothing the caller frees. What is read is the run's for the call.
///
/// NOTES:
/// A run may be done again - a check, then the writing - and each counts
/// for itself. Ctrl-C is looked for between files on the task that made
/// the run, so a run on a process of its own is stopped with
/// `Signal(process, SIGBREAKF_CTRL_C)`; what was written stays, and the
/// machine's list is left as it was, so the next run finds the rest.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateUpdate`, `GetUpdateInfo`, `ConfirmUpdate`, `sdk.update`
///
/// EXAMPLES:
/// ```zig
/// var code = upd.DoUpdate(run, &[_]utility.TagItem{ .{ .tag = update.UPD_Check, .data = 1 }, .{} });
/// if (code == dos.RETURN_WARN) code = upd.DoUpdate(run, null);
/// var info: update.UpdateInfo = .{};
/// upd.GetUpdateInfo(run, &info);
/// ```
pub fn DoUpdate(base: *UpdateBase, run: *Run, tags: ?[*]const utility.TagItem) i32 {
    const ub = base.utility_base;
    run.check = ub.GetTagData(update.UPD_Check, 0, tags) != 0;
    run.want_boot = ub.GetTagData(update.UPD_Boot, 0, tags) != 0;
    run.force = ub.GetTagData(update.UPD_Force, 0, tags) != 0;
    run.again();
    return walk(run, &run.settings);
}

/// The run, once its switches are set: the lists read and held against
/// this machine, the system volume brought up to the package, and the
/// firmware's partition after it.
fn walk(run: *Run, settings: *const prefs.install.Settings) i32 {
    const sys = run.sys;

    // The list where the machine keeps it, or where a system installed
    // with it elsewhere has it: `_system.walk` moves that one.
    var former = false;
    const mine = prefs.loadWhole(sys, run.dl, install.installed_manifest) orelse found: {
        former = true;
        break :found prefs.loadWhole(sys, run.dl, _system.former_list) orelse {
            return _run.fail(run, "%s is not there: this system was not installed from a list, and there is nothing to compare against. C:Install leaves one\n", .{install.installed_manifest});
        };
    };
    defer sys.FreeVec(@ptrCast(mine.ptr));

    const theirs = _package.whole(run, install.package_manifest) orelse return dos.RETURN_FAIL;
    defer sys.FreeVec(@ptrCast(theirs.ptr));

    const reader = manifest.Reader.init(theirs) catch |err| {
        return _run.fail(run, "the package's %s: %s\n", .{ install.package_manifest, manifest.why(err) });
    };
    if (reader.header.chip != sdk.hardware.chip) {
        return _run.fail(run, "that package holds files for %s; this machine is %s\n", .{
            @as([*:0]const u8, @tagName(reader.header.chip)),
            @as([*:0]const u8, @tagName(sdk.hardware.chip)),
        });
    }
    const board: [*:0]const u8 = @ptrCast(&settings.board);
    if (!run.force and board[0] != 0 and reader.header.board.len != 0 and
        !manifest.samePath(board[0..run.ub.Strlen(board)], reader.header.board))
    {
        var theirs_board: [manifest.max_board + 1:0]u8 = @splat(0);
        theirs_board[_run.copy(&theirs_board, reader.header.board)] = 0;
        return _run.fail(run, "that package holds a kernel for %s, and this system was installed as %s: FORCE takes it all the same\n", .{
            @as([*:0]const u8, @ptrCast(&theirs_board)), board,
        });
    }
    run.files = reader.header.counts.files;
    run.bytes = reader.header.counts.bytes;

    var size: [16:0]u8 = @splat(0);
    update.bytesAsText(&size, run.bytes);
    _run.say(run, "%s: %d files, %s\n", .{ run.from, run.files, @as([*:0]const u8, @ptrCast(&size)) });

    var code = _system.walk(run, mine, theirs, former);
    if (code == dos.RETURN_FAIL) return code;

    // What the firmware reads goes last: a system whose files are all
    // there is of no use if the machine still loads the kernel it was
    // installed with, and a kernel written before them would be the one
    // that came up next to files it has never seen.
    if (run.want_boot) {
        const wrote = _boot.write(run, theirs);
        if (wrote == dos.RETURN_FAIL) return wrote;
        if (code == dos.RETURN_OK) code = wrote;
        if (run.check and run.boot_written != 0) code = dos.RETURN_WARN;
    }
    return code;
}
