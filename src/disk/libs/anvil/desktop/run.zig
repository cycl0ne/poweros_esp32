// SPDX-License-Identifier: MIT
//! Opening what was double-clicked: a disk, a drawer or the trash into
//! its window; anything else by running a program with the icons picked.
//!
//! **Which program**, as the original chooses it: a tool among the icons
//! picked runs with every other picked icon handed to it; else the first
//! project with a default tool has that tool run with the picked icons;
//! else the project clicked is opened with its file type's tool
//! (datatypes.library's BROWSE); else a script - a file with its script
//! bit - runs through `C:IconX`; else the screen's title says it has no
//! tool.
//!
//! **How**, as `Run` starts a program: in a shell of its own that ends
//! with it, its files on its command line - each full name quoted - and
//! as lock-and-name pairs (`NP_ArgList`) for a program that wants locks:
//! the program first, then each file, a drawer or a disk as a lock on
//! itself with an empty name. Its input is NIL:, its output a console
//! that opens only if it prints. It starts in the drawer of the program,
//! with the stack its icon asks for and the priority of its `TOOLPRI`
//! tool type. The desktop counts it until the message it gave the process
//! (`NP_EndMsg`) comes back, which is when Quit may go ahead.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const icon = sdk.icon;
const utility = sdk.utility;
const datatypes = sdk.datatypes;
const TagItem = utility.TagItem;
const icons = @import("../icons/_icons.zig");
const Icon = icons.Icon;
const drawer = @import("../drawer/_drawer.zig");
const Drawer = drawer.Drawer;
const drawer_path = @import("../drawer/path.zig");
const Desktop = @import("_desktop.zig").Desktop;
const app = @import("app.zig");

/// The most icons handed to one program.
const chosen_max = 16;
/// The longest command line made.
const line_max = 4096;

/// The message a started program's process gives back as it ends.
pub const Ended = struct {
    message: exec.Message = .{},
};

/// An icon picked, as a program is handed it: its full name, and its
/// icon - its own, or read for the purpose (`owned`).
const Chosen = struct {
    path: [dos.path_max + 1:0]u8 = @splat(0),
    object: ?*icon.DiskObject = null,
    owned: bool = false,
    /// Its protection bits, for a script.
    entry_protection: u32 = 0,

    fn pathText(chosen: *const Chosen) []const u8 {
        var n: usize = 0;
        while (chosen.path[n] != 0) n += 1;
        return chosen.path[0..n];
    }

    fn kind(chosen: *const Chosen) u32 {
        const object = chosen.object orelse return icon.WBPROJECT;
        return object.kind;
    }
};

/// What a run is made of, in one block: the icons, the pairs and the
/// line, too large for the desktop's stack.
const Work = struct {
    chosen: [chosen_max]Chosen = @splat(.{}),
    count: usize = 0,
    pairs: [chosen_max + 1]dos.WBArg = undefined,
    spelled: [chosen_max + 1][dos.name_max + 1]u8 = undefined,
    pair_count: usize = 0,
    line: [line_max]u8 = undefined,
    tool: [dos.path_max + 1:0]u8 = @splat(0),
};

/// The full name of an icon on its ground into `into`: `Name:` for a disk
/// on the desktop, the drawer's path and its name in a drawer. Its length.
pub fn pathOf(where: ?*Drawer, ic: *const Icon, into: []u8) ?usize {
    if (where) |dr| return drawer_path.join(into, dr.pathText(), ic.name());
    if (ic.path) |held| {
        const text = textOf(held);
        if (text.len + 1 > into.len) return null;
        @memcpy(into[0..text.len], text);
        into[text.len] = 0;
        return text.len;
    }
    const name = ic.name();
    if (name.len + 2 > into.len) return null;
    @memcpy(into[0..name.len], name);
    into[name.len] = ':';
    into[name.len + 1] = 0;
    return name.len + 1;
}

/// The icon double-clicked opened - a program's icon by telling its
/// program.
pub fn open(d: *Desktop, where: ?*Drawer, ic: *Icon) void {
    if (ic.app != null) return app.opened(d, ic);
    var full: [dos.path_max + 1]u8 = undefined;
    const length = pathOf(where, ic, &full) orelse return;
    const kind: u32 = if (ic.object) |object| object.kind else if (ic.entry.isDrawer()) icon.WBDRAWER else icon.WBPROJECT;
    const a_disk = where == null and ic.path == null;
    if (a_disk or kind == icon.WBDISK or kind == icon.WBDRAWER or kind == icon.WBGARBAGE or ic.entry.isDrawer()) {
        drawer.open(d, full[0..length]);
        return;
    }
    runChosen(d, where, ic);
}

