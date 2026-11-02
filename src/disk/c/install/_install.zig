// SPDX-License-Identifier: MIT
//! What the install's parts share: the run it all hangs off, the drives
//! it makes, and the small helpers the parts print and ask through.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const rdb = sdk.rdb;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const RDBBase = sdk.interface.rdb.RDBBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Install";

/// The drives an install makes, by the names the disks guide's recipe
/// gives them: the system in the container, the rest of it beside, and
/// the partition the firmware reads.
pub const default_system = "DH0";
pub const default_work = "DH1";
pub const default_boot = "BOOT";
pub const default_boot_b = "BOOTB";

/// The volumes' labels.
pub const default_label = "System";
pub const work_label = "Work";

/// How large a boot partition is: a kernel, what the firmware reads with
/// it, and room for the one it is replacing.
pub const boot_bytes: u64 = 256 * 1024 * 1024;

/// How large the system partition is unless SIZE says: this much, or half
/// of what the container has when half is less.
pub const system_bytes: u64 = 32 * 1024 * 1024 * 1024;

/// The least the container may be: the system's own files are tens of
/// megabytes, and posfs wants room for its journal and a snapshot beside
/// them. A disk that cannot hold this much with its boot partitions is
/// refused before the question, not after the table is written.
pub const least_container: u64 = 128 * 1024 * 1024;

/// The most boot partitions a firmware starts from (`SYSTAG_BootSlots`).
pub const max_slots = 2;

/// A name with its colon, as dos's calls want it.
pub const DriveName = dos.blockdrives.Name;

/// One drive an install makes.
pub const Drive = struct {
    /// The name asked for, which the table or the GPT entry gets.
    name: [*:0]const u8 = "",
    /// The volume's label.
    label: [*:0]const u8 = "",
    /// Its DosType.
    dos_type: u32 = 0,
    /// What it was mounted as - the name with dots added where that was
    /// taken - with its colon. Empty until it is mounted.
    mounted: DriveName = @splat(0),

    /// Whether it is mounted, and so has a name to write to.
    pub fn there(drive: *const Drive) bool {
        return drive.mounted[0] != 0;
    }

    /// Its mounted name with the colon, for dos.
    pub fn path(drive: *const Drive) [*:0]const u8 {
        return @ptrCast(&drive.mounted);
    }
};

/// Where the files come from.
pub const Kind = enum {
    /// The running system: `SYS:` for the files, `SYS:Storage/Boot` for
    /// what the firmware reads.
    running,
    /// A package in a directory, wherever that is read from.
    directory,
};

/// The install, from its arguments to the disk it leaves.
pub const Run = struct {
    sys: *ExecBase,
    dl: *DosBase,
    rb: *RDBBase,
    eb: *ExpansionBase,
    ub: *UtilityBase,

    /// The block device and unit being installed onto.
    device: [*:0]const u8 = "",
    unit: u32 = 0,

    /// What was asked for.
    quiet: bool = false,
    force: bool = false,
    restart: bool = false,
    /// SIZE in bytes, 0 for the default.
    size: u64 = 0,
    /// FROM, empty for the running system.
    from: [*:0]const u8 = "",
    kind: Kind = .running,

    /// How many partitions this board's firmware starts from.
    slots: u32 = 1,

    boot: [max_slots]Drive = .{ .{}, .{} },
    system: Drive = .{},
    work: Drive = .{},

    /// The table, while it is open.
    handle: ?*rdb.RDBHandle = null,

    /// The chip and board the source says its files are for, as text in
    /// the source's own manifest; empty where it named none.
    board: [32:0]u8 = @splat(0),

    /// How many files and bytes went over, for the last word.
    files: u32 = 0,
    bytes: u64 = 0,
};

/// A byte count as a person reads it: "14.9M", "4096" for something
/// small.
pub fn bytesAsText(into: *[16:0]u8, bytes: u64) void {
    const units = [_]struct { scale: u64, tag: []const u8 }{
        .{ .scale = 1 << 40, .tag = "T" },
        .{ .scale = 1 << 30, .tag = "G" },
        .{ .scale = 1 << 20, .tag = "M" },
        .{ .scale = 1 << 10, .tag = "K" },
    };
    for (units) |unit| {
        if (bytes < unit.scale) continue;
        const whole = bytes / unit.scale;
        const tenths = (bytes % unit.scale) * 10 / unit.scale;
        var at = decimal(into, whole);
        if (whole < 100) { // a tenth still tells you something there
            into[at] = '.';
            at += 1;
            at += decimal(into[at..], tenths);
        }
        at += copy(into[at..], unit.tag);
        into[at] = 0;
        return;
    }
    const at = decimal(into, bytes);
    into[at] = 0;
}

/// `value` in decimal digits into `into`; how many.
pub fn decimal(into: []u8, value: u64) usize {
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var left = value;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    for (0..count) |index| into[index] = digits[count - 1 - index];
    return count;
}

/// `from` into `into`; how many bytes.
pub fn copy(into: []u8, from: []const u8) usize {
    @memcpy(into[0..from.len], from);
    return from.len;
}

/// A NUL-terminated text's length.
pub fn length(text: [*:0]const u8) usize {
    var at: usize = 0;
    while (text[at] != 0) at += 1;
    return at;
}

/// A name with its colon into a drive's `mounted`: what MountPartition
/// answered, which may be the asked name with dots added.
pub fn mountedName(into: *DriveName, name: *const rdb.MountName) void {
    const text: [*:0]const u8 = @ptrCast(name);
    const at = copy(into, text[0..length(text)]);
    into[at] = ':';
    into[at + 1] = 0;
}

/// A line said unless QUIET.
pub fn say(run: *Run, comptime format: [:0]const u8, args: anytype) void {
    if (run.quiet) return;
    _ = Printf(run.dl, format, args);
}

/// A line always said, and the output flushed: what the person is waited
/// on for comes after it.
pub fn tell(run: *Run, comptime format: [:0]const u8, args: anytype) void {
    _ = Printf(run.dl, format, args);
    _ = run.dl.Flush(run.dl.Output());
}

/// What went wrong, with the command's name in front of it, and the code
/// a failed install answers.
pub fn fail(run: *Run, comptime format: [:0]const u8, args: anytype) i32 {
    _ = run.dl.PutStr(COMMAND_NAME ++ ": ");
    _ = Printf(run.dl, format, args);
    return dos.RETURN_FAIL;
}

/// What dos said went wrong, and the same code.
pub fn failed(run: *Run, what: [*:0]const u8, code: i32) i32 {
    _ = run.dl.PrintFault(code, what);
    return dos.RETURN_FAIL;
}

/// RETURN to go on, or Ctrl-C. A line is read rather than a character, so
/// a script can answer with a blank one.
pub fn confirm(run: *Run) bool {
    const dl = run.dl;
    _ = dl.PutStr("Press RETURN to install, or CTRL-C to stop: ");
    _ = dl.Flush(dl.Output());
    while (true) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) return false;
        const char = dl.FGetC(dl.Input());
        if (char < 0) return false; // the end of the input, or a broken stream
        if (char == '\n') return true;
    }
}

/// Whether Ctrl-C was typed; it is said once where it was.
pub fn stopped(run: *Run) bool {
    if (run.dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) return false;
    _ = run.dl.PrintFault(dos.ERROR_BREAK, null);
    return true;
}

/// A fact of the board's system tag list.
pub fn boardFact(run: *Run, tag: sdk.utility.Tag, default: usize) usize {
    return run.ub.GetTagData(tag, default, run.eb.SystemTags());
}
