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
const gradientslider = @import("../gradientslider/gradientslider.zig");
const gs = sdk.gadgets.gradientslider;
const tapedeck = @import("../tapedeck/tapedeck.zig");
const fuelgauge = @import("../fuelgauge/fuelgauge.zig");
const spinner = @import("../spinner/spinner.zig");
const spg = sdk.gadgets.spinner;
const meter = @import("../meter/meter.zig");
const mt = sdk.gadgets.meter;
const arc = @import("../arc/arc.zig");
const ar = sdk.gadgets.arc;
const roller = @import("../roller/roller.zig");
const ro = sdk.gadgets.roller;
const calendar = @import("../calendar/calendar.zig");
const ca = sdk.gadgets.calendar;
const canvas = @import("../canvas/canvas.zig");
const cv = sdk.gadgets.canvas;
const qrcode = @import("../qrcode/qrcode.zig");
const qc = sdk.gadgets.qrcode;
const barcode = @import("../barcode/barcode.zig");
const bcg = sdk.gadgets.barcode;
const angles = sdk.gadgets.angles;
const chart = @import("../chart/chart.zig");
const keyboard = @import("../keyboard/keyboard.zig");
const cr = sdk.gadgets.chart;
const integer = @import("../integer/integer.zig");
const chooser = @import("../chooser/chooser.zig");
const pageclass = @import("../page/page.zig");
const scrollgroup = @import("../scrollgroup/scrollgroup.zig");
const listbrowser = @import("../listbrowser/listbrowser.zig");
const toolbutton = @import("../toolbutton/toolbutton.zig");
const tbg = sdk.gadgets.toolbutton;
const ribbon = @import("../ribbon/ribbon.zig");
const command_image = @import("../../images/command/command.zig");
const rbn = sdk.gadgets.ribbon;
const lbr = sdk.gadgets.listbrowser;
const sgc = sdk.gadgets.scrollgroup;
const pgc = sdk.gadgets.page;
const clicktab = @import("../clicktab/clicktab.zig");
const ct = sdk.gadgets.clicktab;
const ch = sdk.gadgets.chooser;
const ig = sdk.gadgets.integer;
const fg = sdk.gadgets.fuelgauge;
const td = sdk.gadgets.tapedeck;
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
    /// How many times the tag was heard.
    times: u32 = 0,
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
            if (item.tag == heard.tag) {
                heard.value = item.data;
                heard.times += 1;
            }
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
    /// The class libraries the class opens, made before it.
    needs: [2]?*exec.Library = .{ null, null },

    fn up(tag: *const exec.Resident, heard: *Heard) !Rig {
        return upAfter(tag, heard, &.{});
    }

    /// The class libraries of `needs` made first, which the class's own
    /// opens by their paths, as ramlib takes them.
    fn upAfter(tag: *const exec.Resident, heard: *Heard, needs: []const *const exec.Resident) !Rig {
        const kib = try host_rom.intuition.setUp();
        const ib = kib.iface();
        heard.ib = ib;
        var made: [2]?*exec.Library = .{ null, null };
        if (needs.len > 0) ByTail.install();
        for (needs, 0..) |need, i| made[i] = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, need, null) orelse return error.NoClassLibrary));
        const lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, tag, null) orelse return error.NoClassLibrary));
        const listener_class = ib.MakeClass(null, classusr.ROOTCLASS, null, 0) orelse return error.NoListener;
        listener_class.dispatcher.entry = &listen;
        listener_class.user_data = @intFromPtr(heard);
        const listener = ib.NewObjectTagList(listener_class, null, null) orelse return error.NoListener;
        return .{ .kib = kib, .ib = ib, .lib = lib, .listener_class = listener_class, .listener = listener, .heard = heard, .needs = made };
    }

    /// The class library expunged - which it refuses while its class has
    /// objects - and those it needed after it, and everything else given
    /// back.
    fn down(rig: *Rig) !void {
        rig.ib.DisposeObject(rig.listener);
        try testing.expect(rig.ib.FreeClass(rig.listener_class));
        const sys = kexec.SysBase.iface();
        _ = sys.RemLibrary(rig.lib);
        try testing.expect(rig.ib.FindClass(rig.lib.name().ptr) == null);
        for (rig.needs) |maybe| if (maybe) |need| {
            _ = sys.RemLibrary(need);
            try testing.expect(rig.ib.FindClass(need.name().ptr) == null);
        };
        if (rig.needs[0] != null) ByTail.remove();
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
    // It takes text, so the on-screen keyboard comes up for it.
    try testing.expect(gc.gadget(line).flags & gc.GFLG_TYPING != 0);
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

    // Room kept for a wider text: a time as wide as "-00:00" whatever it
    // shows, and wider only for a text wider than that. Measured in a font
    // the DrawInfo names, as on a screen.
    const graphics = sdk.graphics;
    const gb = rig.kib.graphics_base;
    const font = gb.OpenFont(&.{ .name = graphics.POSPAZNAME, .y_size = 8 }).?;
    var pens: [sdk.intuition.screens.NUMDRIPENS]graphics.Pen = @splat(0);
    var dri = sdk.intuition.screens.DrawInfo{ .pens = &pens, .font = font };
    var times: [3]*Object = undefined;
    const shown = [_][*:0]const u8{ "1:05", "1:05", "-00:00" };
    for (&times, shown, 0..) |*time, words, i| time.* = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_DrawInfo, .data = @intFromPtr(&dri) },
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr(words) },
        .{ .tag = if (i == 1) tx.TEXT_RoomFor else utility.TAG_IGNORE, .data = @intFromPtr("-00:00") },
        .{},
    }).?;
    const kept = domainOf(ib, times[2], gc.GDOMAIN_NOMINAL).width;
    try testing.expect(domainOf(ib, times[0], gc.GDOMAIN_NOMINAL).width < kept);
    try testing.expectEqual(kept, domainOf(ib, times[1], gc.GDOMAIN_NOMINAL).width);
    try testing.expectEqual(kept, domainOf(ib, times[1], gc.GDOMAIN_MINIMUM).width);
    _ = ib.SetAttrsTagList(times[1], &[_]TagItem{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr("-12:34:56") }, .{} });
    try testing.expect(domainOf(ib, times[1], gc.GDOMAIN_NOMINAL).width > kept);
    for (times) |time| ib.DisposeObject(time);
    gb.CloseFont(font);

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

    // Many levels, and a knob as long as the slider is high - far longer
    // than a level: a press
    // beside it pages the pot by its length, tens of levels, and only the
    // one level the press moves it is told, never where the length took
    // it.
    const long = ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 5 },
        .{ .tag = sl.SLIDER_Max, .data = 200 },
        .{ .tag = sl.SLIDER_Level, .data = 30 },
        .{ .tag = gc.GA_Width, .data = 120 },
        .{ .tag = gc.GA_Height, .data = 16 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    const long_width: i32 = @intCast(attr(ib, long, gc.GA_Width));
    for ([_]struct { x: i32, level: usize }{ .{ .x = 4, .level = 29 }, .{ .x = long_width - 6, .level = 30 } }) |press_at| {
        heard.times = 0;
        var paged = input(gc.GM_GOACTIVE, &press, press_at.x, 5, &termination);
        try testing.expect(ib.SendMessage(long, @ptrCast(&paged)) & gc.GMR_VERIFY != 0);
        try testing.expectEqual(@as(i32, @intCast(press_at.level)), termination);
        try testing.expectEqual(press_at.level, attr(ib, long, sl.SLIDER_Level));
        try testing.expectEqual(@as(?usize, press_at.level), heard.value);
        try testing.expectEqual(@as(u32, 1), heard.times);
    }
    ib.DisposeObject(long);

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

/// Hides line 4 of the test's list from selection.
fn fourthDisabled(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = hook;
    _ = object;
    const msg: *const lv.LVDrawMsg = @ptrCast(@alignCast(message.?));
    if (msg.method_id == lv.LV_ISDISABLED and msg.line == 4) return lv.LVCB_DISABLED;
    return lv.LVCB_UNKNOWN;
}

/// A press of the left button at a moment, with the Shift keys as given.
fn pressing(secs: u32, micro: u32, qualifier: u32) ie.InputEvent {
    return .{
        .class = ie.IECLASS_RAWMOUSE,
        .code = ie.IECODE_LBUTTON,
        .qualifier = qualifier,
        .time = .{ .secs = secs, .micro = micro },
    };
}

/// The pointer moved with the button held, with the Shift keys as given.
fn dragging(qualifier: u32) ie.InputEvent {
    return .{
        .class = ie.IECLASS_NEWPOINTERPOS,
        .code = ie.IECODE_NOBUTTON,
        .qualifier = qualifier,
    };
}

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

    // Detached while the list changes, and given back: nothing is
    // selected while it is away, and the same list keeps the view and
    // the selection it had, however much longer it has grown.
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Top, .data = 3 }, .{} });
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Selected, .data = 4 }, .{} });
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Labels, .data = lv.LISTVIEW_DETACH }, .{} });
    try testing.expectEqual(@as(usize, 0), attr(ib, view, lv.LISTVIEW_Labels));
    var on_nothing = input(gc.GM_GOACTIVE, &press, 10, second_y, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE, ib.SendMessage(view, @ptrCast(&on_nothing)));
    kexec.SysBase.iface().Remove(&nodes[19]);
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&list) }, .{} });
    try testing.expectEqual(@as(usize, 3), attr(ib, view, lv.LISTVIEW_Top));
    try testing.expectEqual(@as(usize, 4), attr(ib, view, lv.LISTVIEW_Selected));
    try testing.expectEqual(@as(u32, 19), own.count);

    // Another list starts at its top with nothing selected.
    var other_nodes: [3]exec.Node = undefined;
    var other: exec.List = .{};
    other.init(.unknown);
    for (&other_nodes) |*node| {
        node.* = .{ .name = "other" };
        kexec.SysBase.iface().AddTail(&other, node);
    }
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&other) }, .{} });
    try testing.expectEqual(@as(usize, 0), attr(ib, view, lv.LISTVIEW_Top));
    try testing.expectEqual(lv.LISTVIEW_NONE, @as(u32, @truncate(attr(ib, view, lv.LISTVIEW_Selected))));

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

test "listview.gadget: the selected line's name written into a string gadget" {
    const kib = try host_rom.intuition.setUp();
    ByTail.install();
    const scroller_lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &scroller.Library.resident_tag, null).?));
    const string_lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &string.Library.resident_tag, null).?));
    const ib = kib.iface();
    const lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &listview.Library.resident_tag, null).?));

    var names: [4][8:0]u8 = undefined;
    var nodes: [4]exec.Node = undefined;
    var list: exec.List = .{};
    list.init(.unknown);
    for (&nodes, &names, 0..) |*node, *name, i| {
        name.* = @splat(0);
        name[0] = 'L';
        name[1] = '0' + @as(u8, @intCast(i));
        node.* = .{ .name = name };
        kexec.SysBase.iface().AddTail(&list, node);
    }

    const field = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        .{ .tag = gc.STRINGA_MaxChars, .data = 32 },
        .{},
    }).?;
    const view = ib.NewObjectTagList(null, lv.LISTVIEW_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_Width, .data = 150 },
        .{ .tag = gc.GA_Height, .data = 80 },
        .{ .tag = lv.LISTVIEW_ItemHeight, .data = 10 },
        .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&list) },
        .{ .tag = lv.LISTVIEW_SelectString, .data = @intFromPtr(field) },
        .{},
    }).?;
    const cl = classes.objectClass(view);
    const own = classes.instData(listview.Data, cl, view);
    const parts = listview.partsOf(sdk.gadgets.baseOf(cl), own, view, null);

    const shownName = struct {
        fn of(base: *IntuitionBase, o: *Object) []const u8 {
            var at: usize = 0;
            _ = base.GetAttr(gc.STRINGA_TextVal, o, &at);
            if (at == 0) return "";
            return std.mem.span(@as([*:0]const u8, @ptrFromInt(at)));
        }
    }.of;

    // A press on the second line puts its name in the field.
    var termination: i32 = -1;
    var down = input(gc.GM_GOACTIVE, &press, 10, parts.lines.top + parts.line_height + 2, &termination);
    _ = ib.SendMessage(view, @ptrCast(&down));
    try testing.expectEqualStrings("L1", shownName(ib, field));
    var up = input(gc.GM_HANDLEINPUT, &release, 10, parts.lines.top + parts.line_height + 2, &termination);
    _ = ib.SendMessage(view, @ptrCast(&up));

    // So does naming the line.
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Selected, .data = 3 }, .{} });
    try testing.expectEqualStrings("L3", shownName(ib, field));
    // The same list again keeps what was selected; another list has
    // nothing selected, and the field goes empty with it.
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&list) }, .{} });
    try testing.expectEqualStrings("L3", shownName(ib, field));
    var other: exec.List = .{};
    other.init(.unknown);
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&other) }, .{} });
    try testing.expectEqualStrings("", shownName(ib, field));
    try testing.expectEqual(@intFromPtr(field), attr(ib, view, lv.LISTVIEW_SelectString));

    ib.DisposeObject(view);
    ib.DisposeObject(field);
    const sys = kexec.SysBase.iface();
    _ = sys.RemLibrary(lib);
    _ = sys.RemLibrary(string_lib);
    _ = sys.RemLibrary(scroller_lib);
    ByTail.remove();
    try host_rom.intuition.tearDown(kib);
}

test "checkbox and radiobutton: scaled marks fill the room they are given" {
    var termination: i32 = -1;

    // A box in a gadget 100 by 30: the mark at the left in the middle
    // without scaling, the whole box with it.
    {
        var heard = Heard{ .tag = cb.CHECKBOX_Checked, .ib = undefined };
        var rig = try Rig.up(&checkbox.Library.resident_tag, &heard);
        const ib = rig.ib;
        const plain = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_Width, .data = 100 },
            .{ .tag = gc.GA_Height, .data = 30 },
            .{},
        }).?;
        const scaled = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_Width, .data = 100 },
            .{ .tag = gc.GA_Height, .data = 30 },
            .{ .tag = cb.CHECKBOX_Scaled, .data = 1 },
            .{},
        }).?;
        var far = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = 60, .y = 3 } };
        try testing.expectEqual(@as(usize, 0), ib.SendMessage(plain, @ptrCast(&far)));
        try testing.expectEqual(gc.GMR_GADGETHIT, ib.SendMessage(scaled, @ptrCast(&far)));
        // What it says it needs is the font's size either way: a scaled
        // box takes the room it is given, it does not ask for more.
        var plain_size = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
        var scaled_size = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
        _ = ib.SendMessage(plain, @ptrCast(&plain_size));
        _ = ib.SendMessage(scaled, @ptrCast(&scaled_size));
        try testing.expectEqual(plain_size.domain.height, scaled_size.domain.height);
        ib.DisposeObject(plain);
        ib.DisposeObject(scaled);
        try rig.down();
    }

    // Two choices in a group 80 tall: the lines a font apart without
    // scaling, spread over the height with it.
    {
        var heard = Heard{ .tag = rb.RADIO_Active, .ib = undefined };
        var rig = try Rig.up(&radiobutton.Library.resident_tag, &heard);
        const ib = rig.ib;
        const labels = [_:null]?[*:0]const u8{ "Serial", "USB" };
        const tags = [_]TagItem{
            .{ .tag = gc.GA_Width, .data = 120 },
            .{ .tag = gc.GA_Height, .data = 80 },
            .{ .tag = rb.RADIO_Labels, .data = @intFromPtr(&labels) },
            .{},
        };
        const plain = ib.NewObjectTagList(null, rb.RADIO_CLASS, &tags).?;
        const scaled = ib.NewObjectTagList(null, rb.RADIO_CLASS, &[_]TagItem{
            .{ .tag = rb.RADIO_Scaled, .data = 1 },
            .{ .tag = utility.TAG_MORE, .data = @intFromPtr(&tags) },
        }).?;
        // A third of the way down: the second line in a group of two
        // font-high lines, still the first when they are spread out.
        var on_plain = input(gc.GM_GOACTIVE, &press, 10, 30, &termination);
        _ = ib.SendMessage(plain, @ptrCast(&on_plain));
        try testing.expectEqual(@as(usize, 1), attr(ib, plain, rb.RADIO_Active));
        var on_scaled = input(gc.GM_GOACTIVE, &press, 10, 30, &termination);
        _ = ib.SendMessage(scaled, @ptrCast(&on_scaled));
        try testing.expectEqual(@as(usize, 0), attr(ib, scaled, rb.RADIO_Active));
        // And the whole height is its own, which a group of two font-high
        // lines does not ask for.
        var most = gc.GpDomain{ .which = gc.GDOMAIN_MAXIMUM };
        _ = ib.SendMessage(scaled, @ptrCast(&most));
        try testing.expectEqual(gc.GDOMAIN_UNLIMITED, most.domain.height);
        ib.DisposeObject(plain);
        ib.DisposeObject(scaled);
        try rig.down();
    }
}

test "slider.gadget: the level's room in pixels as well as in characters" {
    var heard = Heard{ .tag = sl.SLIDER_Level, .ib = undefined };
    var rig = try Rig.up(&slider.Library.resident_tag, &heard);
    const ib = rig.ib;
    const shown = [_]TagItem{
        .{ .tag = sl.SLIDER_Max, .data = 64 },
        .{ .tag = sl.SLIDER_LevelFormat, .data = @intFromPtr("%ld") },
        .{ .tag = sl.SLIDER_MaxLevelLen, .data = 2 },
        .{},
    };
    const by_characters = ib.NewObjectTagList(null, sl.SLIDER_CLASS, &shown).?;
    const by_pixels = ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
        .{ .tag = sl.SLIDER_MaxLevelPixels, .data = 120 },
        .{ .tag = utility.TAG_MORE, .data = @intFromPtr(&shown) },
    }).?;
    var narrow = gc.GpDomain{ .which = gc.GDOMAIN_MINIMUM };
    var wide = gc.GpDomain{ .which = gc.GDOMAIN_MINIMUM };
    _ = ib.SendMessage(by_characters, @ptrCast(&narrow));
    _ = ib.SendMessage(by_pixels, @ptrCast(&wide));
    try testing.expect(wide.domain.width > narrow.domain.width);
    try testing.expect(wide.domain.width >= narrow.domain.width + 120);
    // The pixels are for the level: a slider that does not show one is
    // no wider for them.
    const hidden = ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
        .{ .tag = sl.SLIDER_Max, .data = 64 },
        .{ .tag = sl.SLIDER_MaxLevelPixels, .data = 120 },
        .{},
    }).?;
    const bare = ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
        .{ .tag = sl.SLIDER_Max, .data = 64 },
        .{},
    }).?;
    var none = gc.GpDomain{ .which = gc.GDOMAIN_MINIMUM };
    var plain = gc.GpDomain{ .which = gc.GDOMAIN_MINIMUM };
    _ = ib.SendMessage(hidden, @ptrCast(&none));
    _ = ib.SendMessage(bare, @ptrCast(&plain));
    try testing.expectEqual(plain.domain.width, none.domain.width);
    ib.DisposeObject(by_characters);
    ib.DisposeObject(by_pixels);
    ib.DisposeObject(hidden);
    ib.DisposeObject(bare);
    try rig.down();
}

test "scroller.gadget: an arrow's triangle sits in the middle of its button" {
    // Every button from the smallest that takes an arrow up to a large
    // one, square and oblong, upright and across.
    var width: i32 = 5;
    while (width <= 40) : (width += 1) {
        var height: i32 = 4;
        while (height <= 40) : (height += 1) {
            for ([_]bool{ true, false }) |vertical| {
                const at = gc.Box{ .left = 7, .top = 3, .width = width, .height = height };
                const triangle = sdk.gadgets.support.triangleIn(at, vertical) orelse continue;
                const across_room = if (vertical) at.width else at.height;
                const along_room = if (vertical) at.height else at.width;
                const across_left = if (vertical) at.left else at.top;
                const along_left = if (vertical) at.top else at.left;

                // The same number of pixels at each edge, both ways.
                const across_before = triangle.across_at - across_left;
                const across_after = across_room - triangle.base - across_before;
                try testing.expectEqual(across_before, across_after);
                const along_before = triangle.along_at - along_left;
                const along_after = along_room - triangle.rows - along_before;
                try testing.expectEqual(along_before, along_after);
                // And a pixel clear of the button's edge on every side.
                try testing.expect(across_before >= 1 and along_before >= 1);

                // Every row is as wide either side of the middle: what
                // it leaves at the two ends of the base is the same.
                var row: i32 = 0;
                while (row < triangle.rows) : (row += 1) {
                    const start = triangle.startAt(row);
                    const w = triangle.widthAt(row);
                    try testing.expectEqual(start - triangle.across_at, triangle.base - w - (start - triangle.across_at));
                    try testing.expect(w >= 1 and w <= triangle.base);
                }
                // The tip is the first row and the base the last.
                try testing.expectEqual(triangle.tip, triangle.widthAt(0));
                try testing.expectEqual(triangle.base, triangle.widthAt(triangle.rows - 1));
            }
        }
    }
}

/// The key that works a gadget, typed.
fn keyed(typed: u32, qualifier: u32, termination: *i32) gc.GpKey {
    return .{ .key = typed, .qualifier = qualifier, .termination = termination };
}

test "gadget classes: the key that works each one, and the Shift that turns it round" {
    var termination: i32 = -1;

    // A check box turns over, and the state is the code.
    {
        var heard = Heard{ .tag = cb.CHECKBOX_Checked, .ib = undefined };
        var rig = try Rig.up(&checkbox.Library.resident_tag, &heard);
        const ib = rig.ib;
        const box = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = 1 },
            .{ .tag = gc.GA_Key, .data = 'b' },
            .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
            .{},
        }).?;
        // A key that is not this gadget's does nothing at all.
        var other = keyed('z', 0, &termination);
        try testing.expectEqual(gc.GMKR_NOTHING, ib.SendMessage(box, @ptrCast(&other)));
        // Upper case is the same key.
        var works = keyed('B', 0, &termination);
        try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(box, @ptrCast(&works)));
        try testing.expectEqual(@as(i32, 1), termination);
        try testing.expectEqual(@as(?usize, 1), heard.value);
        try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(box, @ptrCast(&works)));
        try testing.expectEqual(@as(i32, 0), termination);
        // Disabled, it answers to nothing.
        _ = ib.SetAttrsTagList(box, &[_]TagItem{ .{ .tag = gc.GA_Disabled, .data = 1 }, .{} });
        try testing.expectEqual(gc.GMKR_NOTHING, ib.SendMessage(box, @ptrCast(&works)));
        ib.DisposeObject(box);
        try rig.down();
    }

    // A cycle gadget steps on, and back with Shift held.
    {
        var heard = Heard{ .tag = cy.CYCLE_Active, .ib = undefined };
        var rig = try Rig.up(&cycle.Library.resident_tag, &heard);
        const ib = rig.ib;
        const labels = [_:null]?[*:0]const u8{ "Low", "Medium", "High" };
        const gadget = ib.NewObjectTagList(null, cy.CYCLE_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = 2 },
            .{ .tag = gc.GA_Key, .data = 'l' },
            .{ .tag = cy.CYCLE_Labels, .data = @intFromPtr(&labels) },
            .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
            .{},
        }).?;
        var works = keyed('l', 0, &termination);
        try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(gadget, @ptrCast(&works)));
        try testing.expectEqual(@as(i32, 1), termination);
        var back = keyed('l', ie.IEQUALIFIER_LSHIFT, &termination);
        try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(gadget, @ptrCast(&back)));
        try testing.expectEqual(@as(i32, 0), termination);
        // From the first it comes round to the last.
        try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(gadget, @ptrCast(&back)));
        try testing.expectEqual(@as(i32, 2), termination);
        ib.DisposeObject(gadget);
        try rig.down();
    }

    // A radio group steps a line on, and comes round.
    {
        var heard = Heard{ .tag = rb.RADIO_Active, .ib = undefined };
        var rig = try Rig.up(&radiobutton.Library.resident_tag, &heard);
        const ib = rig.ib;
        const labels = [_:null]?[*:0]const u8{ "Serial", "USB" };
        const gadget = ib.NewObjectTagList(null, rb.RADIO_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = 3 },
            .{ .tag = gc.GA_Key, .data = 'p' },
            .{ .tag = rb.RADIO_Labels, .data = @intFromPtr(&labels) },
            .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
            .{},
        }).?;
        var works = keyed('p', 0, &termination);
        try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(gadget, @ptrCast(&works)));
        try testing.expectEqual(@as(i32, 1), termination);
        try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(gadget, @ptrCast(&works)));
        try testing.expectEqual(@as(i32, 0), termination);
        ib.DisposeObject(gadget);
        try rig.down();
    }

    // A slider moves a level, and stops at its ends.
    {
        var heard = Heard{ .tag = sl.SLIDER_Level, .ib = undefined };
        var rig = try Rig.up(&slider.Library.resident_tag, &heard);
        const ib = rig.ib;
        const gadget = ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = 4 },
            .{ .tag = gc.GA_Key, .data = 'v' },
            .{ .tag = sl.SLIDER_Min, .data = 0 },
            .{ .tag = sl.SLIDER_Max, .data = 2 },
            .{ .tag = sl.SLIDER_Level, .data = 1 },
            .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
            .{},
        }).?;
        var works = keyed('v', 0, &termination);
        try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(gadget, @ptrCast(&works)));
        try testing.expectEqual(@as(i32, 2), termination);
        // At the end it has nothing to report, and says so.
        try testing.expectEqual(gc.GMKR_DONE, ib.SendMessage(gadget, @ptrCast(&works)));
        var back = keyed('v', ie.IEQUALIFIER_RSHIFT, &termination);
        try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(gadget, @ptrCast(&back)));
        try testing.expectEqual(@as(i32, 1), termination);
        ib.DisposeObject(gadget);
        try rig.down();
    }

    // A scroller moves the view a thing at a time.
    {
        var heard = Heard{ .tag = sr.SCROLLER_Top, .ib = undefined };
        var rig = try Rig.up(&scroller.Library.resident_tag, &heard);
        const ib = rig.ib;
        const gadget = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = 5 },
            .{ .tag = gc.GA_Key, .data = 's' },
            .{ .tag = sr.SCROLLER_Total, .data = 10 },
            .{ .tag = sr.SCROLLER_Visible, .data = 4 },
            .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
            .{},
        }).?;
        var works = keyed('s', 0, &termination);
        try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(gadget, @ptrCast(&works)));
        try testing.expectEqual(@as(i32, 1), termination);
        var back = keyed('s', ie.IEQUALIFIER_LSHIFT, &termination);
        try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(gadget, @ptrCast(&back)));
        try testing.expectEqual(@as(i32, 0), termination);
        try testing.expectEqual(gc.GMKR_DONE, ib.SendMessage(gadget, @ptrCast(&back)));
        ib.DisposeObject(gadget);
        try rig.down();
    }
}

