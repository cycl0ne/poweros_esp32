// SPDX-License-Identifier: MIT
//! StartUSB: a bus started - its process, its controller, its root hub.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const usb = sdk.usb;
const st = sdk.expansion.systemtags;
const UsbBase = @import("../usb_base.zig").UsbBase;
const _bus = @import("_bus.zig");
const Bus = _bus.Bus;

/// The process's stack, and its priority: above dos's processes, so a
/// keyboard plugged in is set up while a program computes.
const stack_bytes = 8192;
const process_pri = 5;

/// Starts a bus: its controller opened, its root hub set up, and from
/// then on whatever is plugged in.
///
/// SYNOPSIS:
/// ```zig
/// fn StartUSB(base: *UsbBase, bus: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `bus` - which bus, from 0: the board's USB sockets that may be a
///   host (`PARTKIND_USB`, `USBROLE_HOST`), in the order its parts list
///   them, and after them the xHCI controllers on PCI, in the order
///   xhci.device numbers them.
///
/// RESULT:
/// 0 when the bus runs (or already did); `USBERR_NOBUS` if there is no
/// such bus, `USBERR_CONTROLLER` if its controller could not be opened,
/// `USBERR_NOMEM` without memory or a process.
///
/// There is no highest bus number: a machine has as many buses as it has
/// controllers. `USBERR_NOBUS` is what a walk from 0 up stops on.
///
/// BEHAVIOR:
/// A process of the bus's own opens the controller and sets up its root
/// hub; this returns once the controller is open, without waiting for
/// what is plugged in to be set up - a device found later is set up as
/// it comes either way, and a program that waits for one uses
/// AddUSBNotify. A bus that runs is left as it is. The library stays
/// open while a bus runs.
///
/// CONTEXT:
/// - Waits: yes, until the bus's process has opened the controller.
/// - Interrupts: no.
/// - Locks: takes the library's bus lock; none may be held.
/// - Process: a Task will do; the bus's own process is a dos process.
///
/// OWNERSHIP:
/// The bus is the library's until StopUSB.
///
/// NOTES:
/// A bus is a controller. The board's `PARTKIND_USB` parts that may be
/// hosts are the first of them, each on the device that drives its chip
/// (`CHIP_DWC2`: usbotg.device; `CHIP_XHCI`, `CHIP_DWC3`: xhci.device) -
/// those are described because nothing can find a controller that is
/// part of a chip. Every number past them is an xHCI controller on PCI,
/// which is found instead: the sockets of a machine of that kind are in
/// groups with a controller each, and how many there are is the
/// machine's answer. A bus that is not started leaves its sockets dark,
/// since a hub's ports are given their power when their bus starts.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StopUSB`, `ObtainUSBDeviceList`, `AddUSBNotify`
///
/// EXAMPLES:
/// ```zig
/// if (ub.StartUSB(0) != 0) return fail("no USB bus");
/// ```
pub fn StartUSB(base: *UsbBase, bus: u32) i32 {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.bus_lock);
    defer sys.ReleaseSemaphore(&base.bus_lock);
    if (_bus.busOf(base, bus) != null) return 0;
    if (!openHelpers(base)) return usb.USBERR_NOMEM;
    const controller = findController(base, bus) orelse return usb.USBERR_NOBUS;

    // The bus's record is the library's, kept in its base until StopUSB:
    // the system's, not the task's that started it.
    const memory = sys.AllocMem(@sizeOf(Bus), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return usb.USBERR_NOMEM;
    const record: *Bus = @ptrCast(@alignCast(memory));
    record.* = .{ .usb_base = base, .number = bus, .hc_name = controller.name, .hc_unit = controller.unit };
    const signal = sys.AllocSignal(-1);
    if (signal < 0) {
        sys.FreeMem(memory, @sizeOf(Bus));
        return usb.USBERR_NOMEM;
    }
    defer sys.FreeSignal(signal);
    record.waiter = sys.FindTask(null);
    record.waiter_signal = signal;
    holdLibrary(base, 1);
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&_bus.busProcess) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr("usb.library bus") },
        .{ .tag = dos.NP_StackSize, .data = stack_bytes },
        .{ .tag = dos.NP_Priority, .data = process_pri },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(record) },
        .{ .tag = dos.NP_HoldLibrary, .data = @intFromPtr(&base.lib) },
        .{},
    };
    if (base.dos.?.CreateNewProc(&tags) == null) {
        holdLibrary(base, -1);
        sys.FreeMem(memory, @sizeOf(Bus));
        return usb.USBERR_NOMEM;
    }
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    if (record.result != 0) {
        const result = record.result;
        sys.FreeMem(memory, @sizeOf(Bus));
        // A controller that is not there is not a bus. The board's own
        // parts are counted, so a number past them is a controller the
        // bus was looked for on PCI and did not find: the answer that
        // says there are no more buses, which is what a walk from 0 up
        // stops on.
        if (controller.found and result == usb.USBERR_CONTROLLER) return usb.USBERR_NOBUS;
        return result;
    }
    record.next = @ptrCast(@alignCast(base.bus_list));
    base.bus_list = record;
    return 0;
}

