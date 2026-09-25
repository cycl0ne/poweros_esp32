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
const string = @import("../string/string.zig");
const text = @import("../text/text.zig");
const slider = @import("../slider/slider.zig");
const scroller = @import("../scroller/scroller.zig");
const listview = @import("../listview/listview.zig");
const palette = @import("../palette/palette.zig");
const colorwheel = @import("../colorwheel/colorwheel.zig");
const cw = sdk.gadgets.colorwheel;
const pa = sdk.gadgets.palette;
const sr = sdk.gadgets.scroller;
const lv = sdk.gadgets.listview;
const st = sdk.gadgets.string;
const tx = sdk.gadgets.text;
const sl = sdk.gadgets.slider;
const pg = intuition.propgclass;

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

/// A key pressed, as the keyboard sends it.
fn key(code: u16) ie.InputEvent {
    return .{ .class = ie.IECLASS_RAWKEY, .code = code };
}

test "string.gadget: a line in a ridge, and a number field that takes digits only" {
    var heard = Heard{ .tag = gc.STRINGA_LongVal, .ib = undefined };
    var rig = try Rig.up(&string.Library.resident_tag, &heard);
    const ib = rig.ib;

    // Text: set and read through strgclass's own attributes.
    const line = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        .{ .tag = gc.STRINGA_MaxChars, .data = 32 },
        .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr("PowerOS") },
        .{},
    }).?;
    const said: [*:0]const u8 = @ptrFromInt(attr(ib, line, gc.STRINGA_TextVal));
    try testing.expectEqualStrings("PowerOS", std.mem.span(said));
    _ = ib.SetAttrsTagList(line, &[_]TagItem{ .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr("Amiga") }, .{} });
    try testing.expectEqualStrings("Amiga", std.mem.span(@as([*:0]const u8, @ptrFromInt(attr(ib, line, gc.STRINGA_TextVal)))));
    // A line of the font high inside its ridge, taller than the line alone.
    try testing.expect(attr(ib, line, gc.GA_Height) > 12);
    ib.DisposeObject(line);

    // A number field.
    const number = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 9 },
        .{ .tag = gc.STRINGA_MaxChars, .data = 16 },
        .{ .tag = gc.STRINGA_LongVal, .data = 0 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    _ = ib.SetAttrsTagList(number, &[_]TagItem{ .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr("") }, .{} });
    var termination: i32 = -1;
    var down = input(gc.GM_GOACTIVE, &press, 20, 5, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(number, @ptrCast(&down)));
    // "4", "a", "2": the letter is turned away. (Keys that are the same
    // on every keymap.)
    for ([_]u16{ 0x04, 0x20, 0x02 }) |code| {
        const e = key(code);
        var typed = input(gc.GM_HANDLEINPUT, &e, 20, 5, &termination);
        try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(number, @ptrCast(&typed)));
    }
    try testing.expectEqualStrings("42", std.mem.span(@as([*:0]const u8, @ptrFromInt(attr(ib, number, gc.STRINGA_TextVal)))));
    try testing.expectEqual(@as(isize, 42), @as(isize, @bitCast(attr(ib, number, gc.STRINGA_LongVal))));
    // The target heard the number, in the field's own name.
    try testing.expectEqual(@as(?usize, 42), heard.value);
    try testing.expectEqual(@as(?usize, 9), heard.id);
    // Return ends it, the way that counts.
    const enter = key(0x44);
    var done = input(gc.GM_HANDLEINPUT, &enter, 20, 5, &termination);
    try testing.expect(ib.SendMessage(number, @ptrCast(&done)) & gc.GMR_VERIFY != 0);

    ib.DisposeObject(number);
    try rig.down();
}

