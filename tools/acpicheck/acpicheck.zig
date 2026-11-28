// SPDX-License-Identifier: MPL-2.0
//! acpicheck: loads a machine's tables of bytecode - a folder C:Acpi
//! saved them to (`Acpi TO`) - into a namespace on the host, with
//! acpi.resource's own interpreter, and says what loading them found;
//! with --run it then runs the firmware's methods as the resource starts
//! the machine, and says what each answered and what it touched.
//!
//! usage: acpicheck [--namespace] [--acpiexec | --run] <folder>
//!
//! The tables are loaded in the order the resource loads them: DSDT.aml,
//! then SSDT1.aml, SSDT2.aml and on, then PSDT1.aml and on, each as long
//! as its header says, the code at its own level run as it loads. Every
//! table in the folder is there for what a method asks for by its
//! signature (LoadTable, a DataTableRegion). A line for each table says
//! how many names it made, how many terms outside a method it holds, how
//! many of its names were there already, how many of its scopes were not,
//! and how many of its terms could not be read; the interpreter's own
//! lines come before it, and a line for the whole after the last, with
//! each place the code at the tables' own level touched as they loaded.
//!
//! The machine is the host's: each address space is memory that reads 0
//! until it is written, each function's configuration space its own; the
//! clock moves only as the interpreter looks at it (100 microseconds a
//! look), sleeps or stalls, so that nothing waits.
//!
//! --run then does what the resource's start does - memory, ports, PCI's
//! configuration and the clock's memory connected, `\_PIC(1)`, `\_INI`
//! and `\_SB._INI`, each device's, processor's and thermal zone's `_STA`
//! and `_INI` in the namespace's order (a child's only where its parent
//! is present or functioning), `\_SB._OSC` asking for no capability - and
//! then evaluates every `_CRS`, `_PRT`, `_CST` and `_CPC`, each thermal
//! zone's `_TMP`, `\_S5` and `\_PTS(5)`. Each evaluation is a line with its
//! path; the interpreter's lines follow, then what it answered, each
//! place it touched - `mem`, `io`, `pci` segment:bus:device.function+
//! offset, `cmos`, `ec`, any other space by its number - read (`r`) or
//! written (`w`) at its width, and how often, what it waited for, and the
//! notifications it queued. After the last, every place any of them
//! touched, by space.
//!
//! --acpiexec instead does what ACPICA's acpiexec does before it dumps
//! its namespace: the spaces it connects - the embedded controllers'
//! first, then SMBus, CMOS, PCI BAR target, IPMI, GPIO, the generic
//! serial bus, PCC, PRM, fixed hardware, 0x80 and 0xE4; PCI's
//! configuration never - connected, and every device's `_STA` asked as
//! its own checks ask them (a device neither present nor functioning
//! keeps those below it from being asked), so that what `_REG` and
//! `_STA` set is the same in both dumps.
//!
//! With --namespace the namespace follows, a name a line in its order -
//! how deep, the name, what it holds and what that is - in the layout of
//! acpiexec's ("namespace"), so that the two can be compared.
//!
//! The exit code is 0 when every term could be read and every evaluation
//! ran to its end, 1 when an opcode was not known, a term could not be
//! read or an evaluation ended with an error, and 2 when the folder could
//! not be loaded at all.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const sdk = @import("sdk");
const hardware_acpi = sdk.hardware.acpi;
const acpi = @import("acpi");
const AcpiBase = acpi.AcpiBase;
const namespace = acpi.namespace;
const Node = namespace.Node;
const object = acpi.object;
const Object = object.Object;
const interpreter = acpi.interpreter;
const Item = interpreter.Item;

/// A byte of an address space: the space, the function whose
/// configuration space it is in, its address.
const Key = struct {
    space: u8,
    function: u64,
    address: u64,
};

/// A place an evaluation touched: where, how wide, read or written.
const Touch = struct {
    space: u8,
    function: u64,
    address: u64,
    width: u8,
    write: bool,
};

/// Each place touched, and how often.
const Places = std.AutoArrayHashMapUnmanaged(Touch, u32);

/// The interpreter's machine on the host.
const Tool = struct {
    acpi: AcpiBase = .{ .lib = undefined, .sys_base = undefined, .machine = &machine },
    allocator: mem.Allocator,
    out: *std.ArrayList(u8),
    /// Every table in the folder.
    tables: []const []const u8 = &.{},
    /// In units of 100 nanoseconds.
    clock: u64 = 0,
    /// What the evaluation running has waited for, in microseconds.
    waited: u64 = 0,
    bytes: std.AutoHashMapUnmanaged(Key, u8) = .empty,
    /// What the evaluation running touched, and what all of them did.
    touched: Places = .empty,
    all: Places = .empty,
    evaluations: u32 = 0,
    /// The evaluations that ended with an error.
    failed: u32 = 0,
};

