// SPDX-License-Identifier: MIT
//! Install: a system onto a card or an SSD - partitioned, formatted,
//! filled and bootable - in one command, on a machine that has nothing
//! but a console. Built against the SDK only.
//!
//!   Install DEVICE,UNIT/N,SYSTEM/K,WORK/K,BOOT/K,SIZE/K,FROM/K,NAME/K,
//!           FORCE/S,QUIET/S,RESTART/S
//!
//!   Install                              the units one can go onto
//!   Install nvme.device                  unit 0 of it, asking first
//!   Install nvme.device 1 FORCE          unit 1, asking nothing
//!   Install nvme.device SIZE 8G          8 GB for the system, the rest for work
//!   Install nvme.device FROM WORK:package      from a release package
//!   Install sdcard.device NAME Tools RESTART   and start from it at once
//!
//! With no DEVICE it lists every unit of every block device with what
//! each one holds, and which one the running system is on - the one not
//! to install over. With one it says what it is about to do and waits for
//! RETURN, unless FORCE says yes for it.
//!
//! What it leaves on the disk:
//!
//!     block 0      a protective MBR
//!     block 1      the GPT
//!     BOOT         FAT32, 256 MB - what the firmware reads, marked
//!                  EFI System where the firmware is UEFI and Basic
//!                  data where it reads a partition by its place
//!     BOOTB        the second one, where the firmware starts from either
//!     container    the PowerOS container, the rest of the disk
//!       DH0        posfs, "System", bootable, BootPri 5
//!       DH1        posfs, "Work", the rest of the container
//!
//! The boot partitions come first because a firmware looks for its files
//! in the first ones, and the container takes what they leave. They are
//! marked not to be mounted when the medium comes in
//! (`gpt.ATTR_NO_AUTOMOUNT`), since they are the firmware's and nothing
//! here works in them: this mounts them itself to write them, and an
//! update asks rdb.library for them by the names install.prefs keeps. How many
//! there are is the board's own fact (`SYSTAG_BootSlots`): one where the
//! firmware reads one partition, two where it can be sent to the other
//! for a single start, and both then hold the same files, so that either
//! starts the machine. SYSTEM, WORK and BOOT name the drives, NAME the
//! system volume, and SIZE says how much of the container the system
//! partition has - without it 32 GB, or half the container where half is
//! less.
//!
//! FROM names a release package - a directory holding `manifest`,
//! `system/` and `boot/` - and every file is held against the sum and the
//! length its list gives, so a package that arrived damaged stops the
//! install on the file that is wrong. Without FROM the running system is
//! the source: `SYS:` for the files and `SYS:Storage/Boot` for what the
//! firmware reads, which is how a machine installs itself with no network
//! and no second machine. A package whose kernel was built for another
//! board is refused, since such a kernel starts with no console; FORCE
//! installs it all the same.
//!
//! It leaves `SYS:Storage/installed.manifest` on the new volume - the list an update
//! compares against - and `ENVARC:Sys/install.prefs`, which says what was
//! installed where and from where. RESTART starts the machine again at
//! the end, every drive of a block device held still first so that what
//! it holds is written out.
//!
//! The return code is 0 for a system installed, 5 for one stopped at the
//! question or by Ctrl-C, and 20 for one that could not be made, with the
//! reason said.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const expansion = sdk.expansion;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const RDBBase = sdk.interface.rdb.RDBBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

const drives = dos.blockdrives;

const shared = @import("_install.zig");
const units = @import("units.zig");
const disk = @import("disk.zig");
const files = @import("files.zig");
const Run = shared.Run;

pub const COMMAND_NAME = shared.COMMAND_NAME;
const VERSION_STRING = "\x00$VER: Install 1.6 (10.11.2026)\r\n";

/// rdb.library is opened at version 1 and its revision asked after: the
/// GPT calls came with 1.4 and a FAT partition of a GPT, which the boot
/// partitions are, with 1.7.
const rdb_version = 1;
const fat_revision = 7;
const expansion_version = 0;

