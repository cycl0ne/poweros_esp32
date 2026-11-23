// SPDX-License-Identifier: MIT
//! OpenHID: a function for a keyboard or a mouse, by its report
//! descriptor.

const sdk = @import("sdk");
const exec = sdk.exec;
const hid = sdk.hid;
const utility = sdk.utility;
const kb = sdk.devices.keyboard;
const mouse_device = sdk.devices.mouse;
const HIDBase = @import("../hid_base.zig").HIDBase;
const layout = @import("../report/layout.zig");
const _function = @import("_function.zig");
const Function = _function.Function;

/// Makes a function for a device by its report descriptor: the sources
/// of what the descriptor describes opened, for its reports to be handed
/// to with HIDInput.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenHID(base: *HIDBase, descriptor: ?[*]const u8, length: u32,
///     tags: ?[*]const utility.TagItem) ?*hid.HIDFunction
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `descriptor`, `length` - the device's report descriptor, as it gives
///   it; null for a device that has none.
/// - `tags` - HIDA_Boot, a boot interface's kind (HIDBOOT_KEYBOARD,
///   HIDBOOT_MOUSE); HIDA_OutputHook, the hook an output report goes to;
///   HIDA_ReplyPort, the port the sources' requests reply to.
///
/// RESULT:
/// The function; its `flags` say what it drives - HIDF_KEYBOARD,
/// HIDF_MOUSE, HIDF_TABLET - and HIDF_BOOT where it reads the boot
/// protocol's report. Null where the descriptor describes nothing the
/// library drives, a source does not open, or there is no memory.
///
/// BEHAVIOR:
/// The descriptor's first keyboard collection and its first mouse
/// collection are read: where each report keeps its keys - as bits, as
/// slots of usages - its buttons, its move or its place, and its wheel,
/// and a keyboard's LEDs' output report. A keyboard makes the function a
/// source of keyboard.device, a mouse or a tablet one of mouse.device,
/// and a descriptor with both both, its reports told apart by their IDs.
/// With HIDA_Boot, where the descriptor does not describe that kind, the
/// function reads the boot protocol's report of it and nothing else, and
/// says so with HIDF_BOOT: the driver then puts the device in the boot
/// protocol. The sources' requests reply to HIDA_ReplyPort, or to a port
/// the function makes for the task that calls OpenHID.
///
/// CONTEXT:
/// - Waits: yes, while the sources open.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The function is the library's until CloseHID; the descriptor stays the
/// caller's and is not kept. The hook and the port must outlast the
/// function.
///
/// NOTES:
/// HIDInput and CloseHID are called on the task the reply port belongs to:
/// HIDA_ReplyPort's, or that of the task that called OpenHID. A driver
/// that opens its functions on one task and reads its devices on another
/// names a port of the second.
///
/// BUGS:
/// A collection past the first keyboard and the first mouse - a consumer
/// control's keys, a second mouse - is not read.
///
/// SEE ALSO:
/// `HIDInput`, `CloseHID`
///
/// EXAMPLES:
/// ```zig
/// const tags = [_]utility.TagItem{
///     .{ .tag = hid.HIDA_ReplyPort, .data = @intFromPtr(port) },
///     .{ .tag = hid.HIDA_OutputHook, .data = @intFromPtr(&output_hook) },
///     .{ .tag = utility.TAG_DONE, .data = 0 },
/// };
/// const function = hb.OpenHID(descriptor.ptr, @intCast(descriptor.len), &tags) orelse return false;
/// ```
pub fn OpenHID(base: *HIDBase, descriptor: ?[*]const u8, length: u32, tags: ?[*]const utility.TagItem) ?*hid.HIDFunction {
    const sys = base.sys_base;
    const ub = base.utility;
    const boot: u32 = @truncate(ub.GetTagData(hid.HIDA_Boot, 0, tags));
    const hook: ?*utility.Hook = @ptrFromInt(ub.GetTagData(hid.HIDA_OutputHook, 0, tags));
    const reply: ?*exec.MsgPort = @ptrFromInt(ub.GetTagData(hid.HIDA_ReplyPort, 0, tags));
    const bytes: []const u8 = if (descriptor) |given| given[0..length] else &.{};

    var keyboard = layout.keyboardLayout(bytes);
    var mouse = layout.mouseLayout(bytes);
    var flags: u32 = 0;
    // A boot interface's kind read by its descriptor, or else by the boot
    // protocol's report alone.
    if (boot == hid.HIDBOOT_KEYBOARD and keyboard == null) {
        keyboard = layout.boot_keyboard;
        mouse = null;
        flags = hid.HIDF_BOOT;
    } else if (boot == hid.HIDBOOT_MOUSE and mouse == null) {
        mouse = layout.boot_mouse;
        keyboard = null;
        flags = hid.HIDF_BOOT;
    }
    if (keyboard == null and mouse == null) return null;

    const memory = sys.AllocMem(@sizeOf(Function), exec.MEMF_CLEAR) orelse return null;
    const function: *Function = @ptrCast(@alignCast(memory));
    function.output = hook;
    function.port = reply;
    if (reply == null) {
        function.port = sys.CreateMsgPort() orelse {
            _function.release(base, function);
            return null;
        };
        function.own_port = true;
    }
    if (keyboard) |found| {
        function.keyboard = found;
        flags |= hid.HIDF_KEYBOARD;
        if (!_function.openSource(sys, &function.keyboard_source, kb.KEYBOARDNAME, kb.KBDF_SOURCE, function.port.?)) {
            _function.release(base, function);
            return null;
        }
    }
    if (mouse) |found| {
        function.mouse = found;
        flags |= if (found.absolute) hid.HIDF_TABLET else hid.HIDF_MOUSE;
        if (!_function.openSource(sys, &function.mouse_source, mouse_device.MOUSENAME, mouse_device.MOUSEF_SOURCE, function.port.?)) {
            _function.release(base, function);
            return null;
        }
    }
    function.public.flags = flags;
    return &function.public;
}
