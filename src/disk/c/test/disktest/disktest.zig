// SPDX-License-Identifier: MIT
//! DiskTest: a block device's unit looked at through its requests - its
//! geometry, the partition table in its first blocks, how fast it reads
//! - and, only when asked, how fast it writes and whether what was
//! written reads back. Built against the SDK only.
//!
//!   DiskTest DEVICE/A,UNIT/N,SPEED/K/N,BUFFER/K/N,ALIGN/K/N,AT/K/N,WRITE/S,COMPARE/S
//!
//!   DiskTest nvme.device              unit 0: its size, and its MBR or
//!                                     GPT partitions
//!   DiskTest nvme.device SPEED 64     ... and 64 MiB read from block 0
//!                                     in requests of 1 MiB
//!   DiskTest nvme.device SPEED 64 BUFFER 4194304
//!                                     ... in requests of 4 MiB
//!   DiskTest nvme.device SPEED 64 ALIGN 16
//!                                     ... into a buffer 16 bytes past
//!                                     a page, as an AllocVec'd one is
//!   DiskTest nvme.device SPEED 64 ALIGN 3 COMPARE
//!                                     ... and read again, each request
//!                                     twice - into that buffer and into
//!                                     one on a page - and compared
//!   DiskTest nvme.device SPEED 8 AT 4096 WRITE
//!                                     8 MiB from block 4096 written with
//!                                     a pattern, put on the medium
//!                                     (CMD_UPDATE), read back and
//!                                     compared: **what was there is
//!                                     gone**
//!
//! Only reads are sent without WRITE; COMPARE reads only too. A GPT is read where block 0 holds
//! the protective MBR's partition (type 0xEE): its header in block 1,
//! and its partitions where the header says, each with its type named
//! where it is one of the usual.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const td = sdk.devices.trackdisk;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const TimerBase = sdk.interface.timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "DiskTest";
const VERSION_STRING = "\x00$VER: DiskTest 1.0 (18.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DEVICE/A,UNIT/N,SPEED/K/N,BUFFER/K/N,ALIGN/K/N,AT/K/N,WRITE/S,COMPARE/S";
const arg_device = 0;
const arg_unit = 1;
const arg_speed = 2;
const arg_buffer = 3;
const arg_align = 4;
const arg_at = 5;
const arg_write = 6;
const arg_compare = 7;

/// What one request of the speed test moves without BUFFER, and at most.
const default_request: u32 = 1024 * 1024;
const most_request: u32 = 64 * 1024 * 1024;

