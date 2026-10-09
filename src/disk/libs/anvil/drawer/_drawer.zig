// SPDX-License-Identifier: MIT
//! A disk or a drawer opened into a window of its icons, or of its files
//! as text.
//!
//! **The window** is one of the desktop's: on its shared port, with its
//! menus and its screen title, and GimmeZeroZero, so what the desktop
//! draws inside is cut at the border. Its box is the one the drawer's
//! icon keeps (`DrawerData`), or else half the screen, a little further
//! down and across for each drawer open - and the whole screen under its
//! bar when the screen is narrower than 640. Bars in the right and bottom
//! borders scroll it.
//!
//! **Reading** is a piece at a time: `ExAll` a bufferful in each round of
//! the desktop's loop, so a drawer of thousands of files on a card does
//! not stop the desktop answering. A file `x.info` is `x`'s icon, not a
//! file of its own; `.backdrop` is the desktop's own and not shown. With
//! all files shown - the default - a file without an icon gets its
//! default; with only icons, only files with an icon of their own.
//!
//! **Icons** lie where their files say; the rest go in the next free cell
//! along the rows, one after another as they are read. **As text**, a row
//! for each file (`textview.zig`).
//!
//! **Following**: the drawer is watched with StartNotify and read again
//! when it changes - whoever changed it.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const icon = sdk.icon;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const utility = sdk.utility;
const anvil_prefs = sdk.prefs.anvil;
const notify = dos.notify;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const icc = intuition.icclass;
const pg = intuition.propgclass;
const sr = sdk.gadgets.scroller;
const TagItem = utility.TagItem;
const Rect = graphics.Rect;
const icons = @import("../icons/_icons.zig");
const Icon = icons.Icon;
const path = @import("path.zig");
const textview = @import("textview.zig");
const Desktop = @import("../desktop/_desktop.zig").Desktop;

pub const View = anvil_prefs.View;

/// How many bytes of entries one ExAll is given: a few dozen files.
const chunk_bytes = 4096;

/// The two bars' gadget IDs.
pub const ID_VERT = 1;
pub const ID_HORIZ = 2;

/// The room kept clear round a drawer's icons.
const margin = 8;

/// The IDCMP classes a drawer window takes.
const drawer_idcmp = wn.IDCMP_MOUSEBUTTONS | wn.IDCMP_MOUSEMOVE | wn.IDCMP_MENUPICK | wn.IDCMP_REFRESHWINDOW |
    wn.IDCMP_CLOSEWINDOW | wn.IDCMP_NEWSIZE | wn.IDCMP_IDCMPUPDATE | wn.IDCMP_ACTIVEWINDOW |
    wn.IDCMP_DISKINSERTED | wn.IDCMP_DISKREMOVED | wn.IDCMP_NEWPREFS;

/// The longest title: the name and how full its disk is.
const title_max = 160;

pub const Drawer = struct {
    node: exec.Node = .{},
    window: *intuition.Window,
    /// The inside's RastPort: (0, 0) is the inside's corner. Its layer is
    /// held while anything is drawn into it.
    rp: *graphics.RastPort,
    layer: *sdk.layers.Layer,
    inner_width: i32 = 0,
    inner_height: i32 = 0,
    path: [dos.path_max + 1]u8 = @splat(0),
    path_len: u16 = 0,
    is_volume: bool = false,
    view: View = .icon,
    show_all: bool = true,
    icons: exec.List = .{},
    /// How far it has been read: a lock while there is more.
    lock: ?*dos.FileLock = null,
    control: ?*dos.ExAllControl = null,
    buffer: ?[*]u8 = null,
    /// The next free cell's number along the rows.
    next_cell: i32 = 0,
    /// Where the inside's (0, 0) is on the drawer's ground.
    origin: icons.Origin = .{},
    bars: [2]?*intuition.Object = .{ null, null },
    watch: notify.NotifyRequest = .{},
    watched: bool = false,
    title: [title_max:0]u8 = @splat(0),

    pub fn pathText(dr: *const Drawer) []const u8 {
        return dr.path[0..dr.path_len];
    }

    pub fn reading(dr: *const Drawer) bool {
        return dr.lock != null;
    }
};

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const left = if (x >= 'a' and x <= 'z') x - 32 else x;
        const right = if (y >= 'a' and y <= 'z') y - 32 else y;
        if (left != right) return false;
    }
    return true;
}

