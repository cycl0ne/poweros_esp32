// SPDX-License-Identifier: MPL-2.0
//! MakeDosNode: a device node for a disk's partition, made by its driver
//! before dos.library is up.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ExpansionBase = @import("../expansion_base.zig").ExpansionBase;

/// What MakeDosNode allocates in one piece; the two names follow it.
const Made = extern struct {
    node: dos.DosList,
    startup: dos.FileSysStartupMsg,
    environ: dos.DosEnvec,
};

/// A file system's handler does more than RAM:'s, and answers the programs
/// it serves from above them.
const handler_stack = 16 * 1024;
const handler_pri = 5;

/// Makes a device node for a disk's partition, with what its handler is
/// started with.
///
/// SYNOPSIS:
/// ```zig
/// fn MakeDosNode(eb: *ExpansionBase, dos_name: [*:0]const u8,
///     device_name: [*:0]const u8, unit: u32, flags: u32,
///     environ: *const dos.DosEnvec) ?*dos.DosList
/// ```
///
/// SINCE: 1.1. LVO -28.
///
/// INPUTS:
/// - `dos_name` - the device's name, without the colon: `DH0`.
/// - `device_name` - the exec device its handler opens: `flash.device`.
/// - `unit` - the unit, for OpenDevice.
/// - `flags` - OpenDevice's flags.
/// - `environ` - the partition's geometry and file system parameters, as
///   its PartitionBlock holds them. Copied.
///
/// RESULT:
/// The node, or null when there is no memory.
///
/// BEHAVIOR:
/// A DLT_DEVICE node whose `startup` is a FileSysStartupMsg naming the
/// device, the unit and the flags, with a copy of `environ` as its
/// environment. The node, the message, the copy and both names are one
/// allocation, so nothing in it points outside it. The handler gets a 16
/// KiB stack and priority 5; which handler it is the caller names in
/// `misc.handler.handler` before AddBootNode.
///
/// It needs no dos.library, which is what it is for: a disk's driver
/// starts before dos does.
///
/// CONTEXT:
/// - Waits: no, but AllocVec may run the low-memory handlers.
/// - Interrupts: no.
/// - Locks: none taken; no spinlock may be held: it allocates.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until AddBootNode takes it. One AllocVec: FreeVec frees all
/// of it, and so does dos.library's FreeDosEntry.
///
/// NOTES:
/// dos.library's MakeDosEntry makes a bare node, named and nothing more;
/// this one carries what a file system's handler is started with.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddBootNode`, dos.library `MakeDosEntry`, sdk/libs/dos/filehandler.zig
///
/// EXAMPLES:
/// ```zig
/// const node = eb.MakeDosNode("DH0", "flash.device", 0, 0, &pb.environment) orelse return;
/// node.misc.handler.handler = "flashfs-handler";
/// if (!eb.AddBootNode(pb.environment.boot_pri, node)) sys.FreeVec(node);
/// ```
pub fn MakeDosNode(
    eb: *ExpansionBase,
    dos_name: [*:0]const u8,
    device_name: [*:0]const u8,
    unit: u32,
    flags: u32,
    environ: *const dos.DosEnvec,
) ?*dos.DosList {
    const ub = eb.utility_base;
    const name_len = ub.Strlen(dos_name);
    const device_len = ub.Strlen(device_name);
    const block = eb.sys_base.AllocVec(@sizeOf(Made) + name_len + 1 + device_len + 1, exec.MEMF_CLEAR) orelse return null;
    const made: *Made = @ptrCast(@alignCast(block));
    // MEMF_CLEAR leaves the NUL after each.
    const name_copy: [*]u8 = @as([*]u8, @ptrCast(block)) + @sizeOf(Made);
    @memcpy(name_copy[0..name_len], dos_name[0..name_len]);
    const device_copy = name_copy + name_len + 1;
    @memcpy(device_copy[0..device_len], device_name[0..device_len]);

    made.environ = environ.*;
    made.startup = .{
        .unit = unit,
        .device = @ptrCast(device_copy),
        .environ = &made.environ,
        .flags = flags,
    };
    made.node = .{
        .type = .device,
        .name = @ptrCast(name_copy),
        .misc = .{ .handler = .{
            .stack_size = handler_stack,
            .priority = handler_pri,
            .startup = @intFromPtr(&made.startup),
        } },
    };
    return &made.node;
}
