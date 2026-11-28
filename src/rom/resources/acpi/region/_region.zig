// SPDX-License-Identifier: MPL-2.0
//! Field units and the regions they are in: a field's bits read and
//! written through the address space its region is in, a unit at a
//! time, and the regions told when their space can be reached (`_REG`).
//!
//! **Units.** A field is reached in units of its access width - a byte
//! for AnyAcc and BufferAcc; two, four or eight bytes for WordAcc,
//! DWordAcc and QWordAcc - each at an offset that is a multiple of the
//! width: the first the unit its first bit is in, and as many after it
//! as its bits reach into. A unit must lie inside its region: one past
//! its end is an error, never made narrower.
//!
//! **Reading** puts the units' bits together, the field's own and no
//! others: an integer where they fit one, a buffer of as many bytes as
//! they fill where they do not. A field of no bits reads as 0.
//!
//! **Writing** an integer writes it once, cut to the field's width or
//! filled out with zeros; a string or a buffer is written in pieces the
//! size of the field, one after the other, so that the field ends up
//! holding the last - and nothing at all from an empty one, or into a
//! field of no bits. A unit the field covers whole is written as it is;
//! one it covers in part is read first and changed (Preserve), or has
//! ones (WriteAsOnes) or zeros (WriteAsZeros) around the field's bits.
//!
//! **An index field** reaches each unit by writing the unit's offset into
//! its index field, then reading or writing its data field; **a bank
//! field** writes its bank's number into its bank field before each unit.
//! The value must fit the field it is written into. A field whose lock
//! rule says so - or whose index, data or bank field's does - is reached
//! holding `\_GL`, the mutex that stands for the firmware's global lock,
//! from its first unit to its last.
//!
//! **The spaces.** Memory, the ports and the spaces drivers serve are the
//! machine's to reach (`Machine.access`). A region of PCI's configuration
//! space is of the function the device it is declared in is at: the
//! device's `_ADR`, on the bus the bridges between it and the root bridge
//! lead to from the root bridge's `_BBN`, in the root bridge's `_SEG` -
//! worked out at the region's first access, and kept. A region over a
//! table (DataTableRegion) is the table where it is in memory. The spaces
//! whose fields carry a buffer to a controller and back (SMBus, IPMI,
//! GenericSerialBus, PRM, FFixedHW), the general-purpose pins and the
//! platform's channel (PCC) have nothing to reach them yet: a field of
//! one is an error.
//!
//! **_REG.** A region of a space other than memory, the ports and a
//! table is told once that its space can be reached: the method `_REG`
//! of the scope the region is declared in is run with the space and 1.
//! The regions there already are told when the space is connected
//! (`connectSpace`), one a method makes later as it is made, the ones a
//! table loaded later defines once it is loaded; one a method made is
//! told the space is gone (0) when the method returns, where it was told
//! it is there. A region whose `_REG` ended with an error counts as told.

const sdk = @import("sdk");
const exec = sdk.exec;
const hardware_acpi = sdk.hardware.acpi;
const AcpiBase = @import("../acpi_base.zig").AcpiBase;
const machine = @import("../machine/_machine.zig");
const namespace = @import("../namespace/_namespace.zig");
const Node = namespace.Node;
const object = @import("../object/_object.zig");
const Object = object.Object;
const interpreter = @import("../interpreter/_interpreter.zig");
const Run = interpreter.Run;
const Item = interpreter.Item;
const Error = interpreter.Error;
const convert = @import("../interpreter/convert.zig");
const store = @import("../interpreter/store.zig");
const sync = @import("../interpreter/sync.zig");

/// The deepest an index field's index or data field, or a bank field's
/// bank field, may itself be such a field.
const MOST_DEPTH = 8;

/// The most bytes a field read as a buffer may have.
const MOST_FIELD_BYTES = 1 << 16;

// --- reading and writing a field ----------------------------------------------------------

/// The field unit `held` (`node`'s) read: an integer where its bits fit
/// one, a buffer where they do not.
pub fn readField(run: *Run, node: *Node, held: *Object) Error!Item {
    _ = node;
    const field = held.value.field_unit;
    if (field.bit_length <= run.ab.integer_bits) {
        var room: [8]u8 = @splat(0);
        try transaction(run, field, .{ .read = &room });
        return .{ .integer = convert.bytesInteger(run.ab, &room) };
    }
    const length = (field.bit_length + 7) / 8;
    if (length > MOST_FIELD_BYTES) return error.Range;
    const bytes = object.makeBytes(run.ab, length) orelse return error.NoMemory;
    transaction(run, field, .{ .read = bytes.slice() }) catch |err| {
        object.freeBytes(run.ab, bytes);
        return err;
    };
    return .{ .object = object.make(run.ab, .{ .buffer = bytes }) orelse {
        object.freeBytes(run.ab, bytes);
        return error.NoMemory;
    } };
}

