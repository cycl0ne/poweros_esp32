// SPDX-License-Identifier: MIT
//! Update: an installed system brought up to date from a release
//! package, taking from it exactly what differs and leaving what was
//! changed here alone. Built against the SDK only; the work is
//! LIBS:update.library's (`sdk.update`), which SYS:System/Update runs in
//! a window.
//!
//!   Update FROM/K,CHECK/S,BOOT/S,FORCE/S,QUIET/S,CONFIRM/S,RESTART/S
//!
//!   Update                         from where the machine was installed
//!   Update CHECK                   what would happen, and nothing else
//!   Update FROM WORK:package       from a package on a volume
//!   Update FROM http://10.0.2.2:8080/     from one a server hands out
//!   Update BOOT RESTART            the kernel too, and start on it
//!   Update CONFIRM                 the kernel that came up, kept
//!
//! FROM is a release package - a directory holding `manifest`,
//! `system/` and `boot/`. An argument with `://` in it is an address,
//! read through LIBS:http.library; anything else is a path, so a mounted
//! share, a stick or a second disk wants no network and no server.
//! Without FROM the source is the one `ENVARC:Sys/install.prefs` kept,
//! which is where the system came from.
//!
//! Three things are compared, not two: the list the machine was given
//! (`SYS:System/manifest`), the list in the package, and the file
//! itself.
//!
//!     installed  file      package   what happens
//!     =          there     =         nothing; the file is not read
//!     =          gone      =         written again
//!     =          =         differs   fetched and written
//!     =          differs   any       changed here: kept, and said
//!     not in it  -         in it     new: fetched
//!     in it      -         not in it the build dropped it: deleted
//!     not in it  -         not in it the machine's own: never touched
//!
//! Where the two lists agree the file is looked for and not read, so an
//! update costs one name a path and nothing more for everything the
//! build left as it was, and a file that went missing comes back.
//!
//! A line is said for every path something happens to, the first word
//! saying what: `new` for one the build has begun to ship, `newer` for
//! one it changed, `again` for one that was not there, `kept` for one
//! changed on this machine, `gone` for one the build dropped, `drawer`
//! for a drawer made, and `list` for the package's list written as the
//! machine's own at the end.
//!
//! So an edited `ENVARC:Sys/style.prefs` or a `DEVS:NetInterfaces/WLAN0`
//! with a passphrase in it lives through every update with no list of
//! exceptions, and FORCE is how the package wins instead. Each file is
//! fetched to a name of its own on the volume, held against the length
//! and the CRC-32 the list gives, and renamed into place, so a run that
//! is cut leaves either the old file or the new one; what the build
//! dropped goes last and in reverse, a drawer after what was in it; and
//! the package's list is written as the machine's own at the very end,
//! so a run that never finished looks like one that never happened.
//!
//! CHECK says all of that and writes nothing. Its return code is 5 where
//! there is something to do and 0 where there is not, so a script can
//! ask. A run that did something answers 0, one stopped with Ctrl-C 5,
//! and one that could not finish 20, with the reason said.
//!
//! **BOOT** writes the other half as well: the files the firmware reads,
//! into the partition it reads them from, after the system volume's - a
//! system whose files are all there is of no use if the machine still
//! loads the kernel it was installed with, and a kernel written before
//! them would be the one that came up next to files it has never seen.
//! That partition is found through rdb.library, by the name
//! `install.prefs` kept: the slot
//! not in use written where the firmware starts from either of a pair,
//! `autoboot.txt` pointed at it for a single start, and the file being
//! replaced kept as `<name>.old` where there is no second partition.
//!
//! **CONFIRM** is what the system that came up on a tried partition runs
//! to keep it: the two numbers in `autoboot.txt` the other way round, so
//! that the next start is on this partition with no flag set. A system
//! that never comes up never runs it, and the start after the tried one
//! is back on the partition that worked.
//!
//! **RESTART** starts the machine again at the end, through `C:Reboot`,
//! which holds every drive still first; where a partition was written to
//! be tried it asks the firmware for that one, this once.
//!
//! Before the first file is written the system volume is given a
//! snapshot, where it is a file system that keeps
//! them: what a system that comes up and is wrong is put back to. There
//! is one of it and it is made again each run, since a volume is only
//! ever put back to its newest snapshot.

