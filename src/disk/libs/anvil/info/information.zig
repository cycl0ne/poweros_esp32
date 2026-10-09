// SPDX-License-Identifier: MIT
//! Information: what a file, a drawer or a disk is, and its icon's
//! fields, in a window to read and change.
//!
//! **The window** lives on a process of its own, so the desktop - or the
//! program that asked - goes on meanwhile, and there can be as many as
//! there are files asked about. What it shows goes by the kind of the
//! icon: for a disk whether it may be written, its blocks, used and free,
//! the block size, when it was made and its default tool; for a file or a
//! drawer when it was last changed, its protection bits and its comment;
//! for a program or a document its size and its stack - the usual one
//! the desktop gives, when its icon asks for none; a document's
//! default tool; the tool types, a line each, of anything but a disk and
//! the trash. Without an icon file only what the file itself says is
//! shown, and no icon is written.
//!
//! **Save** writes the bits and the comment where they changed, and the
//! icon with the window's stack (rounded up to 4 bytes; an icon that
//! asked for none and still shows the usual one goes on asking for none),
//! default tool and tool types; Cancel or the close gadget leaves everything as it
//! was. The drawer's notification brings the change to the desktop.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const icon = sdk.icon;
const utility = sdk.utility;
const intuition = sdk.intuition;
const wn = intuition.windows;
const wc = intuition.windowclass;
const lg = intuition.layoutgclass;
const gc = intuition.gadgetclass;
const classusr = intuition.classusr;
const tx = sdk.gadgets.text;
const st = sdk.gadgets.string;
const cb = sdk.gadgets.checkbox;
const ig = sdk.gadgets.integer;
const te = sdk.gadgets.textedit;
const TagItem = utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const IconBase = sdk.interface.icon.IconBase;
const Object = intuition.Object;
const _base = @import("../anvil_base.zig");
const AnvilBase = _base.AnvilBase;
const path = @import("../drawer/path.zig");
const usual_stack = @import("../start/startanvil.zig").usual_stack;

/// The bits shown, in the order of their boxes: ticked means allowed for
/// the four that are set to forbid (rwed), set for the others.
const Bit = struct { label: [*:0]const u8, mask: u32, forbids: bool };
const bits = [_]Bit{
    .{ .label = "Script", .mask = dos.FIBF_SCRIPT, .forbids = false },
    .{ .label = "Archived", .mask = dos.FIBF_ARCHIVE, .forbids = false },
    .{ .label = "Readable", .mask = dos.FIBF_READ, .forbids = true },
    .{ .label = "Writable", .mask = dos.FIBF_WRITE, .forbids = true },
    .{ .label = "Executable", .mask = dos.FIBF_EXECUTE, .forbids = true },
    .{ .label = "Deletable", .mask = dos.FIBF_DELETE, .forbids = true },
};

/// How many tool types are written back, and how long they may be in all.
const types_max = 32;
const types_bytes = 2048;

const ID_SAVE = 1;
const ID_CANCEL = 2;

/// What the icon is, which says what the window shows.
const Kind = enum { disk, drawer, tool, project, garbage };

/// The gadget classes the window is made of, in `Info.libraries` after
/// dos, intuition and icon; the tool types' editor is left out when it
/// cannot be had.
const classes = [_][*:0]const u8{ tx.TEXT_LIBRARY, st.STRING_LIBRARY, cb.CHECKBOX_LIBRARY, ig.INTEGER_LIBRARY, te.TEXTEDIT_LIBRARY };
const AT_TEXTEDIT = 3 + classes.len - 1;

