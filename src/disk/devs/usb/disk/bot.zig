// SPDX-License-Identifier: MIT
//! Bulk-Only Transport (USB Mass Storage Class, Bulk-Only 1.0): how a
//! SCSI command goes to a stick. Each command is three stages on the
//! interface's two bulk endpoints: the command block wrapper (31 bytes,
//! out) carrying the command block and the logical unit, the data (in or
//! out, as the wrapper says, at most its length), and the status wrapper
//! (13 bytes, in) - whether the command passed, failed or lost its way,
//! and how much of the data it did not use.
//!
//! **When it goes wrong.** A stall in the data stage is the device
//! refusing the rest of the data: the halt is cleared and the status read
//! as usual. A stall on the status is cleared and the status read once
//! more. A status that is not one - the wrong length, signature or tag -
//! or a phase error, or a transfer that fails outright, takes the reset
//! recovery: the interface reset by its class request and both endpoints'
//! halts cleared, after which the next command starts clean. A device
//! that has gone is not reset; the caller hears that it has.
//!
//! **A device being let go of** (`leaving`, set by the driver's unbind,
//! which then aborts the pipes' transfers) ends the command at its next
//! stage - and a transfer aborted under it - as a device that has gone,
//! rather than after a timeout on a device that is no longer there.
//!
//! The wrappers are built and read here without hardware (the host tests
//! hold that part); `run` drives the pipes.

const sdk = @import("sdk");
const exec = sdk.exec;
const usb = sdk.usb;
const d = usb.descriptors;
const usbhc = sdk.devices.usbhc;
const ExecBase = sdk.interface.exec.ExecBase;
const UsbBase = sdk.interface.usb.UsbBase;

pub const cbw_bytes = 31;
pub const csw_bytes = 13;
const CBW_SIGNATURE: u32 = 0x4342_5355; // "USBC"
const CSW_SIGNATURE: u32 = 0x5342_5355; // "USBS"
const CBW_FLAG_IN: u8 = 0x80;

/// bCSWStatus.
pub const CSW_PASSED: u8 = 0;
pub const CSW_FAILED: u8 = 1;
pub const CSW_PHASE_ERROR: u8 = 2;

fn putLe32(into: []u8, value: u32) void {
    into[0] = @truncate(value);
    into[1] = @truncate(value >> 8);
    into[2] = @truncate(value >> 16);
    into[3] = @truncate(value >> 24);
}

fn getLe32(from: []const u8) u32 {
    return @as(u32, from[0]) | @as(u32, from[1]) << 8 | @as(u32, from[2]) << 16 | @as(u32, from[3]) << 24;
}

/// The command block wrapper for `command`, to logical unit `lun`, whose
/// data stage moves `length` bytes in (from the device) or out.
pub fn wrapperOf(into: *[cbw_bytes]u8, tag: u32, length: u32, in: bool, lun: u8, command: []const u8) void {
    into.* = @splat(0);
    putLe32(into[0..4], CBW_SIGNATURE);
    putLe32(into[4..8], tag);
    putLe32(into[8..12], length);
    into[12] = if (in) CBW_FLAG_IN else 0;
    into[13] = lun & 0x0F;
    const count = @min(command.len, 16);
    into[14] = @intCast(count);
    @memcpy(into[15..][0..count], command[0..count]);
}

/// What a status wrapper says: the status, and the bytes of the data
/// stage the command did not use.
pub const Status = struct { status: u8, residue: u32 };

/// The status wrapper `data` - null when it is not one for the command
/// tagged `tag`.
pub fn statusOf(data: []const u8, tag: u32) ?Status {
    if (data.len != csw_bytes) return null;
    if (getLe32(data[0..4]) != CSW_SIGNATURE or getLe32(data[4..8]) != tag) return null;
    if (data[12] > CSW_PHASE_ERROR) return null;
    return .{ .status = data[12], .residue = getLe32(data[8..12]) };
}

/// How a command ended: it passed, it failed (the device has a sense to
/// say why), the device has gone, or the transport broke and was reset.
pub const Outcome = enum { passed, failed, gone, broken };

pub const Result = struct {
    outcome: Outcome,
    /// The bytes the data stage moved.
    moved: u32 = 0,
};

/// One interface's way to its device: the pipes, and the wrappers' bytes.
pub const Transport = struct {
    sys: *ExecBase,
    ub: *UsbBase,
    device: *usb.USBDevice,
    interface_number: u8,
    bulk_in: *usb.USBPipe,
    bulk_out: *usb.USBPipe,
    tag: u32 = 0,
    /// Set by the unbind: the device is being let go of.
    leaving: u8 = 0,
    wrapper: [cbw_bytes]u8 = @splat(0),
    status: [csw_bytes]u8 = @splat(0),
};

/// How long a device may keep a stage waiting, in milliseconds: the
/// wrapper goes at once, a status may wait for the medium to finish a
/// write.
const wrapper_ms: u32 = 5_000;
const status_ms: u32 = 20_000;