/// The drawer open on `path`, if one is.
pub fn findPath(d: *Desktop, wanted: []const u8) ?*Drawer {
    var it = d.drawers.iterator();
    while (it.next()) |node| {
        const dr: *Drawer = @alignCast(@fieldParentPtr("node", node));
        if (same(dr.pathText(), wanted)) return dr;
    }
    return null;
}

/// The drawer whose window `window` is.
pub fn find(d: *Desktop, window: ?*intuition.Window) ?*Drawer {
    const wanted = window orelse return null;
    var it = d.drawers.iterator();
    while (it.next()) |node| {
        const dr: *Drawer = @alignCast(@fieldParentPtr("node", node));
        if (dr.window == wanted) return dr;
    }
    return null;
}

fn windowAttr(d: *Desktop, window: *intuition.Window, tag: utility.Tag) i32 {
    var value: usize = 0;
    d.ib.GetWindowAttrs(window, &[_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} });
    return @bitCast(@as(u32, @truncate(value)));
}

/// `path` opened into a window: brought to the front when it is open
/// already. The drawer's icon (`Disk.info` for a volume) gives the box,
/// the view and what is shown.
pub fn open(d: *Desktop, wanted: []const u8) void {
    if (findPath(d, wanted)) |dr| {
        d.ib.WindowToFront(dr.window);
        d.ib.ActivateWindow(dr.window);
        return;
    }
    if (wanted.len == 0 or wanted.len > dos.path_max) return;
    const memory = d.sys.AllocVec(@sizeOf(Drawer), exec.MEMF_CLEAR) orelse return;
    const dr: *Drawer = @ptrCast(@alignCast(memory));
    var name: [dos.path_max + 1:0]u8 = @splat(0);
    @memcpy(name[0..wanted.len], wanted);
    const object = d.icon_base.GetDiskObjectNew(&name);
    defer if (object) |held| d.icon_base.FreeDiskObject(held);

    var view = d.prefs.view;
    var show_all = true;
    var place_at = defaultBox(d);
    if (object) |held| if (held.drawer_data) |data| {
        if (data.width > 0 and data.height > 0) place_at = .{ .min_x = data.left, .min_y = data.top, .max_x = data.left + data.width, .max_y = data.top + data.height };
        if (data.view_modes >= icon.DDVM_BYICON and data.view_modes <= icon.DDVM_BYSIZE) view = @enumFromInt(data.view_modes - icon.DDVM_BYICON);
        if (data.flags & icon.DDFLAGS_SHOWICONS != 0) show_all = false;
    };

    const window = d.ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(d.screen) },
        .{ .tag = wn.WA_Left, .data = @bitCast(@as(isize, place_at.min_x)) },
        .{ .tag = wn.WA_Top, .data = @bitCast(@as(isize, place_at.min_y)) },
        .{ .tag = wn.WA_Width, .data = @intCast(place_at.max_x - place_at.min_x) },
        .{ .tag = wn.WA_Height, .data = @intCast(place_at.max_y - place_at.min_y) },
        .{ .tag = wn.WA_MinWidth, .data = 120 },
        .{ .tag = wn.WA_MinHeight, .data = 80 },
        .{ .tag = wn.WA_MaxWidth, .data = @bitCast(@as(isize, -1)) },
        .{ .tag = wn.WA_MaxHeight, .data = @bitCast(@as(isize, -1)) },
        .{ .tag = wn.WA_Title, .data = @intFromPtr(&dr.title) },
        .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(&d.title) },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_SizeBRight, .data = 1 },
        .{ .tag = wn.WA_SizeBBottom, .data = 1 },
        .{ .tag = wn.WA_GimmeZeroZero, .data = 1 },
        .{ .tag = wn.WA_SimpleRefresh, .data = 1 },
        .{ .tag = wn.WA_NewLookMenus, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_UserPort, .data = @intFromPtr(d.windows_port) },
        .{ .tag = wn.WA_IDCMP, .data = drawer_idcmp },
        .{},
    }) orelse {
        d.sys.FreeVec(memory);
        return;
    };
    var rp: usize = 0;
    var layer: usize = 0;
    d.ib.GetWindowAttrs(window, &[_]TagItem{
        .{ .tag = wn.WA_RastPort, .data = @intFromPtr(&rp) },
        .{ .tag = wn.WA_Layer, .data = @intFromPtr(&layer) },
        .{},
    });
    dr.* = .{
        .window = window,
        .rp = @ptrFromInt(rp),
        .layer = @ptrFromInt(layer),
        .path_len = @intCast(wanted.len),
        .is_volume = wanted[wanted.len - 1] == ':',
        .view = view,
        .show_all = show_all,
    };
    @memcpy(dr.path[0..wanted.len], wanted);
    dr.icons.init(.unknown);
    measure(d, dr);
    makeTitle(d, dr);
    d.ib.SetWindowTitles(window, &dr.title, wn.TITLE_UNCHANGED);
    if (d.menu_strip) |strip| _ = d.ib.SetMenuStrip(window, strip);
    makeBars(d, dr);
    d.sys.AddTail(&d.drawers, &dr.node);
    d.showChecks(dr.view, dr.show_all);

    // Followed: read again when it changes.
    dr.watch = .{ .name = @ptrCast(&dr.path), .flags = notify.NRF_SEND_MESSAGE, .port = d.notify_port, .user_data = @intFromPtr(dr) };
    dr.watched = d.dl.StartNotify(&dr.watch);
    startReading(d, dr);
}

