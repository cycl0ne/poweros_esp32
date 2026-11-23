// SPDX-License-Identifier: MIT
//! The service calls' shared parts: the records an SDP query brings back
//! (sdp/client.zig) made into ObtainBTServices's list - each record a
//! BTService, what a program looks for read from its attributes, the
//! record itself copied after it with its name.
//!
//! **What is read** of a record: its handle; the first class its class
//! list names; the PSM and RFCOMM channel its protocol descriptor list
//! names - the first of its alternatives, where it has them - an L2CAP
//! without a PSM followed by RFCOMM being RFCOMM's PSM; the first profile
//! of its profile list, with its version; its name, in the language its
//! language base list names first - or at 0x0100, where it has none - up
//! to a NUL. What a record does not hold is 0, or empty.
//!
//! **A data element** read for a program (NextBTDataElement,
//! FindBTServiceAttribute) is described in a BTDataElement: its type, its
//! data where it was read, an integer's value, a UUID made 128 bits.
//!
//! **A program's record** (AddBTService) is kept on the base's list under
//! its lock, its handle and its bytes after it as the SDP server answers
//! with them: the handle's attribute first, then the program's.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const l2cap = bluetooth.l2cap;
const sdp = bluetooth.sdp;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _sdp = @import("../sdp/_sdp.zig");
const att_client = @import("../att/client.zig");
const sdp_server = @import("../sdp/server.zig");

/// The room the records are gathered in: more than a device sends.
pub const ROOM = 32 * 1024;

/// What is read of one record.
pub const Read = struct {
    service: bluetooth.BTService = .{},
    name: []const u8 = &.{},
};

/// The records of `records` - an SDP answer's attribute lists, a sequence
/// of one sequence a record - read; false for bytes that are not that.
/// `each` is given every record whole and what was read of it.
pub fn walk(records: []const u8, context: anytype, comptime each: fn (@TypeOf(context), []const u8, *const Read) void) bool {
    if (records.len == 0) return true;
    const lists = _sdp.element(records) orelse return false;
    if (lists.kind != sdp.DE_SEQUENCE or lists.whole != records.len) return false;
    var at: usize = 0;
    while (at < lists.data.len) {
        const record = _sdp.element(lists.data[at..]) orelse return false;
        if (record.kind != sdp.DE_SEQUENCE) return false;
        const bytes = lists.data[at..][0..record.whole];
        at += record.whole;
        var found: Read = .{};
        read(record, &found);
        each(context, bytes, &found);
    }
    return true;
}

/// What a record says of itself.
pub fn read(record: _sdp.Element, into: *Read) void {
    var name_base: u32 = sdp.ATTR_SERVICE_NAME;
    var pairs = Pairs{ .rest = record.data };
    while (pairs.next()) |pair| {
        switch (pair.id) {
            sdp.ATTR_SERVICE_RECORD_HANDLE => into.service.handle = _sdp.unsigned(pair.value) orelse 0,
            sdp.ATTR_SERVICE_CLASS_ID_LIST => {
                var classes = _sdp.itemsOf(pair.value);
                if (classes.next()) |first| {
                    if (_sdp.uuid(first)) |class| {
                        into.service.class = .{ .bytes = class };
                        into.service.class16 = _sdp.short(class);
                    }
                }
            },
            sdp.ATTR_PROTOCOL_DESCRIPTOR_LIST => protocols(pair.value, &into.service),
            sdp.ATTR_LANGUAGE_BASE_LIST => {
                // Triplets: the language, its encoding, its base.
                var items = _sdp.itemsOf(pair.value);
                _ = items.next();
                _ = items.next();
                if (items.next()) |base_item| name_base = _sdp.unsigned(base_item) orelse name_base;
            },
            sdp.ATTR_PROFILE_DESCRIPTOR_LIST => {
                var profiles = _sdp.itemsOf(pair.value);
                const first = profiles.next() orelse continue;
                var parts = _sdp.itemsOf(first);
                const profile = parts.next() orelse continue;
                into.service.profile16 = if (_sdp.uuid(profile)) |uuid| _sdp.short(uuid) else 0;
                if (parts.next()) |version| into.service.profile_version = @truncate(_sdp.unsigned(version) orelse 0);
            },
            else => {},
        }
    }
    // The name, now that its language's base is known.
    pairs = .{ .rest = record.data };
    while (pairs.next()) |pair| {
        if (pair.id != name_base or pair.value.kind != sdp.DE_TEXT) continue;
        const text = pair.value.data;
        var length: usize = 0;
        while (length < text.len and text[length] != 0) length += 1;
        into.name = text[0..length];
    }
}

/// A record's attributes, an id and its value at a time.
pub const Pairs = struct {
    rest: []const u8,

    pub const Pair = struct { id: u32, value: _sdp.Element };

    pub fn next(pairs: *Pairs) ?Pair {
        while (true) {
            const id_item = _sdp.element(pairs.rest) orelse return null;
            const value = _sdp.element(pairs.rest[id_item.whole..]) orelse return null;
            pairs.rest = pairs.rest[id_item.whole + value.whole ..];
            const id = _sdp.unsigned(id_item) orelse continue;
            return .{ .id = id, .value = value };
        }
    }
};