/// A command run: `command` to logical unit `lun`, its data stage `length`
/// bytes into `data` (`in`) or from it, given `data_ms` to come.
pub fn run(transport: *Transport, lun: u8, command: []const u8, data: ?[*]u8, length: u32, in: bool, data_ms: u32) Result {
    if (leaving(transport)) return .{ .outcome = .gone };
    transport.tag +%= 1;
    const tag = transport.tag;
    wrapperOf(&transport.wrapper, tag, if (data == null) 0 else length, in, lun, command);
    switch (move(transport, transport.bulk_out, &transport.wrapper, cbw_bytes, wrapper_ms)) {
        0 => {},
        usbhc.UHIOERR_DETACHED, exec.IOERR_ABORTED => return .{ .outcome = .gone },
        else => return broken(transport),
    }
    var moved: u32 = 0;
    if (data) |bytes| if (length > 0) {
        const pipe = if (in) transport.bulk_in else transport.bulk_out;
        switch (move(transport, pipe, bytes, length, data_ms)) {
            0 => {},
            // The device refused the rest: its halt cleared, and the
            // status says how the command ended.
            usbhc.UHIOERR_STALL => _ = transport.ub.ClearUSBStall(pipe),
            usbhc.UHIOERR_DETACHED, exec.IOERR_ABORTED => return .{ .outcome = .gone },
            else => return broken(transport),
        }
        moved = @intCast(pipe.io.std.actual);
    };
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        switch (move(transport, transport.bulk_in, &transport.status, csw_bytes, status_ms)) {
            0 => break,
            usbhc.UHIOERR_STALL => {
                _ = transport.ub.ClearUSBStall(transport.bulk_in);
                if (tries == 0) continue;
                return broken(transport);
            },
            usbhc.UHIOERR_DETACHED, exec.IOERR_ABORTED => return .{ .outcome = .gone },
            else => return broken(transport),
        }
    }
    const got: usize = @intCast(transport.bulk_in.io.std.actual);
    const said = statusOf(transport.status[0..@min(got, csw_bytes)], tag) orelse return broken(transport);
    return switch (said.status) {
        CSW_PASSED => .{ .outcome = .passed, .moved = moved },
        CSW_FAILED => .{ .outcome = .failed, .moved = moved },
        else => broken(transport),
    };
}

fn leaving(transport: *const Transport) bool {
    return @atomicLoad(u8, &transport.leaving, .acquire) != 0;
}

/// `length` bytes over `pipe`, waiting at most `ms` for the device:
/// io_Error - IOERR_ABORTED without sending, once the device is being
/// let go of.
fn move(transport: *Transport, pipe: *usb.USBPipe, bytes: [*]u8, length: u32, ms: u32) i8 {
    if (leaving(transport)) return exec.IOERR_ABORTED;
    const io = &pipe.io;
    io.std.data = @ptrCast(bytes);
    io.std.length = length;
    io.std.actual = 0;
    io.nak_timeout = ms;
    _ = transport.sys.DoIO(&io.std.req);
    return io.std.req.err;
}

/// The reset recovery: the interface reset, both endpoints' halts
/// cleared. The command that needed it is answered as broken - or as gone,
/// for a device being let go of, which is not spoken to again.
fn broken(transport: *Transport) Result {
    if (leaving(transport)) return .{ .outcome = .gone };
    reset(transport);
    return .{ .outcome = .broken };
}

pub fn reset(transport: *Transport) void {
    const setup = usb.SetupPacket{
        .request_type = d.USB_DIR_OUT | d.USB_TYPE_CLASS | d.USB_RECIP_INTERFACE,
        .request = d.MSC_REQ_RESET,
        .value = 0,
        .index = transport.interface_number,
        .length = 0,
    };
    _ = transport.ub.DoUSBControl(transport.device, &setup, null, null);
    _ = transport.ub.ClearUSBStall(transport.bulk_in);
    _ = transport.ub.ClearUSBStall(transport.bulk_out);
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

test "a command block wrapper: signature, tag, length, direction, unit, command" {
    var wrapper: [cbw_bytes]u8 = undefined;
    wrapperOf(&wrapper, 0x0102_0304, 512, true, 1, &.{ 0x28, 0, 0, 0, 0, 7, 0, 0, 1, 0 });
    try testing.expectEqualSlices(u8, &.{ 0x55, 0x53, 0x42, 0x43 }, wrapper[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0x04, 0x03, 0x02, 0x01 }, wrapper[4..8]);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x02, 0x00, 0x00 }, wrapper[8..12]);
    try testing.expectEqual(@as(u8, 0x80), wrapper[12]);
    try testing.expectEqual(@as(u8, 1), wrapper[13]);
    try testing.expectEqual(@as(u8, 10), wrapper[14]);
    try testing.expectEqual(@as(u8, 0x28), wrapper[15]);
    try testing.expectEqual(@as(u8, 7), wrapper[20]);
    try testing.expectEqual(@as(u8, 0), wrapper[25]);
}

test "a status wrapper is the command's only with its signature and tag" {
    const good = [_]u8{ 0x55, 0x53, 0x42, 0x53, 9, 0, 0, 0, 0x00, 0x02, 0, 0, CSW_FAILED };
    const said = statusOf(&good, 9).?;
    try testing.expectEqual(CSW_FAILED, said.status);
    try testing.expectEqual(@as(u32, 512), said.residue);
    try testing.expect(statusOf(&good, 8) == null);
    try testing.expect(statusOf(good[0..12], 9) == null);
    var bad = good;
    bad[3] = 0x43;
    try testing.expect(statusOf(&bad, 9) == null);
    bad = good;
    bad[12] = 3;
    try testing.expect(statusOf(&bad, 9) == null);
}