test "listview.gadget: several lines at once, a disabled line passed over, a double-click" {
    var heard = Heard{ .tag = lv.LISTVIEW_Selected, .ib = undefined };
    const kib = try host_rom.intuition.setUp();
    ByTail.install();
    const scroller_lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &scroller.Library.resident_tag, null).?));
    const ib = kib.iface();
    heard.ib = ib;
    const lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &listview.Library.resident_tag, null).?));

    var names: [12][8:0]u8 = undefined;
    var nodes: [12]exec.Node = undefined;
    var list: exec.List = .{};
    list.init(.unknown);
    for (&nodes, &names, 0..) |*node, *name, i| {
        name.* = @splat(0);
        name[0] = 'L';
        name[1] = '0' + @as(u8, @intCast(i));
        node.* = .{ .name = name };
        kexec.SysBase.iface().AddTail(&list, node);
    }

    var hook = utility.Hook{ .entry = &fourthDisabled };
    const view = ib.NewObjectTagList(null, lv.LISTVIEW_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 7 },
        .{ .tag = gc.GA_Width, .data = 150 },
        .{ .tag = gc.GA_Height, .data = 120 },
        .{ .tag = lv.LISTVIEW_ItemHeight, .data = 10 },
        .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&list) },
        .{ .tag = lv.LISTVIEW_MultiSelect, .data = 1 },
        .{ .tag = lv.LISTVIEW_CallBack, .data = @intFromPtr(&hook) },
        .{},
    }).?;
    const cl = classes.objectClass(view);
    const own = classes.instData(listview.Data, cl, view);
    const parts = listview.partsOf(sdk.gadgets.baseOf(cl), own, view, null);
    try testing.expect(parts.visible >= 8);
    // Multi-select shows what is selected without being asked to.
    try testing.expect(own.show_selected != 0);

    const chosen: *const lv.LVSelected = @ptrFromInt(attr(ib, view, lv.LISTVIEW_SelectedArray));
    try testing.expectEqual(@as(u32, 12), chosen.count);
    try testing.expectEqual(@as(u32, 0), chosen.selected());

    const y = struct {
        fn of(line: u32, p: listview.Parts) i32 {
            return p.lines.top + @as(i32, @intCast(line)) * p.line_height + 2;
        }
    }.of;
    var termination: i32 = -1;

    // A press on line 1 selects it alone; a drag without Shift moves that
    // one selection rather than adding to it.
    var down = input(gc.GM_GOACTIVE, &pressing(100, 0, 0), 10, y(1, parts), &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(view, @ptrCast(&down)));
    try testing.expect(chosen.has(1));
    var drag = input(gc.GM_HANDLEINPUT, &dragging(0), 10, y(2, parts), &termination);
    _ = ib.SendMessage(view, @ptrCast(&drag));
    try testing.expectEqual(@as(u32, 1), chosen.selected());
    try testing.expect(chosen.has(2));
    var up = input(gc.GM_HANDLEINPUT, &release, 10, y(2, parts), &termination);
    _ = ib.SendMessage(view, @ptrCast(&up));
    try testing.expectEqual(@as(i32, 2), termination);

    // A press with Shift adds line 1, and a drag with Shift carries that
    // state to line 5 - over line 4, which is disabled.
    var shift_down = input(gc.GM_GOACTIVE, &pressing(200, 0, ie.IEQUALIFIER_LSHIFT), 10, y(1, parts), &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(view, @ptrCast(&shift_down)));
    try testing.expectEqual(@as(u32, 2), chosen.selected());
    var shift_drag = input(gc.GM_HANDLEINPUT, &dragging(ie.IEQUALIFIER_LSHIFT), 10, y(5, parts), &termination);
    _ = ib.SendMessage(view, @ptrCast(&shift_drag));
    try testing.expect(chosen.has(1) and chosen.has(2) and chosen.has(3) and chosen.has(5));
    try testing.expect(!chosen.has(4));
    try testing.expectEqual(@as(u32, 4), chosen.selected());
    var shift_up = input(gc.GM_HANDLEINPUT, &release, 10, y(5, parts), &termination);
    _ = ib.SendMessage(view, @ptrCast(&shift_up));
    try testing.expectEqual(@as(i32, 5), termination);
    try testing.expectEqual(@as(usize, 5), attr(ib, view, lv.LISTVIEW_Selected));

    // A second press with Shift on a selected line takes it away again.
    var shift_off = input(gc.GM_GOACTIVE, &pressing(300, 0, ie.IEQUALIFIER_RSHIFT), 10, y(2, parts), &termination);
    _ = ib.SendMessage(view, @ptrCast(&shift_off));
    try testing.expect(!chosen.has(2));
    try testing.expectEqual(@as(u32, 3), chosen.selected());
    var off_up = input(gc.GM_HANDLEINPUT, &release, 10, y(2, parts), &termination);
    _ = ib.SendMessage(view, @ptrCast(&off_up));

    // A press without Shift is the whole selection again.
    var alone = input(gc.GM_GOACTIVE, &pressing(400, 0, 0), 10, y(6, parts), &termination);
    _ = ib.SendMessage(view, @ptrCast(&alone));
    try testing.expectEqual(@as(u32, 1), chosen.selected());
    try testing.expect(chosen.has(6));
    var alone_up = input(gc.GM_HANDLEINPUT, &release, 10, y(6, parts), &termination);
    _ = ib.SendMessage(view, @ptrCast(&alone_up));
    try testing.expectEqual(@as(i32, 6), termination);

    // The same line again, soon enough: the code carries the flag, and
    // the line is still the rest of it.
    var again = input(gc.GM_GOACTIVE, &pressing(400, 100_000, 0), 10, y(6, parts), &termination);
    _ = ib.SendMessage(view, @ptrCast(&again));
    var again_up = input(gc.GM_HANDLEINPUT, &release, 10, y(6, parts), &termination);
    _ = ib.SendMessage(view, @ptrCast(&again_up));
    try testing.expect(@as(u32, @bitCast(termination)) & lv.LISTVIEW_DOUBLE != 0);
    try testing.expectEqual(@as(u32, 6), @as(u32, @bitCast(termination)) & ~lv.LISTVIEW_DOUBLE);

    // A third press is not another double-click, and one too late is none.
    var third = input(gc.GM_GOACTIVE, &pressing(400, 150_000, 0), 10, y(6, parts), &termination);
    _ = ib.SendMessage(view, @ptrCast(&third));
    var third_up = input(gc.GM_HANDLEINPUT, &release, 10, y(6, parts), &termination);
    _ = ib.SendMessage(view, @ptrCast(&third_up));
    try testing.expectEqual(@as(i32, 6), termination);
    var late = input(gc.GM_GOACTIVE, &pressing(500, 0, 0), 10, y(6, parts), &termination);
    _ = ib.SendMessage(view, @ptrCast(&late));
    var late_up = input(gc.GM_HANDLEINPUT, &release, 10, y(6, parts), &termination);
    _ = ib.SendMessage(view, @ptrCast(&late_up));
    try testing.expectEqual(@as(i32, 6), termination);

    // The one line named clears the rest. The same list given back, one
    // line shorter, keeps what was selected and what was ticked; another
    // list clears both.
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Selected, .data = 9 }, .{} });
    try testing.expectEqual(@as(u32, 1), chosen.selected());
    try testing.expect(chosen.has(9));
    kexec.SysBase.iface().Remove(&nodes[11]);
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&list) }, .{} });
    try testing.expectEqual(@as(u32, 11), chosen.count);
    try testing.expectEqual(@as(u32, 1), chosen.selected());
    try testing.expect(chosen.has(9));

    // The key that works the list moves the selection a line on, and back
    // with Shift held.
    _ = ib.SetAttrsTagList(view, &[_]TagItem{ .{ .tag = gc.GA_Key, .data = 'i' }, .{} });
    var works = keyed('i', 0, &termination);
    try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(view, @ptrCast(&works)));
    try testing.expectEqual(@as(i32, 10), termination);
    try testing.expect(chosen.has(10) and chosen.selected() == 1);
    var up_a_line = keyed('i', ie.IEQUALIFIER_LSHIFT, &termination);
    try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(view, @ptrCast(&up_a_line)));
    try testing.expectEqual(@as(i32, 9), termination);

    ib.DisposeObject(view);
    const sys = kexec.SysBase.iface();
    _ = sys.RemLibrary(lib);
    try testing.expect(ib.FindClass(lv.LISTVIEW_CLASS) == null);
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

test "gradientslider.gadget: the knob along the gradient, skips beside it, a drag, the right button" {
    // The knob's place: 0 at the start, the largest value at the end.
    var own = gradientslider.Data{ .max = 100, .knob_pixels = 5 };
    const at_start = gradientslider.Layout.of(&own, 104, 16);
    try testing.expectEqual(@as(i32, 0), at_start.pos);
    own.current = 100;
    const at_end = gradientslider.Layout.of(&own, 104, 16);
    try testing.expectEqual(at_end.range - at_end.span, at_end.pos);
    // And back from where the pointer drags it.
    own.mouse_offset = 0;
    try testing.expectEqual(@as(i32, 0), gradientslider.valueAt(&own, at_end, -10));
    try testing.expectEqual(@as(i32, 100), gradientslider.valueAt(&own, at_end, 500));
    // The gradient: the first pen at the start, the last at the end, a
    // mix between.
    const two = [_]sdk.graphics.Pen{ 0xFF000000, 0xFFFFFFFF };
    try testing.expectEqual(@as(u32, 0xFF000000), gradientslider.shade(&two, 2, 0, 101));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), gradientslider.shade(&two, 2, 100, 101));
    const middle = gradientslider.shade(&two, 2, 50, 101);
    try testing.expect(middle & 0xFF >= 0x7F and middle & 0xFF <= 0x80);

    var heard = Heard{ .tag = gs.GRAD_CurVal, .ib = undefined };
    var rig = try Rig.up(&gradientslider.Library.resident_tag, &heard);
    const ib = rig.ib;
    const pens = [_]sdk.graphics.Pen{ 0xFFFF8000, 0xFF000000, gs.GRAD_PEN_END };
    const gradient = ib.NewObjectTagList(null, gs.GRAD_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 12 },
        .{ .tag = gc.GA_Width, .data = 104 },
        .{ .tag = gc.GA_Height, .data = 16 },
        .{ .tag = gs.GRAD_MaxVal, .data = 100 },
        .{ .tag = gs.GRAD_CurVal, .data = 50 },
        .{ .tag = gs.GRAD_SkipVal, .data = 10 },
        .{ .tag = gs.GRAD_PenArray, .data = @intFromPtr(&pens) },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 50), attr(ib, gradient, gs.GRAD_CurVal));
    // Past the end is the end.
    _ = ib.SetAttrsTagList(gradient, &[_]TagItem{ .{ .tag = gs.GRAD_CurVal, .data = 999 }, .{} });
    try testing.expectEqual(@as(usize, 100), attr(ib, gradient, gs.GRAD_CurVal));
    _ = ib.SetAttrsTagList(gradient, &[_]TagItem{ .{ .tag = gs.GRAD_CurVal, .data = 50 }, .{} });

    // Beside the knob: a skip that way, done at once, and told.
    var termination: i32 = -1;
    var before = input(gc.GM_GOACTIVE, &press, 4, 8, &termination);
    try testing.expect(ib.SendMessage(gradient, @ptrCast(&before)) & gc.GMR_VERIFY != 0);
    try testing.expectEqual(@as(usize, 40), attr(ib, gradient, gs.GRAD_CurVal));
    try testing.expectEqual(@as(?usize, 40), heard.value);
    try testing.expectEqual(@as(?usize, 12), heard.id);
    var after = input(gc.GM_GOACTIVE, &press, 100, 8, &termination);
    _ = ib.SendMessage(gradient, @ptrCast(&after));
    try testing.expectEqual(@as(usize, 50), attr(ib, gradient, gs.GRAD_CurVal));

    // On the knob: held, dragged to the end, then the right button puts
    // the value back.
    const cl = classes.objectClass(gradient);
    const inst = classes.instData(gradientslider.Data, cl, gradient);
    const knob = gradientslider.Layout.of(inst, 104, 16);
    var grab = input(gc.GM_GOACTIVE, &press, 2 + knob.pos + 2, 8, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(gradient, @ptrCast(&grab)));
    const moving = ie.InputEvent{ .class = ie.IECLASS_NEWPOINTERPOS, .code = ie.IECODE_NOBUTTON };
    var drag = input(gc.GM_HANDLEINPUT, &moving, 200, 8, &termination);
    _ = ib.SendMessage(gradient, @ptrCast(&drag));
    try testing.expectEqual(@as(usize, 100), attr(ib, gradient, gs.GRAD_CurVal));
    const right = ie.InputEvent{ .class = ie.IECLASS_NEWPOINTERPOS, .code = ie.IECODE_RBUTTON };
    var undo = input(gc.GM_HANDLEINPUT, &right, 200, 8, &termination);
    try testing.expect(ib.SendMessage(gradient, @ptrCast(&undo)) & gc.GMR_VERIFY != 0);
    try testing.expectEqual(@as(usize, 50), attr(ib, gradient, gs.GRAD_CurVal));

    // A wheel's brightness in the slider: 0xFFFF less it, set when the
    // wheel's is, and read back from the gradient into the wheel.
    const wheel_lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &colorwheel.Library.resident_tag, null).?));
    const brightness = ib.NewObjectTagList(null, gs.GRAD_CLASS, &[_]TagItem{.{}}).?;
    const wheel = ib.NewObjectTagList(null, cw.WHEEL_CLASS, &[_]TagItem{
        .{ .tag = cw.WHEEL_Brightness, .data = 0xC000C000 },
        .{ .tag = cw.WHEEL_GradientSlider, .data = @intFromPtr(brightness) },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 0x3FFF), attr(ib, brightness, gs.GRAD_CurVal));
    _ = ib.SetAttrsTagList(brightness, &[_]TagItem{ .{ .tag = gs.GRAD_CurVal, .data = 0xFFFF }, .{} });
    try testing.expectEqual(@as(usize, 0), attr(ib, wheel, cw.WHEEL_Brightness));

    ib.DisposeObject(wheel);
    ib.DisposeObject(brightness);
    _ = kexec.SysBase.iface().RemLibrary(wheel_lib);
    ib.DisposeObject(gradient);
    try rig.down();
}

test "tapedeck.gadget: a tape deck's modes and pause, the song before and after, an animation control's buttons and frames" {
    var heard = Heard{ .tag = td.TDECK_Mode, .ib = undefined };
    var rig = try Rig.up(&tapedeck.Library.resident_tag, &heard);
    const ib = rig.ib;
    var termination: i32 = -1;

    // A tape deck: five buttons, as wide as they are at its height - a
    // line of the font and the bevel, 16 at the least.
    const deck = ib.NewObjectTagList(null, td.TDECK_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 13 },
        .{ .tag = td.TDECK_Tape, .data = 1 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    const height: i32 = @intCast(attr(ib, deck, gc.GA_Height));
    try testing.expect(height >= 16);
    const tape = tapedeck.Buttons.ofTape(false, height);
    try testing.expectEqual(@as(usize, 5), tape.count);
    try testing.expectEqual(@as(usize, @intCast(tape.right)), attr(ib, deck, gc.GA_Width));
    // Play twice the height wide, rewind one and a half; stop a gap after
    // fast forward.
    try testing.expectEqual(2 * height, tape.boxes[1].width);
    try testing.expectEqual(@divTrunc(3 * height, 2), tape.boxes[0].width);
    try testing.expect(tape.boxes[3].left > tape.boxes[2].left + tape.boxes[2].width);
    try testing.expectEqual(@as(usize, td.BUT_STOP), attr(ib, deck, td.TDECK_Mode));
    // Play: the mode, done at once, and the code.
    var play = input(gc.GM_GOACTIVE, &press, 40, 7, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE | gc.GMR_VERIFY, ib.SendMessage(deck, @ptrCast(&play)));
    try testing.expectEqual(@as(i32, td.BUT_PLAY), termination);
    try testing.expectEqual(@as(?usize, td.BUT_PLAY), heard.value);
    try testing.expectEqual(@as(?usize, 13), heard.id);
    // Pause turns over, and the mode stays with the paused code added.
    var pause = input(gc.GM_GOACTIVE, &press, @intCast(tape.boxes[4].left + 4), 7, &termination);
    _ = ib.SendMessage(deck, @ptrCast(&pause));
    try testing.expectEqual(@as(i32, td.BUT_PLAY | td.TDECK_PAUSED_CODE), termination);
    try testing.expectEqual(@as(usize, 1), attr(ib, deck, td.TDECK_Paused));
    _ = ib.SendMessage(deck, @ptrCast(&pause));
    try testing.expectEqual(@as(usize, 0), attr(ib, deck, td.TDECK_Paused));
    _ = ib.SetAttrsTagList(deck, &[_]TagItem{ .{ .tag = td.TDECK_Mode, .data = td.BUT_FORWARD }, .{} });
    try testing.expectEqual(@as(usize, td.BUT_FORWARD), attr(ib, deck, td.TDECK_Mode));
    ib.DisposeObject(deck);

    // With tracks: the song before first and the song after last. A press
    // on either leaves the mode, and the code says which, paused or not.
    const tracks = ib.NewObjectTagList(null, td.TDECK_CLASS, &[_]TagItem{
        .{ .tag = td.TDECK_Tape, .data = 1 },
        .{ .tag = td.TDECK_Tracks, .data = 1 },
        .{ .tag = td.TDECK_Mode, .data = td.BUT_PLAY },
        .{},
    }).?;
    const round = tapedeck.Buttons.ofTape(true, height);
    try testing.expectEqual(@as(usize, 7), round.count);
    try testing.expectEqual(td.BUT_PREVIOUS, round.ids[0]);
    try testing.expectEqual(td.BUT_NEXT, round.ids[6]);
    try testing.expectEqual(@as(usize, @intCast(round.right)), attr(ib, tracks, gc.GA_Width));
    var before = input(gc.GM_GOACTIVE, &press, 4, 7, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE | gc.GMR_VERIFY, ib.SendMessage(tracks, @ptrCast(&before)));
    try testing.expectEqual(@as(i32, td.BUT_PREVIOUS), termination);
    try testing.expectEqual(@as(usize, td.BUT_PLAY), attr(ib, tracks, td.TDECK_Mode));
    _ = ib.SetAttrsTagList(tracks, &[_]TagItem{ .{ .tag = td.TDECK_Paused, .data = 1 }, .{} });
    var after = input(gc.GM_GOACTIVE, &press, @intCast(round.right - 4), 7, &termination);
    _ = ib.SendMessage(tracks, @ptrCast(&after));
    try testing.expectEqual(@as(i32, td.BUT_NEXT | td.TDECK_PAUSED_CODE), termination);
    try testing.expectEqual(@as(usize, td.BUT_PLAY), attr(ib, tracks, td.TDECK_Mode));
    ib.DisposeObject(tracks);

    // An animation control, 202 wide: rewind 27, play 48, fast forward 27,
    // the frames in the rest.
    const buttons = tapedeck.Buttons.of(false, false, 202, 16);
    try testing.expectEqual(@as(i32, 27), buttons.boxes[0].width);
    try testing.expectEqual(@as(i32, 48), buttons.boxes[1].width);
    try testing.expectEqual(@as(i32, 102), buttons.boxes[3].left);
    // Narrower than 80: no rewind nor fast forward.
    try testing.expectEqual(@as(i32, 0), tapedeck.Buttons.of(false, false, 70, 16).boxes[0].width);

    const anim = ib.NewObjectTagList(null, td.TDECK_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 14 },
        .{ .tag = td.TDECK_Frames, .data = 50 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    const moving = ie.InputEvent{ .class = ie.IECLASS_NEWPOINTERPOS, .code = ie.IECODE_NOBUTTON };
    // Rewind is the mode while it is held, and stops when let go.
    var rewind = input(gc.GM_GOACTIVE, &press, 10, 7, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(anim, @ptrCast(&rewind)));
    try testing.expectEqual(@as(usize, td.BUT_REWIND), attr(ib, anim, td.TDECK_Mode));
    try testing.expectEqual(@as(?usize, td.BUT_REWIND), heard.value);
    var off = input(gc.GM_HANDLEINPUT, &moving, 60, 7, &termination);
    _ = ib.SendMessage(anim, @ptrCast(&off));
    try testing.expectEqual(@as(usize, td.BUT_STOP), attr(ib, anim, td.TDECK_Mode));
    var back_on = input(gc.GM_HANDLEINPUT, &moving, 10, 7, &termination);
    _ = ib.SendMessage(anim, @ptrCast(&back_on));
    try testing.expectEqual(@as(usize, td.BUT_REWIND), attr(ib, anim, td.TDECK_Mode));
    var let_go = input(gc.GM_HANDLEINPUT, &release, 10, 7, &termination);
    try testing.expect(ib.SendMessage(anim, @ptrCast(&let_go)) & gc.GMR_VERIFY != 0);
    try testing.expectEqual(@as(i32, td.BUT_STOP), termination);
    // Play stays when let go; pressed again while playing, it stops.
    var play_down = input(gc.GM_GOACTIVE, &press, 50, 7, &termination);
    _ = ib.SendMessage(anim, @ptrCast(&play_down));
    var play_up = input(gc.GM_HANDLEINPUT, &release, 50, 7, &termination);
    _ = ib.SendMessage(anim, @ptrCast(&play_up));
    try testing.expectEqual(@as(i32, td.BUT_PLAY), termination);
    try testing.expectEqual(gc.GMR_NOREUSE | gc.GMR_VERIFY, ib.SendMessage(anim, @ptrCast(&play_down)));
    try testing.expectEqual(@as(usize, td.BUT_STOP), attr(ib, anim, td.TDECK_Mode));

    // The frame slider: a press past its knob pages to a later frame, and
    // the code is the frame with the frame code added.
    _ = ib.SetAttrsTagList(anim, &[_]TagItem{ .{ .tag = td.TDECK_CurrentFrame, .data = 0 }, .{} });
    termination = -1;
    var frames = input(gc.GM_GOACTIVE, &press, 190, 7, &termination);
    try testing.expect(ib.SendMessage(anim, @ptrCast(&frames)) & gc.GMR_VERIFY != 0);
    const frame = attr(ib, anim, td.TDECK_CurrentFrame);
    try testing.expect(frame > 0);
    try testing.expectEqual(@as(i32, @intCast(td.TDECK_FRAME_CODE | frame)), termination);

    ib.DisposeObject(anim);
    try rig.down();
}

test "spinner.gadget: square by default, running unless told, never pressed" {
    var heard = Heard{ .tag = spg.SPINNER_Running, .ib = undefined };
    var rig = try Rig.up(&spinner.Library.resident_tag, &heard);
    const ib = rig.ib;

    const turning = ib.NewObjectTagList(null, spg.SPINNER_CLASS, &[_]TagItem{.{}}).?;
    try testing.expectEqual(@as(usize, 1), attr(ib, turning, spg.SPINNER_Running));
    try testing.expectEqual(@as(usize, 1000), attr(ib, turning, spg.SPINNER_Period));
    try testing.expectEqual(@as(usize, 24), attr(ib, turning, gc.GA_Width));
    try testing.expectEqual(@as(usize, 24), attr(ib, turning, gc.GA_Height));
    _ = ib.SetAttrsTagList(turning, &[_]TagItem{
        .{ .tag = spg.SPINNER_Running, .data = 0 },
        .{ .tag = spg.SPINNER_Period, .data = 400 },
        .{},
    });
    try testing.expectEqual(@as(usize, 0), attr(ib, turning, spg.SPINNER_Running));
    try testing.expectEqual(@as(usize, 400), attr(ib, turning, spg.SPINNER_Period));

    var least = gc.GpDomain{ .which = gc.GDOMAIN_MINIMUM };
    try testing.expect(ib.SendMessage(turning, @ptrCast(&least)) != 0);
    try testing.expectEqual(least.domain.width, least.domain.height);
    var hit = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = 2, .y = 2 } };
    try testing.expectEqual(@as(usize, 0), ib.SendMessage(turning, @ptrCast(&hit)));
    ib.DisposeObject(turning);
    try rig.down();
}

