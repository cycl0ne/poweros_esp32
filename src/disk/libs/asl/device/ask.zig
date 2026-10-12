// SPDX-License-Identifier: MIT
//! The device requester: the units of the devices that speak a command
//! set, one line each, and the one picked as the answer.
//!
//! What there is comes from expansion.library's `ObtainDeviceUnits`: the
//! devices in the ROM and in DEVS: whose tags say they speak it, and the
//! units the board has of each. Nothing is opened or loaded to find
//! them, so a requester for a serial line does not take a UART or start a
//! radio by being shown. A line says the device, the unit and what the
//! board calls the unit; a double press on one, Return or the positive
//! button answers with it.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const intuition = sdk.intuition;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const wn = intuition.windows;
const asl = sdk.asl;
const devices = sdk.expansion.devices;
const lv = sdk.gadgets.listview;
const ExecBase = sdk.interface.exec.ExecBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const AslBase = @import("../asl_base.zig").AslBase;
const _request = @import("../request/_request.zig");
const Requester = _request.Requester;

const ID_UNITS = 1;
const ID_OK = 2;
const ID_CANCEL = 3;

/// One line of the list: its node, the unit it shows, and its text.
const Line = extern struct {
    node: exec.Node = .{},
    unit: *const devices.DeviceUnit,
    text: [96]u8 = @splat(0),
};

/// A device requester while it is up.
const Session = struct {
    r: *Requester,
    sys: *ExecBase,
    ib: *IntuitionBase,
    ub: *UtilityBase,
    eb: *ExpansionBase = undefined,
    object: *Object = undefined,
    window: *intuition.Window = undefined,
    units_gadget: *Object = undefined,
    /// What ObtainDeviceUnits answered, and the lines made from it.
    found: ?*exec.List = null,
    lines: exec.List = .{},
    line_block: ?[*]Line = null,
    /// The line picked, if any.
    picked: ?*const devices.DeviceUnit = null,
    answered: bool = false,
};

/// `text` added at `at` in `into`, cut to fit and the NUL kept; where
/// the next text goes.
fn append(into: []u8, at: usize, text: [*:0]const u8) usize {
    var put = at;
    var i: usize = 0;
    while (text[i] != 0 and put + 1 < into.len) : (i += 1) {
        into[put] = text[i];
        put += 1;
    }
    into[put] = 0;
    return put;
}

/// A line's text: the device, its unit, and what the board calls it.
fn lineText(unit: *const devices.DeviceUnit, into: []u8) void {
    var at = append(into, 0, unit.node.name orelse "?");
    at = append(into, at, "  unit ");
    var digits: [11:0]u8 = @splat(0);
    var count: usize = 0;
    var left = unit.unit;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    var number: [11:0]u8 = @splat(0);
    for (0..count) |i| number[i] = digits[count - 1 - i];
    at = append(into, at, &number);
    if (unit.label) |label| {
        at = append(into, at, "  ");
        _ = append(into, at, label);
    }
}

fn sameText(one: [*:0]const u8, other: [*:0]const u8) bool {
    var i: usize = 0;
    while (one[i] == other[i]) : (i += 1) {
        if (one[i] == 0) return true;
    }
    return false;
}

/// The units listed, the program's filter asked about each. False
/// without the memory for them.
fn readUnits(s: *Session) bool {
    const found = s.eb.ObtainDeviceUnits(s.r.speaks, null) orelse return false;
    s.found = found;
    var count: usize = 0;
    var node = found.first();
    while (node) |it| : (node = it.next()) count += 1;
    if (count == 0) return true;
    const block = s.sys.AllocVec(count * @sizeOf(Line), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
    const lines: [*]Line = @ptrCast(@alignCast(block));
    s.line_block = lines;
    var made: usize = 0;
    node = found.first();
    while (node) |it| : (node = it.next()) {
        const unit: *const devices.DeviceUnit = @ptrCast(@alignCast(it));
        if (s.r.flags1 & asl.FRF_FILTERFUNC != 0) {
            if (s.r.filter_func) |hook| {
                if (s.ub.CallHookPkt(hook, @ptrCast(s.r), @ptrCast(@constCast(unit))) == 0) continue;
            }
        }
        const line = &lines[made];
        line.* = .{ .unit = unit };
        lineText(unit, &line.text);
        line.node.name = @ptrCast(&line.text);
        s.sys.AddTail(&s.lines, &line.node);
        made += 1;
    }
    return true;
}

fn lineAt(s: *Session, at: u32) ?*Line {
    const node = lv.nodeAt(&s.lines, at) orelse return null;
    return @fieldParentPtr("node", node);
}

// --- the window -------------------------------------------------------------

fn makeButton(s: *Session, text: [*:0]const u8, id: usize) ?*Object {
    return s.ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr(text) },
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
}

