// SPDX-License-Identifier: MIT
//! Update: an installed system brought up to date from a release
//! package, taking from it exactly what differs and leaving what was
//! changed here alone. Built against the SDK only.
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
//! `install.prefs` kept, and `boot.zig` has the whole of it: the slot
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
//! snapshot (`shared.snapshot`), where it is a file system that keeps
//! them: what a system that comes up and is wrong is put back to. There
//! is one of it and it is made again each run, since a volume is only
//! ever put back to its newest snapshot.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const http = sdk.http;
const bsd = sdk.bsdsocket;
const utility = sdk.utility;
const install = sdk.install;
const manifest = install.manifest;
const prefs = sdk.prefs;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const HttpBase = sdk.interface.http.HttpBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const Printf = dos.stdio.Printf;

const shared = @import("_update.zig");
const source = @import("source.zig");
const compare = @import("compare.zig");
const boot = @import("boot.zig");
const Run = shared.Run;

pub const COMMAND_NAME = shared.COMMAND_NAME;
const VERSION_STRING = "\x00$VER: Update 1.0 (01.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FROM/K,CHECK/S,BOOT/S,FORCE/S,QUIET/S,CONFIRM/S,RESTART/S";
const arg_from = 0;
const arg_check = 1;
const arg_boot = 2;
const arg_force = 3;
const arg_quiet = 4;
const arg_confirm = 5;
const arg_restart = 6;
const arg_count = 7;

const utility_version = 0;

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

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    var run: Run = .{ .sys = sys, .dl = dl, .ub = ub };
    run.check = argv[arg_check] != 0;
    run.force = argv[arg_force] != 0;
    run.quiet = argv[arg_quiet] != 0;
    run.want_boot = argv[arg_boot] != 0;
    run.restart = argv[arg_restart] != 0;

    // What the install left, which says where the files came from and
    // which board they were built for.
    var settings: prefs.install.Settings = .{};
    const left = prefs.loadWhole(sys, dl, prefs.install.ENVARC_FILE);
    defer if (left) |text| sys.FreeVec(@ptrCast(text.ptr));
    if (left) |text| {
        if (prefs.firstLine(text)) |line| {
            if (prefs.install.parse(ub, line, &settings)) |wrong| {
                return shared.fail(&run, "%s: %s\n", .{ prefs.install.ENVARC_FILE, wrong });
            }
        }
    }

    run.installed = &settings;

    // CONFIRM is the started system's own step and wants no package: it
    // says the kernel that was tried came up.
    if (argv[arg_confirm] != 0) {
        const code = boot.confirm(&run);
        if (code == dos.RETURN_OK and argv[arg_restart] != 0) restart(&run, false);
        return code;
    }

    if (dos.rdargs.string(argv[arg_from])) |text| {
        run.from = text;
    } else {
        const kept: [*:0]const u8 = @ptrCast(&settings.source);
        if (kept[0] == 0) {
            return shared.fail(&run, "no FROM, and %s says nothing about where this system came from\n", .{prefs.install.ENVARC_FILE});
        }
        run.from = kept;
    }
    run.kind = if (source.isAddress(run.from[0..shared.length(run.from)])) .address else .path;

    const memory = sys.AllocVec(shared.buffer_bytes, exec.MEMF_ANY) orelse {
        return shared.fail(&run, "no memory\n", .{});
    };
    defer sys.FreeVec(memory);
    const bytes: [*]u8 = @ptrCast(memory);
    run.buffer = bytes[0..shared.buffer_bytes];

    if (run.kind == .address) {
        const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
            return shared.fail(&run, "%s is an address and %s is not there\n", .{ run.from, bsd.SOCKETNAME });
        };
        defer sys.CloseLibrary(socket_lib);
        const http_lib = sys.OpenLibrary(http.HTTPNAME, 1) orelse {
            return shared.fail(&run, "%s is an address and %s is not there\n", .{ run.from, http.HTTPNAME });
        };
        defer sys.CloseLibrary(http_lib);
        run.sb = @ptrCast(socket_lib);
        run.hb = @ptrCast(http_lib);
        const hb = run.hb.?;
        run.client = hb.CreateClient(run.sb.?, &[_]utility.TagItem{
            .{ .tag = http.HTTP_UserAgent, .data = @intFromPtr("PowerOS-Update/1.0") },
            .{},
        }) orelse return shared.fail(&run, "no memory for the HTTP client\n", .{});
        defer hb.DeleteClient(run.client);
        return update(&run, &settings);
    }
    return update(&run, &settings);
}

