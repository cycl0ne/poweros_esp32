// SPDX-License-Identifier: MPL-2.0
//! dos.library's ROM tag, and the init routines it names.
//!
//! dos is the last cold-start resident, and its init starts the after-DOS
//! residents with InitCode(RTF_AFTERDOS). The tag is not RTF_AUTOINIT: an
//! auto-init resident's init runs before AddLibrary, and the after-DOS
//! residents must find dos.library on the list. So `init` makes the
//! library with MakeLibrary - whose init, `initBase`, fills in the base -
//! adds it, calls InitCode, and starts the machine's first shell.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const TagItem = sdk.utility.TagItem;
const vec = exec.vec;
const dos_lvo = @import("dos_lvo.zig");
const DosBase = @import("dos_base.zig").DosBase;
const doslist = @import("doslist/_doslist.zig");
const date = @import("date/_date.zig");
const segment = @import("program/_program.zig");

/// What the library is on exec's list as, and its version.
pub const LIBRARY_NAME = sdk.dos.DOSNAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 1;
const BUILD_DATE = "15.9.2026";
const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The utility.library dos.library opens: the ROM's own.
const UTILITY_VERSION = 1;

/// The NIL: node's handler: a ROM tag, found by name when NIL: is first
/// used (src/rom/handler/nil).
pub const nil_handler_name = "nil-handler";

/// The RAM: node's handler: a ROM tag too (src/rom/handler/ram).
const ram_handler_name = "ram-handler";

/// The CON:, RAW: and AUX: nodes' handler (src/rom/handler/con). CON: and
/// RAW: are a terminal in a window, one window per Open; AUX: is the same
/// terminal on a serial port.
const con_handler_name = "con-handler";

/// A console in a window opens intuition.library and draws through it, so
/// its process wants more than the 8 KiB a handler is given by default.
const con_stack_size = 16384;

/// AUX:'s startup, which says it is a console on an exec device rather
/// than in a window. No device name: the handler asks the machine which
/// port its console is on (the USB port on the board, UART0 in the
/// emulator). A node mounted later can name serial.device and a unit here
/// instead, which is why this is the same structure a file system's node
/// carries.
const aux_startup: dos.FileSysStartupMsg = .{};

/// The PIPE: node's handler, the pipe between two processes
/// (src/rom/handler/pipe).
const pipe_handler_name = "pipe-handler";

/// The flash disk's handler (src/rom/handler/flashfs). Which nodes it gets
/// is the disk's business: doslist/'s mountDisk reads its RigidDiskBlock.
const flashfs_handler_name = doslist.FLASHFS_HANDLER;

/// The ROM's handlers, which dos's init adds as system segments from their
/// tags, so a node names its handler and the handler's code is found.
const rom_handlers = [_][*:0]const u8{ nil_handler_name, ram_handler_name, con_handler_name, pipe_handler_name, flashfs_handler_name };