/// One window's state, in one block its process frees as it ends.
const Info = struct {
    base: *AnvilBase,
    name: [dos.path_max + 1:0]u8 = @splat(0),
    screen: ?*intuition.Screen = null,

    sys: *ExecBase = undefined,
    dl: *DosBase = undefined,
    ib: *IntuitionBase = undefined,
    libraries: [3 + classes.len]?*exec.Library = @splat(null),
    /// The icon file's contents; null for a file without one.
    object: ?*icon.DiskObject = null,
    kind: Kind = .project,
    fib: dos.FileInfoBlock = .{},
    disk: dos.InfoData = .{},
    made: dos.DateStamp = .{},

    // The gadgets read back on Save.
    boxes: [bits.len]?*Object = @splat(null),
    comment: ?*Object = null,
    tool: ?*Object = null,
    stack: ?*Object = null,
    types: ?*Object = null,

    // The texts shown, which text.gadget points at.
    lines: [10][96:0]u8 = @splat(@splat(0)),
    line_count: usize = 0,
    tool_text: [dos.path_max + 1:0]u8 = @splat(0),
    types_text: [types_bytes]u8 = undefined,
    // What Save writes into the icon.
    type_pointers: [types_max + 1]?[*:0]const u8 = @splat(null),
};

/// Shows a file's information in a window.
///
/// SYNOPSIS:
/// ```zig
/// fn Information(base: *AnvilBase, lock: ?*dos.FileLock, name: [*:0]const u8, screen: ?*intuition.Screen) bool
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `lock` - the drawer `name` is in; null for the caller's current
///   directory, or when `name` is a full name.
/// - `name` - the file, the drawer or the disk (`Work:`); empty for the
///   drawer `lock` itself.
/// - `screen` - the screen the window opens on; null for the default
///   public screen.
///
/// RESULT:
/// True once the window's process has started; false with IoErr set:
/// ERROR_OBJECT_NOT_FOUND, ERROR_LINE_TOO_LONG, ERROR_NO_FREE_STORE.
///
/// BEHAVIOR:
/// The window opens on a process of its own and the call returns at
/// once. What it shows goes by the kind of the icon. A disk: whether it
/// may be written, its blocks, used and free, the block size, when it
/// was made, its default tool. A file or a drawer: when it was last
/// changed, its protection bits (Script, Archived, Readable, Writable,
/// Executable, Deletable) and, but for the trash, its comment; a program
/// or a document its size in bytes and blocks and its stack - for an
/// icon that asks for none, the one the desktop gives (24 KiB) - a
/// document its default tool; a drawer, a program and a document their
/// tool types, a line each. Without an icon file the icon's fields are
/// left out. Save writes the bits and the comment where they changed,
/// and the icon with the stack, the default tool and the tool types, and
/// closes the window; an icon that asked for no stack and still shows the
/// desktop's goes on asking for none. Cancel and the close gadget close
/// it with nothing written.
///
/// CONTEXT:
/// - Waits: yes, for the name to be found and the process started.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a process: the name is found through dos.
///
/// OWNERSHIP:
/// `lock` and `name` are read and not kept. A screen given must stay
/// open until the window has closed.
///
/// NOTES:
/// The window's process holds anvil.library open while it runs. The
/// desktop's Icons menu opens one for each icon picked.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartAnvil`, icon.library's `PutDiskObject`
///
/// EXAMPLES:
/// ```zig
/// _ = ab.Information(null, "SYS:Programs/Notepad", null);
/// ```
pub fn Information(base: *AnvilBase, lock: ?*dos.FileLock, name: [*:0]const u8, screen: ?*intuition.Screen) bool {
    const sys = base.sys_base;
    const dl = base.dos_base;
    const memory = sys.AllocVec(@sizeOf(Info), exec.MEMF_CLEAR) orelse return failed(dl, dos.ERROR_NO_FREE_STORE);
    const info: *Info = @ptrCast(@alignCast(memory));
    info.* = .{ .base = base, .screen = screen };
    // The full name, from the drawer the lock is on.
    if (lock) |held| {
        if (!dl.NameFromLock(held, &info.name, info.name.len) or !dl.AddPart(&info.name, name, info.name.len)) {
            sys.FreeVec(memory);
            return failed(dl, dos.ERROR_LINE_TOO_LONG);
        }
    } else {
        var length: usize = 0;
        while (name[length] != 0) : (length += 1) {
            if (length == dos.path_max) {
                sys.FreeVec(memory);
                return failed(dl, dos.ERROR_LINE_TOO_LONG);
            }
            info.name[length] = name[length];
        }
    }
    const there = dl.Lock(&info.name, dos.SHARED_LOCK) orelse {
        sys.FreeVec(memory);
        return failed(dl, dos.ERROR_OBJECT_NOT_FOUND);
    };
    // The full name, so the window does not hang on the caller's current
    // directory.
    if (lock == null) _ = dl.NameFromLock(there, &info.name, info.name.len);
    dl.UnLock(there);
    _base.holdLibrary(base, 1);
    const tags = [_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&infoMain) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr("Information") },
        .{ .tag = dos.NP_StackSize, .data = 24576 },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(info) },
        .{ .tag = dos.NP_HoldLibrary, .data = @intFromPtr(&base.lib) },
        .{},
    };
    if (dl.CreateNewProc(&tags) == null) {
        _base.holdLibrary(base, -1);
        sys.FreeVec(memory);
        return failed(dl, dos.ERROR_NO_FREE_STORE);
    }
    return true;
}