/// `value` - an integer, a string or a buffer - written into the field
/// unit `held` (`node`'s), as the file's header says.
pub fn writeField(run: *Run, node: *Node, held: *Object, value: *Object) Error!void {
    _ = node;
    const field = held.value.field_unit;
    var room: [8]u8 = undefined;
    const source = try convert.storage(run.ab, value, &room);
    if (field.bit_length == 0 or source.len == 0) return;
    if (value.value == .integer) return transaction(run, field, .{ .write = source });
    const piece = (field.bit_length + 7) / 8;
    try lockFor(run, field, true);
    defer lockFor(run, field, false) catch {};
    var at: usize = 0;
    while (at < source.len) : (at += piece) {
        try writeBits(run, field, source[at..@min(at + piece, source.len)], 0);
    }
}

/// What one transaction does: the field's bits read into the bytes
/// given, or written from them.
const Transfer = union(enum) {
    read: []u8,
    write: []const u8,
};

/// One read or one write of the field, under `\_GL` where it asks for it.
fn transaction(run: *Run, field: object.Field, transfer: Transfer) Error!void {
    try lockFor(run, field, true);
    defer lockFor(run, field, false) catch {};
    switch (transfer) {
        .read => |into| try readBits(run, field, into, 0),
        .write => |from| try writeBits(run, field, from, 0),
    }
}

/// `\_GL` taken (`take`) or given back for a field that asks for it.
fn lockFor(run: *Run, field: object.Field, take: bool) Error!void {
    if (!needsLock(field)) return;
    const root = run.ab.root orelse return;
    const node = namespace.child(root, namespace.nameOf("_GL_")) orelse return;
    const held = node.object orelse return;
    const mutex = switch (held.value) {
        .mutex => |*mutex| mutex,
        else => return,
    };
    if (take) {
        _ = try sync.take(run, mutex, sync.FOREVER);
    } else {
        sync.give(run, mutex);
    }
}

/// Whether reaching `field` takes `\_GL`: its own lock rule, or that of
/// the field its index, its data or its bank goes through.
fn needsLock(field: object.Field) bool {
    if (field.flags & object.FIELD_LOCK != 0) return true;
    if (field.kind == .region) return false;
    const fields = [2]?*Node{ if (field.kind == .index) field.container else null, field.second };
    for (fields) |maybe| {
        const node = maybe orelse continue;
        const held = namespace.target(node).object orelse continue;
        switch (held.value) {
            .field_unit => |inner| if (inner.flags & object.FIELD_LOCK != 0) return true,
            else => {},
        }
    }
    return false;
}

// --- units ------------------------------------------------------------------------------

/// How a field's bits lie in its units: how wide a unit is, in bytes,
/// and the offset of the first.
const Units = struct {
    width: u8,
    first: u64,

    fn bits(units: Units) u64 {
        return @as(u64, units.width) * 8;
    }
};

fn unitsOf(field: object.Field) Error!Units {
    const width: u8 = switch (field.access()) {
        object.ACCESS_ANY, object.ACCESS_BYTE, object.ACCESS_BUFFER => 1,
        object.ACCESS_WORD => 2,
        object.ACCESS_DWORD => 4,
        object.ACCESS_QWORD => 8,
        else => return error.Broken,
    };
    const unit_bits = @as(u64, width) * 8;
    return .{ .width = width, .first = field.bit_offset / unit_bits * width };
}

/// The field's bits, each unit read in turn, into `into` from its first
/// bit; the bits of `into` past them are left as they are.
fn readBits(run: *Run, field: object.Field, into: []u8, depth: u32) Error!void {
    if (field.bit_length == 0) return;
    const units = try unitsOf(field);
    const field_end = @as(u64, field.bit_offset) + field.bit_length;
    var offset = units.first;
    while (offset * 8 < field_end) : (offset += units.width) {
        var value: u64 = 0;
        try unitAccess(run, field, offset, units.width, false, &value, depth);
        var bytes: [8]u8 = undefined;
        littleEndian(value, &bytes);
        const unit_start = offset * 8;
        const low = @max(unit_start, field.bit_offset);
        const high = @min(unit_start + units.bits(), field_end);
        store.copyBits(into, @intCast(low - field.bit_offset), bytes[0..units.width], @intCast(low - unit_start), @intCast(high - low));
    }
}

