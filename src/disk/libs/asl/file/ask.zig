// SPDX-License-Identifier: MIT
//! The file requester: a window of intuition's classes, a list read a
//! piece at a time, and what the program is answered with.
//!
//! The window is a windowclass object holding one layout: the list, the
//! Drawer, File and Pattern fields under it, and a row of buttons at the
//! bottom. The layout places and sizes everything, so the requester has
//! no geometry of its own and follows the window as it is resized.
//!
//! The drawer is read with `ExAll`, a bufferful at a time, between
//! rounds of input rather than all at once: a drawer of some thousands of
//! files on a card takes long enough that a requester which waited for it
//! would look stopped. The list is handed back to the gadget after each
//! piece, which keeps the view and the selection where they were.
//!
//! What the requester is answered with is in the request structure: the
//! drawer and the name, and with `ASLFR_DoMultiSelect` the pairs of
//! `arg_list`, all of them in that one drawer.
//!
//! A card going in or out (`IDCMP_DISKINSERTED`, `IDCMP_DISKREMOVED`)
//! has the drawer read again, or the volumes listed again when those are
//! what is shown.
//!
//! While the desktop runs, a file dragged from it and let go on the
//! requester goes to its drawer and puts its name in the File field; a
//! drawer or a disk let go there is gone to.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const wn = intuition.windows;
const sc = intuition.screens;
const asl = sdk.asl;
const lv = sdk.gadgets.listview;
const st = sdk.gadgets.string;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const AslBase = @import("../asl_base.zig").AslBase;
const _request = @import("../request/_request.zig");
const Requester = _request.Requester;
const entries = @import("entries.zig");
const Entry = entries.Entry;

/// The gadgets, by the id the window names them with.
const ID_LIST = 1;
const ID_DRAWER = 2;
const ID_FILE = 3;
const ID_PATTERN = 4;
const ID_OK = 5;
const ID_CANCEL = 6;
const ID_PARENT = 7;
const ID_VOLUMES = 8;

/// Room between a line's text and the frame, at either side.
const column_margin = 4;

/// The Control menu, in the order the table below has them.
const ITEM_RESTORE = 0;
const ITEM_PARENT = 1;
const ITEM_VOLUMES = 2;
const ITEM_RESCAN = 3;
const ITEM_NEW_DRAWER = 5;
const ITEM_DELETE = 6;
const ITEM_CANCEL = 8;
const ITEM_OK = 9;

/// The raw key codes the requester answers to. A cursor key stands for
/// no character, so it is these the keymap never turns into one.
const KEY_UP: u32 = 0x4C;
const KEY_DOWN: u32 = 0x4D;

/// The characters it answers to. Return and Esc do stand for characters,
/// and reach a window as those rather than as raw keys.
const CHAR_RETURN: u32 = 0x0D;
const CHAR_ESC: u32 = 0x1B;

/// A file requester while it is up.
const Session = struct {
    r: *Requester,
    sys: *ExecBase,
    dl: *DosBase,
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    ub: *UtilityBase,
    object: *Object,
    window: *intuition.Window,
    list_gadget: *Object,
    drawer_gadget: *Object,
    file_gadget: *Object,
    pattern_gadget: ?*Object,
    /// The lines, and the walk that fills them.
    list: exec.List = .{},
    walk: entries.Walk = .{},
    /// The volumes and the assigns are shown in place of a drawer's
    /// entries: there is no drawer to walk then, and a line picked is a
    /// whole place rather than a name in one.
    showing_volumes: bool = false,
    /// The hook that draws a line in two columns.
    draw_hook: utility.Hook = .{},
    /// The Pattern field parsed, and whether there is one.
    pattern: [2 * (dos.name_max + 2)]u8 = @splat(0),
    has_pattern: bool = false,
    /// `ASLFR_AcceptPattern` and `ASLFR_RejectPattern`, parsed.
    accept: [2 * (dos.name_max + 2)]u8 = @splat(0),
    has_accept: bool = false,
    reject: [2 * (dos.name_max + 2)]u8 = @splat(0),
    has_reject: bool = false,
    /// The Control menu, while it is on the window.
    menu: ?*intuition.Menu = null,
    /// Where a path is built while one is being worked out. It is here
    /// rather than on the stack of whichever call wants it: a whole path
    /// is a kilobyte, and the calls that want one call each other.
    path: [dos.path_max + 1]u8 = @splat(0),
    /// The fields as the requester opened with them, for Restore.
    was_drawer: [dos.path_max + 1]u8 = @splat(0),
    was_file: [dos.name_max + 1]u8 = @splat(0),
    was_pattern: [dos.name_max + 1]u8 = @splat(0),
    /// The window as one files can be dropped on, while the desktop runs.
    drop: sdk.anvil.DropTarget = .{},
    /// True once the requester has been answered or given up.
    answered: bool = false,
    given_up: bool = false,
};