test "text.gadget: a text or a number through its format, never pressed" {
    var heard = Heard{ .tag = tx.TEXT_Number, .ib = undefined };
    var rig = try Rig.up(&text.Library.resident_tag, &heard);
    const ib = rig.ib;

    // Copied: the caller's text may change after.
    var mine = [_:0]u8{ 'R', 'e', 'a', 'd', 'y' };
    const status = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&mine) },
        .{ .tag = tx.TEXT_CopyText, .data = 1 },
        .{ .tag = tx.TEXT_Border, .data = 1 },
        .{},
    }).?;
    mine[0] = 'X';
    try testing.expectEqualStrings("Ready", std.mem.span(@as([*:0]const u8, @ptrFromInt(attr(ib, status, tx.TEXT_Text)))));
    _ = ib.SetAttrsTagList(status, &[_]TagItem{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr("Busy") }, .{} });
    try testing.expectEqualStrings("Busy", std.mem.span(@as([*:0]const u8, @ptrFromInt(attr(ib, status, tx.TEXT_Text)))));
    _ = ib.SetAttrsTagList(status, &[_]TagItem{ .{ .tag = tx.TEXT_Number, .data = @bitCast(@as(isize, -7)) }, .{} });
    try testing.expectEqual(@as(isize, -7), @as(isize, @bitCast(attr(ib, status, tx.TEXT_Number))));

    // Never pressed.
    var hit = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = 1, .y = 1 } };
    try testing.expectEqual(@as(usize, 0), ib.SendMessage(status, @ptrCast(&hit)));
    ib.DisposeObject(status);

    // A number through a format: %ld takes all of it, %d its low half.
    var into: [32]u8 = undefined;
    const sys = kexec.SysBase.iface();
    try testing.expectEqualStrings("42 files", std.mem.span(sdk.gadgets.support.formatNumber(sys, "%ld files", 42, &into)));
    try testing.expectEqualStrings("-3", std.mem.span(sdk.gadgets.support.formatNumber(sys, "%d", -3, &into)));
    // Cut to fit, never past the end.
    var small: [4]u8 = undefined;
    try testing.expectEqualStrings("123", std.mem.span(sdk.gadgets.support.formatNumber(sys, "%ld", 123456, &small)));
    try rig.down();
}

fn doubled(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = hook;
    _ = object;
    const level: *const i32 = @ptrCast(@alignCast(message.?));
    return @bitCast(@as(isize, level.* * 2));
}

test "slider.gadget: levels spread over the pot, the knob on its level, and the level shown" {
    var heard = Heard{ .tag = sl.SLIDER_Level, .ib = undefined };
    var rig = try Rig.up(&slider.Library.resident_tag, &heard);
    const ib = rig.ib;

    // Every level is the pot it puts the knob at, and the ends are the
    // pot's ends: across, the smallest at the left; up and down, at the
    // bottom.
    var across = slider.Data{ .min = -5, .max = 5 };
    try testing.expectEqual(@as(u32, 0), slider.potFor(&across, -5));
    try testing.expectEqual(pg.MAXPOT, slider.potFor(&across, 5));
    var up = slider.Data{ .min = -5, .max = 5, .vertical = 1 };
    try testing.expectEqual(pg.MAXPOT, slider.potFor(&up, -5));
    try testing.expectEqual(@as(u32, 0), slider.potFor(&up, 5));
    var level: i32 = -5;
    while (level <= 5) : (level += 1) {
        try testing.expectEqual(level, slider.levelAt(&across, slider.potFor(&across, level)));
        try testing.expectEqual(level, slider.levelAt(&up, slider.potFor(&up, level)));
    }
    // A pot between two levels is the nearer one.
    try testing.expectEqual(@as(i32, 0), slider.levelAt(&across, pg.MAXPOT / 2 + 100));

    // The wrong way round is swapped, and past the end is the end.
    const knob = ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 4 },
        .{ .tag = sl.SLIDER_Min, .data = 15 },
        .{ .tag = sl.SLIDER_Max, .data = 0 },
        .{ .tag = sl.SLIDER_Level, .data = 99 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 0), attr(ib, knob, sl.SLIDER_Min));
    try testing.expectEqual(@as(usize, 15), attr(ib, knob, sl.SLIDER_Max));
    try testing.expectEqual(@as(usize, 15), attr(ib, knob, sl.SLIDER_Level));
    _ = ib.SetAttrsTagList(knob, &[_]TagItem{ .{ .tag = sl.SLIDER_Level, .data = 0 }, .{} });

    // A press beside the knob, at the right: one level that way, reported
    // and told.
    var termination: i32 = -1;
    const width: i32 = @intCast(attr(ib, knob, gc.GA_Width));
    var beside = input(gc.GM_GOACTIVE, &press, width - 6, 5, &termination);
    try testing.expect(ib.SendMessage(knob, @ptrCast(&beside)) & gc.GMR_VERIFY != 0);
    try testing.expectEqual(@as(i32, 1), termination);
    try testing.expectEqual(@as(usize, 1), attr(ib, knob, sl.SLIDER_Level));
    try testing.expectEqual(@as(?usize, 1), heard.value);
    try testing.expectEqual(@as(?usize, 4), heard.id);

    // Dragged to the far end and let go: the last level.
    _ = ib.SetAttrsTagList(knob, &[_]TagItem{ .{ .tag = sl.SLIDER_Level, .data = 0 }, .{} });
    var grab = input(gc.GM_GOACTIVE, &press, 6, 5, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(knob, @ptrCast(&grab)));
    const moving = ie.InputEvent{ .class = ie.IECLASS_NEWPOINTERPOS, .code = ie.IECODE_NOBUTTON };
    var drag = input(gc.GM_HANDLEINPUT, &moving, width + 40, 5, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(knob, @ptrCast(&drag)));
    try testing.expectEqual(@as(?usize, 15), heard.value);
    var let_go = input(gc.GM_HANDLEINPUT, &release, width + 40, 5, &termination);
    try testing.expect(ib.SendMessage(knob, @ptrCast(&let_go)) & gc.GMR_VERIFY != 0);
    try testing.expectEqual(@as(i32, 15), termination);
    ib.DisposeObject(knob);

    // The level shown through its format, and through a hook first.
    var hook = utility.Hook{ .entry = &doubled };
    const shown = ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
        .{ .tag = sl.SLIDER_Level, .data = 6 },
        .{ .tag = sl.SLIDER_LevelFormat, .data = @intFromPtr("%ld%%") },
        .{ .tag = sl.SLIDER_MaxLevelLen, .data = 4 },
        .{ .tag = sl.SLIDER_DispFunc, .data = @intFromPtr(&hook) },
        .{},
    }).?;
    const own = classes.instData(slider.Data, classes.objectClass(shown), shown);
    try testing.expectEqualStrings("12%", std.mem.span(slider.levelText(sdk.gadgets.baseOf(classes.objectClass(shown)), own, shown)));
    ib.DisposeObject(shown);
    try rig.down();
}