/// Where a drawer opens without a box of its own: half the screen,
/// cascading; the whole screen under its bar on a narrow one.
fn defaultBox(d: *Desktop) Rect {
    const top = d.bar_height + 1;
    if (d.screen_width < 640) return .{ .min_x = 0, .min_y = top, .max_x = d.screen_width, .max_y = d.screen_height };
    var count: i32 = 0;
    var it = d.drawers.iterator();
    while (it.next()) |_| count += 1;
    const cascade = @rem(count, 8) * 24;
    const width = @divTrunc(d.screen_width, 2);
    const height = @divTrunc(d.screen_height, 2);
    return .{ .min_x = 40 + cascade, .min_y = top + 20 + cascade, .max_x = 40 + cascade + width, .max_y = top + 20 + cascade + height };
}

/// The inside's size, as the window is now.
fn measure(d: *Desktop, dr: *Drawer) void {
    const width = windowAttr(d, dr.window, wn.WA_Width);
    const height = windowAttr(d, dr.window, wn.WA_Height);
    const left = windowAttr(d, dr.window, wn.WA_BorderLeft);
    const top = windowAttr(d, dr.window, wn.WA_BorderTop);
    const right = windowAttr(d, dr.window, wn.WA_BorderRight);
    const bottom = windowAttr(d, dr.window, wn.WA_BorderBottom);
    dr.inner_width = @max(0, width - left - right);
    dr.inner_height = @max(0, height - top - bottom);
}

/// The window's title: the drawer's name, and for a disk how full it is.
fn makeTitle(d: *Desktop, dr: *Drawer) void {
    const name = path.lastPart(dr.pathText());
    if (!dr.is_volume) {
        const length = @min(name.len, title_max);
        @memcpy(dr.title[0..length], name[0..length]);
        dr.title[length] = 0;
        return;
    }
    var info: dos.InfoData = .{};
    const lock = d.dl.Lock(@ptrCast(&dr.path), dos.SHARED_LOCK);
    defer if (lock) |held| d.dl.UnLock(held);
    const known = if (lock) |held| d.dl.Info(held, &info) else false;
    const shown = name[0..@min(name.len, 64)];
    if (known) {
        _ = path.diskTitle(&dr.title, shown, info.num_blocks, info.num_blocks_used, info.bytes_per_block);
    } else {
        _ = path.diskTitle(&dr.title, shown, 0, 0, 0);
    }
}

