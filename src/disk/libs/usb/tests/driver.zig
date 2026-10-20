// SPDX-License-Identifier: MIT
//! A class driver for host tests: it takes every interface usb.library
//! offers it and counts what it was told. A test puts it in the library's
//! table of drivers by hand, with the match it is to have, in place of
//! the table read from DEVS:usb/.

const sdk = @import("sdk");
const exec = sdk.exec;
const usb = sdk.usb;
const usbclass = sdk.devices.usbclass;
const ExecBase = sdk.interface.exec.ExecBase;

pub const NAME = "usb/standin.device";

pub const Driver = extern struct {
    dev: exec.Device,
    sys: *ExecBase,
    /// The interfaces it took and was told were gone; those it has now.
    binds: u32 = 0,
    unbinds: u32 = 0,
    holding: u32 = 0,
    /// The interface number it was offered last.
    last_interface: u8 = 0xFF,
};

pub fn driverOf(dev: *exec.Device) *Driver {
    return @fieldParentPtr("dev", dev);
}

fn driverInit(dev: *exec.Device, _: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Device {
    const driver = driverOf(dev);
    const header = dev.*;
    driver.* = .{ .dev = header, .sys = sys };
    return dev;
}

fn driverOpen(dev: *exec.Device, _: *exec.IORequest, unit: u32, _: u32) callconv(.c) i32 {
    if (unit != usbclass.USBCLASS_UNIT_BIND) return exec.IOERR_OPENFAIL;
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

fn bind(dev: *exec.Device, binding: *usb.USBBinding) callconv(.c) bool {
    const driver = driverOf(dev);
    driver.binds += 1;
    driver.holding += 1;
    driver.last_interface = binding.interface.?.interface_number;
    return true;
}

fn unbind(dev: *exec.Device, _: *usb.USBBinding) callconv(.c) void {
    const driver = driverOf(dev);
    driver.unbinds += 1;
    driver.holding -= 1;
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

pub const tag: exec.Resident = .{
    .match_tag = &tag,
    .flags = exec.RTF_AUTOINIT,
    .version = 1,
    .type = .device,
    .pri = 0,
    .name = NAME,
    .id_string = "standin.device 1.0",
    .init = &driver_table,
};