const timer_tick = ie.InputEvent{ .class = ie.IECLASS_TIMER };

test "scroller.gadget: the top kept in the view, arrows that step and repeat, pages" {
    var heard = Heard{ .tag = sr.SCROLLER_Top, .ib = undefined };
    var rig = try Rig.up(&scroller.Library.resident_tag, &heard);
    const ib = rig.ib;

    const bar = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 6 },
        .{ .tag = sr.SCROLLER_Total, .data = 200 },
        .{ .tag = sr.SCROLLER_Visible, .data = 20 },
        .{ .tag = sr.SCROLLER_Top, .data = 500 },
        .{ .tag = sr.SCROLLER_Arrows, .data = 12 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    // Past the last full view is the last full view.
    try testing.expectEqual(@as(usize, 180), attr(ib, bar, sr.SCROLLER_Top));
    _ = ib.SetAttrsTagList(bar, &[_]TagItem{ .{ .tag = sr.SCROLLER_Top, .data = 0 }, .{} });
    // Across, 100 of bar and two arrows of 12 at the right, 16 thick.
    try testing.expectEqual(@as(usize, 124), attr(ib, bar, gc.GA_Width));
    try testing.expectEqual(@as(usize, 16), attr(ib, bar, gc.GA_Height));

    // The forward arrow: a step at the press, none for three ticks, then
    // one at each.
    var termination: i32 = -1;
    var down = input(gc.GM_GOACTIVE, &press, 118, 8, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(bar, @ptrCast(&down)));
    try testing.expectEqual(@as(usize, 1), attr(ib, bar, sr.SCROLLER_Top));
    try testing.expectEqual(@as(?usize, 1), heard.value);
    try testing.expectEqual(@as(?usize, 6), heard.id);
    var tick = input(gc.GM_HANDLEINPUT, &timer_tick, 118, 8, &termination);
    for (0..3) |_| _ = ib.SendMessage(bar, @ptrCast(&tick));
    try testing.expectEqual(@as(usize, 1), attr(ib, bar, sr.SCROLLER_Top));
    _ = ib.SendMessage(bar, @ptrCast(&tick));
    _ = ib.SendMessage(bar, @ptrCast(&tick));
    try testing.expectEqual(@as(usize, 3), attr(ib, bar, sr.SCROLLER_Top));
    // Off the arrow it holds still.
    var off = input(gc.GM_HANDLEINPUT, &timer_tick, 40, 8, &termination);
    _ = ib.SendMessage(bar, @ptrCast(&off));
    try testing.expectEqual(@as(usize, 3), attr(ib, bar, sr.SCROLLER_Top));
    // Let go: the top is the code.
    var up = input(gc.GM_HANDLEINPUT, &release, 118, 8, &termination);
    try testing.expect(ib.SendMessage(bar, @ptrCast(&up)) & gc.GMR_VERIFY != 0);
    try testing.expectEqual(@as(i32, 3), termination);

    // The back arrow at the start does nothing.
    _ = ib.SetAttrsTagList(bar, &[_]TagItem{ .{ .tag = sr.SCROLLER_Top, .data = 0 }, .{} });
    var back = input(gc.GM_GOACTIVE, &press, 106, 8, &termination);
    _ = ib.SendMessage(bar, @ptrCast(&back));
    try testing.expectEqual(@as(usize, 0), attr(ib, bar, sr.SCROLLER_Top));
    var back_up = input(gc.GM_HANDLEINPUT, &release, 106, 8, &termination);
    _ = ib.SendMessage(bar, @ptrCast(&back_up));

    // A press in the bar beside the knob: a page, one line kept.
    var page = input(gc.GM_GOACTIVE, &press, 90, 8, &termination);
    try testing.expect(ib.SendMessage(bar, @ptrCast(&page)) & gc.GMR_VERIFY != 0);
    const paged = attr(ib, bar, sr.SCROLLER_Top);
    try testing.expectEqual(@as(usize, 19), paged);
    try testing.expectEqual(@as(i32, 19), termination);
    try testing.expectEqual(@as(?usize, 19), heard.value);

    ib.DisposeObject(bar);
    try rig.down();
}