/// Every icon picked, on every ground, into `work`; the clicked one
/// first, so a project's own tool is found for it before any other.
fn gather(d: *Desktop, work: *Work, where: ?*Drawer, clicked: *Icon) void {
    add(d, work, where, clicked);
    var on_ground = d.volumes.iterator();
    while (on_ground.next()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        if (ic.selected and ic != clicked) add(d, work, null, ic);
    }
    var drawers = d.drawers.iterator();
    while (drawers.next()) |dnode| {
        const dr: *Drawer = @alignCast(@fieldParentPtr("node", dnode));
        var it = dr.icons.iterator();
        while (it.next()) |node| {
            const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
            if (ic.selected and ic != clicked) add(d, work, dr, ic);
        }
    }
}

fn add(d: *Desktop, work: *Work, where: ?*Drawer, ic: *Icon) void {
    if (work.count == chosen_max) return;
    const chosen = &work.chosen[work.count];
    _ = pathOf(where, ic, &chosen.path) orelse return;
    chosen.object = ic.object;
    if (chosen.object == null) {
        // A drawer viewed as text has read no icons: read this one now.
        chosen.object = d.icon_base.GetDiskObjectNew(&chosen.path);
        chosen.owned = chosen.object != null;
    }
    chosen.entry_protection = ic.entry.protection;
    work.count += 1;
}

fn release(d: *Desktop, work: *Work) void {
    for (work.chosen[0..work.count]) |*chosen| {
        if (chosen.owned) if (chosen.object) |object| d.icon_base.FreeDiskObject(object);
    }
    for (work.pairs[0..work.pair_count]) |pair| d.dl.UnLock(pair.lock);
}

/// The icons picked run, as the file's header says.
fn runChosen(d: *Desktop, where: ?*Drawer, clicked: *Icon) void {
    const memory = d.sys.AllocVec(@sizeOf(Work), exec.MEMF_CLEAR) orelse return;
    defer d.sys.FreeVec(memory);
    const work: *Work = @ptrCast(@alignCast(memory));
    work.* = .{};
    gather(d, work, where, clicked);
    defer release(d, work);
    _ = launch(d, work);
}

/// The file `path` run as a double click on its icon `object` runs it,
/// alone: the end message of the program started, which the desktop is
/// given back when it ends, or null when none was.
pub fn runFile(d: *Desktop, path: [*:0]const u8, object: *icon.DiskObject) ?*Ended {
    const memory = d.sys.AllocVec(@sizeOf(Work), exec.MEMF_CLEAR) orelse return null;
    defer d.sys.FreeVec(memory);
    const work: *Work = @ptrCast(@alignCast(memory));
    work.* = .{};
    const chosen = &work.chosen[0];
    const length = textOf(path).len;
    if (length > dos.path_max) return null;
    @memcpy(chosen.path[0..length], textOf(path));
    chosen.object = object;
    // Its protection, for a script.
    if (d.dl.Lock(path, dos.SHARED_LOCK)) |lock| {
        defer d.dl.UnLock(lock);
        if (d.sys.AllocVec(@sizeOf(dos.FileInfoBlock), exec.MEMF_CLEAR)) |fib_memory| {
            defer d.sys.FreeVec(fib_memory);
            const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(fib_memory));
            if (d.dl.Examine(lock, fib)) chosen.entry_protection = fib.protection;
        }
    }
    work.count = 1;
    defer release(d, work);
    return launch(d, work);
}

/// The chosen icons run: the end message of the program started, or null
/// when none was.
fn launch(d: *Desktop, work: *Work) ?*Ended {
    if (work.count == 0) return null;

    // A tool among them: it runs, with the others.
    for (work.chosen[0..work.count], 0..) |*chosen, i| {
        if (chosen.kind() != icon.WBTOOL) continue;
        return start(d, work, chosen.pathText(), i, chosen.object);
    }
    // A project with a default tool: that tool, with all of them.
    for (work.chosen[0..work.count]) |*chosen| {
        const object = chosen.object orelse continue;
        if (object.kind != icon.WBPROJECT) continue;
        const tool = object.default_tool orelse continue;
        if (tool[0] == 0) continue;
        return start(d, work, textOf(tool), null, object);
    }
    const first = &work.chosen[0];
    // The file's type's tool.
    if (typeTool(d, &first.path, &work.tool)) {
        return start(d, work, textOf(&work.tool), null, first.object);
    }
    // A script, through IconX.
    if (first.entry_protection & dos.FIBF_SCRIPT != 0) return start(d, work, "C:IconX", null, first.object);
    var said: [96]u8 = undefined;
    d.say(sayText(&said, drawer_path.lastPart(first.pathText()), " has no tool to open it"));
    return null;
}

