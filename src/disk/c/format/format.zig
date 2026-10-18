// SPDX-License-Identifier: MIT
//! Format: a fresh, empty volume over the medium in a drive, given a name.
//! Built against the SDK only.
//!
//!   Format DRIVE=DEVICE/K/A,NAME/K/A,FAT32/S,EXFAT/S,POSFS/S,QUICK/S,BLOCKSIZE/K/N
//!
//!   Format DRIVE SD0: NAME Photos
//!   Format DRIVE SD0: NAME Photos EXFAT
//!   Format DRIVE DH1: NAME Work POSFS
//!   Format DRIVE SD0: NAME Films BLOCKSIZE 65536
//!
//! DRIVE is the drive's device, with or without its colon; NAME the new
//! volume's, without one: one to 30 characters, none of them `:` or `/`.
//! The file system may hold less - a FAT32 label is eleven characters,
//! kept in upper case - and refuses a name it cannot hold before it writes
//! anything.
//!
//! The format is the drive's own: the file system its node was mounted
//! with, in the form its DosType names. A FAT drive (`MSD`, `MSH`) writes
//! FAT32 up to 32 GiB and exFAT past that, unless the DosType's last byte
//! names one; FAT32 and EXFAT choose for this format, and only on a FAT
//! drive. A posfs drive (`POS\0`, `POS\1`) writes posfs. POSFS says that
//! posfs is meant: on a drive mounted for another file system it writes
//! nothing and says how the drive is given posfs - a format never changes
//! the handler a drive was mounted with. QUICK is accepted and changes
//! nothing: every format here writes the volume's structures over the
//! medium as it is, without erasing or reading it back.
//!
//! BLOCKSIZE is the new volume's unit of allocation in bytes, a power of
//! two (FormatTags's FORMAT_BlockSize): posfs's block, FAT's cluster.
//! Without it the file system chooses by the partition and the medium's
//! size. A size the file system or the medium cannot have is refused
//! before anything is written.
//!
//! It asks before it does anything:
//!
//!   Insert disk to be formatted in device SD0:
//!   Press RETURN to begin formatting or CTRL-C to abort:
//!
//! The answer is read from Input(), so a script may give it a blank line.
//! Then the drive is inhibited, formatted, and let go (dos.library's
//! Inhibit and Format), and Format waits until the drive has its new
//! volume. A drive with a file open for writing is not touched. The
//! return code is 0 for a volume made, 5 for one stopped at the question,
//! 20 for one that could not be made, with the reason said.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const fat = dos.fat;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Format";
const VERSION_STRING = "\x00$VER: Format 1.3 (18.10.2026)\r\n";

const template = "DRIVE=DEVICE/K/A,NAME/K/A,FAT32/S,EXFAT/S,POSFS/S,QUICK/S,BLOCKSIZE/K/N";
const arg_device = 0;
const arg_name = 1;
const arg_fat32 = 2;
const arg_exfat = 3;
const arg_posfs = 4;
const arg_block_size = 6;
const arg_count = 7;

const MSG_INSERT = "Insert disk to be formatted in device %s\n";
const MSG_PRESS = "Press RETURN to begin formatting or CTRL-C to abort: ";
const MSG_NOTFS = "%s is not a file system\n";
const MSG_NOTFAT = "FAT32 and EXFAT are for a FAT drive, which %s is not\n";
const MSG_NOTPOSFS =
    "%s is not mounted for posfs. Its DosType says which file system a drive\n" ++
    "gets: on the flash, RDB CHANGE <drive> DOSTYPE POS and a reboot; for a card,\n" ++
    "DosType = 0x504F5301 in DEVS:<drive>, then Assign <drive>: DISMOUNT and\n" ++
    "Mount <drive>:\n";
const MSG_INITING = "Initializing disk...\n";
const MSG_DONE = "Format complete.\n";

/// The most a device name may be: 30, the colon and the NUL.
const max_device = dos.MAX_DEVICE_NAME + 2;