const machine = acpi.machine.Machine{
    .allocate = allocate,
    .free = free,
    .log = log,
    .lock = lock,
    .unlock = unlock,
    .time = time,
    .sleep = sleep,
    .stall = stall,
    .findTable = findTable,
    .access = access,
};

fn toolOf(ab: *AcpiBase) *Tool {
    return @fieldParentPtr("acpi", ab);
}

fn allocate(ab: *AcpiBase, bytes: usize) ?[*]u8 {
    const block = toolOf(ab).allocator.alignedAlloc(u8, .@"16", bytes) catch return null;
    return block.ptr;
}

fn free(ab: *AcpiBase, memory: [*]u8, bytes: usize) void {
    const aligned: [*]align(16) u8 = @alignCast(memory);
    toolOf(ab).allocator.free(aligned[0..bytes]);
}

/// One task, nothing to lock against.
fn lock(_: *AcpiBase, _: bool) void {}
fn unlock(_: *AcpiBase) void {}

/// What a look at the clock moves it on by: 100 microseconds.
const LOOK = 1000;

fn time(ab: *AcpiBase) u64 {
    const tool = toolOf(ab);
    tool.clock += LOOK;
    return tool.clock;
}

fn sleep(ab: *AcpiBase, milliseconds: u32) void {
    const tool = toolOf(ab);
    tool.clock += @as(u64, milliseconds) * 10_000;
    tool.waited += @as(u64, milliseconds) * 1000;
}

fn stall(ab: *AcpiBase, microseconds: u32) void {
    const tool = toolOf(ab);
    tool.clock += @as(u64, microseconds) * 10;
    tool.waited += microseconds;
}

fn findTable(ab: *AcpiBase, signature: *const [4]u8, oem_id: []const u8, oem_table_id: []const u8) ?[]const u8 {
    for (toolOf(ab).tables) |code| {
        if (!mem.eql(u8, code[0..4], signature)) continue;
        if (!acpi.machine.idMatches(code[10..16], oem_id) or !acpi.machine.idMatches(code[16..24], oem_table_id)) continue;
        return code;
    }
    return null;
}

fn access(ab: *AcpiBase, request: *const acpi.machine.Access, value: *u64) bool {
    const tool = toolOf(ab);
    const pci = request.pci;
    const function: u64 = if (request.space != hardware_acpi.SPACE_PCI_CONFIG) 0 else @as(u64, pci.segment) << 24 | @as(u64, pci.bus) << 16 | @as(u64, pci.device) << 8 | pci.function;
    var index: u8 = 0;
    if (request.write) {
        while (index < request.width) : (index += 1) {
            const key: Key = .{ .space = request.space, .function = function, .address = request.address +% index };
            tool.bytes.put(tool.allocator, key, @truncate(value.* >> @intCast(8 * @as(u32, index)))) catch return false;
        }
    } else {
        var read: u64 = 0;
        while (index < request.width) : (index += 1) {
            const key: Key = .{ .space = request.space, .function = function, .address = request.address +% index };
            const byte: u64 = tool.bytes.get(key) orelse 0;
            read |= byte << @intCast(8 * @as(u32, index));
        }
        value.* = read;
    }
    const touch: Touch = .{ .space = request.space, .function = function, .address = request.address, .width = request.width, .write = request.write };
    count(tool, &tool.touched, touch) catch return false;
    count(tool, &tool.all, touch) catch return false;
    return true;
}

fn count(tool: *Tool, places: *Places, touch: Touch) !void {
    const entry = try places.getOrPut(tool.allocator, touch);
    if (!entry.found_existing) entry.value_ptr.* = 0;
    entry.value_ptr.* += 1;
}

/// A line of the interpreter's: its RawDoFmt format with the values its
/// stream packs, the level's mark at its start written as the log writes
/// a level that is not information.
fn log(ab: *AcpiBase, format: [*:0]const u8, stream: ?*const anyopaque) void {
    const tool = toolOf(ab);
    formatInto(tool.allocator, tool.out, mem.span(format), @ptrCast(stream)) catch {};
}