/// `from`, filled out with zeros, written into the field's bits, a unit
/// at a time.
fn writeBits(run: *Run, field: object.Field, from: []const u8, depth: u32) Error!void {
    if (field.bit_length == 0) return;
    const units = try unitsOf(field);
    const field_end = @as(u64, field.bit_offset) + field.bit_length;
    var offset = units.first;
    while (offset * 8 < field_end) : (offset += units.width) {
        const unit_start = offset * 8;
        const low = @max(unit_start, field.bit_offset);
        const high = @min(unit_start + units.bits(), field_end);
        var value: u64 = 0;
        if (high - low != units.bits()) {
            switch ((field.flags & object.FIELD_UPDATE) >> object.FIELD_UPDATE_SHIFT) {
                1 => value = ~@as(u64, 0),
                2 => value = 0,
                else => try unitAccess(run, field, offset, units.width, false, &value, depth),
            }
        }
        var bytes: [8]u8 = undefined;
        littleEndian(value, &bytes);
        store.copyBits(bytes[0..units.width], @intCast(low - unit_start), from, @intCast(low - field.bit_offset), @intCast(high - low));
        value = fromLittleEndian(&bytes);
        if (units.width < 8) value &= (@as(u64, 1) << @intCast(units.bits())) - 1;
        try unitAccess(run, field, offset, units.width, true, &value, depth);
    }
}

fn littleEndian(value: u64, into: *[8]u8) void {
    for (into, 0..) |*byte, index| byte.* = @truncate(value >> @intCast(index * 8));
}

fn fromLittleEndian(bytes: *const [8]u8) u64 {
    var value: u64 = 0;
    for (bytes, 0..) |byte, index| value |= @as(u64, byte) << @intCast(index * 8);
    return value;
}

/// One unit of `field`, `width` bytes at `offset`, read into `value` or
/// written from it: through the region for a field and a bank field -
/// the bank's number written first -, through the index and the data
/// field for an index field.
fn unitAccess(run: *Run, field: object.Field, offset: u64, width: u8, write: bool, value: *u64, depth: u32) Error!void {
    switch (field.kind) {
        .region => return regionAccess(run, field.container, offset, width, write, value),
        .bank => {
            try writeInner(run, field.second, field.bank_value, depth);
            return regionAccess(run, field.container, offset, width, write, value);
        },
        .index => {
            if (offset > 0xFFFF_FFFF) return error.Range;
            try writeInner(run, field.container, offset, depth);
            if (depth >= MOST_DEPTH) return error.Limit;
            const data = try innerField(namespace.target(field.second orelse return error.Type));
            var bytes: [8]u8 = @splat(0);
            if (write) {
                littleEndian(value.*, &bytes);
                return writeBits(run, data, bytes[0..width], depth + 1);
            }
            try readBits(run, data, bytes[0..width], depth + 1);
            value.* = fromLittleEndian(&bytes);
        },
    }
}

/// The field `node` names, as an index field's index or data or a bank
/// field's bank.
fn innerField(node: *Node) Error!object.Field {
    const held = node.object orelse return error.Type;
    return switch (held.value) {
        .field_unit => |field| field,
        else => error.Type,
    };
}

/// `value` written into the field `maybe` names, which must hold it: an
/// index, a bank's number.
fn writeInner(run: *Run, maybe: ?*Node, value: u64, depth: u32) Error!void {
    if (depth >= MOST_DEPTH) return error.Limit;
    const node = namespace.target(maybe orelse return error.Type);
    const field = try innerField(node);
    if (field.bit_length < 64 and value >> @intCast(field.bit_length) != 0) return error.Range;
    var bytes: [8]u8 = undefined;
    littleEndian(value, &bytes);
    return writeBits(run, field, &bytes, depth + 1);
}

// --- regions ----------------------------------------------------------------------------

