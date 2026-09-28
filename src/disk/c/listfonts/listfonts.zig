// SPDX-License-Identifier: MIT
//! ListFonts: the fonts there are, by family and size. Built against the
//! SDK only.
//!
//!   ListFonts NAME,SAMPLE/S
//!
//! Every font diskfont.library's AvailFonts knows, a line for each family
//! and where its sizes are - in the ROM, on the disk, scaled in memory -
//! with the heights in rows:
//!
//!   spleen.font           8 12 16 24 32   disk
//!   spleen.font          20 48            scaled
//!
//! NAME may be a pattern: `ListFonts go#?`. A size loaded from the disk is listed under the disk only; a family
//! with an outline is listed once more as "any size". SAMPLE draws an
//! outline family at 24 rows. NAME shows
//! one family. SAMPLE draws a line in each size listed, in a window on the
//! default public screen, until the close gadget or Ctrl-C.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const diskfont = sdk.diskfont;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const wn = intuition.windows;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;
const RastPort = graphics.RastPort;
const rdargs = dos.rdargs;

pub const COMMAND_NAME = "ListFonts";
const VERSION_STRING = "\x00$VER: ListFonts 1.0 (28.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "NAME,SAMPLE/S";
const arg_name = 0;
const arg_sample = 1;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NAME = "%-20s";
const MSG_SIZE = " %3d";
const MSG_WHERE = "   %s\n";
const MSG_NONE = "No fonts\n";
const MSG_WAITING = "The close gadget or Ctrl-C closes the window\n";

/// The line drawn in each size.
const sample = "The quick brown fox - 0123456789 - \xc4\xd6\xdc\xe4\xf6\xfc\xdf";

/// Where a size is, in the order families list them.
const Where = enum(u8) { rom, disk, scalable, loaded, scaled };
const where_names = [_][*:0]const u8{ "ROM", "disk", "any size, outline", "memory", "scaled" };

const Font = struct {
    name: [*:0]const u8,
    y_size: u16,
    where: Where,
};

/// At most this many sizes are listed.
const max_fonts = 256;
/// At most this many are drawn with SAMPLE.
const max_samples = 16;

fn whereOf(entry: *const diskfont.AvailFonts) Where {
    if (entry.type & diskfont.AFF_SCALABLE != 0) return .scalable;
    if (entry.type & diskfont.AFF_DISK != 0) return .disk;
    if (entry.type & diskfont.AFF_SCALED != 0) return .scaled;
    if (entry.attr.flags & graphics.FPF_ROMFONT != 0) return .rom;
    return .loaded;
}

/// Name, then where, then height.
fn before(ub: *UtilityBase, a: *const Font, b: *const Font) bool {
    const by_name = ub.Stricmp(a.name, b.name);
    if (by_name != 0) return by_name < 0;
    if (a.where != b.where) return @intFromEnum(a.where) < @intFromEnum(b.where);
    return a.y_size < b.y_size;
}

/// A loaded size that the disk lists too, which it is not listed twice as.
fn onDisk(ub: *UtilityBase, fonts: []const Font, font: *const Font) bool {
    for (fonts) |*other| {
        if (other.where == .disk and other.y_size == font.y_size and ub.Stricmp(other.name, font.name) == 0) return true;
    }
    return false;
}

fn wattr(ib: *IntuitionBase, w: *intuition.Window, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(w, &ask);
    return value;
}

fn set(gb: *GraphicsBase, rp: *RastPort, tag: u32, data: usize) void {
    const tags = [_]TagItem{ .{ .tag = tag, .data = data }, .{} };
    gb.SetRPAttrs(rp, &tags);
}