test "angles: sines in sixteen-thousandths, the angle of a point on the screen" {
    try testing.expectEqual(@as(i32, 0), angles.sine(0));
    try testing.expectEqual(angles.one, angles.sine(90));
    try testing.expectEqual(-angles.one, angles.cosine(180));
    try testing.expectEqual(-angles.one, angles.sine(-90));
    try testing.expectEqual(@as(i32, 11585), angles.sine(45));
    // Up the screen is 90: y runs down.
    try testing.expectEqual(@as(i32, 0), angles.angleOf(10, 0));
    try testing.expectEqual(@as(i32, 90), angles.angleOf(0, -10));
    try testing.expectEqual(@as(i32, 180), angles.angleOf(-10, 0));
    try testing.expectEqual(@as(i32, 270), angles.angleOf(0, 10));
    try testing.expectEqual(@as(i32, 45), angles.angleOf(7, -7));
    try testing.expectEqual(@as(i32, 225), angles.angleOf(-7, 7));
    try testing.expectEqual(@as(i32, 30), angles.angleOf(866, -500));
    const top = angles.pointAt(50, 50, 40, 90);
    try testing.expectEqual(@as(i32, 50), top[0]);
    try testing.expectEqual(@as(i32, 10), top[1]);
}

test "meter.gadget: square, its level held to the scale, never pressed" {
    var heard = Heard{ .tag = mt.METER_Level, .ib = undefined };
    var rig = try Rig.up(&meter.Library.resident_tag, &heard);
    const ib = rig.ib;
    const dial = ib.NewObjectTagList(null, mt.METER_CLASS, &[_]TagItem{
        .{ .tag = mt.METER_Max, .data = 120 },
        .{ .tag = mt.METER_Level, .data = 40 },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 40), attr(ib, dial, mt.METER_Level));
    try testing.expectEqual(@as(usize, 96), attr(ib, dial, gc.GA_Width));
    try testing.expectEqual(@as(usize, 96), attr(ib, dial, gc.GA_Height));
    // Out of a window it is there at once, held to the scale.
    _ = ib.SetAttrsTagList(dial, &[_]TagItem{ .{ .tag = mt.METER_Level, .data = 500 }, .{} });
    try testing.expectEqual(@as(usize, 120), attr(ib, dial, mt.METER_Level));
    var hit = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = 40, .y = 40 } };
    try testing.expectEqual(@as(usize, 0), ib.SendMessage(dial, @ptrCast(&hit)));
    ib.DisposeObject(dial);
    try rig.down();
}

test "arc.gadget: an angle on the ring is a level, a press turns it, the target is told" {
    var heard = Heard{ .tag = ar.ARC_Level, .ib = undefined };
    var rig = try Rig.up(&arc.Library.resident_tag, &heard);
    const ib = rig.ib;

    // From the lower left (225) clockwise round to the lower right (-45).
    const own = arc.Data{};
    try testing.expectEqual(@as(i32, 0), arc.levelAt(&own, 225));
    try testing.expectEqual(@as(i32, 50), arc.levelAt(&own, 90));
    try testing.expectEqual(@as(i32, 100), arc.levelAt(&own, 315));
    // The gap at the bottom holds it at the nearer end.
    try testing.expectEqual(@as(i32, 100), arc.levelAt(&own, 280));
    try testing.expectEqual(@as(i32, 0), arc.levelAt(&own, 260));

    // A track too near its ground to see is drawn darker instead.
    try testing.expect(arc.tooClose(0xFFF4_F5F7, 0xFFFF_FFFF));
    try testing.expect(arc.tooClose(0xFFAA_AAAA, 0xFFAA_AAAA));
    try testing.expect(!arc.tooClose(0xFF88_8888, 0xFFFF_FFFF));

    // A ring without a knob is never pressed.
    const ring = ib.NewObjectTagList(null, ar.ARC_CLASS, &[_]TagItem{.{}}).?;
    var hit = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = 36, .y = 10 } };
    try testing.expectEqual(@as(usize, 0), ib.SendMessage(ring, @ptrCast(&hit)));
    ib.DisposeObject(ring);

    const knob = ib.NewObjectTagList(null, ar.ARC_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 9 },
        .{ .tag = ar.ARC_Turn, .data = 1 },
        .{ .tag = ar.ARC_Level, .data = 20 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 72), attr(ib, knob, gc.GA_Width));
    try testing.expectEqual(gc.GMR_GADGETHIT, ib.SendMessage(knob, @ptrCast(&hit)));
    // Pressed at the top: half way.
    var termination: i32 = -1;
    var down = input(gc.GM_GOACTIVE, &press, 36, 5, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(knob, @ptrCast(&down)));
    try testing.expectEqual(@as(usize, 50), attr(ib, knob, ar.ARC_Level));
    try testing.expectEqual(@as(?usize, 50), heard.value);
    // Let go at the right: three quarters of the way round the sweep.
    var up = input(gc.GM_HANDLEINPUT, &release, 70, 36, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE | gc.GMR_VERIFY, ib.SendMessage(knob, @ptrCast(&up)));
    try testing.expectEqual(@as(i32, 83), termination);
    try testing.expectEqual(@as(?usize, 83), heard.value);
    try testing.expectEqual(@as(?usize, 9), heard.id);
    ib.DisposeObject(knob);
    try rig.down();
}

test "roller.gadget: rows by position, a tap turns to its row, the key a row at a time" {
    var heard = Heard{ .tag = ro.ROLLER_Selected, .ib = undefined };
    var rig = try Rig.up(&roller.Library.resident_tag, &heard);
    const ib = rig.ib;
    const days = [_:null]?[*:0]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri" };

    var own = roller.Data{ .count = 5, .row_height = 12 };
    try testing.expectEqual(@as(u32, 0), roller.rowAt(&own, 5));
    try testing.expectEqual(@as(u32, 1), roller.rowAt(&own, 6));
    try testing.expectEqual(@as(u32, 4), roller.rowAt(&own, 200));
    own.wrap = 1;
    try testing.expectEqual(@as(u32, 0), roller.rowAt(&own, 60));
    try testing.expectEqual(@as(u32, 4), roller.rowAt(&own, -12));

    const wheel = ib.NewObjectTagList(null, ro.ROLLER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 5 },
        .{ .tag = gc.GA_Key, .data = 'd' },
        .{ .tag = ro.ROLLER_Labels, .data = @intFromPtr(&days) },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 0), attr(ib, wheel, ro.ROLLER_Selected));
    // Five rows shown: tall enough for them.
    const height = attr(ib, wheel, gc.GA_Height);
    try testing.expect(height >= 5 * 8);
    // A tap a row below the middle chooses that row.
    var termination: i32 = -1;
    const middle: i32 = @intCast(height / 2);
    const row: i32 = @intCast(height / 5);
    var down = input(gc.GM_GOACTIVE, &press, 10, middle + row, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(wheel, @ptrCast(&down)));
    var up = input(gc.GM_HANDLEINPUT, &release, 10, middle + row, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE | gc.GMR_VERIFY, ib.SendMessage(wheel, @ptrCast(&up)));
    try testing.expectEqual(@as(i32, 1), termination);
    try testing.expectEqual(@as(?usize, 1), heard.value);
    // A drag of two rows up turns two rows on.
    down = input(gc.GM_GOACTIVE, &press, 10, middle, &termination);
    _ = ib.SendMessage(wheel, @ptrCast(&down));
    const moving = ie.InputEvent{ .class = ie.IECLASS_NEWPOINTERPOS, .code = ie.IECODE_NOBUTTON };
    var drag = input(gc.GM_HANDLEINPUT, &moving, 10, middle - 2 * row, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(wheel, @ptrCast(&drag)));
    up = input(gc.GM_HANDLEINPUT, &release, 10, middle - 2 * row, &termination);
    _ = ib.SendMessage(wheel, @ptrCast(&up));
    try testing.expectEqual(@as(usize, 3), attr(ib, wheel, ro.ROLLER_Selected));
    // The key: down a row, and held at the end without wrapping.
    var typed = gc.GpKey{ .gadget_info = null, .key = 'd', .qualifier = 0, .termination = &termination };
    try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(wheel, @ptrCast(&typed)));
    try testing.expectEqual(@as(usize, 4), attr(ib, wheel, ro.ROLLER_Selected));
    try testing.expectEqual(gc.GMKR_DONE, ib.SendMessage(wheel, @ptrCast(&typed)));
    ib.DisposeObject(wheel);
    try rig.down();
}

test "calendar.gadget: the month a day is in, the weeks from the first weekday, the key a day on" {
    var heard = Heard{ .tag = ca.CALENDAR_Day, .ib = undefined };
    var rig = try Rig.up(&calendar.Library.resident_tag, &heard);
    const ib = rig.ib;
    const ub = rig.kib.utility_base;
    // 2 October 2026 is day 17806, a Friday; its month starts on the 1st,
    // a Thursday, and a week from Monday shows it from 28 September.
    try testing.expectEqual(@as(u32, 17805), calendar.monthStart(ub, 17806));
    try testing.expectEqual(@as(u32, 17802), calendar.gridStart(ub, 17805, 1));
    try testing.expectEqual(@as(u32, 17801), calendar.gridStart(ub, 17805, 0));

    var termination: i32 = -1;
    const picker = ib.NewObjectTagList(null, ca.CALENDAR_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 6 },
        .{ .tag = gc.GA_Key, .data = 'c' },
        .{ .tag = ca.CALENDAR_Today, .data = 17806 },
        .{ .tag = ca.CALENDAR_Day, .data = 17834 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 17834), attr(ib, picker, ca.CALENDAR_Day));
    // 30 October, the key once: 31; and again: 1 November.
    var typed = gc.GpKey{ .gadget_info = null, .key = 'c', .qualifier = 0, .termination = &termination };
    try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(picker, @ptrCast(&typed)));
    try testing.expectEqual(@as(?usize, 17835), heard.value);
    _ = ib.SendMessage(picker, @ptrCast(&typed));
    try testing.expectEqual(@as(i32, 17836), termination);
    ib.DisposeObject(picker);
    try rig.down();
}

test "canvas.gadget: a picture to draw into, kept with the gadget, presses told by place" {
    var heard = Heard{ .tag = cv.CANVAS_X, .ib = undefined };
    var rig = try Rig.up(&canvas.Library.resident_tag, &heard);
    const ib = rig.ib;
    const plain = ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{.{}}).?;
    try testing.expectEqual(@as(usize, 160), attr(ib, plain, cv.CANVAS_Width));
    try testing.expectEqual(@as(usize, 120), attr(ib, plain, cv.CANVAS_Height));
    try testing.expectEqual(@as(usize, 160), attr(ib, plain, gc.GA_Width));
    ib.DisposeObject(plain);

    const picture = ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{
        .{ .tag = cv.CANVAS_Width, .data = 50 },
        .{ .tag = cv.CANVAS_Height, .data = 40 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    try testing.expect(attr(ib, picture, cv.CANVAS_RastPort) != 0);
    try testing.expect(attr(ib, picture, cv.CANVAS_BitMap) != 0);
    var termination: i32 = -1;
    var down = input(gc.GM_GOACTIVE, &press, 12, 7, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(picture, @ptrCast(&down)));
    try testing.expectEqual(@as(?usize, 12), heard.value);
    var up = input(gc.GM_HANDLEINPUT, &release, 30, 7, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE | gc.GMR_VERIFY, ib.SendMessage(picture, @ptrCast(&up)));
    try testing.expectEqual(@as(?usize, 30), heard.value);
    ib.DisposeObject(picture);
    try rig.down();
}

test "canvas.gadget: the picture made anew at another size, 0 its box's, what fits of it kept" {
    var heard = Heard{ .tag = cv.CANVAS_X, .ib = undefined };
    var rig = try Rig.up(&canvas.Library.resident_tag, &heard);
    const ib = rig.ib;
    const gb = rig.kib.graphics_base;
    const picture = ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_Width, .data = 20 },
        .{ .tag = gc.GA_Height, .data = 10 },
        .{},
    }).?;
    const old: *sdk.graphics.RastPort = @ptrFromInt(attr(ib, picture, cv.CANVAS_RastPort));
    const red = sdk.graphics.penRGB(255, 0, 0);
    gb.SetRPAttrs(old, &[_]TagItem{ .{ .tag = sdk.graphics.RPTAG_APen, .data = red }, .{} });
    gb.RectFill(old, &.{ .min_x = 2, .min_y = 2, .max_x = 5, .max_y = 5 });
    var drawn: sdk.graphics.Pen = 0;
    try testing.expect(gb.ReadPixel(old, 3, 3, &drawn));

    // Wider by a number, as high as its box by 0: what was drawn is still
    // there, the rest is clear, and the pen drawn with came along.
    _ = ib.SetAttrsTagList(picture, &[_]TagItem{
        .{ .tag = cv.CANVAS_Width, .data = 30 },
        .{ .tag = cv.CANVAS_Height, .data = 0 },
        .{},
    });
    try testing.expectEqual(@as(usize, 30), attr(ib, picture, cv.CANVAS_Width));
    try testing.expectEqual(@as(usize, 10), attr(ib, picture, cv.CANVAS_Height));
    const new: *sdk.graphics.RastPort = @ptrFromInt(attr(ib, picture, cv.CANVAS_RastPort));
    var kept: sdk.graphics.Pen = 0;
    try testing.expect(gb.ReadPixel(new, 3, 3, &kept));
    try testing.expectEqual(drawn, kept);
    var clear: sdk.graphics.Pen = 1;
    try testing.expect(gb.ReadPixel(new, 25, 5, &clear));
    try testing.expect(clear & 0x00FF_FFFF == 0);
    var pen: u32 = 0;
    gb.GetRPAttrs(new, &[_]TagItem{ .{ .tag = sdk.graphics.RPTAG_APen, .data = @intFromPtr(&pen) }, .{} });
    try testing.expectEqual(red, pen);

    // What it asks a layout for stays what it was made with.
    var nominal = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(picture, @ptrCast(&nominal));
    try testing.expectEqual(@as(i32, 20), nominal.domain.width);
    try testing.expectEqual(@as(i32, 10), nominal.domain.height);
    ib.DisposeObject(picture);
    try rig.down();
}

test "qrcode.gadget: the smallest version that holds the text, its modules as the standard lays them" {
    var heard = Heard{ .tag = qc.QR_Version, .ib = undefined };
    var rig = try Rig.up(&qrcode.Library.resident_tag, &heard);
    const ib = rig.ib;

    // "Hello" at M is version 1; this is the symbol a reader decodes.
    const reference = [21]*const [21]u8{
        "111111100111101111111", "100000100000101000001", "101110101010101011101",
        "101110101010001011101", "101110101100101011101", "100000101101001000001",
        "111111101010101111111", "000000001010000000000", "101111100101001111100",
        "000100001001111001101", "001111100110101101110", "001001011011111001100",
        "011100111110100100001", "000000001000100101000", "111111100101010010110",
        "100000101010000111110", "101110101001010010010", "101110101101111101000",
        "101110101100101100100", "100000100101111011100", "111111101100100010010",
    };
    var work: [qrcode.encoder.workSize(1)]u8 = undefined;
    const symbol = qrcode.encoder.encode("Hello", .medium, 1, &work);
    try testing.expectEqual(@as(u32, 21), symbol.size);
    for (reference, 0..) |row, y| {
        for (row, 0..) |module, x| try testing.expectEqual(module == '1', symbol.dark(@intCast(x), @intCast(y)));
    }
    try testing.expectEqual(@as(?u32, 39), qrcode.encoder.versionFor(1200, .high));
    try testing.expectEqual(@as(?u32, null), qrcode.encoder.versionFor(1300, .high));

    const code = ib.NewObjectTagList(null, qc.QR_CLASS, &[_]TagItem{ .{ .tag = qc.QR_Text, .data = @intFromPtr("Hello") }, .{} }).?;
    try testing.expectEqual(@as(usize, 1), attr(ib, code, qc.QR_Version));
    _ = ib.SetAttrsTagList(code, &[_]TagItem{
        .{ .tag = qc.QR_Level, .data = qc.QR_LEVEL_H },
        .{ .tag = qc.QR_Text, .data = @intFromPtr("https://github.com/cycl0ne/poweros_esp32") },
        .{},
    });
    try testing.expectEqual(@as(usize, 5), attr(ib, code, qc.QR_Version));
    _ = ib.SetAttrsTagList(code, &[_]TagItem{ .{ .tag = qc.QR_Text, .data = 0 }, .{} });
    try testing.expectEqual(@as(usize, 0), attr(ib, code, qc.QR_Version));
    ib.DisposeObject(code);
    try rig.down();
}

test "barcode.gadget: Code 128 in set B or C, EAN-13 with its check digit" {
    var heard = Heard{ .tag = bcg.BARCODE_Valid, .ib = undefined };
    var rig = try Rig.up(&barcode.Library.resident_tag, &heard);
    const ib = rig.ib;
    var modules: [barcode.encoder.max_modules]u8 = undefined;
    // Six digits are three symbols of set C: start, three, check, stop.
    try testing.expectEqual(@as(?usize, 11 * 5 + 13), barcode.encoder.code128Modules("123456", &modules));
    try testing.expectEqual(@as(?usize, 11 * 5 + 13), barcode.encoder.code128Modules("ABC", &modules));
    try testing.expectEqual(@as(?usize, null), barcode.encoder.code128Modules("tab\there", &modules));
    try testing.expectEqual(@as(u8, 1), barcode.encoder.eanCheck("400638133393"));
    try testing.expectEqual(@as(u8, 7), barcode.encoder.eanCheck("590123412345"));

    const label = ib.NewObjectTagList(null, bcg.BARCODE_CLASS, &[_]TagItem{
        .{ .tag = bcg.BARCODE_Type, .data = bcg.BARCODE_EAN13 },
        .{ .tag = bcg.BARCODE_Text, .data = @intFromPtr("400638133393") },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 1), attr(ib, label, bcg.BARCODE_Valid));
    _ = ib.SetAttrsTagList(label, &[_]TagItem{ .{ .tag = bcg.BARCODE_Text, .data = @intFromPtr("4006381333932") }, .{} });
    try testing.expectEqual(@as(usize, 0), attr(ib, label, bcg.BARCODE_Valid));
    _ = ib.SetAttrsTagList(label, &[_]TagItem{
        .{ .tag = bcg.BARCODE_Type, .data = bcg.BARCODE_CODE128 },
        .{ .tag = bcg.BARCODE_Text, .data = @intFromPtr("PowerOS") },
        .{},
    });
    try testing.expectEqual(@as(usize, 1), attr(ib, label, bcg.BARCODE_Valid));
    ib.DisposeObject(label);
    try rig.down();
}

test "keyboard.gadget: every row as wide as the others, the key under a point" {
    for (keyboard.rows) |row| {
        var quarters: u32 = 0;
        for (row) |k| quarters += k.quarters;
        try testing.expectEqual(@as(u32, 54), quarters);
    }
    // 540 by 100: a quarter is 10 pixels, a row 20.
    const q = keyboard.keyAt(540, 100, 25, 30).?;
    try testing.expectEqual(@as(usize, 1), q[0]);
    try testing.expectEqual(@as(u8, 0x10), keyboard.rows[q[0]][q[1]].code);
    // The half key before the q is a gap: no key.
    try testing.expect(keyboard.keyAt(540, 100, 10, 30) == null);
    // The space bar, and Return at the right of the third row.
    const space = keyboard.keyAt(540, 100, 270, 90).?;
    try testing.expectEqual(keyboard.Kind.space, keyboard.rows[space[0]][space[1]].kind);
    const enter = keyboard.keyAt(540, 100, 530, 50).?;
    try testing.expectEqual(keyboard.Kind.enter, keyboard.rows[enter[0]][enter[1]].kind);
    const box = keyboard.keyBox(540, 100, 2, 12);
    try testing.expectEqual(@as(i32, 480), box.left);
    try testing.expectEqual(@as(i32, 60), box.width);
}

test "chart.gadget: values kept in a ring per series, the oldest let go, the scale round" {
    var heard = Heard{ .tag = cr.CHART_Count, .ib = undefined };
    var rig = try Rig.up(&chart.Library.resident_tag, &heard);
    const ib = rig.ib;
    const plot = ib.NewObjectTagList(null, cr.CHART_CLASS, &[_]TagItem{
        .{ .tag = cr.CHART_Series, .data = 2 },
        .{ .tag = cr.CHART_Capacity, .data = 4 },
        .{ .tag = cr.CHART_Auto, .data = 1 },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 200), attr(ib, plot, gc.GA_Width));
    // Five values into a ring of four: the first is let go.
    for ([_]i32{ 3, 17, 42, -5, 61 }) |value| {
        _ = ib.SetAttrsTagList(plot, &[_]TagItem{
            .{ .tag = cr.CHART_Current, .data = 0 },
            .{ .tag = cr.CHART_Add, .data = @bitCast(@as(isize, value)) },
            .{},
        });
    }
    _ = ib.SetAttrsTagList(plot, &[_]TagItem{
        .{ .tag = cr.CHART_Current, .data = 1 },
        .{ .tag = cr.CHART_Add, .data = 8 },
        .{ .tag = cr.CHART_Current, .data = 0 },
        .{},
    });
    try testing.expectEqual(@as(usize, 4), attr(ib, plot, cr.CHART_Count));
    // From -5 to 61 in four lines: steps of 20, from -20 to 80.
    try testing.expectEqual(@as(isize, -20), @as(isize, @bitCast(attr(ib, plot, cr.CHART_Min))));
    try testing.expectEqual(@as(usize, 80), attr(ib, plot, cr.CHART_Max));
    _ = ib.SetAttrsTagList(plot, &[_]TagItem{ .{ .tag = cr.CHART_Current, .data = 1 }, .{ .tag = cr.CHART_Clear, .data = 1 }, .{} });
    try testing.expectEqual(@as(usize, 0), attr(ib, plot, cr.CHART_Count));
    ib.DisposeObject(plot);
    try rig.down();

    var own = chart.Data{ .series = 1, .capacity = 3 };
    var values: [3]i32 = undefined;
    own.values = &values;
    for ([_]i32{ 1, 2, 3, 4 }) |v| chart.add(&own, 0, v);
    try testing.expectEqual(@as(i32, 2), chart.valueAt(&own, 0, 0));
    try testing.expectEqual(@as(i32, 4), chart.valueAt(&own, 0, 2));
}