fn formatInto(allocator: mem.Allocator, out: *std.ArrayList(u8), format: []const u8, stream: ?[*]const u8) !void {
    var text = format;
    if (text.len >= 2 and text[0] == sdk.exec.log.LOG_MARK) {
        try out.appendSlice(allocator, switch (text[1]) {
            '1' => "E: ",
            '2' => "W: ",
            else => "",
        });
        text = text[2..];
    }
    var at: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const char = text[index];
        if (char != '%') {
            try out.append(allocator, char);
            continue;
        }
        index += 1;
        var left = false;
        if (index < text.len and text[index] == '-') {
            left = true;
            index += 1;
        }
        var width: usize = 0;
        var zeros = false;
        if (index < text.len and text[index] == '0') zeros = true;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) width = width * 10 + (text[index] - '0');
        var long = false;
        if (index < text.len and (text[index] == 'l' or text[index] == 'z')) {
            long = text[index] == 'l' or @sizeOf(usize) == 8;
            index += 1;
        }
        if (index >= text.len) break;
        const conversion = text[index];
        var piece: [64]u8 = undefined;
        const shown: []const u8 = switch (conversion) {
            '%' => "%",
            's' => blk: {
                const address = readValue(usize, stream.?, &at);
                if (address == 0) break :blk "(null)";
                const string: [*:0]const u8 = @ptrFromInt(address);
                break :blk mem.span(string);
            },
            'c' => blk: {
                piece[0] = @truncate(readValue(u32, stream.?, &at));
                break :blk piece[0..1];
            },
            'd', 'u', 'x', 'X' => blk: {
                const value: u64 = if (long) readValue(u64, stream.?, &at) else readValue(u32, stream.?, &at);
                break :blk switch (conversion) {
                    'd' => std.fmt.bufPrint(&piece, "{d}", .{if (long) @as(i64, @bitCast(value)) else @as(i32, @bitCast(@as(u32, @truncate(value))))}) catch unreachable,
                    'u' => std.fmt.bufPrint(&piece, "{d}", .{value}) catch unreachable,
                    'x' => std.fmt.bufPrint(&piece, "{x}", .{value}) catch unreachable,
                    else => std.fmt.bufPrint(&piece, "{X}", .{value}) catch unreachable,
                };
            },
            else => "",
        };
        if (!left) try pad(allocator, out, shown.len, width, if (zeros) '0' else ' ');
        try out.appendSlice(allocator, shown);
        if (left) try pad(allocator, out, shown.len, width, ' ');
    }
}

fn readValue(comptime T: type, stream: [*]const u8, at: *usize) T {
    const value = mem.readInt(T, stream[at.*..][0..@sizeOf(T)], @import("builtin").cpu.arch.endian());
    at.* += @sizeOf(T);
    return value;
}

fn pad(allocator: mem.Allocator, out: *std.ArrayList(u8), length: usize, width: usize, char: u8) !void {
    var counted = length;
    while (counted < width) : (counted += 1) try out.append(allocator, char);
}

fn put(tool: *Tool, text: []const u8) !void {
    try tool.out.appendSlice(tool.allocator, text);
}

fn print(tool: *Tool, comptime format: []const u8, args: anytype) !void {
    try tool.out.print(tool.allocator, format, args);
}

fn usage() noreturn {
    std.debug.print("usage: acpicheck [--namespace] [--acpiexec | --run] <folder>\n", .{});
    std.process.exit(2);
}

const Mode = enum { load, acpiexec, run };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var dump = false;
    var mode: Mode = .load;
    var folder_path: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (mem.eql(u8, arg, "--namespace")) {
            dump = true;
        } else if (mem.eql(u8, arg, "--run") and mode == .load) {
            mode = .run;
        } else if (mem.eql(u8, arg, "--acpiexec") and mode == .load) {
            mode = .acpiexec;
        } else if (folder_path == null and arg.len > 0 and arg[0] != '-') {
            folder_path = arg;
        } else usage();
    }
    const path = folder_path orelse usage();
    var folder = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        std.debug.print("acpicheck: {s}: {t}\n", .{ path, err });
        std.process.exit(2);
    };
    defer folder.close(io);

    var out: std.ArrayList(u8) = .empty;
    var tool: Tool = .{ .allocator = init.gpa, .out = &out };
    tool.tables = readTables(io, arena, folder) catch |err| {
        std.debug.print("acpicheck: {s}: {t}\n", .{ path, err });
        std.process.exit(2);
    };
    const ab = &tool.acpi;
    if (!namespace.make(ab)) {
        std.debug.print("acpicheck: no memory for the namespace\n", .{});
        std.process.exit(2);
    }

    // The DSDT, then each SSDT and each PSDT by its number.
    var index: u16 = 0;
    const dsdt = folder.readFileAlloc(io, "DSDT.aml", arena, .limited(hardware_acpi.MOST_TABLE_BYTES)) catch |err| {
        std.debug.print("acpicheck: {s}/DSDT.aml: {t}\n", .{ path, err });
        std.process.exit(2);
    };
    try loadOne(&tool, dsdt, "DSDT", &index, 1);
    for ([_]*const [4]u8{ "SSDT", "PSDT" }) |signature| {
        var place: u16 = 1;
        while (true) : (place += 1) {
            var name_buffer: [16]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buffer, "{s}{d}.aml", .{ signature, place });
            const code = folder.readFileAlloc(io, name, arena, .limited(hardware_acpi.MOST_TABLE_BYTES)) catch |err| switch (err) {
                error.FileNotFound => break,
                else => {
                    std.debug.print("acpicheck: {s}/{s}: {t}\n", .{ path, name, err });
                    std.process.exit(2);
                },
            };
            try loadOne(&tool, code, signature, &index, place);
        }
    }
    const sum = ab.loaded;
    try print(&tool, "{d} tables, {d} names; {d} terms outside a method; {d} defined again, {d} not there, {d} not known, {d} broken\n", .{
        ab.tables, sum.names, sum.code, sum.again, sum.missing, sum.unknown, sum.broken,
    });
    // What the code at the tables' own level touched as they loaded.
    try showTouched(&tool);
    try showNotices(&tool);
    switch (mode) {
        .load => {},
        .acpiexec => {
            for (ACPIEXEC_SPACES) |space| acpi.region.connectSpace(ab, space);
            if (ab.root) |root| askStatus(&tool, root);
        },
        .run => try runStart(&tool),
    }
    try showNotices(&tool);
    if (dump) {
        try put(&tool, "ACPI Namespace (from Namespace Root):\n");
        try dumpNamespace(&tool);
    }
    try Io.File.stdout().writeStreamingAll(io, out.items);
    std.process.exit(if (sum.unknown + sum.broken + tool.failed == 0) 0 else 1);
}