fn failed(dl: *DosBase, code: i32) bool {
    _ = dl.SetIoErr(code);
    return false;
}

fn pair(tag: utility.Tag, data: usize) TagItem {
    return .{ .tag = tag, .data = data };
}

fn textOf(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}

/// The window's process: what the name is read, the window shown and
/// answered, everything given back - its own block last.
fn infoMain(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const info: *Info = @ptrCast(@alignCast(me.user_data orelse return));
    defer sys.FreeVec(info);
    info.sys = sys;
    defer close(info);
    info.dl = @ptrCast(open(info, 0, dos.DOSNAME) orelse return);
    info.ib = @ptrCast(open(info, 1, intuition.INTUITIONNAME) orelse return);
    _ = open(info, 2, icon.ICONNAME);
    for (classes, 3..) |name, at| {
        if (open(info, at, name) == null and at != AT_TEXTEDIT) return;
    }
    if (!read(info)) return;
    defer if (info.object) |object| iconBase(info).FreeDiskObject(object);
    show(info);
}

fn open(info: *Info, at: usize, name: [*:0]const u8) ?*exec.Library {
    const lib = info.sys.OpenLibrary(name, 0) orelse return null;
    info.libraries[at] = lib;
    return lib;
}

fn close(info: *Info) void {
    var at = info.libraries.len;
    while (at > 0) {
        at -= 1;
        if (info.libraries[at]) |lib| info.sys.CloseLibrary(lib);
    }
}

fn iconBase(info: *Info) *IconBase {
    return @ptrCast(info.libraries[2].?);
}

/// What the name is: its FileInfoBlock, for a disk what Info says, its
/// icon and from that its kind.
fn read(info: *Info) bool {
    const dl = info.dl;
    const lock = dl.Lock(&info.name, dos.SHARED_LOCK) orelse return false;
    defer dl.UnLock(lock);
    if (!dl.Examine(lock, &info.fib)) return false;
    const parent = dl.ParentDir(lock);
    if (parent) |held| {
        dl.UnLock(held);
        info.kind = if (info.fib.dir_entry_type > 0) .drawer else .project;
    } else {
        info.kind = .disk;
        _ = dl.Info(lock, &info.disk);
        if (info.disk.volume_node) |node| info.made = node.misc.volume.volume_date;
    }
    if (info.libraries[2] != null) info.object = iconBase(info).GetDiskObject(&info.name);
    if (info.object) |object| info.kind = switch (object.kind) {
        icon.WBDISK => .disk,
        icon.WBDRAWER => .drawer,
        icon.WBTOOL => .tool,
        icon.WBGARBAGE => .garbage,
        else => .project,
    };
    return true;
}

/// A line of text shown, kept in the window's state.
fn line(info: *Info, parts: []const []const u8) [*:0]const u8 {
    const into = &info.lines[@min(info.line_count, info.lines.len - 1)];
    info.line_count += 1;
    var length: usize = 0;
    for (parts) |part| {
        const take: usize = @min(part.len, into.len - length);
        @memcpy(into[length..][0..take], part[0..take]);
        length += take;
    }
    into[length] = 0;
    return into;
}

fn numberText(into: []u8, value: u64) []const u8 {
    return into[0..path.number(into, value)];
}