test "text.gadget: markup into runs, runs wrapped into lines" {
    var heard = Heard{ .tag = tx.TEXT_Text, .ib = undefined };
    var rig = try Rig.up(&text.Library.resident_tag, &heard);
    const ib = rig.ib;
    const sys = kexec.SysBase.iface();
    const gb = rig.kib.graphics_base;
    const parsed = text.rich.parse(sys, gb, "Press <b>OK</b> or <c=#C03030>Cancel</c><br><<done", sdk.graphics.POSPAZNAME).?;
    const runs = &parsed.runs;
    try testing.expectEqualStrings("Press ", std.mem.span(runs[0].text.?));
    try testing.expectEqualStrings("OK", std.mem.span(runs[1].text.?));
    try testing.expectEqual(@as(u32, sdk.graphics.FSF_BOLD), runs[1].style);
    try testing.expectEqualStrings(" or ", std.mem.span(runs[2].text.?));
    try testing.expectEqual(@as(u32, 0), runs[2].style);
    try testing.expectEqualStrings("Cancel", std.mem.span(runs[3].text.?));
    try testing.expectEqual(@as(sdk.graphics.Pen, 0xFFC0_3030), runs[3].colour);
    try testing.expectEqualStrings("\n", std.mem.span(runs[4].text.?));
    try testing.expectEqualStrings("<done", std.mem.span(runs[5].text.?));
    try testing.expect(runs[6].text == null);
    text.rich.free(sys, gb, parsed);

    // One line unwrapped; narrow and wrapped, several.
    const words = "one two three four five six";
    const line = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        .{ .tag = tx.TEXT_Markup, .data = 1 },
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr(words) },
        .{},
    }).?;
    const one_line = attr(ib, line, gc.GA_Height);
    try testing.expect(one_line > 0);
    const block = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        .{ .tag = tx.TEXT_Markup, .data = 1 },
        .{ .tag = tx.TEXT_Wrap, .data = 1 },
        .{ .tag = gc.GA_Width, .data = 50 },
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr(words) },
        .{},
    }).?;
    var nominal = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(block, @ptrCast(&nominal));
    try testing.expect(nominal.domain.height >= 3 * @as(i32, @intCast(one_line)));
    ib.DisposeObject(line);
    ib.DisposeObject(block);
    try rig.down();
}

test "text.gadget: a line of runs cut at an edge with dots, a run in a pen named" {
    var heard = Heard{ .tag = tx.TEXT_Text, .ib = undefined };
    var rig = try Rig.up(&text.Library.resident_tag, &heard);
    const gb = rig.kib.graphics_base;
    const graphics = sdk.graphics;
    const sc = sdk.intuition.screens;
    const bitmap = gb.AllocBitMapTagList(&[_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = 160 },
        .{ .tag = graphics.BMTAG_Height, .data = 16 },
        .{},
    }).?;
    const rp = gb.CreateRastPortTagList(&[_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(bitmap) }, .{} }).?;
    const font = gb.OpenFont(&.{ .name = graphics.POSPAZNAME, .y_size = 8 }).?;
    graphics.SetFont(gb, rp, font);
    const black = graphics.penRGB(0, 0, 0);
    const red = graphics.penRGB(0xFF, 0, 0);
    const green = graphics.penRGB(0, 0xFF, 0);
    var pens: [sc.NUMDRIPENS]graphics.Pen = @splat(black);
    pens[sc.DIMTEXTPEN] = green;
    const runs = [_]tx.TextRun{
        .{ .text = "one two three four five six", .colour = tx.screenPen(sc.DIMTEXTPEN) },
        .{},
    };
    const ink = text.rich.Ink{ .gb = gb, .rp = rp, .font = font, .front = red, .pens = &pens };
    const line = text.rich.lineAt(ink, &runs, .{}, 0x7FFF, false).?;
    try testing.expect(line.width > 100);

    // Cut at 60: nothing drawn past it, and what is drawn is the pen the
    // run names, not the front pen.
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = black }, .{} });
    gb.RectFill(rp, &.{ .min_x = 0, .min_y = 0, .max_x = 160, .max_y = 16 });
    const right = text.rich.drawLine(ink, &runs, line, 0, 0, 60);
    try testing.expect(right <= 60 and right > 40);
    var seen_green = false;
    for (0..16) |y| for (0..160) |x| {
        var pixel: graphics.Pen = 0;
        try testing.expect(gb.ReadPixel(rp, @intCast(x), @intCast(y), &pixel));
        if (x >= 60) try testing.expectEqual(black, pixel | 0xFF00_0000);
        try testing.expect(pixel | 0xFF00_0000 != red);
        if (pixel | 0xFF00_0000 == green) seen_green = true;
    };
    try testing.expect(seen_green);

    // Room for no letter of "two": the dots follow "one", not the space
    // after it.
    const one = gb.TextLength(rp, "one", 3);
    const dots = gb.TextLength(rp, "...", 3);
    const tight = gb.TextLength(rp, "one ", 4) + dots + 1;
    try testing.expectEqual(one + dots, text.rich.drawLine(ink, &runs, line, 0, 0, tight));

    // Not cut: the whole line, as wide as it was measured.
    try testing.expectEqual(line.width, text.rich.drawLine(ink, &runs, line, 0, 0, null));
    gb.CloseFont(font);
    gb.FreeRastPort(rp);
    gb.FreeBitMap(bitmap);
    try rig.down();
}

test "fuelgauge.gadget: the level held in its range, the part filled, never pressed" {
    var heard = Heard{ .tag = fg.GAUGE_Level, .ib = undefined };
    var rig = try Rig.up(&fuelgauge.Library.resident_tag, &heard);
    const ib = rig.ib;

    const gauge = ib.NewObjectTagList(null, fg.GAUGE_CLASS, &[_]TagItem{
        .{ .tag = fg.GAUGE_Max, .data = 200 },
        .{ .tag = fg.GAUGE_Level, .data = 50 },
        .{ .tag = fg.GAUGE_Format, .data = @intFromPtr("%ld%%") },
        .{ .tag = fg.GAUGE_Percent, .data = 1 },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 50), attr(ib, gauge, fg.GAUGE_Level));
    try testing.expectEqual(@as(usize, 25), attr(ib, gauge, fg.GAUGE_Percent));

    // Past the end is held at the end.
    _ = ib.SetAttrsTagList(gauge, &[_]TagItem{ .{ .tag = fg.GAUGE_Level, .data = 500 }, .{} });
    try testing.expectEqual(@as(usize, 200), attr(ib, gauge, fg.GAUGE_Level));
    try testing.expectEqual(@as(usize, 100), attr(ib, gauge, fg.GAUGE_Percent));

    // A range that does not start at nothing counts from where it starts.
    _ = ib.SetAttrsTagList(gauge, &[_]TagItem{
        .{ .tag = fg.GAUGE_Min, .data = 100 },
        .{ .tag = fg.GAUGE_Level, .data = 150 },
        .{},
    });
    try testing.expectEqual(@as(usize, 50), attr(ib, gauge, fg.GAUGE_Percent));

    // As wide as it looks right, a line of the font and its frame thick.
    var nominal = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    try testing.expect(ib.SendMessage(gauge, @ptrCast(&nominal)) != 0);
    try testing.expect(nominal.domain.width >= 100);
    try testing.expect(nominal.domain.height > 0);
    var least = gc.GpDomain{ .which = gc.GDOMAIN_MINIMUM };
    try testing.expect(ib.SendMessage(gauge, @ptrCast(&least)) != 0);
    try testing.expect(least.domain.width < nominal.domain.width);

    // Never pressed: the press goes through it to the window.
    var hit = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = 2, .y = 2 } };
    try testing.expectEqual(@as(usize, 0), ib.SendMessage(gauge, @ptrCast(&hit)));
    ib.DisposeObject(gauge);

    // The ends the wrong way round are put right when it is made.
    const upside = ib.NewObjectTagList(null, fg.GAUGE_CLASS, &[_]TagItem{
        .{ .tag = fg.GAUGE_Min, .data = 10 },
        .{ .tag = fg.GAUGE_Max, .data = 0 },
        .{ .tag = fg.GAUGE_Level, .data = 5 },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 0), attr(ib, upside, fg.GAUGE_Min));
    try testing.expectEqual(@as(usize, 10), attr(ib, upside, fg.GAUGE_Max));
    try testing.expectEqual(@as(usize, 50), attr(ib, upside, fg.GAUGE_Percent));
    ib.DisposeObject(upside);
    try rig.down();
}

test "integer.gadget: the arrows step the number, and a number typed is brought into range" {
    var heard = Heard{ .tag = ig.INTEGER_Number, .ib = undefined };
    const kib = try host_rom.intuition.setUp();
    ByTail.install();
    // The field's library first, which the number field's opens.
    const string_lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &string.Library.resident_tag, null).?));
    const ib = kib.iface();
    heard.ib = ib;
    const lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &integer.Library.resident_tag, null).?));
    const listener_class = ib.MakeClass(null, classusr.ROOTCLASS, null, 0).?;
    listener_class.dispatcher.entry = &listen;
    listener_class.user_data = @intFromPtr(&heard);
    const listener = ib.NewObjectTagList(listener_class, null, null).?;

    const field = ib.NewObjectTagList(null, ig.INTEGER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 9 },
        .{ .tag = ig.INTEGER_Min, .data = 10 },
        .{ .tag = ig.INTEGER_Max, .data = 20 },
        .{ .tag = ig.INTEGER_Number, .data = 15 },
        .{ .tag = ig.INTEGER_Step, .data = 2 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(listener) },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 15), attr(ib, field, ig.INTEGER_Number));

    // The arrows are at the right end, up over down. A press on the up
    // arrow steps by INTEGER_Step and holds the gadget; letting it go
    // reports the number.
    const g = gc.gadget(field);
    const width = g.width;
    const height = g.height;
    var termination: i32 = -1;
    var down = input(gc.GM_GOACTIVE, &press, width - 2, 1, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(field, @ptrCast(&down)));
    try testing.expectEqual(@as(usize, 17), attr(ib, field, ig.INTEGER_Number));
    // Stepped, it takes no text: no on-screen keyboard for it.
    try testing.expect(g.flags & gc.GFLG_TYPING == 0);
    var up = input(gc.GM_HANDLEINPUT, &release, width - 2, 1, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE | gc.GMR_VERIFY, ib.SendMessage(field, @ptrCast(&up)));
    try testing.expectEqual(@as(i32, 17), termination);
    try testing.expectEqual(@as(?usize, 17), heard.value);
    try testing.expectEqual(@as(?usize, 9), heard.id);

    // The down arrow, at the bottom of the same column, takes it away and
    // stops at the smallest.
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var again = input(gc.GM_GOACTIVE, &press, width - 2, height - 2, &termination);
        try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(field, @ptrCast(&again)));
        var let_go = input(gc.GM_HANDLEINPUT, &release, width - 2, height - 2, &termination);
        _ = ib.SendMessage(field, @ptrCast(&let_go));
    }
    try testing.expectEqual(@as(usize, 10), attr(ib, field, ig.INTEGER_Number));

    // A number typed: taken as it is typed, and brought into the range
    // when the field is done with it.
    var typed = classusr.OpUpdate{
        .method_id = classusr.OM_UPDATE,
        .attr_list = &[_]TagItem{ .{ .tag = gc.STRINGA_LongVal, .data = 99 }, .{} },
        .flags = classusr.OPUF_INTERIM,
    };
    _ = ib.SendMessage(field, @ptrCast(&typed));
    try testing.expectEqual(@as(usize, 99), attr(ib, field, ig.INTEGER_Number));
    typed.flags = 0;
    _ = ib.SendMessage(field, @ptrCast(&typed));
    try testing.expectEqual(@as(usize, 20), attr(ib, field, ig.INTEGER_Number));
    try testing.expectEqual(@as(?usize, 20), heard.value);

    // A press on the field itself is the field's: it goes active and is
    // not an arrow step.
    const before = attr(ib, field, ig.INTEGER_Number);
    var in_field = input(gc.GM_GOACTIVE, &press, 2, 1, &termination);
    _ = ib.SendMessage(field, @ptrCast(&in_field));
    try testing.expectEqual(before, attr(ib, field, ig.INTEGER_Number));
    // Typed into, it takes text: the on-screen keyboard comes up for it.
    try testing.expect(g.flags & gc.GFLG_TYPING != 0);
    var gone = gc.GpGoInactive{ .gadget_info = null, .abort = 0 };
    _ = ib.SendMessage(field, @ptrCast(&gone));

    // Made without arrows, it is as wide as the field alone.
    const plain = ib.NewObjectTagList(null, ig.INTEGER_CLASS, &[_]TagItem{
        .{ .tag = ig.INTEGER_Arrows, .data = 0 },
        .{},
    }).?;
    try testing.expect(gc.gadget(plain).width < width);
    ib.DisposeObject(plain);

    ib.DisposeObject(field);
    ib.DisposeObject(listener);
    try testing.expect(ib.FreeClass(listener_class));
    const sys = kexec.SysBase.iface();
    // The number field first: it has the field's library open.
    _ = sys.RemLibrary(lib);
    try testing.expect(ib.FindClass(ig.INTEGER_CLASS) == null);
    _ = sys.RemLibrary(string_lib);
    try testing.expect(ib.FindClass(st.STRING_CLASS) == null);
    ByTail.remove();
    try host_rom.intuition.tearDown(kib);
}

test "chooser.gadget: the labels it picks from, and the key that steps them" {
    var heard = Heard{ .tag = ch.CHOOSER_Active, .ib = undefined };
    var rig = try Rig.up(&chooser.Library.resident_tag, &heard);
    const ib = rig.ib;

    const keymaps = [_:null]?[*:0]const u8{ "deutsch", "usa", "usa2", "france" };
    const which = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 4 },
        .{ .tag = gc.GA_Key, .data = 'k' },
        .{ .tag = ch.CHOOSER_Labels, .data = @intFromPtr(&keymaps) },
        .{ .tag = ch.CHOOSER_Active, .data = 2 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 4), attr(ib, which, ch.CHOOSER_NumLabels));
    try testing.expectEqual(@as(usize, 2), attr(ib, which, ch.CHOOSER_Active));

    // The key steps on, and back with a Shift key held, round at either
    // end - the panel wants a pointer, and a key has none.
    var termination: i32 = -1;
    var step_on = keyed('k', 0, &termination);
    try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(which, @ptrCast(&step_on)));
    try testing.expectEqual(@as(usize, 3), attr(ib, which, ch.CHOOSER_Active));
    try testing.expectEqual(@as(i32, 3), termination);
    try testing.expectEqual(@as(?usize, 3), heard.value);
    try testing.expectEqual(@as(?usize, 4), heard.id);
    try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(which, @ptrCast(&step_on)));
    try testing.expectEqual(@as(usize, 0), attr(ib, which, ch.CHOOSER_Active));
    var back = keyed('k', ie.IEQUALIFIER_LSHIFT, &termination);
    try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(which, @ptrCast(&back)));
    try testing.expectEqual(@as(usize, 3), attr(ib, which, ch.CHOOSER_Active));

    // A shorter list holds the one shown inside it.
    const two = [_:null]?[*:0]const u8{ "on", "off" };
    _ = ib.SetAttrsTagList(which, &[_]TagItem{ .{ .tag = ch.CHOOSER_Labels, .data = @intFromPtr(&two) }, .{} });
    try testing.expectEqual(@as(usize, 2), attr(ib, which, ch.CHOOSER_NumLabels));
    try testing.expectEqual(@as(usize, 1), attr(ib, which, ch.CHOOSER_Active));

    // Wide enough for its widest label and the mark beside it, and a
    // line of the font tall whatever its width.
    var nominal = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    try testing.expect(ib.SendMessage(which, @ptrCast(&nominal)) != 0);
    var least = gc.GpDomain{ .which = gc.GDOMAIN_MINIMUM };
    try testing.expect(ib.SendMessage(which, @ptrCast(&least)) != 0);
    try testing.expect(least.domain.width > 0);
    try testing.expect(nominal.domain.width >= least.domain.width);
    try testing.expectEqual(nominal.domain.height, least.domain.height);

    // It is pressed, and without a window to open the panel on it takes
    // nothing and lets the press go.
    var hit = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = 2, .y = 2 } };
    try testing.expectEqual(gc.GMR_GADGETHIT, ib.SendMessage(which, @ptrCast(&hit)));
    var down = input(gc.GM_GOACTIVE, &press, 2, 2, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE, ib.SendMessage(which, @ptrCast(&down)));

    ib.DisposeObject(which);
    try rig.down();
}

test "page.gadget: the page that is shown answers for the gadget" {
    var heard = Heard{ .tag = pgc.PAGE_Current, .ib = undefined };
    var rig = try Rig.up(&pageclass.Library.resident_tag, &heard);
    const ib = rig.ib;

    // Two pages, each a button with a key of its own.
    const first = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("One") },
        .{ .tag = gc.GA_ID, .data = 1 },
        .{ .tag = gc.GA_Key, .data = 'a' },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    }).?;
    const second = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("A much longer page") },
        .{ .tag = gc.GA_ID, .data = 2 },
        .{ .tag = gc.GA_Key, .data = 'b' },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    }).?;
    const pages = [_:null]?*Object{ first, second };
    const book = ib.NewObjectTagList(null, pgc.PAGE_CLASS, &[_]TagItem{
        .{ .tag = pgc.PAGE_Pages, .data = @intFromPtr(&pages) },
        .{ .tag = pgc.PAGE_Current, .data = 0 },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 2), attr(ib, book, pgc.PAGE_NumPages));
    try testing.expectEqual(@as(usize, 0), attr(ib, book, pgc.PAGE_Current));

    // As big as the largest page needs, so the page turns without the
    // window changing size.
    var want = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    try testing.expect(ib.SendMessage(book, @ptrCast(&want)) != 0);
    var wide = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(second, @ptrCast(&wide));
    try testing.expectEqual(wide.domain.width, want.domain.width);

    // The key of the page that is shown works; the other page's does not.
    var termination: i32 = -1;
    var key_a = keyed('a', 0, &termination);
    var key_b = keyed('b', 0, &termination);
    try testing.expect(ib.SendMessage(book, @ptrCast(&key_a)) != gc.GMKR_NOTHING);
    try testing.expectEqual(gc.GMKR_NOTHING, ib.SendMessage(book, @ptrCast(&key_b)));
    _ = ib.SetAttrsTagList(book, &[_]TagItem{ .{ .tag = pgc.PAGE_Current, .data = 1 }, .{} });
    try testing.expectEqual(@as(usize, 1), attr(ib, book, pgc.PAGE_Current));
    try testing.expectEqual(gc.GMKR_NOTHING, ib.SendMessage(book, @ptrCast(&key_a)));
    try testing.expect(ib.SendMessage(book, @ptrCast(&key_b)) != gc.GMKR_NOTHING);

    // Past the last page is the last page.
    _ = ib.SetAttrsTagList(book, &[_]TagItem{ .{ .tag = pgc.PAGE_Current, .data = 9 }, .{} });
    try testing.expectEqual(@as(usize, 1), attr(ib, book, pgc.PAGE_Current));

    // The pages go with it.
    ib.DisposeObject(book);
    try rig.down();
}

test "page.gadget: a row of tabs along its top turns the pages, and a page turned by hand shows in it" {
    var heard = Heard{ .tag = pgc.PAGE_Current, .ib = undefined };
    var rig = try Rig.up(&pageclass.Library.resident_tag, &heard);
    const ib = rig.ib;
    const tabs_lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &clicktab.Library.resident_tag, null).?));

    const first = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("One") },
        .{ .tag = gc.GA_ID, .data = 1 },
        .{ .tag = gc.GA_Key, .data = 'a' },
        .{},
    }).?;
    const second = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("Two") },
        .{ .tag = gc.GA_ID, .data = 2 },
        .{ .tag = gc.GA_Key, .data = 'b' },
        .{},
    }).?;
    const pages = [_:null]?*Object{ first, second };
    const names = [_:null]?[*:0]const u8{ "One", "Two" };
    const tabs = ib.NewObjectTagList(null, ct.CLICKTAB_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 7 },
        .{ .tag = gc.GA_Key, .data = 't' },
        .{ .tag = ct.CLICKTAB_Labels, .data = @intFromPtr(&names) },
        .{},
    }).?;
    const book = ib.NewObjectTagList(null, pgc.PAGE_CLASS, &[_]TagItem{
        .{ .tag = pgc.PAGE_Pages, .data = @intFromPtr(&pages) },
        .{ .tag = pgc.PAGE_Tabs, .data = @intFromPtr(tabs) },
        .{ .tag = pgc.PAGE_Current, .data = 1 },
        .{},
    }).?;
    // The row shows the page the gadget was made on.
    try testing.expectEqual(@as(usize, 1), attr(ib, tabs, ct.CLICKTAB_Current));

    // Taller than a page by the row and the frame, wider than a page by
    // the frame, and never narrower than the row.
    var want = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    try testing.expect(ib.SendMessage(book, @ptrCast(&want)) != 0);
    var row = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(tabs, @ptrCast(&row));
    var page = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(first, @ptrCast(&page));
    try testing.expect(want.domain.height > row.domain.height + page.domain.height);
    try testing.expect(want.domain.width > page.domain.width);
    try testing.expect(want.domain.width >= row.domain.width);
    // A page with no most size leaves the gadget's unlimited, the frame
    // and the row not added past the limit.
    var most = gc.GpDomain{ .which = gc.GDOMAIN_MAXIMUM };
    _ = ib.SendMessage(book, @ptrCast(&most));
    try testing.expect(most.domain.width <= gc.GDOMAIN_UNLIMITED and most.domain.height <= gc.GDOMAIN_UNLIMITED);

    // The row is asked for a key before the page: its key takes the next
    // tab, round to the first, and the page turns with it.
    var termination: i32 = -1;
    var step = keyed('t', 0, &termination);
    try testing.expect(ib.SendMessage(book, @ptrCast(&step)) != gc.GMKR_NOTHING);
    try testing.expectEqual(@as(usize, 0), attr(ib, tabs, ct.CLICKTAB_Current));
    try testing.expectEqual(@as(usize, 0), attr(ib, book, pgc.PAGE_Current));
    var key_a = keyed('a', 0, &termination);
    var key_b = keyed('b', 0, &termination);
    try testing.expect(ib.SendMessage(book, @ptrCast(&key_a)) != gc.GMKR_NOTHING);
    try testing.expectEqual(gc.GMKR_NOTHING, ib.SendMessage(book, @ptrCast(&key_b)));

    // A page turned by hand is the tab in front.
    _ = ib.SetAttrsTagList(book, &[_]TagItem{ .{ .tag = pgc.PAGE_Current, .data = 1 }, .{} });
    try testing.expectEqual(@as(usize, 1), attr(ib, tabs, ct.CLICKTAB_Current));

    // The row goes with the gadget: its class has no objects left, so its
    // library goes when it is asked to.
    ib.DisposeObject(book);
    _ = kexec.SysBase.iface().RemLibrary(tabs_lib);
    try testing.expect(ib.FindClass(tabs_lib.name().ptr) == null);
    try rig.down();
}

