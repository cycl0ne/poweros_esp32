// SPDX-License-Identifier: MIT
//! A host controller for host tests: a device speaking `DEVIF_USBHC`'s
//! isochronous transfers as a script says, at once - no bus, and no time
//! but the frames it counts. A test opens it into a bus's `hc_io`, and
//! the pipes usb.library makes on that bus send it their transfers.
//!
//! **The stream's packets** are numbered from 0 across its transfers, as
//! they come. A packet the script names lost comes back UHIOERR_MISSED
//! with nothing moved; the rest go whole - an OUT packet's bytes kept in
//! `sent`, one after the other, an IN packet filled with the low byte of
//! its number, `short_bytes` long where the script says it comes short.
//!
//! **The frames**: each transfer starts in the frame after the one before
//! it ended, its packets `interval` frames apart. One the script puts a
//! gap before starts that many frames later and says so in `iso_gap`, as
//! a controller whose ring ran dry does; one with `UHF_ISO_FRAME` starts
//! in the frame it asks for. UHCMD_QUERYDEVICE answers the frame now.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const usbhc = sdk.devices.usbhc;
const ExecBase = sdk.interface.exec.ExecBase;

pub const NAME = "hcstandin.device";

/// No transfer or packet: the script says nothing of one.
pub const none = std.math.maxInt(u32);

pub const HC = extern struct {
    dev: exec.Device,
    sys: *ExecBase,
    unit: exec.Unit = .{},
    /// The frame the next transfer starts in, and the stream's packets and
    /// transfers so far.
    frame: u32 = 100,
    packets: u32 = 0,
    transfers: u32 = 0,
    /// The script: a bit per packet of the stream's first 64 that is
    /// lost; the transfer a gap of `gap` frames comes before; the packet
    /// that comes short, with `short_bytes`.
    lost: u64 = 0,
    gap_before: u32 = none,
    gap: u16 = 0,
    short_packet: u32 = none,
    short_bytes: u16 = 0,
    /// What the OUT packets brought, one after the other, as much as fits.
    sent: [4096]u8 = @splat(0),
    sent_length: u32 = 0,
};

pub fn hcOf(dev: *exec.Device) *HC {
    return @fieldParentPtr("dev", dev);
}

fn hcInit(dev: *exec.Device, _: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Device {
    const hc = hcOf(dev);
    const header = dev.*;
    hc.* = .{ .dev = header, .sys = sys };
    return dev;
}

fn hcOpen(dev: *exec.Device, io: *exec.IORequest, unit: u32, _: u32) callconv(.c) i32 {
    if (unit != 0) return exec.IOERR_OPENFAIL;
    io.unit = &hcOf(dev).unit;
    dev.open_cnt += 1;
    return 0;
}

fn hcClose(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    io.unit = null;
    dev.open_cnt -= 1;
    return null;
}

fn hcExpunge(dev: *exec.Device) callconv(.c) ?*anyopaque {
    const sys = hcOf(dev).sys;
    sys.DetachLibrary(dev);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(dev) - dev.neg_size);
    sys.FreeMem(start, @as(usize, dev.neg_size) + dev.pos_size);
    return null;
}

fn hcBeginIO(dev: *exec.Device, request: *exec.IORequest) callconv(.c) void {
    const hc = hcOf(dev);
    const req: *usbhc.IOUsbHC = @ptrCast(@alignCast(request));
    request.err = serve(hc, req);
    if (request.flags & exec.IOF_QUICK == 0) hc.sys.ReplyMsg(&request.message);
}

fn hcAbortIO(_: *exec.Device, _: *exec.IORequest) callconv(.c) i32 {
    return 0;
}

fn serve(hc: *HC, req: *usbhc.IOUsbHC) i8 {
    req.std.actual = 0;
    switch (req.std.req.command) {
        usbhc.UHCMD_ISOXFER => return transfer(hc, req),
        usbhc.UHCMD_QUERYDEVICE => {
            const info: *usbhc.USBHCInfo = @ptrCast(@alignCast(req.std.data.?));
            info.* = .{ .name = "standin", .speed = usbhc.USB_SPEED_FULL, .channels = 4, .ports = 1, .frame = hc.frame & (usbhc.UHC_FRAMES - 1) };
            req.std.actual = @sizeOf(usbhc.USBHCInfo);
            return 0;
        },
        else => return exec.IOERR_NOCMD,
    }
}

/// An isochronous transfer as the script says, at once.
fn transfer(hc: *HC, req: *usbhc.IOUsbHC) i8 {
    const length: u32 = @intCast(req.std.length);
    const packet = if (req.iso_packet != 0) req.iso_packet else req.max_packet;
    const count: u32 = if (req.iso_list != null) req.iso_count else (length + packet - 1) / packet;
    if (count == 0 or count > usbhc.UHC_ISO_PACKETS) return exec.IOERR_BADLENGTH;
    const data: [*]u8 = @ptrCast(req.std.data.?);
    const in = req.endpoint & 0x80 != 0;

    var gap: u32 = if (hc.transfers == hc.gap_before) hc.gap else 0;
    if (req.flags & usbhc.UHF_ISO_FRAME != 0) {
        const ahead = (@as(u32, req.iso_frame) -% hc.frame) & (usbhc.UHC_FRAMES - 1);
        if (ahead > usbhc.UHC_ISO_AHEAD) return usbhc.UHIOERR_MISSED;
        gap = ahead;
    }
    hc.frame +%= gap;
    req.iso_frame = @truncate(hc.frame & (usbhc.UHC_FRAMES - 1));
    req.iso_gap = @truncate(gap);
    req.iso_lost = 0;

    var offset: u32 = 0;
    var n: u32 = 0;
    while (n < count) : (n += 1) {
        const number = hc.packets + n;
        const asked: u32 = if (req.iso_list) |list| list[n].length else @min(packet, length - n * packet);
        const lost = number < 64 and hc.lost & (@as(u64, 1) << @intCast(number)) != 0;
        const got: u32 = if (lost) 0 else if (number == hc.short_packet) @min(hc.short_bytes, asked) else asked;
        if (req.iso_list) |list| {
            list[n].actual = @truncate(got);
            list[n].status = if (lost) usbhc.UHIOERR_MISSED else 0;
        }
        if (lost) req.iso_lost += 1;
        if (in) {
            @memset(data[offset..][0..got], @truncate(number));
        } else {
            const kept = @min(got, hc.sent.len - hc.sent_length);
            @memcpy(hc.sent[hc.sent_length..][0..kept], data[offset..][0..kept]);
            hc.sent_length += kept;
        }
        req.std.actual += got;
        offset += asked;
    }
    hc.packets += count;
    hc.transfers += 1;
    hc.frame +%= count * @max(req.interval, 1);
    return 0;
}

const hc_vectors = [_]*const anyopaque{
    exec.vec(hcOpen),
    exec.vec(hcClose),
    exec.vec(hcExpunge),
    exec.vec(exec.libExtFunc),
    exec.vec(hcBeginIO),
    exec.vec(hcAbortIO),
};

const hc_table = exec.InitTable{
    .data_size = @sizeOf(HC),
    .vectors = &hc_vectors,
    .vector_count = hc_vectors.len,
    .init = &hcInit,
};

pub const tag: exec.Resident = .{
    .match_tag = &tag,
    .flags = exec.RTF_AUTOINIT,
    .version = 1,
    .type = .device,
    .pri = 0,
    .name = NAME,
    .id_string = "hcstandin.device 1.0",
    .init = &hc_table,
};
