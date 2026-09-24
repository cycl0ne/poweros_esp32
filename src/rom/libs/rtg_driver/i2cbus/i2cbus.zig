// SPDX-License-Identifier: MPL-2.0
//! A display's command bus, over i2c.device.
//!
//! A module of its own: it opens rtg.library at cold start, hands in a
//! driver of the transport kind, and from then on anything that asks
//! rtg.library for an "i2c" bus gets one of these. What it does is turn
//! TxParam, TxColor and RxParam into transfers on an i2c.device unit.
//!
//! A read is one I2CCMD_WRITEREAD and not a write followed by a read, so
//! that nothing else on the bus can get in between the command and the
//! bytes that answer it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const rtg = sdk.rtg;
const i2c = sdk.devices.i2c;
const devices = sdk.exec.devices;
const TagItem = sdk.utility.TagItem;
const err = rtg.errors;
const tags = rtg.tags;
const RtgBase = sdk.interface.rtg.RtgBase;

const frame = @import("frame.zig");

const MODULE_NAME = "rtg-i2c";
const DRIVER_NAME = "i2c";
const VERSION = 1;
const REVISION = 0;
const BUILD_DATE = "17.9.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// As much as goes out in one transfer of parameters: the control phase,
/// the command and a part's longest register write. Pixels are sent in as
/// many of these as it takes.
const chunk = 64;

/// Everything this driver has that changes, allocated once by the init: a
/// ROM image is read only, so the driver node and SysBase live in memory
/// and every entry point finds them again through the node, which is a
/// field of this block.
const State = struct {
    driver: rtg.RtgDriver = .{},
    sys: *ExecBase,
};

fn stateOf(driver: *rtg.RtgDriver) *State {
    return @fieldParentPtr("driver", driver);
}

/// What one bus keeps.
const Instance = struct {
    sys: *ExecBase,
    port: ?*exec.MsgPort = null,
    request: ?*i2c.IOExtI2C = null,
    address: u16 = 0,
    shape: frame.Shape = .{},
    buffer: [chunk]u8 = undefined,
};

fn instanceOf(io: *rtg.RtgTransport) *Instance {
    return @ptrCast(@alignCast(io.instance.?));
}

fn createTransport(made_by: *rtg.RtgDriver, io: *rtg.RtgTransport, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const rb: *RtgBase = io.rtg_base.?;
    const sys = stateOf(made_by).sys;
    const instance = instanceOf(io);
    instance.* = .{ .sys = sys };

    const address = rb.GetRtgTagData(tags.RTGA_I2C_Address, 0, tag_list);
    if (address == 0 or address > 0x7F) return err.RTGERR_BAD_TAGS;
    instance.address = @truncate(address);
    instance.shape = .{
        .control_bytes = @truncate(rb.GetRtgTagData(tags.RTGA_I2C_ControlBytes, 1, tag_list)),
        .dc_bit = @truncate(rb.GetRtgTagData(tags.RTGA_I2C_DcBit, 6, tag_list)),
        .dc_low_on_data = rb.GetRtgTagData(tags.RTGA_I2C_DcLowOnData, 0, tag_list) != 0,
        .cmd_bits = @truncate(rb.GetRtgTagData(tags.RTGA_I2C_CmdBits, 8, tag_list)),
    };
    if (instance.shape.cmd_bits != 8 and instance.shape.cmd_bits != 16) return err.RTGERR_BAD_TAGS;
    io.cmd_bits = instance.shape.cmd_bits;
    io.param_bits = @truncate(rb.GetRtgTagData(tags.RTGA_I2C_ParamBits, 8, tag_list));
    io.control_bytes = instance.shape.control_bytes;
    io.dc_bit = instance.shape.dc_bit;
    if (instance.shape.dc_low_on_data) io.flags |= rtg.transport.RTGTRF_DC_LOW_ON_DATA;

    const unit: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_I2C_Unit, 0, tag_list));
    const port = sys.CreateMsgPort() orelse return err.RTGERR_NO_MEMORY;
    instance.port = port;
    const request = sys.CreateIORequest(port, @sizeOf(i2c.IOExtI2C)) orelse {
        sys.DeleteMsgPort(port);
        instance.port = null;
        return err.RTGERR_NO_MEMORY;
    };
    instance.request = @ptrCast(@alignCast(request));
    if (sys.OpenDevice(i2c.DEVICE_NAME, unit, request, 0) != 0) {
        sys.DeleteIORequest(request);
        sys.DeleteMsgPort(port);
        instance.request = null;
        instance.port = null;
        // No such controller on this machine: the bus is simply not there.
        return err.RTGERR_NO_DISPLAY;
    }

    const speed = rb.GetRtgTagData(tags.RTGA_I2C_Speed, 0, tag_list);
    if (speed != 0) {
        const io_request = instance.request.?;
        io_request.speed = @truncate(speed);
        io_request.scl_pin = i2c.PIN_KEEP;
        io_request.sda_pin = i2c.PIN_KEEP;
        _ = command(instance, i2c.I2CCMD_SETPARAMS, 0, null, 0);
    }

    io.ops = &ops;
    return err.RTGERR_OK;
}

/// One i2c.device command, its error turned into one of ours.
fn command(instance: *Instance, code: u16, length: u32, data: ?*anyopaque, write_length: u32) i32 {
    const request = instance.request orelse return err.RTGERR_NO_DISPLAY;
    request.req.req.command = code;
    request.address = instance.address;
    request.req.length = length;
    request.req.data = data;
    request.wr_length = write_length;
    const answer = instance.sys.DoIO(&request.req.req);
    if (answer == 0) return err.RTGERR_OK;
    return switch (answer) {
        i2c.I2CErr_NoAck => err.RTGERR_IO,
        i2c.I2CErr_Timeout => err.RTGERR_TIMEOUT,
        i2c.I2CErr_InvParam => err.RTGERR_BAD_ARG,
        else => err.RTGERR_IO,
    };
}

