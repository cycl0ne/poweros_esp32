// SPDX-License-Identifier: MIT
//! Show: what the machine is made of, from the lists it keeps. Built
//! against the SDK only.
//!
//!   Show TASKS/S,DEVS/S,LIBS/S,RESOURCES/S,PORTS/S,SEMAPHORES/S,
//!        HANDLERS/S,RESIDENTS/S,INTS/S,MEM/S,SEGMENTS/S,ALL/S
//!
//! With nothing asked for it prints a line per section saying how much
//! there is of each, which is the question "what is going on" usually
//! wants answered first. A switch prints that section; ALL prints them
//! all.
//!
//! Everything here is read from exec's and dos's own lists rather than
//! from a copy, so every walk is done holding the thing that keeps the
//! list still - Forbid for exec's, Disable for the two task queues and the
//! interrupt vectors, the DosList's own lock for the handlers - and
//! nothing writes. A list is walked, printed from, and let go.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Show";
const VERSION_STRING = "\x00$VER: Show 1.0 (17.9.2026)\r\n";

const template = "TASKS/S,DEVS/S,LIBS/S,RESOURCES/S,PORTS/S,SEMAPHORES/S," ++
    "HANDLERS/S,RESIDENTS/S,INTS/S,MEM/S,SEGMENTS/S,ALL/S";
const arg_tasks = 0;
const arg_devs = 1;
const arg_libs = 2;
const arg_resources = 3;
const arg_ports = 4;
const arg_semaphores = 5;
const arg_handlers = 6;
const arg_residents = 7;
const arg_ints = 8;
const arg_mem = 9;
const arg_segments = 10;
const arg_all = 11;
const arg_count = 12;

var sys: *ExecBase = undefined;
var dl: *DosBase = undefined;