const template = "DEVICE,UNIT/N,SYSTEM/K,WORK/K,BOOT/K,SIZE/K,FROM/K,NAME/K,FORCE/S,QUIET/S,RESTART/S";
const arg_device = 0;
const arg_unit = 1;
const arg_system = 2;
const arg_work = 3;
const arg_boot = 4;
const arg_size = 5;
const arg_from = 6;
const arg_name = 7;
const arg_force = 8;
const arg_quiet = 9;
const arg_restart = 10;
const arg_count = 11;

const MSG_NOLIBRARY = "%s: %s %d or later is needed and is not there\n";
const MSG_BAD_SIZE = "SIZE: %s is no size: a number of bytes, or one with K, M, G or T after it\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, length: usize) callconv(.c) i32 {
    _ = args;
    _ = length;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const rdb_lib = sys.OpenLibrary(sdk.rdb.RDBNAME, rdb_version) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, sdk.rdb.RDBNAME, @as(u32, rdb_version) });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(rdb_lib);
    if (rdb_lib.version == 1 and rdb_lib.revision < fat_revision) {
        _ = Printf(dl, "%s: %s 1.%d or later makes a boot partition of a GPT; this is 1.%d\n", .{
            COMMAND_NAME, sdk.rdb.RDBNAME, @as(u32, fat_revision), @as(u32, rdb_lib.revision),
        });
        return dos.RETURN_FAIL;
    }
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, expansion_version) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, expansion.EXPANSIONNAME, @as(u32, expansion_version) });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(expansion_lib);
    const utility_lib = sys.OpenLibrary(sdk.utility.UTILITYNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, sdk.utility.UTILITYNAME, @as(u32, 0) });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(utility_lib);

    var run: Run = .{
        .sys = sys,
        .dl = dl,
        .rb = @ptrCast(rdb_lib),
        .eb = @ptrCast(expansion_lib),
        .ub = @ptrCast(utility_lib),
    };
    const code = go(&run, &argv);
    _ = dl.Flush(dl.Output());
    return code;
}