/// The whole of it, once the source is known and the libraries are open.
fn update(run: *Run, settings: *const prefs.install.Settings) i32 {
    const sys = run.sys;

    const mine = prefs.loadWhole(sys, run.dl, install.installed_manifest) orelse {
        return shared.fail(run, "%s is not there: this system was not installed from a list, and there is nothing to compare against. C:Install leaves one\n", .{install.installed_manifest});
    };
    defer sys.FreeVec(@ptrCast(mine.ptr));

    const theirs = source.whole(run, install.package_manifest) orelse return dos.RETURN_FAIL;
    defer sys.FreeVec(@ptrCast(theirs.ptr));

    const reader = manifest.Reader.init(theirs) catch |err| {
        return shared.fail(run, "the package's %s: %s\n", .{ install.package_manifest, manifest.why(err) });
    };
    if (reader.header.chip != sdk.hardware.chip) {
        return shared.fail(run, "that package holds files for %s; this machine is %s\n", .{
            @as([*:0]const u8, @tagName(reader.header.chip)),
            @as([*:0]const u8, @tagName(sdk.hardware.chip)),
        });
    }
    const board: [*:0]const u8 = @ptrCast(&settings.board);
    if (!run.force and board[0] != 0 and reader.header.board.len != 0 and
        !manifest.samePath(board[0..shared.length(board)], reader.header.board))
    {
        var theirs_board: [manifest.max_board + 1:0]u8 = @splat(0);
        theirs_board[shared.copy(&theirs_board, reader.header.board)] = 0;
        return shared.fail(run, "that package holds a kernel for %s, and this system was installed as %s: FORCE takes it all the same\n", .{
            @as([*:0]const u8, @ptrCast(&theirs_board)), board,
        });
    }
    run.files = reader.header.counts.files;
    run.bytes = reader.header.counts.bytes;

    var size: [16:0]u8 = @splat(0);
    shared.bytesAsText(&size, run.bytes);
    shared.say(run, "%s: %d files, %s\n", .{ run.from, run.files, @as([*:0]const u8, @ptrCast(&size)) });

    var code = compare.walk(run, mine, theirs);
    if (code == dos.RETURN_FAIL) return code;

    // What the firmware reads goes last: a system whose files are all
    // there is of no use if the machine still loads the kernel it was
    // installed with, and a kernel written before them would be the one
    // that came up next to files it has never seen.
    if (run.want_boot) {
        const wrote = boot.write(run, theirs);
        if (wrote == dos.RETURN_FAIL) return wrote;
        if (code == dos.RETURN_OK) code = wrote;
        if (run.check and run.boot_written != 0) code = dos.RETURN_WARN;
    }
    said(run);
    if (run.restart and !run.check and code != dos.RETURN_FAIL) restart(run, run.tried != 0);
    return code;
}

/// The machine started again through `C:Reboot`, which holds every drive
/// still first; `tried` asks the firmware for the partition that was
/// written, this once.
fn restart(run: *Run, tried: bool) void {
    shared.tell(run, "Restarting.\n", .{});
    const line: [*:0]const u8 = if (tried) "C:Reboot TRYBOOT FORCE" else "C:Reboot FORCE";
    if (!run.dl.Execute(line, null, null)) {
        _ = shared.fail(run, "C:Reboot is not there, so nothing was restarted\n", .{});
    }
}

/// What the run came to, in one line.
fn said(run: *Run) void {
    if (!compare.changed(run) and run.kept == 0) {
        shared.say(run, "Nothing to do: this system is what that package holds.\n", .{});
        return;
    }
    var size: [16:0]u8 = @splat(0);
    shared.bytesAsText(&size, run.written_bytes);
    shared.say(run, "%s: %d written (%s), %d deleted, %d kept as they are, %d drawers made.\n", .{
        if (run.check) "Would be" else "Done",
        run.written,
        @as([*:0]const u8, @ptrCast(&size)),
        run.deleted,
        run.kept,
        run.made,
    });
    if (run.kept != 0) {
        shared.say(run, "What is kept was changed on this machine; FORCE takes the package's own.\n", .{});
    }
    if (!run.want_boot and run.boot != 0) {
        shared.say(run, "The %d files the firmware reads are in the package too; BOOT writes them into the partition it reads.\n", .{run.boot});
    }
    if (run.tried != 0) {
        shared.say(run, "That partition is the one the firmware starts from for a single start, once the machine is restarted with the flag for it set (C:Reboot TRYBOOT, or RESTART here); the start after that is on the partition it starts from now. Update CONFIRM on the system that comes up keeps the new one.\n", .{});
    } else if (!run.check and compare.changed(run)) {
        shared.say(run, "Restart to run what was written.\n", .{});
    }
}
