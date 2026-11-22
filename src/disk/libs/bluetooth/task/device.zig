// SPDX-License-Identifier: MIT
//! A controller's device, as the task uses it: its unit opened and asked
//! what it is, the reads kept queued on it and taken as they come back,
//! the writes that carry the HCI's packets to it, and all of it taken
//! back and closed when the controller goes.
//!
//! Every request is answered to the task's one reply port; what it was -
//! which controller, a read or a write - is in the `Request` it starts
//! with (controller/_controller.zig).

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const hcidev = sdk.devices.hci;
const ExecBase = sdk.interface.exec.ExecBase;
const _controller = @import("../controller/_controller.zig");
const Controller = _controller.Controller;
const Request = _controller.Request;
const Read = _controller.Read;
const Write = _controller.Write;
const _hci = @import("../hci/_hci.zig");

/// The request a message on the reply port is.
pub fn requestOf(message: *exec.Message) *Request {
    const io: *hcidev.IOHciReq = @ptrCast(@alignCast(message));
    return @fieldParentPtr("io", io);
}

/// The controller's unit opened on its first read, and the other
/// requests made from it; the device asked what it knows of the
/// controller. 0, or what the open answered: HCIERR_NOTREADY for a
/// controller its device is still setting up.
pub fn open(controller: *Controller, replies: *exec.MsgPort) i32 {
    const sys = controller.base.sys_base;
    for (&controller.reads) |*read| {
        read.request.controller = controller;
        read.request.io.std.req.message.reply_port = replies;
        read.request.io.std.req.message.length = @sizeOf(hcidev.IOHciReq);
    }
    for (&controller.writes) |*write| {
        write.request.controller = controller;
        write.request.io.std.req.message.reply_port = replies;
        write.request.io.std.req.message.length = @sizeOf(hcidev.IOHciReq);
    }
    const first = &controller.reads[0].request.io;
    const opened = sys.OpenDevice(&controller.device_name, controller.unit, &first.std.req, 0);
    if (opened != 0) return opened;
    controller.open = true;
    for (controller.reads[1..]) |*read| copyOpen(&read.request.io, first);
    for (&controller.writes) |*write| copyOpen(&write.request.io, first);
    // Answered at once, in this task.
    var info: hcidev.HCIInfo = .{};
    first.std.req.command = hcidev.HCICMD_QUERY;
    first.std.data = &info;
    first.std.length = @sizeOf(hcidev.HCIInfo);
    if (sys.DoIO(&first.std.req) == 0) {
        controller.bus = info.bus;
        controller.baud = info.baud;
        _controller.copyString(&controller.chip, info.chip);
        _controller.copyString(&controller.firmware, info.firmware);
    }
    return 0;
}

fn copyOpen(into: *hcidev.IOHciReq, from: *const hcidev.IOHciReq) void {
    into.std.req.device = from.std.req.device;
    into.std.req.unit = from.std.req.unit;
}

/// Every read not out sent.
pub fn startReads(controller: *Controller) void {
    for (&controller.reads) |*read| {
        if (!read.request.out) sendRead(controller, read);
    }
}

fn sendRead(controller: *Controller, read: *Read) void {
    if (controller.leaving) return;
    const io = &read.request.io;
    io.std.req.command = exec.CMD_READ;
    if (read.bigger) |room| {
        io.std.data = room;
        io.std.length = read.bigger_size;
    } else {
        io.std.data = &read.buffer;
        io.std.length = read.buffer.len;
    }
    io.std.actual = 0;
    io.packet_type = 0;
    read.request.out = true;
    controller.base.sys_base.SendIO(&io.std.req);
}

/// The HCI layer's port: a packet copied into a free write and sent.
pub fn port(controller: *Controller) _hci.Port {
    return .{ .context = controller, .send = sendPacket };
}

fn sendPacket(context: *anyopaque, packet_type: u8, bytes: []const u8) bool {
    const controller: *Controller = @ptrCast(@alignCast(context));
    if (controller.leaving or !controller.open) return false;
    if (bytes.len > _controller.WRITE_SIZE) return false;
    for (&controller.writes) |*write| {
        if (write.request.out) continue;
        for (bytes, 0..) |byte, index| write.buffer[index] = byte;
        const io = &write.request.io;
        io.std.req.command = exec.CMD_WRITE;
        io.std.data = &write.buffer;
        io.std.length = bytes.len;
        io.std.actual = 0;
        io.packet_type = packet_type;
        write.request.out = true;
        controller.base.sys_base.SendIO(&io.std.req);
        return true;
    }
    return false;
}

/// What a request came back with, taken: a packet handed to the layer and
/// the read sent again, a write's room handed back. Under the base's
/// lock; `now` the time.
pub fn replied(controller: *Controller, request: *Request, now: u64) void {
    request.out = false;
    const layer = &controller.layer;
    layer.now = now;
    switch (request.kind) {
        .write => {
            // A packet the device would not take: a command's answer will
            // not come, and its time-out gives it up.
            if (!controller.leaving) _hci.pump(layer);
        },
        .read => {
            const read: *Read = @fieldParentPtr("request", request);
            if (controller.leaving) return;
            const io = &read.request.io;
            switch (io.std.req.err) {
                0 => {
                    const room: [*]const u8 = @ptrCast(io.std.data.?);
                    const length: usize = @intCast(@min(io.std.actual, io.std.length));
                    _hci.received(layer, io.packet_type, room[0..length]);
                    sendRead(controller, read);
                },
                hcidev.HCIERR_TOOLONG => {
                    if (grow(controller, read, @intCast(io.std.actual))) {
                        sendRead(controller, read);
                    } else {
                        _hci.fail(layer, bluetooth.BTERR_NOMEM);
                    }
                },
                hcidev.HCIERR_DETACHED => _hci.fail(layer, bluetooth.BTERR_DETACHED),
                exec.IOERR_ABORTED => sendRead(controller, read),
                else => _hci.fail(layer, bluetooth.BTERR_PROTOCOL),
            }
        },
    }
}

/// A read given a room of `size` bytes, for a packet longer than its own.
fn grow(controller: *Controller, read: *Read, size: usize) bool {
    const sys = controller.base.sys_base;
    if (size <= read.buffer.len or size > 4 + 65535) return false;
    const room = sys.AllocVec(size, exec.MEMF_ANY) orelse return false;
    if (read.bigger) |old| sys.FreeVec(old);
    read.bigger = @ptrCast(room);
    read.bigger_size = size;
    return true;
}

/// Every request out taken back and waited for, and the unit closed. On
/// the task, which owns the reply port; the controller is `leaving`, so
/// nothing is sent again.
pub fn close(controller: *Controller) void {
    const sys = controller.base.sys_base;
    controller.leaving = true;
    if (controller.open) {
        for (&controller.reads) |*read| takeBack(sys, &read.request);
        for (&controller.writes) |*write| takeBack(sys, &write.request);
        sys.CloseDevice(&controller.reads[0].request.io.std.req);
        controller.open = false;
    }
    for (&controller.reads) |*read| {
        if (read.bigger) |room| sys.FreeVec(room);
        read.bigger = null;
    }
}

fn takeBack(sys: *ExecBase, request: *Request) void {
    if (!request.out) return;
    _ = sys.AbortIO(&request.io.std.req);
    _ = sys.WaitIO(&request.io.std.req);
    request.out = false;
}