/// One of the window's numbers, which is opaque to a program.
fn windowAttr(s: *Session, tag: utility.Tag) i32 {
    var value: usize = 0;
    const ask_it = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    s.ib.GetWindowAttrs(s.window, &ask_it);
    return @bitCast(@as(u32, @truncate(value)));
}

fn textLen(s: [*:0]const u8) usize {
    var n: usize = 0;
    while (s[n] != 0) n += 1;
    return n;
}

// --- drawing a line ---------------------------------------------------------

/// One line in two columns: the name at the left, what the entry is at
/// the right. The hook fills the line's ground itself, so the gadget
/// draws nothing more of it.
fn drawEntry(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const msg: *const lv.LVDrawMsg = @ptrCast(@alignCast(message.?));
    if (msg.method_id != lv.LV_DRAW) return lv.LVCB_UNKNOWN;
    const s: *Session = @ptrCast(@alignCast(hook.data.?));
    const gb = s.gb;
    const rp = msg.rast_port.?;
    const node: *exec.Node = @ptrCast(@alignCast(object.?));
    const entry: *Entry = @fieldParentPtr("node", node);
    const styled = sdk.gadgets.support.pensFor(s.ib, msg.draw_info.?, null, intuition.style.PART_MAIN, intuition.style.PART_SELECTION);
    const pens: [*]const graphics.Pen = &styled;
    const selected = msg.state == lv.LVR_SELECTED or msg.state == lv.LVR_SELECTEDDISABLED;

    const ground = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = pens[if (selected) sc.FILLPEN else sc.BACKGROUNDPEN] },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{},
    };
    gb.SetRPAttrs(rp, &ground);
    gb.RectFill(rp, &msg.bounds);

    var baseline: u32 = 0;
    var height: u32 = 0;
    const ask_metrics = [_]TagItem{
        .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
        .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) },
        .{},
    };
    gb.GetRPAttrs(rp, &ask_metrics);
    const top = msg.bounds.min_y + @divTrunc(msg.bounds.max_y - msg.bounds.min_y - @as(i32, @intCast(height)), 2) + @as(i32, @intCast(baseline));
    const ink = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = pens[if (selected) sc.FILLTEXTPEN else sc.TEXTPEN] },
        .{},
    };
    gb.SetRPAttrs(rp, &ink);

    const right = entry.right();
    const right_len: u32 = @intCast(textLen(right));
    const right_width = gb.TextLength(rp, right, right_len);
    const right_at = msg.bounds.max_x - column_margin - right_width;

    const name = entry.name();
    var name_len: u32 = @intCast(textLen(name));
    const room = right_at - (msg.bounds.min_x + column_margin) - column_margin;
    if (gb.TextLength(rp, name, name_len) > room) {
        var extent: graphics.TextExtent = .{};
        name_len = gb.TextFit(rp, name, name_len, &extent, null, 1, @max(room, 0), 0);
    }
    gb.Move(rp, msg.bounds.min_x + column_margin, top);
    gb.Text(rp, name, name_len);
    gb.Move(rp, right_at, top);
    gb.Text(rp, right, right_len);
    return lv.LVCB_OK;
}

// --- what is shown ----------------------------------------------------------

/// A pattern parsed into `into`; false when it is no pattern or will not
/// fit, which means everything is shown.
fn parsePattern(s: *Session, text: ?[*:0]const u8, into: []u8) bool {
    const from = text orelse return false;
    if (from[0] == 0) return false;
    if (2 * textLen(from) + 2 > into.len) return false;
    return s.ub.ParsePatternNoCase(from, @ptrCast(into.ptr), @intCast(into.len)) >= 0;
}

/// Whether an entry is shown: the tags' patterns, the Pattern field, the
/// icons, the drawers-only flag and the program's own hook, in that
/// order.
fn shown(s: *Session, name: [*:0]const u8, kind: i32) bool {
    const r = s.r;
    const is_dir = kind > 0;
    if (!is_dir and r.flags2 & asl.FRF2_DRAWERSONLY != 0) return false;
    // The patterns are put to files, and to drawers only when asked.
    const filtered = !is_dir or r.flags2 & asl.FRF2_FILTERDRAWERS != 0;
    if (filtered) {
        if (r.flags2 & asl.FRF2_REJECTICONS != 0 and endsWithInfo(name)) return false;
        if (s.has_accept and !s.ub.MatchPatternNoCase(@ptrCast(&s.accept), name)) return false;
        if (s.has_reject and s.ub.MatchPatternNoCase(@ptrCast(&s.reject), name)) return false;
        if (s.has_pattern and !s.ub.MatchPatternNoCase(@ptrCast(&s.pattern), name)) return false;
    }
    if (r.flags1 & asl.FRF_FILTERFUNC != 0) if (r.filter_func) |hook| {
        var data = dos.ExAllData{ .name = @constCast(name), .type = kind };
        if (s.ub.CallHookPkt(hook, @ptrCast(s.r), @ptrCast(&data)) == 0) return false;
    };
    return true;
}