/// ramlib's part in opening a class library by its path, which the host
/// tests do without: exec is asked for the name's tail.
const ByTail = struct {
    var old: ?*const anyopaque = null;

    fn open(sys: *sdk.interface.exec.ExecBase, name: [*:0]const u8, version: u32) callconv(.c) ?*exec.Library {
        var tail = name;
        var i: usize = 0;
        while (name[i] != 0) : (i += 1) {
            if (name[i] == '/' or name[i] == ':') tail = name + i + 1;
        }
        const exec_open: *const fn (*sdk.interface.exec.ExecBase, [*:0]const u8, u32) callconv(.c) ?*exec.Library = @ptrCast(@alignCast(old.?));
        return exec_open(sys, tail, version);
    }

    fn install() void {
        const sys = kexec.SysBase.iface();
        old = sys.SetFunction(@ptrCast(@alignCast(sys)), sdk.interface.exec.LVO.OpenLibrary, @ptrCast(&open));
    }

    fn remove() void {
        const sys = kexec.SysBase.iface();
        _ = sys.SetFunction(@ptrCast(@alignCast(sys)), sdk.interface.exec.LVO.OpenLibrary, old.?);
    }
};

/// Hides line 3 of the test's list from selection.
fn thirdDisabled(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = hook;
    _ = object;
    const msg: *const lv.LVDrawMsg = @ptrCast(@alignCast(message.?));
    if (msg.method_id == lv.LV_ISDISABLED and msg.line == 3) return lv.LVCB_DISABLED;
    return lv.LVCB_UNKNOWN;
}

