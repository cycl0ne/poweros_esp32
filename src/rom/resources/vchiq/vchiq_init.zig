// SPDX-License-Identifier: MPL-2.0
//! vchiq.resource's ROM tag, and the init routine it names: the board's
//! VCHIQ found - its doorbells, their interrupt, the memory the kernel
//! kept for it - and the firmware's mailbox. The queue is not started
//! until a service is opened.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const st = sdk.expansion.systemtags;
const videocore = sdk.hardware.videocore;
const ExecBase = sdk.interface.exec.ExecBase;
const vchiq_lvo = @import("vchiq_lvo.zig");
const base = @import("vchiq_base.zig");
const VchiqBase = base.VchiqBase;

/// The name it is opened by. The SDK's.
pub const RESOURCE_NAME = sdk.resources.vchiq.VCHIQNAME;
pub const RESOURCE_VERSION = 1;
pub const RESOURCE_REVISION = 0;
const BUILD_DATE = "17.11.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn vchiqBase(lib: *exec.Library) *VchiqBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

/// ResInit: the locks, and the board's VCHIQ and firmware parts. A board
/// without them, or without the memory, has a resource whose services
/// never open (VCHIQERR_NO_FIRMWARE).
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no; it runs on the exec task at cold start.
/// - Locks: none needed. - Process: a Task will do.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const vb = vchiqBase(lib);
    lib.revision = RESOURCE_REVISION;
    vb.sys_base = sys_base;
    vb.state = base.STATE_DEAD;
    vb.regs = 0;
    vb.irq = 0;
    vb.mailbox = 0;
    vb.memory = 0;
    vb.bus = 0;
    vb.memory_bytes = 0;
    sys_base.InitSemaphore(&vb.start_lock);
    sys_base.InitSemaphore(&vb.tx_lock);
    sys_base.InitSemaphore(&vb.list_lock);
    vb.task = null;
    vb.hooked = false;
    vb.rung = .{};
    vb.space = .{};
    vb.connected = .{};
    vb.tx_pos = 0;
    vb.rx_pos = 0;
    vb.paused = false;
    vb.pagelists = 0;
    vb.fragments = 0;
    vb.services = @splat(null);
    if (find(vb, sys_base)) vb.state = base.STATE_ASLEEP;
    return lib;
}

/// The board's VCHIQ part and its firmware's, into `vb`: false when
/// either is missing, or the kernel kept no memory for it.
fn find(vb: *VchiqBase, sys: *ExecBase) bool {
    const utility_lib = sys.OpenLibrary(sdk.utility.UTILITYNAME, 0) orelse return false;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return false;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_FIRMWARE, st.CHIP_BCM2711_VCHIQ) orelse return false;
    const firmware = eb.FindBoardPart(null, st.PARTKIND_FIRMWARE, st.CHIP_RPI_FIRMWARE) orelse return false;
    vb.regs = ub.GetTagData(st.PART_Address, 0, part.tags);
    vb.irq = @intCast(ub.GetTagData(st.PART_Irq, 0, part.tags));
    vb.mailbox = ub.GetTagData(st.PART_Address, 0, firmware.tags);
    const shared: ?*const st.SharedMemory = @ptrFromInt(ub.GetTagData(st.PART_SharedMemory, 0, part.tags));
    if (shared) |memory| {
        vb.memory = memory.base;
        vb.memory_bytes = if (memory.base != 0) memory.bytes else 0;
    }
    if (vb.regs == 0 or vb.irq == 0 or vb.mailbox == 0) return false;
    if (vb.memory == 0) {
        exec.kprintf(sys, "%s: the kernel kept no memory for the queue\n", .{RESOURCE_NAME});
        return false;
    }
    vb.bus = videocore.busAddress(vb.mailbox, vb.memory);
    return true;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(VchiqBase),
    .vectors = &vchiq_lvo.vectors,
    .vector_count = vchiq_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 60: after expansion.library (102), which has the
/// board's parts.
pub export const vchiq_resource_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &vchiq_resource_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = 60,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..],
    .init = &init_table,
};
