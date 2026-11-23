// SPDX-License-Identifier: MIT
//! A profile driver for host tests: it takes every service the binder
//! offers it - or, told to, declines each - and counts what it was told.
//! A test makes one of a name of its own and puts it in the library's
//! table of drivers by hand, with the matches it is to have, in place of
//! the table read from DEVS:bluetooth/.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const btprofile = sdk.devices.btprofile;
const ExecBase = sdk.interface.exec.ExecBase;

pub const Driver = extern struct {
    dev: exec.Device,
    sys: *ExecBase,
    /// Whether it takes what it is offered.
    takes: bool = true,
    /// The services it was offered, took and was told were gone; those it
    /// drives now.
    offers: u32 = 0,
    binds: u32 = 0,
    unbinds: u32 = 0,
    holding: u32 = 0,
    /// What it was offered last, and the flags it was last let go with.
    last_class: u16 = 0,
    last_handle: u32 = 0,
    last_flags: u32 = 0,
};

pub fn driverOf(dev: *exec.Device) *Driver {
    return @fieldParentPtr("dev", dev);
}

/// A stand-in opened by `name` ("bluetooth/<file>").
pub fn Standin(comptime name: [:0]const u8) type {
    return struct {
        pub const NAME = name;

        pub const tag: exec.Resident = .{
            .match_tag = &tag,
            .flags = exec.RTF_AUTOINIT,
            .version = 1,
            .type = .device,
            .pri = 0,
            .name = NAME,
            .id_string = "standin 1.0",
            .init = &driver_table,
        };
    };
}

fn driverInit(dev: *exec.Device, _: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Device {
    const driver = driverOf(dev);
    const header = dev.*;
    driver.* = .{ .dev = header, .sys = sys };
    return dev;
}

fn driverOpen(dev: *exec.Device, _: *exec.IORequest, unit: u32, _: u32) callconv(.c) i32 {
    if (unit != btprofile.BTPROFILE_UNIT_BIND) return exec.IOERR_OPENFAIL;
    dev.open_cnt += 1;
    return 0;
}

fn driverClose(dev: *exec.Device, _: *exec.IORequest) callconv(.c) ?*anyopaque {
    dev.open_cnt -= 1;
    return null;
}

fn driverExpunge(dev: *exec.Device) callconv(.c) ?*anyopaque {
    const sys = driverOf(dev).sys;
    sys.DetachLibrary(dev);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(dev) - dev.neg_size);
    sys.FreeMem(start, @as(usize, dev.neg_size) + dev.pos_size);
    return null;
}

fn driverBeginIO(dev: *exec.Device, request: *exec.IORequest) callconv(.c) void {
    request.err = exec.IOERR_NOCMD;
    if (request.flags & exec.IOF_QUICK == 0) driverOf(dev).sys.ReplyMsg(&request.message);
}

fn driverAbortIO(_: *exec.Device, _: *exec.IORequest) callconv(.c) i32 {
    return 0;
}

fn bind(dev: *exec.Device, binding: *bluetooth.BTBinding) callconv(.c) bool {
    const driver = driverOf(dev);
    driver.offers += 1;
    const service = binding.service.?;
    driver.last_class = service.class16;
    driver.last_handle = service.handle;
    if (!driver.takes) return false;
    driver.binds += 1;
    driver.holding += 1;
    binding.unit = driver.binds;
    return true;
}

fn unbind(dev: *exec.Device, _: *bluetooth.BTBinding, flags: u32) callconv(.c) void {
    const driver = driverOf(dev);
    driver.unbinds += 1;
    driver.holding -= 1;
    driver.last_flags = flags;
}

const driver_vectors = [_]*const anyopaque{
    exec.vec(driverOpen),
    exec.vec(driverClose),
    exec.vec(driverExpunge),
    exec.vec(exec.libExtFunc),
    exec.vec(driverBeginIO),
    exec.vec(driverAbortIO),
    exec.vec(bind),
    exec.vec(unbind),
};

const driver_table = exec.InitTable{
    .data_size = @sizeOf(Driver),
    .vectors = &driver_vectors,
    .vector_count = driver_vectors.len,
    .init = &driverInit,
};
