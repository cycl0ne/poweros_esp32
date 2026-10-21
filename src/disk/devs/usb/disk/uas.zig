// SPDX-License-Identifier: MIT
//! USB Attached SCSI (UAS 1.0): how a SCSI command goes to a disk over
//! four bulk pipes, each named by the Pipe Usage descriptor after its
//! endpoint. The command pipe (out) takes a Command IU - the command
//! block, its tag and its logical unit - the status pipe (in) answers
//! with a Sense IU - the SCSI status, and the sense data of a command
//! that failed - and the data goes on the data-in and data-out pipes.
//!
//! **At SuperSpeed** the status and data pipes have streams, and a
//! command's are the stream of its tag: its status transfer and its data
//! transfer are out before its Command IU goes, and the device moves
//! each when it is ready. **Below SuperSpeed** the device says when: a
//! Read Ready or Write Ready IU on the status pipe before the data, then
//! the Sense IU.
//!
//! **One command at a time**, as the task runs them: every command is tag
//! 1, a task management function tag 2.
//!
//! **Sense comes with the status.** The Sense IU of a command that failed
//! carries its sense data, which is kept, and the REQUEST SENSE that
//! follows is answered from it without going to the device.
//!
//! **When it goes wrong.** A stall in the data stage is the device
//! refusing the rest of the data: the halt is cleared and the status read
//! as usual. A status that is not one for the command, a transfer that
//! fails outright, or a status that does not come takes the recovery:
//! whatever is still out taken back, LOGICAL UNIT RESET (a Task
//! Management IU, answered by a Response IU), every pipe's halt cleared.
//! A device that has gone is not reset; the caller hears that it has.
//!
//! **A device being let go of** (`leaving`, set by the driver's unbind,
//! which then aborts every pipe's transfer) ends the command at its next
//! stage as a device that has gone.
//!
//! The IUs are built and read here without hardware (the host tests hold
//! that part); `run` drives the pipes.

const sdk = @import("sdk");
const exec = sdk.exec;
const usb = sdk.usb;
const usbhc = sdk.devices.usbhc;
const scsidisk = sdk.devices.scsidisk;
const ExecBase = sdk.interface.exec.ExecBase;
const UsbBase = sdk.interface.usb.UsbBase;
const bot = @import("bot.zig");
const scsi = @import("scsi.zig");

/// The IUs, by their first byte.
pub const IU_COMMAND: u8 = 0x01;
pub const IU_SENSE: u8 = 0x03;
pub const IU_RESPONSE: u8 = 0x04;
pub const IU_TASK_MANAGEMENT: u8 = 0x05;
pub const IU_READ_READY: u8 = 0x06;
pub const IU_WRITE_READY: u8 = 0x07;
/// A Task Management IU's function: every task of the logical unit
/// ended, and the unit reset.
pub const TMF_LOGICAL_UNIT_RESET: u8 = 0x08;

pub const command_iu_bytes = 32;
pub const task_iu_bytes = 16;
/// The most a status transfer takes: a Sense IU's 16 bytes and 96 of
/// sense data.
pub const status_bytes = 112;

/// The tags: the command's - at SuperSpeed its status and data stream -
/// and a task management function's.
pub const command_tag: u16 = 1;
pub const task_tag: u16 = 2;

fn putBe16(into: []u8, value: u16) void {
    into[0] = @truncate(value >> 8);
    into[1] = @truncate(value);
}

fn getBe16(from: []const u8) u16 {
    return @as(u16, from[0]) << 8 | from[1];
}

/// The Command IU for `command`, tagged `tag`, to logical unit `lun`: a
/// simple task, the command block in 16 bytes, and the logical unit in
/// the single-level form - its number in the LUN's second byte.
pub fn commandOf(into: *[command_iu_bytes]u8, tag: u16, lun: u8, command: []const u8) void {
    into.* = @splat(0);
    into[0] = IU_COMMAND;
    putBe16(into[2..4], tag);
    into[9] = lun;
    const count = @min(command.len, 16);
    @memcpy(into[16..][0..count], command[0..count]);
}