/// The library's open count changed by `by` under its own lock, as
/// OpenLibrary and CloseLibrary change it: the count a bus's process
/// holds, which dos gives back when the process ends (NP_HoldLibrary).
fn holdLibrary(base: *UsbBase, by: i32) void {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.lib.lock);
    defer sys.ReleaseSemaphore(&base.lib.lock);
    if (by > 0) base.lib.open_cnt += 1 else base.lib.open_cnt -= 1;
}

/// dos.library and utility.library, opened once.
fn openHelpers(base: *UsbBase) bool {
    const sys = base.sys_base;
    if (base.dos == null) base.dos = @ptrCast(sys.OpenLibrary(dos.DOSNAME, 0) orelse return false);
    if (base.utility == null) base.utility = @ptrCast(sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return false);
    return true;
}

const Controller = struct {
    name: [*:0]const u8,
    unit: u32,
    /// Whether it was found rather than described: a controller on PCI,
    /// which may simply not be there.
    found: bool = false,
};

/// Bus `bus`'s controller: the board's `bus`th USB part that may be a
/// host, on the device that drives its chip; none for a chip no device
/// here drives, though it keeps its number.
///
/// **Past the board's parts the buses are the xHCI controllers on PCI**,
/// in the order xhci.device numbers them - which is the order
/// pci.library found them, after any controller the board described. A
/// machine of that kind says nothing about them: the sockets of a PC are
/// in groups with a controller each, and how many there are is the
/// machine's to answer, not a list's. Whether bus `bus` is one of them
/// is answered by opening it.
fn findController(base: *UsbBase, bus: u32) ?Controller {
    const sys = base.sys_base;
    const ub = base.utility.?;
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return null;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    var count: u32 = 0;
    var part = eb.FindBoardPart(null, st.PARTKIND_USB, st.CHIP_ANY);
    while (part) |it| : (part = eb.FindBoardPart(it, st.PARTKIND_USB, st.CHIP_ANY)) {
        if (ub.GetTagData(st.PART_UsbRoles, st.USBROLE_HOST, it.tags) & st.USBROLE_HOST == 0) continue;
        if (count == bus) {
            const name: [*:0]const u8 = switch (ub.GetTagData(st.PART_Chip, st.CHIP_NONE, it.tags)) {
                st.CHIP_DWC2 => "usbotg.device",
                st.CHIP_XHCI, st.CHIP_DWC3 => "xhci.device",
                else => return null,
            };
            return .{ .name = name, .unit = @truncate(ub.GetTagData(st.PART_BusUnit, 0, it.tags)) };
        }
        count += 1;
    }
    return .{ .name = "xhci.device", .unit = bus - count, .found = true };
}
