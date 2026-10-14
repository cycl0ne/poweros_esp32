// SPDX-License-Identifier: MIT
//! The AIC8800's boot ROM given its firmware: what A69C:8800 needs before
//! it comes back as the Wi-Fi device, A69C:8801.
//!
//! Everything is the debug task's messages, one at a time, each answered
//! by its confirmation: a word read (`readMem`), a word written
//! (`writeMem`), some bits of one written (`maskWrite`), up to a
//! kilobyte written (`blockWrite`), and the program started
//! (`startApp`), which is not answered - the chip leaves the bus.
//!
//! **In order** (`load`): the chip's revision read, which decides the
//! patch files and whether a revision's own writes come first; the
//! system's registers set; the firmware, the patch's address table and
//! the patch itself written where they run; the patch table's list of
//! writes made (`patchTable`); the firmware's configuration patched at
//! the place it says (`configPatch`); one RF register masked; the
//! firmware started at its first word.
//!
//! The transport is the caller's: a message sent whole, and one transfer
//! in read - so the sequence is tested on the host against a pretend
//! chip.

const msg = @import("msg.zig");

const DBG_MEM_READ_REQ = msg.id(msg.TASK_DBG, 0);
const DBG_MEM_READ_CFM = msg.id(msg.TASK_DBG, 1);
const DBG_MEM_WRITE_REQ = msg.id(msg.TASK_DBG, 2);
const DBG_MEM_WRITE_CFM = msg.id(msg.TASK_DBG, 3);
const DBG_MEM_BLOCK_WRITE_REQ = msg.id(msg.TASK_DBG, 11);
const DBG_MEM_BLOCK_WRITE_CFM = msg.id(msg.TASK_DBG, 12);
const DBG_START_APP_REQ = msg.id(msg.TASK_DBG, 13);
const DBG_MEM_MASK_WRITE_REQ = msg.id(msg.TASK_DBG, 17);
const DBG_MEM_MASK_WRITE_CFM = msg.id(msg.TASK_DBG, 18);

/// How much a block write carries; its parameters are this long however
/// little of it is used.
pub const block_bytes = 1024;
/// Where the firmware runs, and the boot type that starts it there.
pub const firmware_address: u32 = 0x00110000;
const adid_address: u32 = 0x00161928;
const patch_address: u32 = 0x00100000;
const boot_auto: u32 = 1;

/// The chip's revision: the third byte of the word at 0x40500000.
pub const REV_U02: u8 = 3;
pub const REV_U03: u8 = 7;
/// The revision's sub-number at 0x00000004 that makes a U03 a U04.
const SUB_U04: u8 = 0x20;

/// How a message reaches the chip and its answers come back.
pub const Transport = msg.Transport;

/// The files the boot ROM is given: the firmware, and the patch files of
/// the chip's revision.
pub const Files = struct {
    firmware: []const u8,
    adid: []const u8,
    patch: []const u8,
    patch_table: []const u8,
};

pub const Error = error{
    /// A message did not go, or its answer did not come.
    NoAnswer,
    /// The chip answered a write as not done.
    Refused,
    /// The patch table is not one.
    BadPatchTable,
};

/// The chip's revision, and its sub-number.
pub const Revision = struct { chip: u8, sub: u8 };