/// The bars in the right and bottom borders, aimed at the window's IDCMP.
/// Without scroller.gadget the drawer has none.
fn makeBars(d: *Desktop, dr: *Drawer) void {
    if (!d.has_scroller) return;
    const window = dr.window;
    const left = windowAttr(d, window, wn.WA_BorderLeft);
    const top = windowAttr(d, window, wn.WA_BorderTop);
    const right = windowAttr(d, window, wn.WA_BorderRight);
    const bottom = windowAttr(d, window, wn.WA_BorderBottom);
    const vert = d.ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_VERT },
        .{ .tag = gc.GA_RightBorder, .data = 1 },
        .{ .tag = gc.GA_RelRight, .data = @bitCast(@as(isize, -(right - 1))) },
        .{ .tag = gc.GA_Top, .data = @bitCast(@as(isize, top)) },
        .{ .tag = gc.GA_Width, .data = @bitCast(@as(isize, right)) },
        .{ .tag = gc.GA_RelHeight, .data = @bitCast(@as(isize, -(top + bottom))) },
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEVERT },
        .{ .tag = sr.SCROLLER_Arrows, .data = @bitCast(@as(isize, bottom)) },
        .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
        .{},
    }) orelse return;
    const horiz = d.ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_HORIZ },
        .{ .tag = gc.GA_BottomBorder, .data = 1 },
        .{ .tag = gc.GA_Left, .data = @bitCast(@as(isize, left)) },
        .{ .tag = gc.GA_RelBottom, .data = @bitCast(@as(isize, -(bottom - 1))) },
        .{ .tag = gc.GA_RelWidth, .data = @bitCast(@as(isize, -(left + right))) },
        .{ .tag = gc.GA_Height, .data = @bitCast(@as(isize, bottom)) },
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEHORIZ },
        .{ .tag = sr.SCROLLER_Arrows, .data = @bitCast(@as(isize, @divTrunc(bottom * 16, 11))) },
        .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
        .{},
    }) orelse {
        d.ib.DisposeObject(vert);
        return;
    };
    _ = d.ib.AddGList(window, vert, -1, 1);
    _ = d.ib.AddGList(window, horiz, -1, 1);
    d.ib.RefreshWindowFrame(window);
    dr.bars = .{ vert, horiz };
}

/// How far one step of a bar - an arrow pressed - moves the view: a
/// row of text, or a part of an icon's cell.
fn step(d: *Desktop, dr: *const Drawer) i32 {
    if (dr.view != .icon) return d.drawer_look.font_height + 2;
    return @max(8, @divTrunc(d.drawer_look.cell.height, 4));
}

/// The bars set from where the drawer's ground reaches and what of it
/// shows, counted in steps.
fn setBars(d: *Desktop, dr: *Drawer) void {
    const reach = extent(d, dr);
    const unit = step(d, dr);
    const sizes = [2][3]i32{
        .{ reach.max_y, dr.inner_height, dr.origin.y },
        .{ reach.max_x, dr.inner_width, dr.origin.x },
    };
    for (dr.bars, sizes) |held, size| {
        const bar = held orelse continue;
        const visible = @divTrunc(size[1], unit);
        const total = @max(@divTrunc(size[0] + unit - 1, unit), visible);
        _ = d.ib.SetGadgetAttrsTagList(bar, dr.window, &[_]TagItem{
            .{ .tag = sr.SCROLLER_Total, .data = @intCast(total) },
            .{ .tag = sr.SCROLLER_Visible, .data = @intCast(visible) },
            .{ .tag = sr.SCROLLER_Top, .data = @intCast(@divTrunc(size[2], unit)) },
            .{},
        });
    }
}

/// How far the drawer's ground reaches: its icons with a margin, or its
/// rows.
fn extent(d: *Desktop, dr: *Drawer) Rect {
    if (dr.view != .icon) {
        const cols = textview.columns(&d.drawer_look, dr.inner_width);
        var count: i32 = 0;
        var it = dr.icons.iterator();
        while (it.next()) |_| count += 1;
        return .{ .max_x = textview.rowsWidth(&d.drawer_look, cols), .max_y = count * cols.row_height };
    }
    var reach = Rect{};
    var it = dr.icons.iterator();
    while (it.next()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        const b = ic.box(&d.drawer_look);
        reach.max_x = @max(reach.max_x, b.max_x + margin);
        reach.max_y = @max(reach.max_y, b.max_y + margin);
    }
    return reach;
}

