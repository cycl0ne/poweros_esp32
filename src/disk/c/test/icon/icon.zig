// SPDX-License-Identifier: MIT
//! Icon: prints the icons of names, as icon.library gives them, and shows
//! their pictures. Built against the SDK only.
//!
//!   Icon NAME/M,DEFAULTS/S,PUT/K,SHOW/S
//!
//! Each NAME's icon - its own, or the default that fits it
//! (GetDiskObjectNew) - is printed: its kind, its place, its default tool,
//! its tool types, its stack, a drawer's window, and its picture's size.
//! DEFAULTS prints the five defaults too. PUT writes the first icon as the
//! icon of the name it gives, and prints it read back. SHOW opens a window
//! with every picture in a row, until it is closed or Ctrl-C.

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

pub const COMMAND_NAME = "Icon";
const VERSION_STRING = "\x00$VER: Icon 1.0 (08.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "NAME/M,DEFAULTS/S,PUT/K,SHOW/S";
const arg_name = 0;
const arg_defaults = 1;
const arg_put = 2;
const arg_show = 3;

/// The most icons held at once.
const icons_max = 24;

const kind_words = [_][*:0]const u8{ "none", "disk", "drawer", "tool", "project", "trashcan", "?", "?", "app icon" };
const default_names = [_][*:0]const u8{ "(default disk)", "(default drawer)", "(default tool)", "(default project)", "(default trashcan)" };

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    const icon_lib = sys.OpenLibrary(icon.ICONNAME, 1) orelse {
        _ = Printf(dl, "%s: no %s\n", .{ COMMAND_NAME, icon.ICONNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(icon_lib);
    const ib: *IconBase = @ptrCast(icon_lib);

    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    var held: [icons_max]*icon.DiskObject = undefined;
    var labels: [icons_max][*:0]const u8 = undefined;
    var count: usize = 0;
    defer for (held[0..count]) |object| ib.FreeDiskObject(object);

    var result: i32 = dos.RETURN_OK;
    for (dos.rdargs.multi(argv[arg_name])) |name| {
        if (count == icons_max) break;
        const object = ib.GetDiskObjectNew(name) orelse {
            _ = dl.PrintFault(dl.IoErr(), name);
            result = dos.RETURN_WARN;
            continue;
        };
        held[count] = object;
        labels[count] = name;
        count += 1;
    }
    if (argv[arg_defaults] != 0) {
        for (1..6) |kind| {
            if (count == icons_max) break;
            held[count] = ib.GetDefDiskObject(@intCast(kind)) orelse continue;
            labels[count] = default_names[kind - 1];
            count += 1;
        }
    }
    for (held[0..count], labels[0..count]) |object, label| show(dl, ib, label, object);

    if (argv[arg_put] != 0 and count > 0) {
        const target: [*:0]const u8 = @ptrFromInt(argv[arg_put]);
        if (!ib.PutDiskObject(target, held[0])) {
            _ = dl.PrintFault(dl.IoErr(), target);
            return dos.RETURN_FAIL;
        }
        const back = ib.GetDiskObject(target) orelse {
            _ = dl.PrintFault(dl.IoErr(), target);
            return dos.RETURN_FAIL;
        };
        defer ib.FreeDiskObject(back);
        _ = Printf(dl, "written, and read back:\n", .{});
        show(dl, ib, target, back);
    }
    _ = dl.Flush(dl.Output());

    if (argv[arg_show] != 0 and count > 0) {
        if (!picture(sys, dl, held[0..count])) return dos.RETURN_FAIL;
    }
    return result;
}

/// One icon printed.
fn show(dl: *DosBase, ib: *IconBase, name: [*:0]const u8, object: *const icon.DiskObject) void {
    _ = ib;
    const kind = if (object.kind < kind_words.len) kind_words[object.kind] else "?";
    _ = Printf(dl, "%s: %s", .{ name, kind });
    if (object.current_x != icon.NO_ICON_POSITION) {
        _ = Printf(dl, ", at %ld,%ld", .{ @as(i64, object.current_x), @as(i64, object.current_y) });
    }
    if (object.image) |image| _ = Printf(dl, ", %lux%lu picture", .{ @as(u64, image.width), @as(u64, image.height) });
    if (object.stack_size != 0) _ = Printf(dl, ", stack %lu", .{@as(u64, object.stack_size)});
    _ = Printf(dl, "\n", .{});
    if (object.default_tool) |tool| _ = Printf(dl, "  tool %s\n", .{tool});
    if (object.tool_types) |types| {
        var index: usize = 0;
        while (types[index]) |entry| : (index += 1) _ = Printf(dl, "  type %s\n", .{entry});
    }
    if (object.drawer_data) |drawer| {
        if (drawer.width > 0) {
            _ = Printf(dl, "  window %ld,%ld %ldx%ld\n", .{ @as(i64, drawer.left), @as(i64, drawer.top), @as(i64, drawer.width), @as(i64, drawer.height) });
        }
    }
}

/// A window with every picture in a row, until it is closed.
fn picture(sys: *ExecBase, dl: *DosBase, objects: []const *icon.DiskObject) bool {
    const intuition_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse return false;
    defer sys.CloseLibrary(intuition_lib);
    const graphics_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, 0) orelse return false;
    defer sys.CloseLibrary(graphics_lib);
    const ib: *IntuitionBase = @ptrCast(intuition_lib);
    const gb: *GraphicsBase = @ptrCast(graphics_lib);

    var width: i32 = 16;
    var height: i32 = 16;
    for (objects) |object| {
        const image = object.image orelse continue;
        width += @as(i32, @intCast(image.width)) + 16;
        height = @max(height, @as(i32, @intCast(image.height)) + 32);
    }
    const tags = [_]TagItem{
        .{ .tag = wn.WA_Left, .data = 40 },
        .{ .tag = wn.WA_Top, .data = 40 },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(@max(width, 160)) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(height) },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Icons") },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW },
        .{},
    };
    const window = ib.OpenWindowTagList(&tags) orelse {
        _ = Printf(dl, "%s: no window\n", .{COMMAND_NAME});
        return false;
    };
    defer ib.CloseWindow(window);
    const rp: *graphics.RastPort = @ptrFromInt(attr(ib, window, wn.WA_RastPort));
    const left: i32 = @intCast(attr(ib, window, wn.WA_BorderLeft));
    const top: i32 = @intCast(attr(ib, window, wn.WA_BorderTop));

    var x: i32 = left + 16;
    for (objects) |object| {
        const image = object.image orelse continue;
        const w: i32 = @intCast(image.width);
        const h: i32 = @intCast(image.height);
        const area = graphics.Rect{ .min_x = x, .min_y = top + 16, .max_x = x + w, .max_y = top + 16 + h };
        gb.BlendPixelArray(rp, image.pixels, image.width * 4, @intFromEnum(sdk.rtg.bitmaps.PixelFormat.rgba32), 0, 0, &area);
        x += w + 16;
    }

    var running = true;
    while (running) {
        const got = ib.WaitIMsg(window, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) running = false;
        while (ib.GetIMsg(window)) |message| {
            if (message.class == wn.IDCMP_CLOSEWINDOW) running = false;
            ib.ReplyIMsg(message);
        }
    }
    return true;
}

fn attr(ib: *IntuitionBase, window: *intuition.Window, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(window, &ask);
    return value;
}
