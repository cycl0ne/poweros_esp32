// SPDX-License-Identifier: MIT
//! Scroll: a form taller than its window, in a scroll group. Built against
//! the SDK only.
//!
//!   Scroll [HEIGHT/K/N]
//!
//! It opens scrollgroup.gadget and the classes of the form - string,
//! integer, checkbox, cycle and slider - and a window object on the
//! default public screen whose layout is a scroll group round four groups
//! in titled frames: "Network", "Sound", "Display" and "Power". The window
//! is HEIGHT pixels tall (200 when not given), less than the form needs,
//! so the bar in its right border moves it; the wheel does the same over
//! anything in it that takes no wheel itself. A gadget the edge cuts
//! through is drawn as far as the view reaches, and works there.
//!
//! The bars are in the window's border, the scroll group made without
//! scrollers of its own: each bar's `ICA_TARGET` is the scroll group and
//! its `ICA_MAP` turns its top into `SCROLLGROUP_Top` or
//! `SCROLLGROUP_Left`, so a drag moves the form without the program
//! hearing of it; the other way, the scroll group tells the window where
//! its view is (`IDCMP_IDCMPUPDATE`), and the bars are set from that.
//!
//! Every gadget let go is printed with its ID and the code it finished
//! with. The close gadget or Ctrl-C end it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const utility = sdk.utility;
const intuition = sdk.intuition;
const icc = intuition.icclass;
const pg = intuition.propgclass;
const sr = sdk.gadgets.scroller;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const sg = sdk.gadgets.scrollgroup;
const st = sdk.gadgets.string;
const ig = sdk.gadgets.integer;
const cb = sdk.gadgets.checkbox;
const cy = sdk.gadgets.cycle;
const sl = sdk.gadgets.slider;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Scroll";
const VERSION_STRING = "\x00$VER: Scroll 1.0 (07.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "HEIGHT/K/N";
const arg_height = 0;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display\n";
const MSG_NOMEMORY = "No memory for the gadgets\n";
const MSG_NOWINDOW = "No window\n";
const MSG_HELLO = "Scroll the form. The close gadget or Ctrl-C end it\n";
const MSG_GADGET = "Gadget %lu: code %ld\n";

const modes = [_:null]?[*:0]const u8{ "Window", "Full screen", "Mirror" };

/// A field of the form, made from its class and tags, with an ID.
fn make(ib: *IntuitionBase, class: [*:0]const u8, id: u32, tags: []const TagItem) ?*Object {
    var all: [8]TagItem = undefined;
    all[0] = .{ .tag = gc.GA_ID, .data = id };
    all[1] = .{ .tag = gc.GA_RelVerify, .data = 1 };
    for (tags, 2..) |item, i| all[i] = item;
    all[2 + tags.len] = .{};
    return ib.NewObjectTagList(null, class, &all);
}

/// A layout in a frame with `title` in its top edge, holding `fields`,
/// each with its label.
fn group(ib: *IntuitionBase, title: [*:0]const u8, fields: []const ?*Object, labels: []const [*:0]const u8) ?*Object {
    var all: [32]TagItem = undefined;
    all[0] = .{ .tag = lg.LAYOUTA_FrameTitle, .data = @intFromPtr(title) };
    all[1] = .{ .tag = lg.LAYOUTA_Margin, .data = 6 };
    all[2] = .{ .tag = lg.LAYOUTA_Spacing, .data = 4 };
    var n: usize = 3;
    for (fields, labels) |field, label| {
        all[n] = .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(field.?) };
        all[n + 1] = .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(label) };
        all[n + 2] = .{ .tag = lg.CHILDA_WeightHeight, .data = 0 };
        n += 3;
    }
    all[n] = .{};
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &all);
}

/// The window's layout and the scroll group in it.
const Built = struct { layout: *Object, view: *Object };

