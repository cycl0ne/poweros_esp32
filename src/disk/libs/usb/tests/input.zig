// SPDX-License-Identifier: MIT
//! An input.device for host tests: it keeps the events written to it
//! (IND_WRITEEVENT), the first `max_events`, and answers nothing else.

const sdk = @import("sdk");
const exec = sdk.exec;
const input = sdk.devices.input;
const ie = sdk.devices.inputevent;
const ExecBase = sdk.interface.exec.ExecBase;

pub const max_events = 16;

pub const Input = extern struct {
    dev: exec.Device,
    sys: *ExecBase,
    events: [max_events]ie.InputEvent = @splat(.{}),
    count: u32 = 0,
};

pub fn inputOf(dev: *exec.Device) *Input {
    return @fieldParentPtr("dev", dev);
}

/// The events kept so far.
pub fn written(stand_in: *Input) []const ie.InputEvent {
    return stand_in.events[0..@min(stand_in.count, max_events)];
}

fn inputInit(dev: *exec.Device, _: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Device {
    const stand_in = inputOf(dev);
    const header = dev.*;
    stand_in.* = .{ .dev = header, .sys = sys };
    return dev;
}

fn inputOpen(dev: *exec.Device, _: *exec.IORequest, _: u32, _: u32) callconv(.c) i32 {
    dev.open_cnt += 1;
    return 0;
}

fn inputClose(dev: *exec.Device, _: *exec.IORequest) callconv(.c) ?*anyopaque {
    dev.open_cnt -= 1;
    return null;
}

fn inputExpunge(dev: *exec.Device) callconv(.c) ?*anyopaque {
    const sys = inputOf(dev).sys;
    sys.DetachLibrary(dev);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(dev) - dev.neg_size);
    sys.FreeMem(start, @as(usize, dev.neg_size) + dev.pos_size);
    return null;
}

fn inputBeginIO(dev: *exec.Device, request: *exec.IORequest) callconv(.c) void {
    const stand_in = inputOf(dev);
    const io: *exec.IOStdReq = @ptrCast(@alignCast(request));
    if (request.command == input.IND_WRITEEVENT) {
        const event: *const ie.InputEvent = @ptrCast(@alignCast(io.data.?));
        if (stand_in.count < max_events) stand_in.events[stand_in.count] = event.*;
        stand_in.count += 1;
        request.err = 0;
    } else {
        request.err = exec.IOERR_NOCMD;
    }
    if (request.flags & exec.IOF_QUICK == 0) stand_in.sys.ReplyMsg(&request.message);
}

fn inputAbortIO(_: *exec.Device, _: *exec.IORequest) callconv(.c) i32 {
    return 0;
}

const input_vectors = [_]*const anyopaque{
    exec.vec(inputOpen),
    exec.vec(inputClose),
    exec.vec(inputExpunge),
    exec.vec(exec.libExtFunc),
    exec.vec(inputBeginIO),
    exec.vec(inputAbortIO),
};

const input_table = exec.InitTable{
    .data_size = @sizeOf(Input),
    .vectors = &input_vectors,
    .vector_count = input_vectors.len,
    .init = &inputInit,
};

pub const tag: exec.Resident = .{
    .match_tag = &tag,
    .flags = exec.RTF_AUTOINIT,
    .version = 1,
    .type = .device,
    .pri = 0,
    .name = input.INPUTNAME,
    .id_string = "input.device (stand-in) 1.0",
    .init = &input_table,
};