/// MakeLibrary's init: the base's name, version, SysBase and
/// utility.library; the device list with the ROM's nodes (NIL:, RAM:,
/// CON:, RAW:, AUX:, PIPE:) and the flash disk's partitions, each handler
/// started on first use; timer.device, the resident segments, and the
/// system disk's assigns. Without utility.library or a node there is no
/// dos.library: null makes MakeLibrary free the base.
///
/// INPUTS:
/// - `lib` - the library MakeLibrary made, its jump table in place.
/// - `seg_list` - unused: dos is in the ROM.
/// - `sys_base` - exec, kept in the base.
///
/// RESULT:
/// `lib`, or null.
fn initBase(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const db: *DosBase = @fieldParentPtr("lib", lib);
    const dos_lib = db.iface();
    db.sys_base = sys_base;
    db.utility_base = @ptrCast(sys_base.OpenLibrary(sdk.interface.utility.NAME, UTILITY_VERSION) orelse return null);
    doslist.init(db);
    sys_base.InitSemaphore(&db.cli_lock);
    db.clis = @splat(null);
    const nil_node = dos_lib.MakeDosEntry("NIL", dos.DLT_DEVICE) orelse {
        sys_base.CloseLibrary(db.utility_base.lib());
        return null;
    };
    nil_node.misc.handler.handler = nil_handler_name;
    _ = dos_lib.AddDosEntry(nil_node);
    const ram_node = dos_lib.MakeDosEntry("RAM", dos.DLT_DEVICE) orelse {
        sys_base.CloseLibrary(db.utility_base.lib());
        return null;
    };
    ram_node.misc.handler.handler = ram_handler_name;
    ram_node.misc.handler.priority = 10; // above the programs it serves
    _ = dos_lib.AddDosEntry(ram_node);
    for ([_][*:0]const u8{ "CON", "RAW" }, 0..) |name, raw| {
        const node = dos_lib.MakeDosEntry(name, dos.DLT_DEVICE) orelse {
            sys_base.CloseLibrary(db.utility_base.lib());
            return null;
        };
        node.misc.handler.handler = con_handler_name;
        node.misc.handler.startup = raw; // dp_Arg2: 0 a window, 1 a raw one
        node.misc.handler.stack_size = con_stack_size;
        _ = dos_lib.AddDosEntry(node);
    }
    // The same handler on a serial port: the console of a machine whose
    // display is not up, or is not wanted.
    if (dos_lib.MakeDosEntry("AUX", dos.DLT_DEVICE)) |aux_node| {
        aux_node.misc.handler.handler = con_handler_name;
        aux_node.misc.handler.startup = @intFromPtr(&aux_startup);
        _ = dos_lib.AddDosEntry(aux_node);
    }
    const pipe_node = dos_lib.MakeDosEntry("PIPE", dos.DLT_DEVICE) orelse {
        sys_base.CloseLibrary(db.utility_base.lib());
        return null;
    };
    pipe_node.misc.handler.handler = pipe_handler_name;
    _ = dos_lib.AddDosEntry(pipe_node);
    // The disk's partitions, from its own RigidDiskBlock: nothing here
    // knows how big the chip is or what the partitions are called.
    const disk = doslist.mountDisk(db, sys_base);
    date.openTimer(db);
    segment.initSegments(db);
    for (rom_handlers) |name| {
        const tag = sys_base.FindResident(name) orelse continue;
        if (tag.type != .handler) continue;
        const rh: *const exec.ResidentHandler = @fieldParentPtr("resident", tag);
        _ = dos_lib.AddSegment(name, &dos.SegCode{ .entry = rh.handler }, dos.CMD_SYSTEM);
    }
    // The shell (src/rom/shell), under the three names programs ask for
    // it by.
    if (sys_base.FindResident("shell")) |tag| {
        if (tag.type == .shell) {
            const rh: *const exec.ResidentHandler = @fieldParentPtr("resident", tag);
            for ([_][*:0]const u8{ "shell", "BootShell", "CLI" }) |name| {
                _ = dos_lib.AddSegment(name, &dos.SegCode{ .entry = rh.handler }, dos.CMD_SYSTEM);
            }
        }
    }
    // ENV: and T: are not here: where global variables live and where work
    // files go is policy, and policy belongs in S:Startup-Sequence, which
    // makes the directories and assigns them. Until it has run there is no
    // ENV: and no T:, and a global variable or a work file fails to
    // resolve - which is the honest answer on a machine that has not
    // finished starting.
    // The boot partition is the system disk, with the usual directories on it:
    // the bootable one with the highest de_BootPri. Late,
    // as everything else here is, so the disk is only looked at when
    // something is wanted from it: an empty or unformatted one costs
    // nothing and the shell still runs.
    if (disk.boot) |boot| {
        var path: [dos.MAX_DEVICE_NAME + 2:0]u8 = @splat(0);
        const name = boot[0..db.utility_base.Strlen(boot)];
        if (name.len <= dos.MAX_DEVICE_NAME) {
            @memcpy(path[0..name.len], name);
            path[name.len] = ':';
            _ = dos_lib.AssignLate("SYS", &path);
            for ([_][2][*:0]const u8{
                .{ "C", "SYS:c" },
                .{ "S", "SYS:s" },
                .{ "LIBS", "SYS:libs" },
                .{ "DEVS", "SYS:devs" },
                // What a device is, for Mount to read.
                .{ "HANDLERS", "SYS:handlers" },
            }) |pair| _ = dos_lib.AssignLate(pair[0], pair[1]);
        }
    }
    lib.node.name = LIBRARY_NAME;
    lib.version = LIBRARY_VERSION;
    lib.revision = LIBRARY_REVISION;
    lib.id_string = LIBRARY_VERSION_STRING[1..];
    return lib;
}