pub const Boot = struct {
    transport: Transport,
    out: [msg.header_bytes + 8 + block_bytes]u8 = undefined,
    in: [2048]u8 = undefined,

    /// `id` with `params` sent, and the parameters of its confirmation
    /// `answer` copied to `into`. Records that are not it are passed
    /// over; the chip's log lines are said.
    fn call(boot: *Boot, id: u16, params: []const u8, answer: u16, into: []u8) Error!void {
        const t = boot.transport;
        const length = msg.request(&boot.out, id, msg.TASK_DBG, params);
        if (length == 0 or !t.send(t.context, boot.out[0..length])) return Error.NoAnswer;
        // A few transfers may come before it: log lines, a stale answer.
        var tries: u32 = 0;
        while (tries < 8) : (tries += 1) {
            const got = t.receive(t.context, &boot.in) orelse return Error.NoAnswer;
            var reader = msg.Reader{ .bytes = boot.in[0..got] };
            while (reader.next()) |record| switch (record) {
                .message => |m| if (m.id == answer) {
                    const count = @min(into.len, m.params.len);
                    @memcpy(into[0..count], m.params[0..count]);
                    return;
                },
                .log => |text| t.say(t.context, text),
                else => {},
            };
        }
        return Error.NoAnswer;
    }

    pub fn readMem(boot: *Boot, address: u32) Error!u32 {
        var params: [4]u8 = undefined;
        msg.put32(&params, 0, address);
        var answer: [8]u8 = @splat(0);
        try boot.call(DBG_MEM_READ_REQ, &params, DBG_MEM_READ_CFM, &answer);
        return msg.get32(&answer, 4);
    }

    pub fn writeMem(boot: *Boot, address: u32, value: u32) Error!void {
        var params: [8]u8 = undefined;
        msg.put32(&params, 0, address);
        msg.put32(&params, 4, value);
        var answer: [8]u8 = undefined;
        try boot.call(DBG_MEM_WRITE_REQ, &params, DBG_MEM_WRITE_CFM, &answer);
    }

    pub fn maskWrite(boot: *Boot, address: u32, mask: u32, value: u32) Error!void {
        var params: [12]u8 = undefined;
        msg.put32(&params, 0, address);
        msg.put32(&params, 4, mask);
        msg.put32(&params, 8, value);
        var answer: [8]u8 = undefined;
        try boot.call(DBG_MEM_MASK_WRITE_REQ, &params, DBG_MEM_MASK_WRITE_CFM, &answer);
    }

    /// Up to `block_bytes` written at `address`.
    pub fn blockWrite(boot: *Boot, address: u32, bytes: []const u8) Error!void {
        var params: [8 + block_bytes]u8 = @splat(0);
        msg.put32(&params, 0, address);
        msg.put32(&params, 4, @intCast(bytes.len));
        @memcpy(params[8..][0..bytes.len], bytes);
        var answer: [4]u8 = @splat(0xFF);
        try boot.call(DBG_MEM_BLOCK_WRITE_REQ, &params, DBG_MEM_BLOCK_WRITE_CFM, &answer);
        if (msg.get32(&answer, 0) != 0) return Error.Refused;
    }

    /// A file written at `address`, a kilobyte at a time.
    pub fn upload(boot: *Boot, address: u32, bytes: []const u8) Error!void {
        var at: usize = 0;
        while (at < bytes.len) : (at += block_bytes) {
            const part = bytes[at..@min(at + block_bytes, bytes.len)];
            try boot.blockWrite(address + @as(u32, @intCast(at)), part);
        }
    }

    /// The program at `address` started: the chip leaves the bus and
    /// answers nothing.
    pub fn startApp(boot: *Boot, address: u32, kind: u32) Error!void {
        var params: [8]u8 = undefined;
        msg.put32(&params, 0, address);
        msg.put32(&params, 4, kind);
        const t = boot.transport;
        const length = msg.request(&boot.out, DBG_START_APP_REQ, msg.TASK_DBG, &params);
        if (!t.send(t.context, boot.out[0..length])) return Error.NoAnswer;
    }

    pub fn revision(boot: *Boot) Error!Revision {
        const chip = try boot.readMem(0x40500000);
        const sub = try boot.readMem(0x00000004);
        return .{ .chip = @truncate(chip >> 16), .sub = @truncate(sub >> 4) };
    }

    /// The whole of it, the files the revision's.
    pub fn load(boot: *Boot, rev: Revision, files: Files) Error!void {
        if (rev.chip == REV_U02) {
            for (pmic_u02) |pair| try boot.writeMem(pair[0], pair[1]);
        }
        if (rev.chip == REV_U03 and rev.sub == SUB_U04) {
            for (system_u04) |pair| try boot.writeMem(pair[0], pair[1]);
        }
        for (system) |pair| try boot.writeMem(pair[0], pair[1]);
        try boot.upload(firmware_address, files.firmware);
        try boot.upload(adid_address, files.adid);
        try boot.upload(patch_address, files.patch);
        try boot.patchTable(files.patch_table);
        try boot.configPatch();
        try boot.maskWrite(0x40344058, 0x00800000, 0);
        try boot.startApp(firmware_address, boot_auto);
    }

    /// The patch table's writes. It begins with a 16-byte tag, then
    /// records: a 16-byte name, a type, a count, and that many pairs of an
    /// address and a value. The Bluetooth mode's record is given this
    /// host's values; a version record is no writes; a power-on record is
    /// followed by a tenth of a second.
    pub fn patchTable(boot: *Boot, table: []const u8) Error!void {
        const tag = "AICBT_PT_TAG";
        if (table.len < 16) return Error.BadPatchTable;
        for (tag, 0..) |char, i| if (table[i] != char) return Error.BadPatchTable;
        var at: usize = 16;
        while (at + 24 <= table.len) {
            const kind = msg.get32(table, at + 16);
            var count: usize = msg.get32(table, at + 20);
            at += 24;
            if (kind >= 1000) count = 0;
            if (at + count * 8 > table.len) return Error.BadPatchTable;
            const pairs = table[at..][0 .. count * 8];
            at += count * 8;
            if (kind == pt_version) continue;
            for (0..count) |i| {
                const address = msg.get32(pairs, i * 8);
                var value = msg.get32(pairs, i * 8 + 4);
                if (kind == pt_btmode and i < btmode_values.len) value = btmode_values[i];
                try boot.writeMem(address, value);
            }
            if (kind == pt_power_on) boot.transport.wait(boot.transport.context, 100);
        }
    }

    /// The firmware's configuration patched: the table's offsets are from
    /// the base the firmware keeps at 0x110180, and the list of address
    /// and value pairs goes at 0x1E6000, its place and length told at
    /// 0x1E5318.
    pub fn configPatch(boot: *Boot) Error!void {
        const config_base = try boot.readMem(firmware_address + 0x180);
        const list: u32 = 0x1E6000;
        try boot.writeMem(0x1E5318, list);
        try boot.writeMem(0x1E531C, config_patch.len * 2);
        for (config_patch, 0..) |pair, i| {
            const at = list + @as(u32, @intCast(i)) * 8;
            try boot.writeMem(at, config_base + pair[0]);
            try boot.writeMem(at + 4, pair[1]);
        }
    }
};

