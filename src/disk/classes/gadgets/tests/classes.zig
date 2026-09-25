// SPDX-License-Identifier: MIT
//! Host tests of the gadget classes on the disk: each class library made
//! from its ROM tag on the ROM's intuition.library, its objects driven
//! with the `GM_` methods as intuition drives them, and what they tell a
//! target caught by a class of the test's own.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const host_rom = @import("host_rom");
const exec = sdk.exec;
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const icc = intuition.icclass;
const ie = sdk.devices.inputevent;
const cb = sdk.gadgets.checkbox;
const cy = sdk.gadgets.cycle;
const rb = sdk.gadgets.radiobutton;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Object = classes.Object;
const TagItem = utility.TagItem;
const kexec = host_rom.exec;

const checkbox = @import("../checkbox/checkbox.zig");
const cycle = @import("../cycle/cycle.zig");
const radiobutton = @import("../radiobutton/radiobutton.zig");

/// What a target was last told: the value of the one tag it listens for,
/// and the gadget's ID.
const Heard = struct {
    tag: utility.Tag,
    value: ?usize = null,
    id: ?usize = null,
    ib: *IntuitionBase,
};

fn listen(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *classes.Class = @ptrCast(hook);
    const heard: *Heard = @ptrFromInt(cl.user_data);
    const msg: *classusr.Msg = @ptrCast(@alignCast(message.?));
    if (msg.method_id == classusr.OM_UPDATE) {
        const update: *classusr.OpUpdate = @ptrCast(@alignCast(msg));
        var i: usize = 0;
        while (update.attr_list.?[i].tag != utility.TAG_DONE) : (i += 1) {
            const item = update.attr_list.?[i];
            if (item.tag == heard.tag) heard.value = item.data;
            if (item.tag == gc.GA_ID) heard.id = item.data;
        }
        return 0;
    }
    return heard.ib.SendSuperMessage(cl, @ptrCast(object), msg);
}

/// The ROM's intuition, the class library made from its tag, and a
/// listener to be the gadgets' target.
const Rig = struct {
    kib: *host_rom.intuition.IntuitionBase,
    ib: *IntuitionBase,
    lib: *exec.Library,
    listener_class: *classes.Class,
    listener: *Object,
    heard: *Heard,

    fn up(tag: *const exec.Resident, heard: *Heard) !Rig {
        const kib = try host_rom.intuition.setUp();
        const ib = kib.iface();
        heard.ib = ib;
        const lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, tag, null) orelse return error.NoClassLibrary));
        const listener_class = ib.MakeClass(null, classusr.ROOTCLASS, null, 0) orelse return error.NoListener;
        listener_class.dispatcher.entry = &listen;
        listener_class.user_data = @intFromPtr(heard);
        const listener = ib.NewObjectTagList(listener_class, null, null) orelse return error.NoListener;
        return .{ .kib = kib, .ib = ib, .lib = lib, .listener_class = listener_class, .listener = listener, .heard = heard };
    }

    /// The class library expunged - which it refuses while its class has
    /// objects - and everything else given back.
    fn down(rig: *Rig) !void {
        rig.ib.DisposeObject(rig.listener);
        try testing.expect(rig.ib.FreeClass(rig.listener_class));
        const sys = kexec.SysBase.iface();
        _ = sys.RemLibrary(rig.lib);
        try testing.expect(rig.ib.FindClass(rig.lib.name().ptr) == null);
        try host_rom.intuition.tearDown(rig.kib);
    }
};

fn input(method: classusr.MethodID, event: *const ie.InputEvent, x: i32, y: i32, termination: *i32) gc.GpInput {
    return .{ .method_id = method, .gadget_info = null, .event = event, .termination = termination, .mouse = .{ .x = x, .y = y } };
}

const press = ie.InputEvent{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_LBUTTON };
const release = ie.InputEvent{ .class = ie.IECLASS_NEWPOINTERPOS, .code = ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX };
const shifted_release = ie.InputEvent{
    .class = ie.IECLASS_NEWPOINTERPOS,
    .code = ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX,
    .qualifier = ie.IEQUALIFIER_LSHIFT,
};

fn attr(ib: *IntuitionBase, o: *Object, tag: utility.Tag) usize {
    var value: usize = 0;
    _ = ib.GetAttr(tag, o, &value);
    return value;
}

