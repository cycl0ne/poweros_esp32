// SPDX-License-Identifier: MIT
//! Intuition: what intuition.library has made of the display. Built
//! against the SDK only.
//!
//!   Intuition WINDOWS/S,GADGETS/S,SLIDERS/S,TEXT/S,REQUEST/S,MENUS/S,REQUESTER/S,CLOSE/S
//!
//! With nothing asked for it locks the default public screen - which opens
//! it, the first time - prints its size, depth, title bar and pens, and
//! lets it go again. The screen stays open: it is the machine's, not this
//! command's.
//!
//! WINDOWS opens three windows on it - a smart one, a simple-refresh one
//! that listens on its message port, and a small one in front - writes in
//! each, moves and sizes the simple one so the others uncover and cover
//! it, and then answers its messages until they are all closed - each by
//! its own close gadget - or Ctrl-C:
//! every IDCMP_REFRESHWINDOW is a BeginRefresh, the number of damaged
//! rectangles (WA_Damage) printed, the text drawn again, and an EndRefresh; clicks inside it and keys while it is active are printed.
//! Then it closes them.
//!
//! GADGETS opens a window with three buttons - two in its top left, one
//! kept in its bottom right corner however it is sized - and prints each
//! IDCMP_GADGETUP with the gadget's ID until the third button or the close
//! gadget is used. One turns Two off and on again (OffGadget, OnGadget),
//! Two flips the window to its other box and back (ZipWindow), and every
//! press is counted in the window's title (SetWindowTitles). While the
//! window is active the screen's bar says "Gadgets demo" (WA_ScreenTitle),
//! and it may be sized up to 600 wide and the screen's height
//! (WindowLimits).
//!
//! TEXT opens a window and draws in it from descriptions: two runs of text
//! with PrintIText, the second in a colour and a place of its own, a box
//! that fits the first - measured with IntuiTextLength - with DrawBorder,
//! and a row of imageclass images with DrawImage, each the same one-bit
//! arrow in a different pair of the screen's own pens, which is the whole
//! path from a class to the glass: NewObjectTagList, the image's
//! attributes, IM_DRAW through its dispatcher, BltTemplate. It reads the
//! screen's size with LockIBase held, and its close gadget or Ctrl-C ends
//! it.
//!
//! REQUEST asks in an easy requester (EasyRequest), on the default public
//! screen, until its rightmost button is used, and prints each answer: 1
//! and 2 for the buttons from the left, 0 for the rightmost.
//!
//! MENUS opens a window with menus (SetMenuStrip): Project with shortcuts
//! and an item, Export, marked with » for the two subitems it opens,
//! Options with two checkmarks that toggle and
//! three that rule each other out, one of them disabled (OffMenu), and a
//! third menu disabled whole. Each IDCMP_MENUPICK is printed item by item
//! along the chain (ItemAddress, `next_select`) with what is checked; each
//! IDCMP_MENUVERIFY is printed and answered; with the Help key over an
//! item, its IDCMP_MENUHELP is printed. Project's Quit, the close gadget or
//! Ctrl-C ends it.
//!
//! REQUESTER opens a window with two buttons. Ask puts up a requester in
//! the window (Request): a ridge with words in it, a line to type a name
//! in - ready for typing at once (ActivateGadget) - and OK and Cancel,
//! both end gadgets that take it down. Auto asks with AutoRequestTagList. A
//! double-click of the menu button puts up the window's double-click
//! requester (SetDMRequest), answered with IDCMP_REQVERIFY. Each
//! IDCMP_REQSET, IDCMP_REQCLEAR and button is printed; the close gadget or
//! Ctrl-C ends it.
//!
//! CLOSE closes the default screen, which leaves the display black. It is
//! refused while anything else holds it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const sc = intuition.screens;
const ic = intuition.imageclass;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const LayersBase = sdk.interface.layers.LayersBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const wn = intuition.windows;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Intuition";
const VERSION_STRING = "\x00$VER: Intuition 1.7 (22.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "WINDOWS/S,GADGETS/S,SLIDERS/S,TEXT/S,REQUEST/S,MENUS/S,REQUESTER/S,CLOSE/S";
const arg_windows = 0;
const arg_gadgets = 1;
const arg_sliders = 2;
const arg_text = 3;
const arg_request = 4;
const arg_menus = 5;
const arg_requester = 6;
const arg_close = 7;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display, or it shows another screen\n";
const MSG_SCREEN = "Screen     %s, %dx%d, %d bits a pixel, title bar %d rows\n";
const MSG_PEN = "  %-16s %08lx\n";
const MSG_IMAGES = "Images     %d drawn with DrawImage\n";
const MSG_WINDOWS = "Windows    3 open - each closes with its close gadget, Ctrl-C closes the rest\n";
const MSG_NOWINDOWS = "Windows    could not open them\n";
const MSG_MESSAGE = "  %s\n";
const MSG_BUTTON = "  MOUSEBUTTONS %s at %d,%d\n";
const MSG_KEY = "  RAWKEY %02x qualifier %04x\n";
const MSG_VANILLA = "  VANILLAKEY '%c' (%02x)\n";
const MSG_CLOSEONE = "  CLOSEWINDOW - %s closed\n";
const MSG_DAMAGE = "    %d damaged rectangles\n";
const MSG_DONE = "Windows    closed after %d messages\n";
const MSG_TEXT = "Text       \"%s\" is %ld pixels wide, boxed, on a screen of %ldx%ld - the close gadget or Ctrl-C ends it\n";
const MSG_CLOSED = "Closed     the default screen\n";
const MSG_NOCLOSE = "Closed     nothing - it is locked by something else\n";

const pen_names = [_][*:0]const u8{
    "DETAILPEN",        "BLOCKPEN",     "TEXTPEN",     "SHINEPEN",
    "SHADOWPEN",        "FILLPEN",      "FILLTEXTPEN", "BACKGROUNDPEN",
    "HIGHLIGHTTEXTPEN", "BARDETAILPEN", "BARBLOCKPEN", "BARTRIMPEN",
};

/// A pointer, sixteen by sixteen, one bit to a pixel.
const arrow = [_]u8{
    0b1000_0000, 0b0000_0000, 0b1100_0000, 0b0000_0000,
    0b1110_0000, 0b0000_0000, 0b1111_0000, 0b0000_0000,
    0b1111_1000, 0b0000_0000, 0b1111_1100, 0b0000_0000,
    0b1111_1110, 0b0000_0000, 0b1111_1111, 0b0000_0000,
    0b1111_1111, 0b1000_0000, 0b1111_1100, 0b0000_0000,
    0b1101_1110, 0b0000_0000, 0b1000_1110, 0b0000_0000,
    0b0000_0111, 0b0000_0000, 0b0000_0111, 0b0000_0000,
    0b0000_0011, 0b1000_0000, 0b0000_0000, 0b0000_0000,
};