/// Whether nothing reaches `space` yet.
fn noneReaches(space: u8) bool {
    return switch (space) {
        hardware_acpi.SPACE_SMBUS,
        hardware_acpi.SPACE_IPMI,
        hardware_acpi.SPACE_GENERAL_PURPOSE_IO,
        hardware_acpi.SPACE_GENERIC_SERIAL_BUS,
        hardware_acpi.SPACE_PCC,
        hardware_acpi.SPACE_PRM,
        hardware_acpi.SPACE_FUNCTIONAL_FIXED,
        => true,
        else => false,
    };
}

/// `width` bytes at `offset` in the region `region_node` names.
fn regionAccess(run: *Run, region_node: *Node, offset: u64, width: u8, write: bool, value: *u64) Error!void {
    const node = namespace.target(region_node);
    const held = node.object orelse return error.Type;
    const region = switch (held.value) {
        .region => |*region| region,
        else => return error.Type,
    };
    if (offset > region.length or width > region.length - offset) return regionError(run, node, error.Range);
    if (region.table) return tableAccess(region, offset, width, write, value);
    if (noneReaches(region.space)) return regionError(run, node, error.Access);
    var request: machine.Access = .{ .space = region.space, .address = region.offset +% offset, .width = width, .write = write };
    if (region.space == hardware_acpi.SPACE_PCI_CONFIG) {
        if (!region.pci_known) {
            region.pci = try functionOf(run, node);
            region.pci_known = true;
        }
        request.pci = region.pci;
    }
    if (!write) value.* = 0;
    if (!run.ab.machine.access(run.ab, &request, value)) return regionError(run, node, error.Access);
    if (!write and width < 8) value.* &= (@as(u64, 1) << @intCast(width * 8)) - 1;
}

/// `into.len` bytes of the region `node` from `offset`, a byte at a
/// time: what Load reads a table from.
pub fn readBytes(run: *Run, node: *Node, offset: u64, into: []u8) Error!void {
    for (into, 0..) |*byte, at| {
        var value: u64 = 0;
        try regionAccess(run, node, offset + at, 1, false, &value);
        byte.* = @truncate(value);
    }
}

/// `err` about the region `node`: its name kept for the log.
fn regionError(run: *Run, node: *Node, err: Error) Error {
    _ = namespace.pathOf(node, &run.detail);
    run.has_detail = true;
    return err;
}

/// A unit of a table's region, read or written where the table is.
fn tableAccess(region: *const object.Region, offset: u64, width: u8, write: bool, value: *u64) void {
    const bytes: [*]u8 = @ptrFromInt(@as(usize, @intCast(region.offset + offset)));
    if (write) {
        for (0..width) |index| bytes[index] = @truncate(value.* >> @intCast(index * 8));
        return;
    }
    var read: u64 = 0;
    for (0..width) |index| read |= @as(u64, bytes[index]) << @intCast(index * 8);
    value.* = read;
}

// --- the function a region of configuration space is of ----------------------------------

const HEADER_TYPE = 0x0E;
const SECONDARY_BUS = 0x19;
const MOST_LEVELS = 16;

/// The PCI function the region `node` is of: the device it is in, found
/// from the root bridge down, each bridge on the way giving the bus the
/// next is on (see the file's header).
fn functionOf(run: *Run, node: *Node) Error!machine.Pci {
    // The devices from the region's own up to the root bridge.
    var chain: [MOST_LEVELS]*Node = undefined;
    var count: usize = 0;
    var root_bridge: ?*Node = null;
    var at = node.parent;
    while (at) |each| : (at = each.parent) {
        if (each.kind() != .device) continue;
        if (try isDeviceOf(run, each, &ROOT_BRIDGES)) {
            root_bridge = each;
            break;
        }
        if (count == MOST_LEVELS) return error.Limit;
        chain[count] = each;
        count += 1;
    }
    var pci: machine.Pci = .{};
    const bridge = root_bridge orelse {
        // No root bridge above it: the device's own address, on bus 0.
        if (count > 0) setAddress(&pci, try integerOf(run, chain[0], "_ADR") orelse 0);
        return pci;
    };
    pci.segment = @truncate(try integerOf(run, bridge, "_SEG") orelse 0);
    pci.bus = @truncate(try integerOf(run, bridge, "_BBN") orelse 0);
    if (count == 0) {
        setAddress(&pci, try integerOf(run, bridge, "_ADR") orelse 0);
        return pci;
    }
    // From the top down: each a function on the bus the one above leads to.
    var level = count;
    while (level > 0) {
        level -= 1;
        const address = try integerOf(run, chain[level], "_ADR") orelse break;
        setAddress(&pci, address);
        if (level == 0) break;
        const kind = configByte(run, pci, HEADER_TYPE) orelse break;
        if (kind & 0x7F != 1 and kind & 0x7F != 2) break;
        const secondary = configByte(run, pci, SECONDARY_BUS) orelse break;
        if (secondary == 0) break;
        pci.bus = secondary;
    }
    return pci;
}

