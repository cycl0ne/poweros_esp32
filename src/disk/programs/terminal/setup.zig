// SPDX-License-Identifier: MIT
//! Terminal's settings window: the line - a getdevice.gadget, whose button
//! lists the serial lines this board has - its speed, frame and
//! handshake, what the Return key sends, and whether what is typed is
//! shown and a line feed starts a new line. Save keeps them in ENVARC: as
//! well as ENV:, Use for now only, Cancel leaves them as they were.
//!
//! The window is an object of its own beside the terminal's, run in the
//! same loop: the terminal goes on showing what the line sends while it
//! is open. What its gadgets hold is read when Save or Use is pressed.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const intuition = sdk.intuition;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const wn = intuition.windows;
const devices = sdk.expansion.devices;
const gd = sdk.gadgets.getdevice;
const ch = sdk.gadgets.chooser;
const cy = sdk.gadgets.cycle;
const cb = sdk.gadgets.checkbox;
const ExecBase = sdk.interface.exec.ExecBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const settings_file = @import("settings.zig");
const Settings = settings_file.Settings;

const ID_LINE = 1;
const ID_SPEED = 2;
const ID_FRAME = 3;
const ID_HANDSHAKE = 4;
const ID_RETURN = 5;
const ID_ECHO = 6;
const ID_LFNEWLINE = 7;
const ID_SAVE = 8;
const ID_USE = 9;
const ID_CANCEL = 10;

/// The class libraries the window is made of, open while it is.
const class_libraries = [_][*:0]const u8{ gd.GETDEVICE_LIBRARY, ch.CHOOSER_LIBRARY, cy.CYCLE_LIBRARY, cb.CHECKBOX_LIBRARY };

const frame_labels = blk: {
    var labels: [settings_file.frames.len + 1]?[*:0]const u8 = undefined;
    for (settings_file.frames, 0..) |frame, i| labels[i] = frame.name.ptr;
    labels[settings_file.frames.len] = null;
    break :blk labels;
};
const handshake_labels = [_:null]?[*:0]const u8{ "None", "xON/xOFF" };
const return_labels = [_:null]?[*:0]const u8{ "CR", "LF", "CR LF" };

/// What the window was closed with.
pub const Outcome = enum { open, save, use, cancel };