export fn _program_entry(base: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sys = base;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    dl = @ptrCast(dos_lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const all = argv[arg_all] != 0;
    var asked = all;
    for (argv[0..arg_all]) |switch_on| {
        if (switch_on != 0) asked = true;
    }
    if (!asked) return summary();

    if (all or argv[arg_tasks] != 0) tasks();
    if (all or argv[arg_libs] != 0) modules("Libraries", exec.EXECLIST_LIBRARIES);
    if (all or argv[arg_devs] != 0) modules("Devices", exec.EXECLIST_DEVICES);
    if (all or argv[arg_resources] != 0) resources();
    if (all or argv[arg_ports] != 0) ports();
    if (all or argv[arg_semaphores] != 0) semaphores();
    if (all or argv[arg_handlers] != 0) handlers();
    if (all or argv[arg_residents] != 0) residents();
    if (all or argv[arg_ints] != 0) interrupts();
    if (all or argv[arg_mem] != 0) memory();
    if (all or argv[arg_segments] != 0) segments();
    return dos.RETURN_OK;
}

/// Walking a list needs the next node and an end: exec's lists end at a
/// sentinel whose own successor is null.
fn nextNode(node: *exec.Node) ?*exec.Node {
    const succ = node.succ orelse return null;
    return if (succ.succ == null) null else succ;
}

fn firstOf(which: u32) ?*exec.Node {
    const list = sys.ExecList(which) orelse return null;
    return list.first();
}

fn countOf(which: u32) u32 {
    sys.Forbid();
    defer sys.Permit();
    var count: u32 = 0;
    var node = firstOf(which);
    while (node) |n| : (node = nextNode(n)) count += 1;
    return count;
}

fn name(of: ?[*:0]const u8) [*:0]const u8 {
    return of orelse "?";
}

// --- one line each ------------------------------------------------------------

fn summary() i32 {
    _ = Printf(dl, "%-12s %d ready, %d waiting\n", .{
        "Tasks",
        countOf(exec.EXECLIST_TASK_READY),
        countOf(exec.EXECLIST_TASK_WAIT),
    });
    _ = Printf(dl, "%-12s %d\n", .{ "Libraries", countOf(exec.EXECLIST_LIBRARIES) });
    _ = Printf(dl, "%-12s %d\n", .{ "Devices", countOf(exec.EXECLIST_DEVICES) });
    _ = Printf(dl, "%-12s %d\n", .{ "Resources", countOf(exec.EXECLIST_RESOURCES) });
    _ = Printf(dl, "%-12s %d\n", .{ "Ports", countOf(exec.EXECLIST_PORTS) });
    _ = Printf(dl, "%-12s %d\n", .{ "Semaphores", countOf(exec.EXECLIST_SEMAPHORES) });
    _ = Printf(dl, "%-12s %d\n", .{ "Handlers", countHandlers() });
    _ = Printf(dl, "%-12s %d\n", .{ "Residents", countResidents() });
    _ = Printf(dl, "%-12s %d in use of %d\n", .{ "Interrupts", countInterrupts(), sdk.hardware.intbits.INTB_COUNT });
    _ = Printf(dl, "%-12s %d regions\n", .{ "Memory", countOf(exec.EXECLIST_MEMORY) });
    _ = Printf(dl, "%-12s %d\n", .{ "Segments", countSegments() });
    _ = dl.PutStr("Show ALL, or a switch per section: Show ?\n");
    return dos.RETURN_OK;
}

// --- exec's lists -------------------------------------------------------------

/// The two task queues, and whoever is running. A task is moved between
/// them from an interrupt, so this holds them still with Disable rather
/// than Forbid - and prints nothing while it has them, since printing
/// waits on a handler.
fn tasks() void {
    _ = dl.PutStr("\nTasks\n");
    _ = dl.PutStr("state     pri  address     name\n");
    if (sys.FindTask(null)) |self| {
        _ = Printf(dl, "%-8s %4d  0x%08x  %s (this one)\n", .{
            "run",
            self.node.pri,
            @intFromPtr(self),
            name(self.node.name),
        });
    }
    showQueue("ready", exec.EXECLIST_TASK_READY);
    showQueue("wait", exec.EXECLIST_TASK_WAIT);
}

/// One queue, a node at a time: what is printed is copied out under
/// Disable and printed after, because a printed line goes to a handler and
/// a handler cannot run while the scheduler is held.
fn showQueue(state: [*:0]const u8, which: u32) void {
    var after: ?*exec.Node = null;
    while (true) {
        var address: usize = 0;
        var pri: i8 = 0;
        var buffer: [40]u8 = @splat(0);
        var is_process = false;

        sys.Disable();
        const node = if (after) |a| nextNode(a) else firstOf(which);
        if (node) |n| {
            const task: *exec.Task = @fieldParentPtr("node", n);
            address = @intFromPtr(task);
            pri = n.pri;
            is_process = n.type == .process;
            copyName(&buffer, n.name);
            after = n;
        }
        sys.Enable();

        if (node == null) return;
        _ = Printf(dl, "%-8s %4d  0x%08x  %s%s\n", .{
            state,
            pri,
            address,
            @as([*:0]const u8, @ptrCast(&buffer)),
            if (is_process) " (process)" else "",
        });
    }
}

/// A name out of a list, into memory of this program's own: the node it
/// came from may be gone by the time the line is printed.
fn copyName(into: []u8, from: ?[*:0]const u8) void {
    const text = from orelse "?";
    var i: usize = 0;
    while (text[i] != 0 and i + 1 < into.len) : (i += 1) into[i] = text[i];
    into[i] = 0;
}

/// Libraries and devices are the same structure and print the same way.
fn modules(title: [*:0]const u8, which: u32) void {
    _ = Printf(dl, "\n%s\n", .{title});
    _ = dl.PutStr("name                  ver  open  pri  address\n");
    var after: ?*exec.Node = null;
    while (true) {
        var buffer: [40]u8 = @splat(0);
        var version: u16 = 0;
        var revision: u16 = 0;
        var open_cnt: u16 = 0;
        var pri: i8 = 0;
        var address: usize = 0;

        sys.Forbid();
        const node = if (after) |a| nextNode(a) else firstOf(which);
        if (node) |n| {
            const lib: *exec.Library = @fieldParentPtr("node", n);
            copyName(&buffer, n.name);
            version = lib.version;
            revision = lib.revision;
            open_cnt = lib.open_cnt;
            pri = n.pri;
            address = @intFromPtr(lib);
            after = n;
        }
        sys.Permit();

        if (node == null) return;
        _ = Printf(dl, "%-20s %2d.%-2d %4d  %3d  0x%08x\n", .{
            @as([*:0]const u8, @ptrCast(&buffer)),
            version,
            revision,
            open_cnt,
            pri,
            address,
        });
    }
}

/// A resource is a node and whatever its owner made of it: there is no
/// open count and no version to read, only the name it is opened by.
fn resources() void {
    _ = dl.PutStr("\nResources\n");
    _ = dl.PutStr("name                  pri  address\n");
    nodeList(exec.EXECLIST_RESOURCES);
}

fn ports() void {
    _ = dl.PutStr("\nPublic ports\n");
    _ = dl.PutStr("name                  pri  address\n");
    nodeList(exec.EXECLIST_PORTS);
}

fn semaphores() void {
    _ = dl.PutStr("\nPublic semaphores\n");
    _ = dl.PutStr("name                  pri  address\n");
    nodeList(exec.EXECLIST_SEMAPHORES);
}

/// What every list has in common, for the ones with nothing else worth
/// printing.
fn nodeList(which: u32) void {
    var after: ?*exec.Node = null;
    while (true) {
        var buffer: [40]u8 = @splat(0);
        var pri: i8 = 0;
        var address: usize = 0;

        sys.Forbid();
        const node = if (after) |a| nextNode(a) else firstOf(which);
        if (node) |n| {
            copyName(&buffer, n.name);
            pri = n.pri;
            address = @intFromPtr(n);
            after = n;
        }
        sys.Permit();

        if (node == null) return;
        _ = Printf(dl, "%-20s %4d  0x%08x\n", .{
            @as([*:0]const u8, @ptrCast(&buffer)),
            pri,
            address,
        });
    }
}

/// The biggest single piece of a region: MemHeader says how much is free
/// altogether, and the chunks say whether it is in one piece.
fn largestChunk(mh: *exec.MemHeader) usize {
    var most: usize = 0;
    var chunk = mh.first;
    while (chunk) |c| : (chunk = c.next) {
        if (c.bytes > most) most = c.bytes;
    }
    return most;
}

fn memory() void {
    _ = dl.PutStr("\nMemory\n");
    _ = dl.PutStr("name                           pri      free     largest\n");
    var after: ?*exec.Node = null;
    while (true) {
        var buffer: [40]u8 = @splat(0);
        var pri: i8 = 0;
        var free: usize = 0;
        var largest: usize = 0;

        sys.Forbid();
        const node = if (after) |a| nextNode(a) else firstOf(exec.EXECLIST_MEMORY);
        if (node) |n| {
            const mh: *exec.MemHeader = @fieldParentPtr("node", n);
            copyName(&buffer, n.name);
            pri = n.pri;
            free = mh.free;
            largest = largestChunk(mh);
            after = n;
        }
        sys.Permit();

        if (node == null) return;
        _ = Printf(dl, "%-29s %4d  %8d  %10d\n", .{
            @as([*:0]const u8, @ptrCast(&buffer)),
            pri,
            free,
            largest,
        });
    }
}

// --- the ROM's own ------------------------------------------------------------

fn residents() void {
    const list = sys.ResModules() orelse {
        _ = dl.PutStr("\nResidents   none: the scan has not run\n");
        return;
    };
    _ = dl.PutStr("\nResidents\n");
    _ = dl.PutStr("name                  ver  pri  type       flags\n");
    var i: usize = 0;
    while (list[i]) |tag| : (i += 1) {
        _ = Printf(dl, "%-20s %4d %4d  %-9s  %s%s%s%s\n", .{
            name(tag.name),
            tag.version,
            tag.pri,
            typeName(tag.type),
            if (tag.flags & exec.RTF_COLDSTART != 0) "coldstart " else "",
            if (tag.flags & exec.RTF_SINGLETASK != 0) "singletask " else "",
            if (tag.flags & exec.RTF_AFTERDOS != 0) "afterdos " else "",
            if (tag.flags & exec.RTF_AUTOINIT != 0) "autoinit" else "",
        });
    }
}

fn typeName(node_type: exec.NodeType) [*:0]const u8 {
    return switch (node_type) {
        .library => "library",
        .device => "device",
        .resource => "resource",
        .task => "task",
        .process => "process",
        .handler => "handler",
        .rtg_driver => "rtg driver",
        .shell => "shell",
        .msgport => "port",
        .semaphore, .signalsem => "semaphore",
        .memory => "memory",
        .interrupt => "interrupt",
        else => "-",
    };
}

/// The names of the interrupt sources, built at compile time out of the
/// SDK's own INTB_ constants: the source numbers are the chip's, and a
/// number alone says nothing about which peripheral it belongs to.
const source_names = blk: {
    const intbits = sdk.hardware.intbits;
    var names: [intbits.INTB_COUNT]?[*:0]const u8 = @splat(null);
    for (@typeInfo(intbits).@"struct".decls) |d| {
        if (!@import("std").mem.startsWith(u8, d.name, "INTB_")) continue;
        const value = @field(intbits, d.name);
        if (@TypeOf(value) != u32 or value >= intbits.INTB_COUNT) continue;
        names[value] = d.name[5..].ptr;
    }
    break :blk names;
};

fn sourceName(number: u32) [*:0]const u8 {
    if (number >= source_names.len) return "?";
    return source_names[number] orelse "-";
}

/// Every interrupt source that has anything on it: what is handling it,
/// how many servers are chained and how often it has fired.
fn interrupts() void {
    _ = dl.PutStr("\nInterrupts\n");
    _ = dl.PutStr("source  name                servers       count  first server\n");
    var number: u32 = 0;
    while (number < sdk.hardware.intbits.INTB_COUNT) : (number += 1) {
        const vector = sys.IntVector(number) orelse continue;

        var buffer: [40]u8 = @splat(0);
        var servers: u32 = 0;
        var count: u32 = 0;
        var handled = false;

        sys.Disable();
        handled = vector.handler != null;
        count = vector.count;
        var node = vector.servers.first();
        if (node) |n| copyName(&buffer, n.name);
        while (node) |n| : (node = nextNode(n)) servers += 1;
        if (handled and servers == 0) {
            if (vector.handler) |handler| copyName(&buffer, handler.node.name);
        }
        sys.Enable();

        if (servers == 0 and !handled) continue;
        _ = Printf(dl, "%6d  %-18s %7d  %10d  %s%s\n", .{
            number,
            sourceName(number),
            servers,
            count,
            @as([*:0]const u8, @ptrCast(&buffer)),
            if (handled) " (a handler, not a chain)" else "",
        });
    }
}

// --- dos's own ----------------------------------------------------------------

/// The device list: the handlers, the volumes and the assigns, which are
/// one list with three kinds of entry. It has a lock of its own.
fn handlers() void {
    _ = dl.PutStr("\nHandlers, volumes and assigns\n");
    _ = dl.PutStr("name                  kind        state    handler\n");
    const flags = dos.LDF_DEVICES | dos.LDF_VOLUMES | dos.LDF_ASSIGNS | dos.LDF_READ;
    const start = dl.LockDosList(flags) orelse return;
    var entry = dl.NextDosEntry(start, flags);
    while (entry) |e| : (entry = dl.NextDosEntry(e, flags)) {
        _ = Printf(dl, "%-20s  %-10s  %-7s  %s\n", .{
            name(e.name),
            entryKind(e.type),
            if (e.type == .device) handlerState(e) else "",
            if (e.type == .device) name(e.misc.handler.handler) else "",
        });
    }
    dl.UnLockDosList(flags);
}

/// What a device's handler is doing: running (the node has its port),
/// loaded (its code came from a file and is in memory), or neither - not
/// started, and nothing of it in memory.
fn handlerState(entry: *const dos.DosList) [*:0]const u8 {
    if (entry.task != null) return "running";
    if (entry.misc.handler.seg_list != null) return "loaded";
    return "-";
}

fn entryKind(kind: dos.DosListType) [*:0]const u8 {
    return switch (kind) {
        .device => "handler",
        .directory => "assign",
        .volume => "volume",
        .late => "late assign",
        .nonbinding => "path assign",
        else => "-",
    };
}

/// The resident segments: the commands Resident has cached, which dos
/// keeps by name and hands out from memory instead of loading.
/// seg_UC: how many are using it, or what kind of segment it is.
fn useCount(uc: i32) [*:0]const u8 {
    return switch (uc) {
        dos.CMD_SYSTEM => "system",
        dos.CMD_INTERNAL => "shell",
        dos.CMD_DISABLED => "off",
        else => countText(uc),
    };
}

var count_buffer: [12]u8 = @splat(0);

fn countText(uc: i32) [*:0]const u8 {
    var value: u32 = @intCast(if (uc < 0) 0 else uc);
    var at: usize = count_buffer.len - 1;
    count_buffer[at] = 0;
    if (value == 0) {
        at -= 1;
        count_buffer[at] = '0';
    }
    while (value != 0) {
        at -= 1;
        count_buffer[at] = '0' + @as(u8, @intCast(value % 10));
        value /= 10;
    }
    return @ptrCast(&count_buffer[at]);
}

fn segments() void {
    _ = dl.PutStr("\nResident segments\n");
    _ = dl.PutStr("name                  uses  address\n");
    // Shared: this only reads, and a command that is loading meanwhile
    // should not be held up by a listing. The lock answers with the first
    // segment, and the list walks from there.
    var segment = dl.LockSegmentList(true);
    defer dl.UnLockSegmentList();
    while (segment) |s| : (segment = s.next) {
        _ = Printf(dl, "%-20s %5s  0x%08x\n", .{
            name(s.name),
            useCount(s.uc),
            @intFromPtr(s),
        });
    }
}

// --- the counts the summary prints --------------------------------------------

fn countHandlers() u32 {
    const flags = dos.LDF_DEVICES | dos.LDF_VOLUMES | dos.LDF_ASSIGNS | dos.LDF_READ;
    const start = dl.LockDosList(flags) orelse return 0;
    defer dl.UnLockDosList(flags);
    var count: u32 = 0;
    var entry = dl.NextDosEntry(start, flags);
    while (entry) |e| : (entry = dl.NextDosEntry(e, flags)) count += 1;
    return count;
}

fn countResidents() u32 {
    const list = sys.ResModules() orelse return 0;
    var count: u32 = 0;
    while (list[count] != null) count += 1;
    return count;
}

fn countInterrupts() u32 {
    var count: u32 = 0;
    var number: u32 = 0;
    while (number < sdk.hardware.intbits.INTB_COUNT) : (number += 1) {
        const vector = sys.IntVector(number) orelse continue;
        sys.Disable();
        const in_use = vector.handler != null or vector.servers.first() != null;
        sys.Enable();
        if (in_use) count += 1;
    }
    return count;
}

fn countSegments() u32 {
    // Shared: this only reads, and a command that is loading meanwhile
    // should not be held up by a listing.
    var segment = dl.LockSegmentList(true);
    defer dl.UnLockSegmentList();
    var count: u32 = 0;
    while (segment) |s| : (segment = s.next) count += 1;
    return count;
}

/// The "$VER:" string, which `Version <file>` looks for. Nothing refers to
/// it, so it needs an export and a section of its own that program.ld
/// KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