// --- reading ---------------------------------------------------------------------

fn startReading(d: *Desktop, dr: *Drawer) void {
    stopReading(d, dr);
    dr.next_cell = 0;
    const lock = d.dl.Lock(@ptrCast(&dr.path), dos.SHARED_LOCK) orelse return;
    const control: *dos.ExAllControl = @ptrCast(@alignCast(d.dl.AllocDosObject(dos.DOS_EXALLCONTROL, null) orelse {
        d.dl.UnLock(lock);
        return;
    }));
    const block = d.sys.AllocVec(chunk_bytes, exec.MEMF_ANY) orelse {
        d.dl.FreeDosObject(dos.DOS_EXALLCONTROL, @ptrCast(control));
        d.dl.UnLock(lock);
        return;
    };
    dr.lock = lock;
    dr.control = control;
    dr.buffer = @ptrCast(block);
    d.readingMore();
}

fn stopReading(d: *Desktop, dr: *Drawer) void {
    if (dr.control) |control| {
        if (dr.lock != null and dr.buffer != null) d.dl.ExAllEnd(dr.lock, dr.buffer.?, chunk_bytes, dos.ED_DATE, control);
        d.dl.FreeDosObject(dos.DOS_EXALLCONTROL, @ptrCast(control));
    }
    if (dr.buffer) |block| d.sys.FreeVec(@ptrCast(block));
    if (dr.lock) |lock| d.dl.UnLock(lock);
    dr.control = null;
    dr.buffer = null;
    dr.lock = null;
}

fn endsInInfo(name: []const u8) bool {
    if (name.len < 5) return false;
    return same(name[name.len - 5 ..], ".info");
}

/// One bufferful of every drawer still being read; whether any has more.
pub fn readSome(d: *Desktop) bool {
    var more = false;
    var it = d.drawers.iterator();
    while (it.next()) |node| {
        const dr: *Drawer = @alignCast(@fieldParentPtr("node", node));
        if (!dr.reading()) continue;
        readChunk(d, dr);
        if (dr.reading()) more = true;
    }
    return more;
}

fn readChunk(d: *Desktop, dr: *Drawer) void {
    const control = dr.control orelse return;
    const buffer = dr.buffer orelse return;
    control.entries = 0;
    const more = d.dl.ExAll(dr.lock, buffer, chunk_bytes, dos.ED_DATE, control);
    var at: ?*dos.ExAllData = if (control.entries != 0) @ptrCast(@alignCast(buffer)) else null;
    while (at) |data| : (at = data.next) {
        const name_z = data.name orelse continue;
        var length: usize = 0;
        while (name_z[length] != 0) length += 1;
        const name = name_z[0..length];
        if (endsInInfo(name) or same(name, ".backdrop")) continue;
        addEntry(d, dr, name, data);
    }
    if (!more) stopReading(d, dr);
    if (dr.view != .icon) drawInside(d, dr);
    setBars(d, dr);
}

/// One file of the drawer shown: its icon - or its default, with all
/// files shown - placed and drawn, or its row.
fn addEntry(d: *Desktop, dr: *Drawer, name: []const u8, data: *const dos.ExAllData) void {
    // A file left out lies on the desktop instead.
    var whole: [dos.path_max + 1]u8 = undefined;
    if (path.join(&whole, dr.pathText(), name)) |length| {
        if (d.isLeftOut(whole[0..length])) return;
    }
    var object: ?*icon.DiskObject = null;
    if (dr.view == .icon) {
        var full: [dos.path_max + 1:0]u8 = @splat(0);
        _ = path.join(&full, dr.pathText(), name) orelse return;
        object = if (dr.show_all) d.icon_base.GetDiskObjectNew(&full) else d.icon_base.GetDiskObject(&full);
        if (object == null) return;
    }
    const ic = icons.make(d.sys, &d.pictures, object, name, &d.drawer_look) orelse {
        if (object) |held| d.icon_base.FreeDiskObject(held);
        return;
    };
    ic.entry = .{
        .kind = data.type,
        .size = data.size,
        .date = .{ .days = data.days, .minute = data.minute, .tick = data.ticks },
        .protection = data.prot,
    };
    if (dr.view != .icon) {
        textview.insert(d.sys, &dr.icons, ic, dr.view);
        return;
    }
    ic.measure(d.gb, dr.rp, &d.drawer_look);
    const held = object.?;
    if (held.current_x != icon.NO_ICON_POSITION and held.current_y != icon.NO_ICON_POSITION) {
        ic.x = held.current_x;
        ic.y = held.current_y;
        ic.placed_by_file = true;
    } else place(d, dr, ic);
    d.sys.AddTail(&dr.icons, &ic.node);
    hold(d, dr);
    defer release(d, dr);
    ic.draw(d.gb, dr.rp, &d.drawer_look, dr.origin);
}