const Disk = struct {
    sys: *ExecBase,
    dl: *DosBase,
    io: exec.IOStdReq = .{},
    block: u32 = 512,
    blocks: u64 = 0,

    /// `command` of `length` bytes at `offset`: io_Error.
    fn send(disk: *Disk, command: u16, offset: u64, length: u64, data: ?*anyopaque) i8 {
        disk.io.req.command = command;
        disk.io.offset = offset;
        disk.io.length = length;
        disk.io.data = data;
        disk.io.actual = 0;
        _ = disk.sys.DoIO(&disk.io.req);
        return disk.io.req.err;
    }
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [8]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const device: [*:0]const u8 = @ptrFromInt(argv[arg_device]);
    const unit = number(argv[arg_unit], 0);
    const speed_mib = number(argv[arg_speed], 0);
    const offset_bytes = number(argv[arg_align], 0) % 4096;
    const at = number(argv[arg_at], 0);
    const write = argv[arg_write] != 0;
    const compare = argv[arg_compare] != 0;
    const request_bytes = std.mem.alignForward(u32, std.math.clamp(number(argv[arg_buffer], default_request), 4096, most_request), 4096);

    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    var disk = Disk{ .sys = sys, .dl = dl };
    disk.io.req.message.reply_port = port;
    disk.io.req.message.length = @sizeOf(exec.IOStdReq);
    if (sys.OpenDevice(device, unit, &disk.io.req, 0) != 0) {
        _ = Printf(dl, "%s: cannot open %s unit %u\n", .{ COMMAND_NAME, device, unit });
        return dos.RETURN_ERROR;
    }
    defer sys.CloseDevice(&disk.io.req);

    var geometry = td.DriveGeometry{};
    if (disk.send(td.TD_GETGEOMETRY, 0, @sizeOf(td.DriveGeometry), &geometry) != 0 or geometry.sector_size == 0) {
        _ = Printf(dl, "%s unit %u: no geometry (error %d)\n", .{ device, unit, @as(i32, disk.io.req.err) });
        return dos.RETURN_ERROR;
    }
    disk.block = geometry.sector_size;
    disk.blocks = geometry.total_sectors;
    const mib = (disk.blocks * disk.block) >> 20;
    _ = Printf(dl, "%s unit %u: %lu blocks of %u bytes, %lu MiB\n", .{ device, unit, disk.blocks, disk.block, mib });

    // COMPARE's buffer on the page after the other's end.
    const buffer_bytes = request_bytes + 2 * 4096 + if (compare) request_bytes + 4096 else 0;
    const memory = sys.AllocVec(buffer_bytes, exec.MEMF_ANY) orelse {
        _ = Printf(dl, "%s: no memory\n", .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const page = std.mem.alignForward(usize, @intFromPtr(memory), 4096);
    const buffer: [*]u8 = @ptrFromInt(page + offset_bytes);

    showPartitions(&disk, buffer);

    if (speed_mib == 0) return dos.RETURN_OK;
    const first = @as(u64, at) * disk.block;
    const total = @as(u64, speed_mib) << 20;
    if (first > disk.blocks * disk.block or total > disk.blocks * disk.block - first) {
        _ = Printf(dl, "%s: %u MiB from block %u is past the unit's end\n", .{ COMMAND_NAME, speed_mib, at });
        return dos.RETURN_ERROR;
    }
    var clock: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&clock.node);
    const timer_base: *TimerBase = @ptrCast(@alignCast(clock.node.device.?));
    const where: [*:0]const u8 = if (offset_bytes == 0) "on a page" else "off a page";

    if (write) {
        const started = eclock(timer_base);
        var done: u64 = 0;
        while (done < total) {
            const piece: u32 = @intCast(@min(total - done, request_bytes));
            fill(buffer[0..piece], first + done);
            if (disk.send(exec.CMD_WRITE, first + done, piece, buffer) != 0) return failed(&disk, "write", first + done);
            done += piece;
        }
        if (disk.send(exec.CMD_UPDATE, 0, 0, null) != 0) return failed(&disk, "update", 0);
        report(dl, "written", total, eclock(timer_base) - started, where);
    }

    const started = eclock(timer_base);
    var done: u64 = 0;
    var mismatch: ?u64 = null;
    while (done < total) {
        const piece: u32 = @intCast(@min(total - done, request_bytes));
        if (disk.send(exec.CMD_READ, first + done, piece, buffer) != 0) return failed(&disk, "read", first + done);
        if (write and mismatch == null) mismatch = differs(buffer[0..piece], first + done);
        done += piece;
    }
    report(dl, "read", total, eclock(timer_base) - started, where);
    if (write) {
        if (mismatch) |byte| {
            _ = Printf(dl, "%s: what was written differs from byte %lu on\n", .{ COMMAND_NAME, byte });
            return dos.RETURN_ERROR;
        }
        _ = Printf(dl, "what was written read back as it was\n", .{});
    }
    if (!compare) return dos.RETURN_OK;

    // Each buffer filled with its own bytes first: a request that leaves
    // a part of one as it was differs too.
    const check: [*]u8 = @ptrFromInt(page + request_bytes + 4096);
    done = 0;
    while (done < total) {
        const piece: u32 = @intCast(@min(total - done, request_bytes));
        @memset(buffer[0..piece], 0xA5);
        @memset(check[0..piece], 0x5A);
        if (disk.send(exec.CMD_READ, first + done, piece, buffer) != 0) return failed(&disk, "read", first + done);
        if (disk.send(exec.CMD_READ, first + done, piece, check) != 0) return failed(&disk, "read", first + done);
        if (std.mem.indexOfDiff(u8, buffer[0..piece], check[0..piece])) |byte| {
            _ = Printf(dl, "%s: byte %lu read into the buffer %s differs from it read on a page\n", .{ COMMAND_NAME, first + done + byte, where });
            return dos.RETURN_ERROR;
        }
        done += piece;
    }
    _ = Printf(dl, "%lu MiB read twice, the buffer %s and on a page, alike\n", .{ total >> 20, where });
    return dos.RETURN_OK;
}

fn number(arg: usize, default: u32) u32 {
    if (arg == 0) return default;
    return @bitCast(@as(*const i32, @ptrFromInt(arg)).*);
}

fn failed(disk: *Disk, what: [*:0]const u8, offset: u64) i32 {
    _ = Printf(disk.dl, "%s: %s at byte %lu failed (error %d)\n", .{ COMMAND_NAME, what, offset, @as(i32, disk.io.req.err) });
    return dos.RETURN_ERROR;
}

fn report(dl: *DosBase, what: [*:0]const u8, bytes: u64, us: u64, where: [*:0]const u8) void {
    const took = @max(us, 1);
    const kib_s = bytes * 1_000_000 / took / 1024;
    _ = Printf(dl, "%lu MiB %s in %lu ms, %lu.%02lu MiB/s, the buffer %s\n", .{ bytes >> 20, what, took / 1000, kib_s / 1024, kib_s % 1024 * 100 / 1024, where });
}

/// The pattern the write test writes: each word its own byte offset on
/// the medium, mixed.
fn fill(bytes: []u8, offset: u64) void {
    var i: usize = 0;
    while (i < bytes.len) : (i += 8) std.mem.writeInt(u64, bytes[i..][0..8], pattern(offset + i), .little);
}

fn differs(bytes: []const u8, offset: u64) ?u64 {
    var i: usize = 0;
    while (i < bytes.len) : (i += 8) {
        if (std.mem.readInt(u64, bytes[i..][0..8], .little) != pattern(offset + i)) return offset + i;
    }
    return null;
}

fn pattern(offset: u64) u64 {
    return offset *% 0x9E37_79B9_7F4A_7C15 ^ 0x5A5A_5A5A_5A5A_5A5A;
}

/// The E-clock in microseconds.
fn eclock(timer_base: *TimerBase) u64 {
    var value: timer.EClockVal = .{};
    const rate = timer_base.ReadEClock(&value);
    const count = value.toTicks();
    return count / rate * 1_000_000 + count % rate * 1_000_000 / rate;
}

// --- partition tables ---------------------------------------------------------------------

fn showPartitions(disk: *Disk, buffer: [*]u8) void {
    const dl = disk.dl;
    if (disk.send(exec.CMD_READ, 0, disk.block, buffer) != 0) {
        _ = Printf(dl, "block 0 does not read (error %d)\n", .{@as(i32, disk.io.req.err)});
        return;
    }
    const sector = buffer[0..512];
    if (sector[510] != 0x55 or sector[511] != 0xAA) {
        _ = Printf(dl, "no partition table in block 0\n", .{});
        return;
    }
    var protective = false;
    _ = Printf(dl, "MBR:\n", .{});
    for (0..4) |n| {
        const entry = sector[446 + n * 16 ..][0..16];
        const kind = entry[4];
        if (kind == 0) continue;
        const start = std.mem.readInt(u32, entry[8..12], .little);
        const count = std.mem.readInt(u32, entry[12..16], .little);
        _ = Printf(dl, "  %u: type 0x%02x, blocks %u to %u%s\n", .{ @as(u32, @intCast(n + 1)), @as(u32, kind), start, start +% count -% 1, @as([*:0]const u8, if (entry[0] & 0x80 != 0) ", active" else "") });
        if (kind == 0xEE) protective = true;
    }
    if (protective) showGpt(disk, buffer);
}

const known_types = [_]struct { guid: [16]u8, name: [*:0]const u8 }{
    .{ .guid = .{ 0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B }, .name = "EFI System" },
    .{ .guid = .{ 0xAF, 0x3D, 0xC6, 0x0F, 0x83, 0x84, 0x72, 0x47, 0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4 }, .name = "Linux filesystem" },
    .{ .guid = .{ 0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44, 0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7 }, .name = "Microsoft basic data" },
    .{ .guid = .{ 0x6D, 0xFD, 0x57, 0x06, 0xAB, 0xA4, 0xC4, 0x43, 0x84, 0xE5, 0x09, 0x33, 0xC8, 0x4B, 0x4F, 0x4F }, .name = "Linux swap" },
};

fn showGpt(disk: *Disk, buffer: [*]u8) void {
    const dl = disk.dl;
    if (disk.send(exec.CMD_READ, disk.block, disk.block, buffer) != 0) {
        _ = Printf(dl, "GPT: block 1 does not read (error %d)\n", .{@as(i32, disk.io.req.err)});
        return;
    }
    const header = buffer[0..92];
    if (!std.mem.eql(u8, header[0..8], "EFI PART")) {
        _ = Printf(dl, "GPT: no header in block 1\n", .{});
        return;
    }
    const first_usable = std.mem.readInt(u64, header[40..48], .little);
    const last_usable = std.mem.readInt(u64, header[48..56], .little);
    const entries_at = std.mem.readInt(u64, header[72..80], .little);
    const count = std.mem.readInt(u32, header[80..84], .little);
    const size = std.mem.readInt(u32, header[84..88], .little);
    var guid: [37]u8 = undefined;
    formatGuid(header[56..72], &guid);
    _ = Printf(dl, "GPT: disk %s, blocks %lu to %lu usable, %u entries of %u bytes from block %lu\n", .{ @as([*:0]const u8, @ptrCast(&guid)), first_usable, last_usable, count, size, entries_at });
    if (size < 128 or size > disk.block or count > 1024) return;
    const per_block = disk.block / size;
    var block: u64 = entries_at;
    var n: u32 = 0;
    while (n < count) : (block += 1) {
        if (disk.send(exec.CMD_READ, block * disk.block, disk.block, buffer) != 0) return;
        var i: u32 = 0;
        while (i < per_block and n < count) : ({
            i += 1;
            n += 1;
        }) {
            const entry = buffer[i * size ..][0..128];
            if (std.mem.allEqual(u8, entry[0..16], 0)) continue;
            const start = std.mem.readInt(u64, entry[32..40], .little);
            const end = std.mem.readInt(u64, entry[40..48], .little);
            var name: [37:0]u8 = @splat(0);
            for (0..36) |c| {
                const unit = std.mem.readInt(u16, entry[56 + c * 2 ..][0..2], .little);
                if (unit == 0) break;
                name[c] = if (unit >= 0x20 and unit < 0x7F) @intCast(unit) else '?';
            }
            formatGuid(entry[0..16], &guid);
            var kind: [*:0]const u8 = @ptrCast(&guid);
            for (known_types) |known| {
                if (std.mem.eql(u8, &known.guid, entry[0..16])) kind = known.name;
            }
            const mib = ((end - start + 1) * disk.block) >> 20;
            _ = Printf(dl, "  %u: blocks %lu to %lu, %lu MiB, %s \"%s\"\n", .{ n + 1, start, end, mib, kind, @as([*:0]const u8, &name) });
        }
    }
}

/// A GUID as it is written: its first three fields stored little-endian.
fn formatGuid(bytes: *const [16]u8, into: *[37]u8) void {
    const digits = "0123456789ABCDEF";
    const order = [_]u8{ 3, 2, 1, 0, 0xFF, 5, 4, 0xFF, 7, 6, 0xFF, 8, 9, 0xFF, 10, 11, 12, 13, 14, 15 };
    var at: usize = 0;
    for (order) |index| {
        if (index == 0xFF) {
            into[at] = '-';
            at += 1;
            continue;
        }
        into[at] = digits[bytes[index] >> 4];
        into[at + 1] = digits[bytes[index] & 0xF];
        at += 2;
    }
    into[at] = 0;
}
