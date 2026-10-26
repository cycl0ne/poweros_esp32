// SPDX-License-Identifier: MPL-2.0
//! exec's lists as `s3>` and the ROM debugger both show them - the tasks,
//! the libraries, devices and resources, the public ports and semaphores,
//! and the semaphores each task holds: which nodes a listing reads, what
//! it keeps of each as a row, and the line a row becomes.
//!
//! **One walk, read two ways.** `s3>` is a task among the others: it takes
//! a list's lock, copies the rows out (`Copied`), lets go, and prints
//! after - printing waits, and under a spinlock nothing may. The debugger
//! has the machine stopped: nothing moves under it, and a lock may be held
//! by the very code it stopped, so it takes none and prints each row as it
//! is read. What it walks may also be what broke, so it reads through a
//! `Reader` that asks the chip about every address first - a node, the
//! struct around it, a name, the task a port signals - and counts the
//! nodes, so a list that points nowhere or runs in a circle ends in a line
//! saying where, not in a second fault. The shell's reader,
//! `Reader.trusted`, believes what it reads, as the lock lets it.
//!
//! **A listing** is a namespace: its `Row`, its `header`, `print` for one
//! row, and `each`, which hands every row to a sink - anything with
//! `add(row)` and `brokenOff(address)`. Nothing here takes a lock or calls
//! through a jump table; the shell takes its locks around `each`.

const sdk = @import("sdk");
const exec_base = @import("../exec_base.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const List = sdk.exec.List;
const Node = sdk.exec.Node;
const Task = sdk.exec.Task;
const Library = sdk.exec.Library;
const MsgPort = sdk.exec.MsgPort;
const SignalSemaphore = sdk.exec.SignalSemaphore;

/// How a listing reads memory.
pub const Reader = struct {
    /// Whether an address can be read without a fault; null where all of
    /// memory is believed.
    readable: ?*const fn (address: usize) bool = null,

    /// The shell's: it holds the list's lock, so what it reads is whole.
    pub const trusted: Reader = .{};

    /// Whether the `size` bytes at `address` can be read.
    pub fn can(reader: Reader, address: usize, size: usize) bool {
        const check = reader.readable orelse return true;
        if (address == 0 or address > ~@as(usize, 0) - size) return false;
        return check(address) and check(address + size - 1);
    }

    /// The `T` at `address`, if one can be there: aligned for it, and all
    /// of it readable.
    pub fn at(reader: Reader, comptime T: type, address: usize) ?*const T {
        if (address == 0 or address % @alignOf(T) != 0) return null;
        if (!reader.can(address, @sizeOf(T))) return null;
        return @ptrFromInt(address);
    }
};

/// How many nodes a walk that checks follows before it takes the list to
/// run in a circle.
pub const max_nodes = 256;

/// The `T`s on a list, head to tail, each node looked at before its link
/// is followed; `field` is the Node in `T` the list links.
pub fn Walk(comptime T: type, comptime field: []const u8) type {
    return struct {
        const Self = @This();

        reader: Reader,
        next_node: ?*Node,
        left: u32 = max_nodes,
        /// The node it broke off at - one that could not be read, or the
        /// one past `max_nodes`; 0 while the list is whole.
        broken_at: usize = 0,

        pub fn next(walk: *Self) ?*const T {
            const address = @intFromPtr(walk.next_node orelse return null);
            const node = walk.reader.at(Node, address) orelse return walk.breakOff(address);
            // The tail sentinel: its successor (lh_Tail) is null.
            const succ = node.succ orelse {
                walk.next_node = null;
                return null;
            };
            if (walk.reader.readable != null) {
                if (walk.left == 0) return walk.breakOff(address);
                walk.left -= 1;
            }
            const item = walk.reader.at(T, address -% @offsetOf(T, field)) orelse return walk.breakOff(address);
            walk.next_node = succ;
            return item;
        }

        fn breakOff(walk: *Self, address: usize) ?*const T {
            walk.broken_at = address;
            walk.next_node = null;
            return null;
        }
    };
}

/// A walk over `list`'s `T`s.
pub fn walkOf(comptime T: type, comptime field: []const u8, reader: Reader, list: *const List) Walk(T, field) {
    return .{ .reader = reader, .next_node = list.head };
}

/// A walk over the bare nodes of `list`: a Node's link is at its start.
pub fn walkNodes(reader: Reader, list: *const List) Walk(Node, "succ") {
    return walkOf(Node, "succ", reader, list);
}

/// How many nodes are on `list`, as far as it can be read.
pub fn countOf(reader: Reader, list: *const List) u32 {
    var nodes = walkNodes(reader, list);
    var count: u32 = 0;
    while (nodes.next()) |_| count += 1;
    return count;
}

/// A name copied into `into`, cut to fit and NUL-terminated: "?" for
/// none, and cut where the reader can read no further.
pub fn nameInto(reader: Reader, into: []u8, from: ?[*:0]const u8) [*:0]const u8 {
    const text = from orelse "?";
    var length: usize = 0;
    while (length + 1 < into.len and reader.can(@intFromPtr(text) + length, 1) and text[length] != 0) : (length += 1) {
        into[length] = text[length];
    }
    into[length] = 0;
    return @ptrCast(into.ptr);
}

/// An enum value's name, "?" for one the enum does not name.
pub fn enumName(comptime E: type, value: E) [*:0]const u8 {
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (@intFromEnum(value) == field.value) return field.name;
    }
    return "?";
}

