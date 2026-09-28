// SPDX-License-Identifier: MIT
//! FontView: every font there is, and a line drawn in the one chosen.
//! Built against the SDK only.
//!
//!   FontView
//!
//! A window on the default public screen: the font families on the left,
//! as diskfont.library's AvailFonts knows them - in the ROM, in memory, on
//! the disk - and the sizes of the one chosen beside them: the heights it
//! was drawn at, or, for a family with an outline, a range of heights to
//! render it at. Choosing a size opens that font with OpenDiskFont; a line
//! under the lists says what it is - rows, where it came from, whether it
//! was drawn or made, its kind of pixels - and a sample line is drawn in
//! it below. The close gadget or Ctrl-C ends it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const diskfont = sdk.diskfont;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const tx = sdk.gadgets.text;
const lv = sdk.gadgets.listview;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "FontView";
const VERSION_STRING = "\x00$VER: FontView 1.0 (28.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "";

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display\n";
const MSG_NOMEMORY = "No memory for the window\n";
const MSG_NOFONTS = "No fonts\n";

const ID_FONTS = 1;
const ID_SIZES = 2;

/// The line drawn in the chosen font.
const sample = "The quick brown fox jumps over the lazy dog - 0123456789 - \xc4\xd6\xdc\xe4\xf6\xfc\xdf";

/// The heights an outline is offered at.
const outline_sizes = [_]u16{ 8, 10, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64 };

const max_families = 64;
const max_sizes = 32;

/// A family: its line in the list, its name, the heights it has.
const Family = extern struct {
    node: exec.Node = .{},
    name: [32]u8 = @splat(0),
    sizes: [max_sizes]u16 = @splat(0),
    size_count: u32 = 0,
    /// It has an outline: any height, the heights offered are a range.
    scalable: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
};

/// A line of the size list.
const SizeLine = extern struct {
    node: exec.Node = .{},
    label: [24]u8 = @splat(0),
};

/// What the program holds between events.
const State = struct {
    families: [max_families]Family = undefined,
    family_count: u32 = 0,
    family_list: exec.List = .{},
    size_lines: [max_sizes]SizeLine = undefined,
    size_list: exec.List = .{},
    /// The family chosen, the font open for the preview, and the line
    /// that says what it is.
    chosen: ?*Family = null,
    font: ?*graphics.TextFont = null,
    about: [96]u8 = @splat(0),
};

fn copyName(to: []u8, from: [*:0]const u8) void {
    var i: usize = 0;
    while (from[i] != 0 and i + 1 < to.len) : (i += 1) to[i] = from[i];
    to[i] = 0;
}

/// The family of that name, made if it is new.
fn familyOf(ub: *UtilityBase, state: *State, name: [*:0]const u8) ?*Family {
    for (state.families[0..state.family_count]) |*family| {
        if (ub.Stricmp(@ptrCast(&family.name), name) == 0) return family;
    }
    if (state.family_count == max_families) return null;
    const family = &state.families[state.family_count];
    family.* = .{};
    copyName(&family.name, name);
    family.node.name = @ptrCast(&family.name);
    state.family_count += 1;
    return family;
}

/// A height into a family's list, once, in order.
fn addSize(family: *Family, rows: u16) void {
    if (rows == 0) return;
    const sizes = family.sizes[0..family.size_count];
    for (sizes) |have| if (have == rows) return;
    if (family.size_count == max_sizes) return;
    var at = family.size_count;
    while (at > 0 and family.sizes[at - 1] > rows) : (at -= 1) family.sizes[at] = family.sizes[at - 1];
    family.sizes[at] = rows;
    family.size_count += 1;
}

/// Every family AvailFonts knows, with its heights, sorted by name.
fn collect(sys: *ExecBase, ub: *UtilityBase, dfb: *DiskfontBase, state: *State) void {
    var size: u32 = 2048;
    while (true) {
        const buffer = sys.AllocVec(size, exec.MEMF_ANY) orelse return;
        defer sys.FreeVec(buffer);
        const more = dfb.AvailFonts(buffer, size, diskfont.AFF_MEMORY | diskfont.AFF_DISK);
        if (more != 0) {
            size += more;
            continue;
        }
        const header: *const diskfont.AvailFontsHeader = @ptrCast(@alignCast(buffer));
        for (diskfont.availEntries(header)) |*entry| {
            const family = familyOf(ub, state, entry.attr.name) orelse continue;
            if (entry.type & diskfont.AFF_SCALABLE != 0) {
                family.scalable = 1;
            } else {
                addSize(family, entry.attr.y_size);
            }
        }
        break;
    }
    // A family with an outline is offered a range of heights beside any
    // it has drawn.
    for (state.families[0..state.family_count]) |*family| {
        if (family.scalable != 0) for (outline_sizes) |rows| addSize(family, rows);
    }
    // By name, then onto the list.
    const families = state.families[0..state.family_count];
    for (1..@max(families.len, 1)) |i| {
        const family = families[i];
        var at = i;
        while (at > 0 and ub.Stricmp(@ptrCast(&family.name), @ptrCast(&families[at - 1].name)) < 0) : (at -= 1) families[at] = families[at - 1];
        families[at] = family;
    }
    state.family_list.init(.unknown);
    for (families) |*family| {
        family.node.name = @ptrCast(&family.name);
        sys.AddTail(&state.family_list, &family.node);
    }
}