/// An icon put in the next free cell along the rows, past the icons that
/// lie where their files say.
fn place(d: *Desktop, dr: *Drawer, ic: *Icon) void {
    var taken: [64]Rect = undefined;
    var count: usize = 0;
    var it = dr.icons.iterator();
    while (it.next()) |node| {
        const other: *Icon = @alignCast(@fieldParentPtr("node", node));
        if (!other.placed_by_file) continue;
        if (count == taken.len) break;
        taken[count] = other.box(&d.drawer_look);
        count += 1;
    }
    const width = @max(dr.inner_width, d.drawer_look.cell.width + 2 * margin);
    const area = Rect{ .min_x = margin, .min_y = margin, .max_x = width - margin, .max_y = width };
    const found = icons.place.nextFree(area, d.drawer_look.cell, taken[0..count], dr.next_cell);
    dr.next_cell = found.index + 1;
    ic.putInCell(&d.drawer_look, found.at.x, found.at.y);
}

/// Every icon let go of, and the drawer read again from the start.
pub fn reread(d: *Desktop, dr: *Drawer) void {
    stopReading(d, dr);
    forgetIcons(d, dr);
    makeTitle(d, dr);
    d.ib.SetWindowTitles(dr.window, &dr.title, wn.TITLE_UNCHANGED);
    clearInside(d, dr);
    startReading(d, dr);
}

fn forgetIcons(d: *Desktop, dr: *Drawer) void {
    d.letGoOf(dr);
    while (dr.icons.first()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        d.sys.Remove(&ic.node);
        icons.free(d.sys, d.icon_base, &d.pictures, ic);
    }
}

// --- drawing -------------------------------------------------------------------

/// The drawer's layer held, for drawing into it; a holder may take it
/// again. Nothing but graphics is called while it is held.
pub fn hold(d: *Desktop, dr: *Drawer) void {
    d.lb.LockLayer(dr.layer);
}

pub fn release(d: *Desktop, dr: *Drawer) void {
    d.lb.UnlockLayer(dr.layer);
}

fn clearInside(d: *Desktop, dr: *Drawer) void {
    hold(d, dr);
    defer release(d, dr);
    const whole = Rect{ .min_x = 0, .min_y = 0, .max_x = dr.inner_width, .max_y = dr.inner_height };
    d.gb.EraseRect(dr.rp, &whole);
}

/// What shows of the drawer drawn: its icons, or its rows.
pub fn drawShown(d: *Desktop, dr: *Drawer) void {
    hold(d, dr);
    defer release(d, dr);
    if (dr.view == .icon) {
        var it = dr.icons.iterator();
        while (it.next()) |node| {
            const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
            const b = ic.shownBox(&d.drawer_look, dr.origin);
            if (b.max_x <= 0 or b.max_y <= 0 or b.min_x >= dr.inner_width or b.min_y >= dr.inner_height) continue;
            ic.draw(d.gb, dr.rp, &d.drawer_look, dr.origin);
        }
        return;
    }
    const cols = textview.columns(&d.drawer_look, dr.inner_width);
    var y: i32 = -dr.origin.y;
    var it = dr.icons.iterator();
    while (it.next()) |node| : (y += cols.row_height) {
        if (y + cols.row_height <= 0) continue;
        if (y >= dr.inner_height) break;
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        textview.drawRow(d.gb, d.dl, dr.rp, &d.drawer_look, cols, ic, y, dr.origin.x, dr.inner_width);
    }
}