fn setAddress(pci: *machine.Pci, address: u64) void {
    pci.device = @truncate(address >> 16);
    pci.function = @truncate(address);
}

/// A byte of the function `pci`'s configuration space; null where the
/// machine cannot read it.
fn configByte(run: *Run, pci: machine.Pci, offset: u8) ?u8 {
    var value: u64 = 0;
    const request: machine.Access = .{ .space = hardware_acpi.SPACE_PCI_CONFIG, .address = offset, .width = 1, .write = false, .pci = pci };
    if (!run.ab.machine.access(run.ab, &request, &value)) return null;
    return @truncate(value);
}

/// A kind of device as `_HID` and `_CID` name it: its EISA number, or
/// its text.
const Identity = struct {
    number: u64,
    text: []const u8,
};

/// PCI's root bridges, PNP0A03 and PNP0A08.
const ROOT_BRIDGES = [_]Identity{
    .{ .number = 0x030AD041, .text = "PNP0A03" },
    .{ .number = 0x080AD041, .text = "PNP0A08" },
};

/// The embedded controller, PNP0C09.
const EMBEDDED_CONTROLLERS = [_]Identity{.{ .number = 0x090CD041, .text = "PNP0C09" }};

/// Whether `device` is of one of `identities`: its own identity, or
/// among those it is compatible with.
fn isDeviceOf(run: *Run, device: *Node, identities: []const Identity) Error!bool {
    for ([2]*const [4]u8{ "_HID", "_CID" }) |name| {
        const item = try valueOf(run, device, name) orelse continue;
        defer interpreter.release(run.ab, item);
        if (isIdentity(item, identities)) return true;
        switch (item) {
            .object => |held| switch (held.value) {
                .package => |package| for (package.elements[0..package.count]) |element| {
                    const inside = element orelse continue;
                    if (isIdentity(.{ .object = inside }, identities)) return true;
                },
                else => {},
            },
            else => {},
        }
    }
    return false;
}

fn isIdentity(item: Item, identities: []const Identity) bool {
    for (identities) |identity| {
        const same = switch (item) {
            .integer => |value| value == identity.number,
            .object => |held| switch (held.value) {
                .integer => |value| value == identity.number,
                .string => |text| sameText(text.slice(), identity.text),
                else => false,
            },
            else => false,
        };
        if (same) return true;
    }
    return false;
}

fn sameText(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |a, b| {
        if (a != b) return false;
    }
    return true;
}

/// What `device`'s child `name` is: a method's result, what a name holds;
/// null where there is none.
fn valueOf(run: *Run, device: *Node, name: *const [4]u8) Error!?Item {
    const node = namespace.child(device, namespace.nameOf(name)) orelse return null;
    const held = node.object orelse return null;
    if (held.value == .method) return try interpreter.callNested(run, node, &.{});
    return try store.readNode(run, node);
}

/// `device`'s child `name` as an integer; null where there is none, or
/// it is no integer.
fn integerOf(run: *Run, device: *Node, name: *const [4]u8) Error!?u64 {
    const item = try valueOf(run, device, name) orelse return null;
    defer interpreter.release(run.ab, item);
    return switch (item) {
        .integer => |value| value,
        .object => |held| switch (held.value) {
            .integer => |value| value,
            else => null,
        },
        else => null,
    };
}

// --- _REG ---------------------------------------------------------------------------------

/// Whether a region of `region` is told when its space can be reached.
fn isTold(region: *const object.Region) bool {
    if (region.table) return false;
    return region.space != hardware_acpi.SPACE_SYSTEM_MEMORY and region.space != hardware_acpi.SPACE_SYSTEM_IO;
}

/// Whether `space` has been connected.
pub fn isConnected(ab: *const AcpiBase, space: u8) bool {
    return ab.connected[space >> 6] & (@as(u64, 1) << @intCast(space & 63)) != 0;
}