fn dateText(dl: *DosBase, into: *[2 * dos.LEN_DATSTRING]u8, stamp: dos.DateStamp) []const u8 {
    var date: [dos.LEN_DATSTRING:0]u8 = @splat(0);
    var time: [dos.LEN_DATSTRING:0]u8 = @splat(0);
    var when = dos.DateTime{ .stamp = stamp, .str_date = &date, .str_time = &time };
    if (!dl.DateToStr(&when)) return "";
    const day = textOf(&date);
    const clock = textOf(&time);
    @memcpy(into[0..day.len], day);
    into[day.len] = ' ';
    @memcpy(into[day.len + 1 ..][0..clock.len], clock);
    return into[0 .. day.len + 1 + clock.len];
}

/// The window's children, gathered for its layout.
const Children = struct {
    tags: [48]TagItem = undefined,
    count: usize = 0,

    fn tag(children: *Children, tag_id: utility.Tag, data: usize) void {
        children.tags[children.count] = pair(tag_id, data);
        children.count += 1;
    }

    /// A child under `label`, as tall as it needs.
    fn add(children: *Children, object: ?*Object, label: ?[*:0]const u8) void {
        children.tag(lg.LAYOUTA_AddChild, @intFromPtr(object));
        if (label) |written| children.tag(lg.CHILDA_Label, @intFromPtr(written));
        children.tag(lg.CHILDA_WeightHeight, 0);
    }

    /// A text under `label`.
    fn text(children: *Children, ib: *IntuitionBase, shown: [*:0]const u8, label: [*:0]const u8) void {
        children.add(ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(shown)), .{} }), label);
    }
};