/// The line for a list that could be read no further.
pub fn printBrokenOff(out: anytype, address: usize) void {
    out.print("... the list breaks off at 0x%08zx\n", .{address});
}

/// The task at `address`, if one can be read there.
fn taskAt(reader: Reader, address: ?*const anyopaque) ?*const Task {
    return reader.at(Task, @intFromPtr(address orelse return null));
}

/// A listing's rows copied out while a lock is held, to print once it is
/// let go; past `capacity` they are only counted.
pub fn Copied(comptime Listing: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        rows: [capacity]Listing.Row = undefined,
        count: usize = 0,
        more: u32 = 0,
        broken_at: usize = 0,

        pub fn add(copied: *Self, row: *const Listing.Row) void {
            if (copied.count == capacity) {
                copied.more += 1;
                return;
            }
            copied.rows[copied.count] = row.*;
            copied.count += 1;
        }

        pub fn brokenOff(copied: *Self, address: usize) void {
            if (copied.broken_at == 0) copied.broken_at = address;
        }

        /// The header and the rows, or the listing's `none` when there are
        /// none; then how many more there were.
        pub fn print(copied: *const Self, out: anytype) void {
            if (@hasDecl(Listing, "none")) {
                if (copied.count == 0 and copied.more == 0 and copied.broken_at == 0) return out.print(Listing.none, .{});
            }
            out.print(Listing.header, .{});
            for (copied.rows[0..copied.count]) |*row| Listing.print(out, row);
            if (copied.more != 0) out.print("... and %u more\n", .{copied.more});
            if (copied.broken_at != 0) printBrokenOff(out, copied.broken_at);
        }
    };
}

/// Every task with `take`: each core's running one first, with its core,
/// then the ready ones and the waiting ones.
fn eachTask(reader: Reader, base: *const ExecBase, sink: anytype, comptime take: anytype) void {
    const cores: usize = @min(base.cores_running, exec_base.max_cores);
    for (base.cpus[0..cores], 0..) |*cpu, core| {
        if (taskAt(reader, cpu.this_task)) |task| take(reader, task, @intCast(core), sink);
    }
    for ([_]*const List{ &base.task_ready, &base.task_wait }) |list| {
        var queue = walkOf(Task, "node", reader, list);
        while (queue.next()) |task| take(reader, task, 0, sink);
        if (queue.broken_at != 0) sink.brokenOff(queue.broken_at);
    }
}

// --- the listings -----------------------------------------------------------

