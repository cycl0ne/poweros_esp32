// SPDX-License-Identifier: MIT
//! Drag: a window with icons to drag across the screen (BeginDrag,
//! EndDrag). Built against the SDK only.
//!
//!   Drag FLYBACK/S
//!
//! The window shows the five default icons. Pressing one and moving takes
//! its picture along with the pointer, over every window, the windows
//! under it drawing on; letting go says which window it was let go over,
//! or that it was over none. With FLYBACK the picture flies back to where
//! it was taken from before it goes. The close gadget or Ctrl-C ends it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const icon = sdk.icon;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const wn = intuition.windows;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IconBase = sdk.interface.icon.IconBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Drag";
const VERSION_STRING = "\x00$VER: Drag 1.0 (08.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FLYBACK/S";

/// Where the icons sit in the window: a row, this far apart.
const margin = 16;
const gap = 16;
const kinds = 5;

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
    const flyback = argv[0] != 0;

    const icon_lib = sys.OpenLibrary(icon.ICONNAME, 1) orelse return fail(dl, icon.ICONNAME);
    defer sys.CloseLibrary(icon_lib);
    const ib_icon: *IconBase = @ptrCast(icon_lib);
    const intuition_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse return fail(dl, intuition.INTUITIONNAME);
    defer sys.CloseLibrary(intuition_lib);
    const ib: *IntuitionBase = @ptrCast(intuition_lib);
    const graphics_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, 0) orelse return fail(dl, graphics.GRAPHICSNAME);
    defer sys.CloseLibrary(graphics_lib);
    const gb: *GraphicsBase = @ptrCast(graphics_lib);

    var objects: [kinds]?*icon.DiskObject = @splat(null);
    defer for (objects) |object| ib_icon.FreeDiskObject(object);
    for (&objects, 1..) |*object, kind| object.* = ib_icon.GetDefDiskObject(@intCast(kind));

    const window = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 300 },
        .{ .tag = wn.WA_Top, .data = 120 },
        .{ .tag = wn.WA_InnerWidth, .data = margin * 2 + kinds * 48 + (kinds - 1) * gap },
        .{ .tag = wn.WA_InnerHeight, .data = 48 + margin * 2 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Drag an icon") },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_RMBTrap, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW | wn.IDCMP_MOUSEBUTTONS },
        .{},
    }) orelse return fail(dl, "a window");
    defer ib.CloseWindow(window);
    const rp: *graphics.RastPort = @ptrFromInt(attr(ib, window, wn.WA_RastPort));
    const left: i32 = @intCast(attr(ib, window, wn.WA_BorderLeft));
    const top: i32 = @intCast(attr(ib, window, wn.WA_BorderTop));
    for (objects, 0..) |object, index| {
        const image = (object orelse continue).image orelse continue;
        const x = left + margin + @as(i32, @intCast(index)) * (48 + gap);
        const area = graphics.Rect{ .min_x = x, .min_y = top + margin, .max_x = x + @as(i32, @intCast(image.width)), .max_y = top + margin + @as(i32, @intCast(image.height)) };
        gb.BlendPixelArray(rp, image.pixels, image.width * 4, @intFromEnum(sdk.rtg.bitmaps.PixelFormat.rgba32), 0, 0, &area);
    }
    _ = Printf(dl, "Press an icon and drag it; close the window to stop\n", .{});
    _ = dl.Flush(dl.Output());

    var dragging = false;
    var running = true;
    while (running) {
        const got = ib.WaitIMsg(window, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) running = false;
        while (ib.GetIMsg(window)) |message| {
            const class = message.class;
            const code = message.code;
            const x = message.mouse_x;
            const y = message.mouse_y;
            ib.ReplyIMsg(message);
            if (class == wn.IDCMP_CLOSEWINDOW) running = false;
            if (class != wn.IDCMP_MOUSEBUTTONS) continue;
            if (code == wn.SELECTDOWN and !dragging) {
                const index = iconAt(x - left, y - top) orelse continue;
                const image = (objects[index] orelse continue).image orelse continue;
                const picture = sdk.rtg.Surface{ .pixels = @constCast(image.pixels), .width = image.width, .height = image.height, .pitch = image.width * 4, .format = .rgba32 };
                const icon_x = x - left - margin - @as(i32, @intCast(index)) * (48 + gap);
                const icon_y = y - top - margin;
                dragging = ib.BeginDrag(window, &picture, @intCast(icon_x), @intCast(icon_y));
                if (!dragging) _ = Printf(dl, "%s: the display will not drag it\n", .{COMMAND_NAME});
            } else if (code == wn.SELECTUP and dragging) {
                dragging = false;
                const target = ib.EndDrag(window, if (flyback) intuition.DRAGF_FLYBACK else 0);
                if (target) |over| {
                    const title: ?[*:0]const u8 = @ptrFromInt(attr(ib, over, wn.WA_Title));
                    _ = Printf(dl, "let go over \"%s\"%s\n", .{ title orelse "(untitled)", if (over == window) " - its own" else "" });
                } else {
                    _ = Printf(dl, "let go over no window\n", .{});
                }
                _ = dl.Flush(dl.Output());
            }
        }
    }
    if (dragging) _ = ib.EndDrag(window, 0);
    return dos.RETURN_OK;
}

/// Which icon (x, y) inside the window is on.
fn iconAt(x: i32, y: i32) ?usize {
    if (y < margin or y >= margin + 48) return null;
    const along = x - margin;
    if (along < 0) return null;
    const index: usize = @intCast(@divTrunc(along, 48 + gap));
    if (index >= kinds or @mod(along, 48 + gap) >= 48) return null;
    return index;
}

fn attr(ib: *IntuitionBase, window: *intuition.Window, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(window, &ask);
    return value;
}

fn fail(dl: *DosBase, what: [*:0]const u8) i32 {
    _ = Printf(dl, "%s: no %s\n", .{ COMMAND_NAME, what });
    return dos.RETURN_FAIL;
}