/// The patch table's record types that are not plain writes.
const pt_btmode: u32 = 3;
const pt_power_on: u32 = 4;
const pt_version: u32 = 6;

/// The Bluetooth mode's nine values: hwinfo unset (1, -1), working mode,
/// Bluetooth alone, on the shared port, at 1.5 Mbaud with flow control,
/// no low-power mode, the default transmit level.
const btmode_values = [_]u32{ 1, 0xFFFFFFFF, 0, 2, 1, 1_500_000, 1, 0, 0x6020 };

/// The system's registers: clocks, the power controller, the watchdog
/// stopped. In this order.
const system = [_][2]u32{
    .{ 0x40500014, 0x00000101 },
    .{ 0x40500018, 0x0000010D },
    .{ 0x40500004, 0x00000010 },
    .{ 0x50000000, 0x03220204 },
    .{ 0x50019150, 0x00000002 },
    .{ 0x50017008, 0x00000000 },
};

/// Revision U02 first: a fix the ROM needs.
const pmic_u02 = [_][2]u32{
    .{ 0x40040000, 0x00001AC8 },
    .{ 0x40040084, 0x00011580 },
    .{ 0x40040080, 0x00000001 },
    .{ 0x40100058, 0x00000000 },
};

/// Revision U04 first: a few instructions the ROM jumps to, so the
/// receive queue is not flushed before the firmware starts.
const system_u04 = [_][2]u32{
    .{ 0x40040000, 0x0000042C }, .{ 0x40040004, 0x0000DD44 },
    .{ 0x40040008, 0x00000448 }, .{ 0x4004000C, 0x0000044C },
    .{ 0x0019B800, 0xB9F0F19B }, .{ 0x0019B804, 0x0019B81D },
    .{ 0x0019B808, 0xBF00FA79 }, .{ 0x0019B80C, 0xF007BF00 },
    .{ 0x0019B810, 0x4605B672 }, .{ 0x0019B814, 0x21E0F04F },
    .{ 0x0019B818, 0xBE0BF664 }, .{ 0x0019B81C, 0xF665B510 },
    .{ 0x0019B820, 0x4804FC9D }, .{ 0x0019B824, 0xFA9EF66C },
    .{ 0x0019B828, 0xFCA8F665 }, .{ 0x0019B82C, 0x4010E8BD },
    .{ 0x0019B830, 0xBAC6F66C }, .{ 0x0019B834, 0x0019A0C4 },
    .{ 0x40040084, 0x0019B800 }, .{ 0x40040080, 0x0000000F },
    .{ 0x40100058, 0x00000000 },
};