/// How long the new volume is waited for after the drive is let go, in
/// ticks between two looks and in looks.
const settle_ticks = 15;
const settle_tries = 100;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const asked = rdargs.string(argv[arg_device]).?;
    const label = rdargs.string(argv[arg_name]).?;
    if (!dos.volumename.valid(label[0..lengthOf(label)])) {
        _ = dl.PrintFault(dos.ERROR_INVALID_COMPONENT_NAME, COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    var switches: u32 = 0;
    for ([_]usize{ arg_fat32, arg_exfat, arg_posfs }) |index| {
        if (argv[index] != 0) switches += 1;
    }
    if (switches > 1) {
        _ = dl.PrintFault(dos.ERROR_TOO_MANY_ARGS, COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    const block_size = rdargs.number(argv[arg_block_size]) orelse 0;
    if (block_size < 0) {
        _ = dl.PrintFault(dos.ERROR_BAD_NUMBER, COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = dos.FORMAT_BlockSize, .data = @intCast(block_size) },
        .{ .tag = sdk.utility.TAG_DONE, .data = 0 },
    };

    // "SD0" and "SD0:" both name the device; the colon is what dos's
    // calls want, and what the messages read best with.
    var device: [max_device:0]u8 = @splat(0);
    var at: usize = 0;
    while (asked[at] != 0 and asked[at] != ':' and at + 2 < device.len) : (at += 1) {
        device[at] = asked[at];
    }
    if (at == 0 or asked[at] == ':' and asked[at + 1] != 0) {
        _ = dl.PrintFault(dos.ERROR_INVALID_COMPONENT_NAME, asked);
        return dos.RETURN_FAIL;
    }
    device[at] = ':';
    const name: [*:0]const u8 = @ptrCast(&device);

    const dp = dl.GetDeviceProc(name, null) orelse return fail(dl, dl.IoErr());
    defer dl.FreeDeviceProc(dp);
    // A device it must be: once inhibited, a drive may have no volume to
    // be let go by.
    const node = dp.dev_node orelse return fail(dl, dos.ERROR_DEVICE_NOT_MOUNTED);
    if (node.type != .device) return fail(dl, dos.ERROR_DEVICE_NOT_MOUNTED);
    const port = dp.port orelse return fail(dl, dos.ERROR_DEVICE_NOT_MOUNTED);
    if (!dl.IsFileSystem(name)) {
        _ = Printf(dl, MSG_NOTFS, .{name});
        return dos.RETURN_FAIL;
    }

    // The node's own DosType is what the drive holds; a switch only
    // chooses the FAT format in it.
    var dos_type: u32 = 0;
    if (argv[arg_fat32] != 0 or argv[arg_exfat] != 0) {
        const own = dosTypeOf(node);
        if (!fat.isFatType(own)) {
            _ = Printf(dl, MSG_NOTFAT, .{name});
            return dos.RETURN_FAIL;
        }
        dos_type = fat.typeWithFormat(own, if (argv[arg_fat32] != 0) fat.FORMAT_FAT32 else fat.FORMAT_EXFAT);
    }
    if (argv[arg_posfs] != 0 and !dos.posfs.isPosfsType(dosTypeOf(node))) {
        _ = Printf(dl, MSG_NOTPOSFS, .{name});
        return dos.RETURN_FAIL;
    }

    // What can be told before the question is told then.
    var info: dos.InfoData = .{};
    if (dl.DoPkt(port, @intFromEnum(dos.ActionCode.disk_info), @bitCast(@intFromPtr(&info)), 0, 0, 0, 0) != dos.DOSFALSE) {
        if (info.disk_type == dos.ID_NO_DISK_PRESENT) return fail(dl, dos.ERROR_NO_DISK);
        if (info.disk_type == dos.ID_BUSY_DISK) return fail(dl, dos.ERROR_OBJECT_IN_USE);
        if (info.disk_state == dos.ID_WRITE_PROTECTED) return fail(dl, dos.ERROR_DISK_WRITE_PROTECTED);
    }

    _ = Printf(dl, MSG_INSERT, .{name});
    if (!confirm(dl)) {
        _ = dl.PrintFault(dos.ERROR_BREAK, null);
        return dos.RETURN_WARN;
    }

    if (!dl.Inhibit(name, true)) return fail(dl, dl.IoErr());
    _ = dl.PutStr(MSG_INITING);
    const made = dl.FormatTags(name, label, dos_type, &tags);
    const code = dl.IoErr();
    _ = dl.Inhibit(name, false);
    if (!made) return fail(dl, code);
    if (!settled(dl, port)) return fail(dl, dos.ERROR_NOT_A_DOS_DISK);
    _ = dl.PutStr(MSG_DONE);
    return dos.RETURN_OK;
}

/// The reason said, and the return code for a format not made.
fn fail(dl: *DosBase, code: i32) i32 {
    _ = dl.PrintFault(code, COMMAND_NAME);
    return dos.RETURN_FAIL;
}

fn lengthOf(text: [*:0]const u8) usize {
    var count: usize = 0;
    while (text[count] != 0) count += 1;
    return count;
}

/// The device node's de_DosType, or 0 when it was mounted without an
/// environment.
fn dosTypeOf(node: *dos.DosList) u32 {
    const startup: ?*const dos.FileSysStartupMsg = @ptrFromInt(node.misc.handler.startup);
    const msg = startup orelse return 0;
    const environ = msg.environ orelse return 0;
    return environ.dos_type;
}

/// Whether the drive shows a volume again once let go: it reads the
/// medium when the last inhibit is taken back, and a file system may then
/// still be checking what it found.
fn settled(dl: *DosBase, port: *exec.MsgPort) bool {
    var tries: u32 = 0;
    while (tries < settle_tries) : (tries += 1) {
        var info: dos.InfoData = .{};
        if (dl.DoPkt(port, @intFromEnum(dos.ActionCode.disk_info), @bitCast(@intFromPtr(&info)), 0, 0, 0, 0) != dos.DOSFALSE and
            info.disk_state != dos.ID_VALIDATING and readable(info.disk_type)) return true;
        dl.Delay(settle_ticks);
    }
    return false;
}

/// Whether an id_DiskType names a volume a file system reads.
fn readable(disk_type: u32) bool {
    return switch (disk_type) {
        dos.ID_NO_DISK_PRESENT, dos.ID_UNREADABLE_DISK, dos.ID_NOT_REALLY_DOS, dos.ID_BUSY_DISK => false,
        else => true,
    };
}

/// RETURN, or Ctrl-C. A line is read rather than a character so that a
/// script can answer with a blank one.
fn confirm(dl: *DosBase) bool {
    _ = dl.PutStr(MSG_PRESS);
    _ = dl.Flush(dl.Output());
    while (true) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) return false;
        const c = dl.FGetC(dl.Input());
        if (c < 0) return false; // end of input, or a broken stream
        if (c == '\n') return true;
    }
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