/// The console the machine comes up on, and the script its first shell
/// reads: a window that covers the display, and the script that sets the
/// machine up once. No close gadget - the machine's own shell is not a
/// thing to be able to put away by accident.
const boot_console: [*:0]const u8 = "CON:///-1/PowerOS Shell";
const boot_script: [*:0]const u8 = "S:Startup-Sequence";

/// The machine's first shell, on the display. dos starts it at the end of
/// its own init, where the machine has everything it needs: the disk is
/// mounted, the library is on the list, and the after-DOS residents (which
/// is where libraries and devices from the disk come in) have run.
///
/// It runs on: dos's init cannot wait for a shell that is meant to last
/// until the machine is switched off, so this is asynchronous and what
/// comes back is the CLI's number. A machine with no display opens no
/// window and gets no shell here, and says so - it still has its debug
/// shell on the serial line, whose `newshell` opens one anywhere.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `sys_base` - exec, for the message when there is no shell.
fn startBootShell(db: *DosBase, sys_base: *ExecBase) void {
    const dos_lib = db.iface();
    const script = dos_lib.Open(boot_script, dos.MODE_OLDFILE);
    const dir = dos_lib.Lock("SYS:", dos.SHARED_LOCK) orelse dos_lib.Lock("RAM:", dos.SHARED_LOCK);
    const tags = [_]TagItem{
        .{ .tag = dos.SYS_Window, .data = @intFromPtr(boot_console) },
        .{ .tag = dos.SYS_Asynch, .data = 1 },
        .{ .tag = dos.SYS_UserShell, .data = 1 },
        .{ .tag = dos.SYS_ScriptFile, .data = @intFromPtr(script) },
        .{ .tag = dos.NP_CurrentDir, .data = @intFromPtr(dir) },
        .{},
    };
    const number = dos_lib.SystemTagList(null, &tags);
    if (number >= 0) return;
    const code = dos_lib.IoErr();
    if (script) |fh| _ = dos_lib.Close(fh);
    dos_lib.UnLock(dir);
    sdk.exec.kprintf(sys_base, "dos.library: no shell on %s (error %d)\n", .{ boot_console, code });
}

/// The resident's init: the library on the list, the after-DOS residents,
/// then the machine's own shell.
///
/// INPUTS:
/// - `seg_list` - handed on to MakeLibrary.
/// - `sys_base` - exec.
///
/// RESULT:
/// The library, or null when it could not be made.
fn init(seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*anyopaque {
    const lib = sys_base.MakeLibrary(&dos_lvo.vectors, dos_lvo.vectors.len, @sizeOf(DosBase), &initBase, seg_list) orelse return null;
    sys_base.AddLibrary(lib);
    sdk.exec.kprintf(sys_base, "%s %d.%d: starting the after-DOS residents\n", .{ lib.name(), lib.version, lib.revision });
    _ = sys_base.InitCode(exec.RTF_AFTERDOS, 0);
    startBootShell(@fieldParentPtr("lib", lib), sys_base);
    return lib;
}

/// The ROM tag: a cold-start library, the last one at cold start, whose
/// `init` makes and adds the library itself.
pub export const dos_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &dos_library_tag,
    .flags = exec.RTF_COLDSTART,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = -128, // the last one at cold start
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = vec(init),
};