/// A display for a window to open on: the fake board, 64 by 40 pixels.
const Display = struct {
    state: *host_rom.fakeboard.State,
    board: *sdk.rtg.RtgBoard,
    bitmap: *sdk.rtg.RtgBitMap,

    fn up(kib: *host_rom.intuition.IntuitionBase) !Display {
        const gb: *host_rom.graphics.GraphicsBase = @ptrCast(@alignCast(kib.graphics_base));
        const rtg_base: *sdk.interface.rtg.RtgBase = @ptrCast(@alignCast(gb.rtg_base));
        const state = host_rom.fakeboard.create(kib.sys_base) orelse return error.NoDriver;
        try testing.expect(rtg_base.AddRtgDriver(&state.driver));
        const empty = [_]TagItem{.{}};
        const board = rtg_base.CreateBoardTagList(host_rom.fakeboard.DRIVER_NAME, &empty) orelse return error.NoBoard;
        board.info.width = 64;
        board.info.height = 40;
        const bitmap = rtg_base.AllocBitMap(board, 64, 40, @intFromEnum(sdk.rtg.bitmaps.PixelFormat.rgb565), sdk.rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse return error.NoBitMap;
        try testing.expectEqual(sdk.rtg.errors.RTGERR_OK, rtg_base.ShowBitMap(board, bitmap, 0, 0));
        return .{ .state = state, .board = board, .bitmap = bitmap };
    }

    fn down(d: Display, kib: *host_rom.intuition.IntuitionBase) void {
        const gb: *host_rom.graphics.GraphicsBase = @ptrCast(@alignCast(kib.graphics_base));
        const rtg_base: *sdk.interface.rtg.RtgBase = @ptrCast(@alignCast(gb.rtg_base));
        rtg_base.FreeBitMap(d.bitmap);
        rtg_base.DeleteBoard(d.board);
        _ = rtg_base.RemRtgDriver(&d.state.driver);
        host_rom.fakeboard.destroy(d.state);
    }

    fn pixel(d: Display, x: usize, y: usize) u16 {
        const shown = d.board.showing orelse d.bitmap;
        const row = shown.pixels.? + y * shown.pitch;
        return @as([*]const u16, @ptrCast(@alignCast(row)))[x];
    }
};

test "windowclass: scroll bars in its borders, made with the program's tags, kept from one open to the next" {
    const kib = try host_rom.intuition.setUp();
    // The window object opens the class by its path, as ramlib takes it.
    ByTail.install();
    const scroller_lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &scroller.Library.resident_tag, null).?));
    const ib = kib.iface();
    const display = try Display.up(kib);
    const wn = intuition.windows;
    const wc = intuition.windowclass;

    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("B") },
        .{ .tag = wn.WA_Width, .data = 60 },
        .{ .tag = wn.WA_Height, .data = 38 },
        .{ .tag = wc.WINDOWA_VertScroller, .data = @intFromPtr(&[_]TagItem{
            .{ .tag = gc.GA_ID, .data = 5 },
            .{ .tag = sr.SCROLLER_Total, .data = 100 },
            .{ .tag = sr.SCROLLER_Visible, .data = 10 },
            .{},
        }) },
        // A bar with none of the program's tags at all.
        .{ .tag = wc.WINDOWA_HorizScroller, .data = 0 },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 0), attr(ib, object, wc.WINDOWA_VertScroller));

    var open = wc.WmOpen{};
    const w: *intuition.Window = @ptrFromInt(ib.SendMessage(object, @ptrCast(&open)));
    const vert: *Object = @ptrFromInt(attr(ib, object, wc.WINDOWA_VertScroller));
    const horiz: *Object = @ptrFromInt(attr(ib, object, wc.WINDOWA_HorizScroller));
    try testing.expectEqual(@as(usize, 5), attr(ib, vert, gc.GA_ID));
    try testing.expectEqual(@as(usize, 100), attr(ib, vert, sr.SCROLLER_Total));
    // Both borders as deep as a sizing gadget makes them, which the bars
    // fill, and the window no smaller than their arrows and as much again.
    const wanted = struct {
        fn of(i: *IntuitionBase, window: *intuition.Window, tag: utility.Tag) i32 {
            var value: usize = 0;
            i.GetWindowAttrs(window, &[_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} });
            return @intCast(value);
        }
    }.of;
    const left = wanted(ib, w, wn.WA_BorderLeft);
    const right = wanted(ib, w, wn.WA_BorderRight);
    const bottom = wanted(ib, w, wn.WA_BorderBottom);
    try testing.expect(right > left);
    try testing.expect(bottom > left);
    // As far as the window's size now allows: a smaller one is refused.
    try testing.expect(wanted(ib, w, wn.WA_MinWidth) >= @min(left + right + 4 * bottom, wanted(ib, w, wn.WA_Width)));

    // Closed and opened again: the same bars, their numbers as they were.
    var shut = wc.WmClose{};
    _ = ib.SendMessage(object, @ptrCast(&shut));
    _ = ib.SetAttrsTagList(vert, &[_]TagItem{ .{ .tag = sr.SCROLLER_Total, .data = 200 }, .{} });
    _ = ib.SendMessage(object, @ptrCast(&open));
    try testing.expectEqual(@intFromPtr(vert), attr(ib, object, wc.WINDOWA_VertScroller));
    try testing.expectEqual(@intFromPtr(horiz), attr(ib, object, wc.WINDOWA_HorizScroller));
    try testing.expectEqual(@as(usize, 200), attr(ib, vert, sr.SCROLLER_Total));

    // Gone with the object: the scroller's library has no bar left, and
    // no opener, so it goes when asked.
    var screen_ptr: usize = 0;
    ib.GetWindowAttrs(w, &[_]TagItem{ .{ .tag = wn.WA_Screen, .data = @intFromPtr(&screen_ptr) }, .{} });
    const screen: *intuition.Screen = @ptrFromInt(screen_ptr);
    ib.DisposeObject(object);
    _ = kexec.SysBase.iface().RemLibrary(scroller_lib);
    try testing.expect(ib.FindClass(sr.SCROLLER_CLASS) == null);
    try testing.expect(ib.CloseScreen(screen));
    ByTail.remove();
    display.down(kib);
    try host_rom.intuition.tearDown(kib);
}

test "scrollgroup.gadget: a part of its contents in view, the rest cut off, moved by a scroller or the wheel" {
    const kib = try host_rom.intuition.setUp();
    ByTail.install();
    const scroller_lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &scroller.Library.resident_tag, null).?));
    const lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &scrollgroup.Library.resident_tag, null).?));
    const ib = kib.iface();
    const display = try Display.up(kib);
    const wn = intuition.windows;
    const lg = intuition.layoutgclass;

    // Six buttons one above the other: far taller than the view.
    var buttons: [6]*Object = undefined;
    const form = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
        .{},
    }).?;
    for (&buttons, 0..) |*button, i| {
        const label = [_][*:0]const u8{ "1", "2", "3", "4", "5", "6" };
        button.* = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
            .{ .tag = gc.GA_Text, .data = @intFromPtr(label[i]) },
            .{},
        }).?;
        _ = ib.SetAttrsTagList(form, &[_]TagItem{ .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(button.*) }, .{} });
    }
    const view = ib.NewObjectTagList(null, sgc.SCROLLGROUP_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 0 },
        .{ .tag = gc.GA_Top, .data = 0 },
        .{ .tag = gc.GA_Width, .data = 48 },
        .{ .tag = gc.GA_Height, .data = 24 },
        .{ .tag = sgc.SCROLLGROUP_Contents, .data = @intFromPtr(form) },
        .{},
    }).?;
    const w = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(view) },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{},
    }).?;
    const background = display.pixel(54, 30);

    // Laid out at the size they ask for, from the view's corner; the view
    // is what is left beside the scroller down the right.
    try testing.expectEqual(@as(usize, 0), attr(ib, view, sgc.SCROLLGROUP_Top));
    const contents = gc.gadget(form);
    try testing.expectEqual(@as(i32, 0), contents.top);
    try testing.expect(contents.height > 24);
    const clip: *const sdk.graphics.Rect = @ptrFromInt(attr(ib, buttons[5], gc.GA_ClipRect));
    try testing.expectEqual(sdk.graphics.Rect{ .min_x = 0, .min_y = 0, .max_x = 32, .max_y = 24 }, clip.*);
    // A press on the scroller is the scroll group's; one past the view is
    // nobody's.
    var on_bar = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = 40, .y = 4 } };
    try testing.expectEqual(gc.GMR_GADGETHIT, ib.SendMessage(view, @ptrCast(&on_bar)));
    var past = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = 4, .y = 30 } };
    try testing.expectEqual(@as(usize, 0), ib.SendMessage(view, @ptrCast(&past)));

    // Nothing of the contents is drawn below the view, though most of them
    // lie there.
    ib.RefreshGList(view, w, -1);
    try expectBlankBelow(display, background);

    // Moved: the contents go up under the view, held at the last full view.
    _ = ib.SetGadgetAttrsTagList(view, w, &[_]TagItem{ .{ .tag = sgc.SCROLLGROUP_Top, .data = 10 }, .{} });
    try testing.expectEqual(@as(usize, 10), attr(ib, view, sgc.SCROLLGROUP_Top));
    try testing.expectEqual(@as(i32, -10), contents.top);
    _ = ib.SetGadgetAttrsTagList(view, w, &[_]TagItem{ .{ .tag = sgc.SCROLLGROUP_Top, .data = 1000 }, .{} });
    const last: usize = @intCast(contents.height - 24);
    try testing.expectEqual(last, attr(ib, view, sgc.SCROLLGROUP_Top));
    ib.RefreshGList(view, w, -1);
    try expectBlankBelow(display, background);

    // The wheel over a button, which takes none: three lines a notch.
    _ = ib.SetGadgetAttrsTagList(view, w, &[_]TagItem{ .{ .tag = sgc.SCROLLGROUP_Top, .data = 0 }, .{} });
    var notch = gc.GpWheel{ .gadget_info = null, .mouse = .{ .x = 8, .y = 8 }, .across = 0, .down = 1, .qualifier = 0 };
    try testing.expectEqual(@as(usize, 1), ib.SendMessage(view, @ptrCast(&notch)));
    const moved = attr(ib, view, sgc.SCROLLGROUP_Top);
    try testing.expect(moved > 0 and moved <= last);
    try testing.expectEqual(-@as(i32, @intCast(moved)), contents.top);

    const screen: *intuition.Screen = @ptrFromInt(windowAttrOf(ib, w, wn.WA_Screen));
    ib.CloseWindow(w);
    try testing.expect(ib.CloseScreen(screen));
    // The contents go with it.
    ib.DisposeObject(view);

    // Without scrollers of its own - a program's are in the window's
    // border - the view is the whole box, and the wheel still moves it.
    const tall = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
        .{},
    }).?;
    for (0..6) |_| {
        const button = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{ .{ .tag = gc.GA_Text, .data = @intFromPtr("x") }, .{} }).?;
        _ = ib.SetAttrsTagList(tall, &[_]TagItem{ .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(button) }, .{} });
    }
    const bare = ib.NewObjectTagList(null, sgc.SCROLLGROUP_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 0 },
        .{ .tag = gc.GA_Top, .data = 0 },
        .{ .tag = gc.GA_Width, .data = 48 },
        .{ .tag = gc.GA_Height, .data = 24 },
        .{ .tag = sgc.SCROLLGROUP_Contents, .data = @intFromPtr(tall) },
        .{ .tag = sgc.SCROLLGROUP_Scrollers, .data = 0 },
        .{},
    }).?;
    const w2 = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(bare) },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 48), attr(ib, bare, sgc.SCROLLGROUP_VisibleWidth));
    try testing.expectEqual(@as(usize, 24), attr(ib, bare, sgc.SCROLLGROUP_VisibleHeight));
    try testing.expect(attr(ib, bare, sgc.SCROLLGROUP_TotalHeight) > 24);
    var turn = gc.GpWheel{ .gadget_info = null, .mouse = .{ .x = 8, .y = 8 }, .across = 0, .down = 1, .qualifier = 0 };
    try testing.expectEqual(@as(usize, 1), ib.SendMessage(bare, @ptrCast(&turn)));
    try testing.expect(attr(ib, bare, sgc.SCROLLGROUP_Top) > 0);
    const screen2: *intuition.Screen = @ptrFromInt(windowAttrOf(ib, w2, wn.WA_Screen));
    ib.CloseWindow(w2);
    try testing.expect(ib.CloseScreen(screen2));
    ib.DisposeObject(bare);
    display.down(kib);
    const sys = kexec.SysBase.iface();
    _ = sys.RemLibrary(lib);
    try testing.expect(ib.FindClass(sgc.SCROLLGROUP_CLASS) == null);
    _ = sys.RemLibrary(scroller_lib);
    ByTail.remove();
    try host_rom.intuition.tearDown(kib);
}

/// Below the view, where the buttons' edges and digits would be if they
/// were drawn past it, nothing but the window's ground.
fn expectBlankBelow(display: Display, background: u16) !void {
    for (25..36) |y| {
        for (0..32) |x| try testing.expectEqual(background, display.pixel(x, y));
    }
}

/// The first column of every row of `list`, in order, joined by spaces.
fn namesOf(list: *exec.List, into: []u8) []const u8 {
    var n: usize = 0;
    var node = list.first();
    while (node) |each| : (node = each.next()) {
        const row: *lbr.Row = @fieldParentPtr("node", each);
        const name = std.mem.span(row.cells[0].?);
        if (n > 0) {
            into[n] = ' ';
            n += 1;
        }
        @memcpy(into[n..][0..name.len], name);
        n += name.len;
    }
    return into[0..n];
}

test "listbrowser.gadget: rows in a tree, a closed branch hidden, sorted with every branch kept under its row" {
    var heard = Heard{ .tag = lbr.LISTBROWSER_Selected, .ib = undefined };
    const kib = try host_rom.intuition.setUp();
    ByTail.install();
    const scroller_lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &scroller.Library.resident_tag, null).?));
    const ib = kib.iface();
    heard.ib = ib;
    const lib: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &listbrowser.Library.resident_tag, null).?));
    const listener_class = ib.MakeClass(null, classusr.ROOTCLASS, null, 0).?;
    listener_class.dispatcher.entry = &listen;
    listener_class.user_data = @intFromPtr(&heard);
    const listener = ib.NewObjectTagList(listener_class, null, null).?;
    const sys = kexec.SysBase.iface();

    // A branch "alpha" with two rows under it, closed, between two rows.
    const columns = [_]lbr.Column{
        .{ .title = "Name", .weight = 2 },
        .{ .title = "Size", .weight = 1, .flags = lbr.COLUMN_RIGHT | lbr.COLUMN_NUMBER },
        .{},
    };
    var rows: exec.List = .{};
    rows.init(.unknown);
    const given = [_]struct { name: [*:0]const u8, size: [*:0]const u8, depth: u16 }{
        .{ .name = "zeta", .size = "5", .depth = 0 },
        .{ .name = "alpha", .size = "30", .depth = 0 },
        .{ .name = "b", .size = "2", .depth = 1 },
        .{ .name = "a", .size = "9", .depth = 1 },
        .{ .name = "mid", .size = "100", .depth = 0 },
    };
    for (given) |one| sys.AddTail(&rows, &lbr.allocRow(sys, &.{ one.name, one.size }, one.depth).?.node);
    const browser = ib.NewObjectTagList(null, lbr.LISTBROWSER_CLASS, &[_]TagItem{
        .{ .tag = lbr.LISTBROWSER_Columns, .data = @intFromPtr(&columns) },
        .{ .tag = lbr.LISTBROWSER_Rows, .data = @intFromPtr(&rows) },
        .{ .tag = gc.GA_ID, .data = 9 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(listener) },
        .{},
    }).?;
    const cl = classes.objectClass(browser);
    const own = classes.instData(listbrowser.Data, cl, browser);
    const parts = listbrowser.partsOf(sdk.gadgets.baseOf(cl), own, browser, null);
    try testing.expect(parts.visible >= 3);

    // Sorted by name: each branch under its row, sorted among itself.
    var names: [64]u8 = undefined;
    _ = ib.SetAttrsTagList(browser, &[_]TagItem{ .{ .tag = lbr.LISTBROWSER_SortColumn, .data = 0 }, .{} });
    try testing.expectEqualStrings("alpha a b mid zeta", namesOf(&rows, &names));
    _ = ib.SetAttrsTagList(browser, &[_]TagItem{ .{ .tag = lbr.LISTBROWSER_SortReverse, .data = 1 }, .{} });
    try testing.expectEqualStrings("zeta mid alpha b a", namesOf(&rows, &names));
    // By size, as numbers: 5 before 30 before 100, and 2 before 9.
    _ = ib.SetAttrsTagList(browser, &[_]TagItem{ .{ .tag = lbr.LISTBROWSER_SortColumn, .data = 1 }, .{ .tag = lbr.LISTBROWSER_SortReverse, .data = 0 }, .{} });
    try testing.expectEqualStrings("zeta alpha b a mid", namesOf(&rows, &names));

    // The selection is the row, counted among all rows.
    _ = ib.SetAttrsTagList(browser, &[_]TagItem{ .{ .tag = lbr.LISTBROWSER_Selected, .data = 4 }, .{} });
    const chosen: *lbr.Row = @ptrFromInt(attr(ib, browser, lbr.LISTBROWSER_SelectedRow));
    try testing.expectEqualStrings("mid", std.mem.span(chosen.cells[0].?));
    try testing.expectEqual(@as(usize, 4), attr(ib, browser, lbr.LISTBROWSER_Selected));

    // "alpha" is closed: the third row shown is "mid", not "b". A press on
    // it, let go, reports its place among every row, 4, and tells the
    // target so.
    const x = parts.lines.left + 30;
    const third = parts.lines.top + 2 * parts.line_height + 1;
    var termination: i32 = -1;
    var down = input(gc.GM_GOACTIVE, &press, x, third, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(browser, @ptrCast(&down)));
    var up = input(gc.GM_HANDLEINPUT, &release, x, third, &termination);
    try testing.expect(ib.SendMessage(browser, @ptrCast(&up)) & gc.GMR_VERIFY != 0);
    try testing.expectEqual(@as(i32, 4), termination);
    try testing.expectEqual(@as(?usize, 4), heard.value);

    // Its triangle opens "alpha": the third row shown is now "b".
    const second = parts.lines.top + parts.line_height + 1;
    var open_it = input(gc.GM_GOACTIVE, &press, parts.lines.left + @divTrunc(parts.line_height, 2), second, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE, ib.SendMessage(browser, @ptrCast(&open_it)));
    var again = input(gc.GM_GOACTIVE, &press, x, third, &termination);
    _ = ib.SendMessage(browser, @ptrCast(&again));
    var let_go = input(gc.GM_HANDLEINPUT, &release, x, third, &termination);
    _ = ib.SendMessage(browser, @ptrCast(&let_go));
    try testing.expectEqual(@as(i32, 2), termination);
    try testing.expectEqual(@as(usize, 5), attr(ib, browser, lbr.LISTBROWSER_Total));
    try testing.expectEqual(@as(usize, parts.visible), attr(ib, browser, lbr.LISTBROWSER_Visible));

    // A press on the "Name" heading, let go on it: sorted by name.
    const heading_y = parts.heads.top + 1;
    var on_heading = input(gc.GM_GOACTIVE, &press, x, heading_y, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(browser, @ptrCast(&on_heading)));
    var off_heading = input(gc.GM_HANDLEINPUT, &release, x, heading_y, &termination);
    _ = ib.SendMessage(browser, @ptrCast(&off_heading));
    try testing.expectEqualStrings("alpha a b mid zeta", namesOf(&rows, &names));
    try testing.expectEqual(@as(usize, 0), attr(ib, browser, lbr.LISTBROWSER_SortColumn));

    ib.DisposeObject(browser);
    lbr.freeRows(sys, &rows);
    ib.DisposeObject(listener);
    try testing.expect(ib.FreeClass(listener_class));
    _ = sys.RemLibrary(lib);
    try testing.expect(ib.FindClass(lbr.LISTBROWSER_CLASS) == null);
    _ = sys.RemLibrary(scroller_lib);
    ByTail.remove();
    try host_rom.intuition.tearDown(kib);
}

fn windowAttrOf(ib: *IntuitionBase, w: *intuition.Window, tag: utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(w, &ask);
    return value;
}

/// What intuition tells a gadget of a borderless window, whose room is
/// all of it; `dri` from the window's screen, which the caller frees.
fn infoOf(ib: *IntuitionBase, w: *intuition.Window, dri: *intuition.DrawInfo) classusr.GadgetInfo {
    const wn = intuition.windows;
    return .{
        .screen = @ptrFromInt(windowAttrOf(ib, w, wn.WA_Screen)),
        .window = w,
        .draw_info = dri,
        .rast_port = @ptrFromInt(windowAttrOf(ib, w, wn.WA_RastPort)),
        .layer = @ptrFromInt(windowAttrOf(ib, w, wn.WA_Layer)),
        .domain_left = 0,
        .domain_top = 0,
        .domain_width = @intCast(windowAttrOf(ib, w, wn.WA_Width)),
        .domain_height = @intCast(windowAttrOf(ib, w, wn.WA_Height)),
    };
}

test "clicktab.gadget: a press takes the tab under it at once, and the key steps them" {
    var heard = Heard{ .tag = ct.CLICKTAB_Current, .ib = undefined };
    var rig = try Rig.up(&clicktab.Library.resident_tag, &heard);
    const ib = rig.ib;

    // With no font to measure in, every tab is as wide as its two
    // margins, which is what makes the places below known.
    const names = [_:null]?[*:0]const u8{ "General", "Network", "About" };
    const tabs = ib.NewObjectTagList(null, ct.CLICKTAB_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 7 },
        .{ .tag = gc.GA_Key, .data = 't' },
        .{ .tag = ct.CLICKTAB_Labels, .data = @intFromPtr(&names) },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 3), attr(ib, tabs, ct.CLICKTAB_NumLabels));
    const width = gc.gadget(tabs).width;
    const tab = @divTrunc(width, 3);

    // A press on the middle tab puts it in front as it is pressed, and is
    // done with: nothing waits for the button to come up.
    var termination: i32 = -1;
    var down = input(gc.GM_GOACTIVE, &press, tab + 2, 2, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE | gc.GMR_VERIFY, ib.SendMessage(tabs, @ptrCast(&down)));
    try testing.expectEqual(@as(usize, 1), attr(ib, tabs, ct.CLICKTAB_Current));
    try testing.expectEqual(@as(i32, 1), termination);
    try testing.expectEqual(@as(?usize, 1), heard.value);
    try testing.expectEqual(@as(?usize, 7), heard.id);

    // The last one the same way.
    var again = input(gc.GM_GOACTIVE, &press, 2 * tab + 2, 2, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE | gc.GMR_VERIFY, ib.SendMessage(tabs, @ptrCast(&again)));
    try testing.expectEqual(@as(usize, 2), attr(ib, tabs, ct.CLICKTAB_Current));

    // The key takes the next tab, and the one before with Shift held.
    var step_on = keyed('t', 0, &termination);
    try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(tabs, @ptrCast(&step_on)));
    try testing.expectEqual(@as(usize, 0), attr(ib, tabs, ct.CLICKTAB_Current));
    try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(tabs, @ptrCast(&step_on)));
    try testing.expectEqual(@as(usize, 1), attr(ib, tabs, ct.CLICKTAB_Current));
    var step_back = keyed('t', ie.IEQUALIFIER_LSHIFT, &termination);
    try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(tabs, @ptrCast(&step_back)));
    try testing.expectEqual(@as(usize, 0), attr(ib, tabs, ct.CLICKTAB_Current));

    // A point past the last tab is not the gadget's.
    var hit = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = width + 4, .y = 2 } };
    try testing.expectEqual(@as(usize, 0), ib.SendMessage(tabs, @ptrCast(&hit)));

    ib.DisposeObject(tabs);
    try rig.down();
}