/// The Task Management IU of `function`, tagged `tag`, for logical unit
/// `lun`.
pub fn taskOf(into: *[task_iu_bytes]u8, tag: u16, function: u8, lun: u8) void {
    into.* = @splat(0);
    into[0] = IU_TASK_MANAGEMENT;
    putBe16(into[2..4], tag);
    into[4] = function;
    into[9] = lun;
}

/// What an IU on the status pipe says: which it is; a Sense IU's SCSI
/// status and sense data; a Response IU's code.
pub const Iu = struct {
    id: u8,
    status: u8 = 0,
    sense: []const u8 = &.{},
    code: u8 = 0,
};

/// The IU `data`, if it is one for tag `tag` - null for one of another
/// tag, of no kind the status pipe carries, or too short to be one.
pub fn iuOf(data: []const u8, tag: u16) ?Iu {
    if (data.len < 4 or getBe16(data[2..4]) != tag) return null;
    switch (data[0]) {
        IU_READ_READY, IU_WRITE_READY => return .{ .id = data[0] },
        IU_SENSE => {
            if (data.len < 16) return null;
            const length = @min(getBe16(data[14..16]), data.len - 16);
            return .{ .id = IU_SENSE, .status = data[6], .sense = data[16..][0..length] };
        },
        IU_RESPONSE => {
            if (data.len < 8) return null;
            return .{ .id = IU_RESPONSE, .code = data[7] };
        },
        else => return null,
    }
}

/// One interface's way to its device: the pipes, and the IUs' bytes.
pub const Transport = struct {
    sys: *ExecBase,
    ub: *UsbBase,
    device: *usb.USBDevice,
    /// The command pipe; the status pipe - at SuperSpeed on the command's
    /// stream, with a second on the task management function's - and the
    /// data pipes, at SuperSpeed on the command's stream.
    command: *usb.USBPipe,
    status: *usb.USBPipe,
    status_task: ?*usb.USBPipe = null,
    data_in: *usb.USBPipe,
    data_out: *usb.USBPipe,
    /// The status and data pipes are on streams: the device is at
    /// SuperSpeed.
    streams: bool = false,
    /// Set by the unbind: the device is being let go of.
    leaving: u8 = 0,
    /// The sense data of the last command that failed, until REQUEST
    /// SENSE takes it.
    sense: [scsi.sense_bytes]u8 = @splat(0),
    sense_length: u8 = 0,
    iu: [command_iu_bytes]u8 = @splat(0),
    answer: [status_bytes]u8 = @splat(0),
};

/// How long a device may keep a stage waiting, in milliseconds: an IU
/// goes at once, a status may wait for the medium to finish a write.
const iu_ms: u32 = 5_000;
const status_ms: u32 = 20_000;

/// A command run: `command` to logical unit `lun`, its data stage
/// `length` bytes into `data` (`in`) or from it, given `data_ms` to come.
pub fn run(transport: *Transport, lun: u8, command: []const u8, data: ?[*]u8, length: u32, in: bool, data_ms: u32) bot.Result {
    if (leaving(transport)) return .{ .outcome = .gone };
    if (command.len != 0 and command[0] == scsi.OP_REQUEST_SENSE and transport.sense_length != 0) {
        return keptSense(transport, data, length);
    }
    transport.sense_length = 0;
    commandOf(&transport.iu, command_tag, lun, command);
    const moving = data != null and length > 0;
    const pipe = if (in) transport.data_in else transport.data_out;
    if (transport.streams) return runOnStreams(transport, pipe, data, length, moving, data_ms);
    return runWhenReady(transport, pipe, data, length, moving, in, data_ms);
}

/// REQUEST SENSE answered from the sense the last command's Sense IU
/// carried.
fn keptSense(transport: *Transport, data: ?[*]u8, length: u32) bot.Result {
    const got: u32 = @min(length, transport.sense_length);
    if (data) |into| @memcpy(into[0..got], transport.sense[0..got]);
    transport.sense_length = 0;
    return .{ .outcome = .passed, .moved = if (data == null) 0 else got };
}

