// SPDX-License-Identifier: MIT
//! OpenHID: a function for a keyboard, a mouse or a consumer control's
//! media keys, by its report descriptor.

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
/// HIDF_MOUSE, HIDF_TABLET, HIDF_CONSUMER - and HIDF_BOOT where it reads
/// the boot protocol's report. Null where the descriptor describes
/// nothing the library drives, a source does not open, or there is no
/// memory.
///
/// BEHAVIOR:
/// The descriptor's keyboard collections - up to four, each in a report
/// of its own, the keys held in any of them held - its first mouse
/// collection and its first consumer control are read: where each
/// report keeps its keys - as bits, as slots of usages - its buttons, its
/// move or its place, and its wheel, a keyboard's LEDs' output report,
/// and where a consumer control's report keeps its media keys - play,
/// pause, stop, previous, next, rewind, fast forward, mute, the volume
/// down and up. A keyboard or a consumer control makes the function a
/// source of keyboard.device - a consumer control alone one of media keys
/// alone (KBDF_MEDIA), no keyboard - a mouse or a tablet one of
/// mouse.device, and a descriptor with several all of them, its reports
/// told apart by their IDs; a consumer control whose reports cannot be
/// told from the keyboard's or the mouse's is passed over. With
/// HIDA_Boot, where the descriptor does not describe that kind, the
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
/// A collection past the first four keyboards, the first mouse and the
/// first consumer control - a second mouse, a system control's power and sleep
/// keys - is not read.
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

    var keyboards: [layout.KEYBOARDS_MOST]layout.KeyboardLayout = undefined;
    var keyboard_count = layout.keyboardLayouts(bytes, &keyboards);
    var keyboard: ?layout.KeyboardLayout = if (keyboard_count > 0) keyboards[0] else null;
    var mouse = layout.mouseLayout(bytes);
    var consumer = layout.consumerLayout(bytes);
    var flags: u32 = 0;
    // A boot interface's kind read by its descriptor, or else by the boot
    // protocol's report alone.
    if (boot == hid.HIDBOOT_KEYBOARD and keyboard == null) {
        keyboard = layout.boot_keyboard;
        keyboards[0] = layout.boot_keyboard;
        keyboard_count = 1;
        mouse = null;
        consumer = null;
        flags = hid.HIDF_BOOT;
    } else if (boot == hid.HIDBOOT_MOUSE and mouse == null) {
        mouse = layout.boot_mouse;
        keyboard = null;
        keyboard_count = 0;
        consumer = null;
        flags = hid.HIDF_BOOT;
    }
    // A report is one collection's: media keys in a report the keyboard
    // or the mouse reads too would be read twice.
    if (consumer) |found| {
        if (keyboard != null) {
            for (keyboards[0..keyboard_count]) |other| {
                if (other.report_id == found.report_id) consumer = null;
            }
        }
        if (mouse) |other| {
            if (other.report_id == found.report_id) consumer = null;
        }
    }
    if (keyboard == null and mouse == null and consumer == null) return null;

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
        for (keyboards[1..keyboard_count], 0..) |more, index| function.more_keyboards[index] = more;
        function.more_count = @intCast(keyboard_count -| 1);
        flags |= hid.HIDF_KEYBOARD;
    }
    if (consumer) |found| {
        function.consumer = found;
        flags |= hid.HIDF_CONSUMER;
    }
    if (keyboard != null or consumer != null) {
        // Media keys alone - a remote control - are no keyboard: the one
        // on the screen still comes up for a board with nothing else.
        const as_what = kb.KBDF_SOURCE | (if (keyboard == null) kb.KBDF_MEDIA else 0);
        if (!_function.openSource(sys, &function.keyboard_source, kb.KEYBOARDNAME, as_what, function.port.?)) {
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