/// How wide the longest line is in the screen's font.
fn widestLine(s: *Session, screen: *intuition.Screen) i32 {
    const dri = s.ib.GetScreenDrawInfo(screen);
    defer s.ib.FreeScreenDrawInfo(screen, dri);
    const font = dri.font orelse return 0;
    var widest: i32 = 0;
    var node = s.lines.first();
    while (node) |it| : (node = it.next()) {
        const line: *Line = @fieldParentPtr("node", it);
        const run = intuition.text.plainRun(@ptrCast(&line.text), font);
        widest = @max(widest, s.ib.IntuiTextLength(&run));
    }
    return widest;
}

/// The window object and everything in it. False with nothing made.
fn build(s: *Session, screen: *intuition.Screen) bool {
    const r = s.r;
    const ib = s.ib;
    const ignore = utility.TAG_IGNORE;
    const units = ib.NewObjectTagList(null, lv.LISTVIEW_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_UNITS },
        .{ .tag = lv.LISTVIEW_ShowSelected, .data = 1 },
        .{},
    });
    const ok = makeButton(s, r.words.positive orelse "_Ok", ID_OK);
    const cancel = makeButton(s, r.words.negative orelse "_Cancel", ID_CANCEL);
    const buttons = if (ok != null and cancel != null)
        ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(ok) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(cancel) },
            .{},
        })
    else
        null;
    const layout = if (units != null and buttons != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = 6 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 4 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(units) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(buttons) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{},
    }) else null;
    const made = layout orelse {
        // A child a group took is that group's to dispose of.
        if (buttons) |group| ib.DisposeObject(group) else {
            for ([_]?*Object{ ok, cancel }) |part| ib.DisposeObject(part);
        }
        ib.DisposeObject(units);
        return false;
    };

    var nominal = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(made, @ptrCast(&nominal));
    // Wide enough for the longest line, beside the list's scroller and
    // inside the margins.
    const wide = @max(nominal.domain.width + 120, widestLine(s, screen) + 48);
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr(r.words.title orelse "Pick a device") },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(@max(if (r.box.width > 0) r.box.width else wide, 1)) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(@max(if (r.box.height > 0) r.box.height else nominal.domain.height, 1)) },
        .{ .tag = if (r.box.left >= 0) wn.WA_Left else ignore, .data = @intCast(@max(r.box.left, 0)) },
        .{ .tag = if (r.box.top >= 0) wn.WA_Top else ignore, .data = @intCast(@max(r.box.top, 0)) },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(made) },
        .{},
    }) orelse {
        ib.DisposeObject(made);
        return false;
    };
    s.object = object;
    s.units_gadget = units.?;
    return true;
}

// --- the loop ---------------------------------------------------------------

/// One word from the window acted on. False when the requester is done.
fn act(s: *Session, word: usize, code: u32) bool {
    switch (word & wc.WMHI_CLASSMASK) {
        wc.WMHI_CLOSEWINDOW => return false,
        wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
            ID_UNITS => {
                s.picked = if (lineAt(s, code & ~lv.LISTVIEW_DOUBLE)) |line| line.unit else null;
                // A second press on a line is the answer.
                if (code & lv.LISTVIEW_DOUBLE != 0 and s.picked != null) {
                    s.answered = true;
                    return false;
                }
            },
            ID_OK => {
                if (s.picked != null) {
                    s.answered = true;
                    return false;
                }
            },
            ID_CANCEL => return false,
            else => {},
        },
        wc.WMHI_VANILLAKEY => switch (word & wc.WMHI_KEYMASK) {
            0x0D => {
                if (s.picked != null) {
                    s.answered = true;
                    return false;
                }
            },
            0x1B => return false,
            else => {},
        },
        else => {},
    }
    return true;
}

// --- the whole thing --------------------------------------------------------