/// At SuperSpeed: the data transfer and the status transfer out on the
/// command's stream, then the Command IU; the status waited for, and the
/// data - taken back if the command failed without moving it all.
fn runOnStreams(transport: *Transport, pipe: *usb.USBPipe, data: ?[*]u8, length: u32, moving: bool, data_ms: u32) bot.Result {
    if (moving) send(transport, pipe, data.?, length, data_ms);
    send(transport, transport.status, &transport.answer, status_bytes, status_ms);
    const sent = move(transport, transport.command, &transport.iu, command_iu_bytes, iu_ms);
    if (sent != 0) {
        takeBack(transport, transport.status);
        if (moving) takeBack(transport, pipe);
        return failedOn(transport, sent);
    }
    const answered = finish(transport, transport.status);
    const iu = if (answered == 0) iuOf(transport.answer[0..actualOf(transport.status)], command_tag) else null;
    const said = iu orelse {
        if (moving) takeBack(transport, pipe);
        return if (answered != 0) failedOn(transport, answered) else broken(transport);
    };
    if (said.id != IU_SENSE) {
        if (moving) takeBack(transport, pipe);
        return broken(transport);
    }
    var moved: u32 = 0;
    if (moving) {
        if (said.status != scsidisk.SCSI_STATUS_GOOD) _ = transport.sys.AbortIO(&pipe.io.std.req);
        switch (finish(transport, pipe)) {
            0 => {},
            // Taken back above, the command having failed - or by the
            // unbind.
            exec.IOERR_ABORTED => if (leaving(transport)) return .{ .outcome = .gone },
            // The device refused the rest: its halt cleared, and the
            // status says how the command ended.
            usbhc.UHIOERR_STALL => _ = transport.ub.ClearUSBStall(pipe),
            usbhc.UHIOERR_DETACHED => return .{ .outcome = .gone },
            else => return broken(transport),
        }
        moved = actualOf(pipe);
    }
    return ended(transport, said, moved);
}

/// Below SuperSpeed: the Command IU, then the status pipe read until the
/// Sense IU comes - a Read Ready or Write Ready before it the turn of the
/// data.
fn runWhenReady(transport: *Transport, pipe: *usb.USBPipe, data: ?[*]u8, length: u32, moving: bool, in: bool, data_ms: u32) bot.Result {
    const sent = move(transport, transport.command, &transport.iu, command_iu_bytes, iu_ms);
    if (sent != 0) return failedOn(transport, sent);
    var moved: u32 = 0;
    var data_done = false;
    while (true) {
        switch (move(transport, transport.status, &transport.answer, status_bytes, status_ms)) {
            0 => {},
            usbhc.UHIOERR_STALL => {
                _ = transport.ub.ClearUSBStall(transport.status);
                return broken(transport);
            },
            else => |err| return failedOn(transport, err),
        }
        const said = iuOf(transport.answer[0..actualOf(transport.status)], command_tag) orelse return broken(transport);
        switch (said.id) {
            IU_SENSE => return ended(transport, said, moved),
            IU_READ_READY, IU_WRITE_READY => {
                if (!moving or data_done or (said.id == IU_READ_READY) != in) return broken(transport);
                data_done = true;
                switch (move(transport, pipe, data.?, length, data_ms)) {
                    0 => {},
                    usbhc.UHIOERR_STALL => _ = transport.ub.ClearUSBStall(pipe),
                    else => |err| return failedOn(transport, err),
                }
                moved = actualOf(pipe);
            },
            else => return broken(transport),
        }
    }
}