/// The window's layout: the scroll group round the form; null, with
/// whatever was made freed, when one of them could not be made.
fn build(ib: *IntuitionBase) ?Built {
    const fields = [_]?*Object{
        make(ib, st.STRING_CLASS, 1, &.{ .{ .tag = gc.STRINGA_MaxChars, .data = 64 }, .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr("poweros.local") } }),
        make(ib, ig.INTEGER_CLASS, 2, &.{ .{ .tag = ig.INTEGER_Min, .data = 1 }, .{ .tag = ig.INTEGER_Max, .data = 65535 }, .{ .tag = ig.INTEGER_Number, .data = 23 } }),
        make(ib, cb.CHECKBOX_CLASS, 3, &.{.{ .tag = cb.CHECKBOX_Checked, .data = 1 }}),
        make(ib, sl.SLIDER_CLASS, 4, &.{ .{ .tag = sl.SLIDER_Max, .data = 64 }, .{ .tag = sl.SLIDER_Level, .data = 40 } }),
        make(ib, cb.CHECKBOX_CLASS, 5, &.{}),
        make(ib, sl.SLIDER_CLASS, 6, &.{ .{ .tag = sl.SLIDER_Max, .data = 100 }, .{ .tag = sl.SLIDER_Level, .data = 70 } }),
        make(ib, cy.CYCLE_CLASS, 7, &.{.{ .tag = cy.CYCLE_Labels, .data = @intFromPtr(&modes) }}),
        make(ib, ig.INTEGER_CLASS, 8, &.{ .{ .tag = ig.INTEGER_Max, .data = 3600 }, .{ .tag = ig.INTEGER_Number, .data = 300 } }),
        make(ib, cb.CHECKBOX_CLASS, 9, &.{.{ .tag = cb.CHECKBOX_Checked, .data = 1 }}),
    };
    for (fields) |field| if (field == null) {
        for (fields) |made| ib.DisposeObject(made);
        return null;
    };
    const groups = [_]?*Object{
        group(ib, "Network", fields[0..3], &.{ "Host", "Port", "DHCP" }),
        group(ib, "Sound", fields[3..5], &.{ "Volume", "Mute" }),
        group(ib, "Display", fields[5..7], &.{ "Brightness", "Mode" }),
        group(ib, "Power", fields[7..9], &.{ "Sleep after", "Wake on key" }),
    };
    const form = for (groups) |made| {
        if (made == null) break null;
    } else ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
        .{ .tag = lg.LAYOUTA_Margin, .data = 6 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(groups[0]) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(groups[1]) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(groups[2]) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(groups[3]) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{},
    });
    const contents = form orelse {
        // A group that was made holds its fields; the rest are loose.
        for (groups, 0..) |made, i| {
            if (made) |g| ib.DisposeObject(g) else for (fieldsOf(i)) |f| ib.DisposeObject(fields[f]);
        }
        return null;
    };
    // Its scrollers are the window's, in the border; what it tells of its
    // view goes to the window.
    const view = ib.NewObjectTagList(null, sg.SCROLLGROUP_CLASS, &[_]TagItem{
        .{ .tag = sg.SCROLLGROUP_Contents, .data = @intFromPtr(contents) },
        .{ .tag = sg.SCROLLGROUP_Scrollers, .data = 0 },
        .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
        .{},
    }) orelse {
        ib.DisposeObject(contents);
        return null;
    };
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(view) },
        .{},
    }) orelse {
        ib.DisposeObject(view);
        return null;
    };
    return .{ .layout = layout, .view = view };
}

/// The two bars in the border.
const Bars = struct { vert: *Object, horiz: *Object };

/// What a bar tells the scroll group as it is dragged; its GA_ID goes no
/// further, or the scroll group would take it for its own.
const vert_map = [_]TagItem{
    .{ .tag = sr.SCROLLER_Top, .data = sg.SCROLLGROUP_Top },
    .{ .tag = gc.GA_ID, .data = utility.TAG_IGNORE },
    .{},
};
const horiz_map = [_]TagItem{
    .{ .tag = sr.SCROLLER_Top, .data = sg.SCROLLGROUP_Left },
    .{ .tag = gc.GA_ID, .data = utility.TAG_IGNORE },
    .{},
};

fn windowAttr(ib: *IntuitionBase, window: *intuition.Window, attr: utility.Tag) isize {
    var value: usize = 0;
    const wanted = [_]TagItem{ .{ .tag = attr, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(window, &wanted);
    return @bitCast(value);
}

/// A bar down the right border and one along the bottom one, each from
/// the window's edge to the sizing gadget in the corner, joined to the
/// scroll group; made once the window is open and its borders' depth is
/// known.
fn makeBars(ib: *IntuitionBase, window: *intuition.Window, view: *Object) ?Bars {
    const left = windowAttr(ib, window, wn.WA_BorderLeft);
    const top = windowAttr(ib, window, wn.WA_BorderTop);
    const right = windowAttr(ib, window, wn.WA_BorderRight);
    const bottom = windowAttr(ib, window, wn.WA_BorderBottom);
    const vert = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_RightBorder, .data = 1 },
        .{ .tag = gc.GA_RelRight, .data = @bitCast(-(right - 1)) },
        .{ .tag = gc.GA_Top, .data = @bitCast(top) },
        .{ .tag = gc.GA_Width, .data = @bitCast(right) },
        .{ .tag = gc.GA_RelHeight, .data = @bitCast(-(top + bottom)) },
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEVERT },
        .{ .tag = sr.SCROLLER_Arrows, .data = @bitCast(bottom) },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(view) },
        .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&vert_map) },
        .{},
    }) orelse return null;
    const horiz = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_BottomBorder, .data = 1 },
        .{ .tag = gc.GA_Left, .data = @bitCast(left) },
        .{ .tag = gc.GA_RelBottom, .data = @bitCast(-(bottom - 1)) },
        .{ .tag = gc.GA_RelWidth, .data = @bitCast(-(left + right)) },
        .{ .tag = gc.GA_Height, .data = @bitCast(bottom) },
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEHORIZ },
        .{ .tag = sr.SCROLLER_Arrows, .data = @bitCast(@divTrunc(bottom * 16, 11)) },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(view) },
        .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&horiz_map) },
        .{},
    }) orelse {
        ib.DisposeObject(vert);
        return null;
    };
    _ = ib.AddGList(window, vert, -1, 1);
    _ = ib.AddGList(window, horiz, -1, 1);
    ib.RefreshWindowFrame(window);
    return .{ .vert = vert, .horiz = horiz };
}