fn attr(ib: *IntuitionBase, s: *intuition.Screen, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetScreenAttrs(s, &ask);
    return value;
}

/// Six arrows in pairs of the screen's pens, in a row from (left, top).
fn drawImages(ib: *IntuitionBase, rp: *graphics.RastPort, dri: *sc.DrawInfo, left: i32, top: i32) u32 {
    const pairs = [_][2]usize{
        .{ sc.TEXTPEN, sc.BACKGROUNDPEN },    .{ sc.SHINEPEN, sc.SHADOWPEN },
        .{ sc.FILLPEN, sc.BACKGROUNDPEN },    .{ sc.FILLTEXTPEN, sc.FILLPEN },
        .{ sc.HIGHLIGHTTEXTPEN, sc.FILLPEN }, .{ sc.BARDETAILPEN, sc.BARBLOCKPEN },
    };
    var drawn: u32 = 0;
    for (pairs, 0..) |pair, i| {
        const tags = [_]TagItem{
            .{ .tag = ic.IA_Width, .data = 16 },
            .{ .tag = ic.IA_Height, .data = 16 },
            .{ .tag = ic.IA_FGPen, .data = dri.pens[pair[0]] },
            .{ .tag = ic.IA_BGPen, .data = dri.pens[pair[1]] },
            .{ .tag = ic.IA_Data, .data = @intFromPtr(&arrow) },
            .{},
        };
        const image = ib.NewObjectTagList(null, intuition.classusr.IMAGECLASS, &tags) orelse continue;
        ib.DrawImage(rp, image, left + @as(i32, @intCast(i)) * 28, top);
        ib.DisposeObject(image);
        drawn += 1;
    }
    return drawn;
}