/// The inside cleared and drawn again.
pub fn drawInside(d: *Desktop, dr: *Drawer) void {
    clearInside(d, dr);
    drawShown(d, dr);
}

/// Between BeginRefresh and EndRefresh: what was uncovered cleared and
/// drawn. Cleared first, since a part reported uncovered may already
/// have icons drawn in it - a window's whole inside is, when it opens -
/// and a name drawn twice over itself comes out heavier.
pub fn refresh(d: *Desktop, dr: *Drawer) void {
    d.ib.BeginRefresh(dr.window);
    hold(d, dr);
    clearInside(d, dr);
    drawShown(d, dr);
    release(d, dr);
    d.ib.EndRefresh(dr.window, true);
}

/// The window resized: the inside measured, the view kept on the ground,
/// the bars set, everything drawn.
pub fn resized(d: *Desktop, dr: *Drawer) void {
    measure(d, dr);
    const reach = extent(d, dr);
    dr.origin.x = @max(0, @min(dr.origin.x, reach.max_x - dr.inner_width));
    dr.origin.y = @max(0, @min(dr.origin.y, reach.max_y - dr.inner_height));
    setBars(d, dr);
    drawInside(d, dr);
}

/// A bar moved: the view follows it, a step at a time.
pub fn scrolled(d: *Desktop, dr: *Drawer, id: u32, top: i32) void {
    const at = top * step(d, dr);
    switch (id) {
        ID_VERT => {
            if (at == dr.origin.y) return;
            dr.origin.y = at;
        },
        ID_HORIZ => {
            if (at == dr.origin.x) return;
            dr.origin.x = at;
        },
        else => return,
    }
    drawInside(d, dr);
}

/// The view changed - by icon, name, date or size - or what is shown:
/// read again in the new way.
pub fn showAs(d: *Desktop, dr: *Drawer, view: View, show_all: bool) void {
    if (view == dr.view and show_all == dr.show_all) return;
    dr.view = view;
    dr.show_all = show_all;
    dr.origin = .{};
    reread(d, dr);
}

/// The point (`x`, `y`) of the window as a point of the inside.
pub fn inside(d: *Desktop, dr: *Drawer, x: i32, y: i32) icons.Origin {
    return .{ .x = x - windowAttr(d, dr.window, wn.WA_BorderLeft), .y = y - windowAttr(d, dr.window, wn.WA_BorderTop) };
}

/// One icon drawn again where it shows: the inside cleared there and
/// every icon that reaches into it drawn - or, viewed as text, its row.
pub fn redrawIcon(d: *Desktop, dr: *Drawer, ic: *Icon) void {
    hold(d, dr);
    defer release(d, dr);
    if (dr.view != .icon) {
        const cols = textview.columns(&d.drawer_look, dr.inner_width);
        var y: i32 = -dr.origin.y;
        var it = dr.icons.iterator();
        while (it.next()) |node| : (y += cols.row_height) {
            if (node != &ic.node) continue;
            const row = Rect{ .min_x = 0, .min_y = y, .max_x = dr.inner_width, .max_y = y + cols.row_height };
            d.gb.EraseRect(dr.rp, &row);
            textview.drawRow(d.gb, d.dl, dr.rp, &d.drawer_look, cols, ic, y, dr.origin.x, dr.inner_width);
            return;
        }
        return;
    }
    // The plate a selected icon has reaches a little past its box.
    const b = ic.shownBox(&d.drawer_look, dr.origin);
    const area = Rect{ .min_x = b.min_x - 4, .min_y = b.min_y - 4, .max_x = b.max_x + 4, .max_y = b.max_y + 4 };
    d.gb.EraseRect(dr.rp, &area);
    var it = dr.icons.iterator();
    while (it.next()) |node| {
        const other: *Icon = @alignCast(@fieldParentPtr("node", node));
        const ob = other.shownBox(&d.drawer_look, dr.origin);
        if (ob.min_x - 4 < area.max_x and area.min_x < ob.max_x + 4 and ob.min_y - 4 < area.max_y and area.min_y < ob.max_y + 4) {
            other.draw(d.gb, dr.rp, &d.drawer_look, dr.origin);
        }
    }
}