/// `tasks`: what each core runs, then the ready and waiting tasks - with
/// the core a running one is on and the cores each is pinned to.
pub const tasks = struct {
    pub const Row = struct {
        address: usize,
        name: [17]u8,
        node_type: sdk.exec.NodeType,
        pri: i8,
        state: sdk.exec.TaskState,
        /// The core it runs on, for a running one.
        core: u8,
        /// The cores it may run on: its TF_CORE0 to TF_CORE3 flags.
        pins: u8,
        sig_wait: u32,
        sig_recvd: u32,
        sig_except: u32,
        user_data: usize,
        except_data: usize,
    };

    pub const header = "task        name             type     pri  state  core  pin  wait      recvd     except    userdata  excdata\n";

    pub fn each(reader: Reader, base: *const ExecBase, sink: anytype) void {
        eachTask(reader, base, sink, add);
    }

    fn add(reader: Reader, task: *const Task, core: u8, sink: anytype) void {
        var row: Row = .{
            .address = @intFromPtr(task),
            .name = undefined,
            .node_type = task.node.type,
            .pri = task.node.pri,
            .state = task.state,
            .core = core,
            .pins = task.flags & sdk.exec.TF_CORES,
            .sig_wait = task.sig_wait,
            .sig_recvd = task.sig_recvd,
            .sig_except = task.sig_except,
            .user_data = @intFromPtr(task.user_data),
            .except_data = @intFromPtr(task.except_data),
        };
        _ = nameInto(reader, &row.name, task.node.name orelse "");
        sink.add(&row);
    }

    pub fn print(out: anytype, row: *const Row) void {
        var core_text: [2:0]u8 = .{ '0' + row.core % 10, 0 };
        const core: [*:0]const u8 = if (row.state != .run) "" else &core_text;
        // The digits of the cores it is pinned to.
        var pin_text: [4:0]u8 = @splat(0);
        var digits: usize = 0;
        for (0..4) |number| {
            if (row.pins & sdk.exec.coreFlag(@intCast(number)) == 0) continue;
            pin_text[digits] = '0' + @as(u8, @intCast(number));
            digits += 1;
        }
        const pin: [*:0]const u8 = &pin_text;
        out.print("0x%08zx  %-16s %-7s %4d  %-6s %-4s  %-3s  %08x  %08x  %08x  %08zx  %08zx\n", .{
            row.address,                                @as([*:0]const u8, @ptrCast(&row.name)),
            enumName(sdk.exec.NodeType, row.node_type), row.pri,
            enumName(sdk.exec.TaskState, row.state),    core,
            pin,                                        row.sig_wait,
            row.sig_recvd,                              row.sig_except,
            row.user_data,                              row.except_data,
        });
    }

    /// How often the cores have dispatched and idled, all told.
    pub const Totals = struct { dispatches: u32 = 0, idle_rounds: u32 = 0 };

    pub fn totals(base: *const ExecBase) Totals {
        var sum: Totals = .{};
        const cores: usize = @min(base.cores_running, exec_base.max_cores);
        for (base.cpus[0..cores]) |*cpu| {
            sum.dispatches +%= cpu.disp_count;
            sum.idle_rounds +%= cpu.idle_count;
        }
        return sum;
    }

    pub fn printTotals(out: anytype, sum: Totals) void {
        out.print("dispatches %u, idle loops %u\n", .{ sum.dispatches, sum.idle_rounds });
    }
};

/// `libs` and `devs`: the bases on exec's library list or its device list.
pub fn Bases(comptime list_field: []const u8) type {
    return struct {
        pub const Row = struct {
            address: usize,
            name: [23]u8,
            version: u16,
            revision: u16,
            open_cnt: u16,
            flags: u8,
        };

        pub const header = "base        name                   version  open  flags\n";

        pub fn each(reader: Reader, base: *const ExecBase, sink: anytype) void {
            var bases = walkOf(Library, "node", reader, &@field(base, list_field));
            while (bases.next()) |lib| {
                var row: Row = .{ .address = @intFromPtr(lib), .name = undefined, .version = lib.version, .revision = lib.revision, .open_cnt = lib.open_cnt, .flags = lib.flags };
                _ = nameInto(reader, &row.name, lib.node.name);
                sink.add(&row);
            }
            if (bases.broken_at != 0) sink.brokenOff(bases.broken_at);
        }

        pub fn print(out: anytype, row: *const Row) void {
            const pending = if (row.flags & sdk.exec.LIBF_DELEXP != 0) "  expunge pending" else "";
            out.print("0x%08zx  %-22s %3d.%-4d %4d  0x%02x%s\n", .{ row.address, @as([*:0]const u8, @ptrCast(&row.name)), row.version, row.revision, row.open_cnt, row.flags, pending });
        }
    };
}

