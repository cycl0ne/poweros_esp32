// SPDX-License-Identifier: MPL-2.0
//! acpicheck: loads a machine's tables of bytecode - a folder C:Acpi
//! saved them to (`Acpi TO`) - into a namespace on the host, with
//! acpi.resource's own interpreter, and says what loading them found.
//!
//! usage: acpicheck [--namespace] <folder>
//!
//! The tables are loaded in the order the resource loads them: DSDT.aml,
//! then SSDT1.aml, SSDT2.aml and on, then PSDT1.aml and on, each as long
//! as its header says. A line for each table says how many names it
//! made, how many terms outside a method it holds, and how many of its
//! names were there already, how many of its scopes were not, and how
//! many of its terms could not be read; the interpreter's own lines -
//! each name defined again, each scope not there, each opcode not known -
//! come before it, and a line for the whole after the last.
//!
//! With --namespace the namespace follows, a name a line in its order -
//! how deep, the name, what it holds and what that is - in the layout of
//! ACPICA's `acpiexec` ("namespace"), so that the two can be compared.
//! An object whose operands are expressions, which the interpreter keeps
//! to be worked out, says `deferred` where acpiexec shows its value.
//!
//! The exit code is 0 when every term could be read, 1 when an opcode was
//! not known or a term could not be read, and 2 when the folder could
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

/// The interpreter's machine on the host: an allocator's memory, and the
/// log into the output.
const Tool = struct {
    acpi: AcpiBase = .{ .lib = undefined, .sys_base = undefined, .machine = &machine },
    allocator: mem.Allocator,
    out: *std.ArrayList(u8),
};

const machine = acpi.machine.Machine{ .allocate = allocate, .free = free, .log = log, .lock = lock, .unlock = unlock };

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
    var count = length;
    while (count < width) : (count += 1) try out.append(allocator, char);
}

fn usage() noreturn {
    std.debug.print("usage: acpicheck [--namespace] <folder>\n", .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var dump = false;
    var folder_path: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (mem.eql(u8, arg, "--namespace")) {
            dump = true;
        } else if (folder_path == null and arg.len > 0 and arg[0] != '-') {
            folder_path = arg;
        } else usage();
    }
    const path = folder_path orelse usage();
    var folder = Io.Dir.cwd().openDir(io, path, .{}) catch |err| {
        std.debug.print("acpicheck: {s}: {t}\n", .{ path, err });
        std.process.exit(2);
    };
    defer folder.close(io);

    var out: std.ArrayList(u8) = .empty;
    var tool: Tool = .{ .allocator = init.gpa, .out = &out };
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
    try out.print(arena, "{d} tables, {d} names; {d} terms outside a method; {d} defined again, {d} not there, {d} not known, {d} broken\n", .{
        ab.tables, sum.names, sum.code, sum.again, sum.missing, sum.unknown, sum.broken,
    });
    if (dump) {
        try out.appendSlice(arena, "ACPI Namespace (from Namespace Root):\n");
        try dumpNamespace(arena, &out, ab);
    }
    try Io.File.stdout().writeStreamingAll(io, out.items);
    std.process.exit(if (sum.unknown + sum.broken == 0) 0 else 1);
}

/// `code`, the `place`th table of `signature`, loaded as the next.
fn loadOne(tool: *Tool, code: []const u8, signature: *const [4]u8, index: *u16, place: u16) !void {
    const ab = &tool.acpi;
    const length = if (code.len >= 8) mem.readInt(u32, code[4..8], .little) else 0;
    if (code.len < 36 or !mem.eql(u8, code[0..4], signature) or length < 36 or length > code.len) {
        try tool.out.print(tool.allocator, "{s} {d}: not a table of its signature, or shorter than it says: left out\n", .{ signature, place });
        return;
    }
    index.* += 1;
    const loaded = acpi.load.loadTable(ab, .{ .code = code[0..length], .index = index.*, .place = place });
    try tool.out.print(tool.allocator, "{s} {d}: {d} bytes, {d} names; {d} terms outside a method; {d} defined again, {d} not there, {d} not known, {d} broken\n", .{
        signature, place, length, loaded.names, loaded.code, loaded.again, loaded.missing, loaded.unknown, loaded.broken,
    });
}

// --- the namespace, as acpiexec lays it out ---------------------------------------

fn dumpNamespace(allocator: mem.Allocator, out: *std.ArrayList(u8), ab: *AcpiBase) !void {
    const root = ab.root orelse return;
    var at = namespace.next(root, root);
    while (at) |node| : (at = namespace.next(root, node)) {
        const depth = namespace.depthOf(node);
        try out.print(allocator, "{d:>2} ", .{depth});
        try out.appendNTimes(allocator, ' ', 2 * depth + 1);
        try out.appendSlice(allocator, &namespace.textOf(node.name));
        try out.print(allocator, " {s: <12} ", .{typeName(node)});
        try details(allocator, out, node);
        try out.append(allocator, '\n');
    }
}

/// What acpiexec calls the kind of object `node` holds.
fn typeName(node: *const Node) []const u8 {
    const held = node.object orelse return "Scope";
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
        .name => "Reference",
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

fn details(allocator: mem.Allocator, out: *std.ArrayList(u8), node: *const Node) !void {
    const held = node.object orelse return;
    switch (held.value) {
        .integer => |value| try out.print(allocator, "= {X:0>16}", .{value}),
        .string => |text| try out.print(allocator, "Len {X:0>2} \"{s}\"", .{ text.length, text.slice() }),
        .buffer => |bytes| {
            try out.print(allocator, "Len {X:0>2}", .{bytes.length});
            if (bytes.length > 0) {
                try out.appendSlice(allocator, " =");
                for (bytes.slice()[0..@min(bytes.length, 12)]) |byte| try out.print(allocator, " {X:0>2}", .{byte});
            }
        },
        .package => |package| try out.print(allocator, "Elements {X:0>2}", .{package.count}),
        .method => |method| try out.print(allocator, "Args {d} Len {X:0>4}", .{ method.args(), method.length }),
        .region => |region| {
            if (region.deferred != null) {
                try out.print(allocator, "[{s}] deferred", .{spaceName(region.space)});
            } else try out.print(allocator, "[{s}] Addr {X:0>16} Len {X:0>4}", .{ spaceName(region.space), region.offset, region.length });
        },
        .field_unit => |field| {
            switch (field.kind) {
                .region => try out.print(allocator, "Rgn [{s}]", .{&namespace.textOf(field.container.name)}),
                .bank => try out.print(allocator, "Rgn [{s}] Bnk [{s}]", .{ &namespace.textOf(field.container.name), &namespace.textOf(field.second.?.name) }),
                .index => try out.print(allocator, "Idx [{s}] Dat [{s}]", .{ &namespace.textOf(field.container.name), &namespace.textOf(field.second.?.name) }),
            }
            try out.print(allocator, " Off {X:0>3} Len {X:0>2} Acc {X:0>2}", .{ field.bit_offset, field.bit_length, accessBytes(field) });
        },
        .buffer_field => try out.appendSlice(allocator, "deferred"),
        .processor => |cpu| try out.print(allocator, "ID {X:0>2} Len {X:0>2} Addr {X:0>16}", .{ cpu.id, cpu.block_length, cpu.block_address }),
        .alias => |target| try out.print(allocator, "Target {s}", .{&namespace.textOf(target.name)}),
        else => {},
    }
}