fn sayText(into: []u8, name: []const u8, rest: []const u8) []const u8 {
    const shown = name[0..@min(name.len, into.len - rest.len - 1)];
    @memcpy(into[0..shown.len], shown);
    @memcpy(into[shown.len..][0..rest.len], rest);
    return into[0 .. shown.len + rest.len];
}

fn textOf(text: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return text[0..n];
}

/// The BROWSE tool datatypes.library names for the file `path`, into
/// `into`; false when it names none.
fn typeTool(d: *Desktop, path: [*:0]const u8, into: *[dos.path_max + 1:0]u8) bool {
    const dt = d.dt orelse return false;
    const lock = d.dl.Lock(path, dos.SHARED_LOCK) orelse return false;
    defer d.dl.UnLock(lock);
    const kind = dt.ObtainDataTypeA(datatypes.datatypesclass.DTST_FILE, lock, null) orelse return false;
    defer dt.ReleaseDataType(kind);
    const tool = datatypes.toolFor(kind, datatypes.TW_BROWSE) orelse return false;
    const text = textOf(tool);
    if (text.len == 0 or text.len > dos.path_max) return false;
    @memcpy(into[0..text.len], text);
    into[text.len] = 0;
    return true;
}

/// The pair for one name into the work's next.
fn pairOf(d: *Desktop, work: *Work, name: [*:0]const u8) bool {
    const at = work.pair_count;
    work.pairs[at] = pairFor(d, name, &work.spelled[at]) orelse return false;
    work.pair_count += 1;
    return true;
}

/// The pair for one name: a lock on its drawer and its own name, spelled
/// into `spelled`, or for a drawer or a disk a lock on itself and an
/// empty name. The lock is the caller's to let go of.
pub fn pairFor(d: *Desktop, name: [*:0]const u8, spelled: *[dos.name_max + 1]u8) ?dos.WBArg {
    const lock = d.dl.Lock(name, dos.SHARED_LOCK) orelse return null;
    const memory = d.sys.AllocVec(@sizeOf(dos.FileInfoBlock), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        d.dl.UnLock(lock);
        return null;
    };
    defer d.sys.FreeVec(memory);
    const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(memory));
    if (!d.dl.Examine(lock, fib)) {
        d.dl.UnLock(lock);
        return null;
    }
    if (fib.dir_entry_type > 0) {
        spelled[0] = 0;
        return .{ .lock = lock, .name = @ptrCast(spelled) };
    }
    const parent = d.dl.ParentDir(lock);
    d.dl.UnLock(lock);
    const above = parent orelse return null;
    @memcpy(spelled, &fib.file_name);
    return .{ .lock = above, .name = @ptrCast(spelled) };
}