test "checkbox.gadget: a press turns it over, let go over the box reports the state" {
    var heard = Heard{ .tag = cb.CHECKBOX_Checked, .ib = undefined };
    var rig = try Rig.up(&checkbox.Library.resident_tag, &heard);
    const ib = rig.ib;

    const box = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 5 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 0), attr(ib, box, cb.CHECKBOX_Checked));
    // Made without a size, it is its box: for the 8-row font, 26 by 11.
    try testing.expectEqual(@as(usize, 26), attr(ib, box, gc.GA_Width));
    try testing.expectEqual(@as(usize, 11), attr(ib, box, gc.GA_Height));

    // Pressed: ticked, and the target told at once.
    var termination: i32 = -1;
    var down = input(gc.GM_GOACTIVE, &press, 3, 3, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(box, @ptrCast(&down)));
    try testing.expectEqual(@as(usize, 1), attr(ib, box, cb.CHECKBOX_Checked));
    try testing.expectEqual(@as(?usize, 1), heard.value);
    try testing.expectEqual(@as(?usize, 5), heard.id);
    // Let go over it: the state is the code.
    var up = input(gc.GM_HANDLEINPUT, &release, 3, 3, &termination);
    const result = ib.SendMessage(box, @ptrCast(&up));
    try testing.expect(result & gc.GMR_VERIFY != 0);
    try testing.expectEqual(@as(i32, 1), termination);

    // Pressed again and let go off it: back to not ticked, not reported.
    termination = -1;
    _ = ib.SendMessage(box, @ptrCast(&down));
    try testing.expectEqual(@as(usize, 0), attr(ib, box, cb.CHECKBOX_Checked));
    var away = input(gc.GM_HANDLEINPUT, &release, 60, 3, &termination);
    try testing.expect(ib.SendMessage(box, @ptrCast(&away)) & gc.GMR_VERIFY == 0);
    try testing.expectEqual(@as(i32, -1), termination);

    // Set and read.
    _ = ib.SetAttrsTagList(box, &[_]TagItem{ .{ .tag = cb.CHECKBOX_Checked, .data = 1 }, .{} });
    try testing.expectEqual(@as(usize, 1), attr(ib, box, cb.CHECKBOX_Checked));

    // Given more room, only the box is pressed: at the left, in the middle
    // of the height.
    _ = ib.SetAttrsTagList(box, &[_]TagItem{ .{ .tag = gc.GA_Width, .data = 200 }, .{ .tag = gc.GA_Height, .data = 31 }, .{} });
    var on_box = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = 2, .y = 15 } };
    try testing.expectEqual(gc.GMR_GADGETHIT, ib.SendMessage(box, @ptrCast(&on_box)));
    var beside = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = 150, .y = 15 } };
    try testing.expectEqual(@as(usize, 0), ib.SendMessage(box, @ptrCast(&beside)));
    var above = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = 2, .y = 2 } };
    try testing.expectEqual(@as(usize, 0), ib.SendMessage(box, @ptrCast(&above)));

    // While it has an object, the library will not go.
    const sys = kexec.SysBase.iface();
    _ = sys.RemLibrary(rig.lib);
    try testing.expect(ib.FindClass(cb.CHECKBOX_CLASS) != null);
    ib.DisposeObject(box);
    try rig.down();
}