test "listview.gadget: top and selection, the view kept full, detach, disabled lines" {
    var heard = Heard{ .tag = lv.LISTVIEW_Selected, .ib = undefined };
    const kib = try host_rom.intuition.setUp();
    ByTail.install();
    // The scroller's library first, which the list view's opens.
    const scroller_lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &scroller.Library.resident_tag, null).?));
    const ib = kib.iface();
    heard.ib = ib;
    const lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &listview.Library.resident_tag, null).?));
    const listener_class = ib.MakeClass(null, classusr.ROOTCLASS, null, 0).?;
    listener_class.dispatcher.entry = &listen;
    listener_class.user_data = @intFromPtr(&heard);
    const listener = ib.NewObjectTagList(listener_class, null, null).?;

    // Twenty lines.
    var names: [20][8:0]u8 = undefined;
    var nodes: [20]exec.Node = undefined;
    var list: exec.List = .{};
    list.init(.unknown);
    for (&nodes, &names, 0..) |*node, *name, i| {
        name.* = @splat(0);
        name[0] = 'L';
        name[1] = '0' + @as(u8, @intCast(i / 10));
        name[2] = '0' + @as(u8, @intCast(i % 10));
        node.* = .{ .name = name };
        kexec.SysBase.iface().AddTail(&list, node);
    }

    var hook = utility.Hook{ .entry = &thirdDisabled };
    const view = ib.NewObjectTagList(null, lv.LISTVIEW_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 5 },
        .{ .tag = gc.GA_Width, .data = 150 },
        .{ .tag = gc.GA_Height, .data = 60 },
        .{ .tag = lv.LISTVIEW_ItemHeight, .data = 10 },
        .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&list) },
        .{ .tag = lv.LISTVIEW_ShowSelected, .data = 1 },
        .{ .tag = lv.LISTVIEW_CallBack, .data = @intFromPtr(&hook) },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(listener) },
        .{},
    }).?;
    const cl = classes.objectClass(view);
    const own = classes.instData(listview.Data, cl, view);
    const parts = listview.partsOf(sdk.gadgets.baseOf(cl), own, view, null);
    const visible = parts.visible;
    try testing.expect(visible >= 4);
    try testing.expectEqual(lv.LISTVIEW_NONE, @as(u32, @truncate(attr(ib, view, lv.LISTVIEW_Selected))));

    // The view is kept full: past the end is the last full view.
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Top, .data = 99 }, .{} });
    try testing.expectEqual(@as(usize, 20 - visible), attr(ib, view, lv.LISTVIEW_Top));
    // The scroller follows.
    try testing.expectEqual(@as(usize, 20 - visible), attr(ib, own.scroller.?, sr.SCROLLER_Top));
    // Made visible, moving as little as it can.
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = lv.LISTVIEW_MakeVisible, .data = 2 }, .{} });
    try testing.expectEqual(@as(usize, 2), attr(ib, view, lv.LISTVIEW_Top));
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = lv.LISTVIEW_MakeVisible, .data = 12 }, .{} });
    try testing.expectEqual(@as(usize, 12 - visible + 1), attr(ib, view, lv.LISTVIEW_Top));
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Top, .data = 0 }, .{} });

    // A press on the second line shown selects it; let go, it is the code.
    var termination: i32 = -1;
    const second_y = parts.lines.top + parts.line_height + 2;
    var down = input(gc.GM_GOACTIVE, &press, 10, second_y, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(view, @ptrCast(&down)));
    try testing.expectEqual(@as(usize, 1), attr(ib, view, lv.LISTVIEW_Selected));
    // Dragged down a line, the selection follows.
    const moving = ie.InputEvent{ .class = ie.IECLASS_NEWPOINTERPOS, .code = ie.IECODE_NOBUTTON };
    var drag = input(gc.GM_HANDLEINPUT, &moving, 10, second_y + parts.line_height, &termination);
    _ = ib.SendMessage(view, @ptrCast(&drag));
    try testing.expectEqual(@as(usize, 2), attr(ib, view, lv.LISTVIEW_Selected));
    // Below the list, a line more at each tick.
    const below_y = parts.lines.top + @as(i32, @intCast(visible)) * parts.line_height + 3;
    var tick = input(gc.GM_HANDLEINPUT, &timer_tick, 10, below_y, &termination);
    _ = ib.SendMessage(view, @ptrCast(&tick));
    try testing.expectEqual(@as(usize, 1), attr(ib, view, lv.LISTVIEW_Top));
    try testing.expectEqual(@as(usize, visible), attr(ib, view, lv.LISTVIEW_Selected));
    var up = input(gc.GM_HANDLEINPUT, &release, 10, below_y, &termination);
    try testing.expect(ib.SendMessage(view, @ptrCast(&up)) & gc.GMR_VERIFY != 0);
    try testing.expectEqual(@as(i32, @intCast(visible)), termination);
    try testing.expectEqual(@as(?usize, visible), heard.value);
    try testing.expectEqual(@as(?usize, 5), heard.id);

    // Line 3 is disabled: a press on it selects nothing.
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Top, .data = 0 }, .{} });
    termination = -1;
    var on_third = input(gc.GM_GOACTIVE, &press, 10, parts.lines.top + 3 * parts.line_height + 2, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE, ib.SendMessage(view, @ptrCast(&on_third)));

    // Detached while the list changes, and given back: from the top,
    // nothing selected.
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Labels, .data = lv.LISTVIEW_DETACH }, .{} });
    try testing.expectEqual(@as(usize, 0), attr(ib, view, lv.LISTVIEW_Labels));
    var on_nothing = input(gc.GM_GOACTIVE, &press, 10, second_y, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE, ib.SendMessage(view, @ptrCast(&on_nothing)));
    kexec.SysBase.iface().Remove(&nodes[19]);
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&list) }, .{} });
    try testing.expectEqual(@as(usize, 0), attr(ib, view, lv.LISTVIEW_Top));
    try testing.expectEqual(lv.LISTVIEW_NONE, @as(u32, @truncate(attr(ib, view, lv.LISTVIEW_Selected))));
    try testing.expectEqual(@as(u32, 19), own.count);

    ib.DisposeObject(view);
    ib.DisposeObject(listener);
    try testing.expect(ib.FreeClass(listener_class));
    const sys = kexec.SysBase.iface();
    // The list view first: it has the scroller's library open.
    _ = sys.RemLibrary(lib);
    try testing.expect(ib.FindClass(lv.LISTVIEW_CLASS) == null);
    _ = sys.RemLibrary(scroller_lib);
    try testing.expect(ib.FindClass(sr.SCROLLER_CLASS) == null);
    ByTail.remove();
    try host_rom.intuition.tearDown(kib);
}