/// The PSM and RFCOMM channel a protocol descriptor list names.
fn protocols(list: _sdp.Element, into: *bluetooth.BTService) void {
    var stack = list;
    // Alternatives: the first of them.
    if (stack.kind == sdp.DE_ALTERNATIVE) {
        var alternatives = _sdp.itemsOf(stack);
        stack = alternatives.next() orelse return;
    }
    var l2cap_seen = false;
    var descriptors = _sdp.itemsOf(stack);
    while (descriptors.next()) |descriptor| {
        var parts = _sdp.itemsOf(descriptor);
        const protocol = parts.next() orelse continue;
        const uuid = _sdp.uuid(protocol) orelse continue;
        switch (_sdp.short(uuid)) {
            sdp.UUID_L2CAP => {
                l2cap_seen = true;
                if (parts.next()) |psm| into.psm = @truncate(_sdp.unsigned(psm) orelse 0);
            },
            sdp.UUID_RFCOMM => {
                if (parts.next()) |channel| into.rfcomm_channel = @truncate(_sdp.unsigned(channel) orelse 0);
                if (l2cap_seen and into.psm == 0) into.psm = l2cap.PSM_RFCOMM;
            },
            else => {},
        }
    }
}

/// One BTService in the list's block: its node's name and its record
/// follow it.
const ENTRY_ALIGN = @alignOf(bluetooth.BTService);

fn entrySize(record_length: usize, name_length: usize) usize {
    const size = @sizeOf(bluetooth.BTService) + record_length + name_length + 1;
    return (size + ENTRY_ALIGN - 1) / ENTRY_ALIGN * ENTRY_ALIGN;
}

const Count = struct {
    size: usize = 0,

    fn add(count: *Count, record: []const u8, found: *const Read) void {
        count.size += entrySize(record.len, found.name.len);
    }
};

const Fill = struct {
    list: *exec.List,
    sys: *sdk.interface.exec.ExecBase,
    at: usize,
    controller: u32,
    address: bluetooth.BTAddress,

    fn add(fill: *Fill, record: []const u8, found: *const Read) void {
        const service: *bluetooth.BTService = @ptrFromInt(fill.at);
        service.* = found.service;
        service.controller = fill.controller;
        service.address = fill.address;
        service.flags = bluetooth.BTSF_SDP;
        const bytes: [*]u8 = @ptrFromInt(fill.at + @sizeOf(bluetooth.BTService));
        @memcpy(bytes[0..record.len], record);
        service.record = bytes;
        service.record_length = @intCast(record.len);
        const name = bytes + record.len;
        @memcpy(name[0..found.name.len], found.name);
        name[found.name.len] = 0;
        service.node.name = @ptrCast(name);
        fill.sys.AddTail(fill.list, &service.node);
        fill.at += entrySize(record.len, found.name.len);
    }
};

/// ObtainBTServices's list made from the records, in one block that
/// ReleaseBTServices frees: 0, BTERR_PROTOCOL for records that are not
/// well made, BTERR_NOMEM.
pub fn make(base: *BluetoothBase, controller: u32, address: bluetooth.BTAddress, records: []const u8, into: *?*exec.List) i32 {
    const sys = base.sys_base;
    var count: Count = .{};
    if (!walk(records, &count, Count.add)) return bluetooth.BTERR_PROTOCOL;
    const head = (@sizeOf(exec.List) + ENTRY_ALIGN - 1) / ENTRY_ALIGN * ENTRY_ALIGN;
    const memory = sys.AllocVec(head + count.size, exec.MEMF_CLEAR) orelse return bluetooth.BTERR_NOMEM;
    const list: *exec.List = @ptrCast(@alignCast(memory));
    list.init(.unknown);
    var fill: Fill = .{ .list = list, .sys = sys, .at = @intFromPtr(memory) + head, .controller = controller, .address = address };
    _ = walk(records, &fill, Fill.add);
    into.* = list;
    return 0;
}

/// A list of one service, in one block ReleaseBTServices frees: a copy of
/// `service`, with its record and its name; null for no memory.
pub fn copy(base: *BluetoothBase, service: *const bluetooth.BTService) ?*exec.List {
    const record: []const u8 = if (service.record) |bytes| bytes[0..service.record_length] else &.{};
    var name: []const u8 = &.{};
    if (service.node.name) |text| {
        var length: usize = 0;
        while (text[length] != 0) length += 1;
        name = text[0..length];
    }
    return one(base, record, &.{ .service = service.*, .name = name });
}

/// A list of one service made from one record, in one block
/// ReleaseBTServices frees, as ObtainBTServices lists a device's: 0,
/// BTERR_PROTOCOL for bytes that are not a record whole, BTERR_NOMEM.
pub fn makeOne(base: *BluetoothBase, controller: u32, address: bluetooth.BTAddress, record: []const u8, into: *?*exec.List) i32 {
    const whole = _sdp.element(record) orelse return bluetooth.BTERR_PROTOCOL;
    if (whole.kind != sdp.DE_SEQUENCE or whole.whole != record.len) return bluetooth.BTERR_PROTOCOL;
    var found: Read = .{};
    read(whole, &found);
    found.service.controller = controller;
    found.service.address = address;
    found.service.flags = bluetooth.BTSF_SDP;
    into.* = one(base, record, &found) orelse return bluetooth.BTERR_NOMEM;
    return 0;
}

