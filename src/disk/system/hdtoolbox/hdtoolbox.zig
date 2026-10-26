// SPDX-License-Identifier: MIT
//! HDToolBox: a drive's partitions - the flash disk's, a card's, a
//! stick's, those of any block device the board has - shown, changed and
//! written back as the drive's RigidDiskBlock. Built against the SDK only.
//!
//!   SYS:System/HDToolBox
//!
//! **The window.** At the top the drive to work on, picked from every
//! unit of every block device (`drives.Units`), and a line saying what it
//! holds. Under it the drive as a bar, its partitions across it in the
//! order of their cylinders and the free runs between them; then the
//! partitions as a list - name, cylinders, size, file system, and the
//! drive each is mounted as - and the fields of the one picked, on two
//! pages: **Partition** (name, file system, first and last cylinder,
//! size, bootable) and **Advanced** (buffers, the most bytes a request
//! moves, boot priority, whether it is mounted at start). The buttons:
//! **New** makes a partition of the free run picked, **Delete** removes
//! the one picked, **Whole disk** makes the drive one partition, **New
//! table** an empty table, **Save** writes it, **Quit** leaves.
//!
//! A third page, **File systems**, lists the file systems the table
//! keeps - the code its partitions of a DosType run when the ROM has no
//! handler for it or an older one - with each one's version, size and
//! whether it is the code that runs. **Add...** reads a handler's load
//! file, from HANDLERS: as a rule, and keeps it for the DosType **For**
//! names, in place of the one kept for it before; **Remove** takes the
//! one picked out. A DosType the table keeps code for is offered to the
//! partitions too. A drive mounted from the table runs the new code once
//! the system starts again, which Save offers.
//!
//! **The bar.** A press picks a partition or a free run. Held in its
//! middle a partition is moved, held at an edge resized, each as far as
//! its neighbours let it (`model.moved`, `model.resized`); an edge snaps
//! to the drive's grid (`model.Grid`). The list picks the same partition,
//! and so do the fields: what is typed into Start and End is taken as
//! typed, as far as the neighbours let it.
//!
//! **A drive with a GPT.** The bar is then the whole disk: the GPT's
//! partitions lie on it where they are, fixed, each named by its own
//! name or its type, and the PowerOS container's table is worked on in
//! the container's cylinders (counted from the container's first block,
//! as the fields show them), drawn where the container is. A partition
//! of the GPT is picked and deleted, never moved. New and Whole disk on
//! a GPT with no container make one over the GPT's largest free run, and
//! a table in it (`AddGPTPartition`, `InitRDB`). New table asks which
//! kind: a RigidDiskBlock over the whole drive (`RemGPT`, `InitRDB`), or
//! a GPT for the whole drive with a container over it (`InitGPT`). Save
//! writes the GPT first (`WriteGPT`) and the table after it, and a GPT
//! read from its copy at the end is offered to be saved, which mends it.
//!
//! **What may be changed.** Everything stays in memory, in the table
//! rdb.library read (`OpenRDB`), until Save. A table read for another
//! block size, or a damaged one, is shown, and can only be replaced (New
//! table, Whole disk). The partition SYS: is on is not moved, removed or
//! given another file system, and the drive it is on gets no new table.
//! The file systems offered are those that can go on the drive
//! (`sdk.dos.filesystems.suits`), and only a drive the ROM mounts at start
//! is booted from, so Bootable is offered only there.
//!
//! **Save.** What the table does to the drives mounted from it is worked
//! out first (`model.stale`): a drive laid out as a partition of the new
//! table goes on as it is, any other is stale. A requester names the
//! partitions whose data is lost and the stale drives. Each stale drive is
//! inhibited - one that refuses, a file open for writing on it, stops the
//! save before anything is written - and stays so, as its handler still
//! reads the old layout. Then the table is written (`WriteRDB`; a medium
//! changed since it was read is read again instead), every partition
//! not yet mounted is mounted and started (`MountPartition`), and with
//! anything stale HDToolBox offers to restart the system: every file
//! system is inhibited first, so that each writes out what it holds, and
//! one that will not is named before the restart.
//!
//! **A medium that comes or goes** on the drive shown is seen (the
//! window's disk-inserted and disk-removed messages, the medium's change
//! count): the drive is read again, after asking when there are changes
//! not saved. Quit asks the same.
//!
//! HDToolBox does not format: C:Format and the desktop's Format put a
//! file system on a partition.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const rdb = sdk.rdb;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const hardblocks = dos.hardblocks;
const filesystems = dos.filesystems;
const gpt = dos.gpt;
const td = sdk.devices.trackdisk;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const RDBBase = sdk.interface.rdb.RDBBase;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const Printf = dos.stdio.Printf;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const icc = intuition.icclass;
const classusr = intuition.classusr;
const sc = intuition.screens;
const requesters = intuition.requesters;
const ct = sdk.gadgets.clicktab;
const pgc = sdk.gadgets.page;
const ch = sdk.gadgets.chooser;
const st = sdk.gadgets.string;
const ig = sdk.gadgets.integer;
const tx = sdk.gadgets.text;
const cb = sdk.gadgets.checkbox;
const cv = sdk.gadgets.canvas;
const lb = sdk.gadgets.listbrowser;
const asl = sdk.asl;
const AslBase = sdk.interface.asl.AslBase;
const model = @import("model.zig");
const drives = @import("drives.zig");
const Span = model.Span;