test "listview.gadget: read only, it selects nothing" {
    var heard = Heard{ .tag = lv.LISTVIEW_Selected, .ib = undefined };
    const kib = try host_rom.intuition.setUp();
    ByTail.install();
    const scroller_lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &scroller.Library.resident_tag, null).?));
    const ib = kib.iface();
    heard.ib = ib;
    const lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &listview.Library.resident_tag, null).?));

    var node = exec.Node{ .name = "only" };
    var list: exec.List = .{};
    list.init(.unknown);
    kexec.SysBase.iface().AddTail(&list, &node);
    const view = ib.NewObjectTagList(null, lv.LISTVIEW_CLASS, &[_]TagItem{
        .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&list) },
        .{ .tag = lv.LISTVIEW_ReadOnly, .data = 1 },
        .{},
    }).?;
    var termination: i32 = -1;
    var down = input(gc.GM_GOACTIVE, &press, 10, 5, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE, ib.SendMessage(view, @ptrCast(&down)));
    try testing.expectEqual(lv.LISTVIEW_NONE, @as(u32, @truncate(attr(ib, view, lv.LISTVIEW_Selected))));

    ib.DisposeObject(view);
    const sys = kexec.SysBase.iface();
    _ = sys.RemLibrary(lib);
    _ = sys.RemLibrary(scroller_lib);
    ByTail.remove();
    try host_rom.intuition.tearDown(kib);
}