/// A window of its own with two runs of text in it, a box around the first
/// that is exactly as wide as IntuiTextLength says, a row of images under
/// them, and the screen's size read with the screens held. Open until its
/// close gadget or Ctrl-C.
fn textDemo(sys: *ExecBase, dl: *DosBase, ib: *IntuitionBase, s: *intuition.Screen) i32 {
    const lay_lib = sys.OpenLibrary(sdk.layers.LAYERSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lay_lib);
    const lb: *LayersBase = @ptrCast(lay_lib);

    const tags = [_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(s) },
        .{ .tag = wn.WA_Left, .data = 300 },
        .{ .tag = wn.WA_Top, .data = 200 },
        .{ .tag = wn.WA_Width, .data = 320 },
        .{ .tag = wn.WA_Height, .data = 120 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Text") },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW },
        .{},
    };
    const w = ib.OpenWindowTagList(&tags) orelse {
        _ = Printf(dl, MSG_NOWINDOWS, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(w);

    const dri = ib.GetScreenDrawInfo(s);
    defer ib.FreeScreenDrawInfo(s, dri);
    var second = intuition.IntuiText{
        .front_pen = dri.pens[sc.HIGHLIGHTTEXTPEN],
        .back_pen = dri.pens[sc.FILLPEN],
        .draw_mode = graphics.DRMD_JAM2,
        .left = 0,
        .top = 20,
        .font = dri.font,
        .text = "second run, in the fill pen",
    };
    var first = intuition.IntuiText{
        .front_pen = dri.pens[sc.TEXTPEN],
        .font = dri.font,
        .text = label,
        .next = &second,
    };
    const wide = ib.IntuiTextLength(&first);

    // Two pixels clear of the letters all round, in the screen's font,
    // which is eight rows tall.
    const right = wide + 3;
    const bottom = 8 + 3;
    const corners = [_]i32{ 0, 0, right, 0, right, bottom, 0, bottom, 0, 0 };
    const box = intuition.Border{
        .left = -2,
        .top = -2,
        .front_pen = dri.pens[sc.SHINEPEN],
        .count = corners.len / 2,
        .xy = &corners,
    };

    // Inside the border, with the layer held, as every program drawing
    // into a window does.
    var drawn: u32 = 0;
    {
        const rp: *graphics.RastPort = @ptrFromInt(wattr(ib, w, wn.WA_RastPort));
        const layer: *sdk.layers.Layer = @ptrFromInt(wattr(ib, w, wn.WA_Layer));
        const left: i32 = @intCast(wattr(ib, w, wn.WA_BorderLeft) + 16);
        const top: i32 = @intCast(wattr(ib, w, wn.WA_BorderTop) + 16);
        lb.LockLayer(layer);
        defer lb.UnlockLayer(layer);
        ib.PrintIText(rp, &first, left, top);
        ib.DrawBorder(rp, &box, left, top);
        drawn = drawImages(ib, rp, dri, left, top + 44);
    }

    const held = ib.LockIBase(0);
    const width = attr(ib, s, sc.SA_Width);
    const height = attr(ib, s, sc.SA_Height);
    ib.UnlockIBase(held);
    _ = Printf(dl, MSG_IMAGES, .{drawn});
    _ = Printf(dl, MSG_TEXT, .{ label, @as(i64, wide), @as(u64, width), @as(u64, height) });

    var running = true;
    while (running and dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) {
        while (ib.GetIMsg(w)) |im| {
            const class = im.class;
            ib.ReplyIMsg(im);
            if (class == wn.IDCMP_CLOSEWINDOW) running = false;
        }
        dl.Delay(5);
    }
    return dos.RETURN_OK;
}

const label = "PowerOS";

fn wattr(ib: *IntuitionBase, w: *intuition.Window, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(w, &ask);
    return value;
}

/// A line of text inside a window's border, holding its layer while it
/// draws, as every program drawing into a window does.
fn say(ib: *IntuitionBase, gb: *GraphicsBase, lb: *LayersBase, w: *intuition.Window, line: i32, text: []const u8) void {
    const rp: *graphics.RastPort = @ptrFromInt(wattr(ib, w, wn.WA_RastPort));
    const layer: *sdk.layers.Layer = @ptrFromInt(wattr(ib, w, wn.WA_Layer));
    const left: i32 = @intCast(wattr(ib, w, wn.WA_BorderLeft));
    const top: i32 = @intCast(wattr(ib, w, wn.WA_BorderTop));
    lb.LockLayer(layer);
    defer lb.UnlockLayer(layer);
    gb.Move(rp, left + 6, top + 12 + line * 10);
    gb.Text(rp, text.ptr, @intCast(text.len));
}

/// Three windows, the middle one simple and listening, until Ctrl-C.
const gc = intuition.gadgetclass;
const MSG_GADGETS = "Gadgets    a window with three buttons - One turns Two off and on, Two zips the window, Done or the close gadget ends it\n";
const MSG_GADGETUP = "  GADGETUP  gadget %ld\n";
const MSG_GADGETS_DONE = "Gadgets    closed after %d presses\n";
const MSG_SLIDERS = "Sliders    two sliders, a line to type in and two buttons - close gadget or Ctrl-C ends it\n";
const MSG_SLIDER_AT = "Slider %ld   at %ld\n";
const MSG_TYPED = "Typed      %s\n";

fn button(ib: *IntuitionBase, prev: ?*intuition.Object, id: usize, text: [*:0]const u8, horizontal: sdk.utility.Tag, left: isize, vertical: sdk.utility.Tag, top: isize) ?*intuition.Object {
    const tags = [_]TagItem{
        .{ .tag = horizontal, .data = @bitCast(left) },
        .{ .tag = vertical, .data = @bitCast(top) },
        .{ .tag = gc.GA_Width, .data = 80 },
        .{ .tag = gc.GA_Height, .data = 20 },
        .{ .tag = gc.GA_Text, .data = @intFromPtr(text) },
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = gc.GA_Previous, .data = @intFromPtr(prev) },
        .{},
    };
    return ib.NewObjectTagList(null, intuition.classusr.BUTTONGCLASS, &tags);
}

const MSG_ANSWER = "Request    answered %ld\n";

/// The same question until it is answered with the rightmost button.
const question = intuition.EasyStruct{
    .title = "Intuition",
    .text_format = "This is an easy requester\non the screen %s.\nAsked %ld times.",
    .gadget_format = "Again|Maybe|Done",
};

fn requestDemo(dl: *DosBase, ib: *IntuitionBase, s: *intuition.Screen) i32 {
    const name: [*:0]const u8 = @ptrFromInt(attr(ib, s, sc.SA_PubName));
    var asked: u64 = 1;
    while (true) : (asked += 1) {
        const answer = intuition.requesters.EasyRequest(ib, null, question, null, .{ name, asked });
        _ = Printf(dl, MSG_ANSWER, .{@as(i64, answer)});
        if (answer == 0) break;
    }
    return dos.RETURN_OK;
}

// --- MENUS ---------------------------------------------------------------------

const mn = intuition.menus;
const MSG_MENUS = "Menus      the menu button over the window shows them - Quit, the close gadget or Ctrl-C ends it\n";
const MSG_PICK = "  MENUPICK  %s (menu %ld item %ld sub %ld)%s\n";
const MSG_NOPICK = "  MENUPICK  nothing\n";
const MSG_VERIFY = "  MENUVERIFY %s\n";
const MSG_HELP = "  MENUHELP  menu %ld item %ld sub %ld\n";

/// Every word the menus show, and which item each is.
const Entry = struct {
    word: [*:0]const u8,
    /// Its menu, and its parent item for a subitem.
    menu: u8,
    parent: ?u8 = null,
    flags: u32 = 0,
    command: u8 = 0,
    exclude: u32 = 0,
};

const project_open = 0;
const project_save = 1;
const project_export = 2;
const export_text = 3;
const export_picture = 4;
const project_quit = 5;
const options_grid = 6;
const options_snap = 7;
const options_small = 8;
const options_medium = 9;
const options_large = 10;
const other_nothing = 11;

const entries = [_]Entry{
    .{ .word = "Open...", .menu = 0, .flags = mn.COMMSEQ, .command = 'O' },
    .{ .word = "Save", .menu = 0, .flags = mn.COMMSEQ, .command = 'S' },
    .{ .word = "Export", .menu = 0 },
    .{ .word = "Text", .menu = 0, .parent = project_export, .flags = mn.COMMSEQ, .command = 'T' },
    .{ .word = "Picture", .menu = 0, .parent = project_export },
    .{ .word = "Quit", .menu = 0, .flags = mn.COMMSEQ, .command = 'Q' },
    .{ .word = "Grid", .menu = 1, .flags = mn.CHECKIT | mn.MENUTOGGLE | mn.CHECKED },
    .{ .word = "Snap", .menu = 1, .flags = mn.CHECKIT | mn.MENUTOGGLE },
    .{ .word = "Small", .menu = 1, .flags = mn.CHECKIT, .exclude = 0b11000 },
    .{ .word = "Medium", .menu = 1, .flags = mn.CHECKIT | mn.CHECKED, .exclude = 0b10100 },
    .{ .word = "Large", .menu = 1, .flags = mn.CHECKIT, .exclude = 0b01100 },
    .{ .word = "Nothing here", .menu = 2 },
};
const menu_titles = [_][*:0]const u8{ "Project", "Options", "Disabled" };

/// The strip, its items and their words, linked in place.
const Strip = struct {
    texts: [entries.len]intuition.IntuiText,
    /// The mark at the right of an item that has subitems.
    more: intuition.IntuiText,
    items: [entries.len]intuition.MenuItem,
    menus: [menu_titles.len]intuition.Menu,

    /// `row` is how tall an item is: the screen's font and a row either
    /// side.
    fn make(strip: *Strip, ib: *IntuitionBase, dri: *sc.DrawInfo, row: i32) void {
        const width: i32 = 140;
        var last: [menu_titles.len]?*intuition.MenuItem = @splat(null);
        var last_sub: ?*intuition.MenuItem = null;
        var rows: [menu_titles.len]i32 = @splat(0);
        var sub_rows: i32 = 0;
        for (entries, 0..) |entry, i| {
            const checkable = entry.flags & mn.CHECKIT != 0;
            strip.texts[i] = .{
                .front_pen = dri.pens[sc.BARDETAILPEN],
                .left = if (checkable) mn.CHECKWIDTH else 4,
                .top = 1,
                .text = entry.word,
            };
            const item = &strip.items[i];
            item.* = .{
                .width = if (entry.parent != null) 100 else width,
                .height = row,
                .flags = mn.ITEMTEXT | mn.ITEMENABLED | mn.HIGHCOMP | entry.flags,
                .mutual_exclude = entry.exclude,
                .item_fill = &strip.texts[i],
                .command = entry.command,
            };
            if (entry.parent) |parent| {
                // Beside its item, a little way in.
                item.left = width - 20;
                item.top = sub_rows * row;
                sub_rows += 1;
                if (last_sub) |before| before.next_item = item else strip.items[parent].sub_item = item;
                last_sub = item;
                continue;
            }
            item.top = rows[entry.menu] * row;
            rows[entry.menu] += 1;
            if (last[entry.menu]) |before| before.next_item = item;
            last[entry.menu] = item;
        }
        var left: i32 = 0;
        for (menu_titles, 0..) |title, m| {
            const measure = intuition.IntuiText{ .text = title, .font = dri.font };
            const title_width = ib.IntuiTextLength(&measure) + 8;
            strip.menus[m] = .{ .left = left, .width = title_width, .name = title, .next_menu = if (m + 1 < menu_titles.len) &strip.menus[m + 1] else null };
            left += title_width + 8;
        }
        for (entries, 0..) |entry, i| {
            if (entry.parent != null) continue;
            if (strip.menus[entry.menu].first_item == null) strip.menus[entry.menu].first_item = &strip.items[i];
        }
        // An item with subitems says so at its right: a second run, », one
        // character in from the edge.
        strip.more = .{ .front_pen = dri.pens[sc.BARDETAILPEN], .left = width - 12, .top = 1, .text = "\xbb" };
        for (&strip.items, 0..) |*item, i| {
            if (item.sub_item != null) strip.texts[i].next = &strip.more;
        }
    }

    /// Which entry an item is.
    fn indexOf(strip: *Strip, item: *intuition.MenuItem) usize {
        for (&strip.items, 0..) |*each, i| {
            if (each == item) return i;
        }
        return 0;
    }
};

fn menusDemo(dl: *DosBase, ib: *IntuitionBase, s: *intuition.Screen) i32 {
    const tags = [_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(s) },
        .{ .tag = wn.WA_Left, .data = 200 },
        .{ .tag = wn.WA_Top, .data = 120 },
        .{ .tag = wn.WA_Width, .data = 360 },
        .{ .tag = wn.WA_Height, .data = 160 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Menus - hold the menu button") },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_MenuHelp, .data = 1 },
        .{ .tag = wn.WA_NewLookMenus, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW | wn.IDCMP_MENUPICK | wn.IDCMP_MENUVERIFY | wn.IDCMP_MENUHELP },
        .{},
    };
    const w = ib.OpenWindowTagList(&tags) orelse {
        _ = Printf(dl, MSG_NOWINDOWS, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(w);
    const dri = ib.GetScreenDrawInfo(s);
    defer ib.FreeScreenDrawInfo(s, dri);

    // The screen's title bar is its font and three rows more; an item is
    // the font and one row above and below.
    const font_height: i32 = @as(i32, @intCast(attr(ib, s, sc.SA_BarHeight))) - 3;
    var strip: Strip = undefined;
    strip.make(ib, dri, font_height + 2);
    _ = ib.SetMenuStrip(w, &strip.menus[0]);
    defer ib.ClearMenuStrip(w);
    ib.OffMenu(w, mn.FULLMENUNUM(1, 4, mn.NOSUB));
    ib.OffMenu(w, mn.FULLMENUNUM(2, mn.NOITEM, mn.NOSUB));
    _ = Printf(dl, MSG_MENUS, .{});

    var running = true;
    while (running and dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) {
        while (ib.GetIMsg(w)) |im| {
            const class = im.class;
            const code = im.code;
            // Answered at once: this program has nothing to change first.
            if (class == wn.IDCMP_MENUVERIFY) {
                _ = Printf(dl, MSG_VERIFY, .{@as([*:0]const u8, if (code == mn.MENUHOT) "MENUHOT - the menus are ours" else "MENUWAITING")});
            }
            ib.ReplyIMsg(im);
            switch (class) {
                wn.IDCMP_CLOSEWINDOW => running = false,
                wn.IDCMP_MENUHELP => _ = Printf(dl, MSG_HELP, .{ @as(i64, mn.MENUNUM(code)), @as(i64, mn.ITEMNUM(code)), @as(i64, mn.SUBNUM(code)) }),
                wn.IDCMP_MENUPICK => {
                    if (code == mn.MENUNULL) _ = Printf(dl, MSG_NOPICK, .{});
                    var number = code;
                    while (number != mn.MENUNULL) {
                        const item = ib.ItemAddress(&strip.menus[0], number) orelse break;
                        const which = strip.indexOf(item);
                        const checked: [*:0]const u8 = if (item.flags & mn.CHECKIT == 0) "" else if (item.flags & mn.CHECKED != 0) " - checked" else " - not checked";
                        _ = Printf(dl, MSG_PICK, .{ entries[which].word, @as(i64, mn.MENUNUM(number)), @as(i64, mn.ITEMNUM(number)), @as(i64, mn.SUBNUM(number)), checked });
                        if (which == project_quit) running = false;
                        number = item.next_select;
                    }
                },
                else => {},
            }
        }
        dl.Delay(2);
    }
    return dos.RETURN_OK;
}

// --- REQUESTER -----------------------------------------------------------------

const MSG_REQUESTER = "Requester  Ask puts one up, Auto asks with AutoRequestTagList, a double-click of the menu button puts up another - close gadget or Ctrl-C ends it\n";
const MSG_REQSET = "  REQSET    %s\n";
const MSG_REQCLEAR = "  REQCLEAR  %s\n";
const MSG_REQVERIFY = "  REQVERIFY - the double-click requester is next\n";
const MSG_NAME = "  OK        name \"%s\"\n";
const MSG_CANCELLED = "  Cancel\n";
const MSG_AUTO = "  AutoRequestTagList answered %s\n";

/// An image that is a frame with words in it: the frame first, the words
/// chained behind it. Null without memory; dispose of the frame and the
/// words both.
fn framedWords(ib: *IntuitionBase, dri: *sc.DrawInfo, words: *const intuition.IntuiText, width: usize, height: usize) ?[2]*intuition.Object {
    const text = ib.NewObjectTagList(null, intuition.classusr.ITEXTICLASS, &[_]TagItem{
        .{ .tag = ic.IA_Left, .data = 10 },
        .{ .tag = ic.IA_Top, .data = 8 },
        .{ .tag = ic.IA_FGPen, .data = dri.pens[sc.TEXTPEN] },
        .{ .tag = ic.IA_Data, .data = @intFromPtr(words) },
        .{},
    }) orelse return null;
    const frame = ib.NewObjectTagList(null, intuition.classusr.FRAMEICLASS, &[_]TagItem{
        .{ .tag = ic.IA_Width, .data = width },
        .{ .tag = ic.IA_Height, .data = height },
        .{ .tag = ic.IA_FrameType, .data = ic.FRAME_RIDGE },
        .{ .tag = ic.IA_EdgesOnly, .data = 1 },
        .{ .tag = ic.IA_NextImage, .data = @intFromPtr(text) },
        .{},
    }) orelse {
        ib.DisposeObject(text);
        return null;
    };
    return .{ frame, text };
}

fn endButton(ib: *IntuitionBase, prev: ?*intuition.Object, id: usize, text: [*:0]const u8, left: isize, top: isize) ?*intuition.Object {
    const b = button(ib, prev, id, text, gc.GA_Left, left, gc.GA_Top, top) orelse return null;
    _ = ib.SetAttrsTagList(b, &[_]TagItem{ .{ .tag = gc.GA_EndGadget, .data = 1 }, .{} });
    return b;
}

fn requesterDemo(dl: *DosBase, ib: *IntuitionBase, s: *intuition.Screen) i32 {
    const rq = intuition.requesters;
    const dri = ib.GetScreenDrawInfo(s);
    defer ib.FreeScreenDrawInfo(s, dri);

    // The window's own two buttons.
    const ask_button = button(ib, null, 1, "Ask", gc.GA_Left, 20, gc.GA_Top, 30) orelse return dos.RETURN_FAIL;
    defer ib.DisposeObject(ask_button);
    const auto_button = button(ib, ask_button, 2, "Auto", gc.GA_Left, 120, gc.GA_Top, 30) orelse return dos.RETURN_FAIL;
    defer ib.DisposeObject(auto_button);

    // The requester Ask puts up: 240 by 90, in the middle of the window.
    const prompt = intuition.IntuiText{ .text = "Your name, please:", .font = dri.font };
    const ask_face = framedWords(ib, dri, &prompt, 240, 90) orelse return dos.RETURN_FAIL;
    defer for (ask_face) |o| ib.DisposeObject(o);
    const name = ib.NewObjectTagList(null, intuition.classusr.STRGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 10 },
        .{ .tag = gc.GA_Top, .data = 24 },
        .{ .tag = gc.GA_Width, .data = 220 },
        .{ .tag = gc.GA_Height, .data = 20 },
        .{ .tag = gc.GA_TabCycle, .data = 1 },
        .{ .tag = gc.STRINGA_MaxChars, .data = 40 },
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer ib.DisposeObject(name);
    const ok = endButton(ib, name, 10, "OK", 10, 58) orelse return dos.RETURN_FAIL;
    defer ib.DisposeObject(ok);
    const cancel = endButton(ib, ok, 11, "Cancel", 150, 58) orelse return dos.RETURN_FAIL;
    defer ib.DisposeObject(cancel);
    var ask: intuition.Requester = undefined;
    ib.InitRequester(&ask);
    ask.width = 240;
    ask.height = 90;
    ask.flags = rq.POINTREL;
    ask.gadgets = name;
    ask.image = ask_face[0];

    // The double-click requester: small, under the pointer.
    const quick_words = intuition.IntuiText{ .text = "Double-clicked", .font = dri.font };
    const quick_face = framedWords(ib, dri, &quick_words, 160, 60) orelse return dos.RETURN_FAIL;
    defer for (quick_face) |o| ib.DisposeObject(o);
    const close = endButton(ib, null, 20, "Close", 40, 30) orelse return dos.RETURN_FAIL;
    defer ib.DisposeObject(close);
    var quick: intuition.Requester = undefined;
    ib.InitRequester(&quick);
    quick.width = 160;
    quick.height = 60;
    quick.flags = rq.POINTREL;
    quick.rel_left = -80;
    quick.rel_top = -10;
    quick.gadgets = close;
    quick.image = quick_face[0];

    const tags = [_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(s) },
        .{ .tag = wn.WA_Left, .data = 180 },
        .{ .tag = wn.WA_Top, .data = 110 },
        .{ .tag = wn.WA_Width, .data = 380 },
        .{ .tag = wn.WA_Height, .data = 200 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Requesters") },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(ask_button) },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_GADGETUP | wn.IDCMP_CLOSEWINDOW | wn.IDCMP_REQSET | wn.IDCMP_REQCLEAR | wn.IDCMP_REQVERIFY },
        .{},
    };
    const w = ib.OpenWindowTagList(&tags) orelse {
        _ = Printf(dl, MSG_NOWINDOWS, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(w);
    _ = ib.SetDMRequest(w, &quick);
    defer _ = ib.ClearDMRequest(w);
    // Anything still up when the window goes is taken down first.
    defer if (ask.flags & rq.REQACTIVE != 0) ib.EndRequest(&ask, w);
    defer if (quick.flags & rq.REQACTIVE != 0) ib.EndRequest(&quick, w);
    _ = Printf(dl, MSG_REQUESTER, .{});

    var running = true;
    while (running and dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) {
        while (ib.GetIMsg(w)) |im| {
            const class = im.class;
            const address = im.iaddress;
            ib.ReplyIMsg(im);
            const which: [*:0]const u8 = if (address == @as(?*anyopaque, @ptrCast(&ask))) "the name requester" else "the double-click requester";
            switch (class) {
                wn.IDCMP_CLOSEWINDOW => running = false,
                wn.IDCMP_REQVERIFY => _ = Printf(dl, MSG_REQVERIFY, .{}),
                wn.IDCMP_REQSET => {
                    _ = Printf(dl, MSG_REQSET, .{which});
                    // Ready for typing at once.
                    if (address == @as(?*anyopaque, @ptrCast(&ask))) _ = ib.ActivateGadget(name, w, &ask);
                },
                wn.IDCMP_REQCLEAR => _ = Printf(dl, MSG_REQCLEAR, .{which}),
                wn.IDCMP_GADGETUP => {
                    var id: usize = 0;
                    _ = ib.GetAttr(gc.GA_ID, @ptrCast(address), &id);
                    switch (id) {
                        1 => if (!ib.Request(&ask, w)) {
                            _ = Printf(dl, MSG_NOWINDOWS, .{});
                        },
                        2 => {
                            const body = intuition.IntuiText{ .text = "Keep what was typed?" };
                            const keep = intuition.IntuiText{ .text = "Keep" };
                            const drop = intuition.IntuiText{ .text = "Drop" };
                            const answer = ib.AutoRequestTagList(w, &[_]TagItem{
                                .{ .tag = rq.SYSREQ_Body, .data = @intFromPtr(&body) },
                                .{ .tag = rq.SYSREQ_Positive, .data = @intFromPtr(&keep) },
                                .{ .tag = rq.SYSREQ_Negative, .data = @intFromPtr(&drop) },
                                .{},
                            });
                            _ = Printf(dl, MSG_AUTO, .{@as([*:0]const u8, if (answer) "Keep" else "Drop")});
                        },
                        10 => {
                            var text: usize = 0;
                            _ = ib.GetAttr(gc.STRINGA_TextVal, name, &text);
                            _ = Printf(dl, MSG_NAME, .{@as([*:0]const u8, @ptrFromInt(text))});
                        },
                        11 => _ = Printf(dl, MSG_CANCELLED, .{}),
                        else => {},
                    }
                },
                else => {},
            }
        }
        dl.Delay(2);
    }
    return dos.RETURN_OK;
}

/// A window title written with RawDoFmt.
const Title = struct {
    buffer: [48]u8 = @splat(0),
    used: usize = 0,

    fn format(t: *Title, sys: *ExecBase, comptime fmt: [:0]const u8, args: anytype) void {
        comptime exec.checkFormat(fmt, @TypeOf(args));
        const stream = exec.fmtStream(args);
        t.used = 0;
        _ = sys.RawDoFmt(fmt, &stream, &put, t);
        t.buffer[t.buffer.len - 1] = 0;
    }

    fn put(c: u8, data: ?*anyopaque) callconv(.c) void {
        const t: *Title = @ptrCast(@alignCast(data.?));
        if (t.used < t.buffer.len - 1) {
            t.buffer[t.used] = c;
            t.used += 1;
        }
    }

    fn text(t: *Title) [*:0]const u8 {
        return @ptrCast(&t.buffer);
    }
};

fn gadgetsDemo(sys: *ExecBase, dl: *DosBase, ib: *IntuitionBase, s: *intuition.Screen) i32 {
    const one = button(ib, null, 1, "One", gc.GA_Left, 20, gc.GA_Top, 30) orelse return dos.RETURN_FAIL;
    defer ib.DisposeObject(one);
    const two = button(ib, one, 2, "Two", gc.GA_Left, 120, gc.GA_Top, 30) orelse return dos.RETURN_FAIL;
    defer ib.DisposeObject(two);
    const done = button(ib, two, 3, "Done", gc.GA_RelRight, -100, gc.GA_RelBottom, -35) orelse return dos.RETURN_FAIL;
    defer ib.DisposeObject(done);

    const tags = [_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(s) },
        .{ .tag = wn.WA_Left, .data = 200 },
        .{ .tag = wn.WA_Top, .data = 150 },
        .{ .tag = wn.WA_Width, .data = 360 },
        .{ .tag = wn.WA_Height, .data = 180 },
        .{ .tag = wn.WA_MinWidth, .data = 240 },
        .{ .tag = wn.WA_MinHeight, .data = 100 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Gadgets") },
        .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr("Gadgets demo") },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(one) },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_GADGETUP | wn.IDCMP_CLOSEWINDOW },
        .{},
    };
    const w = ib.OpenWindowTagList(&tags) orelse {
        _ = Printf(dl, MSG_NOWINDOWS, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(w);

    // As large as 600 wide and the screen's height; the smallest is the
    // one it opened with.
    _ = ib.WindowLimits(w, 0, 0, 600, -1);
    _ = Printf(dl, MSG_GADGETS, .{});
    var presses: u32 = 0;
    var two_off = false;
    // Two, used in turn: the window keeps showing one while the other is
    // written.
    var titles: [2]Title = .{ .{}, .{} };
    var running = true;
    while (running and dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) {
        while (ib.GetIMsg(w)) |im| {
            const class = im.class;
            const gadget: ?*intuition.Object = @ptrCast(im.iaddress);
            ib.ReplyIMsg(im);
            if (class == wn.IDCMP_CLOSEWINDOW) running = false;
            if (class != wn.IDCMP_GADGETUP) continue;
            var id: usize = 0;
            _ = ib.GetAttr(gc.GA_ID, gadget, &id);
            presses += 1;
            _ = Printf(dl, MSG_GADGETUP, .{@as(u64, id)});
            if (id == 1) {
                if (two_off) ib.OnGadget(two, w, null) else ib.OffGadget(two, w, null);
                two_off = !two_off;
            }
            if (id == 2) ib.ZipWindow(w);
            if (id == 3) running = false;
            const title = &titles[presses % 2];
            title.format(sys, "Gadgets - %u presses", .{presses});
            ib.SetWindowTitles(w, title.text(), wn.TITLE_UNCHANGED);
        }
        dl.Delay(5);
    }
    _ = Printf(dl, MSG_GADGETS_DONE, .{presses});
    return dos.RETURN_OK;
}

/// A window with sliders down its right and along its bottom, a line to
/// type in, and a group of two buttons: one of each of the gadget classes
/// that were not here before.
fn slidersDemo(dl: *DosBase, ib: *IntuitionBase, s: *intuition.Screen) i32 {
    const pg = intuition.propgclass;
    const cu = intuition.classusr;
    // The title bar is as tall as the screen's font makes it, so what goes
    // below it is placed from there.
    const bar: isize = @intCast(attr(ib, s, sc.SA_BarHeight));

    // Down the right edge and along the bottom, each the length of the
    // window less the title bar and the corner, so both follow a resize.
    const down = ib.NewObjectTagList(null, cu.PROPGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_RelRight, .data = @bitCast(@as(isize, -17)) },
        .{ .tag = gc.GA_Top, .data = @bitCast(bar + 1) },
        .{ .tag = gc.GA_Width, .data = 16 },
        .{ .tag = gc.GA_RelHeight, .data = @bitCast(-(bar + 1) - 20) },
        .{ .tag = gc.GA_ID, .data = 1 },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEVERT },
        .{ .tag = pg.PGA_NewLook, .data = 1 },
        .{ .tag = pg.PGA_Total, .data = 100 },
        .{ .tag = pg.PGA_Visible, .data = 12 },
        .{ .tag = pg.PGA_Top, .data = 0 },
        .{ .tag = intuition.icclass.ICA_TARGET, .data = intuition.icclass.ICTARGET_IDCMP },
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer ib.DisposeObject(down);
    const across = ib.NewObjectTagList(null, cu.PROPGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 4 },
        .{ .tag = gc.GA_RelBottom, .data = @bitCast(@as(isize, -17)) },
        .{ .tag = gc.GA_RelWidth, .data = @bitCast(@as(isize, -40)) },
        .{ .tag = gc.GA_Height, .data = 16 },
        .{ .tag = gc.GA_ID, .data = 2 },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEHORIZ },
        .{ .tag = pg.PGA_NewLook, .data = 1 },
        .{ .tag = pg.PGA_Total, .data = 40 },
        .{ .tag = pg.PGA_Visible, .data = 20 },
        .{ .tag = pg.PGA_Top, .data = 0 },
        .{ .tag = gc.GA_Previous, .data = @intFromPtr(down) },
        .{ .tag = intuition.icclass.ICA_TARGET, .data = intuition.icclass.ICTARGET_IDCMP },
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer ib.DisposeObject(across);

    // A line to type into, with a buffer of its own.
    const field = ib.NewObjectTagList(null, cu.STRGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 20 },
        .{ .tag = gc.GA_Top, .data = @bitCast(bar + 6) },
        // As wide as the window leaves it: 20 on the left, the right
        // border the vertical slider sits in, and a gap before it.
        .{ .tag = gc.GA_RelWidth, .data = @bitCast(@as(isize, -44)) },
        .{ .tag = gc.GA_Height, .data = 20 },
        .{ .tag = gc.GA_ID, .data = 3 },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = gc.STRINGA_MaxChars, .data = 40 },
        .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr("type here") },
        .{ .tag = gc.GA_Previous, .data = @intFromPtr(across) },
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer ib.DisposeObject(field);

    // Two framed buttons that stand together as one gadget.
    const group = ib.NewObjectTagList(null, cu.GROUPGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 20 },
        .{ .tag = gc.GA_Top, .data = @bitCast(bar + 30) },
        .{ .tag = gc.GA_Width, .data = 180 },
        .{ .tag = gc.GA_Height, .data = 22 },
        .{ .tag = gc.GA_Previous, .data = @intFromPtr(field) },
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer ib.DisposeObject(group);
    for ([_]struct { id: usize, left: usize, text: [*:0]const u8 }{
        .{ .id = 4, .left = 0, .text = "Left" },
        .{ .id = 5, .left = 96, .text = "Right" },
    }) |one| {
        const member = ib.NewObjectTagList(null, cu.FRBUTTONCLASS, &[_]TagItem{
            .{ .tag = gc.GA_Left, .data = one.left },
            .{ .tag = gc.GA_Top, .data = 0 },
            .{ .tag = gc.GA_Width, .data = 84 },
            .{ .tag = gc.GA_Height, .data = 22 },
            .{ .tag = gc.GA_Text, .data = @intFromPtr(one.text) },
            .{ .tag = gc.GA_ID, .data = one.id },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = intuition.icclass.ICA_TARGET, .data = intuition.icclass.ICTARGET_IDCMP },
            .{},
        }) orelse return dos.RETURN_FAIL;
        var add = cu.OpMember{ .method_id = cu.OM_ADDMEMBER, .object = member };
        _ = ib.SendMessage(group, @ptrCast(&add));
    }

    const w = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(s) },
        .{ .tag = wn.WA_Left, .data = 160 },
        .{ .tag = wn.WA_Top, .data = 120 },
        .{ .tag = wn.WA_Width, .data = 320 },
        .{ .tag = wn.WA_Height, .data = 160 },
        // The group of buttons cannot shrink - a member is made absolute
        // when it joins - so the window may not be made narrower than the
        // group's own 200 plus the borders it sits between.
        .{ .tag = wn.WA_MinWidth, .data = 240 },
        .{ .tag = wn.WA_MinHeight, .data = 120 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Sliders") },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(down) },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_GADGETUP | wn.IDCMP_IDCMPUPDATE | wn.IDCMP_CLOSEWINDOW },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOWINDOWS, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(w);

    _ = Printf(dl, MSG_SLIDERS, .{});
    var running = true;
    // The last place each slider was seen, so that the interim updates a
    // drag sends - one per pointer move - are printed only when they say
    // something new. Which slider is which comes from its GA_ID.
    var last = [_]usize{ 0xFFFF, 0xFFFF };
    while (running and dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) {
        while (ib.GetIMsg(w)) |im| {
            const class = im.class;
            // Everything wanted from the message is taken while the message
            // is still ours. Replying hands it back, and the tag list of an
            // IDCMP_IDCMPUPDATE belongs to the message: it is freed with it,
            // which during a drag is as soon as the next update is sent.
            var top: usize = 0;
            var said_top = false;
            var id: usize = 0;
            var said_id = false;
            if (class == wn.IDCMP_IDCMPUPDATE) {
                if (im.iaddress) |address| {
                    const told: [*]const TagItem = @ptrCast(@alignCast(address));
                    var t: usize = 0;
                    while (told[t].tag != sdk.utility.TAG_DONE) : (t += 1) {
                        switch (told[t].tag) {
                            pg.PGA_Top => {
                                top = told[t].data;
                                said_top = true;
                            },
                            gc.GA_ID => {
                                id = told[t].data;
                                said_id = true;
                            },
                            else => {},
                        }
                    }
                }
            }
            ib.ReplyIMsg(im);
            if (class == wn.IDCMP_CLOSEWINDOW) running = false;
            // A slider says where it stands; anything else that speaks only
            // its ID is a button that was used.
            if (said_top) {
                const which: usize = if (id >= 1 and id <= last.len) id - 1 else 0;
                if (last[which] == top) continue;
                last[which] = top;
                _ = Printf(dl, MSG_SLIDER_AT, .{ @as(u64, id), @as(u64, top) });
            } else if (said_id) {
                _ = Printf(dl, MSG_GADGETUP, .{@as(u64, id)});
            }
        }
        dl.Delay(5);
    }
    var text: usize = 0;
    _ = ib.GetAttr(gc.STRINGA_TextVal, field, &text);
    if (text != 0) _ = Printf(dl, MSG_TYPED, .{@as([*:0]const u8, @ptrFromInt(text))});
    return dos.RETURN_OK;
}