pub const COMMAND_NAME = "HDToolBox";
const VERSION = "1.3";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (26.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
/// What the screen's bar says while the window is active.
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const MSG_NOLIBRARY = "No %s\n";
const MSG_OLDLIBRARY = "%s is too old: 1.4 or later is needed\n";
const MSG_NOSCREEN = "No screen\n";
const MSG_NOMEMORY = "No memory for the window\n";

/// The rdb.library that reads and writes a GPT.
const rdb_version = 1;
const rdb_revision = 4;

/// The name a container HDToolBox makes is given in the GPT.
const container_name = "PowerOS";

// --- the gadgets' IDs ----------------------------------------------------------------

const ID_DRIVE = 1;
const ID_BAR = 2;
const ID_LIST = 3;
const ID_TABS = 4;
const ID_NAME = 5;
const ID_FILESYSTEM = 6;
const ID_START = 7;
const ID_END = 8;
const ID_BOOTABLE = 9;
const ID_BUFFERS = 10;
const ID_TRANSFER = 11;
const ID_BOOTPRI = 12;
const ID_AUTOMOUNT = 13;
const ID_FS_LIST = 14;
const ID_FS_FOR = 15;
const ID_NEW = 20;
const ID_DELETE = 21;
const ID_WHOLE = 22;
const ID_TABLE = 23;
const ID_SAVE = 24;
const ID_QUIT = 25;
const ID_FS_ADD = 26;
const ID_FS_REMOVE = 27;

const tab_names = [_:null]?[*:0]const u8{ "Partition", "Advanced", "File systems" };
const page_partition = 0;
const page_advanced = 1;
const page_files = 2;

const columns = [_]lb.Column{
    .{ .title = "Name", .weight = 3 },
    .{ .title = "Cylinders", .weight = 4, .flags = lb.COLUMN_NUMBER },
    .{ .title = "Size", .weight = 2, .flags = lb.COLUMN_RIGHT | lb.COLUMN_NUMBER },
    .{ .title = "File system", .weight = 3 },
    .{ .title = "Mounted", .weight = 2 },
    .{},
};

const fs_columns = [_]lb.Column{
    .{ .title = "Name", .weight = 3 },
    .{ .title = "Version", .weight = 3, .flags = lb.COLUMN_NUMBER },
    .{ .title = "Size", .weight = 2, .flags = lb.COLUMN_RIGHT | lb.COLUMN_NUMBER },
    .{ .title = "Runs", .weight = 3 },
    .{},
};

/// The most file systems a table keeps.
const max_stored = 16;

/// The most partitions shown of a table.
const max_parts = 64;
/// Pixels of a partition's edge that take hold of it on the bar.
const grip_pixels = 8;
/// The bar's height, and the width it asks the layout for at least.
const bar_height = 36;
const bar_width = 300;

/// `part` eighths of `over` laid on `under`.
fn mix(under: graphics.Pen, over: graphics.Pen, part: u32) graphics.Pen {
    var out: graphics.Pen = 0xFF00_0000;
    var shift: u5 = 0;
    while (shift < 24) : (shift += 8) {
        const beneath = (under >> shift) & 0xFF;
        const above = (over >> shift) & 0xFF;
        out |= ((beneath * (8 - part) + above * part) / 8) << shift;
    }
    return out;
}

/// A line of text put together piece by piece, cut at its end.
fn Line(comptime size: usize) type {
    return struct {
        const Self = @This();
        text: [size:0]u8 = @splat(0),
        len: usize = 0,

        fn clear(line: *Self) void {
            line.len = 0;
            line.text[0] = 0;
        }

        fn add(line: *Self, piece: []const u8) void {
            for (piece) |char| {
                if (line.len == size) break;
                line.text[line.len] = char;
                line.len += 1;
            }
            line.text[line.len] = 0;
        }

        fn addText(line: *Self, piece: [*:0]const u8) void {
            var index: usize = 0;
            while (piece[index] != 0) : (index += 1) line.add(piece[index .. index + 1]);
        }

        fn number(line: *Self, value: u64) void {
            var digits: [20]u8 = undefined;
            line.add(digits[0..model.decimal(&digits, value)]);
        }

        fn ptr(line: *const Self) [*:0]const u8 {
            return &line.text;
        }

        fn slice(line: *const Self) []const u8 {
            return line.text[0..line.len];
        }
    };
}

/// A partition of the table as it was read: what a save compares the
/// new table with.
const Before = struct {
    /// The partition on the handle's list; null once it is removed.
    part: ?*rdb.RDBPartition,
    env: dos.DosEnvec,
    name: rdb.MountName,
};

/// A partition of the GPT as it was read: what a save names as lost
/// once it is deleted.
const GptBefore = struct {
    /// The partition on the handle's list; null once it is removed.
    part: ?*rdb.GPTPartition,
    name: [gpt.name_units:0]u8,
};

/// What is picked on the bar.
const Picked = union(enum) {
    none,
    part: *rdb.RDBPartition,
    gap: Span,
    /// A partition of the GPT's, not the container.
    gpt: *rdb.GPTPartition,
};

/// The two tables New table makes.
const TableKind = enum { rdb, gpt };

/// Which of the two a save was writing when it stopped.
const Written = enum { gpt, table };

/// What a press on the bar holds.
const Drag = enum { none, move, low, high };

/// The colours the bar is drawn in, from the screen's pens.
const Pens = struct {
    paper: graphics.Pen = 0,
    ink: graphics.Pen = 0,
    free: graphics.Pen = 0,
    part: graphics.Pen = 0,
    picked: graphics.Pen = 0,
    picked_ink: graphics.Pen = 0,
    edge: graphics.Pen = 0,
    system: graphics.Pen = 0,
    /// A partition of the GPT's.
    foreign: graphics.Pen = 0,
};

const App = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    eb: *ExpansionBase,
    rb: *RDBBase,
    screen: *intuition.Screen,
    draw_info: *intuition.DrawInfo,
    object: *Object = undefined,
    window: ?*intuition.Window = null,

    // The gadgets, the window object's.
    drive: *Object = undefined,
    status: *Object = undefined,
    bar: *Object = undefined,
    list: *Object = undefined,
    tabs: *Object = undefined,
    name: *Object = undefined,
    file_system: *Object = undefined,
    start: *Object = undefined,
    end: *Object = undefined,
    size: *Object = undefined,
    bootable: *Object = undefined,
    buffers: *Object = undefined,
    transfer: *Object = undefined,
    boot_pri: *Object = undefined,
    automount: *Object = undefined,
    new: *Object = undefined,
    delete: *Object = undefined,
    whole: *Object = undefined,
    new_table: *Object = undefined,
    save: *Object = undefined,
    fs_list: *Object = undefined,
    fs_for: *Object = undefined,
    fs_add: *Object = undefined,
    fs_remove: *Object = undefined,
    pages: [tab_names.len:null]?*Object = @splat(null),

    // The drives.
    units: drives.Units = .{},
    unit_text: [drives.max_units]Line(48) = @splat(.{}),
    unit_labels: [drives.max_units + 1:null]?[*:0]const u8 = @splat(null),
    current: usize = 0,
    system: ?*const dos.DosList = null,

    // The drive shown: its table, as read and as it is now.
    handle: ?*rdb.RDBHandle = null,
    /// Why there is no handle: OpenRDB's answer.
    problem: i32 = rdb.RDBERR_OK,
    /// InitRDB has made a table the drive did not have.
    made_table: bool = false,
    changed: bool = false,
    /// A save left drives stale: the system wants a restart.
    restart_wanted: bool = false,
    grid: model.Grid = .{},
    before: [max_parts]Before = undefined,
    before_count: usize = 0,
    mounted: [drives.max_mounted]drives.Mounted = undefined,
    mounted_count: usize = 0,
    /// The partitions in the order of their cylinders, and their spans.
    parts: [max_parts]*rdb.RDBPartition = undefined,
    spans: [max_parts]Span = undefined,
    count: usize = 0,
    picked: Picked = .none,

    // The GPT, on a drive that has one.
    /// Its partitions but the container, in the order of their blocks,
    /// and their spans on the bar.
    gpt_parts: [max_parts]*rdb.GPTPartition = undefined,
    gpt_spans: [max_parts]Span = undefined,
    gpt_count: usize = 0,
    gpt_before: [max_parts]GptBefore = undefined,
    gpt_before_count: usize = 0,
    /// The GPT was read from its copy at the end: a save mends it.
    gpt_repair: bool = false,
    /// The bar's cylinders, in blocks: the table's, or a whole MiB on a
    /// GPT with no table.
    bar_unit: u64 = 1,
    /// The bar's cylinder the table's first is drawn at: the container's.
    shift: u32 = 0,
    /// The table's spans as the bar has them.
    bar_spans: [max_parts]Span = undefined,
    /// The type of the GPT's partition picked, as the file systems'
    /// chooser shows it.
    gpt_kind: [gpt.guid_text_len:0]u8 = @splat(0),

    // The bar.
    rp: *graphics.RastPort = undefined,
    bar_w: i32 = bar_width,
    bar_h: i32 = bar_height,
    baseline: i32 = 0,
    font_h: i32 = 8,
    pens: Pens = .{},
    drag: Drag = .none,
    drag_from: i32 = 0,
    drag_span: Span = .{ .low = 0, .high = 0 },
    drag_room: Span = .{ .low = 0, .high = 0 },

    // The list and the fields.
    rows: exec.List = .{},
    fs_labels: [filesystems.all.len + max_stored + 2:null]?[*:0]const u8 = @splat(null),
    fs_types: [filesystems.all.len + max_stored + 1]u32 = @splat(0),
    fs_other: [model.type_room + 1:0]u8 = @splat(0),
    /// The DosTypes the table keeps code for that the system does not
    /// know, as the partition's chooser shows them.
    fs_stored_text: [max_stored][model.type_room + 1:0]u8 = @splat(@splat(0)),

    // The file systems' page.
    fs_rows: exec.List = .{},
    fs_picked: ?*rdb.RDBFileSystem = null,
    /// What For offers: the file systems the drive takes.
    for_labels: [filesystems.all.len:null]?[*:0]const u8 = @splat(null),
    for_types: [filesystems.all.len]u32 = @splat(0),
    for_active: usize = 0,
    /// The DosTypes whose code was added or taken out since the drive
    /// was read: their drives run what the table says from the next
    /// start.
    touched: [max_stored]u32 = @splat(0),
    touched_count: usize = 0,
    status_text: Line(160) = .{},
    size_text: Line(model.size_room) = .{},

    // Room the stack has none for: the new table's areas, and names.
    after: [max_parts]dos.DosEnvec = undefined,
    names: drives.Names = .{},

    // --- the drive shown ---------------------------------------------------------

    fn unit(app: *const App) ?*const drives.Unit {
        if (app.current >= app.units.count) return null;
        return &app.units.items[app.current];
    }

    /// Whether the handle holds a table to change.
    fn hasTable(app: *const App) bool {
        const handle = app.handle orelse return false;
        return app.made_table or handle.flags & rdb.RDBF_FOUND != 0;
    }

    /// Whether the table may be changed, not only replaced.
    fn editable(app: *const App) bool {
        const handle = app.handle orelse return false;
        if (!app.hasTable()) return false;
        return app.made_table or handle.flags & rdb.RDBF_DAMAGED == 0;
    }

    fn area(app: *const App) Span {
        const handle = app.handle orelse return .{ .low = 0, .high = 0 };
        return .{ .low = handle.rdb.lo_cylinder, .high = handle.rdb.hi_cylinder };
    }

    fn cylinderBytes(app: *const App) u64 {
        const handle = app.handle orelse return 0;
        return @as(u64, handle.rdb.cyl_blocks) * handle.rdb.block_bytes;
    }

    fn barGeometry(app: *const App) model.Bar {
        return .{ .area = app.barArea(), .width = @intCast(@max(app.bar_w, 1)) };
    }

    /// Whether the drive has a sound GPT.
    fn isGpt(app: *const App) bool {
        const handle = app.handle orelse return false;
        return handle.flags & rdb.RDBF_GPT != 0 and handle.flags & rdb.RDBF_GPTDAMAGED == 0;
    }

    /// Whether the table is the one in the GPT's container.
    fn inContainer(app: *const App) bool {
        const handle = app.handle orelse return false;
        return handle.flags & rdb.RDBF_CONTAINER != 0;
    }

    /// Whether a partition of the GPT is the container the table is in.
    fn isWindow(app: *const App, part: *const rdb.GPTPartition) bool {
        const handle = app.handle orelse return false;
        return app.inContainer() and gpt.isContainer(&part.entry) and part.entry.starting_lba == handle.container;
    }

    /// The bar's cylinders: the table's usable ones, or on a GPT every
    /// usable block of the disk, counted from its first block.
    fn barArea(app: *const App) Span {
        const handle = app.handle orelse return .{ .low = 0, .high = 0 };
        if (!app.isGpt()) return app.area();
        const header = &handle.gpt_header;
        return model.blockSpan(header.first_usable_lba, header.last_usable_lba, app.bar_unit);
    }

    /// The container's cylinders on the bar.
    fn containerSpan(app: *const App) Span {
        const handle = app.handle orelse return .{ .low = 0, .high = 0 };
        const blocks = @max(handle.geometry.total_sectors, 1);
        return model.blockSpan(handle.container, handle.container + blocks - 1, app.bar_unit);
    }

    /// A span of the table's cylinders as the bar has it.
    fn toBar(app: *const App, span: Span) Span {
        return .{ .low = span.low +| app.shift, .high = span.high +| app.shift };
    }

    /// The table's spans as the bar has them.
    fn barSpans(app: *App) []const Span {
        for (app.spans[0..app.count], app.bar_spans[0..app.count]) |span, *on_bar| on_bar.* = app.toBar(span);
        return app.bar_spans[0..app.count];
    }

    /// A partition's environment as it lies on the disk: the container's
    /// first cylinder added, for a table in a container.
    fn onDisk(app: *const App, env: *const dos.DosEnvec) dos.DosEnvec {
        const handle = app.handle orelse return env.*;
        if (!app.inContainer()) return env.*;
        return model.onDisk(env, handle.container);
    }

    /// The GPT has no container, and free blocks enough for one.
    fn containerRoom(app: *const App) bool {
        if (!app.isGpt() or app.inContainer()) return false;
        var runs: [max_parts + 1]Span = undefined;
        for (model.gaps(app.barArea(), app.gpt_spans[0..app.gpt_count], &runs)) |gap| {
            // A run of two whole MiB holds one aligned MiB at least.
            if (gap.cylinders() >= 2) return true;
        }
        return false;
    }

    fn blockBytes(app: *const App) u32 {
        const handle = app.handle orelse return 512;
        return handle.geometry.sector_size;
    }

    /// The drive mounted with SYS: on it, of the drive shown.
    fn systemDrive(app: *const App) ?*const drives.Mounted {
        for (app.mounted[0..app.mounted_count]) |*mounted| {
            if (mounted.system) return mounted;
        }
        return null;
    }

    /// Whether a partition is the one SYS: is on: laid out, as read, as
    /// the system's drive is.
    fn isSystem(app: *const App, part: *const rdb.RDBPartition) bool {
        const system = app.systemDrive() orelse return false;
        for (app.before[0..app.before_count]) |*before| {
            const held = before.part orelse continue;
            if (held == part) return model.sameLayout(&before.env, &system.env);
        }
        return false;
    }

    /// The drive a partition is mounted as now: one laid out as it is.
    fn mountedAs(app: *const App, part: *const rdb.RDBPartition) ?*const drives.Mounted {
        const env = app.onDisk(&part.block.environment);
        for (app.mounted[0..app.mounted_count]) |*mounted| {
            if (model.sameLayout(&mounted.env, &env)) return mounted;
        }
        return null;
    }

    /// The drive a partition of the GPT is mounted as now: one over its
    /// blocks.
    fn gptMountedAs(app: *const App, part: *const rdb.GPTPartition) ?*const drives.Mounted {
        for (app.mounted[0..app.mounted_count]) |*mounted| {
            if (model.covers(&mounted.env, part.entry.starting_lba, part.entry.ending_lba, app.blockBytes())) return mounted;
        }
        return null;
    }

    /// Whether SYS: is on a partition of the GPT.
    fn gptIsSystem(app: *const App, part: *const rdb.GPTPartition) bool {
        const mounted = app.gptMountedAs(part) orelse return false;
        return mounted.system;
    }

    /// Whether a drive over `env` goes on reading its blocks: a partition
    /// of the GPT still has them.
    fn keptByGpt(app: *const App, env: *const dos.DosEnvec) bool {
        for (app.gpt_parts[0..app.gpt_count]) |part| {
            if (model.covers(env, part.entry.starting_lba, part.entry.ending_lba, app.blockBytes())) return true;
        }
        return false;
    }

    fn pickedPart(app: *const App) ?*rdb.RDBPartition {
        return switch (app.picked) {
            .part => |part| part,
            else => null,
        };
    }

    fn pickedGpt(app: *const App) ?*rdb.GPTPartition {
        return switch (app.picked) {
            .gpt => |part| part,
            else => null,
        };
    }

    /// The partition a list row stands for, the table's or the GPT's.
    fn pickOf(app: *const App, user_data: usize) ?Picked {
        for (app.parts[0..app.count]) |part| {
            if (@intFromPtr(part) == user_data) return .{ .part = part };
        }
        for (app.gpt_parts[0..app.gpt_count]) |part| {
            if (@intFromPtr(part) == user_data) return .{ .gpt = part };
        }
        return null;
    }

    /// The handle's partitions gathered in the order of their cylinders.
    fn gather(app: *App) void {
        app.count = 0;
        const handle = app.handle orelse return;
        var unsorted: [max_parts]*rdb.RDBPartition = undefined;
        var spans: [max_parts]Span = undefined;
        var total: usize = 0;
        var walk = app.rb.NextPartition(handle, null);
        while (walk) |part| : (walk = app.rb.NextPartition(handle, part)) {
            if (total == max_parts) break;
            unsorted[total] = part;
            spans[total] = Span.of(&part.block.environment);
            total += 1;
        }
        var order: [max_parts]u32 = undefined;
        model.order(spans[0..total], &order);
        for (order[0..total], 0..) |from, index| {
            app.parts[index] = unsorted[from];
            app.spans[index] = spans[from];
        }
        app.count = total;

        // The bar's cylinders: the table's, or whole MiB on a GPT with no
        // table; a container's first block is on one of them.
        app.bar_unit = if (app.hasTable()) @max(handle.rdb.cyl_blocks, 1) else gpt.alignmentBlocks(handle.geometry.sector_size);
        app.shift = if (app.inContainer()) @intCast(@min(handle.container / app.bar_unit, 0xFFFF_FFFF)) else 0;
        app.gpt_count = 0;
        if (!app.isGpt()) return;
        var gpt_unsorted: [max_parts]*rdb.GPTPartition = undefined;
        total = 0;
        var walk_gpt = app.rb.NextGPTPartition(handle, null);
        while (walk_gpt) |part| : (walk_gpt = app.rb.NextGPTPartition(handle, part)) {
            if (total == max_parts) break;
            if (app.isWindow(part)) continue;
            gpt_unsorted[total] = part;
            spans[total] = model.blockSpan(part.entry.starting_lba, part.entry.ending_lba, app.bar_unit);
            total += 1;
        }
        model.order(spans[0..total], &order);
        for (order[0..total], 0..) |from, index| {
            app.gpt_parts[index] = gpt_unsorted[from];
            app.gpt_spans[index] = spans[from];
        }
        app.gpt_count = total;
    }

    fn indexOf(app: *const App, part: *const rdb.RDBPartition) ?usize {
        for (app.parts[0..app.count], 0..) |other, index| {
            if (other == part) return index;
        }
        return null;
    }

    /// The drive picked in the chooser read, its table and what is
    /// mounted from it.
    fn openDrive(app: *App, index: usize) void {
        app.closeDrive();
        app.current = index;
        app.picked = .none;
        const shown = app.unit() orelse {
            app.problem = rdb.RDBERR_DEVICE;
            app.refresh();
            return;
        };
        app.mounted_count = drives.mountedOn(app.dl, shown.device, shown.number, app.system, &app.mounted).len;
        var err: i32 = rdb.RDBERR_OK;
        app.handle = app.rb.OpenRDB(shown.device, shown.number, &err);
        app.problem = err;
        if (app.handle) |handle| {
            const gpt_flags = rdb.RDBF_GPT | rdb.RDBF_GPTCHANGED | rdb.RDBF_GPTDAMAGED;
            app.gpt_repair = handle.flags & gpt_flags == rdb.RDBF_GPT | rdb.RDBF_GPTCHANGED;
            app.grid = model.Grid.of(app.cylinderBytes(), handle.geometry.erase_size);
            app.gather();
            if (handle.flags & rdb.RDBF_FOUND != 0) {
                for (app.parts[0..app.count]) |part| {
                    // Where it lies on the disk, which a container that
                    // goes with a new table does not move.
                    const before = &app.before[app.before_count];
                    before.* = .{ .part = part, .env = app.onDisk(&part.block.environment), .name = @splat(0) };
                    const name = part.block.name();
                    @memcpy(before.name[0..name.len], name);
                    app.before_count += 1;
                }
            }
            for (app.gpt_parts[0..app.gpt_count]) |part| {
                const before = &app.gpt_before[app.gpt_before_count];
                before.* = .{ .part = part, .name = @splat(0) };
                _ = gptLabel(part, &before.name);
                app.gpt_before_count += 1;
            }
            if (app.count != 0) {
                app.picked = .{ .part = app.parts[0] };
            } else if (app.gpt_count != 0) {
                app.picked = .{ .gpt = app.gpt_parts[0] };
            }
        }
        app.refresh();
    }

    fn closeDrive(app: *App) void {
        if (app.handle) |handle| app.rb.CloseRDB(handle);
        app.handle = null;
        app.made_table = false;
        app.changed = false;
        app.restart_wanted = false;
        app.touched_count = 0;
        app.fs_picked = null;
        app.before_count = 0;
        app.mounted_count = 0;
        app.count = 0;
        app.gpt_count = 0;
        app.gpt_before_count = 0;
        app.gpt_repair = false;
        app.shift = 0;
        app.picked = .none;
        app.problem = rdb.RDBERR_OK;
    }

    /// The medium's change count, asked of the device; null when it
    /// cannot say.
    fn mediumCount(app: *App) ?u32 {
        const shown = app.unit() orelse return null;
        const sys = app.sys;
        const port = sys.CreateMsgPort() orelse return null;
        defer sys.DeleteMsgPort(port);
        var io: exec.IOStdReq = .{ .req = .{ .message = .{ .reply_port = port, .length = @sizeOf(exec.IOStdReq) } } };
        if (sys.OpenDevice(shown.device, shown.number, &io.req, 0) != 0) return null;
        defer sys.CloseDevice(&io.req);
        io.req.command = td.TD_CHANGENUM;
        if (sys.DoIO(&io.req) != 0) return null;
        return @truncate(io.actual);
    }

    /// A medium came or went somewhere: the drive shown read again when
    /// it was its own.
    fn mediumChanged(app: *App) void {
        if (app.handle) |handle| {
            if (handle.geometry.flags & td.DGF_REMOVABLE == 0) return;
            const now = app.mediumCount() orelse return;
            if (now == handle.change_num) return;
            if (app.changed and !app.ask("The medium in the drive has changed.\nRead it again? The changes not saved are lost.", "Read it|Keep them")) return;
        }
        app.openDrive(app.current);
    }

    // --- what is shown -------------------------------------------------------------

    /// Everything shown made to fit the drive and the pick.
    fn refresh(app: *App) void {
        app.gather();
        app.showRows();
        app.showFields();
        app.showFileSystems();
        app.showButtons();
        app.showStatus();
        app.drawBar();
    }

    /// The gadget set: drawn at once when it is in sight, or kept to be
    /// drawn when its page is shown - a gadget of a page out of sight
    /// would draw over the page in sight.
    fn set(app: *App, page: ?usize, object: *Object, tags: []const TagItem) void {
        const window = app.window orelse {
            _ = app.ib.SetAttrsTagList(object, tags.ptr);
            return;
        };
        if (page) |wanted| {
            var shown: usize = 0;
            _ = app.ib.GetAttr(ct.CLICKTAB_Current, app.tabs, &shown);
            if (shown != wanted) {
                _ = app.ib.SetAttrsTagList(object, tags.ptr);
                return;
            }
        }
        _ = app.ib.SetGadgetAttrsTagList(object, window, tags.ptr);
    }

    fn enable(app: *App, page: ?usize, object: *Object, on: bool) void {
        app.set(page, object, &.{ .{ .tag = gc.GA_Disabled, .data = @intFromBool(!on) }, .{} });
    }

    /// A line on the status line until the next is.
    fn say(app: *App, text: []const u8) void {
        app.status_text.clear();
        app.status_text.add(text);
        app.set(null, app.status, &.{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(app.status_text.ptr()) }, .{} });
    }

    /// What the drive holds, on the status line.
    fn showStatus(app: *App) void {
        var line: Line(160) = .{};
        if (app.units.count == 0) {
            line.add("No block device to partition");
        } else if (app.handle == null) {
            line.add(switch (app.problem) {
                rdb.RDBERR_DEVICE => "No medium in the drive, or the device is not there",
                rdb.RDBERR_IO => "The drive cannot be read",
                rdb.RDBERR_NOMEM => "No memory to read the drive",
                else => "The drive cannot be used",
            });
        } else if (!app.hasTable()) {
            const handle = app.handle.?;
            if (handle.flags & rdb.RDBF_GPTDAMAGED != 0) {
                line.add("The GPT is damaged: New table replaces it");
            } else if (app.inContainer()) {
                line.add("The PowerOS container has no table: New or Whole disk makes one");
            } else if (app.isGpt()) {
                line.add("A GPT with ");
                line.number(app.gpt_count);
                line.add(if (app.gpt_count == 1) " partition" else " partitions");
                line.add(if (app.containerRoom()) " and no PowerOS container: New makes one" else ", and no room for a PowerOS container");
                if (app.changed) line.add(", not saved");
            } else if (handle.flags & rdb.RDBF_FOREIGN != 0) {
                line.add("The table is for another block size: New table replaces it");
            } else if (app.wholeDrive()) |whole| {
                line.add("No partitions: ");
                line.add(whole.nameText());
                line.add(": is the whole medium");
                if (filesystems.of(whole.env.dos_type)) |file_system| {
                    line.add(" (");
                    line.addText(file_system.name);
                    line.add(")");
                }
            } else {
                line.add("No partitions: New table or Whole disk makes them");
            }
        } else if (!app.editable()) {
            line.add("The table is damaged: New table replaces it");
        } else {
            line.number(app.count);
            line.add(if (app.count == 1) " partition, " else " partitions, ");
            var runs: [max_parts + 1]Span = undefined;
            var free: u64 = 0;
            for (model.gaps(app.area(), app.spans[0..app.count], &runs)) |gap| free += gap.cylinders();
            var size: [model.size_room]u8 = undefined;
            line.add(model.sizeText(free * app.cylinderBytes(), &size));
            line.add(" free");
            if (app.inContainer()) line.add(" in the PowerOS container");
            if (app.gpt_count != 0) {
                line.add(", ");
                line.number(app.gpt_count);
                line.add(" more on the GPT");
            }
            if (app.changed) line.add(", not saved");
            if (app.restart_wanted) line.add("; a restart puts the table in force");
        }
        if (app.gpt_repair and !app.changed) line.add("; the GPT's first copy is damaged, and Save mends it");
        app.status_text = line;
        app.set(null, app.status, &.{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(app.status_text.ptr()) }, .{} });
    }

    /// The drive over the whole medium mounted from the drive shown.
    fn wholeDrive(app: *const App) ?*const drives.Mounted {
        for (app.mounted[0..app.mounted_count]) |*mounted| {
            if (mounted.env.wholeMedium()) return mounted;
        }
        return null;
    }

    /// The list made anew from the partitions, the picked one selected.
    fn showRows(app: *App) void {
        app.set(null, app.list, &.{ .{ .tag = lb.LISTBROWSER_Rows, .data = lb.LISTBROWSER_DETACH }, .{} });
        lb.freeRows(app.sys, &app.rows);
        var selected: u32 = lb.LISTBROWSER_NONE;
        for (app.parts[0..app.count], 0..) |part, index| {
            const env = &part.block.environment;
            var name: Line(dos.MAX_DEVICE_NAME + 1) = .{};
            name.add(part.block.name());
            var cylinders: Line(24) = .{};
            cylinders.number(env.low_cyl);
            cylinders.add("-");
            cylinders.number(env.high_cyl);
            var size: [model.size_room + 1]u8 = @splat(0);
            const size_text = model.sizeText(Span.of(env).cylinders() * app.cylinderBytes(), size[0..model.size_room]);
            size[size_text.len] = 0;
            var type_text: [model.type_room + 1]u8 = @splat(0);
            const file_system: [*:0]const u8 = if (filesystems.of(env.dos_type)) |known| known.name else blk: {
                _ = model.typeText(env.dos_type, type_text[0..model.type_room]);
                break :blk @ptrCast(&type_text);
            };
            var mounted: Line(dos.MAX_DEVICE_NAME + 1) = .{};
            if (app.mountedAs(part)) |drive| {
                mounted.add(drive.nameText());
                mounted.add(":");
            }
            const texts = [_][*:0]const u8{ name.ptr(), cylinders.ptr(), @ptrCast(&size), file_system, mounted.ptr() };
            const list_row = lb.allocRow(app.sys, &texts, 0) orelse break;
            list_row.user_data = @intFromPtr(part);
            app.sys.AddTail(&app.rows, &list_row.node);
            if (app.pickedPart() == part) selected = @intCast(index);
        }
        // The GPT's partitions after the table's: no cylinders, and their
        // type for a file system.
        for (app.gpt_parts[0..app.gpt_count], 0..) |part, index| {
            var name: [gpt.name_units:0]u8 = @splat(0);
            _ = gptLabel(part, &name);
            var size: [model.size_room + 1]u8 = @splat(0);
            const size_text = model.sizeText(gptBytes(part, app.blockBytes()), size[0..model.size_room]);
            size[size_text.len] = 0;
            var guid: [gpt.guid_text_len:0]u8 = @splat(0);
            const kind: [*:0]const u8 = gpt.typeName(&part.entry.partition_type_guid) orelse blk: {
                gpt.formatGuid(&part.entry.partition_type_guid, &guid);
                break :blk &guid;
            };
            var mounted: Line(dos.MAX_DEVICE_NAME + 1) = .{};
            if (app.gptMountedAs(part)) |drive| {
                mounted.add(drive.nameText());
                mounted.add(":");
            }
            const texts = [_][*:0]const u8{ &name, "-", @ptrCast(&size), kind, mounted.ptr() };
            const list_row = lb.allocRow(app.sys, &texts, 0) orelse break;
            list_row.user_data = @intFromPtr(part);
            app.sys.AddTail(&app.rows, &list_row.node);
            if (app.pickedGpt() == part) selected = @intCast(app.count + index);
        }
        app.set(null, app.list, &.{
            .{ .tag = lb.LISTBROWSER_Rows, .data = @intFromPtr(&app.rows) },
            .{ .tag = lb.LISTBROWSER_Selected, .data = selected },
            .{},
        });
    }

    /// The fields made to show the partition picked.
    fn showFields(app: *App) void {
        const part = app.pickedPart();
        const may = part != null and app.editable();
        const fixed = if (part) |picked| app.isSystem(picked) else false;
        const rom = if (app.unit()) |shown| shown.rom else false;

        const empty: [1:0]u8 = @splat(0);
        var gpt_name: [gpt.name_units:0]u8 = @splat(0);
        var start: Line(12) = .{};
        var end: Line(12) = .{};
        app.size_text.clear();
        var name_text: [*:0]const u8 = &empty;
        var bootable = false;
        var automount = false;
        var buffers: i32 = 0;
        var transfer: i32 = 0;
        var boot_pri: i32 = 0;
        if (part) |picked| {
            const env = &picked.block.environment;
            name_text = @ptrCast(&picked.block.drive_name);
            start.number(env.low_cyl);
            end.number(env.high_cyl);
            var size: [model.size_room]u8 = undefined;
            app.size_text.add(model.sizeText(Span.of(env).cylinders() * app.cylinderBytes(), &size));
            bootable = picked.block.flags & hardblocks.PBFF_BOOTABLE != 0;
            automount = picked.block.flags & hardblocks.PBFF_NOMOUNT == 0;
            buffers = @intCast(@min(env.num_buffers, 0x7FFF_FFFF));
            transfer = @intCast(@min(env.max_transfer, 0x7FFF_FFFF));
            boot_pri = env.boot_pri;
        } else if (app.pickedGpt()) |picked| {
            // Only shown: a partition of the GPT is not changed here.
            _ = gptLabel(picked, &gpt_name);
            name_text = &gpt_name;
            var size: [model.size_room]u8 = undefined;
            app.size_text.add(model.sizeText(gptBytes(picked, app.blockBytes()), &size));
        }
        var active = app.fileSystems(part);
        if (app.pickedGpt()) |picked| {
            // What the partition is for, in place of a file system.
            var count: usize = 0;
            while (app.fs_labels[count] != null) count += 1;
            app.gpt_kind = @splat(0);
            if (gpt.typeName(&picked.entry.partition_type_guid)) |kind| {
                var length: usize = 0;
                while (kind[length] != 0 and length < app.gpt_kind.len) : (length += 1) app.gpt_kind[length] = kind[length];
            } else {
                gpt.formatGuid(&picked.entry.partition_type_guid, &app.gpt_kind);
            }
            app.fs_labels[count] = &app.gpt_kind;
            app.fs_labels[count + 1] = null;
            active = count;
        }

        app.set(page_partition, app.name, &.{
            .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(name_text) },
            .{ .tag = gc.GA_Disabled, .data = @intFromBool(!may) },
            .{},
        });
        app.set(page_partition, app.file_system, &.{
            .{ .tag = ch.CHOOSER_Labels, .data = @intFromPtr(&app.fs_labels) },
            .{ .tag = ch.CHOOSER_Active, .data = active },
            .{ .tag = gc.GA_Disabled, .data = @intFromBool(!may or fixed) },
            .{},
        });
        app.set(page_partition, app.start, &.{
            .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(start.ptr()) },
            .{ .tag = gc.GA_Disabled, .data = @intFromBool(!may or fixed) },
            .{},
        });
        app.set(page_partition, app.end, &.{
            .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(end.ptr()) },
            .{ .tag = gc.GA_Disabled, .data = @intFromBool(!may or fixed) },
            .{},
        });
        app.set(page_partition, app.size, &.{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(app.size_text.ptr()) }, .{} });
        app.set(page_partition, app.bootable, &.{
            .{ .tag = cb.CHECKBOX_Checked, .data = @intFromBool(bootable) },
            .{ .tag = gc.GA_Disabled, .data = @intFromBool(!may or !rom) },
            .{},
        });
        app.set(page_advanced, app.buffers, &.{
            .{ .tag = ig.INTEGER_Number, .data = @bitCast(@as(isize, buffers)) },
            .{ .tag = gc.GA_Disabled, .data = @intFromBool(!may) },
            .{},
        });
        app.set(page_advanced, app.transfer, &.{
            .{ .tag = ig.INTEGER_Number, .data = @bitCast(@as(isize, transfer)) },
            .{ .tag = gc.GA_Disabled, .data = @intFromBool(!may) },
            .{},
        });
        app.set(page_advanced, app.boot_pri, &.{
            .{ .tag = ig.INTEGER_Number, .data = @bitCast(@as(isize, boot_pri)) },
            .{ .tag = gc.GA_Disabled, .data = @intFromBool(!may) },
            .{},
        });
        app.set(page_advanced, app.automount, &.{
            .{ .tag = cb.CHECKBOX_Checked, .data = @intFromBool(automount) },
            .{ .tag = gc.GA_Disabled, .data = @intFromBool(!may) },
            .{},
        });
    }

    /// The file systems the drive takes, as the chooser's labels, with
    /// the partition's own as one more where it is none of them; which
    /// of them is the partition's.
    fn fileSystems(app: *App, part: ?*const rdb.RDBPartition) usize {
        const erase_size = if (app.handle) |handle| handle.geometry.erase_size else 0;
        const own: u32 = if (part) |picked| picked.block.environment.dos_type else 0;
        const own_system = filesystems.of(own);
        var count: usize = 0;
        var active: ?usize = null;
        for (&filesystems.all) |*file_system| {
            const is_own = if (own_system) |known| known == file_system else false;
            if (!is_own and !filesystems.suits(file_system.dos_type, erase_size, false)) continue;
            if (is_own) active = count;
            app.fs_labels[count] = file_system.name;
            app.fs_types[count] = file_system.dos_type;
            count += 1;
        }
        // A DosType the system does not know, which the table brings the
        // code for.
        if (app.handle) |handle| {
            var stored = app.rb.NextFileSystem(handle, null);
            var index: usize = 0;
            while (stored) |file_system| : (stored = app.rb.NextFileSystem(handle, file_system)) {
                const dos_type = file_system.header.dos_type;
                if (filesystems.of(dos_type) != null or index == max_stored) continue;
                if (dos_type == own) active = count;
                const text = model.typeText(dos_type, app.fs_stored_text[index][0..model.type_room]);
                app.fs_stored_text[index][text.len] = 0;
                app.fs_labels[count] = @ptrCast(&app.fs_stored_text[index]);
                app.fs_types[count] = dos_type;
                count += 1;
                index += 1;
            }
        }
        if (active == null and part != null) {
            const text = model.typeText(own, app.fs_other[0..model.type_room]);
            app.fs_other[text.len] = 0;
            app.fs_labels[count] = @ptrCast(&app.fs_other);
            app.fs_types[count] = own;
            active = count;
            count += 1;
        }
        app.fs_labels[count] = null;
        return active orelse 0;
    }

    /// The buttons that may be pressed now.
    fn showButtons(app: *App) void {
        const may_edit = app.editable();
        const part = app.pickedPart();
        const system_here = app.systemDrive() != null;
        var runs: [1]Span = undefined;
        // A GPT with no table: New makes the container and the table.
        const needs_table = app.inContainer() or app.containerRoom();
        const room = if (may_edit)
            model.gaps(app.area(), app.spans[0..app.count], &runs).len != 0
        else
            !app.hasTable() and needs_table;
        app.enable(null, app.new, room);
        const may_delete = if (app.pickedGpt()) |picked|
            !app.gptIsSystem(picked)
        else
            may_edit and part != null and app.count > 1 and !app.isSystem(part.?);
        app.enable(null, app.delete, may_delete);
        const may_whole = !app.isGpt() or app.hasTable() or needs_table;
        app.enable(null, app.whole, app.handle != null and !system_here and may_whole);
        app.enable(null, app.new_table, app.handle != null and !system_here);
        app.enable(null, app.save, app.handle != null and (app.changed or app.gpt_repair));
        app.enable(page_files, app.fs_add, may_edit and app.for_labels[0] != null);
        app.enable(page_files, app.fs_remove, may_edit and app.fs_picked != null);
    }

    /// The file systems' page made anew from the table's: the list, the
    /// one picked still picked, and what For offers.
    fn showFileSystems(app: *App) void {
        app.set(page_files, app.fs_list, &.{ .{ .tag = lb.LISTBROWSER_Rows, .data = lb.LISTBROWSER_DETACH }, .{} });
        lb.freeRows(app.sys, &app.fs_rows);
        var selected: u32 = lb.LISTBROWSER_NONE;
        var still_there = false;
        var index: u32 = 0;
        if (app.handle) |handle| {
            var stored = if (app.hasTable()) app.rb.NextFileSystem(handle, null) else null;
            while (stored) |file_system| : (stored = app.rb.NextFileSystem(handle, file_system)) {
                const header = &file_system.header;
                var type_text: [model.type_room + 1]u8 = @splat(0);
                const name: [*:0]const u8 = if (filesystems.of(header.dos_type)) |known| known.name else blk: {
                    _ = model.typeText(header.dos_type, type_text[0..model.type_room]);
                    break :blk @ptrCast(&type_text);
                };
                var version: Line(16) = .{};
                version.number(header.version >> 16);
                version.add(".");
                version.number(header.version & 0xFFFF);
                var size: [model.size_room + 1]u8 = @splat(0);
                const size_text = model.sizeText(file_system.size, size[0..model.size_room]);
                size[size_text.len] = 0;
                // The code a partition of the DosType runs: this, or the
                // ROM's handler when that is as new.
                var runs: Line(24) = .{};
                const rom = filesystems.romVersion(app.sys, header.dos_type);
                if (filesystems.storedWins(header.version, rom)) {
                    runs.add("this");
                } else {
                    runs.add("ROM's ");
                    runs.number(rom.? >> 16);
                    runs.add(".");
                    runs.number(rom.? & 0xFFFF);
                }
                const texts = [_][*:0]const u8{ name, version.ptr(), @ptrCast(&size), runs.ptr() };
                const list_row = lb.allocRow(app.sys, &texts, 0) orelse break;
                list_row.user_data = @intFromPtr(file_system);
                app.sys.AddTail(&app.fs_rows, &list_row.node);
                if (app.fs_picked == file_system) {
                    selected = index;
                    still_there = true;
                }
                index += 1;
            }
        }
        if (!still_there) app.fs_picked = null;
        app.set(page_files, app.fs_list, &.{
            .{ .tag = lb.LISTBROWSER_Rows, .data = @intFromPtr(&app.fs_rows) },
            .{ .tag = lb.LISTBROWSER_Selected, .data = selected },
            .{},
        });

        // For: the file systems the drive takes.
        const erase_size = if (app.handle) |handle| handle.geometry.erase_size else 0;
        var count: usize = 0;
        for (&filesystems.all) |*file_system| {
            if (!filesystems.suits(file_system.dos_type, erase_size, false)) continue;
            app.for_labels[count] = file_system.name;
            app.for_types[count] = file_system.dos_type;
            count += 1;
        }
        app.for_labels[count] = null;
        if (app.for_active >= count) app.for_active = 0;
        app.set(page_files, app.fs_for, &.{
            .{ .tag = ch.CHOOSER_Labels, .data = @intFromPtr(&app.for_labels) },
            .{ .tag = ch.CHOOSER_Active, .data = app.for_active },
            .{ .tag = gc.GA_Disabled, .data = @intFromBool(!app.editable() or count == 0) },
            .{},
        });
    }

    // --- the bar --------------------------------------------------------------------

    fn rpAttr(app: *App, attr: utility.Tag) i32 {
        var value: u32 = 0;
        app.gb.GetRPAttrs(app.rp, &[_]TagItem{ .{ .tag = attr, .data = @intFromPtr(&value) }, .{} });
        return @intCast(value);
    }

    /// The screen's font on the bar and the pens from the screen's.
    fn takeLook(app: *App) void {
        if (app.draw_info.font) |font| graphics.SetFont(app.gb, app.rp, font);
        app.font_h = @max(app.rpAttr(graphics.RPTAG_FontHeight), 8);
        app.baseline = app.rpAttr(graphics.RPTAG_FontBaseline);
        const pens = app.draw_info.pens;
        const paper = pens[sc.BACKGROUNDPEN];
        const ink = pens[sc.TEXTPEN];
        app.pens = .{
            .paper = paper,
            .ink = ink,
            .free = mix(paper, ink, 1),
            .part = mix(paper, pens[sc.FILLPEN], 3),
            .picked = pens[sc.FILLPEN],
            .picked_ink = pens[sc.FILLTEXTPEN],
            .edge = pens[sc.SHADOWPEN],
            .system = mix(paper, pens[sc.SHADOWPEN], 2),
            .foreign = mix(paper, ink, 3),
        };
    }

    /// The picture made as big as the bar's box now.
    fn fitBar(app: *App) void {
        _ = app.ib.SetGadgetAttrsTagList(app.bar, app.window, &[_]TagItem{
            .{ .tag = cv.CANVAS_Width, .data = 0 },
            .{ .tag = cv.CANVAS_Height, .data = 0 },
            .{},
        });
        var value: usize = 0;
        _ = app.ib.GetAttr(cv.CANVAS_RastPort, app.bar, &value);
        app.rp = @ptrFromInt(value);
        _ = app.ib.GetAttr(cv.CANVAS_Width, app.bar, &value);
        app.bar_w = @intCast(value);
        _ = app.ib.GetAttr(cv.CANVAS_Height, app.bar, &value);
        app.bar_h = @intCast(value);
        app.takeLook();
    }

    fn setPen(app: *App, pen: graphics.Pen) void {
        app.gb.SetRPAttrs(app.rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = pen }, .{} });
    }

    fn fill(app: *App, left: i32, top: i32, right: i32, bottom: i32, pen: graphics.Pen) void {
        if (right <= left or bottom <= top) return;
        app.setPen(pen);
        app.gb.RectFill(app.rp, &.{ .min_x = left, .min_y = top, .max_x = right, .max_y = bottom });
    }

    fn textWidth(app: *App, text: []const u8) i32 {
        if (text.len == 0) return 0;
        return app.gb.TextLength(app.rp, text.ptr, @intCast(text.len));
    }

    /// `text` in the middle of `left` to `right`, when it fits.
    fn label(app: *App, text: []const u8, left: i32, right: i32, pen: graphics.Pen) void {
        const width = app.textWidth(text);
        if (width + 4 > right - left or app.font_h > app.bar_h) return;
        app.setPen(pen);
        app.gb.Move(app.rp, left + @divTrunc(right - left - width, 2), @divTrunc(app.bar_h - app.font_h, 2) + app.baseline);
        app.gb.Text(app.rp, text.ptr, @intCast(text.len));
    }

    /// The bar drawn: the free cylinders, each partition over its own,
    /// its name on it where there is room, and the pick marked.
    fn drawBar(app: *App) void {
        const width = app.bar_w;
        const height = app.bar_h;
        if (width <= 0 or height <= 0) return;
        if (!app.hasTable() and !app.isGpt()) {
            app.fill(0, 0, width, height, app.pens.free);
            app.ib.QueueGadgetRefresh(app.bar);
            return;
        }
        const bar = app.barGeometry();
        if (app.isGpt()) {
            // The disk's blocks no partition has, framed; the container's
            // free cylinders as free.
            app.fill(0, 0, width, height, app.pens.paper);
            app.outline(0, width, app.pens.edge, 1);
            if (app.inContainer()) {
                const drawn = bar.pixels(app.containerSpan());
                app.fill(@intCast(drawn.left), 0, @intCast(drawn.right), height, app.pens.free);
            }
            for (app.gpt_spans[0..app.gpt_count], app.gpt_parts[0..app.gpt_count]) |span, part| {
                const drawn = bar.pixels(span);
                const left: i32 = @intCast(drawn.left);
                const right: i32 = @intCast(drawn.right);
                const picked = app.pickedGpt() == part;
                app.fill(left, 0, right, height, if (picked) app.pens.picked else app.pens.foreign);
                app.fill(left, 0, left + 1, height, app.pens.edge);
                app.fill(right - 1, 0, right, height, app.pens.edge);
                var name: [gpt.name_units:0]u8 = @splat(0);
                app.label(gptLabel(part, &name), left, right, if (picked) app.pens.picked_ink else app.pens.ink);
            }
        } else {
            app.fill(0, 0, width, height, app.pens.free);
        }
        for (app.barSpans(), app.parts[0..app.count]) |span, part| {
            const drawn = bar.pixels(span);
            const left: i32 = @intCast(drawn.left);
            const right: i32 = @intCast(drawn.right);
            const picked = app.pickedPart() == part;
            const ground = if (picked) app.pens.picked else if (app.isSystem(part)) app.pens.system else app.pens.part;
            app.fill(left, 0, right, height, ground);
            app.fill(left, 0, left + 1, height, app.pens.edge);
            app.fill(right - 1, 0, right, height, app.pens.edge);
            app.label(part.block.name(), left, right, if (picked) app.pens.picked_ink else app.pens.ink);
        }
        switch (app.picked) {
            .gap => |gap| {
                const drawn = bar.pixels(app.toBar(gap));
                app.outline(@intCast(drawn.left), @intCast(drawn.right), app.pens.picked, 2);
            },
            else => {},
        }
        app.ib.QueueGadgetRefresh(app.bar);
    }

    /// A frame `thickness` pixels wide round the bar from `left` to
    /// `right`.
    fn outline(app: *App, left: i32, right: i32, pen: graphics.Pen, thickness: i32) void {
        const height = app.bar_h;
        app.fill(left, 0, right, thickness, pen);
        app.fill(left, height - thickness, right, height, pen);
        app.fill(left, 0, left + thickness, height, pen);
        app.fill(right - thickness, 0, right, height, pen);
    }

    fn pointer(app: *App) i32 {
        var x: usize = 0;
        _ = app.ib.GetAttr(cv.CANVAS_X, app.bar, &x);
        return @truncate(@as(isize, @bitCast(x)));
    }

    /// A press on the bar: a partition or a free run picked, and a
    /// partition taken hold of where it may be changed.
    fn press(app: *App) void {
        app.drag = .none;
        if (!app.hasTable() and !app.isGpt()) return;
        const x = app.pointer();
        const bar = app.barGeometry();
        // A partition of the GPT's is only picked.
        if (model.under(bar, app.gpt_spans[0..app.gpt_count], x)) |index| {
            app.picked = .{ .gpt = app.gpt_parts[index] };
            return app.showPick();
        }
        if (!app.hasTable()) return;
        switch (model.hit(bar, app.barSpans(), x, grip_pixels)) {
            .none => return,
            .gap => |gap| {
                // Only a run of the table's own cylinders.
                const table = app.toBar(app.area());
                const at = bar.cylinderAt(x);
                if (at < table.low or at > table.high) return;
                const low = @max(gap.low, table.low) - app.shift;
                const high = @min(gap.high, table.high) - app.shift;
                app.picked = .{ .gap = .{ .low = low, .high = high } };
            },
            .part => |held| {
                const part = app.parts[held.index];
                app.picked = .{ .part = part };
                if (app.editable() and !app.isSystem(part)) {
                    app.drag = switch (held.grip) {
                        .low => .low,
                        .middle => .move,
                        .high => .high,
                    };
                    app.drag_from = x;
                    app.drag_span = app.spans[held.index];
                    app.drag_room = model.room(app.area(), app.spans[0..app.count], held.index);
                }
            },
        }
        app.showPick();
    }

    /// The pick shown everywhere.
    fn showPick(app: *App) void {
        app.showRows();
        app.showFields();
        app.showButtons();
        app.drawBar();
    }

    /// The partition held moved or resized to where the pointer is.
    fn dragTo(app: *App) void {
        const part = app.pickedPart() orelse return;
        const bar = app.barGeometry();
        const x = app.pointer();
        const span = switch (app.drag) {
            .none => return,
            .move => blk: {
                const by = @as(i64, @intCast(bar.boundaryAt(x))) - @as(i64, @intCast(bar.boundaryAt(app.drag_from)));
                break :blk model.moved(app.drag_room, app.drag_span, @as(i64, app.drag_span.low) + by, app.grid);
            },
            .low => model.resized(app.drag_room, app.drag_span, .low, bar.boundaryAt(x) -| app.shift, app.grid),
            .high => model.resized(app.drag_room, app.drag_span, .high, bar.boundaryAt(x) -| app.shift, app.grid),
        };
        app.place(part, span);
    }

    /// A partition given cylinders: shown on the bar and in the fields.
    fn place(app: *App, part: *rdb.RDBPartition, span: Span) void {
        const env = &part.block.environment;
        if (env.low_cyl == span.low and env.high_cyl == span.high) return;
        env.low_cyl = span.low;
        env.high_cyl = span.high;
        app.changed = true;
        app.gather();
        app.showFields();
        app.showButtons();
        app.drawBar();
    }

    /// The press let go: the list and the line follow.
    fn release(app: *App) void {
        if (app.drag == .none) return;
        app.dragTo();
        app.drag = .none;
        app.showRows();
        app.showStatus();
    }

    // --- the fields -------------------------------------------------------------------

    fn textOf(app: *App, object: *Object) []const u8 {
        var value: usize = 0;
        _ = app.ib.GetAttr(gc.STRINGA_TextVal, object, &value);
        if (value == 0) return "";
        const text: [*:0]const u8 = @ptrFromInt(value);
        var length: usize = 0;
        while (text[length] != 0) length += 1;
        return text[0..length];
    }

    /// The name typed taken, when it may name the partition.
    fn takeName(app: *App) void {
        const part = app.pickedPart() orelse return;
        const typed = app.textOf(app.name);
        const others = &app.names;
        others.* = .{};
        for (app.parts[0..app.count]) |other| {
            if (other != part) others.add(@ptrCast(&other.block.drive_name));
        }
        const problem = model.nameProblem(typed, others.all());
        if (problem != .none) {
            app.say(switch (problem) {
                .empty => "A partition needs a name",
                .long => "A name is 30 characters at most",
                .separator => "A name holds no colon and no slash",
                .taken => "Another partition has that name",
                .none => unreachable,
            });
            app.showFields();
            return;
        }
        if (equalBytes(typed, part.block.name())) return;
        part.block.drive_name = @splat(0);
        @memcpy(part.block.drive_name[0..typed.len], typed);
        app.changed = true;
        app.showRows();
        app.showStatus();
        app.drawBar();
    }

    /// A first or last cylinder typed taken, as far as the neighbours let
    /// it.
    fn takeCylinder(app: *App, edge: model.Edge) void {
        const part = app.pickedPart() orelse return;
        const index = app.indexOf(part) orelse return;
        const object = if (edge == .low) app.start else app.end;
        const typed = model.parseNumber(app.textOf(object)) orelse {
            app.say("A cylinder is a whole number");
            app.showFields();
            return;
        };
        const room = model.room(app.area(), app.spans[0..app.count], index);
        const boundary = if (edge == .low) typed else typed +| 1;
        const span = model.resized(room, app.spans[index], edge, boundary, .{});
        app.place(part, span);
        app.showFields();
        app.showRows();
        app.showStatus();
    }

    fn takeFileSystem(app: *App, code: usize) void {
        const part = app.pickedPart() orelse return;
        if (app.isSystem(part)) return;
        if (code >= app.fs_types.len or app.fs_labels[code] == null) return;
        const wanted = app.fs_types[code];
        const env = &part.block.environment;
        // Another of the same file system's DosTypes stays as it is.
        if (sameFileSystem(env.dos_type, wanted)) return;
        env.dos_type = wanted;
        app.changed = true;
        app.showRows();
        app.showStatus();
    }

    fn takeFlag(app: *App, flag: u32, on: bool) void {
        const part = app.pickedPart() orelse return;
        const was = part.block.flags;
        part.block.flags = if (on) was | flag else was & ~flag;
        if (part.block.flags != was) {
            app.changed = true;
            app.showStatus();
            app.showButtons();
        }
    }

    fn takeNumber(app: *App, id: usize, code: u32) void {
        const part = app.pickedPart() orelse return;
        const env = &part.block.environment;
        const number: i32 = @bitCast(code);
        const field: *u32 = switch (id) {
            ID_BUFFERS => &env.num_buffers,
            ID_TRANSFER => &env.max_transfer,
            ID_BOOTPRI => @ptrCast(&env.boot_pri),
            else => return,
        };
        const value: u32 = @bitCast(number);
        if (field.* == value) return;
        field.* = value;
        app.changed = true;
        app.showStatus();
        app.showButtons();
    }

    // --- the buttons -------------------------------------------------------------------

    /// An easy requester over the window; whether its first button was
    /// pressed.
    fn ask(app: *App, text: [*:0]const u8, buttons: [*:0]const u8) bool {
        return app.choose(text, buttons) == 1;
    }

    /// An easy requester over the window; the button pressed, from 1 on
    /// the left, 0 for the last.
    fn choose(app: *App, text: [*:0]const u8, buttons: [*:0]const u8) i32 {
        const easy = requesters.EasyStruct{ .title = COMMAND_NAME, .text_format = "%s", .gadget_format = buttons };
        const stream = exec.fmtStream(.{text});
        return app.ib.EasyRequestArgs(app.window, &easy, null, &stream);
    }

    /// The names a new partition is not offered: the table's and those
    /// on dos's list.
    fn takenNames(app: *App, names: *drives.Names) void {
        names.addDosList(app.dl);
        for (app.parts[0..app.count]) |part| names.add(@ptrCast(&part.block.drive_name));
    }

    /// A partition over `span`, named the first free name of the drive's
    /// kind, with the first file system the drive takes; picked.
    fn addPartition(app: *App, span: Span) void {
        const handle = app.handle orelse return;
        const shown = app.unit() orelse return;
        const names = &app.names;
        names.* = .{};
        app.takenNames(names);
        var room: [model.name_room + 1]u8 = @splat(0);
        const name = model.freeName(model.prefixFor(shown.device), names.all(), room[0..model.name_room]);
        room[name.len] = 0;
        var dos_type: u32 = 0;
        for (&filesystems.all) |*file_system| {
            if (filesystems.suits(file_system.dos_type, handle.geometry.erase_size, false)) {
                dos_type = file_system.dos_type;
                break;
            }
        }
        switch (app.rb.AddPartition(handle, @ptrCast(&room), span.low, span.high, dos_type)) {
            rdb.RDBERR_OK => {},
            rdb.RDBERR_FULL => return app.say("The table has room for no more partitions"),
            rdb.RDBERR_NOMEM => return app.say("No memory for another partition"),
            else => return app.say("The partition cannot go there"),
        }
        app.changed = true;
        app.gather();
        // The new one is the last on the handle's list.
        var walk = app.rb.NextPartition(handle, null);
        var last: ?*rdb.RDBPartition = null;
        while (walk) |part| : (walk = app.rb.NextPartition(handle, part)) last = part;
        if (last) |part| app.picked = .{ .part = part };
        app.refresh();
    }

    /// New: a partition of the free run picked, or of the largest.
    fn newPartition(app: *App) void {
        if (!app.hasTable() and app.isGpt()) {
            if (!app.makeContainer()) return;
            return app.addPartition(model.fresh(app.area(), app.grid));
        }
        if (!app.editable()) return;
        const gap = switch (app.picked) {
            .gap => |gap| gap,
            else => blk: {
                var runs: [max_parts + 1]Span = undefined;
                var largest: ?Span = null;
                for (model.gaps(app.area(), app.spans[0..app.count], &runs)) |free_run| {
                    if (largest == null or free_run.cylinders() > largest.?.cylinders()) largest = free_run;
                }
                break :blk largest orelse return;
            },
        };
        app.addPartition(model.fresh(gap, app.grid));
    }

    fn deletePartition(app: *App) void {
        const handle = app.handle orelse return;
        if (app.pickedGpt()) |picked| {
            if (app.gptIsSystem(picked)) return;
            for (app.gpt_before[0..app.gpt_before_count]) |*before| {
                if (before.part == picked) before.part = null;
            }
            app.rb.RemGPTPartition(handle, picked);
            app.changed = true;
            app.picked = .none;
            return app.refresh();
        }
        const part = app.pickedPart() orelse return;
        if (app.isSystem(part) or app.count < 2) return;
        const freed = Span.of(&part.block.environment);
        app.forget(part);
        app.rb.RemPartition(handle, part);
        app.changed = true;
        app.gather();
        // The run it leaves is picked, so New makes it again.
        var runs: [max_parts + 1]Span = undefined;
        app.picked = .none;
        for (model.gaps(app.area(), app.spans[0..app.count], &runs)) |gap| {
            if (gap.low <= freed.low and freed.low <= gap.high) app.picked = .{ .gap = gap };
        }
        app.refresh();
    }

    /// A partition about to be freed let go of by what was read.
    fn forget(app: *App, part: *const rdb.RDBPartition) void {
        for (app.before[0..app.before_count]) |*before| {
            const held = before.part orelse continue;
            if (held == part) before.part = null;
        }
    }

    /// Whole disk: the drive one partition, on a table of its own when it
    /// has none.
    fn wholeDisk(app: *App) void {
        const handle = app.handle orelse return;
        if (app.systemDrive() != null) return;
        if (app.count != 0 and !app.ask("Every partition of the drive goes, and one takes its place.\nWhat they hold is lost once the table is saved.", "Go on|Cancel")) return;
        if (!app.hasTable() or !app.editable()) {
            const made = if (app.isGpt()) app.makeContainer() else app.initTable(.rdb);
            if (!made) return;
        }
        while (app.rb.NextPartition(handle, null)) |part| {
            app.forget(part);
            app.rb.RemPartition(handle, part);
        }
        app.changed = true;
        app.gather();
        app.addPartition(model.fresh(app.area(), app.grid));
    }

    /// New table: an empty one in place of what the drive holds - a
    /// RigidDiskBlock over the whole drive, or a GPT for it with a
    /// PowerOS container and a table in that.
    fn newTable(app: *App) void {
        if (app.handle == null or app.systemDrive() != null) return;
        const kind: TableKind = switch (app.choose(
            "A new, empty table for the drive: a RigidDiskBlock over all of it,\n" ++
                "or a GPT, which other systems read too, with a PowerOS container.\n" ++
                "Everything on the drive is lost once the table is saved.",
            "RDB|GPT|Cancel",
        )) {
            1 => .rdb,
            2 => .gpt,
            else => return,
        };
        if (app.initTable(kind)) app.refresh();
    }

    /// An empty table of `kind` in place of everything the handle holds.
    /// A table that cannot be made leaves the drive read again, as it is
    /// on the disk.
    fn initTable(app: *App, kind: TableKind) bool {
        const handle = app.handle orelse return false;
        for (app.parts[0..app.count]) |part| app.forget(part);
        for (app.gpt_before[0..app.gpt_before_count]) |*before| before.part = null;
        switch (kind) {
            .rdb => app.rb.RemGPT(handle),
            .gpt => if (app.rb.InitGPT(handle) != rdb.RDBERR_OK or !app.addContainer()) {
                app.openDrive(app.current);
                app.say("The medium is too small for a GPT with a container");
                return false;
            },
        }
        if (app.rb.InitRDB(handle) != rdb.RDBERR_OK) {
            app.openDrive(app.current);
            app.say("The medium is too small for a table");
            return false;
        }
        app.tableMade();
        return true;
    }

    /// A table in the GPT's container, the container made first over the
    /// GPT's largest free run where there is none. Why not, on the status
    /// line.
    fn makeContainer(app: *App) bool {
        const handle = app.handle orelse return false;
        if (!app.inContainer() and !app.addContainer()) return false;
        if (app.rb.InitRDB(handle) != rdb.RDBERR_OK) {
            // The container stays, without a table.
            app.refresh();
            app.say("The container is too small for a table");
            return false;
        }
        app.tableMade();
        return true;
    }

    /// A PowerOS container added to the GPT over its largest free run.
    fn addContainer(app: *App) bool {
        const handle = app.handle orelse return false;
        var entry: gpt.Entry = .{ .partition_type_guid = gpt.TYPE_CONTAINER };
        gpt.setName(&entry, container_name);
        var err: i32 = rdb.RDBERR_OK;
        if (app.rb.AddGPTPartition(handle, &entry, &err) != null) {
            app.changed = true;
            return true;
        }
        app.say(switch (err) {
            rdb.RDBERR_RANGE => "The GPT has no free space for a PowerOS container",
            rdb.RDBERR_FULL => "The GPT has no free entry for a PowerOS container",
            rdb.RDBERR_NOMEM => "No memory for the container",
            else => "The container cannot be made",
        });
        return false;
    }

    /// InitRDB has made the handle's table: shown, nothing picked.
    fn tableMade(app: *App) void {
        const handle = app.handle orelse return;
        app.made_table = true;
        app.changed = true;
        app.picked = .none;
        app.gather();
        app.grid = model.Grid.of(app.cylinderBytes(), handle.geometry.erase_size);
    }

    /// Whether the window may close: nothing changed, or the requester
    /// says to leave all the same.
    fn mayLeave(app: *App) bool {
        if (!app.changed) return true;
        return app.ask("The table has changed and is not saved.\nLeave all the same?", "Leave|Cancel");
    }

    // --- saving ------------------------------------------------------------------------

    /// The table written, as the header says: the requester, the stale
    /// drives inhibited, WriteRDB, the new partitions mounted, and the
    /// restart offered.
    fn saveTable(app: *App) void {
        const handle = app.handle orelse return;
        // What the new table is laid out as on the disk, and what it
        // leaves stale.
        for (app.parts[0..app.count], 0..) |part, index| app.after[index] = app.onDisk(&part.block.environment);
        const table = app.after[0..app.count];

        var question: Line(400) = .{};
        question.add("Write the table to ");
        question.add(app.unit_text[app.current].slice());
        question.add("?");
        var lost = false;
        for (app.before[0..app.before_count]) |*before| {
            if (model.kept(table, &before.env)) continue;
            question.add(if (lost) " " else "\nWhat these partitions hold is lost: ");
            lost = true;
            question.add(nameText(&before.name));
        }
        for (app.gpt_before[0..app.gpt_before_count]) |*before| {
            if (before.part != null) continue;
            question.add(if (lost) " " else "\nWhat these partitions hold is lost: ");
            lost = true;
            question.add(fieldText(&before.name));
        }
        var stale: [drives.max_mounted]bool = @splat(false);
        var any_stale = false;
        for (app.mounted[0..app.mounted_count], 0..) |*mounted, index| {
            if (!model.stale(&mounted.env, table) or app.keptByGpt(&mounted.env)) continue;
            question.add(if (any_stale) " " else "\nThese drives stop until the system starts again: ");
            any_stale = true;
            stale[index] = true;
            question.add(mounted.nameText());
            question.add(":");
        }
        if (!app.ask(question.ptr(), "Save|Cancel")) return;

        // Every stale drive held still, or nothing is written.
        var held: [drives.max_mounted]bool = @splat(false);
        for (app.mounted[0..app.mounted_count], 0..) |*mounted, index| {
            if (!stale[index]) continue;
            const drive = driveText(mounted);
            if (app.dl.Inhibit(drive.ptr(), true)) {
                held[index] = true;
                continue;
            }
            app.letGo(&held);
            var why: Line(120) = .{};
            why.add(mounted.nameText());
            why.add(": is in use - a file open for writing? Nothing is written");
            app.say(why.slice());
            return;
        }

        // The GPT first: WriteRDB refuses a table whose container is
        // not on the disk yet.
        const gpt_changed = rdb.RDBF_GPT | rdb.RDBF_GPTCHANGED;
        const gpt_written = handle.flags & gpt_changed == gpt_changed;
        if (gpt_written) {
            const err = app.rb.WriteGPT(handle);
            if (err != rdb.RDBERR_OK) return app.notWritten(err, .gpt, false, &held);
        }
        if (app.hasTable()) {
            const err = app.rb.WriteRDB(handle);
            if (err != rdb.RDBERR_OK) return app.notWritten(err, .table, gpt_written, &held);
        }

        // The partitions no drive has yet, mounted.
        var said: Line(160) = .{};
        said.add("Saved");
        var first = true;
        for (app.parts[0..app.count]) |part| {
            if (part.block.flags & hardblocks.PBFF_NOMOUNT != 0) continue;
            if (app.mountedAs(part) != null) continue;
            var name: rdb.MountName = undefined;
            if (app.rb.MountPartition(handle, part, &name, rdb.RDBMF_START) != rdb.RDBERR_OK) continue;
            said.add(if (first) "; mounted " else " ");
            first = false;
            said.add(nameText(&name));
            said.add(":");
        }

        // Read again, the partition picked still picked.
        var picked_name: rdb.MountName = @splat(0);
        if (app.pickedPart()) |part| {
            const name = part.block.name();
            @memcpy(picked_name[0..name.len], name);
        }
        const new_code = app.runsNewCode();
        const restart = any_stale or new_code or app.restart_wanted;
        app.openDrive(app.current);
        app.restart_wanted = restart;
        for (app.parts[0..app.count]) |part| {
            if (equalBytes(part.block.name(), nameText(&picked_name))) app.picked = .{ .part = part };
        }
        app.refresh();
        app.say(said.slice());
        const why: [*:0]const u8 = if (!any_stale and new_code)
            "The table is written. Its drives run the new file system once the system starts again.\nRestart now?"
        else
            "The table is written. Drives mounted from the old one stop until the system starts again.\nRestart now?";
        if (restart and app.ask(why, "Restart|Later")) app.restartSystem();
    }

    /// A write that stopped: why, on the status line. One refused before
    /// anything was written left the disk as it was, and the drives held
    /// go again; one that failed on the way may have written part, and
    /// they stay held. A medium changed since it was read is read again.
    fn notWritten(app: *App, err: i32, what: Written, gpt_written: bool, held: *[drives.max_mounted]bool) void {
        if (err != rdb.RDBERR_IO and !gpt_written) app.letGo(held);
        app.say(switch (what) {
            .gpt => switch (err) {
                rdb.RDBERR_CHANGED => "The medium has changed: it is read again",
                rdb.RDBERR_RANGE => "The GPT's partitions overlap, or do not fit the disk",
                rdb.RDBERR_IO => "The GPT could not be written",
                else => "The GPT was not written",
            },
            .table => switch (err) {
                rdb.RDBERR_CHANGED => "The medium has changed: it is read again",
                rdb.RDBERR_NAME => "Two partitions have one name, or a name is wrong",
                rdb.RDBERR_RANGE => "A partition's cylinders are wrong",
                rdb.RDBERR_FULL => "The table has no room for so many partitions, or for the file systems' code",
                rdb.RDBERR_IO => "The table could not be written",
                else => "The table was not written",
            },
        });
        if (err == rdb.RDBERR_CHANGED) app.openDrive(app.current);
    }

    /// Whether a drive mounted from the drive shown is of a DosType whose
    /// code was added or taken out: it runs what it ran until the system
    /// starts again.
    fn runsNewCode(app: *const App) bool {
        for (app.mounted[0..app.mounted_count]) |*mounted| {
            for (app.touched[0..app.touched_count]) |dos_type| {
                if (mounted.env.dos_type == dos_type) return true;
            }
        }
        return false;
    }

    /// A DosType noted as having had its code changed.
    fn touch(app: *App, dos_type: u32) void {
        for (app.touched[0..app.touched_count]) |seen| {
            if (seen == dos_type) return;
        }
        if (app.touched_count == app.touched.len) return;
        app.touched[app.touched_count] = dos_type;
        app.touched_count += 1;
    }

    // --- the file systems ------------------------------------------------------------

    /// Add...: a handler's load file picked in a requester and kept in
    /// the table for the DosType For names.
    fn addFileSystem(app: *App) void {
        const handle = app.handle orelse return;
        if (!app.editable() or app.for_active >= app.for_types.len or app.for_labels[app.for_active] == null) return;
        const dos_type = app.for_types[app.for_active];
        var path: [264:0]u8 = @splat(0);
        if (!app.askFile(&path)) return;
        var size: u32 = 0;
        const code = app.readFile(&path, &size) orelse return;
        defer app.sys.FreeVec(code);
        const err = app.rb.AddFileSystem(handle, dos_type, code, size);
        if (err != rdb.RDBERR_OK) {
            app.say(switch (err) {
                rdb.RDBERR_FILESYSTEM => "That file is not a handler for this machine",
                rdb.RDBERR_NOMEM => "No memory for the file system",
                else => "The file system was not added",
            });
            return;
        }
        app.touch(dos_type);
        app.changed = true;
        // The one just added picked: it is the list's last.
        var last: ?*rdb.RDBFileSystem = null;
        var stored = app.rb.NextFileSystem(handle, null);
        while (stored) |file_system| : (stored = app.rb.NextFileSystem(handle, file_system)) last = file_system;
        app.fs_picked = last;
        app.refresh();
    }

    /// Remove: the file system picked taken out of the table.
    fn removeFileSystem(app: *App) void {
        const handle = app.handle orelse return;
        const file_system = app.fs_picked orelse return;
        if (!app.editable()) return;
        app.touch(file_system.header.dos_type);
        app.fs_picked = null;
        app.rb.RemFileSystem(handle, file_system);
        app.changed = true;
        app.refresh();
    }

    /// A row picked in the file systems' list.
    fn pickFileSystem(app: *App) void {
        var value: usize = 0;
        _ = app.ib.GetAttr(lb.LISTBROWSER_SelectedRow, app.fs_list, &value);
        app.fs_picked = if (value == 0) null else @ptrFromInt(@as(*lb.Row, @ptrFromInt(value)).user_data);
        app.showButtons();
    }

    /// The file a requester over the window was asked for, its whole
    /// path into `into`; false when none was picked.
    fn askFile(app: *App, into: *[264:0]u8) bool {
        const asl_lib = app.sys.OpenLibrary(asl.ASLNAME, 0) orelse {
            app.say("No " ++ asl.ASLNAME);
            return false;
        };
        defer app.sys.CloseLibrary(asl_lib);
        const al: *AslBase = @ptrCast(asl_lib);
        const request = al.AllocAslRequest(asl.ASL_FileRequest, &[_]TagItem{
            pair(asl.ASLFR_TitleText, @intFromPtr("Which handler?")),
            pair(asl.ASLFR_InitialDrawer, @intFromPtr("HANDLERS:")),
            pair(asl.ASLFR_Window, @intFromPtr(app.window)),
            .{},
        }) orelse return false;
        defer al.FreeAslRequest(request);
        if (!al.AslRequest(request, null)) return false;
        const file: *asl.FileRequester = @ptrCast(@alignCast(request));
        const drawer = file.drawer orelse return false;
        const name = file.file orelse return false;
        if (name[0] == 0) return false;
        var line: Line(263) = .{};
        line.addText(drawer);
        if (line.len != 0 and line.text[line.len - 1] != ':' and line.text[line.len - 1] != '/') line.add("/");
        line.addText(name);
        @memcpy(into[0 .. line.len + 1], line.text[0 .. line.len + 1]);
        return true;
    }

    /// A file read whole into memory of its own, its size in `size`; null,
    /// and why on the status line, when it cannot be.
    fn readFile(app: *App, path: [*:0]const u8, size: *u32) ?[*]u8 {
        const dl = app.dl;
        const fh = dl.Open(path, dos.MODE_OLDFILE) orelse {
            app.say("The file cannot be opened");
            return null;
        };
        defer _ = dl.Close(fh);
        var fib: dos.FileInfoBlock = .{};
        if (!dl.ExamineFH(fh, &fib) or fib.size == 0 or fib.size > 0x7FFF_FFFF) {
            app.say("The file cannot be read");
            return null;
        }
        const bytes: u32 = @intCast(fib.size);
        const code: [*]u8 = @ptrCast(app.sys.AllocVec(bytes, exec.MEMF_ANY) orelse {
            app.say("No memory for the file");
            return null;
        });
        if (dl.Read(fh, code, @intCast(bytes)) != bytes) {
            app.sys.FreeVec(code);
            app.say("The file cannot be read");
            return null;
        }
        size.* = bytes;
        return code;
    }

    /// A node with this startup opens a unit of a block device.
    fn onBlockDevice(app: *const App, startup: *const dos.FileSysStartupMsg) bool {
        for (app.units.all()) |listed| {
            if (dos.filehandler.opensUnit(startup, listed.device, listed.number)) return true;
        }
        return false;
    }

    /// The drives held still let go again.
    fn letGo(app: *App, held: *[drives.max_mounted]bool) void {
        for (app.mounted[0..app.mounted_count], 0..) |*mounted, index| {
            if (!held[index]) continue;
            const drive = driveText(mounted);
            _ = app.dl.Inhibit(drive.ptr(), false);
            held[index] = false;
        }
    }

    /// Every drive mounted from a block device held still, so that its
    /// file system writes out what it holds - ColdReboot itself writes
    /// nothing - and the system started again; a drive that will not stop
    /// is named first. Nodes on other devices, such as a console on a
    /// serial port, hold nothing to write.
    fn restartSystem(app: *App) void {
        const names = &app.names;
        names.* = .{};
        {
            const flags = dos.LDF_DEVICES | dos.LDF_READ;
            const list = app.dl.LockDosList(flags) orelse return;
            defer app.dl.UnLockDosList(flags);
            var entry = app.dl.NextDosEntry(list, dos.LDF_DEVICES);
            while (entry) |node| : (entry = app.dl.NextDosEntry(node, dos.LDF_DEVICES)) {
                if (node.task == null) continue;
                const startup = dos.filehandler.startupOf(node.misc.handler.startup) orelse continue;
                if (!app.onBlockDevice(startup)) continue;
                names.add(node.name);
            }
        }
        var refused: Line(200) = .{};
        for (names.all()) |name| {
            var drive: Line(dos.MAX_DEVICE_NAME + 1) = .{};
            drive.add(name);
            drive.add(":");
            if (app.dl.Inhibit(drive.ptr(), true)) continue;
            refused.add(" ");
            refused.add(drive.slice());
        }
        if (refused.len != 0) {
            var question: Line(300) = .{};
            question.add("These drives would not stop, and what they hold may not be written out:");
            question.add(refused.slice());
            question.add("\nRestart all the same?");
            if (!app.ask(question.ptr(), "Restart|Cancel")) {
                for (names.all()) |name| {
                    var drive: Line(dos.MAX_DEVICE_NAME + 1) = .{};
                    drive.add(name);
                    drive.add(":");
                    _ = app.dl.Inhibit(drive.ptr(), false);
                }
                return;
            }
        }
        app.sys.ColdReboot();
    }

    // --- the window's messages -----------------------------------------------------------

    fn signalOf(app: *App) u32 {
        var mask: usize = 0;
        _ = app.ib.GetAttr(wc.WINDOWA_SigMask, app.object, &mask);
        return @truncate(mask);
    }

    /// A drive picked in the chooser: read, once the changes may go.
    fn pickDrive(app: *App, index: usize) void {
        if (index == app.current) return;
        if (app.changed and !app.ask("The table has changed and is not saved.\nShow another drive all the same?", "Show it|Cancel")) {
            app.set(null, app.drive, &.{ .{ .tag = ch.CHOOSER_Active, .data = app.current }, .{} });
            return;
        }
        app.openDrive(index);
    }

    /// A row picked in the list: its partition picked.
    fn pickRow(app: *App) void {
        var value: usize = 0;
        _ = app.ib.GetAttr(lb.LISTBROWSER_SelectedRow, app.list, &value);
        if (value == 0) return;
        const list_row: *lb.Row = @ptrFromInt(value);
        app.picked = app.pickOf(list_row.user_data) orelse return;
        app.showFields();
        app.showButtons();
        app.drawBar();
    }

    /// Everything the window has to say. False to end.
    fn windowMessages(app: *App) bool {
        var code: u32 = 0;
        var input = wc.WmHandleInput{ .code = &code };
        while (true) {
            const word = app.ib.SendMessage(app.object, @ptrCast(&input));
            if (word == wc.WMHI_LASTMSG) return true;
            var gadget: usize = wc.WINDOW_NOGADGET;
            _ = app.ib.GetAttr(wc.WINDOWA_GadgetID, app.object, &gadget);
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => if (app.mayLeave()) return false,
                wc.WMHI_GADGETDOWN => if (word & wc.WMHI_GADGETMASK == ID_BAR) app.press(),
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_DRIVE => app.pickDrive(code),
                    ID_BAR => app.release(),
                    ID_LIST => app.pickRow(),
                    ID_NAME => app.takeName(),
                    ID_FILESYSTEM => app.takeFileSystem(code),
                    ID_START => app.takeCylinder(.low),
                    ID_END => app.takeCylinder(.high),
                    ID_BOOTABLE => app.takeFlag(hardblocks.PBFF_BOOTABLE, code != 0),
                    ID_AUTOMOUNT => app.takeFlag(hardblocks.PBFF_NOMOUNT, code == 0),
                    ID_BUFFERS, ID_TRANSFER, ID_BOOTPRI => app.takeNumber(word & wc.WMHI_GADGETMASK, code),
                    ID_NEW => app.newPartition(),
                    ID_DELETE => app.deletePartition(),
                    ID_WHOLE => app.wholeDisk(),
                    ID_TABLE => app.newTable(),
                    ID_SAVE => app.saveTable(),
                    ID_FS_LIST => app.pickFileSystem(),
                    ID_FS_FOR => {
                        app.for_active = code;
                    },
                    ID_FS_ADD => app.addFileSystem(),
                    ID_FS_REMOVE => app.removeFileSystem(),
                    ID_QUIT => if (app.mayLeave()) return false,
                    else => {},
                },
                wc.WMHI_IDCMPUPDATE => if (gadget == ID_BAR and app.drag != .none) app.dragTo(),
                wc.WMHI_NEWSIZE => {
                    app.fitBar();
                    app.drawBar();
                },
                wc.WMHI_DISKINSERTED, wc.WMHI_DISKREMOVED => app.mediumChanged(),
                wc.WMHI_NEWPREFS => {
                    app.ib.FreeScreenDrawInfo(app.screen, app.draw_info);
                    app.draw_info = app.ib.GetScreenDrawInfo(app.screen);
                    app.takeLook();
                    app.drawBar();
                },
                else => {},
            }
        }
    }

    fn run(app: *App) void {
        while (true) {
            const got = app.sys.Wait(app.signalOf() | exec.SIGBREAKF_CTRL_C);
            if (got & exec.SIGBREAKF_CTRL_C != 0 and app.mayLeave()) return;
            if (!app.windowMessages()) return;
        }
    }

    // --- the window ---------------------------------------------------------------------

    /// The chooser's labels: each unit as its device and number, and what
    /// the board calls it.
    fn nameUnits(app: *App) void {
        for (app.units.all(), 0..) |*listed, index| {
            const line = &app.unit_text[index];
            line.addText(listed.device);
            line.add(" ");
            line.number(listed.number);
            if (listed.label) |board_name| {
                line.add(" - ");
                line.addText(board_name);
            }
            app.unit_labels[index] = line.ptr();
        }
        if (app.units.count == 0) {
            app.unit_text[0].add("No drive");
            app.unit_labels[0] = app.unit_text[0].ptr();
        }
    }

    /// The rows a line of the screen's font takes.
    fn fontHeight(app: *App) i32 {
        const font = app.draw_info.font orelse return 8;
        var extent = graphics.FontExtent{};
        app.gb.FontExtent(font, &extent);
        return @max(extent.height, 8);
    }

    /// The window's whole layout, its gadgets kept in the App; null when
    /// something could not be made.
    fn build(app: *App) ?*Object {
        const ib = app.ib;
        app.drive = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_DRIVE),
            pair(ch.CHOOSER_Labels, @intFromPtr(&app.unit_labels)),
            pair(ch.CHOOSER_MaxPanelLines, 8),
            .{},
        }) orelse return null;
        app.status = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
            pair(tx.TEXT_Text, @intFromPtr(app.status_text.ptr())),
            pair(tx.TEXT_Clipped, 1),
            .{},
        }) orelse return null;
        app.bar = ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_BAR),
            pair(gc.GA_Immediate, 1),
            pair(gc.GA_RelVerify, 1),
            pair(cv.CANVAS_Width, bar_width),
            pair(cv.CANVAS_Height, bar_height),
            pair(icc.ICA_TARGET, icc.ICTARGET_IDCMP),
            .{},
        }) orelse return null;
        app.rows.init(.unknown);
        app.list = ib.NewObjectTagList(null, lb.LISTBROWSER_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_LIST),
            pair(gc.GA_RelVerify, 1),
            pair(lb.LISTBROWSER_Columns, @intFromPtr(&columns)),
            pair(lb.LISTBROWSER_Rows, @intFromPtr(&app.rows)),
            .{},
        }) orelse return null;

        // The partition's page.
        app.name = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_NAME),
            pair(gc.GA_RelVerify, 1),
            pair(gc.STRINGA_MaxChars, dos.MAX_DEVICE_NAME + 1),
            .{},
        }) orelse return null;
        app.file_system = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_FILESYSTEM),
            pair(ch.CHOOSER_Labels, @intFromPtr(&app.fs_labels)),
            .{},
        }) orelse return null;
        app.bootable = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{ pair(gc.GA_ID, ID_BOOTABLE), .{} }) orelse return null;
        app.start = numberField(ib, ID_START) orelse return null;
        app.end = numberField(ib, ID_END) orelse return null;
        app.size = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
            pair(tx.TEXT_Text, @intFromPtr(app.size_text.ptr())),
            pair(tx.TEXT_Border, 1),
            .{},
        }) orelse return null;
        app.pages[page_partition] = row(ib, &.{
            column(ib, &.{ app.name, app.file_system, app.bootable }, &.{ "_Name", "_File system", "_Bootable" }),
            column(ib, &.{ app.start, app.end, app.size }, &.{ "Sta_rt", "_End", "Size" }),
        }) orelse return null;

        // The advanced page.
        app.buffers = integerField(ib, ID_BUFFERS, 1, 0x7FFF_FFFF) orelse return null;
        app.transfer = integerField(ib, ID_TRANSFER, 512, 0x7FFF_FFFF) orelse return null;
        app.boot_pri = integerField(ib, ID_BOOTPRI, -128, 127) orelse return null;
        app.automount = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{ pair(gc.GA_ID, ID_AUTOMOUNT), .{} }) orelse return null;
        app.pages[page_advanced] = row(ib, &.{
            column(ib, &.{ app.buffers, app.transfer }, &.{ "B_uffers", "Max _transfer" }),
            column(ib, &.{ app.boot_pri, app.automount }, &.{ "Boot _priority", "_Mount at start" }),
        }) orelse return null;

        // The file systems' page.
        app.fs_rows.init(.unknown);
        app.fs_list = ib.NewObjectTagList(null, lb.LISTBROWSER_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_FS_LIST),
            pair(gc.GA_RelVerify, 1),
            pair(lb.LISTBROWSER_Columns, @intFromPtr(&fs_columns)),
            pair(lb.LISTBROWSER_Rows, @intFromPtr(&app.fs_rows)),
            .{},
        }) orelse return null;
        app.fs_for = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_FS_FOR),
            pair(ch.CHOOSER_Labels, @intFromPtr(&app.for_labels)),
            .{},
        }) orelse return null;
        app.fs_add = button(ib, "Add...", ID_FS_ADD) orelse return null;
        app.fs_remove = button(ib, "Remove", ID_FS_REMOVE) orelse return null;
        const fs_side = column(ib, &.{ app.fs_for, app.fs_add, app.fs_remove }, &.{ "F_or", "", "" }) orelse return null;
        // The list as tall as the other pages' three rows of fields, so
        // the pages keep the height they have without it.
        const list_height: usize = @intCast(3 * app.fontHeight() + 24);
        app.pages[page_files] = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
            pair(lg.LAYOUTA_Spacing, 6),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(app.fs_list)),
            pair(lg.CHILDA_MinHeight, list_height),
            pair(lg.CHILDA_MaxHeight, list_height),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(fs_side)),
            pair(lg.CHILDA_WeightWidth, 0),
            .{},
        }) orelse return null;

        app.tabs = ib.NewObjectTagList(null, ct.CLICKTAB_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_TABS),
            pair(ct.CLICKTAB_Labels, @intFromPtr(&tab_names)),
            .{},
        }) orelse return null;
        const book = ib.NewObjectTagList(null, pgc.PAGE_CLASS, &[_]TagItem{
            pair(pgc.PAGE_Pages, @intFromPtr(&app.pages)),
            pair(pgc.PAGE_Tabs, @intFromPtr(app.tabs)),
            .{},
        }) orelse return null;

        app.new = button(ib, "Ne_w", ID_NEW) orelse return null;
        app.delete = button(ib, "_Delete", ID_DELETE) orelse return null;
        app.whole = button(ib, "W_hole disk", ID_WHOLE) orelse return null;
        app.new_table = button(ib, "New t_able", ID_TABLE) orelse return null;
        app.save = button(ib, "_Save", ID_SAVE) orelse return null;
        const buttons = row(ib, &.{ app.new, app.delete, app.whole, app.new_table, app.save, button(ib, "_Quit", ID_QUIT) }) orelse return null;
        const top = column(ib, &.{app.drive}, &.{"Dri_ve"}) orelse return null;

        return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            pair(lg.LAYOUTA_Margin, 6),
            pair(lg.LAYOUTA_Spacing, 4),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(top)),
            pair(lg.CHILDA_WeightHeight, 0),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(app.status)),
            pair(lg.CHILDA_WeightHeight, 0),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(app.bar)),
            pair(lg.CHILDA_WeightHeight, 0),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(app.list)),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(book)),
            pair(lg.CHILDA_WeightHeight, 0),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(buttons)),
            pair(lg.CHILDA_WeightHeight, 0),
            .{},
        });
    }

    fn deinit(app: *App) void {
        app.closeDrive();
        if (app.units.list != null) app.units.release(app.eb);
        lb.freeRows(app.sys, &app.rows);
        lb.freeRows(app.sys, &app.fs_rows);
    }
};