test "cycle.gadget: let go over it, the next choice; with Shift, the one before" {
    var heard = Heard{ .tag = cy.CYCLE_Active, .ib = undefined };
    var rig = try Rig.up(&cycle.Library.resident_tag, &heard);
    const ib = rig.ib;

    // No choices: no gadget.
    try testing.expect(ib.NewObjectTagList(null, cy.CYCLE_CLASS, &[_]TagItem{.{}}) == null);

    const labels = [_:null]?[*:0]const u8{ "Low", "Medium", "High" };
    const choice = ib.NewObjectTagList(null, cy.CYCLE_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 2 },
        .{ .tag = cy.CYCLE_Labels, .data = @intFromPtr(&labels) },
        .{ .tag = cy.CYCLE_Active, .data = 1 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 1), attr(ib, choice, cy.CYCLE_Active));

    var termination: i32 = -1;
    const Step = struct {
        fn run(i: *IntuitionBase, o: *Object, let_go: *const ie.InputEvent, t: *i32) usize {
            var down = input(gc.GM_GOACTIVE, &press, 2, 2, t);
            _ = i.SendMessage(o, @ptrCast(&down));
            var up = input(gc.GM_HANDLEINPUT, let_go, 2, 2, t);
            return i.SendMessage(o, @ptrCast(&up));
        }
    };
    // Forward, round the end.
    try testing.expect(Step.run(ib, choice, &release, &termination) & gc.GMR_VERIFY != 0);
    try testing.expectEqual(@as(i32, 2), termination);
    try testing.expectEqual(@as(?usize, 2), heard.value);
    try testing.expectEqual(@as(?usize, 2), heard.id);
    _ = Step.run(ib, choice, &release, &termination);
    try testing.expectEqual(@as(i32, 0), termination);
    // Back, round the start.
    _ = Step.run(ib, choice, &shifted_release, &termination);
    try testing.expectEqual(@as(i32, 2), termination);
    try testing.expectEqual(@as(usize, 2), attr(ib, choice, cy.CYCLE_Active));

    // Let go off it: nothing changes.
    var down = input(gc.GM_GOACTIVE, &press, 2, 2, &termination);
    _ = ib.SendMessage(choice, @ptrCast(&down));
    var away = input(gc.GM_HANDLEINPUT, &release, -5, 2, &termination);
    try testing.expect(ib.SendMessage(choice, @ptrCast(&away)) & gc.GMR_VERIFY == 0);
    try testing.expectEqual(@as(usize, 2), attr(ib, choice, cy.CYCLE_Active));

    // Past the last is the last; fewer labels bring the choice with them.
    _ = ib.SetAttrsTagList(choice, &[_]TagItem{ .{ .tag = cy.CYCLE_Active, .data = 7 }, .{} });
    try testing.expectEqual(@as(usize, 2), attr(ib, choice, cy.CYCLE_Active));
    const two = [_:null]?[*:0]const u8{ "On", "Off" };
    _ = ib.SetAttrsTagList(choice, &[_]TagItem{ .{ .tag = cy.CYCLE_Labels, .data = @intFromPtr(&two) }, .{} });
    try testing.expectEqual(@as(usize, 1), attr(ib, choice, cy.CYCLE_Active));
    _ = Step.run(ib, choice, &release, &termination);
    try testing.expectEqual(@as(i32, 0), termination);

    ib.DisposeObject(choice);
    try rig.down();
}

test "radiobutton.gadget: a press on a line makes it the one, a press on the one says nothing" {
    var heard = Heard{ .tag = rb.RADIO_Active, .ib = undefined };
    var rig = try Rig.up(&radiobutton.Library.resident_tag, &heard);
    const ib = rig.ib;

    const labels = [_:null]?[*:0]const u8{ "Serial", "USB", "None" };
    const radio = ib.NewObjectTagList(null, rb.RADIO_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 3 },
        .{ .tag = rb.RADIO_Labels, .data = @intFromPtr(&labels) },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 0), attr(ib, radio, rb.RADIO_Active));
    // For the 8-row font the marks are 9 high and the lines 10 apart: three
    // lines are 29 high.
    try testing.expectEqual(@as(usize, 29), attr(ib, radio, gc.GA_Height));

    var termination: i32 = -1;
    // The third line.
    var third = input(gc.GM_GOACTIVE, &press, 3, 24, &termination);
    const result = ib.SendMessage(radio, @ptrCast(&third));
    try testing.expectEqual(gc.GMR_NOREUSE | gc.GMR_VERIFY, result);
    try testing.expectEqual(@as(i32, 2), termination);
    try testing.expectEqual(@as(usize, 2), attr(ib, radio, rb.RADIO_Active));
    try testing.expectEqual(@as(?usize, 2), heard.value);
    try testing.expectEqual(@as(?usize, 3), heard.id);
    // The same line again: nothing to report.
    termination = -1;
    try testing.expectEqual(gc.GMR_NOREUSE, ib.SendMessage(radio, @ptrCast(&third)));
    try testing.expectEqual(@as(i32, -1), termination);
    // The first line.
    var first = input(gc.GM_GOACTIVE, &press, 3, 4, &termination);
    _ = ib.SendMessage(radio, @ptrCast(&first));
    try testing.expectEqual(@as(i32, 0), termination);

    _ = ib.SetAttrsTagList(radio, &[_]TagItem{ .{ .tag = rb.RADIO_Active, .data = 9 }, .{} });
    try testing.expectEqual(@as(usize, 2), attr(ib, radio, rb.RADIO_Active));

    ib.DisposeObject(radio);
    try rig.down();
}
