// SPDX-License-Identifier: MIT
//! TapeDeck: tapedeck.gadget both ways. Built against the SDK only.
//!
//!   TapeDeck
//!
//! It opens tapedeck.gadget and text.gadget from `SYS:classes/gadgets/`
//! and a window object on the default public screen holding one layout: a
//! tape deck, an animation control of 100 frames, a text line with what
//! was pressed last, and an OK button. Each press let go is printed with
//! its code taken apart - the mode, paused or not, or the frame - and
//! shown in the line. OK, the close gadget or Ctrl-C end it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const td = sdk.gadgets.tapedeck;
const tx = sdk.gadgets.text;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "TapeDeck";
const VERSION_STRING = "\x00$VER: TapeDeck 1.0 (25.09.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "";

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display\n";
const MSG_NOMEMORY = "No memory for the gadgets\n";
const MSG_NOWINDOW = "No window\n";
const MSG_HELLO = "Press the buttons. OK, the close gadget or Ctrl-C end it\n";
const MSG_TAPE = "Tape deck: %s%s\n";
const MSG_ANIM = "Animation: %s\n";
const MSG_FRAME = "Animation: frame %lu\n";

const ID_TAPE = 1;
const ID_ANIM = 2;
const ID_LAST = 3;
const ID_OK = 4;

const mode_names = [_][*:0]const u8{ "rewind", "play", "fast forward", "stop" };

fn modeName(mode: u32) [*:0]const u8 {
    return if (mode < mode_names.len) mode_names[mode] else "?";
}

const Shown = struct { layout: *Object, last: *Object };

fn build(ib: *IntuitionBase) ?Shown {
    const tape = ib.NewObjectTagList(null, td.TDECK_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_TAPE },
        .{ .tag = td.TDECK_Tape, .data = 1 },
        .{},
    });
    const anim = ib.NewObjectTagList(null, td.TDECK_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_ANIM },
        .{ .tag = td.TDECK_Frames, .data = 100 },
        .{},
    });
    const last = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_LAST },
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr("nothing yet") },
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
    const parts = [_]?*Object{ tape, anim, last, ok };
    var whole = true;
    for (parts) |part| whole = whole and part != null;
    const layout = if (whole) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(tape) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Tape") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(anim) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Anim") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(last) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Last") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(ok) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{},
    }) else null;
    const made = layout orelse {
        for (parts) |part| ib.DisposeObject(part);
        return null;
    };
    return .{ .layout = made, .last = last.? };
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

    const wanted = [_][*:0]const u8{ td.TDECK_LIBRARY, tx.TEXT_LIBRARY };
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

    const shown = build(ib) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    var nominal = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(shown.layout, @ptrCast(&nominal));
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("TapeDeck") },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(nominal.domain.width + 60) },
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

    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    var words: [48:0]u8 = @splat(0);
    while (true) {
        const got = ib.WaitIMsg(window, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_WARN;
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            if (word & wc.WMHI_CLASSMASK == wc.WMHI_CLOSEWINDOW) return dos.RETURN_OK;
            if (word & wc.WMHI_CLASSMASK != wc.WMHI_GADGETUP) continue;
            var shown_text: [*:0]const u8 = "";
            switch (word & wc.WMHI_GADGETMASK) {
                ID_OK => return dos.RETURN_OK,
                ID_TAPE => {
                    const paused: [*:0]const u8 = if (code & td.TDECK_PAUSED_CODE != 0) ", paused" else "";
                    _ = Printf(dl, MSG_TAPE, .{ modeName(code & 0xFF), paused });
                    shown_text = modeName(code & 0xFF);
                },
                ID_ANIM => if (code & td.TDECK_FRAME_CODE != 0) {
                    _ = Printf(dl, MSG_FRAME, .{@as(u64, code & 0x7FFF)});
                    shown_text = sdk.gadgets.support.formatNumber(sys, "frame %ld", code & 0x7FFF, &words);
                } else {
                    _ = Printf(dl, MSG_ANIM, .{modeName(code)});
                    shown_text = modeName(code);
                },
                else => continue,
            }
            _ = ib.SetGadgetAttrsTagList(shown.last, window, &[_]TagItem{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(shown_text) }, .{} });
        }
    }
}