/// Every table in `folder`: each `.aml` file whose header holds, in the
/// order of their names, each as long as its header says.
fn readTables(io: Io, arena: mem.Allocator, folder: Io.Dir) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var walker = folder.iterate();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !mem.endsWith(u8, entry.name, ".aml")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    mem.sort([]const u8, names.items, {}, nameBefore);
    var tables: std.ArrayList([]const u8) = .empty;
    for (names.items) |name| {
        const code = folder.readFileAlloc(io, name, arena, .limited(hardware_acpi.MOST_TABLE_BYTES)) catch continue;
        if (code.len < 36) continue;
        const length = mem.readInt(u32, code[4..8], .little);
        if (length < 36 or length > code.len) continue;
        try tables.append(arena, code[0..length]);
    }
    return tables.items;
}

fn nameBefore(_: void, one: []const u8, other: []const u8) bool {
    return mem.order(u8, one, other) == .lt;
}

/// `code`, the `place`th table of `signature`, loaded as the next.
fn loadOne(tool: *Tool, code: []const u8, signature: *const [4]u8, index: *u16, place: u16) !void {
    const ab = &tool.acpi;
    const length = if (code.len >= 8) mem.readInt(u32, code[4..8], .little) else 0;
    if (code.len < 36 or !mem.eql(u8, code[0..4], signature) or length < 36 or length > code.len) {
        try print(tool, "{s} {d}: not a table of its signature, or shorter than it says: left out\n", .{ signature, place });
        return;
    }
    index.* += 1;
    const loaded = acpi.load.loadTable(ab, .{ .code = code[0..length], .index = index.*, .place = place });
    try print(tool, "{s} {d}: {d} bytes, {d} names; {d} terms outside a method; {d} defined again, {d} not there, {d} not known, {d} broken\n", .{
        signature, place, length, loaded.names, loaded.code, loaded.again, loaded.missing, loaded.unknown, loaded.broken,
    });
}

// --- the start, and what the steps after it ask -----------------------------------

/// The spaces acpiexec connects before it dumps, in its order.
const ACPIEXEC_SPACES = [_]u8{
    hardware_acpi.SPACE_EMBEDDED_CONTROL,   hardware_acpi.SPACE_SMBUS,
    hardware_acpi.SPACE_SYSTEM_CMOS,        hardware_acpi.SPACE_PCI_BAR_TARGET,
    hardware_acpi.SPACE_IPMI,               hardware_acpi.SPACE_GENERAL_PURPOSE_IO,
    hardware_acpi.SPACE_GENERIC_SERIAL_BUS, hardware_acpi.SPACE_PCC,
    hardware_acpi.SPACE_PRM,                hardware_acpi.SPACE_FUNCTIONAL_FIXED,
    0x80,                                   0xE4,
};

/// The spaces the resource's start connects: those it has handlers for.
const START_SPACES = [_]u8{
    hardware_acpi.SPACE_SYSTEM_MEMORY,
    hardware_acpi.SPACE_SYSTEM_IO,
    hardware_acpi.SPACE_PCI_CONFIG,
    hardware_acpi.SPACE_SYSTEM_CMOS,
};