pub const libraries = Bases("lib_list");
pub const devices = Bases("device_list");

/// `resources`: exec's resource list.
pub const resources = struct {
    pub const Row = struct {
        address: usize,
        name: [23]u8,
        pri: i8,
    };

    pub const header = "base        name                    pri\n";

    pub fn each(reader: Reader, base: *const ExecBase, sink: anytype) void {
        var nodes = walkNodes(reader, &base.resource_list);
        while (nodes.next()) |node| {
            var row: Row = .{ .address = @intFromPtr(node), .name = undefined, .pri = node.pri };
            _ = nameInto(reader, &row.name, node.name);
            sink.add(&row);
        }
        if (nodes.broken_at != 0) sink.brokenOff(nodes.broken_at);
    }

    pub fn print(out: anytype, row: *const Row) void {
        out.print("0x%08zx  %-22s %4d\n", .{ row.address, @as([*:0]const u8, @ptrCast(&row.name)), row.pri });
    }
};

/// `ports`: the public message ports, who they signal and what is queued.
pub const ports = struct {
    pub const Row = struct {
        address: usize,
        name: [15]u8,
        owner: [15]u8,
        pri: i8,
        action: u8,
        sig_bit: u8,
        queued: u32,
    };

    pub const header = "port        name            pri  action   sig  task            queued\n";

    pub fn each(reader: Reader, base: *const ExecBase, sink: anytype) void {
        var public = walkOf(MsgPort, "node", reader, &base.port_list);
        while (public.next()) |port| {
            const action = port.flags & sdk.exec.PF_ACTION;
            var row: Row = .{ .address = @intFromPtr(port), .name = undefined, .owner = undefined, .pri = port.node.pri, .action = action, .sig_bit = port.sig_bit, .queued = countOf(reader, &port.msg_list) };
            _ = nameInto(reader, &row.name, port.node.name);
            const owner: ?[*:0]const u8 = if (action != sdk.exec.PA_SIGNAL or port.sig_task == null)
                "-"
            else if (taskAt(reader, port.sig_task)) |task|
                task.node.name orelse ""
            else
                "?";
            _ = nameInto(reader, &row.owner, owner);
            sink.add(&row);
        }
        if (public.broken_at != 0) sink.brokenOff(public.broken_at);
    }

    pub fn print(out: anytype, row: *const Row) void {
        const action_name = switch (row.action) {
            sdk.exec.PA_SIGNAL => "signal",
            sdk.exec.PA_SOFTINT => "softint",
            else => "ignore",
        };
        out.print("0x%08zx  %-14s %4d  %-7s %4d  %-14s %d\n", .{
            row.address,                              @as([*:0]const u8, @ptrCast(&row.name)), row.pri, action_name, row.sig_bit,
            @as([*:0]const u8, @ptrCast(&row.owner)), row.queued,
        });
    }
};

/// `sems`: the public semaphores, who holds them and how many wait.
pub const semaphores = struct {
    pub const Row = struct {
        address: usize,
        name: [15]u8,
        owner: [15]u8,
        nest_count: u32,
        waiting: u32,
    };

    pub const header = "semaphore   name            owner           nest  waiting\n";

    pub fn each(reader: Reader, base: *const ExecBase, sink: anytype) void {
        var public = walkOf(SignalSemaphore, "link", reader, &base.sem_list);
        while (public.next()) |sem| {
            var row: Row = .{ .address = @intFromPtr(sem), .name = undefined, .owner = undefined, .nest_count = sem.nestCount(), .waiting = countOf(reader, &sem.wait_queue) };
            _ = nameInto(reader, &row.name, sem.link.name);
            const owner: ?[*:0]const u8 = if (row.nest_count == 0)
                "-"
            else if (sem.state & sdk.exec.SEMF_EXCLUSIVE == 0)
                "(shared)"
            else if (taskAt(reader, sem.owner)) |task|
                task.node.name orelse ""
            else
                "?";
            _ = nameInto(reader, &row.owner, owner);
            sink.add(&row);
        }
        if (public.broken_at != 0) sink.brokenOff(public.broken_at);
    }

    pub fn print(out: anytype, row: *const Row) void {
        out.print("0x%08zx  %-14s  %-14s %5u  %d\n", .{
            row.address,    @as([*:0]const u8, @ptrCast(&row.name)), @as([*:0]const u8, @ptrCast(&row.owner)),
            row.nest_count, row.waiting,
        });
    }
};