fn endsWithInfo(name: [*:0]const u8) bool {
    const len = textLen(name);
    const tail = ".info";
    if (len < tail.len) return false;
    for (tail, 0..) |c, i| {
        const here = name[len - tail.len + i];
        if (here != c and here != c - 0x20) return false;
    }
    return true;
}

// --- the list ---------------------------------------------------------------

/// The list handed back to the gadget after it has been changed. The same
/// list given again keeps the view and the selection, so a list that
/// grows while it is read does not jump under the pointer.
fn attachList(s: *Session) void {
    const detach = [_]TagItem{ .{ .tag = lv.LISTVIEW_Labels, .data = lv.LISTVIEW_DETACH }, .{} };
    _ = s.ib.SetGadgetAttrsTagList(s.list_gadget, s.window, &detach);
}

fn showList(s: *Session) void {
    const attach = [_]TagItem{ .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&s.list) }, .{} };
    _ = s.ib.SetGadgetAttrsTagList(s.list_gadget, s.window, &attach);
}

/// One bufferful of the drawer read into the list. The walk ends when
/// ExAll says there is nothing more.
fn readChunk(s: *Session) void {
    const control = s.walk.control orelse return;
    const buffer = s.walk.buffer orelse return;
    attachList(s);
    defer showList(s);
    control.entries = 0;
    const more = s.dl.ExAll(s.walk.lock, buffer, entries.chunk_bytes, dos.ED_SIZE, control);
    var at: ?*dos.ExAllData = if (control.entries != 0) @ptrCast(@alignCast(buffer)) else null;
    while (at) |data| : (at = data.next) {
        const name = data.name orelse continue;
        if (!shown(s, name, data.type)) continue;
        if (!entries.add(s.sys, s.ub, &s.list, name, data.type, data.size)) break;
    }
    if (!more) s.walk.stop(s.sys, s.dl);
}

/// The volumes and the assigns in place of a drawer's entries: what the
/// Volumes button shows, and what there is when no drawer is named.
fn showVolumes(s: *Session) void {
    attachList(s);
    defer showList(s);
    s.walk.stop(s.sys, s.dl);
    entries.empty(s.sys, &s.list);
    s.showing_volumes = true;
    const flags = dos.LDF_VOLUMES | dos.LDF_ASSIGNS | dos.LDF_READ;
    var node = s.dl.LockDosList(flags) orelse return;
    defer s.dl.UnLockDosList(flags);
    while (s.dl.NextDosEntry(node, flags)) |entry| {
        node = entry;
        var name: [dos.MAX_DEVICE_NAME + 2]u8 = @splat(0);
        const len = @min(textLen(entry.name), name.len - 2);
        @memcpy(name[0..len], entry.name[0..len]);
        name[len] = ':';
        name[len + 1] = 0;
        // A volume and an assign are both places to go into, so both are
        // drawers to the list.
        _ = entries.add(s.sys, s.ub, &s.list, @ptrCast(&name), dos.ST_USERDIR, 0);
    }
}

/// The list filled from the Drawer field, or the volumes when it is
/// empty. What could not be read leaves the list empty and the drawer as
/// it was, so the user can type another.
fn refill(s: *Session) void {
    const drawer: [*:0]const u8 = @ptrCast(&s.r.drawer);
    if (drawer[0] == 0) return showVolumes(s);
    attachList(s);
    defer showList(s);
    s.walk.stop(s.sys, s.dl);
    entries.empty(s.sys, &s.list);
    s.showing_volumes = false;
    s.has_pattern = parsePattern(s, @ptrCast(&s.r.pattern), &s.pattern);
    if (!s.walk.start(s.sys, s.dl, drawer)) {
        // Nothing there to read: the list stays empty and says so by
        // being empty.
        return;
    }
}

// --- the fields -------------------------------------------------------------

fn setString(s: *Session, gadget: ?*Object, text: [*:0]const u8) void {
    const g = gadget orelse return;
    const tags = [_]TagItem{ .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(text) }, .{} };
    _ = s.ib.SetGadgetAttrsTagList(g, s.window, &tags);
}

