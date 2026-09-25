// SPDX-License-Identifier: MIT
//! ColorWheel: a colour picked on colorwheel.gadget. Built against the SDK
//! only.
//!
//!   ColorWheel BEVEL/S
//!
//! It opens colorwheel.gadget and text.gadget from `SYS:classes/gadgets/`
//! and a window object on the default public screen holding one layout: a
//! colour wheel, in a bevel with BEVEL, starting at orange; under it a
//! text line with the colour as hue, saturation and brightness, and red,
//! green and blue; and an OK button. Each time the dot is let go the line
//! shows the new colour and it is printed - its red, green and blue once as
//! the wheel says them and once worked out from its hue, saturation and
//! brightness with the library's own ConvertHSBToRGB, which agree. OK, the
//! close gadget or Ctrl-C end it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const cw = sdk.gadgets.colorwheel;
const tx = sdk.gadgets.text;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const ColorWheelBase = sdk.interface.colorwheel.ColorWheelBase;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "ColorWheel";
const VERSION_STRING = "\x00$VER: ColorWheel 1.0 (25.09.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "BEVEL/S";
const arg_bevel = 0;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display\n";
const MSG_NOMEMORY = "No memory for the gadgets\n";
const MSG_NOWINDOW = "No window\n";
const MSG_HELLO = "Drag the dot. OK, the close gadget or Ctrl-C end it\n";
const MSG_COLOUR = "Hue %04x saturation %04x brightness %04x: red %04x green %04x blue %04x, worked out %04x %04x %04x\n";

const ID_WHEEL = 1;
const ID_COLOUR = 2;
const ID_OK = 3;

/// Orange, to start at.
const orange = cw.ColorWheelRGB{ .red = 0xFFFFFFFF, .green = 0x80008000, .blue = 0 };

const Shown = struct { layout: *Object, wheel: *Object, line: *Object };

fn build(ib: *IntuitionBase, bevel: bool) ?Shown {
    const wheel = ib.NewObjectTagList(null, cw.WHEEL_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_WHEEL },
        .{ .tag = gc.GA_Width, .data = 160 },
        .{ .tag = gc.GA_Height, .data = 160 },
        .{ .tag = cw.WHEEL_RGB, .data = @intFromPtr(&orange) },
        .{ .tag = cw.WHEEL_BevelBox, .data = @intFromBool(bevel) },
        .{},
    });
    const line = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_COLOUR },
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr("Drag the dot") },
        .{ .tag = tx.TEXT_CopyText, .data = 1 },
        .{ .tag = tx.TEXT_Border, .data = 1 },
        .{ .tag = tx.TEXT_Clipped, .data = 1 },
        .{},
    });
    const ok = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("OK") },
        .{ .tag = gc.GA_ID, .data = ID_OK },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
    const parts = [_]?*Object{ wheel, line, ok };
    var whole = true;
    for (parts) |part| whole = whole and part != null;
    const layout = if (whole) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(wheel) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(line) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(ok) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{},
    }) else null;
    const made = layout orelse {
        for (parts) |part| ib.DisposeObject(part);
        return null;
    };
    return .{ .layout = made, .wheel = wheel.?, .line = line.? };
}

/// Four hex digits of the top of a 32-bit fraction into `into`.
fn hex4(into: []u8, value: u32) void {
    const digits = "0123456789ABCDEF";
    var shift: u5 = 28;
    for (into[0..4]) |*c| {
        c.* = digits[(value >> shift) & 0xF];
        shift -%= 4;
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

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    // The wheel's library is also where ConvertHSBToRGB is.
    const wheel_lib = sys.OpenLibrary(cw.WHEEL_LIBRARY, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{@as([*:0]const u8, cw.WHEEL_LIBRARY)});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(wheel_lib);
    const wheel_calls: *ColorWheelBase = @ptrCast(wheel_lib);
    const text_lib = sys.OpenLibrary(tx.TEXT_LIBRARY, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{@as([*:0]const u8, tx.TEXT_LIBRARY)});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(text_lib);

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);

    const shown = build(ib, argv[arg_bevel] != 0) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    var nominal = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(shown.layout, @ptrCast(&nominal));
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("ColorWheel") },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(@max(nominal.domain.width, 300)) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(nominal.domain.height) },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(shown.layout) },
        .{},
    }) orelse {
        ib.DisposeObject(shown.layout);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    // Before the libraries its classes are in close.
    defer ib.DisposeObject(object);

    var open = wc.WmOpen{};
    if (ib.SendMessage(object, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    }
    var window_ptr: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_ptr);
    const window: *intuition.Window = @ptrFromInt(window_ptr);
    _ = Printf(dl, MSG_HELLO, .{});

    var handle = wc.WmHandleInput{};
    while (true) {
        const got = ib.WaitIMsg(window, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_WARN;
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_OK => return dos.RETURN_OK,
                    ID_WHEEL => {
                        // The storage GetAttr fills is the structure itself.
                        var hsb: cw.ColorWheelHSB align(@alignOf(usize)) = .{};
                        var rgb: cw.ColorWheelRGB align(@alignOf(usize)) = .{};
                        _ = ib.GetAttr(cw.WHEEL_HSB, shown.wheel, @ptrCast(&hsb));
                        _ = ib.GetAttr(cw.WHEEL_RGB, shown.wheel, @ptrCast(&rgb));
                        var worked: cw.ColorWheelRGB = .{};
                        wheel_calls.ConvertHSBToRGB(&hsb, &worked);
                        _ = Printf(dl, MSG_COLOUR, .{
                            hsb.hue >> 16,    hsb.saturation >> 16, hsb.brightness >> 16,
                            rgb.red >> 16,    rgb.green >> 16,      rgb.blue >> 16,
                            worked.red >> 16, worked.green >> 16,   worked.blue >> 16,
                        });
                        var words: [40:0]u8 = @splat(0);
                        const text = "R xxxx  G xxxx  B xxxx";
                        @memcpy(words[0..text.len], text);
                        hex4(words[2..6], rgb.red);
                        hex4(words[10..14], rgb.green);
                        hex4(words[18..22], rgb.blue);
                        _ = ib.SetGadgetAttrsTagList(shown.line, window, &[_]TagItem{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&words) }, .{} });
                    },
                    else => {},
                },
                else => {},
            }
        }
    }
}