/// `space` connected: every region of it there is told it can be
/// reached, and every one made from now on is told as it is made. The
/// first time the embedded controllers' space is connected, each
/// embedded controller with no region of it among its own names is told
/// as well: firmware that reaches its controller through memory alone
/// still waits for that word before it trusts it.
pub fn connectSpace(ab: *AcpiBase, space: u8) void {
    const again = isConnected(ab, space);
    ab.connected[space >> 6] |= @as(u64, 1) << @intCast(space & 63);
    const root = ab.root orelse return;
    defer if (space == hardware_acpi.SPACE_EMBEDDED_CONTROL and !again) tellControllers(ab, root);
    var at: ?*Node = root;
    while (at) |node| : (at = namespace.next(root, node)) {
        const held = node.object orelse continue;
        switch (held.value) {
            .region => |*region| {
                if (region.space != space or region.connected or !isTold(region)) continue;
                tell(ab, null, node, region, true);
            },
            else => {},
        }
    }
}

/// The region `node`, just made: told its space can be reached, where
/// it is connected already - one a table defines once the whole table
/// is loaded (`tellLoaded`), as its scope's `_REG` may come after it.
pub fn regionMade(run: *Run, node: *Node) void {
    if (run.load != null and run.frames.count == 1) return;
    const held = node.object orelse return;
    const region = switch (held.value) {
        .region => |*region| region,
        else => return,
    };
    if (!isTold(region) or !isConnected(run.ab, region.space)) return;
    tell(run.ab, run, node, region, true);
}

/// Every region of a connected space not told yet told: after a table
/// is loaded, the regions it defined.
pub fn tellLoaded(ab: *AcpiBase) void {
    const root = ab.root orelse return;
    var at: ?*Node = root;
    while (at) |node| : (at = namespace.next(root, node)) {
        const held = node.object orelse continue;
        switch (held.value) {
            .region => |*region| {
                if (region.connected or !isTold(region) or !isConnected(ab, region.space)) continue;
                tell(ab, null, node, region, true);
            },
            else => {},
        }
    }
}

/// The region `node`, about to be taken out of the namespace: told its
/// space is gone, where it was told it is there.
pub fn regionGone(run: *Run, node: *Node) void {
    const held = node.object orelse return;
    const region = switch (held.value) {
        .region => |*region| region,
        else => return,
    };
    if (!region.connected) return;
    tell(run.ab, run, node, region, false);
}

/// `_REG` of the scope `node` is declared in run, with the region's space
/// and whether it is there - nested in `outer` where an evaluation runs.
fn tell(ab: *AcpiBase, outer: ?*Run, node: *Node, region: *object.Region, there: bool) void {
    region.connected = there;
    const scope = node.parent orelse return;
    runReg(ab, outer, scope, region.space, there);
}

/// `scope`'s `_REG`, where it has one, run with `space` and whether the
/// space is there; what goes wrong is said in the log.
fn runReg(ab: *AcpiBase, outer: ?*Run, scope: *Node, space: u8, there: bool) void {
    const method = namespace.child(scope, namespace.nameOf("_REG")) orelse return;
    const held = method.object orelse return;
    if (held.value != .method) return;
    const args = [2]Item{ .{ .integer = space }, .{ .integer = @intFromBool(there) } };
    const result = if (outer) |run| interpreter.callNested(run, method, &args) else interpreter.call(ab, method, &args);
    const item = result catch return;
    interpreter.release(ab, item);
}

/// Each embedded controller with no region of the controllers' space
/// among its own names told that space is there.
fn tellControllers(ab: *AcpiBase, root: *Node) void {
    const space = hardware_acpi.SPACE_EMBEDDED_CONTROL;
    var at: ?*Node = root;
    while (at) |node| : (at = namespace.next(root, node)) {
        if (node.kind() != .device or hasRegionOf(node, space)) continue;
        var run: Run = .{ .ab = ab };
        defer run.deinit();
        const controller = isDeviceOf(&run, node, &EMBEDDED_CONTROLLERS) catch false;
        if (controller) runReg(ab, &run, node, space, true);
    }
}

/// Whether one of `scope`'s own names is a region of `space`.
fn hasRegionOf(scope: *const Node, space: u8) bool {
    var at = scope.first;
    while (at) |node| : (at = node.next) {
        const held = node.object orelse continue;
        switch (held.value) {
            .region => |region| if (region.space == space) return true,
            else => {},
        }
    }
    return false;
}