fn getString(s: *Session, gadget: ?*Object) [*:0]const u8 {
    const g = gadget orelse return "";
    var at: usize = 0;
    _ = s.ib.GetAttr(gc.STRINGA_TextVal, g, &at);
    return if (at != 0) @ptrFromInt(at) else "";
}

/// The three fields read back into the requester, which is where the
/// answer is kept.
fn takeFields(s: *Session) void {
    _request.copyInto(&s.r.drawer, getString(s, s.drawer_gadget));
    _request.copyInto(&s.r.file, getString(s, s.file_gadget));
    if (s.pattern_gadget) |g| _request.copyInto(&s.r.pattern, getString(s, g));
}

/// The drawer changed: the field, the requester and the list follow it.
fn goTo(s: *Session, drawer: [*:0]const u8) void {
    _request.copyInto(&s.r.drawer, drawer);
    setString(s, s.drawer_gadget, @ptrCast(&s.r.drawer));
    refill(s);
}

/// Into the drawer a line names.
fn enterDrawer(s: *Session, name: [*:0]const u8) void {
    if (s.showing_volumes) return goTo(s, name);
    _request.copyInto(&s.path, @ptrCast(&s.r.drawer));
    if (!s.dl.AddPart(@ptrCast(&s.path), name, s.path.len)) return;
    goTo(s, @ptrCast(&s.path));
}

/// Up one drawer; the volumes from a root.
fn goUp(s: *Session) void {
    if (s.showing_volumes) return;
    const lock = s.dl.Lock(@ptrCast(&s.r.drawer), dos.SHARED_LOCK) orelse return showVolumes(s);
    defer s.dl.UnLock(lock);
    const up = s.dl.ParentDir(lock) orelse return showVolumes(s);
    defer s.dl.UnLock(up);
    if (!s.dl.NameFromLock(up, @ptrCast(&s.path), s.path.len)) return;
    goTo(s, @ptrCast(&s.path));
}

/// The entry a line number names, or null past the end.
fn entryAt(s: *Session, line: u32) ?*Entry {
    const node = lv.nodeAt(&s.list, line) orelse return null;
    return @fieldParentPtr("node", node);
}

// --- the answer -------------------------------------------------------------

/// The pairs a multi-select answer is made of: one lock on the drawer,
/// shared by every pair, and the names after the array in the one block.
fn takeArgs(s: *Session) void {
    const r = s.r;
    _request.dropArgs(r);
    if (r.flags1 & asl.FRF_DOMULTISELECT == 0) return;
    var chosen: usize = 0;
    _ = s.ib.GetAttr(lv.LISTVIEW_SelectedArray, s.list_gadget, &chosen);
    if (chosen == 0) return;
    const bits: *const lv.LVSelected = @ptrFromInt(chosen);
    var count: u32 = 0;
    var bytes: usize = 0;
    var line: u32 = 0;
    while (line < bits.count) : (line += 1) {
        if (!bits.has(line)) continue;
        const entry = entryAt(s, line) orelse continue;
        if (entry.isDir()) continue;
        count += 1;
        bytes += textLen(entry.name()) + 1;
    }
    if (count == 0) return;
    const block = s.sys.AllocVec(count * @sizeOf(asl.WBArg) + bytes, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return;
    r.args = block;
    r.arg_lock = s.dl.Lock(@ptrCast(&r.drawer), dos.SHARED_LOCK);
    const args: [*]asl.WBArg = @ptrCast(@alignCast(block));
    var text: [*]u8 = @as([*]u8, @ptrCast(block)) + count * @sizeOf(asl.WBArg);
    var at: u32 = 0;
    line = 0;
    while (line < bits.count and at < count) : (line += 1) {
        if (!bits.has(line)) continue;
        const entry = entryAt(s, line) orelse continue;
        if (entry.isDir()) continue;
        const name = entry.name();
        const len = textLen(name);
        @memcpy(text[0..len], name[0..len]);
        text[len] = 0;
        args[at] = .{ .lock = r.arg_lock, .name = @ptrCast(text) };
        text += len + 1;
        at += 1;
    }
    r.public.file.num_args = @intCast(at);
    r.public.file.arg_list = args;
}

/// The requester answered: the fields taken and, with multi-select, the
/// pairs made. False when there is nothing to answer with - no name, and
/// not a requester that takes a drawer on its own.
fn answer(s: *Session) bool {
    takeFields(s);
    takeArgs(s);
    if (s.r.flags2 & asl.FRF2_DRAWERSONLY != 0) return true;
    if (s.r.public.file.num_args != 0) return true;
    return s.r.file[0] != 0;
}

// --- the window -------------------------------------------------------------

fn makeButton(s: *Session, text: [*:0]const u8, id: usize) ?*Object {
    return s.ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr(text) },
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
}