/// A list of one entry: what was read of a service, its record and name
/// copied after it.
fn one(base: *BluetoothBase, record: []const u8, found: *const Read) ?*exec.List {
    const sys = base.sys_base;
    const head = (@sizeOf(exec.List) + ENTRY_ALIGN - 1) / ENTRY_ALIGN * ENTRY_ALIGN;
    const memory = sys.AllocVec(head + entrySize(record.len, found.name.len), exec.MEMF_CLEAR) orelse return null;
    const list: *exec.List = @ptrCast(@alignCast(memory));
    list.init(.unknown);
    const at = @intFromPtr(memory) + head;
    const service: *bluetooth.BTService = @ptrFromInt(at);
    service.* = found.service;
    service.node = .{};
    const bytes: [*]u8 = @ptrFromInt(at + @sizeOf(bluetooth.BTService));
    @memcpy(bytes[0..record.len], record);
    service.record = if (record.len != 0) bytes else null;
    service.record_length = @intCast(record.len);
    const name = bytes + record.len;
    @memcpy(name[0..found.name.len], found.name);
    name[found.name.len] = 0;
    service.node.name = @ptrCast(name);
    sys.AddTail(list, &service.node);
    return list;
}

/// ObtainBTServices's list over LE, made from the GATT services in
/// `records` - the services procedure's, a ServiceRecord each
/// (att/client.zig) - in one block that ReleaseBTServices frees: 0,
/// BTERR_PROTOCOL for records that are not that, BTERR_NOMEM.
pub fn makeGatt(base: *BluetoothBase, controller: u32, address: bluetooth.BTAddress, records: []const u8, into: *?*exec.List) i32 {
    const sys = base.sys_base;
    const each = @sizeOf(att_client.ServiceRecord);
    if (records.len % each != 0) return bluetooth.BTERR_PROTOCOL;
    const count = records.len / each;
    const head = (@sizeOf(exec.List) + ENTRY_ALIGN - 1) / ENTRY_ALIGN * ENTRY_ALIGN;
    // No record, an empty name.
    const entry = entrySize(0, 0);
    const memory = sys.AllocVec(head + count * entry, exec.MEMF_CLEAR) orelse return bluetooth.BTERR_NOMEM;
    const list: *exec.List = @ptrCast(@alignCast(memory));
    list.init(.unknown);
    for (0..count) |index| {
        const record: *align(1) const att_client.ServiceRecord = @ptrCast(records[index * each ..].ptr);
        const at = @intFromPtr(memory) + head + index * entry;
        const service: *bluetooth.BTService = @ptrFromInt(at);
        service.* = .{
            .controller = controller,
            .address = address,
            .flags = bluetooth.BTSF_GATT,
            .class = .{ .bytes = record.uuid },
            .class16 = _sdp.short(record.uuid),
            .handle = record.start,
            .end_handle = record.end,
        };
        service.node.name = @ptrFromInt(at + @sizeOf(bluetooth.BTService));
        sys.AddTail(list, &service.node);
    }
    into.* = list;
    return 0;
}

// --- data elements ------------------------------------------------------------

/// An element described for a program: its type, where its data is, an
/// integer's value - a signed one's sign kept - and a UUID's as 128 bits.
pub fn describe(item: _sdp.Element, into: *bluetooth.BTDataElement) void {
    into.* = .{ .kind = item.kind, .whole = @intCast(item.whole), .data = item.data.ptr, .length = @intCast(item.data.len) };
    switch (item.kind) {
        sdp.DE_UINT, sdp.DE_INT, sdp.DE_BOOL => if (item.data.len <= 8) {
            var value: u64 = 0;
            for (item.data) |byte| value = value << 8 | byte;
            if (item.kind == sdp.DE_INT and item.data.len > 0 and item.data.len < 8) {
                const unused: u6 = @intCast(64 - 8 * item.data.len);
                value = @bitCast(@as(i64, @bitCast(value << unused)) >> unused);
            }
            into.value = value;
        },
        sdp.DE_UUID => if (_sdp.uuid(item)) |full| {
            into.uuid = .{ .bytes = full };
        },
        else => {},
    }
}

// --- the programs' records ------------------------------------------------------

/// The most bytes a program's record takes as it is served, its handle's
/// attribute and its sequence's header in.
pub const RECORD_MOST = sdp_server.RECORD_MOST;

/// One AddBTService: the BTRecord its caller holds, its bytes after it.
pub const Record = struct {
    node: exec.Node = .{},
    handle: u32,
    length: u32,

    /// Its bytes as they are served: a sequence of its attributes, the
    /// handle's first.
    pub fn bytes(record: *Record) []u8 {
        const start: [*]u8 = @ptrCast(record);
        return (start + @sizeOf(Record))[0..record.length];
    }
};