/// Two DosTypes of one file system: another of FAT's or posfs's stays
/// as it is.
fn sameFileSystem(one: u32, other: u32) bool {
    const first = filesystems.of(one) orelse return one == other;
    const second = filesystems.of(other) orelse return false;
    return first == second;
}

fn equalBytes(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |a, b| {
        if (a != b) return false;
    }
    return true;
}

fn nameText(name: *const rdb.MountName) []const u8 {
    var length: usize = 0;
    while (length < name.len and name[length] != 0) length += 1;
    return name[0..length];
}

/// The text of a fixed field, up to its first NUL.
fn fieldText(field: []const u8) []const u8 {
    var length: usize = 0;
    while (length < field.len and field[length] != 0) length += 1;
    return field[0..length];
}

/// What a partition of the GPT is called on the bar and in the list: its
/// own name, or its type's where it has none, into `into`.
fn gptLabel(part: *const rdb.GPTPartition, into: *[gpt.name_units:0]u8) []const u8 {
    const own = gpt.nameText(&part.entry, into);
    if (own.len != 0) return own;
    const kind = gpt.typeName(&part.entry.partition_type_guid) orelse "Partition";
    into.* = @splat(0);
    var length: usize = 0;
    while (kind[length] != 0 and length < into.len) : (length += 1) into[length] = kind[length];
    return into[0..length];
}