fn windowsDemo(sys: *ExecBase, dl: *DosBase, ib: *IntuitionBase, s: *intuition.Screen) i32 {
    const gfx_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(gfx_lib);
    const lay_lib = sys.OpenLibrary(sdk.layers.LAYERSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lay_lib);
    const gb: *GraphicsBase = @ptrCast(gfx_lib);
    const lb: *LayersBase = @ptrCast(lay_lib);

    // Each open until its close gadget is used; whatever is left is closed
    // at the end.
    var open: [3]?*intuition.Window = .{ null, null, null };
    defer for (open) |w| ib.CloseWindow(w);
    const smart = openOne(ib, s, 40, 40, 360, 220, "Smart refresh", false) orelse {
        _ = Printf(dl, MSG_NOWINDOWS, .{});
        return dos.RETURN_FAIL;
    };
    open[0] = smart;
    const simple = openOne(ib, s, 260, 120, 360, 220, "Simple refresh, listening", true) orelse {
        _ = Printf(dl, MSG_NOWINDOWS, .{});
        return dos.RETURN_FAIL;
    };
    open[1] = simple;
    say(ib, gb, lb, smart, 0, "I keep what is covered.");
    say(ib, gb, lb, smart, 1, "The windows over me cost me nothing.");
    const simple_text = [_][]const u8{ "I keep nothing that is covered.", "Uncover me and I am told to redraw." };
    for (simple_text, 0..) |text, i| say(ib, gb, lb, simple, @intCast(i), text);

    // A third in front of both, then the simple one moved, sized and sent
    // to the back, which uncovers and covers it.
    const small = openOne(ib, s, 520, 60, 220, 120, "In front", false) orelse {
        _ = Printf(dl, MSG_NOWINDOWS, .{});
        return dos.RETURN_FAIL;
    };
    open[2] = small;
    say(ib, gb, lb, small, 0, "Close me first.");
    ib.MoveWindow(simple, 20, 30);
    ib.SizeWindow(simple, 40, 20);
    ib.WindowToBack(simple);
    ib.WindowToFront(simple);
    ib.ActivateWindow(smart);

    _ = Printf(dl, MSG_WINDOWS, .{});
    var messages: u32 = 0;
    while ((open[0] != null or open[1] != null or open[2] != null) and dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) {
        // The other two only listen for their close gadget.
        for ([_]usize{ 0, 2 }) |k| {
            const w = open[k] orelse continue;
            var close = false;
            while (ib.GetIMsg(w)) |im| {
                if (im.class == wn.IDCMP_CLOSEWINDOW) close = true;
                ib.ReplyIMsg(im);
                messages += 1;
            }
            if (close) {
                ib.CloseWindow(w);
                open[k] = null;
                _ = Printf(dl, MSG_CLOSEONE, .{if (k == 0) @as([*:0]const u8, "Smart refresh") else @as([*:0]const u8, "In front")});
            }
        }
        const listener = open[1] orelse {
            dl.Delay(5);
            continue;
        };
        var closing = false;
        while (ib.GetIMsg(listener)) |im| {
            const class = im.class;
            const code = im.code;
            const x = im.mouse_x;
            const y = im.mouse_y;
            const qualifier = im.qualifier;
            ib.ReplyIMsg(im);
            messages += 1;
            switch (class) {
                wn.IDCMP_MOUSEBUTTONS => {
                    const what: [*:0]const u8 = if (code == wn.SELECTDOWN) "down" else "up";
                    _ = Printf(dl, MSG_BUTTON, .{ what, x, y });
                    continue;
                },
                wn.IDCMP_RAWKEY => {
                    _ = Printf(dl, MSG_KEY, .{ code, qualifier });
                    continue;
                },
                wn.IDCMP_VANILLAKEY => {
                    _ = Printf(dl, MSG_VANILLA, .{ code, code });
                    continue;
                },
                wn.IDCMP_CLOSEWINDOW => closing = true,
                else => {},
            }
            const name: [*:0]const u8 = switch (class) {
                wn.IDCMP_REFRESHWINDOW => "REFRESHWINDOW - drawn again",
                wn.IDCMP_NEWSIZE => "NEWSIZE",
                wn.IDCMP_CHANGEWINDOW => "CHANGEWINDOW",
                wn.IDCMP_ACTIVEWINDOW => "ACTIVEWINDOW",
                wn.IDCMP_INACTIVEWINDOW => "INACTIVEWINDOW",
                wn.IDCMP_CLOSEWINDOW => "CLOSEWINDOW - closed",
                else => "another",
            };
            _ = Printf(dl, MSG_MESSAGE, .{name});
            if (class == wn.IDCMP_REFRESHWINDOW) {
                ib.BeginRefresh(simple);
                // What needs drawing: everything drawn is cut to it anyway,
                // and a program that would rather skip the rest reads it.
                const damage = wattr(ib, simple, wn.WA_Damage);
                if (damage != 0) _ = Printf(dl, MSG_DAMAGE, .{gb.RegionRectangles(@ptrFromInt(damage), null, 0)});
                for (simple_text, 0..) |text, i| say(ib, gb, lb, simple, @intCast(i), text);
                ib.EndRefresh(simple, true);
            }
        }
        if (closing) {
            ib.CloseWindow(listener);
            open[1] = null;
        }
        dl.Delay(5);
    }
    _ = Printf(dl, MSG_DONE, .{messages});
    return dos.RETURN_OK;
}

