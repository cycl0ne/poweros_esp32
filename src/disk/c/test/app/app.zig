// SPDX-License-Identifier: MIT
//! App: an icon on the desktop, an item in its Tools menu, and a window
//! files can be dropped on - and every message they bring printed. Built
//! against the SDK only.
//!
//!   App NAME/K,ITEM/K,WINDOW/S
//!
//! NAME is the icon's name ("App" unless given), its picture the default
//! tool's; ITEM is the Tools menu's item ("Show Picked" unless given);
//! WINDOW opens a small window as well. Each message is printed as it
//! comes: what it is for, and the full name of each file it carries - for
//! a window, where they were let go. Ctrl-C, or the window's close
//! gadget, takes everything off again.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const icon = sdk.icon;
const anvil = sdk.anvil;
const intuition = sdk.intuition;
const wn = intuition.windows;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IconBase = sdk.interface.icon.IconBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const AnvilBase = sdk.interface.anvil.AnvilBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "App";
const VERSION_STRING = "\x00$VER: App 1.0 (09.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "NAME/K,ITEM/K,WINDOW/S";
const arg_name = 0;
const arg_item = 1;
const arg_window = 2;

const ID_ICON = 1;
const ID_ITEM = 2;
const ID_WINDOW = 3;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const names = [_][*:0]const u8{ anvil.ANVILNAME, icon.ICONNAME, intuition.INTUITIONNAME };
    const versions = [_]u32{ 1, 1, 0 };
    var libraries: [names.len]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    for (names, versions, 0..) |name, version, i| {
        libraries[i] = sys.OpenLibrary(name, version) orelse {
            _ = Printf(dl, "%s: no %s\n", .{ COMMAND_NAME, name });
            return dos.RETURN_FAIL;
        };
    }
    const ab: *AnvilBase = @ptrCast(libraries[0].?);
    const icon_base: *IconBase = @ptrCast(libraries[1].?);
    const ib: *IntuitionBase = @ptrCast(libraries[2].?);

    const port = sys.CreateMsgPort() orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    // Last: whatever came after the removes is replied, then the port goes.
    defer {
        while (sys.GetMsg(port)) |message| sys.ReplyMsg(message);
        sys.DeleteMsgPort(port);
    }

    // The icon, with the default tool's picture, which the desktop copies.
    const name: [*:0]const u8 = dos.rdargs.string(argv[arg_name]) orelse "App";
    const object = icon_base.GetDefDiskObject(icon.WBTOOL) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    object.current_x = icon.NO_ICON_POSITION;
    object.current_y = icon.NO_ICON_POSITION;
    const app_icon = ab.AddAppIcon(ID_ICON, 0, name, port, object, null);
    icon_base.FreeDiskObject(object);
    if (app_icon == null) {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    defer _ = ab.RemoveAppIcon(app_icon);

    const item: [*:0]const u8 = dos.rdargs.string(argv[arg_item]) orelse "Show Picked";
    const app_item = ab.AddAppMenuItem(ID_ITEM, 0, item, port, null);
    defer _ = ab.RemoveAppMenuItem(app_item);

    // The window, when asked for.
    var window: ?*intuition.Window = null;
    if (argv[arg_window] != 0) window = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Drop files here") },
        .{ .tag = wn.WA_Left, .data = 120 },
        .{ .tag = wn.WA_Top, .data = 80 },
        .{ .tag = wn.WA_Width, .data = 260 },
        .{ .tag = wn.WA_Height, .data = 120 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW },
        .{},
    });
    defer if (window) |shown| ib.CloseWindow(shown);
    const app_window = if (window) |shown| ab.AddAppWindow(ID_WINDOW, 0, shown, port, null) else null;
    defer _ = ab.RemoveAppWindow(app_window);

    _ = Printf(dl, "%s: on the desktop; Ctrl-C ends\n", .{COMMAND_NAME});
    while (true) {
        const got = if (window) |shown|
            ib.WaitIMsg(shown, port.sigMask() | exec.SIGBREAKF_CTRL_C)
        else
            sys.Wait(port.sigMask() | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
        if (window) |shown| {
            var closed = false;
            while (ib.GetIMsg(shown)) |im| {
                if (im.class == wn.IDCMP_CLOSEWINDOW) closed = true;
                ib.ReplyIMsg(im);
            }
            if (closed) break;
        }
        while (sys.GetMsg(port)) |message| {
            const am: *anvil.AppMessage = @fieldParentPtr("message", message);
            print(dl, am);
            sys.ReplyMsg(message);
        }
    }
    return dos.RETURN_OK;
}

/// A message, as it came: what for, and its files.
fn print(dl: *DosBase, am: *const anvil.AppMessage) void {
    const what: [*:0]const u8 = switch (am.kind) {
        anvil.AMTYPE_APPICON => "icon",
        anvil.AMTYPE_APPMENUITEM => "menu item",
        anvil.AMTYPE_APPWINDOW => "window",
        else => "?",
    };
    _ = Printf(dl, "%s %u: %u files", .{ what, am.id, am.num_args });
    if (am.kind == anvil.AMTYPE_APPWINDOW) _ = Printf(dl, " at %d,%d", .{ am.mouse_x, am.mouse_y });
    _ = Printf(dl, "\n", .{});
    const pairs = am.arg_list orelse return;
    for (pairs[0..am.num_args]) |pair| {
        var full: [dos.path_max + 1]u8 = @splat(0);
        if (!dl.NameFromLock(pair.lock, &full, full.len)) continue;
        if (pair.name) |file| if (file[0] != 0) {
            _ = dl.AddPart(@ptrCast(&full), file, full.len);
        };
        _ = Printf(dl, "  %s\n", .{@as([*:0]const u8, @ptrCast(&full))});
    }
}
