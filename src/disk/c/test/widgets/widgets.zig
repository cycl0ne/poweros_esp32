// SPDX-License-Identifier: MIT
//! Widgets: one of each of the round, the date, the drawing and the code
//! gadget classes, in a window. Built against the SDK only.
//!
//!   Widgets TEXT/K
//!
//! The window holds, in framed groups:
//!
//! - **Round**: a meter whose needle a timer moves every second and a
//!   half, and an arc with a knob - turned, it sets the meter.
//! - **Picking**: a roller of the hours that wraps round, and a calendar
//!   on today.
//! - **Drawing**: a canvas the program has painted a pattern into; a press
//!   or a drag on it puts dots down.
//! - **Codes**: TEXT (the repository's address unless given) as a QR code,
//!   as Code 128, and an EAN-13.
//! - **Looks**: a button whose own style rounds its raised bevel, beside a
//!   group framed as a drop box.
//! - **Chart and text**: two series the timer adds to, as lines, and a
//!   text in markup - bold, italic, a colour, a size - wrapped to its
//!   width.
//!
//! Every gadget let go is printed with its code. The close gadget or
//! Ctrl-C end it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const graphics = sdk.graphics;
const motion = sdk.motion;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const MotionBase = sdk.interface.motion.MotionBase;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const ic = intuition.imageclass;
const icc = intuition.icclass;
const style = intuition.style;
const classusr = intuition.classusr;
const mt = sdk.gadgets.meter;
const ar = sdk.gadgets.arc;
const ro = sdk.gadgets.roller;
const ca = sdk.gadgets.calendar;
const cv = sdk.gadgets.canvas;
const qc = sdk.gadgets.qrcode;
const bc = sdk.gadgets.barcode;
const tx = sdk.gadgets.text;
const cr = sdk.gadgets.chart;

pub const COMMAND_NAME = "Widgets";
const VERSION_STRING = "\x00$VER: Widgets 1.0 (2.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TEXT/K";
const arg_text = 0;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOMEMORY = "No memory for the gadgets\n";
const MSG_NOWINDOW = "No window\n";
const MSG_HELLO = "Turn the arc, roll the hours, pick a day, draw on the canvas. The close gadget or Ctrl-C end it\n";
const MSG_GADGET = "Gadget %lu (%s): code %ld\n";

const ID_ARC = 1;
const ID_ROLLER = 2;
const ID_CALENDAR = 3;
const ID_CANVAS = 4;
const ID_ROUND = 5;

fn nameOf(id: usize) [*:0]const u8 {
    return switch (id) {
        ID_ARC => "arc",
        ID_ROLLER => "roller",
        ID_CALENDAR => "calendar",
        ID_CANVAS => "canvas",
        ID_ROUND => "rounded button",
        else => "?",
    };
}

const hours = [_:null]?[*:0]const u8{
    "00", "01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "11",
    "12", "13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "23",
};

/// The levels the timer gives the meter in turn.
const levels = [_]u32{ 30, 85, 55, 110, 10, 70 };

/// The rounded button's own style: the default raised bevel, its corners
/// rounded.
const rounded = [_]TagItem{
    .{ .tag = style.STYLE_Radius, .data = 7 },
    .{ .tag = style.STYLE_BorderWidth, .data = 2 },
    .{},
};

fn pair(t: sdk.utility.Tag, data: usize) TagItem {
    return .{ .tag = t, .data = data };
}

/// A group in a frame with a title, its children across.
fn group(ib: *IntuitionBase, title: [*:0]const u8, frame: u32, children: []const ?*Object) ?*Object {
    var tags: [16]TagItem = undefined;
    var n: usize = 0;
    tags[n] = pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ);
    n += 1;
    tags[n] = pair(lg.LAYOUTA_FrameTitle, @intFromPtr(title));
    n += 1;
    if (frame != ic.FRAME_RIDGE) {
        tags[n] = pair(lg.LAYOUTA_FrameType, frame);
        n += 1;
    }
    tags[n] = pair(lg.LAYOUTA_Margin, 6);
    n += 1;
    tags[n] = pair(lg.LAYOUTA_Spacing, 8);
    n += 1;
    for (children) |child| {
        tags[n] = pair(lg.LAYOUTA_AddChild, @intFromPtr(child));
        n += 1;
    }
    tags[n] = .{};
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &tags);
}