/// How a command ended, from its Sense IU: the sense data of one that
/// failed kept for the REQUEST SENSE that asks for it.
fn ended(transport: *Transport, said: Iu, moved: u32) bot.Result {
    if (said.status == scsidisk.SCSI_STATUS_GOOD) return .{ .outcome = .passed, .moved = moved };
    const count = @min(said.sense.len, transport.sense.len);
    @memcpy(transport.sense[0..count], said.sense[0..count]);
    transport.sense_length = @intCast(count);
    return .{ .outcome = .failed, .moved = moved };
}

fn leaving(transport: *const Transport) bool {
    return @atomicLoad(u8, &transport.leaving, .acquire) != 0;
}

/// What a transfer moved, never more than it had room for.
fn actualOf(pipe: *const usb.USBPipe) u32 {
    return @intCast(@min(pipe.io.std.actual, pipe.io.std.length));
}

/// A transfer of `length` bytes on `pipe` sent, waiting at most `ms` for
/// the device, and not waited for.
fn send(transport: *Transport, pipe: *usb.USBPipe, bytes: [*]u8, length: u32, ms: u32) void {
    const io = &pipe.io;
    io.std.data = @ptrCast(bytes);
    io.std.length = length;
    io.std.actual = 0;
    io.nak_timeout = ms;
    transport.sys.SendIO(&io.std.req);
}

/// A transfer sent waited for: its io_Error.
fn finish(transport: *Transport, pipe: *usb.USBPipe) i8 {
    _ = transport.sys.WaitIO(&pipe.io.std.req);
    return pipe.io.std.req.err;
}

/// A transfer sent taken back and waited for.
fn takeBack(transport: *Transport, pipe: *usb.USBPipe) void {
    _ = transport.sys.AbortIO(&pipe.io.std.req);
    _ = transport.sys.WaitIO(&pipe.io.std.req);
}

/// `length` bytes over `pipe`, waiting at most `ms` for the device:
/// io_Error - IOERR_ABORTED without sending, once the device is being
/// let go of.
fn move(transport: *Transport, pipe: *usb.USBPipe, bytes: [*]u8, length: u32, ms: u32) i8 {
    if (leaving(transport)) return exec.IOERR_ABORTED;
    send(transport, pipe, bytes, length, ms);
    return finish(transport, pipe);
}

/// A transfer that failed outright: the device gone, or the transport
/// broken.
fn failedOn(transport: *Transport, err: i8) bot.Result {
    return switch (err) {
        usbhc.UHIOERR_DETACHED, exec.IOERR_ABORTED => .{ .outcome = .gone },
        else => broken(transport),
    };
}

/// The recovery: the logical unit reset, every pipe's halt cleared. The
/// command that needed it is answered as broken - or as gone, for a
/// device being let go of, which is not spoken to again.
fn broken(transport: *Transport) bot.Result {
    if (leaving(transport)) return .{ .outcome = .gone };
    reset(transport);
    return .{ .outcome = .broken };
}

/// LOGICAL UNIT RESET of the interface's logical unit 0, its Response IU
/// read - below SuperSpeed past what the broken command left on the
/// status pipe - then every endpoint's halt cleared.
pub fn reset(transport: *Transport) void {
    transport.sense_length = 0;
    taskOf(transport.iu[0..task_iu_bytes], task_tag, TMF_LOGICAL_UNIT_RESET, 0);
    if (move(transport, transport.command, &transport.iu, task_iu_bytes, iu_ms) == 0) {
        const pipe = transport.status_task orelse transport.status;
        var tries: u32 = 0;
        while (tries < 4) : (tries += 1) {
            if (move(transport, pipe, &transport.answer, status_bytes, iu_ms) != 0) break;
            const said = iuOf(transport.answer[0..actualOf(pipe)], task_tag) orelse continue;
            if (said.id == IU_RESPONSE) break;
        }
    }
    _ = transport.ub.ClearUSBStall(transport.command);
    _ = transport.ub.ClearUSBStall(transport.status);
    _ = transport.ub.ClearUSBStall(transport.data_in);
    _ = transport.ub.ClearUSBStall(transport.data_out);
}