/// An image that keeps where, how big and in which state it was last asked
/// to draw itself as a frame.
const Asked = extern struct { left: i32 = 0, top: i32 = 0, width: i32 = 0, height: i32 = 0, times: u32 = 0, state: u32 = 0 };

fn askedDispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *classes.Class = @ptrCast(hook);
    const ib: *IntuitionBase = @ptrFromInt(cl.user_data);
    const msg: *classusr.Msg = @ptrCast(@alignCast(message.?));
    if (msg.method_id == intuition.imageclass.IM_DRAWFRAME) {
        const draw: *intuition.imageclass.ImpDraw = @ptrCast(@alignCast(msg));
        const asked = classes.instData(Asked, cl, @ptrCast(object.?));
        asked.* = .{ .left = draw.offset.x, .top = draw.offset.y, .width = draw.dimensions.width, .height = draw.dimensions.height, .times = asked.times + 1, .state = draw.state };
        return 1;
    }
    return ib.SendSuperMessage(cl, @ptrCast(object), msg);
}

fn domainOf(ib: *IntuitionBase, o: *Object, which: u32) gc.Box {
    var ask = gc.GpDomain{ .which = which };
    _ = ib.SendMessage(o, @ptrCast(&ask));
    return ask.domain;
}

test "toolbutton.gadget: a push button's code is 0; a toggle turns over, tells its target, and its state is the code" {
    var heard = Heard{ .tag = tbg.TOOLBUTTON_Checked, .ib = undefined };
    var rig = try Rig.up(&toolbutton.Library.resident_tag, &heard);
    const ib = rig.ib;

    const cut = ib.NewObjectTagList(null, tbg.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 4 },
        .{ .tag = gc.GA_Text, .data = @intFromPtr("Cut") },
        .{},
    }).?;
    // Something to say under gadget help, and without a hint, the label.
    try testing.expectEqual(@as(usize, 1), attr(ib, cut, gc.GA_GadgetHelp));
    try testing.expectEqualStrings("Cut", std.mem.span(@as([*:0]const u8, @ptrFromInt(attr(ib, cut, tbg.TOOLBUTTON_Hint)))));
    try testing.expectEqual(@as(usize, tbg.TBKIND_PUSH), attr(ib, cut, tbg.TOOLBUTTON_Kind));
    try testing.expect(gc.gadget(cut).flags & gc.GFLG_HOVERLOOK != 0);
    var termination: i32 = -1;
    var down = input(gc.GM_GOACTIVE, &press, 2, 2, &termination);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(cut, @ptrCast(&down)));
    // Held: selected, which is drawn pressed; let go over it: 0, and no
    // longer selected.
    try testing.expect(gc.gadget(cut).flags & gc.GFLG_SELECTED != 0);
    var up = input(gc.GM_HANDLEINPUT, &release, 2, 2, &termination);
    try testing.expect(ib.SendMessage(cut, @ptrCast(&up)) & gc.GMR_VERIFY != 0);
    try testing.expectEqual(@as(i32, 0), termination);
    try testing.expect(gc.gadget(cut).flags & gc.GFLG_SELECTED == 0);
    ib.DisposeObject(cut);

    const bold = ib.NewObjectTagList(null, tbg.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 7 },
        .{ .tag = gc.GA_Text, .data = @intFromPtr("_Bold") },
        .{ .tag = tbg.TOOLBUTTON_Kind, .data = tbg.TBKIND_TOGGLE },
        .{ .tag = tbg.TOOLBUTTON_Hint, .data = @intFromPtr("Make the text bold") },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    try testing.expectEqualStrings("Make the text bold", std.mem.span(@as([*:0]const u8, @ptrFromInt(attr(ib, bold, tbg.TOOLBUTTON_Hint)))));
    try testing.expectEqual(@as(usize, 0), attr(ib, bold, tbg.TOOLBUTTON_Checked));
    // Pressed: on at once, and the target told.
    termination = -1;
    _ = ib.SendMessage(bold, @ptrCast(&down));
    try testing.expectEqual(@as(usize, 1), attr(ib, bold, tbg.TOOLBUTTON_Checked));
    try testing.expectEqual(@as(?usize, 1), heard.value);
    try testing.expectEqual(@as(?usize, 7), heard.id);
    try testing.expect(ib.SendMessage(bold, @ptrCast(&up)) & gc.GMR_VERIFY != 0);
    try testing.expectEqual(@as(i32, 1), termination);
    // Its key, from the label's `_`, turns it off again.
    var typed = gc.GpKey{ .key = 'B', .termination = &termination };
    try testing.expect(ib.SendMessage(bold, @ptrCast(&typed)) & gc.GMKR_VERIFY != 0);
    try testing.expectEqual(@as(i32, 0), termination);
    try testing.expectEqual(@as(?usize, 0), heard.value);
    try testing.expectEqual(@as(usize, 0), attr(ib, bold, gc.GA_Selected));
    // Set and read.
    _ = ib.SetAttrsTagList(bold, &[_]TagItem{ .{ .tag = tbg.TOOLBUTTON_Checked, .data = 1 }, .{} });
    try testing.expectEqual(@as(usize, 1), attr(ib, bold, gc.GA_Selected));
    ib.DisposeObject(bold);
    try rig.down();
}

test "toolbutton.gadget: three sizes to the font, a large label in two lines, the picture drawn to the size" {
    var heard = Heard{ .tag = tbg.TOOLBUTTON_Checked, .ib = undefined };
    var rig = try Rig.up(&toolbutton.Library.resident_tag, &heard);
    const ib = rig.ib;
    const asked_class = ib.MakeClass(null, classusr.IMAGECLASS, null, @sizeOf(Asked)).?;
    asked_class.dispatcher.entry = &askedDispatch;
    asked_class.user_data = @intFromPtr(ib);
    const picture = ib.NewObjectTagList(asked_class, null, null).?;

    const button = ib.NewObjectTagList(null, tbg.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("Format Painter") },
        .{ .tag = tbg.TOOLBUTTON_Image, .data = @intFromPtr(picture) },
        .{ .tag = tbg.TOOLBUTTON_Size, .data = tbg.TBSIZE_SMALL },
        .{},
    }).?;
    const measure = sdk.gadgets.support.Measure.of(ib, gc.gadget(button), null);
    defer measure.done(ib);
    const whole = measure.width(ib, "Format Painter");
    const longer = measure.width(ib, "Painter");
    // For the 8-row font the small picture is 16, the large 32; the tool's
    // frame is four pixels of room at each side, two at the top and the
    // bottom.
    // Small: the picture alone, made that size without a size of its own.
    try testing.expectEqual(gc.Box{ .width = 24, .height = 20 }, domainOf(ib, button, gc.GDOMAIN_NOMINAL));
    try testing.expectEqual(@as(usize, 24), attr(ib, button, gc.GA_Width));
    try testing.expectEqual(gc.Box{ .width = 24, .height = 20 }, domainOf(ib, button, gc.GDOMAIN_MAXIMUM));
    // Medium: the label beside the picture, in one line; as wide as there
    // is room at the most.
    _ = ib.SetAttrsTagList(button, &[_]TagItem{ .{ .tag = tbg.TOOLBUTTON_Size, .data = tbg.TBSIZE_MEDIUM }, .{} });
    try testing.expectEqual(gc.Box{ .width = 16 + 4 + whole + 8, .height = 20 }, domainOf(ib, button, gc.GDOMAIN_NOMINAL));
    try testing.expectEqual(gc.GDOMAIN_UNLIMITED, domainOf(ib, button, gc.GDOMAIN_MAXIMUM).width);
    // Large: the label under the picture, broken at its space; two lines
    // high however long it is.
    _ = ib.SetAttrsTagList(button, &[_]TagItem{ .{ .tag = tbg.TOOLBUTTON_Size, .data = tbg.TBSIZE_LARGE }, .{} });
    try testing.expectEqual(gc.Box{ .width = @max(32, longer) + 8, .height = 32 + 2 + 16 + 4 }, domainOf(ib, button, gc.GDOMAIN_NOMINAL));
    try testing.expectEqual(@as(usize, @intCast(32 + 2 + 16 + 4)), attr(ib, button, gc.GA_Height));
    ib.DisposeObject(button);

    // Without a picture, the label is all there is, small or not; the `_`
    // of its key takes no room.
    const plain = ib.NewObjectTagList(null, tbg.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("_Find") },
        .{ .tag = tbg.TOOLBUTTON_Size, .data = tbg.TBSIZE_SMALL },
        .{},
    }).?;
    try testing.expectEqual(gc.Box{ .width = measure.width(ib, "Find") + 8, .height = 8 + 4 }, domainOf(ib, plain, gc.GDOMAIN_NOMINAL));
    ib.DisposeObject(plain);

    // A label that changes, with room kept for the widest of them: as wide
    // for "3:58" as for "-3:16" or "-00:00", and made that wide. Measured
    // in a font the DrawInfo names, as on a screen.
    const graphics = sdk.graphics;
    const gb = rig.kib.graphics_base;
    const font = gb.OpenFont(&.{ .name = graphics.POSPAZNAME, .y_size = 8 }).?;
    var pens: [sdk.intuition.screens.NUMDRIPENS]graphics.Pen = @splat(0);
    var dri = sdk.intuition.screens.DrawInfo{ .pens = &pens, .font = font };
    var lengths: [3]*Object = undefined;
    const labels = [_][*:0]const u8{ "3:58", "3:58", "-00:00" };
    for (&lengths, labels, 0..) |*length, words, i| length.* = ib.NewObjectTagList(null, tbg.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_DrawInfo, .data = @intFromPtr(&dri) },
        .{ .tag = gc.GA_Text, .data = @intFromPtr(words) },
        .{ .tag = if (i == 1) tbg.TOOLBUTTON_RoomFor else utility.TAG_IGNORE, .data = @intFromPtr("-00:00") },
        .{ .tag = tbg.TOOLBUTTON_Size, .data = tbg.TBSIZE_SMALL },
        .{},
    }).?;
    const kept = domainOf(ib, lengths[2], gc.GDOMAIN_NOMINAL).width;
    try testing.expect(domainOf(ib, lengths[0], gc.GDOMAIN_NOMINAL).width < kept);
    try testing.expectEqual(kept, domainOf(ib, lengths[1], gc.GDOMAIN_NOMINAL).width);
    _ = ib.SetAttrsTagList(lengths[1], &[_]TagItem{ .{ .tag = gc.GA_Text, .data = @intFromPtr("-3:16") }, .{} });
    try testing.expectEqual(kept, domainOf(ib, lengths[1], gc.GDOMAIN_NOMINAL).width);
    try testing.expectEqual(@as(usize, @intCast(kept)), attr(ib, lengths[1], gc.GA_Width));
    for (lengths) |length| ib.DisposeObject(length);
    gb.CloseFont(font);

    // Drawn in a window: the picture asked for at the small size, in the
    // middle of a small button and at the left of a medium one.
    const display = try Display.up(rig.kib);
    const wn = intuition.windows;
    const small = ib.NewObjectTagList(null, tbg.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 2 },
        .{ .tag = gc.GA_Top, .data = 2 },
        .{ .tag = gc.GA_Width, .data = 30 },
        .{ .tag = gc.GA_Height, .data = 24 },
        .{ .tag = gc.GA_Text, .data = @intFromPtr("Cut") },
        .{ .tag = tbg.TOOLBUTTON_Image, .data = @intFromPtr(picture) },
        .{ .tag = tbg.TOOLBUTTON_Size, .data = tbg.TBSIZE_SMALL },
        .{},
    }).?;
    const w = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(small) },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{},
    }).?;
    ib.RefreshGList(small, w, 1);
    var asked = classes.instData(Asked, asked_class, picture);
    try testing.expectEqual(Asked{ .left = 2 + 7, .top = 2 + 4, .width = 16, .height = 16, .times = asked.times }, asked.*);
    _ = ib.SetAttrsTagList(small, &[_]TagItem{ .{ .tag = tbg.TOOLBUTTON_Size, .data = tbg.TBSIZE_MEDIUM }, .{} });
    ib.RefreshGList(small, w, 1);
    asked = classes.instData(Asked, asked_class, picture);
    try testing.expectEqual(Asked{ .left = 2 + 4, .top = 2 + 4, .width = 16, .height = 16, .times = asked.times }, asked.*);
    // Made with a size of its own, it keeps it.
    try testing.expectEqual(@as(usize, 30), attr(ib, small, gc.GA_Width));

    const screen: *intuition.Screen = @ptrFromInt(windowAttrOf(ib, w, wn.WA_Screen));
    ib.CloseWindow(w);
    try testing.expect(ib.CloseScreen(screen));
    display.down(rig.kib);
    ib.DisposeObject(small);
    ib.DisposeObject(picture);
    try testing.expect(ib.FreeClass(asked_class));
    try rig.down();
}

test "toolbutton.gadget: flat at rest; under the pointer and on, an edge round a ground of its own" {
    var heard = Heard{ .tag = tbg.TOOLBUTTON_Checked, .ib = undefined };
    var rig = try Rig.up(&toolbutton.Library.resident_tag, &heard);
    const ib = rig.ib;
    const display = try Display.up(rig.kib);
    const wn = intuition.windows;
    const button = ib.NewObjectTagList(null, tbg.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 4 },
        .{ .tag = gc.GA_Top, .data = 4 },
        .{ .tag = gc.GA_Width, .data = 30 },
        .{ .tag = gc.GA_Height, .data = 16 },
        .{ .tag = gc.GA_Text, .data = @intFromPtr("Wrap") },
        .{ .tag = tbg.TOOLBUTTON_Kind, .data = tbg.TBKIND_TOGGLE },
        .{},
    }).?;
    const w = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(button) },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{},
    }).?;
    const background = display.pixel(60, 36);
    // At rest: its left edge and a corner are the window's ground.
    ib.RefreshGList(button, w, 1);
    try testing.expectEqual(background, display.pixel(4, 12));
    try testing.expectEqual(background, display.pixel(33, 19));
    // Under the pointer: one colour all round, a ground of another inside
    // it (the row between the edge and the label), the round corner the
    // window's.
    gc.gadget(button).flags |= gc.GFLG_HOVERED;
    ib.RefreshGList(button, w, 1);
    const edge = display.pixel(4, 12);
    const ground = display.pixel(20, 5);
    try testing.expectEqual(edge, display.pixel(20, 19));
    try testing.expect(edge != background and ground != background and ground != edge);
    try testing.expectEqual(background, display.pixel(4, 4));
    // On: the same frame, a stronger edge and a ground of its own.
    gc.gadget(button).flags &= ~gc.GFLG_HOVERED;
    _ = ib.SetAttrsTagList(button, &[_]TagItem{ .{ .tag = tbg.TOOLBUTTON_Checked, .data = 1 }, .{} });
    ib.RefreshGList(button, w, 1);
    const strong = display.pixel(4, 12);
    try testing.expectEqual(strong, display.pixel(20, 19));
    try testing.expect(strong != edge and strong != background);
    const on = display.pixel(20, 5);
    try testing.expect(on != ground and on != background and on != strong);

    const screen: *intuition.Screen = @ptrFromInt(windowAttrOf(ib, w, wn.WA_Screen));
    ib.CloseWindow(w);
    try testing.expect(ib.CloseScreen(screen));
    display.down(rig.kib);
    ib.DisposeObject(button);
    try rig.down();
}

test "toolbutton.gadget: disabled, its picture is drawn disabled and its label faded, with no ghost over it" {
    var heard = Heard{ .tag = tbg.TOOLBUTTON_Checked, .ib = undefined };
    var rig = try Rig.up(&toolbutton.Library.resident_tag, &heard);
    const ib = rig.ib;
    const display = try Display.up(rig.kib);
    const wn = intuition.windows;
    const asked_class = ib.MakeClass(null, classusr.IMAGECLASS, null, @sizeOf(Asked)).?;
    asked_class.dispatcher.entry = &askedDispatch;
    asked_class.user_data = @intFromPtr(ib);
    const picture = ib.NewObjectTagList(asked_class, null, null).?;
    const button = ib.NewObjectTagList(null, tbg.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 4 },
        .{ .tag = gc.GA_Top, .data = 4 },
        .{ .tag = gc.GA_Width, .data = 40 },
        .{ .tag = gc.GA_Height, .data = 20 },
        .{ .tag = gc.GA_Text, .data = @intFromPtr("W") },
        .{ .tag = tbg.TOOLBUTTON_Image, .data = @intFromPtr(picture) },
        .{},
    }).?;
    const w = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(button) },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{},
    }).?;
    const background = display.pixel(60, 36);
    const asked = classes.instData(Asked, asked_class, picture);

    // Enabled: the picture drawn as it is, the label in the text pen - the
    // only colour in the box but the ground, the picture drawing nothing.
    ib.RefreshGList(button, w, 1);
    try testing.expectEqual(@as(u32, intuition.imageclass.IDS_NORMAL), asked.state);
    var ink: ?@TypeOf(background) = null;
    var inked: usize = 0;
    for (4..44) |x| for (4..24) |y| {
        const at = display.pixel(@intCast(x), @intCast(y));
        if (at == background) continue;
        ink = at;
        inked += 1;
    };
    try testing.expect(ink != null and inked > 0);

    // Disabled: the picture asked to draw itself disabled, the same
    // letter in a colour of its own, and nothing else - no ghost.
    _ = ib.SetAttrsTagList(button, &[_]TagItem{ .{ .tag = gc.GA_Disabled, .data = 1 }, .{} });
    ib.RefreshGList(button, w, 1);
    try testing.expectEqual(@as(u32, intuition.imageclass.IDS_DISABLED), asked.state);
    var faded: usize = 0;
    for (4..44) |x| for (4..24) |y| {
        const at = display.pixel(@intCast(x), @intCast(y));
        if (at == background) continue;
        try testing.expect(at != ink.?);
        faded += 1;
    };
    try testing.expectEqual(inked, faded);

    const screen: *intuition.Screen = @ptrFromInt(windowAttrOf(ib, w, wn.WA_Screen));
    ib.CloseWindow(w);
    try testing.expect(ib.CloseScreen(screen));
    display.down(rig.kib);
    ib.DisposeObject(button);
    ib.DisposeObject(picture);
    try testing.expect(ib.FreeClass(asked_class));
    try rig.down();
}

test "toolbutton.gadget: the mark of a list, a split button's own command, what a target drops down, and a size asked about without being set" {
    var heard = Heard{ .tag = tbg.TOOLBUTTON_Dropped, .ib = undefined };
    var rig = try Rig.up(&toolbutton.Library.resident_tag, &heard);
    const ib = rig.ib;
    const sides = [_:null]?[*:0]const u8{ "Left", "Centre", "Right" };

    const push = ib.NewObjectTagList(null, tbg.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("_Align") },
        .{},
    }).?;
    const align_list = ib.NewObjectTagList(null, tbg.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("_Align") },
        .{ .tag = tbg.TOOLBUTTON_Kind, .data = tbg.TBKIND_DROPDOWN },
        .{ .tag = tbg.TOOLBUTTON_Labels, .data = @intFromPtr(&sides) },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, tbg.TBKIND_DROPDOWN), attr(ib, align_list, tbg.TOOLBUTTON_Kind));
    try testing.expectEqual(@intFromPtr(&sides), attr(ib, align_list, tbg.TOOLBUTTON_Labels));
    // The mark after the label, and the room before it, make it wider.
    const plain = domainOf(ib, push, gc.GDOMAIN_NOMINAL);
    const marked = domainOf(ib, align_list, gc.GDOMAIN_NOMINAL);
    try testing.expectEqual(plain.width + 3 + 9, marked.width);
    try testing.expectEqual(plain.height, marked.height);
    // Its key does nothing - the list is the pointer's - and without a
    // window to drop it down on, a press lets go.
    var termination: i32 = 99;
    var typed = keyed('a', 0, &termination);
    try testing.expectEqual(gc.GMKR_NOTHING, ib.SendMessage(align_list, @ptrCast(&typed)));
    var down = input(gc.GM_GOACTIVE, &press, 2, 2, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE, ib.SendMessage(align_list, @ptrCast(&down)));
    try testing.expect(gc.gadget(align_list).flags & gc.GFLG_SELECTED == 0);

    // A split button: the label is the command, its code TBCODE_MAIN, and
    // so is the key; the mark at the right end is the list's.
    const paste = ib.NewObjectTagList(null, tbg.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("_Align") },
        .{ .tag = tbg.TOOLBUTTON_Kind, .data = tbg.TBKIND_SPLIT },
        .{ .tag = tbg.TOOLBUTTON_Labels, .data = @intFromPtr(&sides) },
        .{},
    }).?;
    try testing.expectEqual(marked, domainOf(ib, paste, gc.GDOMAIN_NOMINAL));
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(paste, @ptrCast(&down)));
    var up = input(gc.GM_HANDLEINPUT, &release, 2, 2, &termination);
    try testing.expect(ib.SendMessage(paste, @ptrCast(&up)) & gc.GMR_VERIFY != 0);
    try testing.expectEqual(tbg.TBCODE_MAIN, termination);
    termination = 99;
    try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(paste, @ptrCast(&typed)));
    try testing.expectEqual(tbg.TBCODE_MAIN, termination);
    var on_mark = input(gc.GM_GOACTIVE, &press, marked.width - 3, 2, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE, ib.SendMessage(paste, @ptrCast(&on_mark)));
    ib.DisposeObject(paste);

    // Without labels, a drop-down drops what its target puts up: the press
    // marks it dropped, drawn pressed, and tells the target which it is;
    // the window hears nothing. The target sets it back.
    const colours = ib.NewObjectTagList(null, tbg.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 9 },
        .{ .tag = gc.GA_Text, .data = @intFromPtr("Colour") },
        .{ .tag = tbg.TOOLBUTTON_Kind, .data = tbg.TBKIND_DROPDOWN },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{},
    }).?;
    try testing.expectEqual(gc.GMR_NOREUSE, ib.SendMessage(colours, @ptrCast(&down)));
    try testing.expectEqual(@as(?usize, 1), heard.value);
    try testing.expectEqual(@as(?usize, 9), heard.id);
    try testing.expectEqual(@as(usize, 1), attr(ib, colours, tbg.TOOLBUTTON_Dropped));
    try testing.expect(gc.gadget(colours).flags & gc.GFLG_SELECTED != 0);
    _ = ib.SetAttrsTagList(colours, &[_]TagItem{ .{ .tag = tbg.TOOLBUTTON_Dropped, .data = 0 }, .{} });
    try testing.expectEqual(@as(usize, 0), attr(ib, colours, tbg.TOOLBUTTON_Dropped));
    try testing.expect(gc.gadget(colours).flags & gc.GFLG_SELECTED == 0);
    ib.DisposeObject(colours);
    ib.DisposeObject(align_list);
    ib.DisposeObject(push);

    // Asked about another size - as a ribbon does that makes its groups
    // smaller - a medium button answers for that one, and is still medium.
    const asked_class = ib.MakeClass(null, classusr.IMAGECLASS, null, @sizeOf(Asked)).?;
    asked_class.dispatcher.entry = &askedDispatch;
    asked_class.user_data = @intFromPtr(ib);
    const picture = ib.NewObjectTagList(asked_class, null, null).?;
    const button = ib.NewObjectTagList(null, tbg.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("Format Painter") },
        .{ .tag = tbg.TOOLBUTTON_Image, .data = @intFromPtr(picture) },
        .{},
    }).?;
    const measure = sdk.gadgets.support.Measure.of(ib, gc.gadget(button), null);
    defer measure.done(ib);
    const small = [_]TagItem{ .{ .tag = tbg.TOOLBUTTON_Size, .data = tbg.TBSIZE_SMALL }, .{} };
    const large = [_]TagItem{ .{ .tag = tbg.TOOLBUTTON_Size, .data = tbg.TBSIZE_LARGE }, .{} };
    var ask = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL, .attrs = &small };
    _ = ib.SendMessage(button, @ptrCast(&ask));
    try testing.expectEqual(gc.Box{ .width = 24, .height = 20 }, ask.domain);
    ask = .{ .which = gc.GDOMAIN_MAXIMUM, .attrs = &small };
    _ = ib.SendMessage(button, @ptrCast(&ask));
    try testing.expectEqual(@as(i32, 24), ask.domain.width);
    ask = .{ .which = gc.GDOMAIN_NOMINAL, .attrs = &large };
    _ = ib.SendMessage(button, @ptrCast(&ask));
    try testing.expectEqual(gc.Box{ .width = @max(32, measure.width(ib, "Painter")) + 8, .height = 32 + 2 + 16 + 4 }, ask.domain);
    try testing.expectEqual(@as(usize, tbg.TBSIZE_MEDIUM), attr(ib, button, tbg.TOOLBUTTON_Size));
    try testing.expectEqual(gc.GDOMAIN_UNLIMITED, domainOf(ib, button, gc.GDOMAIN_MAXIMUM).width);
    ib.DisposeObject(button);
    ib.DisposeObject(picture);
    try testing.expect(ib.FreeClass(asked_class));
    try rig.down();
}