/// The bytes of a partition of the GPT.
fn gptBytes(part: *const rdb.GPTPartition, block_bytes: u32) u64 {
    const entry = &part.entry;
    if (entry.ending_lba < entry.starting_lba) return 0;
    return (entry.ending_lba - entry.starting_lba + 1) * block_bytes;
}

/// A drive's name with its colon, as dos takes it.
fn driveText(mounted: *const drives.Mounted) Line(dos.MAX_DEVICE_NAME + 1) {
    var line: Line(dos.MAX_DEVICE_NAME + 1) = .{};
    line.add(mounted.nameText());
    line.add(":");
    return line;
}

fn pair(tag: utility.Tag, data: usize) TagItem {
    return .{ .tag = tag, .data = data };
}

/// A layout of `children`, one under the other, each with its label.
fn column(ib: *IntuitionBase, children: []const ?*Object, labels: []const [*:0]const u8) ?*Object {
    var tags: [32]TagItem = undefined;
    var count: usize = 0;
    tags[count] = pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT);
    count += 1;
    tags[count] = pair(lg.LAYOUTA_Spacing, 3);
    count += 1;
    for (children, labels) |child, text| {
        tags[count] = pair(lg.LAYOUTA_AddChild, @intFromPtr(child orelse return null));
        count += 1;
        tags[count] = pair(lg.CHILDA_Label, @intFromPtr(text));
        count += 1;
        tags[count] = pair(lg.CHILDA_WeightHeight, 0);
        count += 1;
    }
    tags[count] = .{};
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &tags);
}