/// The pipes, by the Pipe Usage descriptors of a UAS setting: each
/// endpoint's address, 0 for one not found.
pub const Pipes = struct {
    command: u8 = 0,
    status: u8 = 0,
    data_in: u8 = 0,
    data_out: u8 = 0,

    pub fn complete(pipes: Pipes) bool {
        return pipes.command != 0 and pipes.status != 0 and pipes.data_in != 0 and pipes.data_out != 0;
    }
};

/// What a setting's descriptors say of its pipes: `descriptors` the bytes
/// after its interface descriptor, up to the next interface's - each
/// Pipe Usage descriptor naming the endpoint before it.
pub fn pipesOf(descriptors: []const u8) Pipes {
    const d = usb.descriptors;
    var pipes: Pipes = .{};
    var endpoint: u8 = 0;
    var at: usize = 0;
    while (at + 2 <= descriptors.len) {
        const length = descriptors[at];
        if (length < 2 or at + length > descriptors.len) break;
        switch (descriptors[at + 1]) {
            d.USB_DT_INTERFACE => break,
            d.USB_DT_ENDPOINT => if (length >= 7) {
                endpoint = descriptors[at + 2];
            },
            d.MSC_DT_PIPE_USAGE => if (length >= 3 and endpoint != 0) {
                switch (descriptors[at + 2]) {
                    d.MSC_PIPE_COMMAND => pipes.command = endpoint,
                    d.MSC_PIPE_STATUS => pipes.status = endpoint,
                    d.MSC_PIPE_DATA_IN => pipes.data_in = endpoint,
                    d.MSC_PIPE_DATA_OUT => pipes.data_out = endpoint,
                    else => {},
                }
            },
            else => {},
        }
        at += length;
    }
    return pipes;
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

test "a Command IU: its ID, tag, logical unit and command block" {
    var iu: [command_iu_bytes]u8 = undefined;
    commandOf(&iu, 0x0102, 3, &.{ 0x28, 0, 0, 0, 0, 7, 0, 0, 1, 0 });
    try testing.expectEqual(IU_COMMAND, iu[0]);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, iu[2..4]);
    // A simple task, no more command block than the 16 bytes.
    try testing.expectEqual(@as(u8, 0), iu[4]);
    try testing.expectEqual(@as(u8, 0), iu[6]);
    try testing.expectEqualSlices(u8, &.{ 0, 3, 0, 0, 0, 0, 0, 0 }, iu[8..16]);
    try testing.expectEqual(@as(u8, 0x28), iu[16]);
    try testing.expectEqual(@as(u8, 7), iu[21]);
    try testing.expectEqual(@as(u8, 0), iu[31]);
}

test "a Task Management IU: LOGICAL UNIT RESET of unit 0" {
    var iu: [task_iu_bytes]u8 = undefined;
    taskOf(&iu, task_tag, TMF_LOGICAL_UNIT_RESET, 0);
    try testing.expectEqualSlices(u8, &.{ IU_TASK_MANAGEMENT, 0, 0, 2, TMF_LOGICAL_UNIT_RESET, 0, 0, 0 }, iu[0..8]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, iu[8..16]);
}