/// The size list made again for `family`.
fn fillSizes(sys: *ExecBase, state: *State, family: *Family) void {
    state.size_list.init(.unknown);
    for (family.sizes[0..family.size_count], 0..) |rows, i| {
        const line = &state.size_lines[i];
        line.* = .{};
        var number: [8]u8 = undefined;
        var digits: usize = 0;
        var value = rows;
        while (true) {
            number[digits] = '0' + @as(u8, @intCast(value % 10));
            digits += 1;
            value /= 10;
            if (value == 0) break;
        }
        for (0..digits) |d| line.label[d] = number[digits - 1 - d];
        const rest = " rows";
        for (rest, 0..) |c, k| line.label[digits + k] = c;
        line.node.name = @ptrCast(&line.label);
        sys.AddTail(&state.size_list, &line.node);
    }
}

/// The line that says what `font` is.
fn describe(state: *State, font: *graphics.TextFont) void {
    const image = font.image;
    const from: []const u8 = if (font.flags & graphics.FPF_ROMFONT != 0)
        "ROM"
    else if (font.flags & graphics.FPF_DISKFONT != 0)
        "disk"
    else
        "memory";
    const made: []const u8 = if (image.flags & graphics.FPF_DESIGNED != 0) "drawn" else "scaled";
    const kind: []const u8 = switch (image.kind) {
        .mono1 => "ink",
        .alpha4 => "smooth",
        .indexed8 => "colour",
        else => "?",
    };
    const spacing: []const u8 = if (image.flags & graphics.FPF_PROPORTIONAL != 0) "proportional" else "fixed width";
    const out: []u8 = &state.about;
    var at: usize = 0;
    const put = struct {
        fn f(buffer: []u8, pos: *usize, text: []const u8) void {
            for (text) |c| {
                if (pos.* + 1 >= buffer.len) return;
                buffer[pos.*] = c;
                pos.* += 1;
            }
        }
    }.f;
    var name_len: usize = 0;
    const name = font.node.name orelse "";
    while (name[name_len] != 0) name_len += 1;
    put(out, &at, name[0..name_len]);
    put(out, &at, ", ");
    var number: [8]u8 = undefined;
    var digits: usize = 0;
    var value: u32 = image.height;
    while (true) {
        number[digits] = '0' + @as(u8, @intCast(value % 10));
        digits += 1;
        value /= 10;
        if (value == 0) break;
    }
    var k: usize = digits;
    while (k > 0) : (k -= 1) put(out, &at, number[k - 1 .. k]);
    put(out, &at, " rows - ");
    put(out, &at, made);
    put(out, &at, ", ");
    put(out, &at, from);
    put(out, &at, ", ");
    put(out, &at, kind);
    put(out, &at, ", ");
    put(out, &at, spacing);
    out[at] = 0;
}

/// Everything the window needs to change when a size is chosen: the font
/// opened, the sample drawn in it, the line saying what it is.
fn choose(gb: *GraphicsBase, ib: *IntuitionBase, dfb: *DiskfontBase, state: *State, window: *intuition.Window, preview: *Object, about: *Object, line: u32) void {
    const family = state.chosen orelse return;
    if (line >= family.size_count) return;
    const rows = family.sizes[line];
    // A drawn size as drawn; an outline at any height.
    const flags: graphics.FontFlags = if (family.scalable != 0) 0 else graphics.FPF_DESIGNED;
    const font = dfb.OpenDiskFont(&.{ .name = @ptrCast(&family.name), .y_size = rows, .flags = flags }) orelse return;
    describe(state, font);
    _ = ib.SetGadgetAttrsTagList(preview, window, &[_]TagItem{
        .{ .tag = tx.TEXT_Font, .data = @intFromPtr(font) },
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr(sample) },
        .{},
    });
    _ = ib.SetGadgetAttrsTagList(about, window, &[_]TagItem{
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&state.about) },
        .{},
    });
    // The gadget has the new one; the old one can go.
    if (state.font) |old| gb.CloseFont(old);
    state.font = font;
}