fn go(run: *Run, argv: *const [arg_count]usize) i32 {
    const dl = run.dl;

    // With no device there is nothing to install onto: the units are
    // what the person needs to see.
    const device = rdargs.string(argv[arg_device]) orelse return units.list(run);

    run.device = device;
    if (rdargs.number(argv[arg_unit])) |unit| {
        if (unit < 0) return shared.fail(run, "UNIT is a unit of the device, from 0\n", .{});
        run.unit = @intCast(unit);
    }
    run.quiet = argv[arg_quiet] != 0;
    run.force = argv[arg_force] != 0;
    run.restart = argv[arg_restart] != 0;
    run.system = .{
        .name = rdargs.string(argv[arg_system]) orelse shared.default_system,
        .label = rdargs.string(argv[arg_name]) orelse shared.default_label,
        .dos_type = dos.posfs.ID_POSFS_DISK,
    };
    run.work = .{
        .name = rdargs.string(argv[arg_work]) orelse shared.default_work,
        .label = shared.work_label,
        .dos_type = dos.posfs.ID_POSFS_DISK,
    };
    const boot_name = rdargs.string(argv[arg_boot]) orelse shared.default_boot;
    const fat32 = dos.fat.typeWithFormat(dos.ID_MSDOS_DISK, dos.fat.FORMAT_FAT32);
    run.boot[0] = .{ .name = boot_name, .label = "Boot", .dos_type = fat32 };
    // The second of a pair is the first's name with a B after it, so that
    // BOOT names both of them.
    const second = secondName(boot_name) orelse {
        return shared.fail(run, "BOOT: %s leaves no room for the second partition's name, which is that name with a B after it\n", .{boot_name});
    };
    run.boot[1] = .{ .name = second, .label = "Boot B", .dos_type = fat32 };
    if (rdargs.string(argv[arg_size])) |text| {
        run.size = parseSize(text) orelse {
            return shared.fail(run, MSG_BAD_SIZE, .{text});
        };
    }
    if (rdargs.string(argv[arg_from])) |from| {
        run.from = from;
        run.kind = .directory;
    }

    // How many partitions this machine's firmware starts from is the
    // board's own fact; a board that says nothing has one.
    run.slots = @min(shared.max_slots, @max(1, shared.boardFact(run, expansion.systemtags.SYSTAG_BootSlots, 1)));

    // The source before the disk: nothing is written while there is
    // anything to say about where the files come from.
    const looked = files.look(run);
    if (looked != dos.RETURN_OK) return looked;

    if (units.onIt(run, run.device, run.unit) and !run.force) {
        return shared.fail(run, "the running system is on %s unit %d. Installing over the disk it runs from would take it away under itself; FORCE does it all the same\n", .{ run.device, run.unit });
    }

    if (plan(run)) |code| return code;

    defer disk.done(run);
    const made = disk.prepare(run);
    if (made != dos.RETURN_OK) return made;

    shared.say(run, "\nCopying:\n", .{});
    const copied = files.copy(run);
    if (copied != dos.RETURN_OK) return copied;

    var size: [16:0]u8 = @splat(0);
    shared.bytesAsText(&size, run.bytes);
    shared.say(run, "\n%d files, %s: the system on %s, the boot files on %s", .{
        run.files, @as([*:0]const u8, @ptrCast(&size)), run.system.path(), run.boot[0].path(),
    });
    if (run.slots > 1) shared.say(run, " and %s", .{run.boot[1].path()});
    shared.say(run, ".\nThe disk starts the machine at its next cold start.\n", .{});
    shared.say(run, "What the firmware is told to load is the board's own: the disks guide has its section.\n", .{});

    if (!run.restart) {
        shared.say(run, "Restart the machine to start from it (Install ... RESTART does that too).\n", .{});
        return dos.RETURN_OK;
    }
    _ = dl.Flush(dl.Output());
    disk.done(run);
    restart(run);
    return dos.RETURN_OK;
}

/// What is about to happen, and the question before it. Null to go on, a
/// return code to stop.
fn plan(run: *Run) ?i32 {
    const dl = run.dl;
    var total: [16:0]u8 = @splat(0);
    const bytes = disk.size(run) orelse {
        return shared.fail(run, "%s unit %d cannot be read: no such unit, or no medium in it\n", .{ run.device, run.unit });
    };
    shared.bytesAsText(&total, bytes);

    // What the layout cannot do without, before anything is asked or
    // written: the boot partitions and a container worth having.
    const least = @as(u64, run.slots) * shared.boot_bytes + shared.least_container;
    if (bytes < least) {
        var least_text: [16:0]u8 = @splat(0);
        var boot_text: [16:0]u8 = @splat(0);
        shared.bytesAsText(&least_text, least);
        shared.bytesAsText(&boot_text, shared.boot_bytes);
        var container_text: [16:0]u8 = @splat(0);
        shared.bytesAsText(&container_text, shared.least_container);
        return shared.fail(run, "%s unit %d holds %s, and this board's layout wants %s: %d boot %s of %s, and a container of %s at least\n", .{
            run.device,
            run.unit,
            @as([*:0]const u8, @ptrCast(&total)),
            @as([*:0]const u8, @ptrCast(&least_text)),
            @as(u32, @intCast(run.slots)),
            @as([*:0]const u8, if (run.slots == 1) "partition" else "partitions"),
            @as([*:0]const u8, @ptrCast(&boot_text)),
            @as([*:0]const u8, @ptrCast(&container_text)),
        });
    }

    _ = Printf(dl, "Installing onto %s unit %d, %s:\n\n", .{ run.device, run.unit, @as([*:0]const u8, @ptrCast(&total)) });
    var boot: [16:0]u8 = @splat(0);
    shared.bytesAsText(&boot, shared.boot_bytes);
    for (run.boot[0..run.slots], 0..) |drive, slot| {
        _ = Printf(dl, "  %-8s FAT32  %11s  %s\n", .{
            drive.name,
            @as([*:0]const u8, @ptrCast(&boot)),
            @as([*:0]const u8, if (slot == 0) "what the firmware reads" else "the second one, the same files in it"),
        });
    }
    var system: [16:0]u8 = @splat(0);
    if (run.size != 0) {
        shared.bytesAsText(&system, run.size);
    } else {
        _ = shared.copy(&system, "32G or half");
    }
    _ = Printf(dl, "  %-8s posfs  %11s  %s, the system\n", .{ run.system.name, @as([*:0]const u8, @ptrCast(&system)), run.system.label });
    _ = Printf(dl, "  %-8s posfs  %11s  %s\n", .{ run.work.name, "the rest", run.work.label });
    if (run.kind == .running) {
        _ = Printf(dl, "\nFrom this system: SYS: and %s", .{sdk.install.boot_store});
    } else {
        _ = Printf(dl, "\nFrom %s", .{run.from});
    }
    if (run.board[0] != 0) {
        _ = Printf(dl, ", for %s", .{@as([*:0]const u8, @ptrCast(&run.board))});
    }
    _ = dl.PutStr("\n\nEverything on that disk is lost.\n");

    if (run.force) return null;
    if (!shared.confirm(run)) {
        _ = dl.PutStr("\n");
        _ = dl.PrintFault(dos.ERROR_BREAK, null);
        return dos.RETURN_WARN;
    }
    _ = dl.PutStr("\n");
    return null;
}