test "palette.gadget: boxes nearest to square, a pick that follows, the right button puts it back" {
    // Eight colours in a wide room: two rows of four; in a tall one, four
    // rows of two; in a room too small for eight, fewer.
    const wide = palette.gridFor(8, 100, 50).?;
    try testing.expectEqual(@as(u32, 4), wide.columns);
    try testing.expectEqual(@as(u32, 2), wide.rows);
    const tall = palette.gridFor(8, 50, 100).?;
    try testing.expectEqual(@as(u32, 2), tall.columns);
    try testing.expectEqual(@as(u32, 4), tall.rows);
    const cramped = palette.gridFor(8, 20, 4).?;
    try testing.expect(cramped.shown < 8);
    try testing.expect(palette.gridFor(8, 3, 3) == null);
    // A point to its box, pulled into the grid at the edges.
    const area = gc.Box{ .width = 100, .height = 50 };
    try testing.expectEqual(@as(u32, 0), palette.boxAt(wide, area, 1, 1));
    try testing.expectEqual(@as(u32, 5), palette.boxAt(wide, area, 30, 30));
    try testing.expectEqual(@as(u32, 7), palette.boxAt(wide, area, 500, 500));
    try testing.expectEqual(@as(u32, 0), palette.boxAt(wide, area, -9, -9));

    var heard = Heard{ .tag = pa.PALETTE_Color, .ib = undefined };
    var rig = try Rig.up(&palette.Library.resident_tag, &heard);
    const ib = rig.ib;
    const colours = [_]sdk.graphics.Pen{ 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF };
    const pick = ib.NewObjectTagList(null, pa.PALETTE_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 8 },
        .{ .tag = gc.GA_Width, .data = 84 },
        .{ .tag = gc.GA_Height, .data = 24 },
        .{ .tag = pa.PALETTE_ColorTable, .data = @intFromPtr(&colours) },
        .{ .tag = pa.PALETTE_NumColors, .data = colours.len },
        .{ .tag = pa.PALETTE_Color, .data = 1 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 0xFF00FF00), attr(ib, pick, pa.PALETTE_Pen));

    // Pressed on the last box, dragged to the first, let go: the first.
    var termination: i32 = -1;
    var down = input(gc.GM_GOACTIVE, &press, 80, 12, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(pick, @ptrCast(&down)));
    try testing.expectEqual(@as(usize, 3), attr(ib, pick, pa.PALETTE_Color));
    const moving = ie.InputEvent{ .class = ie.IECLASS_NEWPOINTERPOS, .code = ie.IECODE_NOBUTTON };
    var drag = input(gc.GM_HANDLEINPUT, &moving, 3, 12, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(pick, @ptrCast(&drag)));
    try testing.expectEqual(@as(usize, 0), attr(ib, pick, pa.PALETTE_Color));
    var up = input(gc.GM_HANDLEINPUT, &release, 3, 12, &termination);
    try testing.expect(ib.SendMessage(pick, @ptrCast(&up)) & gc.GMR_VERIFY != 0);
    try testing.expectEqual(@as(i32, 0), termination);
    try testing.expectEqual(@as(?usize, 0), heard.value);
    try testing.expectEqual(@as(?usize, 8), heard.id);

    // Pressed on another, then the right button: back to the first, and
    // nothing reported.
    termination = -1;
    var again = input(gc.GM_GOACTIVE, &press, 80, 12, &termination);
    _ = ib.SendMessage(pick, @ptrCast(&again));
    try testing.expectEqual(@as(usize, 3), attr(ib, pick, pa.PALETTE_Color));
    const right = ie.InputEvent{ .class = ie.IECLASS_NEWPOINTERPOS, .code = ie.IECODE_RBUTTON };
    var undo = input(gc.GM_HANDLEINPUT, &right, 80, 12, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE, ib.SendMessage(pick, @ptrCast(&undo)));
    try testing.expectEqual(@as(usize, 0), attr(ib, pick, pa.PALETTE_Color));
    try testing.expectEqual(@as(i32, -1), termination);

    ib.DisposeObject(pick);
    try rig.down();
}