/// The window made, shown and answered.
fn show(info: *Info) void {
    const ib = info.ib;
    var children: Children = .{};
    children.tag(lg.LAYOUTA_Orientation, lg.LORIENT_VERT);
    children.tag(lg.LAYOUTA_Margin, 6);
    children.tag(lg.LAYOUTA_Spacing, 4);
    var number: [24]u8 = undefined;
    var more: [24]u8 = undefined;
    var when: [2 * dos.LEN_DATSTRING]u8 = undefined;
    children.text(ib, line(info, &.{textOf(@ptrCast(&info.fib.file_name))}), "Name");
    if (info.kind == .disk) {
        const disk = &info.disk;
        const state: []const u8 = switch (disk.disk_state) {
            dos.ID_WRITE_PROTECTED => "Read only",
            dos.ID_VALIDATING => "Being validated",
            dos.ID_VALIDATED => "Read and write",
            else => "Unknown",
        };
        const free = disk.num_blocks - @min(disk.num_blocks_used, disk.num_blocks);
        children.text(ib, line(info, &.{state}), "State");
        children.text(ib, line(info, &.{numberText(&number, disk.num_blocks)}), "Blocks");
        children.text(ib, line(info, &.{numberText(&number, disk.num_blocks_used)}), "Used");
        children.text(ib, line(info, &.{numberText(&number, free)}), "Free");
        children.text(ib, line(info, &.{ numberText(&number, disk.bytes_per_block), " bytes" }), "Block size");
        children.text(ib, line(info, &.{dateText(info.dl, &when, info.made)}), "Created");
    } else {
        if (info.kind == .tool or info.kind == .project) {
            children.text(ib, line(info, &.{ numberText(&number, info.fib.size), " bytes, ", numberText(&more, info.fib.num_blocks), " blocks" }), "Size");
        }
        children.text(ib, line(info, &.{dateText(info.dl, &when, info.fib.date)}), "Last changed");
        // The bits, three to a row, label under label.
        var grid_tags: [3 + 2 * bits.len + 1]TagItem = undefined;
        grid_tags[0] = pair(lg.LAYOUTA_Orientation, lg.LORIENT_GRID);
        grid_tags[1] = pair(lg.LAYOUTA_Columns, 3);
        grid_tags[2] = pair(lg.LAYOUTA_Spacing, 6);
        for (bits, 0..) |bit, at| {
            const set = info.fib.protection & bit.mask != 0;
            info.boxes[at] = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{ pair(cb.CHECKBOX_Checked, @intFromBool(set != bit.forbids)), .{} });
            grid_tags[3 + 2 * at] = pair(lg.LAYOUTA_AddChild, @intFromPtr(info.boxes[at]));
            grid_tags[4 + 2 * at] = pair(lg.CHILDA_Label, @intFromPtr(bit.label));
        }
        grid_tags[grid_tags.len - 1] = .{};
        children.add(ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &grid_tags), "Protection");
        if (info.kind != .garbage) {
            info.comment = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
                pair(gc.STRINGA_MaxChars, info.fib.comment.len - 1),
                pair(gc.STRINGA_TextVal, @intFromPtr(&info.fib.comment)),
                .{},
            });
            children.add(info.comment, "Comment");
            children.tag(lg.CHILDA_MinWidth, 280);
        }
    }
    if (info.object) |object| {
        if (info.kind == .tool or info.kind == .project) {
            info.stack = ib.NewObjectTagList(null, ig.INTEGER_CLASS, &[_]TagItem{
                pair(ig.INTEGER_Min, 0),
                pair(ig.INTEGER_Max, 1 << 20),
                pair(ig.INTEGER_Step, 4096),
                pair(ig.INTEGER_Number, if (object.stack_size != 0) object.stack_size else usual_stack),
                .{},
            });
            children.add(info.stack, "Stack");
        }
        if (info.kind == .disk or info.kind == .project) {
            if (object.default_tool) |tool| {
                const text = textOf(tool);
                const take: usize = @min(text.len, dos.path_max);
                @memcpy(info.tool_text[0..take], text[0..take]);
            }
            info.tool = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
                pair(gc.STRINGA_MaxChars, dos.path_max),
                pair(gc.STRINGA_TextVal, @intFromPtr(&info.tool_text)),
                .{},
            });
            children.add(info.tool, "Default tool");
            children.tag(lg.CHILDA_MinWidth, 280);
        }
        if (info.libraries[AT_TEXTEDIT] != null and (info.kind == .drawer or info.kind == .tool or info.kind == .project)) {
            const length = typesText(info, object);
            info.types = ib.NewObjectTagList(null, te.TEXTEDIT_CLASS, &[_]TagItem{
                pair(te.TEXTEDIT_Text, @intFromPtr(&info.types_text)),
                pair(te.TEXTEDIT_TextLength, length),
                .{},
            });
            if (info.types != null) {
                children.tag(lg.LAYOUTA_AddChild, @intFromPtr(info.types));
                children.tag(lg.CHILDA_Label, @intFromPtr("Tool types"));
                // A few lines' room, not the page the editor asks for.
                children.tag(lg.CHILDA_MinHeight, 80);
                children.tag(lg.CHILDA_MaxHeight, 120);
                children.tag(lg.CHILDA_MinWidth, 280);
                children.tag(lg.CHILDA_MaxWidth, 400);
            }
        }
    }
    children.add(ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{ pair(gc.GA_Text, @intFromPtr("_Save")), pair(gc.GA_ID, ID_SAVE), pair(gc.GA_RelVerify, 1), .{} }))),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{ pair(gc.GA_Text, @intFromPtr("_Cancel")), pair(gc.GA_ID, ID_CANCEL), pair(gc.GA_RelVerify, 1), .{} }))),
        .{},
    }), null);
    children.tags[children.count] = .{};
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &children.tags) orelse return;
    const window_object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr(&info.name)),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wn.WA_Position, wn.WPOS_CENTERSCREEN),
        pair(if (info.screen != null) wn.WA_CustomScreen else utility.TAG_IGNORE, @intFromPtr(info.screen)),
        pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        return;
    };
    defer ib.DisposeObject(window_object);
    var opening = wc.WmOpen{};
    if (ib.SendMessage(window_object, @ptrCast(&opening)) == 0) return;
    var window_ptr: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, window_object, &window_ptr);
    const window: *intuition.Window = @ptrFromInt(window_ptr);

    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    while (true) {
        _ = ib.WaitIMsg(window, 0);
        while (true) {
            const word = ib.SendMessage(window_object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return,
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_SAVE => {
                        save(info, window);
                        return;
                    },
                    ID_CANCEL => return,
                    else => {},
                },
                else => {},
            }
        }
    }
}