/// `tool` started with the chosen icons - all but the one at `tool_at`,
/// which is the tool itself - its stack and priority from `object`: its
/// end message, or null when it could not be started.
fn start(d: *Desktop, work: *Work, tool: []const u8, tool_at: ?usize, object: ?*icon.DiskObject) ?*Ended {
    const dl = d.dl;
    var tool_z: [dos.path_max + 1:0]u8 = @splat(0);
    if (tool.len > dos.path_max) return null;
    @memcpy(tool_z[0..tool.len], tool);

    // The pairs: the tool, found where it is - on the command path it is
    // only a name, in the desktop's own drawer - then each file.
    if (!pairOf(d, work, &tool_z)) {
        const here = dl.Lock("", dos.SHARED_LOCK) orelse return null;
        const at = work.pair_count;
        const name = dl.FilePart(&tool_z);
        const length = textOf(name).len;
        @memcpy(work.spelled[at][0..length], textOf(name));
        work.spelled[at][length] = 0;
        work.pairs[at] = .{ .lock = here, .name = @ptrCast(&work.spelled[at]) };
        work.pair_count += 1;
    }
    var n: usize = dos.rdargs.quote(work.line[0 .. line_max - 2], tool) orelse return null;
    for (work.chosen[0..work.count], 0..) |*chosen, i| {
        if (tool_at == i) continue;
        if (!pairOf(d, work, &chosen.path)) continue;
        work.line[n] = ' ';
        n += 1;
        n += dos.rdargs.quote(work.line[n .. line_max - 2], chosen.pathText()) orelse break;
    }
    work.line[n] = '\n';
    work.line[n + 1] = 0;

    // Its console, open only once it prints; NIL: for its input.
    var window: [192:0]u8 = @splat(0);
    const title = textOf(dl.FilePart(&tool_z));
    var w: usize = 0;
    for ([_][]const u8{ "CON:40/60/560/240/", title[0..@min(title.len, 100)], "/AUTO/CLOSE/WAIT" }) |piece| {
        @memcpy(window[w..][0..piece.len], piece);
        w += piece.len;
    }
    const output = dl.Open(&window, dos.MODE_NEWFILE) orelse return null;
    const input = dl.Open("NIL:", dos.MODE_OLDFILE) orelse {
        _ = dl.Close(output);
        return null;
    };
    const ended_memory = d.sys.AllocVec(@sizeOf(Ended), exec.MEMF_CLEAR) orelse {
        _ = dl.Close(input);
        _ = dl.Close(output);
        return null;
    };
    const ended: *Ended = @ptrCast(@alignCast(ended_memory));
    ended.* = .{ .message = .{ .reply_port = d.reply_port, .length = @sizeOf(Ended) } };
    // It starts in the drawer of the program, or of its first file.
    const home: ?*dos.FileLock = if (work.pair_count > 0) dl.DupLock(work.pairs[0].lock) else null;

    var stack: usize = 0;
    var priority: ?isize = null;
    if (object) |held| {
        stack = held.stack_size;
        if (d.icon_base.FindToolType(held.tool_types, "TOOLPRI")) |value| {
            priority = decimal(textOf(value));
        }
    }
    var tags: [12]TagItem = undefined;
    var count: usize = 0;
    const put = struct {
        fn one(into: []TagItem, at: *usize, tag: utility.Tag, data: usize) void {
            into[at.*] = .{ .tag = tag, .data = data };
            at.* += 1;
        }
    }.one;
    put(&tags, &count, dos.SYS_Asynch, 1);
    put(&tags, &count, dos.SYS_Input, @intFromPtr(input));
    put(&tags, &count, dos.SYS_Output, @intFromPtr(output));
    put(&tags, &count, dos.NP_ArgList, @intFromPtr(&work.pairs));
    put(&tags, &count, dos.NP_NumArgs, work.pair_count);
    put(&tags, &count, dos.NP_EndMsg, @intFromPtr(&ended.message));
    if (home) |lock| put(&tags, &count, dos.NP_CurrentDir, @intFromPtr(lock));
    if (stack != 0) put(&tags, &count, dos.NP_StackSize, stack);
    if (priority) |pri| put(&tags, &count, dos.NP_Priority, @bitCast(pri));
    tags[count] = .{};
    if (dl.SystemTagList(@ptrCast(&work.line), &tags) < 0) {
        if (home) |lock| dl.UnLock(lock);
        _ = dl.Close(input);
        _ = dl.Close(output);
        d.sys.FreeVec(ended_memory);
        var said: [96]u8 = undefined;
        d.say(sayText(&said, title, " could not be started"));
        return null;
    }
    d.running += 1;
    return ended;
}

/// A command line run in a shell of its own, as Execute Command does: its
/// output in a console titled `title` that opens if it prints, counted
/// until it ends.
pub fn command(d: *Desktop, line: [*:0]const u8, title: []const u8) void {
    const dl = d.dl;
    var window: [192:0]u8 = @splat(0);
    var w: usize = 0;
    for ([_][]const u8{ "CON:40/60/560/240/", title[0..@min(title.len, 100)], "/AUTO/CLOSE/WAIT" }) |piece| {
        @memcpy(window[w..][0..piece.len], piece);
        w += piece.len;
    }
    const output = dl.Open(&window, dos.MODE_NEWFILE) orelse return;
    const input = dl.Open("NIL:", dos.MODE_OLDFILE) orelse {
        _ = dl.Close(output);
        return;
    };
    const memory = d.sys.AllocVec(@sizeOf(Ended), exec.MEMF_CLEAR) orelse {
        _ = dl.Close(input);
        _ = dl.Close(output);
        return;
    };
    const ended: *Ended = @ptrCast(@alignCast(memory));
    ended.* = .{ .message = .{ .reply_port = d.reply_port, .length = @sizeOf(Ended) } };
    const tags = [_]TagItem{
        .{ .tag = dos.SYS_Asynch, .data = 1 },
        .{ .tag = dos.SYS_Input, .data = @intFromPtr(input) },
        .{ .tag = dos.SYS_Output, .data = @intFromPtr(output) },
        .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(&ended.message) },
        .{},
    };
    if (dl.SystemTagList(line, &tags) < 0) {
        _ = dl.Close(input);
        _ = dl.Close(output);
        d.sys.FreeVec(memory);
        d.say("The command could not be started");
        return;
    }
    d.running += 1;
}

/// A tool type's number, -128 to 127; null for anything else.
pub fn decimal(text: []const u8) ?isize {
    var value: isize = 0;
    var negative = false;
    var rest = text;
    if (rest.len > 0 and rest[0] == '-') {
        negative = true;
        rest = rest[1..];
    }
    if (rest.len == 0 or rest.len > 3) return null;
    for (rest) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    if (negative) value = -value;
    if (value < -128 or value > 127) return null;
    return value;
}