test "the status pipe's IUs: ready, a Sense IU's status and sense, a response; another tag's is none" {
    try testing.expectEqual(IU_READ_READY, iuOf(&.{ IU_READ_READY, 0, 0, 1 }, 1).?.id);
    try testing.expectEqual(IU_WRITE_READY, iuOf(&.{ IU_WRITE_READY, 0, 0, 1 }, 1).?.id);
    try testing.expect(iuOf(&.{ IU_READ_READY, 0, 0, 2 }, 1) == null);
    try testing.expect(iuOf(&.{ IU_READ_READY, 0, 0 }, 1) == null);
    try testing.expect(iuOf(&.{ IU_COMMAND, 0, 0, 1 }, 1) == null);

    // A command that passed: GOOD, no sense.
    var good: [16]u8 = @splat(0);
    good[0] = IU_SENSE;
    good[3] = 1;
    const passed = iuOf(&good, 1).?;
    try testing.expectEqual(scsidisk.SCSI_STATUS_GOOD, passed.status);
    try testing.expectEqual(@as(usize, 0), passed.sense.len);
    // One that failed: CHECK CONDITION, 18 bytes of sense - no medium.
    var failed: [16 + 18]u8 = @splat(0);
    failed[0] = IU_SENSE;
    failed[3] = 1;
    failed[6] = scsidisk.SCSI_STATUS_CHECK_CONDITION;
    failed[15] = 18;
    failed[16] = 0x70;
    failed[18] = scsi.KEY_NOT_READY;
    failed[28] = 0x3A;
    const said = iuOf(&failed, 1).?;
    try testing.expectEqual(scsidisk.SCSI_STATUS_CHECK_CONDITION, said.status);
    try testing.expectEqual(@as(usize, 18), said.sense.len);
    try testing.expect(scsi.senseOf(said.sense).?.noMedium());
    // A sense length past the IU is cut to what came.
    try testing.expectEqual(@as(usize, 10), iuOf(failed[0..26], 1).?.sense.len);
    try testing.expect(iuOf(failed[0..15], 1) == null);

    const response = [_]u8{ IU_RESPONSE, 0, 0, 2, 0, 0, 0, 0x08 };
    try testing.expectEqual(@as(u8, 0x08), iuOf(&response, task_tag).?.code);
    try testing.expect(iuOf(response[0..7], task_tag) == null);
}

test "a UAS setting's pipes, each named by the Pipe Usage descriptor after its endpoint" {
    const d = usb.descriptors;
    // At SuperSpeed a companion between the endpoint and its usage.
    const setting = [_]u8{ 7, d.USB_DT_ENDPOINT, 0x01, d.USB_ENDPOINT_XFER_BULK, 0, 4, 0 } ++
        [_]u8{ 6, d.USB_DT_SS_ENDPOINT_COMP, 15, 0, 0, 0 } ++
        [_]u8{ 4, d.MSC_DT_PIPE_USAGE, d.MSC_PIPE_COMMAND, 0 } ++
        [_]u8{ 7, d.USB_DT_ENDPOINT, 0x82, d.USB_ENDPOINT_XFER_BULK, 0, 4, 0 } ++
        [_]u8{ 4, d.MSC_DT_PIPE_USAGE, d.MSC_PIPE_STATUS, 0 } ++
        [_]u8{ 7, d.USB_DT_ENDPOINT, 0x83, d.USB_ENDPOINT_XFER_BULK, 0, 4, 0 } ++
        [_]u8{ 4, d.MSC_DT_PIPE_USAGE, d.MSC_PIPE_DATA_IN, 0 } ++
        [_]u8{ 7, d.USB_DT_ENDPOINT, 0x04, d.USB_ENDPOINT_XFER_BULK, 0, 4, 0 } ++
        [_]u8{ 4, d.MSC_DT_PIPE_USAGE, d.MSC_PIPE_DATA_OUT, 0 } ++
        // The next interface's endpoints are not this setting's.
        [_]u8{ 9, d.USB_DT_INTERFACE, 1, 0, 1, 8, 6, 0x50, 0 } ++
        [_]u8{ 7, d.USB_DT_ENDPOINT, 0x85, d.USB_ENDPOINT_XFER_BULK, 0, 2, 0 } ++
        [_]u8{ 4, d.MSC_DT_PIPE_USAGE, d.MSC_PIPE_STATUS, 0 };
    const pipes = pipesOf(&setting);
    try testing.expect(pipes.complete());
    try testing.expectEqual(@as(u8, 0x01), pipes.command);
    try testing.expectEqual(@as(u8, 0x82), pipes.status);
    try testing.expectEqual(@as(u8, 0x83), pipes.data_in);
    try testing.expectEqual(@as(u8, 0x04), pipes.data_out);
    // Without the usage descriptors there are no pipes to name.
    try testing.expect(!pipesOf(setting[0..13]).complete());
}