test "colorwheel.gadget: the colour set and read both ways, a press picks, the right button puts back" {
    var heard = Heard{ .tag = cw.WHEEL_Hue, .ib = undefined };
    var rig = try Rig.up(&colorwheel.Library.resident_tag, &heard);
    const ib = rig.ib;

    // Set as red, green and blue: pure green is a third of the way round,
    // fully saturated and bright.
    const green = cw.ColorWheelRGB{ .red = 0, .green = 0xFFFFFFFF, .blue = 0 };
    const wheel = ib.NewObjectTagList(null, cw.WHEEL_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 11 },
        .{ .tag = gc.GA_Width, .data = 101 },
        .{ .tag = gc.GA_Height, .data = 101 },
        .{ .tag = cw.WHEEL_RGB, .data = @intFromPtr(&green) },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    const hue = attr(ib, wheel, cw.WHEEL_Hue);
    try testing.expect(@abs(@as(i64, @intCast(hue >> 16)) - 0x5555) <= 2);
    try testing.expectEqual(@as(usize, 0xFFFFFFFF), attr(ib, wheel, cw.WHEEL_Saturation));
    // GetAttr's storage is a usize's, which the structure is aligned for.
    var hsb: cw.ColorWheelHSB align(@alignOf(usize)) = .{};
    _ = ib.GetAttr(cw.WHEEL_HSB, wheel, @ptrCast(&hsb));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), hsb.brightness);
    // One component changed keeps the others: blue added is cyan.
    _ = ib.SetAttrsTagList(wheel, &[_]TagItem{ .{ .tag = cw.WHEEL_Blue, .data = 0xFFFFFFFF }, .{} });
    var rgb: cw.ColorWheelRGB align(@alignOf(usize)) = .{};
    _ = ib.GetAttr(cw.WHEEL_RGB, wheel, @ptrCast(&rgb));
    try testing.expectEqual(@as(u32, 0), rgb.red >> 24);
    try testing.expectEqual(@as(u32, 0xFF), rgb.green >> 24);
    try testing.expectEqual(@as(u32, 0xFF), rgb.blue >> 24);

    // Pressed at the top of the wheel: red, all of it, and told.
    var termination: i32 = -1;
    var down = input(gc.GM_GOACTIVE, &press, 50, 3, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(wheel, @ptrCast(&down)));
    try testing.expectEqual(@as(usize, 0), attr(ib, wheel, cw.WHEEL_Hue));
    try testing.expectEqual(@as(usize, 0xFFFFFFFF), attr(ib, wheel, cw.WHEEL_Saturation));
    try testing.expectEqual(@as(?usize, 0), heard.value);
    try testing.expectEqual(@as(?usize, 11), heard.id);
    // Dragged to the middle: no saturation.
    const moving = ie.InputEvent{ .class = ie.IECLASS_NEWPOINTERPOS, .code = ie.IECODE_NOBUTTON };
    var middle = input(gc.GM_HANDLEINPUT, &moving, 50, 50, &termination);
    _ = ib.SendMessage(wheel, @ptrCast(&middle));
    try testing.expectEqual(@as(usize, 0), attr(ib, wheel, cw.WHEEL_Saturation));
    // The right button: the colour as it was before the press.
    const right = ie.InputEvent{ .class = ie.IECLASS_NEWPOINTERPOS, .code = ie.IECODE_RBUTTON };
    var undo = input(gc.GM_HANDLEINPUT, &right, 50, 50, &termination);
    try testing.expect(ib.SendMessage(wheel, @ptrCast(&undo)) & gc.GMR_VERIFY != 0);
    try testing.expect(@abs(@as(i64, @intCast(attr(ib, wheel, cw.WHEEL_Hue) >> 16)) - 0x8000) <= 2);

    // Off the wheel is not the wheel; its middle is.
    var corner = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = 1, .y = 1 } };
    try testing.expectEqual(@as(usize, 0), ib.SendMessage(wheel, @ptrCast(&corner)));
    var centre = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = 50, .y = 50 } };
    try testing.expectEqual(gc.GMR_GADGETHIT, ib.SendMessage(wheel, @ptrCast(&centre)));

    // The library's own calls, through its jump table.
    const calls: *sdk.interface.colorwheel.ColorWheelBase = @ptrCast(rig.lib);
    var out_rgb: cw.ColorWheelRGB = .{};
    calls.ConvertHSBToRGB(&.{ .hue = 0, .saturation = 0xFFFFFFFF, .brightness = 0xFFFFFFFF }, &out_rgb);
    try testing.expectEqual(cw.ColorWheelRGB{ .red = 0xFFFFFFFF, .green = 0, .blue = 0 }, out_rgb);
    var out_hsb: cw.ColorWheelHSB = .{};
    calls.ConvertRGBToHSB(&.{ .red = 0x80008000, .green = 0x80008000, .blue = 0x80008000 }, &out_hsb);
    try testing.expectEqual(@as(u32, 0), out_hsb.saturation);
    try testing.expectEqual(@as(u32, 0x80008000), out_hsb.brightness);

    ib.DisposeObject(wheel);
    try rig.down();
}