/// `locks`: from every task's tables of what it holds (`Task.holds`, and
/// Procure's grants in `Task.bid_holds`), the semaphore, its name for a
/// public one, how often and whether shared - and the one each task waits
/// for.
pub const locks = struct {
    /// One line: a hold, a wait, or holds a task's table had no room for.
    pub const Row = struct {
        task: [21]u8,
        id: u32,
        semaphore: usize,
        name: [17]u8,
        count: u32,
        kind: Kind,
    };

    pub const Kind = enum { exclusive, shared, waits, lost };

    pub const header = "task                   #id  semaphore   name              holds\n";
    pub const none = "no task holds or waits for a semaphore\n";

    pub fn each(reader: Reader, base: *const ExecBase, sink: anytype) void {
        eachTask(reader, base, sink, take);
    }

    /// A task's holds, its wait and its lost holds as rows.
    fn take(reader: Reader, task: *const Task, _: u8, sink: anytype) void {
        for ([_][]const sdk.exec.SemaphoreHold{ &task.holds, &task.bid_holds }) |table| {
            for (table) |*hold| {
                const sem = hold.semaphore orelse continue;
                add(reader, sink, task, @intFromPtr(sem), hold.count, if (hold.shared) .shared else .exclusive);
            }
        }
        if (task.waiting_for) |sem| add(reader, sink, task, @intFromPtr(sem), 0, .waits);
        const lost = task.holds_lost +| task.bid_holds_lost;
        if (lost != 0) add(reader, sink, task, 0, lost, .lost);
    }

    fn add(reader: Reader, sink: anytype, task: *const Task, semaphore: usize, times: u32, kind: Kind) void {
        var row: Row = .{ .task = undefined, .id = task.id, .semaphore = semaphore, .name = undefined, .count = times, .kind = kind };
        _ = nameInto(reader, &row.task, task.node.name);
        const sem_name: ?[*:0]const u8 = if (semaphore == 0)
            "-"
        else if (reader.at(SignalSemaphore, semaphore)) |sem|
            sem.link.name orelse "-"
        else
            "?";
        _ = nameInto(reader, &row.name, sem_name);
        sink.add(&row);
    }

    pub fn print(out: anytype, row: *const Row) void {
        const task: [*:0]const u8 = @ptrCast(&row.task);
        const sem_name: [*:0]const u8 = @ptrCast(&row.name);
        const address: u32 = @truncate(row.semaphore);
        switch (row.kind) {
            .exclusive => out.print("%-20s %5u  0x%08x  %-16s  %u exclusive\n", .{ task, row.id, address, sem_name, row.count }),
            .shared => out.print("%-20s %5u  0x%08x  %-16s  %u shared\n", .{ task, row.id, address, sem_name, row.count }),
            .waits => out.print("%-20s %5u  0x%08x  %-16s  waits for it\n", .{ task, row.id, address, sem_name }),
            .lost => out.print("%-20s %5u  %u more holds its table had no room for\n", .{ task, row.id, row.count }),
        }
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

/// A sink that keeps the rows, as the debugger's would print them.
fn Kept(comptime Row: type) type {
    return struct {
        rows: [8]Row = undefined,
        count: usize = 0,
        broken_at: usize = 0,

        pub fn add(kept: *@This(), row: *const Row) void {
            kept.rows[kept.count] = row.*;
            kept.count += 1;
        }

        pub fn brokenOff(kept: *@This(), address: usize) void {
            kept.broken_at = address;
        }
    };
}

/// What the tests let a checked reader read: the nodes they made, and the
/// names in the test binary - anything but `refused`.
var refused: usize = 0;

fn testReadable(address: usize) bool {
    return address != refused;
}

const checked: Reader = .{ .readable = testReadable };

/// `node` added at the end of `list`, as AddTail does.
fn link(list: *List, node: *Node) void {
    node.pred = list.tail_pred;
    node.succ = list.tailNode();
    list.tail_pred.?.succ = node;
    list.tail_pred = node;
}

test "a walk reads every node, trusted or checked" {
    var list: List = .{};
    list.init(.unknown);
    var nodes: [3]Node = .{ .{ .name = "one" }, .{ .name = "two" }, .{ .name = "three" } };
    for (&nodes) |*node| link(&list, node);
    try testing.expectEqual(@as(u32, 3), countOf(.trusted, &list));
    var walk = walkNodes(checked, &list);
    for (&nodes) |*node| try testing.expectEqual(@as(?*const Node, node), walk.next());
    try testing.expect(walk.next() == null);
    try testing.expectEqual(@as(usize, 0), walk.broken_at);
}

test "a checked walk breaks off at a node it cannot read, and at a circle" {
    var list: List = .{};
    list.init(.unknown);
    var nodes: [3]Node = .{ .{}, .{}, .{} };
    for (&nodes) |*node| link(&list, node);
    refused = @intFromPtr(&nodes[1]);
    defer refused = 0;
    var walk = walkNodes(checked, &list);
    try testing.expectEqual(@as(?*const Node, &nodes[0]), walk.next());
    try testing.expect(walk.next() == null);
    try testing.expectEqual(@intFromPtr(&nodes[1]), walk.broken_at);
    try testing.expect(walk.next() == null);

    // The last node pointing back at the first: a list that never ends.
    refused = 0;
    nodes[2].succ = &nodes[0];
    var circle = walkNodes(checked, &list);
    var seen: u32 = 0;
    while (circle.next()) |_| seen += 1;
    try testing.expectEqual(@as(u32, max_nodes), seen);
    try testing.expect(circle.broken_at != 0);
}

test "a name is cut to fit, and where it can be read no further" {
    var into: [6]u8 = undefined;
    try testing.expectEqualStrings("seria", std.mem.span(nameInto(.trusted, &into, "serial.device")));
    try testing.expectEqualStrings("?", std.mem.span(nameInto(.trusted, &into, null)));
    const text: [*:0]const u8 = "abcdef";
    refused = @intFromPtr(text) + 2;
    defer refused = 0;
    try testing.expectEqualStrings("ab", std.mem.span(nameInto(checked, &into, text)));
}

test "the bases' rows, and a port's owner and queue" {
    var base: ExecBase = undefined;
    base.lib_list.init(.library);
    var libs: [2]Library = .{
        .{ .node = .{ .name = "exec.library" }, .version = 5, .revision = 3, .open_cnt = 7 },
        .{ .node = .{ .name = "dos.library" }, .version = 1, .revision = 6 },
    };
    for (&libs) |*lib| link(&base.lib_list, &lib.node);
    var kept: Kept(libraries.Row) = .{};
    libraries.each(checked, &base, &kept);
    try testing.expectEqual(@as(usize, 2), kept.count);
    try testing.expectEqualStrings("exec.library", std.mem.span(@as([*:0]const u8, @ptrCast(&kept.rows[0].name))));
    try testing.expectEqual(@as(u16, 7), kept.rows[0].open_cnt);
    try testing.expectEqual(@as(u16, 6), kept.rows[1].revision);

    var owner: Task = .{ .node = .{ .name = "input" } };
    var port: MsgPort = .{ .node = .{ .name = "IDCMP" }, .sig_task = &owner };
    port.msg_list.init(.message);
    var messages: [2]Node = .{ .{}, .{} };
    for (&messages) |*message| link(&port.msg_list, message);
    base.port_list.init(.msgport);
    link(&base.port_list, &port.node);
    var kept_ports: Kept(ports.Row) = .{};
    ports.each(checked, &base, &kept_ports);
    try testing.expectEqual(@as(usize, 1), kept_ports.count);
    try testing.expectEqualStrings("input", std.mem.span(@as([*:0]const u8, @ptrCast(&kept_ports.rows[0].owner))));
    try testing.expectEqual(@as(u32, 2), kept_ports.rows[0].queued);

    // The task it signals where nothing can be read: named "?", not
    // followed.
    refused = @intFromPtr(&owner);
    defer refused = 0;
    kept_ports = .{};
    ports.each(checked, &base, &kept_ports);
    try testing.expectEqualStrings("?", std.mem.span(@as([*:0]const u8, @ptrCast(&kept_ports.rows[0].owner))));
}