fn destroy(io: *rtg.RtgTransport) callconv(.c) void {
    const instance = instanceOf(io);
    if (instance.request) |request| {
        instance.sys.CloseDevice(&request.req.req);
        instance.sys.DeleteIORequest(&request.req.req);
    }
    if (instance.port) |port| instance.sys.DeleteMsgPort(port);
    instance.request = null;
    instance.port = null;
}

/// A command and its parameters, in one transfer: a part that is told a
/// register number and then its value in two transfers can have another
/// party's traffic in between.
fn send(io: *rtg.RtgTransport, is_data: bool, cmd: i32, bytes: ?[*]const u8, size: u32) i32 {
    const instance = instanceOf(io);
    const head = instance.shape.control_bytes + @as(u32, if (cmd < 0) 0 else instance.shape.cmd_bits / 8);
    if (head >= chunk) return err.RTGERR_BAD_ARG;
    const room = chunk - head;
    var sent: u32 = 0;
    while (true) {
        const left = size - sent;
        const take = @min(left, room);
        const payload: []const u8 = if (bytes) |b| b[sent..][0..take] else &.{};
        // Only the first transfer carries the command; what follows it is
        // the rest of the same run of bytes.
        const this_cmd = if (sent == 0) cmd else -1;
        const count = frame.build(&instance.buffer, instance.shape, is_data, this_cmd, payload) orelse
            return err.RTGERR_BAD_ARG;
        const code = command(instance, devices.CMD_WRITE, @truncate(count), &instance.buffer, 0);
        if (code != err.RTGERR_OK) return code;
        sent += take;
        if (sent >= size) return err.RTGERR_OK;
    }
}

fn txParam(io: *rtg.RtgTransport, cmd: i32, param: ?*const anyopaque, size: u32) callconv(.c) i32 {
    return send(io, false, cmd, @ptrCast(@alignCast(param)), size);
}

fn txColor(io: *rtg.RtgTransport, cmd: i32, color: ?*const anyopaque, size: u32) callconv(.c) i32 {
    const code = send(io, true, cmd, @ptrCast(@alignCast(color)), size);
    if (code == err.RTGERR_OK) {
        // The bytes are gone by the time this returns: the transfers are
        // synchronous. Whoever is waiting for them hears it anyway.
        const board = firstBoardOn(io);
        if (board) |b| _ = rtgBase(io).SignalRtgEvent(b, rtg.events.RTGEV_TX_DONE);
    }
    return code;
}

fn rxParam(io: *rtg.RtgTransport, cmd: i32, buffer: ?*anyopaque, size: u32) callconv(.c) i32 {
    const instance = instanceOf(io);
    const into = buffer orelse return err.RTGERR_BAD_ARG;
    if (size == 0) return err.RTGERR_BAD_ARG;

    // What goes out before the repeated start: the control phase and the
    // command, in one request with the read, so nothing comes between.
    const count = frame.build(&instance.buffer, instance.shape, false, cmd, &.{}) orelse
        return err.RTGERR_BAD_ARG;
    const request = instance.request orelse return err.RTGERR_NO_DISPLAY;
    request.wr_data = &instance.buffer;
    return command(instance, i2c.I2CCMD_WRITEREAD, size, into, @truncate(count));
}

fn rtgBase(io: *rtg.RtgTransport) *RtgBase {
    return io.rtg_base.?;
}

/// The first board that talks through this bus, for the events a transfer
/// raises. A bus carries one panel here; a caller with two would tell them
/// apart by their own event servers.
fn firstBoardOn(io: *rtg.RtgTransport) ?*rtg.RtgBoard {
    const rb = rtgBase(io);
    var board = rb.NextBoard(null);
    while (board) |b| : (board = rb.NextBoard(b)) {
        if (b.transport == io) return b;
    }
    return null;
}

const ops = rtg.RtgTransportOps{
    .destroy = &destroy,
    .tx_param = &txParam,
    .tx_color = &txColor,
    .rx_param = &rxParam,
};

const driver_ops = rtg.RtgDriverOps{ .create_transport = &createTransport };

/// Cold start at 21: after rtg.library (24), which it joins, and after
/// i2c.device (35), which it opens when a bus is asked for.
fn init(seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*anyopaque {
    _ = seg_list;
    const library = sys.OpenLibrary(rtg.RTGNAME, VERSION) orelse return @ptrCast(sys);
    const rb: *RtgBase = @ptrCast(library);

    const memory = sys.AllocVec(@sizeOf(State), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    };
    const state: *State = @ptrCast(@alignCast(memory));
    state.* = .{ .sys = sys };
    state.driver = .{
        .node = .{ .name = DRIVER_NAME, .pri = 0 },
        .version = VERSION,
        .revision = REVISION,
        .id_string = VERSION_STRING[1..],
        .type = rtg.boards.RTGDT_TRANSPORT,
        .ops = &driver_ops,
        .instance_size = @sizeOf(Instance),
    };
    if (!rb.AddRtgDriver(&state.driver)) {
        sys.FreeVec(memory);
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    }
    // The library stays open and the state stays allocated: the driver is
    // on the list for good, and the list is how anything finds it again.
    return @ptrCast(sys);
}

/// No library and no vectors: the tag's init is the whole of it.
export const rtg_i2c_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rtg_i2c_tag,
    .flags = exec.RTF_COLDSTART,
    .version = VERSION,
    .pri = 21,
    .type = .rtg_driver,
    .name = MODULE_NAME,
    .id_string = VERSION_STRING[1..], // past the NUL: a C string
    .init = @ptrCast(@constCast(&init)),
};