/// The firmware's configuration: offsets from its base, and the values -
/// the host is USB, where its buffers and descriptors are, the aggregation
/// limits per queue, a message endpoint of its own, how many received
/// messages it sends unasked.
const config_patch = [_][2]u32{
    .{ 0x0044, 0x00000002 }, .{ 0x0048, 0x00000060 }, .{ 0x004C, 0x00040050 },
    .{ 0x0050, 0x00000000 }, .{ 0x0054, 0x00190000 }, .{ 0x0058, 0x00190140 },
    .{ 0x005C, 0x00000EE0 }, .{ 0x0060, 0x00191020 }, .{ 0x0064, 0x0002EFE0 },
    .{ 0x0068, 0x00000008 }, .{ 0x006C, 0x00000040 }, .{ 0x0070, 0x00000040 },
    .{ 0x0074, 0x00000020 }, .{ 0x0078, 0x00000000 }, .{ 0x007C, 0x00000020 },
    .{ 0x0080, 0x001D0000 }, .{ 0x0084, 0x0000FC00 }, .{ 0x0088, 0x001DFC00 },
    .{ 0x00A8, 0x8D080103 }, .{ 0x00D0, 0x00010103 }, .{ 0x00D4, 0x0404087C },
    .{ 0x00D8, 0x001C0000 }, .{ 0x00DC, 0x00008000 }, .{ 0x00E0, 0x04020A08 },
    .{ 0x00E4, 0x00000001 }, .{ 0x00FC, 0x00000302 }, .{ 0x0100, 0x0000000F },
};

// --- tests --------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// A boot ROM: memory as a map of writes, answered as the chip answers.
const Pretend = struct {
    words: std.AutoHashMap(u32, u32),
    blocks: u32 = 0,
    block_bytes_written: usize = 0,
    started: ?u32 = null,
    pending: [64]u8 = undefined,
    pending_len: usize = 0,
    waited: u32 = 0,

    fn of(context: *anyopaque) *Pretend {
        return @ptrCast(@alignCast(context));
    }

    fn send(context: *anyopaque, bytes: []const u8) bool {
        const chip = of(context);
        const id = msg.get16(bytes, 8);
        const params = bytes[msg.header_bytes..];
        var answer: [8]u8 = @splat(0);
        var answer_len: usize = 0;
        var answer_id: u16 = 0;
        switch (id) {
            DBG_MEM_READ_REQ => {
                const address = msg.get32(params, 0);
                msg.put32(&answer, 0, address);
                msg.put32(&answer, 4, chip.words.get(address) orelse 0);
                answer_len = 8;
                answer_id = DBG_MEM_READ_CFM;
            },
            DBG_MEM_WRITE_REQ => {
                chip.words.put(msg.get32(params, 0), msg.get32(params, 4)) catch return false;
                answer_len = 8;
                answer_id = DBG_MEM_WRITE_CFM;
            },
            DBG_MEM_MASK_WRITE_REQ => {
                answer_len = 8;
                answer_id = DBG_MEM_MASK_WRITE_CFM;
            },
            DBG_MEM_BLOCK_WRITE_REQ => {
                if (params.len != 8 + block_bytes) return false;
                chip.blocks += 1;
                chip.block_bytes_written += msg.get32(params, 4);
                answer_len = 4;
                answer_id = DBG_MEM_BLOCK_WRITE_CFM;
            },
            DBG_START_APP_REQ => {
                chip.started = msg.get32(params, 0);
                return true;
            },
            else => return false,
        }
        // The answer comes with a log line in front of it.
        var record: [64]u8 = @splat(0);
        record[0] = 2;
        record[2] = msg.TYPE_LOG;
        record[4] = 'o';
        record[5] = 'k';
        // An answer's header as the chip sends it: the id at byte 4, its
        // parameters at 16.
        const at = 8;
        msg.put32(&record, at, @intCast(12 + answer_len));
        record[at + 2] = msg.TYPE_MESSAGE | 0x80;
        msg.put32(&record, at + 4, @as(u32, msg.TASK_HOST) << 16 | answer_id);
        msg.put32(&record, at + 8, @as(u32, @intCast(answer_len)) << 16 | msg.TASK_DBG);
        msg.put32(&record, at + 12, 0xADDEDE2A);
        @memcpy(record[at + 16 ..][0..answer_len], answer[0..answer_len]);
        const length = 16 + answer_len;
        @memcpy(chip.pending[0 .. at + length], record[0 .. at + length]);
        chip.pending_len = at + length;
        return true;
    }

    fn receive(context: *anyopaque, into: []u8) ?usize {
        const chip = of(context);
        if (chip.pending_len == 0) return null;
        @memcpy(into[0..chip.pending_len], chip.pending[0..chip.pending_len]);
        defer chip.pending_len = 0;
        return chip.pending_len;
    }

    fn wait(context: *anyopaque, ms: u32) void {
        of(context).waited += ms;
    }

    fn say(_: *anyopaque, _: []const u8) void {}
};