/// Every drive mounted from a block device held still, so that its file
/// system writes out what it holds - ColdReboot writes nothing - and the
/// machine started again. A drive that will not stop is named and the
/// restart goes ahead: the install is already on the disk.
fn restart(run: *Run) void {
    shared.say(run, "Restarting.\n", .{});
    _ = run.dl.Flush(run.dl.Output());
    var mounted: drives.List = .{};
    mounted.gather(run.dl);
    for (mounted.all()) |*name| {
        if (drives.hold(run.dl, name)) continue;
        shared.say(run, "  %s would not stop: what it holds may not be written out\n", .{drives.path(name)});
    }
    run.sys.ColdReboot();
}

/// The second boot partition's name: the first's with a `B` after it.
/// Null when that does not fit in a drive's name.
fn secondName(first: [*:0]const u8) ?[*:0]const u8 {
    const length = shared.length(first);
    if (length == 0 or length + 1 > dos.MAX_DEVICE_NAME) return null;
    @memcpy(second_name[0..length], first[0..length]);
    second_name[length] = 'B';
    second_name[length + 1] = 0;
    return @ptrCast(&second_name);
}
var second_name: [dos.MAX_DEVICE_NAME + 1:0]u8 = @splat(0);

/// A size as it is written on the command line: a number of bytes, or
/// one with K, M, G or T after it.
fn parseSize(text: [*:0]const u8) ?u64 {
    var value: u64 = 0;
    var at: usize = 0;
    var digits: u32 = 0;
    while (text[at] >= '0' and text[at] <= '9') : (at += 1) {
        if (value > (~@as(u64, 0)) / 10) return null;
        value = value * 10 + (text[at] - '0');
        digits += 1;
    }
    if (digits == 0) return null;
    const scale: u64 = switch (text[at]) {
        0 => 1,
        'k', 'K' => 1 << 10,
        'm', 'M' => 1 << 20,
        'g', 'G' => 1 << 30,
        't', 'T' => 1 << 40,
        else => return null,
    };
    if (scale != 1) {
        at += 1;
        if (text[at] != 0) return null;
        if (value > (~@as(u64, 0)) / scale) return null;
    }
    return value * scale;
}

/// The "$VER:" string every PowerOS module carries, which `Version
/// <file>` looks for. Nothing refers to it, so it needs both an export
/// and a section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