/// What the simple window listens for: its refresh and its box, and the
/// input that reaches it.
const listening = wn.IDCMP_REFRESHWINDOW | wn.IDCMP_NEWSIZE | wn.IDCMP_CHANGEWINDOW | wn.IDCMP_ACTIVEWINDOW |
    wn.IDCMP_INACTIVEWINDOW | wn.IDCMP_MOUSEBUTTONS | wn.IDCMP_RAWKEY | wn.IDCMP_VANILLAKEY | wn.IDCMP_CLOSEWINDOW;

fn openOne(ib: *IntuitionBase, s: *intuition.Screen, left: usize, top: usize, width: usize, height: usize, title: [*:0]const u8, simple: bool) ?*intuition.Window {
    const tags = [_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(s) },
        .{ .tag = wn.WA_Left, .data = left },
        .{ .tag = wn.WA_Top, .data = top },
        .{ .tag = wn.WA_Width, .data = width },
        .{ .tag = wn.WA_Height, .data = height },
        .{ .tag = wn.WA_Title, .data = @intFromPtr(title) },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_SimpleRefresh, .data = @intFromBool(simple) },
        .{ .tag = wn.WA_IDCMP, .data = if (simple) listening else wn.IDCMP_CLOSEWINDOW },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    };
    return ib.OpenWindowTagList(&tags);
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [8]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(lib);
    const ib: *IntuitionBase = @ptrCast(lib);

    const s = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_WARN;
    };

    if (argv[arg_close] != 0) {
        ib.UnlockPubScreen(null, s);
        if (ib.CloseScreen(s)) {
            _ = Printf(dl, MSG_CLOSED, .{});
            return dos.RETURN_OK;
        }
        _ = Printf(dl, MSG_NOCLOSE, .{});
        return dos.RETURN_WARN;
    }
    defer ib.UnlockPubScreen(null, s);

    const name: [*:0]const u8 = @ptrFromInt(attr(ib, s, sc.SA_PubName));
    _ = Printf(dl, MSG_SCREEN, .{
        name,
        @as(u32, @intCast(attr(ib, s, sc.SA_Width))),
        @as(u32, @intCast(attr(ib, s, sc.SA_Height))),
        @as(u32, @intCast(attr(ib, s, sc.SA_Depth))),
        @as(u32, @intCast(attr(ib, s, sc.SA_BarHeight))),
    });

    if (argv[arg_windows] != 0) return windowsDemo(sys, dl, ib, s);
    if (argv[arg_gadgets] != 0) return gadgetsDemo(sys, dl, ib, s);
    if (argv[arg_sliders] != 0) return slidersDemo(dl, ib, s);

    if (argv[arg_text] != 0) return textDemo(sys, dl, ib, s);
    if (argv[arg_request] != 0) return requestDemo(dl, ib, s);
    if (argv[arg_menus] != 0) return menusDemo(dl, ib, s);
    if (argv[arg_requester] != 0) return requesterDemo(dl, ib, s);

    const dri = ib.GetScreenDrawInfo(s);
    defer ib.FreeScreenDrawInfo(s, dri);
    for (pen_names, 0..) |pen_name, i| {
        _ = Printf(dl, MSG_PEN, .{ pen_name, @as(u64, dri.pens[i]) });
    }
    return dos.RETURN_OK;
}