/// A layout of `children` side by side.
fn row(ib: *IntuitionBase, children: []const ?*Object) ?*Object {
    var tags: [16]TagItem = undefined;
    var count: usize = 0;
    tags[count] = pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ);
    count += 1;
    tags[count] = pair(lg.LAYOUTA_Spacing, 6);
    count += 1;
    for (children) |child| {
        tags[count] = pair(lg.LAYOUTA_AddChild, @intFromPtr(child orelse return null));
        count += 1;
    }
    tags[count] = .{};
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &tags);
}

fn button(ib: *IntuitionBase, text: [*:0]const u8, id: usize) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        pair(gc.GA_Text, @intFromPtr(text)),
        pair(gc.GA_ID, id),
        pair(gc.GA_RelVerify, 1),
        .{},
    });
}

/// A field for a cylinder's number, which may be past an integer
/// gadget's range.
fn numberField(ib: *IntuitionBase, id: usize) ?*Object {
    return ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        pair(gc.GA_ID, id),
        pair(gc.GA_RelVerify, 1),
        pair(gc.STRINGA_MaxChars, 11),
        .{},
    });
}

fn integerField(ib: *IntuitionBase, id: usize, min: i32, max: i32) ?*Object {
    return ib.NewObjectTagList(null, ig.INTEGER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, id),
        pair(gc.GA_RelVerify, 1),
        pair(ig.INTEGER_Min, @bitCast(@as(isize, min))),
        pair(ig.INTEGER_Max, @bitCast(@as(isize, max))),
        pair(ig.INTEGER_Arrows, 0),
        .{},
    });
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    // The libraries, open until the window object is gone.
    const names = [_][*:0]const u8{
        intuition.INTUITIONNAME, graphics.GRAPHICSNAME, sdk.expansion.EXPANSIONNAME, rdb.RDBNAME,
        ct.CLICKTAB_LIBRARY,     pgc.PAGE_LIBRARY,      ch.CHOOSER_LIBRARY,          st.STRING_LIBRARY,
        ig.INTEGER_LIBRARY,      tx.TEXT_LIBRARY,       cb.CHECKBOX_LIBRARY,         cv.CANVAS_LIBRARY,
        lb.LISTBROWSER_LIBRARY,
    };
    const versions = [names.len]u32{ 0, 0, drives.expansion_version, rdb_version, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var libraries: [names.len]*exec.Library = undefined;
    var opened: usize = 0;
    defer {
        while (opened > 0) {
            opened -= 1;
            sys.CloseLibrary(libraries[opened]);
        }
    }
    for (names, versions) |name, version| {
        libraries[opened] = sys.OpenLibrary(name, version) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{name});
            return dos.RETURN_FAIL;
        };
        opened += 1;
    }
    const rdb_lib = libraries[3];
    if (rdb_lib.version == rdb_version and rdb_lib.revision < rdb_revision) {
        _ = Printf(dl, MSG_OLDLIBRARY, .{rdb.RDBNAME});
        return dos.RETURN_FAIL;
    }
    const ib: *IntuitionBase = @ptrCast(libraries[0]);

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);

    // The program's state is large for its stack: it lives in memory of
    // its own.
    const app: *App = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(App), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }));
    defer sys.FreeVec(app);
    app.* = .{
        .sys = sys,
        .dl = dl,
        .ib = ib,
        .gb = @ptrCast(libraries[1]),
        .eb = @ptrCast(libraries[2]),
        .rb = @ptrCast(rdb_lib),
        .screen = screen,
        .draw_info = ib.GetScreenDrawInfo(screen),
    };
    defer ib.FreeScreenDrawInfo(screen, app.draw_info);
    defer app.deinit();

    if (!app.units.obtain(app.eb)) {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    app.system = drives.systemNode(dl);
    app.nameUnits();
    _ = app.fileSystems(null);

    const layout = app.build() orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr(COMMAND_NAME)),
        pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
        pair(wn.WA_PubScreen, @intFromPtr(screen)),
        // Room for the list's columns; a smaller screen gets what it has.
        pair(wn.WA_InnerWidth, 460),
        pair(wn.WA_AutoAdjust, 1),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_SizeGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wn.WA_IDCMP, wn.IDCMP_IDCMPUPDATE | wn.IDCMP_NEWSIZE | wn.IDCMP_DISKINSERTED | wn.IDCMP_DISKREMOVED | wn.IDCMP_NEWPREFS),
        pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    // The window goes before the rows it shows are freed.
    defer ib.DisposeObject(object);
    app.object = object;

    var open = wc.WmOpen{};
    const opened_window = ib.SendMessage(object, @ptrCast(&open));
    if (opened_window == 0) {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    app.window = @ptrFromInt(opened_window);
    // The bar as big as its box, now that it has one.
    app.fitBar();
    app.openDrive(0);
    app.run();
    return dos.RETURN_OK;
}