test "toolbutton.gadget: a list dropped down under it while held or left open; the label let go over is the code" {
    var heard = Heard{ .tag = tbg.TOOLBUTTON_Checked, .ib = undefined };
    var rig = try Rig.up(&toolbutton.Library.resident_tag, &heard);
    const ib = rig.ib;
    const display = try Display.up(rig.kib);
    const wn = intuition.windows;
    const sides = [_:null]?[*:0]const u8{ "Left", "Centre", "Right" };
    const button = ib.NewObjectTagList(null, tbg.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 2 },
        .{ .tag = gc.GA_Top, .data = 2 },
        .{ .tag = gc.GA_Text, .data = @intFromPtr("_Align") },
        .{ .tag = tbg.TOOLBUTTON_Kind, .data = tbg.TBKIND_DROPDOWN },
        .{ .tag = tbg.TOOLBUTTON_Labels, .data = @intFromPtr(&sides) },
        .{},
    }).?;
    const w = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(button) },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{},
    }).?;
    const screen: *intuition.Screen = @ptrFromInt(windowAttrOf(ib, w, wn.WA_Screen));
    const dri = ib.GetScreenDrawInfo(screen);
    var info = infoOf(ib, w, dri);
    ib.RefreshGList(button, w, 1);
    const height: i32 = @intCast(attr(ib, button, gc.GA_Height));
    // Below the button, on the panel's first label: its frame is no more
    // than four pixels and a line of the font eight.
    const first_line = 2 + height + 5 - 2;
    // The panel's edge, a button's, is just under the button.
    const edge: usize = @intCast(2 + height);
    const under_panel = display.pixel(20, edge);

    // Held: the list under it, the button drawn pressed; let go over the
    // first label, that is the code.
    var termination: i32 = 99;
    var down = input(gc.GM_GOACTIVE, &press, 2, 2, &termination);
    down.gadget_info = &info;
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(button, @ptrCast(&down)));
    try testing.expect(gc.gadget(button).flags & gc.GFLG_SELECTED != 0);
    try testing.expect(display.pixel(20, edge) != under_panel);
    var over_first = input(gc.GM_HANDLEINPUT, &release, 8, first_line, &termination);
    over_first.gadget_info = &info;
    try testing.expectEqual(gc.GMR_NOREUSE | gc.GMR_VERIFY, ib.SendMessage(button, @ptrCast(&over_first)));
    try testing.expectEqual(@as(i32, 0), termination);
    try testing.expect(gc.gadget(button).flags & gc.GFLG_SELECTED == 0);
    try testing.expectEqual(under_panel, display.pixel(20, edge));

    // Let go over the button, the list stands open; a press beside it is
    // nothing taken.
    termination = 99;
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(button, @ptrCast(&down)));
    var on_button = input(gc.GM_HANDLEINPUT, &release, 2, 2, &termination);
    on_button.gadget_info = &info;
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(button, @ptrCast(&on_button)));
    var beside = input(gc.GM_HANDLEINPUT, &press, 60, -1, &termination);
    beside.gadget_info = &info;
    try testing.expectEqual(gc.GMR_NOREUSE, ib.SendMessage(button, @ptrCast(&beside)));
    try testing.expectEqual(@as(i32, 99), termination);
    try testing.expect(gc.gadget(button).flags & gc.GFLG_SELECTED == 0);

    // Made inactive with the list down - another window, the menu button -
    // it goes, and the button is at rest.
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(button, @ptrCast(&down)));
    var gone = gc.GpGoInactive{ .gadget_info = &info, .abort = 1 };
    _ = ib.SendMessage(button, @ptrCast(&gone));
    try testing.expect(gc.gadget(button).flags & gc.GFLG_SELECTED == 0);
    try testing.expectEqual(under_panel, display.pixel(20, edge));

    ib.FreeScreenDrawInfo(screen, dri);
    ib.CloseWindow(w);
    try testing.expect(ib.CloseScreen(screen));
    display.down(rig.kib);
    ib.DisposeObject(button);
    try rig.down();
}

test "toolbutton.gadget: a list that fits under it drops down, though there is more room over it" {
    var heard = Heard{ .tag = tbg.TOOLBUTTON_Checked, .ib = undefined };
    var rig = try Rig.up(&toolbutton.Library.resident_tag, &heard);
    const ib = rig.ib;
    const display = try Display.up(rig.kib);
    const wn = intuition.windows;
    const only = [_:null]?[*:0]const u8{"Only"};
    const button = ib.NewObjectTagList(null, tbg.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 2 },
        .{ .tag = gc.GA_Text, .data = @intFromPtr("_Align") },
        .{ .tag = tbg.TOOLBUTTON_Kind, .data = tbg.TBKIND_DROPDOWN },
        .{ .tag = tbg.TOOLBUTTON_Labels, .data = @intFromPtr(&only) },
        .{},
    }).?;
    // Low on the screen, 40 high: a line of eight and a frame of no more
    // than four fit under it, and over it there is more room than that.
    const height: i32 = @intCast(attr(ib, button, gc.GA_Height));
    const top = 40 - height - 12;
    try testing.expect(top > 12);
    _ = ib.SetAttrsTagList(button, &[_]TagItem{ .{ .tag = gc.GA_Top, .data = @intCast(top) }, .{} });
    const w = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(button) },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{},
    }).?;
    const screen: *intuition.Screen = @ptrFromInt(windowAttrOf(ib, w, wn.WA_Screen));
    const dri = ib.GetScreenDrawInfo(screen);
    var info = infoOf(ib, w, dri);
    ib.RefreshGList(button, w, 1);
    const under: usize = @intCast(top + height);
    const over: usize = @intCast(top - 1);
    const below_it = display.pixel(20, under);
    const above_it = display.pixel(20, over);

    var termination: i32 = 99;
    var down = input(gc.GM_GOACTIVE, &press, 2, 2, &termination);
    down.gadget_info = &info;
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(button, @ptrCast(&down)));
    try testing.expect(display.pixel(20, under) != below_it);
    try testing.expectEqual(above_it, display.pixel(20, over));
    var gone = gc.GpGoInactive{ .gadget_info = &info, .abort = 1 };
    _ = ib.SendMessage(button, @ptrCast(&gone));
    try testing.expectEqual(below_it, display.pixel(20, under));

    ib.FreeScreenDrawInfo(screen, dri);
    ib.CloseWindow(w);
    try testing.expect(ib.CloseScreen(screen));
    display.down(rig.kib);
    ib.DisposeObject(button);
    try rig.down();
}

test "ribbon.gadget: a large tool button the whole height, the rest in columns of three, each as wide as its widest" {
    // A large button; two medium ones that can be wider and a small one
    // that cannot, three to a column; one more small one in a column of
    // its own.
    const entries = [_]ribbon.Entry{
        .{ .width = 40, .height = 60, .most = 40, .large = true },
        .{ .width = 50, .height = 18, .most = gc.GDOMAIN_UNLIMITED },
        .{ .width = 70, .height = 18, .most = gc.GDOMAIN_UNLIMITED },
        .{ .width = 20, .height = 18, .most = 20 },
        .{ .width = 24, .height = 18, .most = 24 },
    };
    // Three rows of 18 and the room between them are 58: the large button
    // is taller, and the room is its height.
    try testing.expectEqual(@as(i32, 3 * 18 + 2 * ribbon.row_gap), ribbon.roomHeight(30, 18));
    const room = ribbon.roomHeight(60, 18);
    try testing.expectEqual(@as(i32, 60), room);
    var spots: [entries.len]gc.Box = undefined;
    const width = ribbon.arrange(&entries, room, &spots);
    const gap = ribbon.column_gap;
    try testing.expectEqual(gc.Box{ .left = 0, .top = 0, .width = 40, .height = 60 }, spots[0]);
    // Each in the middle of its third of the height - 10, 30 and 50 - the
    // medium ones as wide as the column, the small one as it is.
    try testing.expectEqual(gc.Box{ .left = 40 + gap, .top = 1, .width = 70, .height = 18 }, spots[1]);
    try testing.expectEqual(gc.Box{ .left = 40 + gap, .top = 21, .width = 70, .height = 18 }, spots[2]);
    try testing.expectEqual(gc.Box{ .left = 40 + gap, .top = 41, .width = 20, .height = 18 }, spots[3]);
    // Alone in its column: in the middle of the whole height.
    try testing.expectEqual(gc.Box{ .left = 40 + gap + 70 + gap, .top = 21, .width = 24, .height = 18 }, spots[4]);
    try testing.expectEqual(@as(i32, 40 + gap + 70 + gap + 24), width);
}

test "ribbon.gadget: groups made smaller a step at a time, the rightmost first, until they fit; folded and still too wide, those that fit" {
    // What a tool button is shown at on each level.
    const L: u8 = @intCast(tbg.TBSIZE_LARGE);
    const M: u8 = @intCast(tbg.TBSIZE_MEDIUM);
    const S: u8 = @intCast(tbg.TBSIZE_SMALL);
    try testing.expectEqual(L, ribbon.sizeAt(0, L));
    try testing.expectEqual(M, ribbon.sizeAt(1, L));
    try testing.expectEqual(S, ribbon.sizeAt(1, S));
    try testing.expectEqual(S, ribbon.sizeAt(2, L));
    try testing.expectEqual(M, ribbon.sizeAt(ribbon.level_folded, M));
    try testing.expectEqual(ribbon.not_tool, ribbon.sizeAt(1, ribbon.not_tool));

    // Three groups 100 wide, 10 between them: 320. The middle one saves
    // nothing at the first step.
    const widths = [_][ribbon.levels]i32{ .{ 100, 80, 60, 40 }, .{ 100, 100, 70, 40 }, .{ 100, 80, 60, 40 } };
    const even = [_]u32{ 0, 0, 0 };
    var out: [3]u32 = undefined;
    try testing.expectEqual(@as(usize, 3), ribbon.reduce(&widths, &even, 320, 10, &out));
    try testing.expectEqual([3]u32{ 0, 0, 0 }, out);
    // 20 too wide: the rightmost takes the first step, and that is enough.
    try testing.expectEqual(@as(usize, 3), ribbon.reduce(&widths, &even, 300, 10, &out));
    try testing.expectEqual([3]u32{ 0, 0, 1 }, out);
    // 50 too wide: the first step round all three - the middle one has
    // nothing to give - then the second from the right again.
    try testing.expectEqual(@as(usize, 3), ribbon.reduce(&widths, &even, 270, 10, &out));
    try testing.expectEqual([3]u32{ 1, 0, 2 }, out);
    // The order given goes first: the first group made smaller instead.
    const first_goes = [_]u32{ 5, 0, 0 };
    try testing.expectEqual(@as(usize, 3), ribbon.reduce(&widths, &first_goes, 300, 10, &out));
    try testing.expectEqual([3]u32{ 1, 0, 0 }, out);
    // All folded is 140: in 100 the first two fit.
    try testing.expectEqual(@as(usize, 2), ribbon.reduce(&widths, &even, 100, 10, &out));
    try testing.expectEqual([3]u32{ 3, 3, 3 }, out);
}

fn ribbonTool(ib: *IntuitionBase, id: usize, label: [*:0]const u8, size: u32) *Object {
    return ib.NewObjectTagList(null, tbg.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_Text, .data = @intFromPtr(label) },
        .{ .tag = tbg.TOOLBUTTON_Size, .data = size },
        .{},
    }).?;
}

/// The class libraries ribbon.gadget opens: its folded groups' buttons
/// and its launchers' pictures.
const ribbon_needs = [_]*const exec.Resident{ &toolbutton.Library.resident_tag, &command_image.Library.resident_tag };

test "ribbon.gadget: the groups of the tab in front that fit are its members, below the row; a tab is the ribbon's to press, and its key and the wheel turn to it" {
    var heard = Heard{ .tag = rbn.RIBBON_Current, .ib = undefined };
    var rig = try Rig.upAfter(&ribbon.Library.resident_tag, &heard, &ribbon_needs);
    const ib = rig.ib;
    // The window first, so that there is a screen and its font to measure
    // in. The ribbon is larger than the display: what lies outside the
    // window is not drawn, and is laid out and pressed all the same.
    const display = try Display.up(rig.kib);
    const wn = intuition.windows;
    const w = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{},
    }).?;

    // Home: a large button and two medium ones, then a group of one wide
    // button; Insert: a framed button, as any gadget can be an entry.
    const paste = ribbonTool(ib, 10, "_Paste", tbg.TBSIZE_LARGE);
    const cut = ribbonTool(ib, 11, "Cu_t", tbg.TBSIZE_MEDIUM);
    const copy = ribbonTool(ib, 12, "_Copy", tbg.TBSIZE_MEDIUM);
    const bold = ribbonTool(ib, 13, "_Bold letters, as wide as a group gets", tbg.TBSIZE_MEDIUM);
    const sum = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("Sum") },
        .{ .tag = gc.GA_ID, .data = 20 },
        .{ .tag = gc.GA_Key, .data = 's' },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    }).?;
    const clipboard = [_:null]?*Object{ paste, cut, copy };
    const font = [_:null]?*Object{bold};
    const data = [_:null]?*Object{sum};
    const home = [_]rbn.RibbonGroup{ .{ .label = "Clipboard", .items = &clipboard }, .{ .label = "Font", .items = &font }, .{} };
    const insert = [_]rbn.RibbonGroup{ .{ .label = "Data", .items = &data }, .{} };
    const tabs = [_]rbn.RibbonTab{ .{ .label = "_Home", .groups = &home }, .{ .label = "I_nsert", .groups = &insert }, .{} };
    const bar = ib.NewObjectTagList(null, rbn.RIBBON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 7 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{ .tag = rbn.RIBBON_Tabs, .data = @intFromPtr(&tabs) },
        .{},
    }).?;
    try testing.expectEqual(@as(usize, 2), attr(ib, bar, rbn.RIBBON_NumTabs));
    try testing.expectEqual(@as(usize, 0), attr(ib, bar, rbn.RIBBON_Current));

    // Made the size it looks right at, as tall with either tab in front.
    // At the least it is narrower: as wide as the row of tabs, or the
    // narrowest any tab's first group gets.
    const looks = domainOf(ib, bar, gc.GDOMAIN_NOMINAL);
    const least = domainOf(ib, bar, gc.GDOMAIN_MINIMUM);
    try testing.expectEqual(@as(usize, @intCast(looks.width)), attr(ib, bar, gc.GA_Width));
    try testing.expectEqual(@as(usize, @intCast(looks.height)), attr(ib, bar, gc.GA_Height));
    try testing.expectEqual(looks.height, least.height);
    try testing.expect(least.width < looks.width);
    _ = ib.SetAttrsTagList(bar, &[_]TagItem{ .{ .tag = rbn.RIBBON_Current, .data = 1 }, .{} });
    try testing.expectEqual(looks, domainOf(ib, bar, gc.GDOMAIN_NOMINAL));
    _ = ib.SetAttrsTagList(bar, &[_]TagItem{ .{ .tag = rbn.RIBBON_Current, .data = 0 }, .{} });

    // Put in the window and laid out there, as wide as it looks right.
    _ = ib.AddGList(w, bar, -1, 1);
    // The large button stands the whole room high, below the row; the
    // medium ones in a column beside it, as wide as each other and inside
    // its height.
    const p = gc.gadget(paste).*;
    const c = gc.gadget(cut).*;
    const y = gc.gadget(copy).*;
    try testing.expect(p.top > 8);
    try testing.expect(p.height > 2 * c.height);
    try testing.expectEqual(c.left, y.left);
    try testing.expectEqual(c.width, y.width);
    try testing.expect(c.left > p.left + p.width);
    try testing.expect(c.top >= p.top and y.top + y.height <= p.top + p.height);
    try testing.expect(c.top + c.height <= y.top);

    // Home's entries are the members: their keys work; Insert's do not.
    var termination: i32 = -1;
    var key_p = keyed('p', 0, &termination);
    var key_b = keyed('b', 0, &termination);
    var key_s = keyed('s', 0, &termination);
    try testing.expect(ib.SendMessage(bar, @ptrCast(&key_p)) != gc.GMKR_NOTHING);
    try testing.expect(ib.SendMessage(bar, @ptrCast(&key_b)) != gc.GMKR_NOTHING);
    try testing.expectEqual(gc.GMKR_NOTHING, ib.SendMessage(bar, @ptrCast(&key_s)));

    // A point over Cut is Cut's; along the row, only the tabs are the
    // ribbon's. The second tab is where the second run of them starts.
    var over_cut = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = c.left + 2, .y = c.top + 2 } };
    try testing.expectEqual(gc.GMR_GADGETHIT, ib.SendMessage(bar, @ptrCast(&over_cut)));
    var second: i32 = -1;
    var runs: u32 = 0;
    var was = false;
    var x: i32 = 0;
    while (x < least.width) : (x += 1) {
        var along = gc.GpHitTest{ .gadget_info = null, .mouse = .{ .x = x, .y = 3 } };
        const is = ib.SendMessage(bar, @ptrCast(&along)) == gc.GMR_GADGETHIT;
        if (is and !was) {
            runs += 1;
            if (runs == 2) {
                second = x;
                break;
            }
        }
        was = is;
    }
    try testing.expect(second > 0);

    // A press on it turns to Insert at once and is done with: the tab's
    // number is the code, and the target hears it with the ribbon's ID.
    termination = -1;
    var down = input(gc.GM_GOACTIVE, &press, second + 1, 3, &termination);
    try testing.expectEqual(gc.GMR_NOREUSE | gc.GMR_VERIFY, ib.SendMessage(bar, @ptrCast(&down)));
    try testing.expectEqual(@as(i32, 1), termination);
    try testing.expectEqual(@as(usize, 1), attr(ib, bar, rbn.RIBBON_Current));
    try testing.expectEqual(@as(?usize, 1), heard.value);
    try testing.expectEqual(@as(?usize, 7), heard.id);
    var done = gc.GpGoInactive{ .gadget_info = null, .abort = 0 };
    _ = ib.SendMessage(bar, @ptrCast(&done));
    // Insert's entries are the members now.
    try testing.expect(ib.SendMessage(bar, @ptrCast(&key_s)) != gc.GMKR_NOTHING);
    try testing.expectEqual(gc.GMKR_NOTHING, ib.SendMessage(bar, @ptrCast(&key_p)));

    // The wheel over the row: up, back to Home; up again, nothing before
    // the first. Over the page it is the page's.
    var code: i32 = -1;
    var wheel_up = gc.GpWheel{ .mouse = .{ .x = 2, .y = 3 }, .down = -1, .termination = &code };
    try testing.expectEqual(gc.GMWR_VERIFY, ib.SendMessage(bar, @ptrCast(&wheel_up)));
    try testing.expectEqual(@as(i32, 0), code);
    try testing.expectEqual(gc.GMWR_TAKEN, ib.SendMessage(bar, @ptrCast(&wheel_up)));
    try testing.expectEqual(@as(usize, 0), attr(ib, bar, rbn.RIBBON_Current));

    // The key a tab's name marks turns to it, and is the ribbon's.
    termination = -1;
    var key_n = keyed('n', 0, &termination);
    try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(bar, @ptrCast(&key_n)));
    try testing.expectEqual(@as(i32, 1), termination);
    try testing.expectEqual(@as(usize, 1), attr(ib, bar, rbn.RIBBON_Current));

    // Set in the window: Home put where it was and drawn.
    _ = ib.SetGadgetAttrsTagList(bar, w, &[_]TagItem{ .{ .tag = rbn.RIBBON_Current, .data = 0 }, .{} });
    try testing.expectEqual(p.top, gc.gadget(paste).top);
    try testing.expectEqual(c.left, gc.gadget(cut).left);
    ib.RefreshGList(bar, w, 1);

    _ = ib.RemoveGList(w, bar, 1);
    const screen: *intuition.Screen = @ptrFromInt(windowAttrOf(ib, w, wn.WA_Screen));
    ib.CloseWindow(w);
    try testing.expect(ib.CloseScreen(screen));
    display.down(rig.kib);
    // Every entry goes with it, of either tab, member or not, and every
    // button it made: the tool buttons' class has no objects left, so its
    // library goes after the ribbon's.
    ib.DisposeObject(bar);
    try rig.down();
}

fn ribbonDomain(ib: *IntuitionBase, o: *Object, info: *classusr.GadgetInfo, which: u32) gc.Box {
    var ask = gc.GpDomain{ .gadget_info = info, .which = which };
    _ = ib.SendMessage(o, @ptrCast(&ask));
    return ask.domain;
}

fn ribbonLayout(ib: *IntuitionBase, o: *Object, info: *classusr.GadgetInfo, width: i32) void {
    _ = ib.SetAttrsTagList(o, &[_]TagItem{ .{ .tag = gc.GA_Width, .data = @intCast(width) }, .{} });
    var lay = gc.GpLayout{ .gadget_info = info, .initial = 0 };
    _ = ib.SendMessage(o, @ptrCast(&lay));
}

