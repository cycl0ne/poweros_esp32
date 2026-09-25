// SPDX-License-Identifier: MIT
//! Gadgets: the gadget classes on the disk, in a window. Built against the
//! SDK only.
//!
//!   Gadgets
//!
//! It opens checkbox.gadget, cycle.gadget and radiobutton.gadget from
//! `SYS:classes/gadgets/` and a window object on the default public screen
//! holding one layout: a check box "Backups", a second one "Locked" that
//! is ticked and disabled, a cycle "Level" of Low, Medium and High, a
//! radio column "Port" of Serial, USB and None - each labelled by the
//! layout - and an OK button. Every gadget let go is printed with its ID,
//! its name and the code it finished with: the check box's state, the
//! cycle's choice, the radio button's line. OK, the close gadget or
//! Ctrl-C end it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const cb = sdk.gadgets.checkbox;
const cy = sdk.gadgets.cycle;
const rb = sdk.gadgets.radiobutton;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Gadgets";
const VERSION_STRING = "\x00$VER: Gadgets 1.0 (25.09.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "";

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display\n";
const MSG_NOMEMORY = "No memory for the gadgets\n";
const MSG_NOWINDOW = "No window\n";
const MSG_HELLO = "Press the gadgets. OK, the close gadget or Ctrl-C end it\n";
const MSG_GADGET = "Gadget %lu (%s): code %lu\n";

const ID_BACKUPS = 1;
const ID_LOCKED = 2;
const ID_LEVEL = 3;
const ID_PORT = 4;
const ID_OK = 5;

const levels = [_:null]?[*:0]const u8{ "Low", "Medium", "High" };
const ports = [_:null]?[*:0]const u8{ "Serial", "USB", "None" };

fn nameOf(id: usize) [*:0]const u8 {
    return switch (id) {
        ID_BACKUPS => "Backups",
        ID_LOCKED => "Locked",
        ID_LEVEL => "Level",
        ID_PORT => "Port",
        ID_OK => "OK",
        else => "?",
    };
}

/// The layout and everything in it; null, with whatever was made freed,
/// when one of them could not be made.
fn build(ib: *IntuitionBase) ?*Object {
    const backups = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_BACKUPS },
        .{},
    });
    const locked = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_LOCKED },
        .{ .tag = cb.CHECKBOX_Checked, .data = 1 },
        .{ .tag = gc.GA_Disabled, .data = 1 },
        .{},
    });
    const level = ib.NewObjectTagList(null, cy.CYCLE_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_LEVEL },
        .{ .tag = cy.CYCLE_Labels, .data = @intFromPtr(&levels) },
        .{ .tag = cy.CYCLE_Active, .data = 1 },
        .{},
    });
    const port = ib.NewObjectTagList(null, rb.RADIO_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_PORT },
        .{ .tag = rb.RADIO_Labels, .data = @intFromPtr(&ports) },
        .{},
    });
    const ok = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("OK") },
        .{ .tag = gc.GA_ID, .data = ID_OK },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
    const parts = [_]?*Object{ backups, locked, level, port, ok };
    var whole = true;
    for (parts) |part| whole = whole and part != null;
    const layout = if (whole) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(backups) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Backups") },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(locked) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Locked") },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(level) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Level") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(port) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Port") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(ok) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{},
    }) else null;
    if (layout == null) {
        for (parts) |part| ib.DisposeObject(part);
    }
    return layout;
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

    // The class libraries, open for as long as their objects are there:
    // the window object is disposed of before they are closed.
    var libraries: [3]?*exec.Library = .{ null, null, null };
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    for ([_][*:0]const u8{ cb.CHECKBOX_LIBRARY, cy.CYCLE_LIBRARY, rb.RADIO_LIBRARY }, 0..) |name, i| {
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

    const layout = build(ib) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    var nominal = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(layout, @ptrCast(&nominal));
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Gadgets") },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(nominal.domain.width + 40) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(nominal.domain.height) },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    // The window, the layout and every gadget in it, before the libraries
    // their classes are in.
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
    while (true) {
        const got = ib.WaitIMsg(window, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_WARN;
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_GADGETUP => {
                    const id = word & wc.WMHI_GADGETMASK;
                    _ = Printf(dl, MSG_GADGET, .{ @as(u64, id), nameOf(id), @as(u64, code) });
                    if (id == ID_OK) return dos.RETURN_OK;
                },
                else => {},
            }
        }
    }
}