pub const Setup = struct {
    sys: *ExecBase,
    ib: *IntuitionBase,
    classes: [class_libraries.len]?*exec.Library = @splat(null),
    object: ?*Object = null,
    window: ?*intuition.Window = null,
    line: ?*Object = null,
    speed: ?*Object = null,
    frame: ?*Object = null,
    handshake: ?*Object = null,
    send_return: ?*Object = null,
    echo: ?*Object = null,
    lf_newline: ?*Object = null,
    /// The speeds the chooser offers: the usual ones, and the line's own
    /// at the end when it is none of them. Their text, and the labels
    /// pointing into it.
    rate_text: [settings_file.rates.len + 1][8:0]u8 = undefined,
    rate_labels: [settings_file.rates.len + 2]?[*:0]const u8 = @splat(null),
    rate_values: [settings_file.rates.len + 1]u32 = @splat(0),
    rate_count: usize = 0,

    pub fn isOpen(setup: *const Setup) bool {
        return setup.object != null;
    }

    /// The signal its window's messages come with; 0 while it is shut.
    pub fn signal(setup: *const Setup) u32 {
        const object = setup.object orelse return 0;
        var mask: usize = 0;
        _ = setup.ib.GetAttr(wc.WINDOWA_SigMask, object, &mask);
        return @truncate(mask);
    }

    fn fillRates(setup: *Setup, baud: u32) u32 {
        var shown: u32 = 0;
        setup.rate_count = 0;
        var values: [settings_file.rates.len + 1]u32 = undefined;
        var count: usize = 0;
        for (settings_file.rates) |rate| {
            values[count] = rate;
            count += 1;
        }
        var listed = false;
        for (settings_file.rates) |rate| if (rate == baud) {
            listed = true;
        };
        if (!listed) {
            values[count] = baud;
            count += 1;
        }
        for (values[0..count], 0..) |rate, i| {
            setup.rate_values[i] = rate;
            var digits: [8:0]u8 = @splat(0);
            var n: usize = 0;
            var left = rate;
            var reversed: [8]u8 = undefined;
            while (true) {
                reversed[n] = '0' + @as(u8, @intCast(left % 10));
                n += 1;
                left /= 10;
                if (left == 0 or n == reversed.len) break;
            }
            for (0..n) |k| digits[k] = reversed[n - 1 - k];
            setup.rate_text[i] = digits;
            setup.rate_labels[i] = &setup.rate_text[i];
            if (rate == baud) shown = @intCast(i);
        }
        setup.rate_labels[count] = null;
        setup.rate_count = count;
        return shown;
    }

    fn button(setup: *Setup, label: [*:0]const u8, id: u32) ?*Object {
        return setup.ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
            .{ .tag = gc.GA_Text, .data = @intFromPtr(label) },
            .{ .tag = gc.GA_ID, .data = id },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{},
        });
    }

    fn cycle(setup: *Setup, labels: [*]const ?[*:0]const u8, active: u32, id: u32) ?*Object {
        return setup.ib.NewObjectTagList(null, cy.CYCLE_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = id },
            .{ .tag = cy.CYCLE_Labels, .data = @intFromPtr(labels) },
            .{ .tag = cy.CYCLE_Active, .data = active },
            .{},
        });
    }

    fn check(setup: *Setup, on: bool, id: u32) ?*Object {
        return setup.ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = id },
            .{ .tag = cb.CHECKBOX_Checked, .data = @intFromBool(on) },
            .{},
        });
    }

    /// The window opened on `screen`, its gadgets showing `settings`.
    /// False when it could not be; nothing is left open then.
    pub fn open(setup: *Setup, screen: *intuition.Screen, settings: *const Settings) bool {
        if (setup.object != null) {
            if (setup.window) |w| setup.ib.WindowToFront(w);
            return true;
        }
        for (class_libraries, 0..) |name, i| {
            setup.classes[i] = setup.sys.OpenLibrary(name, 0) orelse {
                setup.closeClasses();
                return false;
            };
        }
        const ib = setup.ib;
        const shown_rate = setup.fillRates(settings.baud);
        const line = ib.NewObjectTagList(null, gd.GETDEVICE_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_LINE },
            .{ .tag = gd.GETDEVICE_TitleText, .data = @intFromPtr("Which serial line?") },
            .{ .tag = gd.GETDEVICE_Speaks, .data = devices.DEVIF_SERIAL },
            .{ .tag = gd.GETDEVICE_Device, .data = @intFromPtr(&settings.device) },
            .{ .tag = gd.GETDEVICE_Unit, .data = settings.unit },
            .{},
        });
        const speed = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_SPEED },
            .{ .tag = ch.CHOOSER_Labels, .data = @intFromPtr(&setup.rate_labels) },
            .{ .tag = ch.CHOOSER_Active, .data = shown_rate },
            .{ .tag = ch.CHOOSER_MaxPanelLines, .data = 8 },
            .{},
        });
        const frame = setup.cycle(&frame_labels, settings.frame, ID_FRAME);
        const handshake = setup.cycle(&handshake_labels, @intFromEnum(settings.handshake), ID_HANDSHAKE);
        const send_return = setup.cycle(&return_labels, @intFromEnum(settings.send_return), ID_RETURN);
        const echo = setup.check(settings.echo, ID_ECHO);
        const lf_newline = setup.check(settings.lf_newline, ID_LFNEWLINE);
        const save = setup.button("_Save", ID_SAVE);
        const use = setup.button("_Use", ID_USE);
        const cancel = setup.button("_Cancel", ID_CANCEL);
        const parts = [_]?*Object{ line, speed, frame, handshake, send_return, echo, lf_newline, save, use, cancel };
        for (parts) |part| if (part == null) {
            for (parts) |made| ib.DisposeObject(made);
            setup.closeClasses();
            return false;
        };

        const buttons = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(save) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(use) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(cancel) },
            .{},
        }) orelse {
            for (parts) |made| ib.DisposeObject(made);
            setup.closeClasses();
            return false;
        };
        const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 4 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(line) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Line") },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(speed) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Spee_d") },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(frame) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Frame") },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(handshake) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Handshake") },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(send_return) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Return sends") },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(echo) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Echo typing") },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(lf_newline) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("LF starts a _new line") },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(buttons) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{},
        }) orelse {
            ib.DisposeObject(buttons);
            for (parts[0..7]) |made| ib.DisposeObject(made);
            setup.closeClasses();
            return false;
        };
        const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            .{ .tag = wn.WA_Title, .data = @intFromPtr("Terminal Settings") },
            .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
            .{ .tag = wn.WA_AutoAdjust, .data = 1 },
            .{ .tag = wn.WA_CloseGadget, .data = 1 },
            .{ .tag = wn.WA_DragBar, .data = 1 },
            .{ .tag = wn.WA_DepthGadget, .data = 1 },
            .{ .tag = wn.WA_Activate, .data = 1 },
            .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
            .{},
        }) orelse {
            ib.DisposeObject(layout);
            setup.closeClasses();
            return false;
        };
        var open_window = wc.WmOpen{};
        if (ib.SendMessage(object, @ptrCast(&open_window)) == 0) {
            ib.DisposeObject(object);
            setup.closeClasses();
            return false;
        }
        var window_at: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_at);
        setup.object = object;
        setup.window = @ptrFromInt(window_at);
        setup.line = line;
        setup.speed = speed;
        setup.frame = frame;
        setup.handshake = handshake;
        setup.send_return = send_return;
        setup.echo = echo;
        setup.lf_newline = lf_newline;
        return true;
    }

    fn closeClasses(setup: *Setup) void {
        for (&setup.classes) |*lib| {
            setup.sys.CloseLibrary(lib.*);
            lib.* = null;
        }
    }

    /// The window shut and its objects disposed of, before the classes
    /// they are of are closed.
    pub fn close(setup: *Setup) void {
        const object = setup.object orelse return;
        setup.ib.DisposeObject(object);
        setup.object = null;
        setup.window = null;
        setup.closeClasses();
    }

    fn attr(setup: *Setup, object: ?*Object, tag: utility.Tag) usize {
        var value: usize = 0;
        _ = setup.ib.GetAttr(tag, object orelse return 0, &value);
        return value;
    }

    /// What the gadgets hold, into `settings`.
    fn read(setup: *Setup, settings: *Settings) void {
        const name = setup.attr(setup.line, gd.GETDEVICE_Device);
        if (name != 0) {
            const text: [*:0]const u8 = @ptrFromInt(name);
            var len: usize = 0;
            while (text[len] != 0) len += 1;
            _ = settings.setDevice(text[0..len]);
        }
        settings.unit = @truncate(setup.attr(setup.line, gd.GETDEVICE_Unit));
        const rate = setup.attr(setup.speed, ch.CHOOSER_Active);
        if (rate < setup.rate_count) settings.baud = setup.rate_values[rate];
        settings.frame = @intCast(@min(setup.attr(setup.frame, cy.CYCLE_Active), settings_file.frames.len - 1));
        settings.handshake = if (setup.attr(setup.handshake, cy.CYCLE_Active) == 1) .xonxoff else .none;
        settings.send_return = @enumFromInt(@min(setup.attr(setup.send_return, cy.CYCLE_Active), 2));
        settings.echo = setup.attr(setup.echo, cb.CHECKBOX_Checked) != 0;
        settings.lf_newline = setup.attr(setup.lf_newline, cb.CHECKBOX_Checked) != 0;
    }

    /// The window's messages acted on: `.open` while it stays up, else how
    /// it was closed - with `settings` holding what it was closed with
    /// when that was Save or Use. The window is shut by then.
    pub fn handle(setup: *Setup, settings: *Settings) Outcome {
        const object = setup.object orelse return .cancel;
        var code: u32 = 0;
        var handle_input = wc.WmHandleInput{ .code = &code };
        while (true) {
            const word = setup.ib.SendMessage(object, @ptrCast(&handle_input));
            if (word == wc.WMHI_LASTMSG) return .open;
            const outcome: Outcome = switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => .cancel,
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_SAVE => .save,
                    ID_USE => .use,
                    ID_CANCEL => .cancel,
                    else => .open,
                },
                else => .open,
            };
            if (outcome == .open) continue;
            if (outcome != .cancel) setup.read(settings);
            setup.close();
            return outcome;
        }
    }
};