/// The bars set from where the scroll group's view is.
fn followView(ib: *IntuitionBase, window: *intuition.Window, bars: Bars, view: *Object) void {
    const sides = [_]struct { bar: *Object, total: utility.Tag, visible: utility.Tag, top: utility.Tag }{
        .{ .bar = bars.vert, .total = sg.SCROLLGROUP_TotalHeight, .visible = sg.SCROLLGROUP_VisibleHeight, .top = sg.SCROLLGROUP_Top },
        .{ .bar = bars.horiz, .total = sg.SCROLLGROUP_TotalWidth, .visible = sg.SCROLLGROUP_VisibleWidth, .top = sg.SCROLLGROUP_Left },
    };
    for (sides) |side| {
        var total: usize = 0;
        var visible: usize = 0;
        var top: usize = 0;
        _ = ib.GetAttr(side.total, view, &total);
        _ = ib.GetAttr(side.visible, view, &visible);
        _ = ib.GetAttr(side.top, view, &top);
        _ = ib.SetGadgetAttrsTagList(side.bar, window, &[_]TagItem{
            .{ .tag = sr.SCROLLER_Total, .data = @max(total, 1) },
            .{ .tag = sr.SCROLLER_Visible, .data = @max(visible, 1) },
            .{ .tag = sr.SCROLLER_Top, .data = top },
            .{},
        });
    }
}

/// Which of the fields group `i` holds.
fn fieldsOf(i: usize) []const usize {
    const all = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    return switch (i) {
        0 => all[0..3],
        1 => all[3..5],
        2 => all[5..7],
        else => all[7..9],
    };
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    var height: u32 = 200;
    if (argv[arg_height] != 0) {
        const given: *const i32 = @ptrFromInt(argv[arg_height]);
        if (given.* >= 80) height = @intCast(given.*);
    }

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    // The class libraries, open for as long as their objects are there:
    // the window object is disposed of before they are closed.
    const wanted = [_][*:0]const u8{ sg.SCROLLGROUP_LIBRARY, sr.SCROLLER_LIBRARY, st.STRING_LIBRARY, ig.INTEGER_LIBRARY, cb.CHECKBOX_LIBRARY, cy.CYCLE_LIBRARY, sl.SLIDER_LIBRARY };
    var libraries: [wanted.len]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    for (wanted, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{name});
            return dos.RETURN_FAIL;
        };
    }

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);

    const built = build(ib) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    const layout = built.layout;
    // As wide as the form looks right at, and shorter than it: the scroll
    // group asks for the form's size, so the width is the window's own.
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Scroll") },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Height, .data = height },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_SizeBRight, .data = 1 },
        .{ .tag = wn.WA_SizeBBottom, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_IDCMPUPDATE | wn.IDCMP_NEWSIZE },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.DisposeObject(object);

    var open = wc.WmOpen{};
    if (ib.SendMessage(object, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    }
    var window_ptr: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_ptr);
    const window: *intuition.Window = @ptrFromInt(window_ptr);
    // The bars are the program's, not the window object's: the window is
    // closed first, which takes them out of it, and then they go.
    const bars = makeBars(ib, window, built.view);
    defer {
        var shut = wc.WmClose{};
        _ = ib.SendMessage(object, @ptrCast(&shut));
        if (bars) |made| {
            ib.DisposeObject(made.vert);
            ib.DisposeObject(made.horiz);
        }
    }
    if (bars) |made| followView(ib, window, made, built.view);
    _ = Printf(dl, MSG_HELLO, .{});

    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    while (true) {
        const got = ib.WaitIMsg(window, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_WARN;
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_GADGETUP => {
                    const value: i32 = @bitCast(code);
                    _ = Printf(dl, MSG_GADGET, .{ @as(u64, word & wc.WMHI_GADGETMASK), @as(i64, value) });
                },
                wc.WMHI_IDCMPUPDATE, wc.WMHI_NEWSIZE => if (bars) |made| followView(ib, window, made, built.view),
                else => {},
            }
        }
    }
}