fn makeField(s: *Session, id: usize, text: [*:0]const u8) ?*Object {
    return s.ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.STRINGA_MaxChars, .data = dos.path_max },
        .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(text) },
        .{ .tag = gc.GA_TabCycle, .data = 1 },
        .{},
    });
}

/// The window object and everything in it. False with nothing made.
fn build(s: *Session, screen: *intuition.Screen) bool {
    const r = s.r;
    const ib = s.ib;
    s.draw_hook = .{ .entry = &drawEntry, .data = @ptrCast(s) };

    const list = ib.NewObjectTagList(null, lv.LISTVIEW_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_LIST },
        .{ .tag = lv.LISTVIEW_ShowSelected, .data = 1 },
        .{ .tag = lv.LISTVIEW_CallBack, .data = @intFromPtr(&s.draw_hook) },
        .{ .tag = if (r.flags1 & asl.FRF_DOMULTISELECT != 0) lv.LISTVIEW_MultiSelect else utility.TAG_IGNORE, .data = 1 },
        .{},
    });
    const drawer = makeField(s, ID_DRAWER, @ptrCast(&r.drawer));
    const file = makeField(s, ID_FILE, @ptrCast(&r.file));
    const pattern = if (r.flags1 & asl.FRF_DOPATTERNS != 0) makeField(s, ID_PATTERN, @ptrCast(&r.pattern)) else null;
    const ok = makeButton(s, r.words.positive orelse "_Ok", ID_OK);
    const volumes = makeButton(s, "_Volumes", ID_VOLUMES);
    const parent = makeButton(s, "_Parent", ID_PARENT);
    const cancel = makeButton(s, r.words.negative orelse "_Cancel", ID_CANCEL);

    const buttons = if (ok != null and volumes != null and parent != null and cancel != null)
        ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(ok) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(volumes) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(parent) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(cancel) },
            .{},
        })
    else
        null;

    const whole = list != null and drawer != null and file != null and buttons != null and
        (pattern != null or r.flags1 & asl.FRF_DOPATTERNS == 0);
    const layout = if (whole) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = 6 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 4 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(list) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(drawer) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Drawer") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(file) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_File") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = if (pattern != null) lg.LAYOUTA_AddChild else utility.TAG_IGNORE, .data = @intFromPtr(pattern) },
        .{ .tag = if (pattern != null) lg.CHILDA_Label else utility.TAG_IGNORE, .data = @intFromPtr("Pa_ttern") },
        .{ .tag = if (pattern != null) lg.CHILDA_WeightHeight else utility.TAG_IGNORE, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(buttons) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{},
    }) else null;
    const made = layout orelse {
        // A child a group took is that group's to dispose of; one that
        // never reached a group is disposed of here, and disposing both
        // would free it twice.
        if (buttons) |group| ib.DisposeObject(group) else {
            for ([_]?*Object{ ok, volumes, parent, cancel }) |part| ib.DisposeObject(part);
        }
        for ([_]?*Object{ list, drawer, file, pattern }) |part| ib.DisposeObject(part);
        return false;
    };

    var nominal = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(made, @ptrCast(&nominal));
    const ignore = utility.TAG_IGNORE;
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr(r.words.title orelse "Pick a file") },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(@max(if (r.box.width > 0) r.box.width else nominal.domain.width + 120, 1)) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(@max(if (r.box.height > 0) r.box.height else nominal.domain.height + 60, 1)) },
        .{ .tag = if (r.box.left >= 0) wn.WA_Left else ignore, .data = @intCast(@max(r.box.left, 0)) },
        .{ .tag = if (r.box.top >= 0) wn.WA_Top else ignore, .data = @intCast(@max(r.box.top, 0)) },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        // The cursor keys, Return and Esc are the requester's own, and a
        // card going in or out is a reason to look again.
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_RAWKEY | wn.IDCMP_DISKINSERTED | wn.IDCMP_DISKREMOVED },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(made) },
        .{},
    }) orelse {
        ib.DisposeObject(made);
        return false;
    };
    s.object = object;
    s.list_gadget = list.?;
    s.drawer_gadget = drawer.?;
    s.file_gadget = file.?;
    s.pattern_gadget = pattern;
    return true;
}

// --- the loop ---------------------------------------------------------------