/// The icon's tool types a line each into `types_text`; their length.
fn typesText(info: *Info, object: *icon.DiskObject) usize {
    var length: usize = 0;
    const types = object.tool_types orelse return 0;
    var at: usize = 0;
    while (types[at]) |one| : (at += 1) {
        const text = textOf(one);
        if (length + text.len + 1 > types_bytes) break;
        @memcpy(info.types_text[length..][0..text.len], text);
        length += text.len;
        info.types_text[length] = '\n';
        length += 1;
    }
    return length;
}

/// What the window says now written: the bits, the comment, the icon.
fn save(info: *Info, window: *intuition.Window) void {
    const ib = info.ib;
    const dl = info.dl;
    if (info.kind != .disk) {
        var protection = info.fib.protection;
        for (bits, info.boxes) |bit, held| {
            const box = held orelse continue;
            var checked: usize = 0;
            _ = ib.GetAttr(cb.CHECKBOX_Checked, box, &checked);
            if ((checked != 0) != bit.forbids) protection |= bit.mask else protection &= ~bit.mask;
        }
        if (protection != info.fib.protection) _ = dl.SetProtection(&info.name, protection);
    }
    if (info.comment) |field| {
        var typed: usize = 0;
        _ = ib.GetAttr(gc.STRINGA_TextVal, field, &typed);
        if (typed != 0) {
            const comment: [*:0]const u8 = @ptrFromInt(typed);
            if (!same(comment, @ptrCast(&info.fib.comment))) _ = dl.SetComment(&info.name, comment);
        }
    }
    const object = info.object orelse return;
    // The icon's fields pointed at the window's while it is written, and
    // put back after, for FreeDiskObject.
    const was = object.*;
    defer object.* = was;
    if (info.tool) |field| {
        var typed: usize = 0;
        _ = ib.GetAttr(gc.STRINGA_TextVal, field, &typed);
        const tool: ?[*:0]const u8 = if (typed != 0) @ptrFromInt(typed) else null;
        object.default_tool = if (tool != null and tool.?[0] != 0) tool else null;
    }
    if (info.stack) |field| {
        var value: usize = 0;
        _ = ib.GetAttr(ig.INTEGER_Number, field, &value);
        // The usual one, shown for an icon that asks for none, is left
        // unasked for: it follows the desktop's from then on.
        if (!(object.stack_size == 0 and value == usual_stack)) {
            object.stack_size = @intCast((value + 3) & ~@as(usize, 3));
        }
    }
    if (info.types) |editor| {
        var length: usize = 0;
        _ = ib.GetAttr(te.TEXTEDIT_Length, editor, &length);
        length = @min(length, types_bytes - 1);
        var take = te.TepText{ .method_id = te.TEM_GETTEXT, .buffer = &info.types_text, .size = @intCast(length) };
        _ = ib.DoGadgetMethodA(editor, window, null, @ptrCast(&take));
        _ = splitLines(info.types_text[0 .. length + 1], &info.type_pointers);
        object.tool_types = &info.type_pointers;
    }
    if (!iconBase(info).PutDiskObject(&info.name, object)) {
        const easy = intuition.EasyStruct{ .title = "Information", .text_format = "The icon could not be written.", .gadget_format = "OK" };
        _ = ib.EasyRequestArgs(window, &easy, null, null);
    }
}

/// The lines of `text` but for its last byte, each that is not empty a
/// string where it is - a NUL put where it ended, the last one in the
/// last byte - into `into`, as many as fit before a null after them. How
/// many there are.
pub fn splitLines(text: []u8, into: []?[*:0]const u8) usize {
    const length = text.len - 1;
    var count: usize = 0;
    var start: usize = 0;
    for (0..length + 1) |at| {
        if (at < length and text[at] != '\n') continue;
        text[at] = 0;
        if (at > start and count < into.len - 1) {
            into[count] = @ptrCast(&text[start]);
            count += 1;
        }
        start = at + 1;
    }
    into[count] = null;
    return count;
}

fn same(one: [*:0]const u8, other: [*:0]const u8) bool {
    var at: usize = 0;
    while (one[at] == other[at]) : (at += 1) {
        if (one[at] == 0) return true;
    }
    return false;
}
