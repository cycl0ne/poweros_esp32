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
///   them.
///
/// RESULT:
/// 0 when the bus runs (or already did); `USBERR_NOBUS` if the board has
/// no such bus, `USBERR_CONTROLLER` if its controller could not be
/// opened, `USBERR_NOMEM` without memory or a process.
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
/// The buses are the board's `PARTKIND_USB` parts that may be hosts,
/// each on the device that drives its chip (`CHIP_DWC2`:
/// usbotg.device).
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
    if (bus >= usb.USB_MAX_BUSES) return usb.USBERR_NOBUS;
    sys.ObtainSemaphore(&base.bus_lock);
    defer sys.ReleaseSemaphore(&base.bus_lock);
    if (base.buses[bus] != null) return 0;
    if (!openHelpers(base)) return usb.USBERR_NOMEM;
    const controller = findController(base, bus) orelse return usb.USBERR_NOBUS;

    const memory = sys.AllocMem(@sizeOf(Bus), exec.MEMF_CLEAR) orelse return usb.USBERR_NOMEM;
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
        return result;
    }
    base.buses[bus] = record;
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

const Controller = struct { name: [*:0]const u8, unit: u32 };

/// Bus `bus`'s controller: the board's `bus`th USB part that may be a
/// host, on the device that drives its chip; none for a chip no device
/// here drives, though it keeps its number.
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
                else => return null,
            };
            return .{ .name = name, .unit = @truncate(ub.GetTagData(st.PART_BusUnit, 0, it.tags)) };
        }
        count += 1;
    }
    return null;
}