test "the boot ROM given everything, in order, and started" {
    var chip = Pretend{ .words = std.AutoHashMap(u32, u32).init(testing.allocator) };
    defer chip.words.deinit();
    try chip.words.put(0x40500000, 0x00070000);
    try chip.words.put(0x00000004, 0x00000200);
    try chip.words.put(firmware_address + 0x180, 0x00171974);
    const boot = try testing.allocator.create(Boot);
    defer testing.allocator.destroy(boot);
    boot.* = .{ .transport = .{ .context = &chip, .send = Pretend.send, .receive = Pretend.receive, .wait = Pretend.wait, .say = Pretend.say } };

    const rev = try boot.revision();
    try testing.expectEqual(REV_U03, rev.chip);
    try testing.expectEqual(@as(u8, 0x20), rev.sub);

    // A patch table: the tag, a write, the Bluetooth mode, power on, a version.
    var table: [256]u8 = @splat(0);
    @memcpy(table[0..12], "AICBT_PT_TAG");
    var at: usize = 16;
    const records = [_]struct { kind: u32, pairs: []const [2]u32 }{
        .{ .kind = 1, .pairs = &.{.{ 0x00100100, 0x11 }} },
        .{ .kind = pt_btmode, .pairs = &.{ .{ 0x00200000, 7 }, .{ 0x00200004, 7 } } },
        .{ .kind = pt_power_on, .pairs = &.{.{ 0x00300000, 1 }} },
        .{ .kind = pt_version, .pairs = &.{.{ 0x00400000, 0x41 }} },
    };
    for (records) |record| {
        msg.put32(&table, at + 16, record.kind);
        msg.put32(&table, at + 20, @intCast(record.pairs.len));
        at += 24;
        for (record.pairs) |pair| {
            msg.put32(&table, at, pair[0]);
            msg.put32(&table, at + 4, pair[1]);
            at += 8;
        }
    }
    var firmware: [2500]u8 = @splat(0xAB);
    try boot.load(rev, .{ .firmware = &firmware, .adid = &.{ 1, 2, 3 }, .patch = &.{ 4, 5 }, .patch_table = table[0..at] });

    // The U04 writes, the system's, then the files in blocks of 1024.
    try testing.expectEqual(@as(u32, 0x0019B800), chip.words.get(0x40040084).?);
    try testing.expectEqual(@as(u32, 0x0000010D), chip.words.get(0x40500018).?);
    try testing.expectEqual(@as(u32, 3 + 1 + 1), chip.blocks);
    try testing.expectEqual(@as(usize, 2500 + 3 + 2), chip.block_bytes_written);
    // The patch table: written, the Bluetooth mode given its own, the
    // version passed over, a tenth of a second after power on.
    try testing.expectEqual(@as(u32, 0x11), chip.words.get(0x00100100).?);
    try testing.expectEqual(@as(u32, 1), chip.words.get(0x00200000).?);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), chip.words.get(0x00200004).?);
    try testing.expect(chip.words.get(0x00400000) == null);
    try testing.expectEqual(@as(u32, 100), chip.waited);
    // The configuration patch, from the firmware's own base.
    try testing.expectEqual(@as(u32, 0x1E6000), chip.words.get(0x1E5318).?);
    try testing.expectEqual(@as(u32, 54), chip.words.get(0x1E531C).?);
    try testing.expectEqual(@as(u32, 0x00171974 + 0x44), chip.words.get(0x1E6000).?);
    try testing.expectEqual(@as(u32, 0x0F), chip.words.get(0x1E6000 + 26 * 8 + 4).?);
    try testing.expectEqual(firmware_address, chip.started.?);
}

test "a patch table without its tag is refused" {
    var chip = Pretend{ .words = std.AutoHashMap(u32, u32).init(testing.allocator) };
    defer chip.words.deinit();
    var boot = Boot{ .transport = .{ .context = &chip, .send = Pretend.send, .receive = Pretend.receive, .wait = Pretend.wait, .say = Pretend.say } };
    try testing.expectError(Error.BadPatchTable, boot.patchTable("NOT_A_TABLE_AT_ALL_NO"));
}