/// A pattern painted into the canvas: bands of colour and three rings.
fn paint(gb: *GraphicsBase, rp: *graphics.RastPort, w: i32, h: i32) void {
    var y: i32 = 0;
    while (y < h) : (y += 8) {
        const shade: u32 = @intCast(@divTrunc(y * 200, h));
        gb.SetRPAttrs(rp, &[_]TagItem{ pair(graphics.RPTAG_APen, graphics.penRGB(40, @intCast(shade), @intCast(255 - shade))), .{} });
        gb.RectFill(rp, &.{ .min_y = y, .max_x = w, .max_y = @min(y + 8, h) });
    }
    gb.SetRPAttrs(rp, &[_]TagItem{ pair(graphics.RPTAG_Smooth, 1), pair(graphics.RPTAG_APen, graphics.penRGB(255, 220, 80)), .{} });
    for ([_]i32{ 1, 2, 3 }) |i| {
        gb.FillArc(rp, &.{ .cx = @divTrunc(w * i, 4), .cy = @divTrunc(h, 2), .radius = 14, .inner = 9 });
    }
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
    const text: [*:0]const u8 = rdargs.string(argv[arg_text]) orelse "https://github.com/cycl0ne/poweros_esp32";

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);
    const gfx_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(gfx_lib);
    const gb: *GraphicsBase = @ptrCast(gfx_lib);
    const motion_lib = sys.OpenLibrary(motion.MOTIONNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{motion.MOTIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(motion_lib);
    const mb: *MotionBase = @ptrCast(motion_lib);

    // The class libraries, open until the window object is gone.
    const wanted = [_][*:0]const u8{
        mt.METER_LIBRARY,  ar.ARC_LIBRARY, ro.ROLLER_LIBRARY,  ca.CALENDAR_LIBRARY,
        cv.CANVAS_LIBRARY, qc.QR_LIBRARY,  bc.BARCODE_LIBRARY, tx.TEXT_LIBRARY,
        cr.CHART_LIBRARY,
    };
    var libraries: [wanted.len]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    for (wanted, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{name});
            return dos.RETURN_FAIL;
        };
    }

    const meter = ib.NewObjectTagList(null, mt.METER_CLASS, &[_]TagItem{
        pair(mt.METER_Max, 120),
        pair(mt.METER_Band, 100),
        pair(mt.METER_Ticks, 6),
        pair(mt.METER_Format, @intFromPtr("%ld")),
        pair(gc.GA_Width, 120),
        pair(gc.GA_Height, 120),
        .{},
    });
    const arc = ib.NewObjectTagList(null, ar.ARC_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_ARC),
        pair(gc.GA_RelVerify, 1),
        pair(ar.ARC_Turn, 1),
        pair(ar.ARC_Max, 120),
        pair(ar.ARC_Level, 40),
        pair(ar.ARC_Format, @intFromPtr("%ld")),
        pair(gc.GA_Width, 96),
        pair(gc.GA_Height, 96),
        .{},
    });
    const roller = ib.NewObjectTagList(null, ro.ROLLER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_ROLLER),
        pair(gc.GA_RelVerify, 1),
        pair(ro.ROLLER_Labels, @intFromPtr(&hours)),
        pair(ro.ROLLER_Selected, 9),
        pair(ro.ROLLER_Wrap, 1),
        .{},
    });
    const calendar = ib.NewObjectTagList(null, ca.CALENDAR_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_CALENDAR),
        pair(gc.GA_RelVerify, 1),
        .{},
    });
    const canvas = ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_CANVAS),
        pair(cv.CANVAS_Width, 180),
        pair(cv.CANVAS_Height, 100),
        pair(icc.ICA_TARGET, icc.ICTARGET_IDCMP),
        .{},
    });
    const code = ib.NewObjectTagList(null, qc.QR_CLASS, &[_]TagItem{ pair(qc.QR_Text, @intFromPtr(text)), .{} });
    const bars = ib.NewObjectTagList(null, bc.BARCODE_CLASS, &[_]TagItem{ pair(bc.BARCODE_Text, @intFromPtr("PowerOS")), .{} });
    const ean = ib.NewObjectTagList(null, bc.BARCODE_CLASS, &[_]TagItem{
        pair(bc.BARCODE_Type, bc.BARCODE_EAN13),
        pair(bc.BARCODE_Text, @intFromPtr("400638133393")),
        .{},
    });
    const round = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_ROUND),
        pair(gc.GA_RelVerify, 1),
        pair(gc.GA_Text, @intFromPtr("_Rounded")),
        pair(gc.GA_Style, @intFromPtr(&rounded)),
        .{},
    });
    const note = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr("Drop here")), .{} });

    const plot = ib.NewObjectTagList(null, cr.CHART_CLASS, &[_]TagItem{
        pair(cr.CHART_Series, 2),
        pair(cr.CHART_Capacity, 24),
        pair(cr.CHART_Auto, 1),
        pair(gc.GA_Width, 260),
        pair(gc.GA_Height, 90),
        .{},
    });
    const rich = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Markup, 1),
        pair(tx.TEXT_Wrap, 1),
        pair(gc.GA_Width, 300),
        pair(tx.TEXT_Text, @intFromPtr("Text in <b>bold</b>, in <i>italic</i>, <u>underlined</u>, in <c=#C03030>red</c> and <c=#3060C0><b>bold blue</b></c>, <s=24>bigger</s> and back, wrapped to the width of the gadget.<br>A new line.")),
        .{},
    });

    const parts = [_]?*Object{ meter, arc, roller, calendar, canvas, code, bars, ean, round, note, plot, rich };
    for (parts) |part| if (part == null) {
        for (parts) |made| ib.DisposeObject(made);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    const codes_column = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(bars)),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(ean)),
        .{},
    });
    const drop = group(ib, "Drop box", ic.FRAME_ICONDROPBOX, &.{note});
    const top_row = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(group(ib, "Round", ic.FRAME_RIDGE, &.{ meter, arc }))),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(group(ib, "Picking", ic.FRAME_RIDGE, &.{ roller, calendar }))),
        .{},
    });
    const bottom_row = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(group(ib, "Drawing", ic.FRAME_RIDGE, &.{canvas}))),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(group(ib, "Codes", ic.FRAME_RIDGE, &.{ code, codes_column }))),
        .{},
    });
    const looks = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(round)),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(drop)),
        .{},
    });
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(top_row)),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(bottom_row)),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(group(ib, "Chart and text", ic.FRAME_RIDGE, &.{ plot, rich }))),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(looks)),
        pair(lg.CHILDA_WeightHeight, 0),
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr("Widgets")),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_SizeGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wn.WA_IDCMP, wn.IDCMP_IDCMPUPDATE),
        pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.DisposeObject(object);

    // The canvas painted before the window shows it.
    var canvas_rp: usize = 0;
    _ = ib.GetAttr(cv.CANVAS_RastPort, canvas.?, &canvas_rp);
    const picture: *graphics.RastPort = @ptrFromInt(canvas_rp);
    paint(gb, picture, 180, 100);

    var open = wc.WmOpen{};
    if (ib.SendMessage(object, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    }
    var window_ptr: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_ptr);
    const window: *intuition.Window = @ptrFromInt(window_ptr);
    _ = Printf(dl, MSG_HELLO, .{});

    // The meter's timer.
    const bit = sys.AllocSignal(-1);
    if (bit < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(bit);
    const tick = mb.CreateTimerTagList(&[_]TagItem{
        pair(motion.TIMER_Period, 1500),
        pair(motion.TIMER_Repeat, motion.TIMER_FOREVER),
        pair(motion.TIMER_Signal, @intCast(bit)),
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer mb.DeleteTimer(tick);
    mb.StartTimer(tick);
    const tick_mask = @as(u32, 1) << @intCast(bit);

    var next_level: usize = 0;
    var code_word: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code_word };
    while (true) {
        const got = ib.WaitIMsg(window, tick_mask | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_WARN;
        if (got & tick_mask != 0) {
            _ = ib.SetGadgetAttrsTagList(meter.?, window, &[_]TagItem{ pair(mt.METER_Level, levels[next_level]), .{} });
            _ = ib.SetGadgetAttrsTagList(plot.?, window, &[_]TagItem{
                pair(cr.CHART_Current, 0),
                pair(cr.CHART_Add, levels[next_level]),
                pair(cr.CHART_Current, 1),
                pair(cr.CHART_Add, levels[(next_level + 3) % levels.len] / 2),
                .{},
            });
            next_level = (next_level + 1) % levels.len;
        }
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_GADGETUP => {
                    const id = word & wc.WMHI_GADGETMASK;
                    const value: i32 = @bitCast(code_word);
                    _ = Printf(dl, MSG_GADGET, .{ @as(u64, id), nameOf(id), @as(i64, value) });
                    if (id == ID_ARC) {
                        _ = ib.SetGadgetAttrsTagList(meter.?, window, &[_]TagItem{ pair(mt.METER_Level, @intCast(value)), .{} });
                    }
                },
                // A press or a drag on the canvas: a dot where it is.
                wc.WMHI_IDCMPUPDATE => {
                    var x: usize = 0;
                    var y: usize = 0;
                    _ = ib.GetAttr(cv.CANVAS_X, canvas.?, &x);
                    _ = ib.GetAttr(cv.CANVAS_Y, canvas.?, &y);
                    gb.SetRPAttrs(picture, &[_]TagItem{ pair(graphics.RPTAG_APen, graphics.penRGB(255, 255, 255)), .{} });
                    gb.FillArc(picture, &.{ .cx = @bitCast(@as(u32, @truncate(x))), .cy = @bitCast(@as(u32, @truncate(y))), .radius = 3 });
                    ib.QueueGadgetRefresh(canvas.?);
                },
                else => {},
            }
        }
    }
}