/// One word from the window acted on. False when the requester is done.
fn act(s: *Session, word: usize, code: u32) bool {
    switch (word & wc.WMHI_CLASSMASK) {
        wc.WMHI_CLOSEWINDOW => {
            s.given_up = true;
            return false;
        },
        wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
            ID_OK => {
                if (answer(s)) {
                    s.answered = true;
                    return false;
                }
            },
            ID_CANCEL => {
                s.given_up = true;
                return false;
            },
            ID_PARENT => goUp(s),
            ID_VOLUMES => showVolumes(s),
            ID_LIST => {
                const line = code & ~lv.LISTVIEW_DOUBLE;
                const entry = entryAt(s, line) orelse return true;
                if (entry.isDir()) {
                    // A drawer is entered by a second press on it; one
                    // press only shows which it is.
                    if (code & lv.LISTVIEW_DOUBLE != 0) enterDrawer(s, entry.name());
                    return true;
                }
                setString(s, s.file_gadget, entry.name());
                // A second press on a file is the answer.
                if (code & lv.LISTVIEW_DOUBLE != 0 and answer(s)) {
                    s.answered = true;
                    return false;
                }
            },
            ID_DRAWER => {
                takeFields(s);
                refill(s);
            },
            ID_PATTERN => {
                takeFields(s);
                refill(s);
            },
            ID_FILE => {
                if (answer(s)) {
                    s.answered = true;
                    return false;
                }
            },
            else => {},
        },
        wc.WMHI_MENUPICK => {
            const number: u32 = @truncate(word & wc.WMHI_MENUMASK);
            if (number == intuition.menus.MENUNULL) return true;
            switch (intuition.menus.ITEMNUM(number)) {
                ITEM_RESTORE => restore(s),
                ITEM_PARENT => goUp(s),
                ITEM_VOLUMES => showVolumes(s),
                ITEM_RESCAN => {
                    takeFields(s);
                    refill(s);
                },
                ITEM_NEW_DRAWER => newDrawer(s),
                ITEM_DELETE => deleteNamed(s),
                ITEM_CANCEL => {
                    s.given_up = true;
                    return false;
                },
                ITEM_OK => {
                    if (answer(s)) {
                        s.answered = true;
                        return false;
                    }
                },
                else => {},
            }
        },
        // The keys the requester answers to itself. A field that has the
        // keyboard takes them first, which is what typing in it means.
        wc.WMHI_RAWKEY => switch (word & wc.WMHI_KEYMASK) {
            KEY_UP => moveSelection(s, true),
            KEY_DOWN => moveSelection(s, false),
            else => {},
        },
        // A card going in or out: what is listed may have come or gone
        // with it, so the drawer is read again. Showing the volumes, the
        // list of them is what changed.
        wc.WMHI_DISKINSERTED, wc.WMHI_DISKREMOVED => {
            if (s.showing_volumes) showVolumes(s) else refill(s);
        },
        wc.WMHI_VANILLAKEY => switch (word & wc.WMHI_KEYMASK) {
            CHAR_RETURN => {
                if (answer(s)) {
                    s.answered = true;
                    return false;
                }
            },
            CHAR_ESC => {
                s.given_up = true;
                return false;
            },
            else => {},
        },
        else => {},
    }
    return true;
}

/// Files let go on the requester: to the drawer of each, its name in the
/// File field; a drawer or a disk gone to.
fn takeDrops(s: *Session) void {
    while (s.drop.next(s.dl, &s.path)) |file| {
        s.ib.ActivateWindow(s.window);
        if (file.is_drawer) {
            goTo(s, file.name);
            continue;
        }
        _request.copyInto(&s.r.file, s.dl.FilePart(file.name));
        setString(s, s.file_gadget, @ptrCast(&s.r.file));
        const end = @intFromPtr(s.dl.PathPart(file.name)) - @intFromPtr(&s.path);
        s.path[end] = 0;
        goTo(s, @ptrCast(&s.path));
    }
}