/// A device requester put up and answered.
pub fn ask(ab: *AslBase, r: *Requester) bool {
    const block = ab.sys_base.AllocVec(@sizeOf(Session), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
    defer ab.sys_base.FreeVec(block);
    const s: *Session = @ptrCast(@alignCast(block));
    s.* = .{
        .r = r,
        .sys = ab.sys_base,
        .ib = ab.intuition_base,
        .ub = ab.utility_base,
    };
    s.lines.init(.unknown);
    const expansion_lib = s.sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return false;
    defer s.sys.CloseLibrary(expansion_lib);
    s.eb = @ptrCast(expansion_lib);
    defer {
        if (s.line_block) |lines| s.sys.FreeVec(@ptrCast(lines));
        s.eb.ReleaseDeviceUnits(s.found);
    }
    if (!readUnits(s)) return false;

    const named: ?[*:0]const u8 = if (r.where.window != null or r.where.screen != null) null else r.where.pub_screen;
    const parent_screen: ?*intuition.Screen = if (r.where.window) |w| blk: {
        var at: usize = 0;
        const ask_screen = [_]TagItem{ .{ .tag = wn.WA_Screen, .data = @intFromPtr(&at) }, .{} };
        s.ib.GetWindowAttrs(w, &ask_screen);
        break :blk if (at != 0) @ptrFromInt(at) else null;
    } else null;
    const given: ?*intuition.Screen = parent_screen orelse r.where.screen;
    const screen: *intuition.Screen = given orelse
        (s.ib.LockPubScreen(named) orelse s.ib.LockPubScreen(null) orelse return false);
    defer if (given == null) s.ib.UnlockPubScreen(null, screen);

    if (!build(s, screen)) return false;
    defer s.ib.DisposeObject(s.object);

    var open = wc.WmOpen{};
    if (s.ib.SendMessage(s.object, @ptrCast(&open)) == 0) return false;
    var window_at: usize = 0;
    _ = s.ib.GetAttr(wc.WINDOWA_Window, s.object, &window_at);
    s.window = @ptrFromInt(window_at);

    const parent = if (r.where.sleep != 0) r.where.window else null;
    if (parent) |w| {
        const busy = [_]TagItem{ .{ .tag = wn.WA_BusyPointer, .data = 1 }, .{} };
        s.ib.SetWindowPointerA(w, &busy);
    }
    defer if (parent) |w| {
        const awake = [_]TagItem{ .{ .tag = wn.WA_BusyPointer, .data = 0 }, .{} };
        s.ib.SetWindowPointerA(w, &awake);
    };

    // The lines, and the unit the requester starts on if it lists it.
    var which: u32 = lv.LISTVIEW_NONE;
    var at: u32 = 0;
    var node = s.lines.first();
    while (node) |it| : (node = it.next()) {
        const line: *Line = @fieldParentPtr("node", it);
        if (r.device[0] != 0 and line.unit.unit == r.unit and sameText(line.unit.node.name orelse "", @ptrCast(&r.device))) {
            which = at;
            s.picked = line.unit;
        }
        at += 1;
    }
    const attach = [_]TagItem{
        .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&s.lines) },
        .{ .tag = if (which != lv.LISTVIEW_NONE) lv.LISTVIEW_Selected else utility.TAG_IGNORE, .data = which },
        .{ .tag = if (which != lv.LISTVIEW_NONE) lv.LISTVIEW_MakeVisible else utility.TAG_IGNORE, .data = which },
        .{},
    };
    _ = s.ib.SetGadgetAttrsTagList(s.units_gadget, s.window, &attach);

    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    loop: while (true) {
        while (true) {
            const word = s.ib.SendMessage(s.object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            if (!act(s, word, code)) break :loop;
        }
        const got = s.ib.WaitIMsg(s.window, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
    }

    // Where it was left, and what it was answered with.
    var box: [4]usize = @splat(0);
    const ask_box = [_]TagItem{
        .{ .tag = wn.WA_Left, .data = @intFromPtr(&box[0]) },
        .{ .tag = wn.WA_Top, .data = @intFromPtr(&box[1]) },
        .{ .tag = wn.WA_Width, .data = @intFromPtr(&box[2]) },
        .{ .tag = wn.WA_Height, .data = @intFromPtr(&box[3]) },
        .{},
    };
    s.ib.GetWindowAttrs(s.window, &ask_box);
    r.box.left = @bitCast(@as(u32, @truncate(box[0])));
    r.box.top = @bitCast(@as(u32, @truncate(box[1])));
    r.box.width = @bitCast(@as(u32, @truncate(box[2])));
    r.box.height = @bitCast(@as(u32, @truncate(box[3])));
    r.public.device.left_edge = r.box.left;
    r.public.device.top_edge = r.box.top;
    r.public.device.width = r.box.width;
    r.public.device.height = r.box.height;
    if (s.answered) {
        const unit = s.picked.?;
        _request.copyInto(&r.device, unit.node.name);
        _request.copyInto(&r.unit_label, unit.label);
        r.unit = unit.unit;
        r.public.device.device = @ptrCast(&r.device);
        r.public.device.unit = r.unit;
        r.public.device.label = @ptrCast(&r.unit_label);
    }
    const detach = [_]TagItem{ .{ .tag = lv.LISTVIEW_Labels, .data = lv.LISTVIEW_DETACH }, .{} };
    _ = s.ib.SetGadgetAttrsTagList(s.units_gadget, s.window, &detach);
    return s.answered;
}