test "ribbon.gadget: the tabs the row has no room for are behind a », which drops them down; the tab in front stays in the row" {
    var heard = Heard{ .tag = rbn.RIBBON_Current, .ib = undefined };
    var rig = try Rig.upAfter(&ribbon.Library.resident_tag, &heard, &ribbon_needs);
    const ib = rig.ib;
    // The ribbon is larger than the display, as in the tests before; the
    // list the » drops down is kept on the screen.
    const display = try Display.up(rig.kib);
    const wn = intuition.windows;
    const w = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{},
    }).?;
    const screen: *intuition.Screen = @ptrFromInt(windowAttrOf(ib, w, wn.WA_Screen));
    const dri = ib.GetScreenDrawInfo(screen);
    var info = infoOf(ib, w, dri);

    // Five tabs of a small button each, the last contextual.
    var tools: [5]*Object = undefined;
    var items: [5][1:null]?*Object = undefined;
    var groups: [5][2]rbn.RibbonGroup = undefined;
    const names = [_][*:0]const u8{ "_Home", "_Insert", "_View", "_Data", "T_able" };
    const plain = [_][]const u8{ "Home", "Insert", "View", "Data", "Table" };
    var tabs: [6]rbn.RibbonTab = undefined;
    for (0..5) |i| {
        tools[i] = ribbonTool(ib, 10 + i, names[i], tbg.TBSIZE_SMALL);
        items[i] = .{tools[i]};
        groups[i] = .{ .{ .label = "Group", .items = &items[i] }, .{} };
        tabs[i] = .{ .label = names[i], .groups = &groups[i] };
    }
    tabs[4].id = 7;
    tabs[4].contextual = 1;
    tabs[5] = .{};
    const bar = ib.NewObjectTagList(null, rbn.RIBBON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 3 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{ .tag = rbn.RIBBON_Tabs, .data = @intFromPtr(&tabs) },
        .{},
    }).?;
    const own = classes.instData(ribbon.Data, ib.FindClass(rbn.RIBBON_CLASS).?, bar);
    _ = ib.AddGList(w, bar, -1, 1);

    // As wide as it looks right, every tab stands in the row and there is
    // no »: just before the mark is the row's end.
    const looks = ribbonDomain(ib, bar, &info, gc.GDOMAIN_NOMINAL);
    const least = ribbonDomain(ib, bar, &info, gc.GDOMAIN_MINIMUM);
    try testing.expect(least.width < looks.width);
    ribbonLayout(ib, bar, &info, looks.width);
    const before_mark = looks.width - ribbon.fold_width - 2;
    var at_end = gc.GpHitTest{ .gadget_info = &info, .mouse = .{ .x = before_mark, .y = 3 } };
    try testing.expectEqual(@as(usize, 0), ib.SendMessage(bar, @ptrCast(&at_end)));

    // As narrow as it gets, the » stands there; pressed, it drops down
    // the tabs out of the row by their names, the key's `_` left out, and
    // the ribbon keeps the events.
    ribbonLayout(ib, bar, &info, least.width);
    const more_x = least.width - ribbon.fold_width - @divTrunc(ribbon.more_width, 2);
    var on_more = gc.GpHitTest{ .gadget_info = &info, .mouse = .{ .x = more_x, .y = 3 } };
    try testing.expectEqual(gc.GMR_GADGETHIT, ib.SendMessage(bar, @ptrCast(&on_more)));
    var termination: i32 = 99;
    var down = input(gc.GM_GOACTIVE, &press, more_x, 3, &termination);
    down.gadget_info = &info;
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(bar, @ptrCast(&down)));
    try testing.expect(own.panel.isUp());
    const listed = own.panel.count;
    try testing.expect(listed >= 1 and listed <= 3);
    const first_tab = own.more_tabs.?[0];
    try testing.expect(first_tab != 0);
    for (0..listed) |k| try testing.expectEqualStrings(plain[own.more_tabs.?[k]], std.mem.span(own.panel.labels.?[k].?));

    // Let go over its first line: that tab is in front - in the row now -
    // reported with its number, and the list is gone.
    const p = own.panel;
    const line_y = p.box.top + p.inset.top + @divTrunc(p.line_height, 2);
    var pick = input(gc.GM_HANDLEINPUT, &release, p.box.left + @divTrunc(p.box.width, 2), line_y, &termination);
    pick.gadget_info = &info;
    try testing.expectEqual(gc.GMR_NOREUSE | gc.GMR_VERIFY, ib.SendMessage(bar, @ptrCast(&pick)));
    try testing.expectEqual(@as(i32, @intCast(first_tab)), termination);
    try testing.expectEqual(@as(usize, first_tab), attr(ib, bar, rbn.RIBBON_Current));
    try testing.expectEqual(@as(?usize, first_tab), heard.value);
    try testing.expect(!own.panel.isUp() and own.more_block == null);
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(bar, @ptrCast(&down)));
    for (0..own.panel.count) |k| try testing.expect(own.more_tabs.?[k] != first_tab);

    // Made inactive with the list down, it goes and nothing is taken.
    var gone = gc.GpGoInactive{ .gadget_info = &info, .abort = 1 };
    _ = ib.SendMessage(bar, @ptrCast(&gone));
    try testing.expect(!own.panel.isUp() and own.more_block == null);
    try testing.expectEqual(@as(usize, first_tab), attr(ib, bar, rbn.RIBBON_Current));

    // The contextual tab shown is out of the row too, and in the list.
    _ = ib.SetGadgetAttrsTagList(bar, w, &[_]TagItem{ .{ .tag = rbn.RIBBON_ShowTab, .data = 7 }, .{} });
    try testing.expectEqual(gc.GMR_MEACTIVE, ib.SendMessage(bar, @ptrCast(&down)));
    var found = false;
    for (0..own.panel.count) |k| {
        if (std.mem.eql(u8, std.mem.span(own.panel.labels.?[k].?), "Table")) found = own.more_tabs.?[k] == 4;
    }
    try testing.expect(found);
    _ = ib.SendMessage(bar, @ptrCast(&gone));

    _ = ib.RemoveGList(w, bar, 1);
    ib.FreeScreenDrawInfo(screen, dri);
    ib.CloseWindow(w);
    try testing.expect(ib.CloseScreen(screen));
    display.down(rig.kib);
    ib.DisposeObject(bar);
    try rig.down();
}

test "ribbon.build: a table made into a ribbon - its tabs, groups, buttons and their pictures, a gadget of the program's - each entry found by its ID; out of order, nothing" {
    var heard = Heard{ .tag = rbn.RIBBON_Current, .ib = undefined };
    var rig = try Rig.upAfter(&ribbon.Library.resident_tag, &heard, &ribbon_needs);
    const ib = rig.ib;
    const sys = kexec.SysBase.iface();
    const cmd = sdk.images.command;

    const pastes = [_:null]?[*:0]const u8{ "Paste as text", "Paste special" };
    const mine = ribbonTool(ib, 77, "_Mine", tbg.TBSIZE_SMALL);
    const table = [_]rbn.NewRibbon{
        .{ .type = rbn.RB_TAB, .label = "_Home" },
        .{ .type = rbn.RB_GROUP, .label = "Clipboard", .glyph = cmd.CMD_PASTE, .id = 90, .reduce = 2 },
        .{ .type = rbn.RB_LARGE, .id = 10, .label = "_Paste", .glyph = cmd.CMD_PASTE, .kind = tbg.TBKIND_SPLIT, .labels = &pastes },
        .{ .type = rbn.RB_MEDIUM, .id = 11, .label = "Cu_t", .glyph = cmd.CMD_CUT, .flags = rbn.RBF_DISABLED },
        .{ .type = rbn.RB_GROUP, .label = "Font" },
        .{ .type = rbn.RB_SMALL, .id = 20, .label = "_Bold", .glyph = cmd.CMD_BOLD, .kind = tbg.TBKIND_TOGGLE, .flags = rbn.RBF_CHECKED, .hint = "Make it bold" },
        .{ .type = rbn.RB_GADGET, .id = 77, .gadget = mine },
        .{ .type = rbn.RB_TAB, .label = "T_able", .id = 7, .flags = rbn.RBF_CONTEXTUAL, .colour = 0xFFF28C28 },
        .{ .type = rbn.RB_GROUP, .label = "Rows" },
        .{ .type = rbn.RB_MEDIUM, .id = 40, .label = "Insert _row" },
        .{},
    };
    const built = rbn.build(sys, ib, &table, &[_]TagItem{ .{ .tag = gc.GA_ID, .data = 3 }, .{} }).?;
    try testing.expectEqual(@as(u32, 3), gc.gadget(built.ribbon).id);
    try testing.expectEqual(@as(usize, 2), attr(ib, built.ribbon, rbn.RIBBON_NumTabs));

    // The tabs, each one's groups ending in an empty one and each group's
    // entries in a null.
    try testing.expectEqual(table[0].label, built.tabs[0].label);
    try testing.expectEqual(@as(u32, 0), built.tabs[0].contextual);
    try testing.expectEqual(table[7].label, built.tabs[1].label);
    try testing.expectEqual(@as(u32, 1), built.tabs[1].contextual);
    try testing.expectEqual(@as(u32, 7), built.tabs[1].id);
    try testing.expectEqual(@as(u32, 0xFFF28C28), built.tabs[1].colour);
    try testing.expect(built.tabs[2].label == null);
    const home = built.tabs[0].groups.?;
    try testing.expectEqual(table[1].label, home[0].label);
    try testing.expectEqual(@as(u32, 90), home[0].launcher);
    try testing.expectEqual(@as(u32, 2), home[0].reduce);
    try testing.expect(home[0].image != null);
    try testing.expectEqual(table[4].label, home[1].label);
    try testing.expect(home[1].image == null);
    try testing.expect(home[2].label == null);
    const clipboard = home[0].items.?;
    try testing.expect(clipboard[0] != null and clipboard[0] == built.entry(10));
    try testing.expect(clipboard[1] != null and clipboard[1] == built.entry(11));
    try testing.expect(clipboard[2] == null);
    const font = home[1].items.?;
    try testing.expect(font[0] != null and font[0] == built.entry(20));
    try testing.expect(font[1] == mine and built.entry(77) == mine);
    try testing.expect(font[2] == null);
    const rows = built.tabs[1].groups.?;
    try testing.expectEqual(table[8].label, rows[0].label);
    try testing.expect(rows[0].items.?[0] == built.entry(40) and rows[0].items.?[1] == null);
    try testing.expect(rows[1].label == null);
    try testing.expect(built.entry(999) == null);

    // The buttons as their lines say: a picture each of the folded group
    // and the buttons with a glyph, in the order of the lines.
    try testing.expectEqual(@as(usize, 4), built.picture_count);
    try testing.expect(home[0].image == built.pictures[0]);
    try testing.expectEqual(@intFromPtr(built.pictures[1]), attr(ib, built.entry(10).?, tbg.TOOLBUTTON_Image));
    try testing.expectEqual(@intFromPtr(built.pictures[2]), attr(ib, built.entry(11).?, tbg.TOOLBUTTON_Image));
    try testing.expectEqual(@intFromPtr(built.pictures[3]), attr(ib, built.entry(20).?, tbg.TOOLBUTTON_Image));
    try testing.expectEqual(@as(usize, 0), attr(ib, built.entry(40).?, tbg.TOOLBUTTON_Image));
    try testing.expectEqual(@as(usize, cmd.CMD_CUT), attr(ib, built.pictures[2].?, cmd.COMMAND_Glyph));
    try testing.expect(gc.gadget(built.entry(11).?).flags & gc.GFLG_DISABLED != 0);
    try testing.expect(gc.gadget(built.entry(10).?).flags & gc.GFLG_DISABLED == 0);
    try testing.expectEqual(@as(usize, 1), attr(ib, built.entry(20).?, tbg.TOOLBUTTON_Checked));
    try testing.expectEqual(@as(usize, 0), attr(ib, built.entry(40).?, tbg.TOOLBUTTON_Checked));
    const hint: [*:0]const u8 = @ptrFromInt(attr(ib, built.entry(20).?, tbg.TOOLBUTTON_Hint));
    try testing.expectEqualStrings("Make it bold", std.mem.span(hint));
    try testing.expectEqual(@as(u32, 10), gc.gadget(built.entry(10).?).id);

    // The ribbon takes the entries with it, the pictures go after it.
    ib.DisposeObject(built.ribbon);
    built.free(sys, ib);

    // An entry before any group, and a null gadget: nothing made, and the
    // gadgets given disposed of - the classes are expunged below only
    // when none of their objects is left.
    const stray = ribbonTool(ib, 78, "_Stray", tbg.TBSIZE_SMALL);
    const unordered = [_]rbn.NewRibbon{
        .{ .type = rbn.RB_TAB, .label = "_Home" },
        .{ .type = rbn.RB_GADGET, .id = 78, .gadget = stray },
        .{},
    };
    try testing.expect(rbn.build(sys, ib, &unordered, null) == null);
    const given = ribbonTool(ib, 79, "_Given", tbg.TBSIZE_SMALL);
    const missing = [_]rbn.NewRibbon{
        .{ .type = rbn.RB_TAB, .label = "_Home" },
        .{ .type = rbn.RB_GROUP, .label = "Group", .glyph = cmd.CMD_CUT },
        .{ .type = rbn.RB_GADGET, .id = 79, .gadget = given },
        .{ .type = rbn.RB_GADGET, .id = 80, .gadget = null },
        .{},
    };
    try testing.expect(rbn.build(sys, ib, &missing, null) == null);
    try rig.down();
}

test "ribbon.gadget: too narrow, a group folds into a button that drops it down; the mark minimizes it, and a tab then drops its page down; a contextual tab comes and goes" {
    var heard = Heard{ .tag = rbn.RIBBON_Minimized, .ib = undefined };
    var rig = try Rig.upAfter(&ribbon.Library.resident_tag, &heard, &ribbon_needs);
    const ib = rig.ib;
    // The ribbon is larger than the display, as in the test before; so is
    // a popup put up from it, which has no layer then and is up all the
    // same.
    const display = try Display.up(rig.kib);
    const wn = intuition.windows;
    const rq = intuition.requesters;
    const w = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 64 },
        .{ .tag = wn.WA_Height, .data = 40 },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{},
    }).?;
    const screen: *intuition.Screen = @ptrFromInt(windowAttrOf(ib, w, wn.WA_Screen));
    const dri = ib.GetScreenDrawInfo(screen);
    var info = infoOf(ib, w, dri);

    // Home: Clipboard, and Font with a launcher; Table, contextual, with a
    // group of its own.
    const paste = ribbonTool(ib, 10, "_Paste", tbg.TBSIZE_LARGE);
    const cut = ribbonTool(ib, 11, "Cu_t", tbg.TBSIZE_MEDIUM);
    const copy = ribbonTool(ib, 12, "_Copy", tbg.TBSIZE_MEDIUM);
    const bold = ribbonTool(ib, 13, "_Bold", tbg.TBSIZE_MEDIUM);
    const italic = ribbonTool(ib, 14, "_Italic", tbg.TBSIZE_MEDIUM);
    const under = ribbonTool(ib, 15, "_Underline", tbg.TBSIZE_MEDIUM);
    const rows = ribbonTool(ib, 16, "_Rows", tbg.TBSIZE_LARGE);
    const clipboard = [_:null]?*Object{ paste, cut, copy };
    const font = [_:null]?*Object{ bold, italic, under };
    const layout = [_:null]?*Object{rows};
    const home = [_]rbn.RibbonGroup{ .{ .label = "Clipboard", .items = &clipboard }, .{ .label = "Font", .items = &font, .launcher = 50 }, .{} };
    const table = [_]rbn.RibbonGroup{ .{ .label = "Layout", .items = &layout }, .{} };
    const tabs = [_]rbn.RibbonTab{ .{ .label = "_Home", .groups = &home }, .{ .label = "T_able", .groups = &table, .id = 7, .contextual = 1 }, .{} };
    const bar = ib.NewObjectTagList(null, rbn.RIBBON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 7 },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(rig.listener) },
        .{ .tag = rbn.RIBBON_Tabs, .data = @intFromPtr(&tabs) },
        .{},
    }).?;
    const own = classes.instData(ribbon.Data, ib.FindClass(rbn.RIBBON_CLASS).?, bar);
    const looks = domainOf(ib, bar, gc.GDOMAIN_NOMINAL);
    const least = domainOf(ib, bar, gc.GDOMAIN_MINIMUM);
    _ = ib.AddGList(w, bar, -1, 1);
    ib.RefreshGList(bar, w, 1);

    // As wide as it looks right, every group whole: Font's launcher at the
    // right of its name, under its entries, a member to press.
    const launcher = own.parts.?[1].launcher.?;
    try testing.expectEqual(@as(usize, 50), attr(ib, launcher, gc.GA_ID));
    const l = gc.gadget(launcher).*;
    const u = gc.gadget(under).*;
    try testing.expect(l.top >= u.top + u.height);
    try testing.expect(l.left + l.width <= looks.width);
    try testing.expect(l.left > gc.gadget(bold).left);
    var on_launcher = gc.GpHitTest{ .gadget_info = &info, .mouse = .{ .x = l.left + 2, .y = l.top + 2 } };
    try testing.expectEqual(gc.GMR_GADGETHIT, ib.SendMessage(bar, @ptrCast(&on_launcher)));
    try testing.expect(gc.gadget(launcher).window == w);

    // Narrower a pixel at a time, until Font is folded: at the right, it
    // goes before Clipboard does. Its button is the member then, and its
    // entries are not, nor its window's.
    var width = looks.width;
    while (width > least.width and own.parts.?[1].level != ribbon.level_folded) {
        width -= 1;
        ribbonLayout(ib, bar, &info, width);
    }
    try testing.expectEqual(@as(u32, ribbon.level_folded), own.parts.?[1].level);
    try testing.expect(own.parts.?[0].level < ribbon.level_folded);
    const folded = own.parts.?[1].button.?;
    try testing.expect(gc.gadget(folded).window == w);
    try testing.expect(gc.gadget(bold).window == null);
    ib.RefreshGList(bar, w, 1);

    // Its button pressed - found by the hit test first, as intuition asks
    // one before a press: the group dropped down under it in a popup, its
    // entries there; the button stays down while it is.
    const fb = gc.gadget(folded).*;
    var on_button = gc.GpHitTest{ .gadget_info = &info, .mouse = .{ .x = fb.left + 2, .y = fb.top + 2 } };
    try testing.expectEqual(gc.GMR_GADGETHIT, ib.SendMessage(bar, @ptrCast(&on_button)));
    var termination: i32 = 99;
    var on_folded = input(gc.GM_GOACTIVE, &press, fb.left + 2, fb.top + 2, &termination);
    on_folded.gadget_info = &info;
    try testing.expectEqual(gc.GMR_NOREUSE, ib.SendMessage(bar, @ptrCast(&on_folded)));
    var done = gc.GpGoInactive{ .gadget_info = &info, .abort = 0 };
    _ = ib.SendMessage(bar, @ptrCast(&done));
    try testing.expect(own.popup_ribbon != null);
    try testing.expect(own.popup.flags & rq.REQACTIVE != 0);
    // Under it, moved onto the screen - 64 by 40 - as far as it must be.
    try testing.expectEqual(@max(@min(fb.left, 64 - own.popup.width), 0), own.popup.left);
    try testing.expectEqual(@max(@min(fb.top + fb.height, 40 - own.popup.height), 0), own.popup.top);
    try testing.expectEqual(@as(usize, 1), attr(ib, folded, tbg.TOOLBUTTON_Dropped));
    try testing.expect(gc.gadget(folded).flags & gc.GFLG_SELECTED != 0);
    try testing.expect(gc.gadget(bold).requester == &own.popup);
    const pb = gc.gadget(bold).*;
    try testing.expect(pb.left >= 0 and pb.left + pb.width <= own.popup.width);
    try testing.expect(pb.top >= 0 and pb.top + pb.height <= own.popup.height);
    // Down again: the entries are nobody's, the button at rest.
    ib.EndRequest(&own.popup, w);
    try testing.expect(own.popup_ribbon == null);
    try testing.expectEqual(@as(usize, 0), attr(ib, folded, tbg.TOOLBUTTON_Dropped));
    try testing.expect(gc.gadget(folded).flags & gc.GFLG_SELECTED == 0);
    try testing.expect(gc.gadget(bold).requester == null and gc.gadget(bold).window == null);

    // The mark at the row's right end minimizes it: the row alone, nothing
    // on the page to press, and the target told.
    const whole = ribbonDomain(ib, bar, &info, gc.GDOMAIN_NOMINAL);
    termination = 99;
    var on_mark = input(gc.GM_GOACTIVE, &press, width - 4, 3, &termination);
    on_mark.gadget_info = &info;
    try testing.expectEqual(gc.GMR_NOREUSE | gc.GMR_VERIFY, ib.SendMessage(bar, @ptrCast(&on_mark)));
    try testing.expectEqual(rbn.RBCODE_MINIMIZED, termination);
    try testing.expectEqual(@as(usize, 1), attr(ib, bar, rbn.RIBBON_Minimized));
    try testing.expectEqual(@as(?usize, 1), heard.value);
    const row = ribbonDomain(ib, bar, &info, gc.GDOMAIN_NOMINAL).height;
    try testing.expect(row < whole.height);
    var key_p = keyed('p', 0, &termination);
    try testing.expectEqual(gc.GMKR_NOTHING, ib.SendMessage(bar, @ptrCast(&key_p)));
    ib.RefreshGList(bar, w, 1);

    // A press on Home then drops its page down under the row, as wide as
    // the ribbon.
    termination = 99;
    var on_home = input(gc.GM_GOACTIVE, &press, 6, 3, &termination);
    on_home.gadget_info = &info;
    try testing.expectEqual(gc.GMR_NOREUSE | gc.GMR_VERIFY, ib.SendMessage(bar, @ptrCast(&on_home)));
    try testing.expectEqual(@as(i32, 0), termination);
    try testing.expect(own.popup.flags & rq.REQACTIVE != 0);
    try testing.expectEqual(@as(u32, 0), own.popup_tab);
    try testing.expectEqual(width, own.popup.width);
    try testing.expectEqual(@max(@min(row, 40 - own.popup.height), 0), own.popup.top);
    try testing.expect(gc.gadget(paste).requester == &own.popup);
    ib.EndRequest(&own.popup, w);
    try testing.expect(own.popup_ribbon == null and gc.gadget(paste).requester == null);

    // The mark again: back, and told so.
    try testing.expectEqual(gc.GMR_NOREUSE | gc.GMR_VERIFY, ib.SendMessage(bar, @ptrCast(&on_mark)));
    try testing.expectEqual(@as(usize, 0), attr(ib, bar, rbn.RIBBON_Minimized));
    try testing.expectEqual(@as(?usize, 0), heard.value);
    try testing.expect(ib.SendMessage(bar, @ptrCast(&key_p)) != gc.GMKR_NOTHING);

    // Two presses on a tab in time minimize it as well.
    const first_press = ie.InputEvent{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_LBUTTON, .time = .{ .secs = 10, .micro = 0 } };
    const second_press = ie.InputEvent{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_LBUTTON, .time = .{ .secs = 10, .micro = 100000 } };
    var once = input(gc.GM_GOACTIVE, &first_press, 6, 3, &termination);
    once.gadget_info = &info;
    _ = ib.SendMessage(bar, @ptrCast(&once));
    try testing.expectEqual(@as(usize, 0), attr(ib, bar, rbn.RIBBON_Minimized));
    var twice = input(gc.GM_GOACTIVE, &second_press, 6, 3, &termination);
    twice.gadget_info = &info;
    try testing.expectEqual(gc.GMR_NOREUSE | gc.GMR_VERIFY, ib.SendMessage(bar, @ptrCast(&twice)));
    try testing.expectEqual(rbn.RBCODE_MINIMIZED, termination);
    try testing.expectEqual(@as(usize, 1), attr(ib, bar, rbn.RIBBON_Minimized));
    _ = ib.SendMessage(bar, @ptrCast(&on_mark));
    try testing.expectEqual(@as(usize, 0), attr(ib, bar, rbn.RIBBON_Minimized));

    // Table is out of the row until it is shown: its key does nothing,
    // then turns to it; hidden again, Home is in front.
    var key_a = keyed('a', 0, &termination);
    try testing.expectEqual(gc.GMKR_NOTHING, ib.SendMessage(bar, @ptrCast(&key_a)));
    _ = ib.SetGadgetAttrsTagList(bar, w, &[_]TagItem{ .{ .tag = rbn.RIBBON_ShowTab, .data = 7 }, .{} });
    try testing.expectEqual(gc.GMKR_VERIFY, ib.SendMessage(bar, @ptrCast(&key_a)));
    try testing.expectEqual(@as(usize, 1), attr(ib, bar, rbn.RIBBON_Current));
    try testing.expect(gc.gadget(rows).window == w);
    ib.RefreshGList(bar, w, 1);
    _ = ib.SetGadgetAttrsTagList(bar, w, &[_]TagItem{ .{ .tag = rbn.RIBBON_HideTab, .data = 7 }, .{} });
    try testing.expectEqual(@as(usize, 0), attr(ib, bar, rbn.RIBBON_Current));
    try testing.expect(gc.gadget(rows).window == null);

    // In a window lower than it is told, it is its row alone by itself.
    _ = ib.SetAttrsTagList(bar, &[_]TagItem{ .{ .tag = rbn.RIBBON_MinimizeBelow, .data = 300 }, .{} });
    try testing.expectEqual(row, ribbonDomain(ib, bar, &info, gc.GDOMAIN_NOMINAL).height);
    try testing.expectEqual(@as(usize, 0), attr(ib, bar, rbn.RIBBON_Minimized));
    _ = ib.SetAttrsTagList(bar, &[_]TagItem{ .{ .tag = rbn.RIBBON_MinimizeBelow, .data = 0 }, .{} });
    try testing.expectEqual(whole.height, ribbonDomain(ib, bar, &info, gc.GDOMAIN_NOMINAL).height);

    _ = ib.RemoveGList(w, bar, 1);
    ib.FreeScreenDrawInfo(screen, dri);
    ib.CloseWindow(w);
    try testing.expect(ib.CloseScreen(screen));
    display.down(rig.kib);
    ib.DisposeObject(bar);
    try rig.down();
}