/// A family chosen: its sizes listed, the middle one of them shown.
fn chooseFamily(sys: *ExecBase, gb: *GraphicsBase, ib: *IntuitionBase, dfb: *DiskfontBase, state: *State, window: *intuition.Window, sizes: *Object, preview: *Object, about: *Object, line: u32) void {
    if (line >= state.family_count) return;
    const family = &state.families[line];
    state.chosen = family;
    _ = ib.SetGadgetAttrsTagList(sizes, window, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Labels, .data = lv.LISTVIEW_DETACH }, .{} });
    fillSizes(sys, state, family);
    const shown: u32 = if (family.size_count == 0) lv.LISTVIEW_NONE else family.size_count / 2;
    _ = ib.SetGadgetAttrsTagList(sizes, window, &[_]TagItem{
        .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&state.size_list) },
        .{ .tag = lv.LISTVIEW_Selected, .data = shown },
        .{ .tag = lv.LISTVIEW_MakeVisible, .data = if (shown == lv.LISTVIEW_NONE) 0 else shown },
        .{},
    });
    if (shown != lv.LISTVIEW_NONE) choose(gb, ib, dfb, state, window, preview, about, shown);
}

const Parts = struct { layout: *Object, fonts: *Object, sizes: *Object, about: *Object, preview: *Object };

fn build(ib: *IntuitionBase, state: *State) ?Parts {
    const fonts = ib.NewObjectTagList(null, lv.LISTVIEW_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_FONTS },
        .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&state.family_list) },
        .{ .tag = lv.LISTVIEW_ShowSelected, .data = 1 },
        .{},
    });
    const sizes = ib.NewObjectTagList(null, lv.LISTVIEW_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_SIZES },
        .{ .tag = lv.LISTVIEW_ShowSelected, .data = 1 },
        .{},
    });
    const about = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr("Choose a font and a size") },
        .{ .tag = tx.TEXT_Border, .data = 1 },
        .{ .tag = tx.TEXT_Clipped, .data = 1 },
        .{},
    });
    const preview = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr("") },
        .{ .tag = tx.TEXT_Border, .data = 1 },
        .{ .tag = tx.TEXT_Clipped, .data = 1 },
        .{},
    });
    const lists = if (fonts != null and sizes != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(fonts) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Font") },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 3 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(sizes) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Size") },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 1 },
        .{},
    }) else null;
    const parts = [_]?*Object{ lists, about, preview };
    var whole = true;
    for (parts) |part| whole = whole and part != null;
    const layout = if (whole) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(lists) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(about) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(preview) },
        .{ .tag = lg.CHILDA_MinHeight, .data = 100 },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{},
    }) else null;
    const made = layout orelse {
        // What a layout took is its own; only what none took goes here.
        if (lists == null) {
            ib.DisposeObject(fonts);
            ib.DisposeObject(sizes);
        }
        for (parts) |part| ib.DisposeObject(part);
        return null;
    };
    return .{ .layout = made, .fonts = fonts.?, .sizes = sizes.?, .about = about.?, .preview = preview.? };
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

    const names = [_][*:0]const u8{ sdk.interface.utility.NAME, graphics.GRAPHICSNAME, intuition.INTUITIONNAME, diskfont.DISKFONTNAME, lv.LISTVIEW_LIBRARY, tx.TEXT_LIBRARY };
    var libraries: [names.len]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    for (names, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{name});
            return dos.RETURN_FAIL;
        };
    }
    const ub: *UtilityBase = @ptrCast(libraries[0].?);
    const gb: *GraphicsBase = @ptrCast(libraries[1].?);
    const ib: *IntuitionBase = @ptrCast(libraries[2].?);
    const dfb: *DiskfontBase = @ptrCast(libraries[3].?);

    // Too big for a stack: in memory of its own.
    const state_memory = sys.AllocVec(@sizeOf(State), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(state_memory);
    const state: *State = @ptrCast(@alignCast(state_memory));
    state.* = .{};
    // Closed after the window, whose preview draws in it.
    defer if (state.font) |font| gb.CloseFont(font);
    collect(sys, ub, dfb, state);
    if (state.family_count == 0) {
        _ = Printf(dl, MSG_NOFONTS, .{});
        return dos.RETURN_WARN;
    }
    state.size_list.init(.unknown);

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);

    const parts = build(ib, state) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("FontView") },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_InnerWidth, .data = 720 },
        .{ .tag = wn.WA_InnerHeight, .data = 420 },
        .{ .tag = wn.WA_AutoAdjust, .data = 1 },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(parts.layout) },
        .{},
    }) orelse {
        ib.DisposeObject(parts.layout);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.DisposeObject(object);

    var open = wc.WmOpen{};
    if (ib.SendMessage(object, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    var window_ptr: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_ptr);
    const window: *intuition.Window = @ptrFromInt(window_ptr);

    // The first family shown to begin with.
    _ = ib.SetGadgetAttrsTagList(parts.fonts, window, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Selected, .data = 0 }, .{} });
    chooseFamily(sys, gb, ib, dfb, state, window, parts.sizes, parts.preview, parts.about, 0);

    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    while (true) {
        const got = ib.WaitIMsg(window, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_OK;
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_FONTS => chooseFamily(sys, gb, ib, dfb, state, window, parts.sizes, parts.preview, parts.about, code),
                    ID_SIZES => choose(gb, ib, dfb, state, window, parts.preview, parts.about, code),
                    else => {},
                },
                else => {},
            }
        }
    }
}