/// The platform-wide `_OSC`'s UUID, 0811B06E-4A27-44F9-8D60-3CBBC22E7B48,
/// in the byte order ToUUID writes.
const PLATFORM_OSC = [16]u8{ 0x6E, 0xB0, 0x11, 0x08, 0x27, 0x4A, 0xF9, 0x44, 0x8D, 0x60, 0x3C, 0xBB, 0xC2, 0x2E, 0x7B, 0x48 };

fn runStart(tool: *Tool) !void {
    const ab = &tool.acpi;
    const root = ab.root orelse return;
    try put(tool, "--- the start\n");
    for (START_SPACES) |space| {
        try print(tool, "connect space {d}\n", .{space});
        beginEvaluation(tool);
        acpi.region.connectSpace(ab, space);
        try showTouched(tool);
        try showNotices(tool);
    }
    if (childOf(root, "_PIC")) |method| _ = try evaluate(tool, method, &.{.{ .integer = 1 }});
    if (childOf(root, "_INI")) |method| _ = try evaluate(tool, method, &.{});
    const system_bus = childOf(root, "_SB_");
    if (system_bus) |bus| {
        if (childOf(bus, "_INI")) |method| _ = try evaluate(tool, method, &.{});
    }
    try startDevices(tool, root, system_bus);
    if (system_bus) |bus| {
        if (childOf(bus, "_OSC")) |method| {
            const uuid = try bufferOf(ab, &PLATFORM_OSC);
            defer object.release(ab, uuid);
            const capabilities = try bufferOf(ab, &[8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
            defer object.release(ab, capabilities);
            _ = try evaluate(tool, method, &.{ .{ .object = uuid }, .{ .integer = 1 }, .{ .integer = 2 }, .{ .object = capabilities } });
            try put(tool, "  the capabilities after it: ");
            try showObject(tool, capabilities, 0);
            try put(tool, "\n");
        }
    }

    try put(tool, "--- what the steps after it ask\n");
    try evaluateEach(tool, "_CRS", &.{ .device, .processor, .thermal_zone, .power_resource });
    try evaluateEach(tool, "_PRT", &.{.device});
    try evaluateEach(tool, "_CST", &.{ .device, .processor });
    try evaluateEach(tool, "_CPC", &.{ .device, .processor });
    try evaluateEach(tool, "_TMP", &.{.thermal_zone});
    if (childOf(root, "_S5_")) |node| _ = try evaluate(tool, node, &.{});
    if (childOf(root, "_PTS")) |method| _ = try evaluate(tool, method, &.{.{ .integer = 5 }});
    try print(tool, "--- {d} evaluations, {d} ended with an error; every place touched:\n", .{ tool.evaluations, tool.failed });
    try showAll(tool);
}

/// Each device's `_STA` below `scope`, in the namespace's order, as
/// acpiexec's own checks ask them before it dumps: a device neither
/// present nor functioning, or whose `_STA` fails, keeps the devices
/// below it from being asked.
fn askStatus(tool: *Tool, scope: *Node) void {
    const ab = &tool.acpi;
    var at = scope.first;
    while (at) |node| : (at = node.next) {
        switch (node.kind()) {
            .method => continue,
            .device => if (childOf(node, "_STA")) |method| {
                const result = interpreter.call(ab, method, &.{}) catch continue;
                defer interpreter.release(ab, result);
                const status: u64 = switch (result) {
                    .integer => |value| value,
                    .object => |answered| switch (answered.value) {
                        .integer => |value| value,
                        else => 0,
                    },
                    else => 0,
                };
                if (status & 0x09 == 0) continue;
            },
            else => {},
        }
        askStatus(tool, node);
    }
}

/// Each device, processor and thermal zone below `scope` started in the
/// namespace's order: its `_STA`, its `_INI` where that says it is
/// present, and its children where it is present or functioning. A
/// `_STA` that fails counts as functioning but not present. The system
/// bus's own `_INI` was run before.
fn startDevices(tool: *Tool, scope: *Node, system_bus: ?*Node) error{OutOfMemory}!void {
    var at = scope.first;
    while (at) |node| : (at = node.next) {
        switch (node.kind()) {
            .device, .processor, .thermal_zone => {
                var status: u64 = 0x0F;
                if (childOf(node, "_STA")) |method| status = try evaluate(tool, method, &.{}) orelse 0x08;
                if (status & 0x01 != 0 and node != system_bus) {
                    if (childOf(node, "_INI")) |method| _ = try evaluate(tool, method, &.{});
                }
                if (status & 0x09 != 0) try startDevices(tool, node, system_bus);
            },
            .method => {},
            else => try startDevices(tool, node, system_bus),
        }
    }
}

/// Every name `name` in the namespace whose parent is of one of `kinds`,
/// evaluated.
fn evaluateEach(tool: *Tool, comptime name: *const [4]u8, kinds: []const object.Kind) !void {
    const root = tool.acpi.root orelse return;
    var at: ?*Node = root;
    while (at) |node| : (at = namespace.next(root, node)) {
        if (node.name != namespace.nameOf(name)) continue;
        const parent = node.parent orelse continue;
        if (mem.indexOfScalar(object.Kind, kinds, parent.kind()) == null) continue;
        _ = try evaluate(tool, node, &.{});
    }
}

fn childOf(scope: *Node, comptime name: *const [4]u8) ?*Node {
    return namespace.child(scope, namespace.nameOf(name));
}

fn bufferOf(ab: *AcpiBase, bytes: []const u8) !*Object {
    const made = object.makeBytes(ab, @intCast(bytes.len)) orelse return error.OutOfMemory;
    @memcpy(made.bytes[0..bytes.len], bytes);
    return object.make(ab, .{ .buffer = made }) orelse error.OutOfMemory;
}

fn beginEvaluation(tool: *Tool) void {
    tool.touched.clearRetainingCapacity();
    tool.waited = 0;
}

/// `node` evaluated with `args`: a method called, what a name holds
/// shown. Its line, what it answered, what it touched and what it
/// queued; the integer it answered, null where it answered none or
/// failed.
fn evaluate(tool: *Tool, node: *Node, args: []const Item) error{OutOfMemory}!?u64 {
    const ab = &tool.acpi;
    try showPath(tool, node);
    if (args.len > 0) {
        try put(tool, " (");
        for (args, 0..) |arg, index| {
            if (index > 0) try put(tool, ", ");
            try showItem(tool, arg, 1);
        }
        try put(tool, ")");
    }
    try put(tool, "\n");
    beginEvaluation(tool);
    tool.evaluations += 1;
    var answer: ?u64 = null;
    const held = node.object orelse return null;
    if (held.value == .method) {
        if (interpreter.call(ab, node, args)) |result| {
            defer interpreter.release(ab, result);
            try put(tool, "  = ");
            try showItem(tool, result, 0);
            try put(tool, "\n");
            answer = switch (result) {
                .integer => |value| value,
                .object => |answered| switch (answered.value) {
                    .integer => |value| value,
                    else => null,
                },
                else => null,
            };
        } else |err| {
            tool.failed += 1;
            try print(tool, "  failed: {t}\n", .{err});
        }
    } else {
        try put(tool, "  = ");
        try showObject(tool, held, 0);
        try put(tool, "\n");
    }
    try showTouched(tool);
    try showNotices(tool);
    return answer;
}

// --- what was answered and touched -------------------------------------------------

fn showPath(tool: *Tool, node: *const Node) !void {
    var path: [namespace.PATH_ROOM]u8 = undefined;
    const length = namespace.pathOf(node, &path);
    try put(tool, path[0..length]);
}

fn showItem(tool: *Tool, item: Item, depth: u32) error{OutOfMemory}!void {
    switch (item) {
        .none => try put(tool, "(nothing)"),
        .integer => |value| try print(tool, "0x{X}", .{value}),
        .object => |held| try showObject(tool, held, depth),
        else => try put(tool, "(a reference)"),
    }
}

/// An object as a line shows it: a package's elements two deep, a
/// buffer's every byte.
fn showObject(tool: *Tool, held: *const Object, depth: u32) error{OutOfMemory}!void {
    switch (held.value) {
        .integer => |value| try print(tool, "0x{X}", .{value}),
        .string => |text| try print(tool, "\"{s}\"", .{text.slice()}),
        .buffer => |bytes| {
            try print(tool, "Buffer ({d})", .{bytes.length});
            if (bytes.length > 0) try put(tool, " =");
            for (bytes.slice()) |byte| try print(tool, " {X:0>2}", .{byte});
        },
        .package => |package| {
            try print(tool, "Package ({d})", .{package.count});
            if (depth >= 2 or package.count == 0) return;
            try put(tool, " {");
            for (package.elements[0..package.count], 0..) |element, index| {
                try put(tool, if (index == 0) " " else ", ");
                if (element) |inside| try showObject(tool, inside, depth + 1) else try put(tool, "-");
            }
            try put(tool, " }");
        },
        .name => |reference| try showNameString(tool, reference.path[0..reference.length]),
        .reference => try put(tool, "(a reference)"),
        else => try put(tool, typeName(held)),
    }
}

/// A name string as the bytecode writes it, as text.
fn showNameString(tool: *Tool, bytes: []const u8) !void {
    var at: usize = 0;
    while (at < bytes.len and (bytes[at] == '\\' or bytes[at] == '^')) : (at += 1) try tool.out.append(tool.allocator, bytes[at]);
    var segments: usize = 1;
    if (at < bytes.len) switch (bytes[at]) {
        0x00 => return,
        0x2E => {
            segments = 2;
            at += 1;
        },
        0x2F => {
            if (at + 1 >= bytes.len) return;
            segments = bytes[at + 1];
            at += 2;
        },
        else => {},
    };
    var index: usize = 0;
    while (index < segments and at + 4 <= bytes.len) : (index += 1) {
        if (index > 0) try put(tool, ".");
        try put(tool, bytes[at .. at + 4]);
        at += 4;
    }
}

fn showPlace(tool: *Tool, touch: Touch) !void {
    switch (touch.space) {
        hardware_acpi.SPACE_SYSTEM_MEMORY => try print(tool, "mem {X:0>8}", .{touch.address}),
        hardware_acpi.SPACE_SYSTEM_IO => try print(tool, "io {X:0>4}", .{touch.address}),
        hardware_acpi.SPACE_PCI_CONFIG => try print(tool, "pci {X:0>4}:{X:0>2}:{X:0>2}.{X}+{X:0>3}", .{
            touch.function >> 24, (touch.function >> 16) & 0xFF, (touch.function >> 8) & 0xFF, touch.function & 0xFF, touch.address,
        }),
        hardware_acpi.SPACE_SYSTEM_CMOS => try print(tool, "cmos {X:0>2}", .{touch.address}),
        hardware_acpi.SPACE_EMBEDDED_CONTROL => try print(tool, "ec {X:0>2}", .{touch.address}),
        else => try print(tool, "space {X:0>2} {X}", .{ touch.space, touch.address }),
    }
}

/// What the evaluation running touched, each place once with how often,
/// and what it waited for.
fn showTouched(tool: *Tool) !void {
    if (tool.touched.count() == 0 and tool.waited == 0) return;
    try put(tool, "  touched:");
    for (tool.touched.keys(), tool.touched.values(), 0..) |touch, times, index| {
        try put(tool, if (index == 0) " " else ", ");
        try showPlace(tool, touch);
        try print(tool, " {c}{d}", .{ @as(u8, if (touch.write) 'w' else 'r'), touch.width });
        if (times > 1) try print(tool, " x{d}", .{times});
    }
    if (tool.waited > 0) try print(tool, "; waited {d} us", .{tool.waited});
    try put(tool, "\n");
}

fn showNotices(tool: *Tool) !void {
    const ab = &tool.acpi;
    while (acpi.notice.take(ab)) |taken| {
        try put(tool, "  notify ");
        try showPath(tool, taken.node);
        try print(tool, " 0x{X}\n", .{taken.value});
        namespace.unhold(ab, taken.node);
    }
}

fn touchBefore(_: void, one: Touch, other: Touch) bool {
    if (one.space != other.space) return one.space < other.space;
    if (one.function != other.function) return one.function < other.function;
    if (one.address != other.address) return one.address < other.address;
    if (one.write != other.write) return !one.write;
    return one.width < other.width;
}

/// Every place any evaluation touched, a line a place: how it was read
/// and written, and how often.
fn showAll(tool: *Tool) !void {
    const places = try tool.allocator.dupe(Touch, tool.all.keys());
    defer tool.allocator.free(places);
    mem.sort(Touch, places, {}, touchBefore);
    var index: usize = 0;
    while (index < places.len) {
        const first = places[index];
        try put(tool, "  ");
        try showPlace(tool, first);
        while (index < places.len and places[index].space == first.space and places[index].function == first.function and places[index].address == first.address) : (index += 1) {
            const touch = places[index];
            try print(tool, " {c}{d} x{d}", .{ @as(u8, if (touch.write) 'w' else 'r'), touch.width, tool.all.get(touch).? });
        }
        try put(tool, "\n");
    }
}

// --- the namespace, as acpiexec lays it out ---------------------------------------

fn dumpNamespace(tool: *Tool) !void {
    const root = tool.acpi.root orelse return;
    var at = namespace.next(root, root);
    while (at) |node| : (at = namespace.next(root, node)) {
        const depth = namespace.depthOf(node);
        try print(tool, "{d:>2} ", .{depth});
        try tool.out.appendNTimes(tool.allocator, ' ', 2 * depth + 1);
        try put(tool, &namespace.textOf(node.name));
        try print(tool, " {s: <12} ", .{if (node.object) |held| typeName(held) else "Scope"});
        try details(tool, node);
        try put(tool, "\n");
    }
}

/// What acpiexec calls the kind of object `held` is.
fn typeName(held: *const Object) []const u8 {
    return switch (held.value) {
        .uninitialized => "Untyped",
        .integer => "Integer",
        .string => "String",
        .buffer => "Buffer",
        .package => "Package",
        .field_unit => |field| switch (field.kind) {
            .region => "RegionField",
            .bank => "BankField",
            .index => "IndexField",
        },
        .device => "Device",
        .event => "Event",
        .method => "Method",
        .mutex => "Mutex",
        .region => "Region",
        .power_resource => "Power",
        .processor => "Processor",
        .thermal_zone => "Thermal",
        .buffer_field => "BufferField",
        .debug => "DebugObject",
        .name, .reference => "Reference",
        .alias => "Alias",
    };
}

/// acpiexec's names of the address spaces.
fn spaceName(space: u8) []const u8 {
    return switch (space) {
        hardware_acpi.SPACE_SYSTEM_MEMORY => "SystemMemory",
        hardware_acpi.SPACE_SYSTEM_IO => "SystemIO",
        hardware_acpi.SPACE_PCI_CONFIG => "PCI_Config",
        hardware_acpi.SPACE_EMBEDDED_CONTROL => "EmbeddedControl",
        hardware_acpi.SPACE_SMBUS => "SMBus",
        hardware_acpi.SPACE_SYSTEM_CMOS => "SystemCMOS",
        hardware_acpi.SPACE_PCI_BAR_TARGET => "PCIBARTarget",
        hardware_acpi.SPACE_IPMI => "IPMI",
        hardware_acpi.SPACE_GENERAL_PURPOSE_IO => "GeneralPurposeIo",
        hardware_acpi.SPACE_GENERIC_SERIAL_BUS => "GenericSerialBus",
        hardware_acpi.SPACE_PCC => "PCC",
        hardware_acpi.SPACE_PRM => "PlatformRtMechanism",
        hardware_acpi.SPACE_FUNCTIONAL_FIXED => "FunctionalFixedHW",
        else => "UserDefinedRegion",
    };
}

/// How many bytes each access of a field reaches: any access and a
/// buffer's are a byte's.
fn accessBytes(field: object.Field) u32 {
    return switch (field.access()) {
        object.ACCESS_WORD => 2,
        object.ACCESS_DWORD => 4,
        object.ACCESS_QWORD => 8,
        else => 1,
    };
}

/// The name that holds `target`, for a buffer field's buffer.
fn holderOf(root: *Node, target: *const Object) ?*Node {
    var at: ?*Node = root;
    while (at) |node| : (at = namespace.next(root, node)) {
        if (node.object == target) return node;
    }
    return null;
}

fn details(tool: *Tool, node: *const Node) !void {
    const held = node.object orelse return;
    switch (held.value) {
        .integer => |value| try print(tool, "= {X:0>16}", .{value}),
        .string => |text| try print(tool, "Len {X:0>2} \"{s}\"", .{ text.length, text.slice() }),
        .buffer => |bytes| {
            try print(tool, "Len {X:0>2}", .{bytes.length});
            if (bytes.length > 0) {
                try put(tool, " =");
                for (bytes.slice()[0..@min(bytes.length, 12)]) |byte| try print(tool, " {X:0>2}", .{byte});
            }
        },
        .package => |package| try print(tool, "Elements {X:0>2}", .{package.count}),
        .method => |method| try print(tool, "Args {d} Len {X:0>4}", .{ method.args(), method.length }),
        .region => |region| try print(tool, "[{s}] Addr {X:0>16} Len {X:0>4}", .{ spaceName(region.space), region.offset, region.length }),
        .field_unit => |field| {
            switch (field.kind) {
                .region => try print(tool, "Rgn [{s}]", .{&namespace.textOf(field.container.name)}),
                .bank => try print(tool, "Rgn [{s}] Bnk [{s}]", .{ &namespace.textOf(field.container.name), &namespace.textOf(field.second.?.name) }),
                .index => try print(tool, "Idx [{s}] Dat [{s}]", .{ &namespace.textOf(field.container.name), &namespace.textOf(field.second.?.name) }),
            }
            try print(tool, " Off {X:0>3} Len {X:0>2} Acc {X:0>2}", .{ field.bit_offset, field.bit_length, accessBytes(field) });
        },
        .buffer_field => |field| {
            if (holderOf(tool.acpi.root.?, field.buffer)) |holder| try print(tool, "Buf [{s}]", .{&namespace.textOf(holder.name)});
            const bytes: u32 = if (field.as_buffer or field.bit_length <= 8) 1 else field.bit_length / 8;
            try print(tool, " Off {X:0>3} Len {X:0>2} Acc {X:0>2}", .{ field.bit_offset, field.bit_length, bytes });
        },
        .processor => |cpu| try print(tool, "ID {X:0>2} Len {X:0>2} Addr {X:0>16}", .{ cpu.id, cpu.block_length, cpu.block_address }),
        .alias => |target| try print(tool, "Target {s}", .{&namespace.textOf(target.name)}),
        else => {},
    }
}