const sdk = @import("sdk");
const dos = sdk.dos;
const utility = sdk.utility;
const prefs = sdk.prefs;
const update = sdk.update;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const UpdateBase = sdk.interface.update.UpdateBase;
const TagItem = utility.TagItem;
const Printf = dos.stdio.Printf;

const auto = @import("auto.zig");

pub const COMMAND_NAME = "Update";
const VERSION_STRING = "\x00$VER: Update 1.2 (08.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FROM/K,CHECK/S,BOOT/S,FORCE/S,QUIET/S,CONFIRM/S,RESTART/S,AUTO/S";
const arg_from = 0;
const arg_check = 1;
const arg_boot = 2;
const arg_force = 3;
const arg_quiet = 4;
const arg_confirm = 5;
const arg_restart = 6;
const arg_auto = 7;
const arg_count = 8;

const utility_version = 0;
const update_version = 1;

/// What the command was asked, the libraries it calls, and the run.
pub const Command = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ub: *UtilityBase,
    upd: *UpdateBase,
    run: ?*update.Update = null,
    check: bool = false,
    force: bool = false,
    quiet: bool = false,
    want_boot: bool = false,
    restart: bool = false,
    auto: bool = false,
    /// What the last walk came to.
    info: update.UpdateInfo = .{},
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    const utility_lib = sys.OpenLibrary(utility.UTILITYNAME, utility_version) orelse {
        _ = Printf(dl, "%s: %s is not there\n", .{ COMMAND_NAME, utility.UTILITYNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(utility_lib);
    const ub: *UtilityBase = @ptrCast(utility_lib);

    const update_lib = sys.OpenLibrary(update.UPDATENAME, update_version) orelse {
        _ = Printf(dl, "%s: %s is not there\n", .{ COMMAND_NAME, update.UPDATENAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(update_lib);
    const upd: *UpdateBase = @ptrCast(update_lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    var command: Command = .{
        .sys = sys,
        .dl = dl,
        .ub = ub,
        .upd = upd,
        .check = argv[arg_check] != 0,
        .force = argv[arg_force] != 0,
        .quiet = argv[arg_quiet] != 0,
        .want_boot = argv[arg_boot] != 0,
        .restart = argv[arg_restart] != 0,
        .auto = argv[arg_auto] != 0,
    };

    // CONFIRM is the started system's own step and wants no package: it
    // says the kernel that was tried came up.
    if (argv[arg_confirm] != 0) {
        const code = upd.ConfirmUpdate(&[_]TagItem{
            .{ .tag = update.UPD_Check, .data = @intFromBool(command.check) },
            .{ .tag = update.UPD_Quiet, .data = @intFromBool(command.quiet) },
            .{},
        });
        if (code == dos.RETURN_OK and command.restart) restart(&command, false);
        return code;
    }

    // What the machine was told to do by itself, which AUTO does.
    if (command.auto) {
        var wanted: prefs.update.Settings = .{};
        const wants = switch (auto.settingsOf(&command, &wanted)) {
            .wrong => return dos.RETURN_FAIL,
            // A machine looks nowhere unless it was told where.
            .none => return dos.RETURN_OK,
            .settings => |held| held,
        };
        if (!wants.at_start) return dos.RETURN_OK;
        // A run of its own has no console: what it finds is said, and
        // writing it is asked for unless the file says otherwise.
        command.check = !wants.apply;
        command.want_boot = command.want_boot or wants.boot;
    }

    // Without FROM the package is the one update.prefs names, else the
    // one the system was installed from: the library looks.
    const from = dos.rdargs.string(argv[arg_from]);
    command.run = upd.CreateUpdate(&[_]TagItem{
        .{ .tag = if (from != null) update.UPD_Source else utility.TAG_IGNORE, .data = @intFromPtr(from) },
        .{ .tag = update.UPD_Quiet, .data = @intFromBool(command.quiet) },
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer upd.DeleteUpdate(command.run);
    return whole(&command);
}

/// The run, and what AUTO puts around it: a look first, what it found in
/// the system log and on the desktop, and the writing once it is asked
/// for. An ordinary run is the walk alone.
fn whole(command: *Command) i32 {
    if (!command.auto) return walk(command);
    const code = walk(command);
    if (code == dos.RETURN_FAIL) return code;
    const info = &command.info;
    if (code != dos.RETURN_WARN) {
        // Nothing to do, or everything done already because the file
        // said to write what was found without asking.
        if (!update.changes(info)) auto.logged(command, "nothing newer at %s\n", .{info.source});
        return code;
    }
    auto.logged(command, "%ld files to write and %ld to delete at %s\n", .{
        @as(u64, info.written), @as(u64, info.deleted), info.source,
    });
    const now = auto.offer(command) orelse return code;
    if (!now) return code;
    command.check = false;
    return walk(command);
}

/// One walk, what it came to said, a run of its own's work put in the
/// log, and the machine started again where RESTART asks.
fn walk(command: *Command) i32 {
    const run = command.run.?;
    const code = command.upd.DoUpdate(run, &[_]TagItem{
        .{ .tag = update.UPD_Check, .data = @intFromBool(command.check) },
        .{ .tag = update.UPD_Boot, .data = @intFromBool(command.want_boot) },
        .{ .tag = update.UPD_Force, .data = @intFromBool(command.force) },
        .{},
    });
    command.upd.GetUpdateInfo(run, &command.info);
    if (code == dos.RETURN_FAIL) return code;
    said(command);
    const info = &command.info;
    if (command.auto and !command.check and update.changes(info)) {
        auto.logged(command, "%ld files written, %ld deleted\n", .{ @as(u64, info.written), @as(u64, info.deleted) });
    }
    if (command.restart and !command.check) restart(command, info.tried != 0);
    return code;
}

/// The machine started again through `C:Reboot`, which holds every drive
/// still first; `tried` asks the firmware for the partition that was
/// written, this once.
fn restart(command: *Command, tried: bool) void {
    const dl = command.dl;
    _ = Printf(dl, "Restarting.\n", .{});
    _ = dl.Flush(dl.Output());
    const line: [*:0]const u8 = if (tried) "C:Reboot TRYBOOT FORCE" else "C:Reboot FORCE";
    if (!dl.Execute(line, null, null)) {
        _ = fail(command, "C:Reboot is not there, so nothing was restarted\n", .{});
    }
}

/// A line said unless QUIET.
fn say(command: *Command, comptime format: [:0]const u8, args: anytype) void {
    if (command.quiet) return;
    _ = Printf(command.dl, format, args);
}

/// What went wrong, with the command's name in front of it, and the code
/// a failed update answers.
pub fn fail(command: *Command, comptime format: [:0]const u8, args: anytype) i32 {
    _ = command.dl.PutStr(COMMAND_NAME ++ ": ");
    _ = Printf(command.dl, format, args);
    return dos.RETURN_FAIL;
}

/// What the run came to, in one line.
fn said(command: *Command) void {
    const info = &command.info;
    if (!update.changes(info) and info.kept == 0) {
        say(command, "Nothing to do: this system is what that package holds.\n", .{});
        return;
    }
    var size: [16:0]u8 = @splat(0);
    update.bytesAsText(&size, info.written_bytes);
    say(command, "%s: %d written (%s), %d deleted, %d kept as they are, %d drawers made.\n", .{
        if (command.check) "Would be" else "Done",
        info.written,
        @as([*:0]const u8, @ptrCast(&size)),
        info.deleted,
        info.kept,
        info.made,
    });
    if (info.kept != 0) {
        say(command, "What is kept was changed on this machine; FORCE takes the package's own.\n", .{});
    }
    if (!command.want_boot and info.boot != 0) {
        say(command, "The %d files the firmware reads are in the package too; BOOT writes them into the partition it reads.\n", .{info.boot});
    }
    if (info.tried != 0) {
        say(command, "That partition is the one the firmware starts from for a single start, once the machine is restarted with the flag for it set (C:Reboot TRYBOOT, or RESTART here); the start after that is on the partition it starts from now. Update CONFIRM on the system that comes up keeps the new one.\n", .{});
    } else if (!command.check and update.changes(info)) {
        say(command, "Restart to run what was written.\n", .{});
    }
}