/// The icons in the box `band` of the inside - the rows it crosses,
/// viewed as text - each handed to `each`.
pub fn eachIn(d: *Desktop, dr: *Drawer, band: Rect, context: anytype, comptime each: fn (@TypeOf(context), *Icon) void) void {
    if (dr.view != .icon) {
        const cols = textview.columns(&d.drawer_look, dr.inner_width);
        var y: i32 = -dr.origin.y;
        var it = dr.icons.iterator();
        while (it.next()) |node| : (y += cols.row_height) {
            if (y + cols.row_height > band.min_y and y < band.max_y) each(context, @alignCast(@fieldParentPtr("node", node)));
        }
        return;
    }
    var it = dr.icons.iterator();
    while (it.next()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        const b = ic.shownBox(&d.drawer_look, dr.origin);
        if (b.min_x < band.max_x and band.min_x < b.max_x and b.min_y < band.max_y and band.min_y < b.max_y) each(context, ic);
    }
}

/// The icon at the point (`x`, `y`) of the window, if any.
pub fn iconAt(d: *Desktop, dr: *Drawer, x: i32, y: i32) ?*Icon {
    const left = windowAttr(d, dr.window, wn.WA_BorderLeft);
    const top = windowAttr(d, dr.window, wn.WA_BorderTop);
    const inside_x = x - left;
    const inside_y = y - top;
    if (dr.view != .icon) {
        const cols = textview.columns(&d.drawer_look, dr.inner_width);
        const row = @divFloor(inside_y + dr.origin.y, cols.row_height);
        if (inside_y < 0 or row < 0) return null;
        var n: i32 = 0;
        var it = dr.icons.iterator();
        while (it.next()) |node| : (n += 1) {
            if (n == row) return @alignCast(@fieldParentPtr("node", node));
        }
        return null;
    }
    var found: ?*Icon = null;
    var it = dr.icons.iterator();
    while (it.next()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        if (ic.hit(&d.drawer_look, dr.origin, inside_x, inside_y)) found = ic;
    }
    return found;
}

/// The window's box on the screen.
pub fn box(d: *Desktop, dr: *Drawer) Rect {
    const left = windowAttr(d, dr.window, wn.WA_Left);
    const top = windowAttr(d, dr.window, wn.WA_Top);
    return .{
        .min_x = left,
        .min_y = top,
        .max_x = left + windowAttr(d, dr.window, wn.WA_Width),
        .max_y = top + windowAttr(d, dr.window, wn.WA_Height),
    };
}

/// Clean Up: every icon put in the next free cell along the rows again,
/// whatever its file says, and the view back at the start.
pub fn cleanUp(d: *Desktop, dr: *Drawer) void {
    if (dr.view != .icon) return;
    dr.next_cell = 0;
    var it = dr.icons.iterator();
    while (it.next()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        ic.placed_by_file = false;
        place(d, dr, ic);
        ic.moved = true;
    }
    dr.origin = .{};
    setBars(d, dr);
    drawInside(d, dr);
}

/// The drawer `path` names in: its window, its icons, its watch gone.
pub fn close(d: *Desktop, dr: *Drawer) void {
    stopReading(d, dr);
    if (dr.watched) d.dl.EndNotify(&dr.watch);
    d.sys.Remove(&dr.node);
    if (d.menu_strip != null) d.ib.ClearMenuStrip(dr.window);
    // Whatever of this window is still on the shared port goes with it.
    d.ib.CloseWindow(dr.window);
    for (dr.bars) |bar| d.ib.DisposeObject(bar);
    forgetIcons(d, dr);
    d.sys.FreeVec(dr);
}

pub fn closeAll(d: *Desktop) void {
    while (d.drawers.first()) |node| close(d, @alignCast(@fieldParentPtr("node", node)));
}

/// The drawer `dr` is in opened, or a volume's own window, nothing.
pub fn openParent(d: *Desktop, dr: *Drawer) void {
    const up = path.parent(dr.pathText()) orelse return;
    var copy: [dos.path_max]u8 = undefined;
    @memcpy(copy[0..up.len], up);
    open(d, copy[0..up.len]);
}