/// The requester run until it is answered or given up.
fn loop(s: *Session) void {
    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    while (true) {
        while (true) {
            const word = s.ib.SendMessage(s.object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            if (!act(s, word, code)) return;
        }
        // A piece of the drawer between rounds of input: the list grows
        // while the requester stays answerable, and nothing waits until
        // there is nothing left to read.
        if (s.walk.reading()) {
            readChunk(s);
            continue;
        }
        const got = s.ib.WaitIMsg(s.window, s.drop.signal() | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) {
            s.given_up = true;
            return;
        }
        if (got & s.drop.signal() != 0) takeDrops(s);
    }
}

// --- the whole thing --------------------------------------------------------

/// A file requester put up and answered. True when it was answered, false
/// when it was given up or could not be shown.
pub fn ask(ab: *AslBase, r: *Requester) bool {
    // The session is allocated, not kept on the stack: it holds a whole
    // path several times over, and a command's stack is eight kilobytes.
    const block = ab.sys_base.AllocVec(@sizeOf(Session), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
    defer ab.sys_base.FreeVec(block);
    const s: *Session = @ptrCast(@alignCast(block));
    s.* = Session{
        .r = r,
        .sys = ab.sys_base,
        .dl = ab.dos_base,
        .ib = ab.intuition_base,
        .gb = ab.graphics_base,
        .ub = ab.utility_base,
        .object = undefined,
        .window = undefined,
        .list_gadget = undefined,
        .drawer_gadget = undefined,
        .file_gadget = undefined,
        .pattern_gadget = null,
    };
    s.list.init(.unknown);
    s.has_accept = parsePattern(s, r.accept_pattern, &s.accept);
    s.has_reject = parsePattern(s, r.reject_pattern, &s.reject);

    // Where it opens: the window's screen, the screen it was given, the
    // public screen of that name, or the default public screen.
    const named: ?[*:0]const u8 = if (r.where.window != null or r.where.screen != null) null else r.where.pub_screen;
    const parent_screen: ?*intuition.Screen = if (r.where.window) |w| blk: {
        var at: usize = 0;
        const ask_screen = [_]TagItem{ .{ .tag = wn.WA_Screen, .data = @intFromPtr(&at) }, .{} };
        s.ib.GetWindowAttrs(w, &ask_screen);
        break :blk if (at != 0) @ptrFromInt(at) else null;
    } else null;
    const given: ?*intuition.Screen = parent_screen orelse r.where.screen;
    const screen: *intuition.Screen = given orelse
        (s.ib.LockPubScreen(named) orelse s.ib.LockPubScreen(null) orelse return false);
    const locked = given == null;
    defer if (locked) s.ib.UnlockPubScreen(null, screen);

    if (!build(s, screen)) return false;
    defer s.ib.DisposeObject(s.object);

    var open = wc.WmOpen{};
    if (s.ib.SendMessage(s.object, @ptrCast(&open)) == 0) return false;
    var window_at: usize = 0;
    _ = s.ib.GetAttr(wc.WINDOWA_Window, s.object, &window_at);
    s.window = @ptrFromInt(window_at);

    // The parent takes no input while the requester is up, if it asked
    // for that; its pointer says so as well.
    const parent = if (r.where.sleep != 0) r.where.window else null;
    if (parent) |w| {
        const busy = [_]TagItem{ .{ .tag = wn.WA_BusyPointer, .data = 1 }, .{} };
        s.ib.SetWindowPointerA(w, &busy);
    }
    defer if (parent) |w| {
        const awake = [_]TagItem{ .{ .tag = wn.WA_BusyPointer, .data = 0 }, .{} };
        s.ib.SetWindowPointerA(w, &awake);
    };

    // Files let go on it, while the desktop runs; taken off the desktop's
    // list before the window closes.
    s.drop.add(s.sys, s.window);
    defer s.drop.remove();

    // What the fields opened with, for Restore.
    _request.copyInto(&s.was_drawer, @ptrCast(&r.drawer));
    _request.copyInto(&s.was_file, @ptrCast(&r.file));
    _request.copyInto(&s.was_pattern, @ptrCast(&r.pattern));
    addMenu(s, screen);
    defer dropMenu(s);

    refill(s);
    loop(s);

    // Where it was left, so the next request opens there.
    const left = windowAttr(s, wn.WA_Left);
    const top = windowAttr(s, wn.WA_Top);
    const width = windowAttr(s, wn.WA_Width);
    const height = windowAttr(s, wn.WA_Height);
    r.box.left = left;
    r.box.top = top;
    r.box.width = width;
    r.box.height = height;
    r.public.file.left_edge = left;
    r.public.file.top_edge = top;
    r.public.file.width = width;
    r.public.file.height = height;

    s.walk.stop(s.sys, s.dl);
    attachList(s);
    entries.empty(s.sys, &s.list);
    return s.answered;
}

// --- the Control menu -------------------------------------------------------

/// The Control menu: what the buttons do and what there is no room for a
/// button for. The order is the `ITEM_` numbers above.
const control_menu = [_]intuition.menus.NewMenu{
    .{ .type = intuition.menus.NM_TITLE, .label = "Control" },
    .{ .type = intuition.menus.NM_ITEM, .label = "Restore", .comm_key = "R" },
    .{ .type = intuition.menus.NM_ITEM, .label = "Parent", .comm_key = "P" },
    .{ .type = intuition.menus.NM_ITEM, .label = "Volumes", .comm_key = "V" },
    .{ .type = intuition.menus.NM_ITEM, .label = "Rescan", .comm_key = "S" },
    .{ .type = intuition.menus.NM_ITEM, .label = intuition.menus.NM_BARLABEL },
    .{ .type = intuition.menus.NM_ITEM, .label = "New Drawer", .comm_key = "N" },
    .{ .type = intuition.menus.NM_ITEM, .label = "Delete", .comm_key = "D" },
    .{ .type = intuition.menus.NM_ITEM, .label = intuition.menus.NM_BARLABEL },
    .{ .type = intuition.menus.NM_ITEM, .label = "Cancel" },
    .{ .type = intuition.menus.NM_ITEM, .label = "Ok" },
    .{ .type = intuition.menus.NM_END },
};

/// The menu made and put on the window. A requester without one is a
/// requester with fewer ways to do the same things, so a failure here is
/// not a failure of the request.
fn addMenu(s: *Session, screen: *intuition.Screen) void {
    const menu = s.ib.CreateMenusA(&control_menu, null) orelse return;
    if (!s.ib.LayoutMenusA(menu, screen, null)) {
        s.ib.FreeMenus(menu);
        return;
    }
    if (!s.ib.SetMenuStrip(s.window, menu)) {
        s.ib.FreeMenus(menu);
        return;
    }
    s.menu = menu;
}

fn dropMenu(s: *Session) void {
    const menu = s.menu orelse return;
    s.ib.ClearMenuStrip(s.window);
    s.ib.FreeMenus(menu);
    s.menu = null;
}

/// The fields put back as the requester opened with them.
fn restore(s: *Session) void {
    _request.copyInto(&s.r.file, @ptrCast(&s.was_file));
    _request.copyInto(&s.r.pattern, @ptrCast(&s.was_pattern));
    setString(s, s.file_gadget, @ptrCast(&s.r.file));
    if (s.pattern_gadget) |g| setString(s, g, @ptrCast(&s.r.pattern));
    goTo(s, @ptrCast(&s.was_drawer));
}

/// A drawer made with the name in the File field, and gone into. Nothing
/// happens without a name; what could not be made says so by the drawer
/// not changing.
fn newDrawer(s: *Session) void {
    takeFields(s);
    if (s.r.file[0] == 0 or s.showing_volumes) return;
    _request.copyInto(&s.path, @ptrCast(&s.r.drawer));
    if (!s.dl.AddPart(@ptrCast(&s.path), @ptrCast(&s.r.file), s.path.len)) return;
    const made = s.dl.CreateDir(@ptrCast(&s.path)) orelse return;
    s.dl.UnLock(made);
    _request.copyInto(&s.r.file, "");
    setString(s, s.file_gadget, @ptrCast(&s.r.file));
    goTo(s, @ptrCast(&s.path));
}

/// The name in the File field deleted, and the list read again. A drawer
/// with anything in it stays: this deletes one thing, not a tree.
fn deleteNamed(s: *Session) void {
    takeFields(s);
    if (s.r.file[0] == 0 or s.showing_volumes) return;
    _request.copyInto(&s.path, @ptrCast(&s.r.drawer));
    if (!s.dl.AddPart(@ptrCast(&s.path), @ptrCast(&s.r.file), s.path.len)) return;
    if (!s.dl.DeleteFile(@ptrCast(&s.path))) return;
    _request.copyInto(&s.r.file, "");
    setString(s, s.file_gadget, @ptrCast(&s.r.file));
    refill(s);
}

/// The selection moved a line, and kept in view. The File field follows
/// it, as a press on the line would.
fn moveSelection(s: *Session, back: bool) void {
    var at: usize = 0;
    _ = s.ib.GetAttr(lv.LISTVIEW_Selected, s.list_gadget, &at);
    var count: u32 = 0;
    var node = s.list.first();
    while (node) |n| : (node = n.next()) count += 1;
    if (count == 0) return;
    const was: u32 = @truncate(at);
    const line: u32 = if (was == lv.LISTVIEW_NONE)
        (if (back) count - 1 else 0)
    else if (back)
        (if (was == 0) 0 else was - 1)
    else
        @min(was + 1, count - 1);
    const tags = [_]TagItem{
        .{ .tag = lv.LISTVIEW_Selected, .data = line },
        .{ .tag = lv.LISTVIEW_MakeVisible, .data = line },
        .{},
    };
    _ = s.ib.SetGadgetAttrsTagList(s.list_gadget, s.window, &tags);
    const entry = entryAt(s, line) orelse return;
    if (!entry.isDir()) setString(s, s.file_gadget, entry.name());
}