/// A line in each font, in a window, until it is closed.
fn drawSamples(sys: *ExecBase, dl: *DosBase, dfb: *DiskfontBase, fonts: []const Font) i32 {
    const gfx_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, graphics.GRAPHICS_VERSION) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(gfx_lib);
    const gb: *GraphicsBase = @ptrCast(gfx_lib);
    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    var opened: [max_samples]?*graphics.TextFont = @splat(null);
    const count = @min(fonts.len, max_samples);
    defer for (opened[0..count]) |font| if (font) |f| gb.CloseFont(f);
    const measure = gb.CreateRastPortTagList(null) orelse return dos.RETURN_FAIL;
    defer gb.FreeRastPort(measure);
    var inner_w: i32 = 0;
    var inner_h: i32 = 8;
    for (fonts[0..count], 0..) |font, i| {
        // A drawn size as drawn; a scaled one scaled again; an outline at
        // a size to show it by.
        const flags: graphics.FontFlags = if (font.where == .scaled) 0 else graphics.FPF_DESIGNED;
        const rows: u16 = if (font.where == .scalable) 24 else font.y_size;
        opened[i] = dfb.OpenDiskFont(&.{ .name = font.name, .y_size = rows, .flags = flags });
        const f = opened[i] orelse continue;
        graphics.SetFont(gb, measure, f);
        inner_w = @max(inner_w, gb.TextLength(measure, sample, sample.len));
        inner_h += @as(i32, f.image.height) + 4;
    }
    if (inner_w == 0) return dos.RETURN_WARN;

    const screen = ib.LockPubScreen(null) orelse return dos.RETURN_WARN;
    defer ib.UnlockPubScreen(null, screen);
    const window_tags = [_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Left, .data = 20 },
        .{ .tag = wn.WA_Top, .data = 30 },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(inner_w + 16) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(inner_h + 4) },
        .{ .tag = wn.WA_AutoAdjust, .data = 1 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("ListFonts") },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_SmartRefresh, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW },
        .{},
    };
    const w = ib.OpenWindowTagList(&window_tags) orelse return dos.RETURN_FAIL;
    defer ib.CloseWindow(w);
    const rp: *RastPort = @ptrFromInt(wattr(ib, w, wn.WA_RastPort));
    const left: i32 = @intCast(wattr(ib, w, wn.WA_BorderLeft));
    var y: i32 = @as(i32, @intCast(wattr(ib, w, wn.WA_BorderTop))) + 8;
    set(gb, rp, graphics.RPTAG_DrMd, graphics.DRMD_JAM1);
    for (opened[0..count]) |font| {
        const f = font orelse continue;
        graphics.SetFont(gb, rp, f);
        gb.Move(rp, left + 8, y + @as(i32, f.image.baseline));
        gb.Text(rp, sample, sample.len);
        y += @as(i32, f.image.height) + 4;
    }

    _ = Printf(dl, MSG_WAITING, .{});
    var open = true;
    while (open) {
        const got = ib.WaitIMsg(w, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
        while (ib.GetIMsg(w)) |im| {
            const class = im.class;
            ib.ReplyIMsg(im);
            if (class == wn.IDCMP_CLOSEWINDOW) open = false;
        }
    }
    return dos.RETURN_OK;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(utility_lib);
    const ub: *UtilityBase = @ptrCast(utility_lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    // NAME is a pattern, without case: "go#?" is every Go family.
    var pattern: [128]u8 = undefined;
    const only = if (rdargs.string(argv[arg_name])) |name| blk: {
        if (ub.ParsePatternNoCase(name, &pattern, pattern.len) < 0) {
            _ = dl.PrintFault(dos.ERROR_BAD_TEMPLATE, name);
            return dos.RETURN_FAIL;
        }
        break :blk @as([*:0]const u8, @ptrCast(&pattern));
    } else null;

    const df_lib = sys.OpenLibrary(diskfont.DISKFONTNAME, diskfont.DISKFONT_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{diskfont.DISKFONTNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(df_lib);
    const dfb: *DiskfontBase = @ptrCast(df_lib);

    // What AvailFonts knows, in a buffer grown until it fits.
    var size: u32 = 2048;
    var buffer: ?*anyopaque = null;
    while (true) {
        buffer = sys.AllocVec(size, exec.MEMF_ANY) orelse return dos.RETURN_FAIL;
        const more = dfb.AvailFonts(buffer.?, size, diskfont.AFF_MEMORY | diskfont.AFF_DISK | diskfont.AFF_SCALED);
        if (more == 0) break;
        sys.FreeVec(buffer);
        size += more;
    }
    defer sys.FreeVec(buffer);
    const header: *const diskfont.AvailFontsHeader = @ptrCast(@alignCast(buffer.?));

    var all: [max_fonts]Font = undefined;
    var count: usize = 0;
    for (diskfont.availEntries(header)) |*entry| {
        if (count == max_fonts) break;
        if (only) |parsed| if (!ub.MatchPatternNoCase(parsed, entry.attr.name)) continue;
        all[count] = .{ .name = entry.attr.name, .y_size = entry.attr.y_size, .where = whereOf(entry) };
        count += 1;
    }
    // Sorted, a size at a time into place.
    for (1..@max(count, 1)) |i| {
        const font = all[i];
        var at = i;
        while (at > 0 and before(ub, &font, &all[at - 1])) : (at -= 1) all[at] = all[at - 1];
        all[at] = font;
    }
    // Loaded sizes the disk lists too go.
    var kept: usize = 0;
    for (0..count) |i| {
        if (all[i].where == .loaded and onDisk(ub, all[0..count], &all[i])) continue;
        all[kept] = all[i];
        kept += 1;
    }
    const fonts = all[0..kept];
    if (fonts.len == 0) {
        _ = Printf(dl, MSG_NONE, .{});
        return dos.RETURN_WARN;
    }

    var i: usize = 0;
    while (i < fonts.len) {
        const first = fonts[i];
        _ = Printf(dl, MSG_NAME, .{first.name});
        while (i < fonts.len and fonts[i].where == first.where and ub.Stricmp(fonts[i].name, first.name) == 0) : (i += 1) {
            if (fonts[i].where != .scalable) _ = Printf(dl, MSG_SIZE, .{@as(u32, fonts[i].y_size)});
        }
        _ = Printf(dl, MSG_WHERE, .{where_names[@intFromEnum(first.where)]});
    }

    if (argv[arg_sample] != 0) return drawSamples(sys, dl, dfb, fonts);
    return dos.RETURN_OK;
}
