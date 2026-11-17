// SPDX-License-Identifier: MPL-2.0
//! The BCM2711's JPEG decoder, which is the VideoCore's firmware: its MMAL
//! component "ril.image_decode", reached through vchiq.resource
//! (sdk.hardware.mmal) - the Compute Module 4's.
//!
//! **A decode** makes the component and sets its ports: the input takes
//! JPEG, in buffers of up to `piece_most` bytes; the output gives the
//! decoded samples in three planes, the colour halved across and down
//! (I420) - a grey file's brightness plane is the picture. The output is
//! enabled with no buffers: once the component has read the file's frame
//! header it says the picture's format (EVENT_FORMAT_CHANGED), and the
//! port is disabled, set to it, enabled again and handed its buffers.
//!
//! **Only 4:2:0 and grey** are taken. The firmware gives I420 and nothing
//! else that works: asked for I422 it sizes its buffers for that and
//! writes something else (its planes as I420's); asked for blue, green and
//! red (BGRA, RGBA) it gives no picture, or a wrong one. A 4:2:2 or 4:4:4
//! file would lose half or three quarters of its colour, so it is
//! JPEGERR_UNSUPPORTED and decoded in software.
//!
//! **The file** goes in pieces, each a buffer's message and then its bytes
//! as a bulk the firmware reads straight from the caller's file - nothing
//! is copied on the way in. The last piece is the frame's end and the
//! stream's. As many pieces are out at once as the input has buffers; one
//! is free again once the component handed its buffer back and the
//! firmware read the bulk.
//!
//! **The picture** comes in output buffers' messages, the bytes of each in
//! a bulk the firmware writes into memory here, one after the other until
//! one is the frame's end. Its planes are then turned into the caller's
//! picture, three bytes a pixel, by ycc.zig as other codecs' samples are,
//! or for grey its brightness rows copied as they are. The component is
//! made and destroyed for each decode.

const sdk = @import("sdk");
const exec = sdk.exec;
const types = sdk.resources.jpeg;
const vchiq = sdk.resources.vchiq;
const mmal = sdk.hardware.mmal;
const ExecBase = sdk.interface.exec.ExecBase;
const VchiqBase = sdk.interface.vchiq.VchiqBase;
const Header = @import("../header/_header.zig").Header;
const ycc = @import("ycc.zig");

/// The input's buffers, and the most bytes each takes.
const in_count = 3;
const piece_most: u32 = 512 * 1024;
/// How long a bulk of the picture's is waited for once it is asked for.
const bulk_us: u64 = 2_000_000;

const Input = struct {
    /// The component has the buffer.
    with_vpu: bool = false,
    bulk: vchiq.VchiqBulk = .{},

    fn free(i: *const Input) bool {
        return !i.with_vpu and (i.bulk.size == 0 or i.bulk.done.signalled != 0);
    }
};

/// `file` decoded by the firmware into `out`, `pitch` bytes from one row
/// to the next, as `h` says the picture is: JPEGERR_OK; JPEGERR_NO_ENGINE
/// without the firmware's decoder; JPEGERR_NO_MEMORY; JPEGERR_UNSUPPORTED
/// for a 4:2:2 or 4:4:4 file, and a picture the firmware will not give in
/// its format;
/// JPEGERR_FAILED when it stopped on the file or did not finish within
/// `time_us`. The caller holds the resource's lock.
pub fn decode(sys: *ExecBase, vq: *VchiqBase, file: []const u8, h: *const Header, out: [*]u8, pitch: u32, time_us: u64) u32 {
    if (!takes(h.sampling)) return types.JPEGERR_UNSUPPORTED;
    const memory = sys.AllocVec(@sizeOf(Decode), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return types.JPEGERR_NO_MEMORY;
    defer sys.FreeVec(memory);
    const d: *Decode = @ptrCast(@alignCast(memory));
    d.* = .{ .sys = sys, .vq = vq, .file = file, .grey = h.count == 1 };
    defer d.end();
    var answer = d.start();
    if (answer == types.JPEGERR_OK) answer = d.run(time_us);
    if (answer == types.JPEGERR_OK) answer = d.copyOut(h, out, pitch);
    return answer;
}

/// Whether the firmware gives a file of `sampling` at its full colour.
fn takes(sampling: u32) bool {
    return sampling == types.JPEGSAMP_420 or sampling == types.JPEGSAMP_GREY;
}

const Decode = struct {
    sys: *ExecBase,
    vq: *VchiqBase,
    file: []const u8,
    grey: bool,
    c: mmal.Client = undefined,
    open: bool = false,
    made: bool = false,
    component: u32 = 0,
    input: mmal.PortInfo = undefined,
    output: mmal.PortInfo = undefined,
    out_enabled: bool = false,
    /// The bytes an input buffer takes, and how many of the file are out.
    piece: u32 = 0,
    sent: usize = 0,
    inputs: [in_count]Input = @splat(.{}),
    /// The picture as the firmware gives it: where it is received, how
    /// much room there is, how much came, and its layout - the planes'
    /// offsets and pitches as the first buffer gives them.
    received: ?*anyopaque = null,
    received_size: usize = 0,
    data: [*]u8 = undefined,
    room: usize = 0,
    length: usize = 0,
    planes: u32 = 0,
    plane_offset: [3]u32 = @splat(0),
    plane_pitch: [3]u32 = @splat(0),
    rx_bulk: vchiq.VchiqBulk = .{},
    done: bool = false,
    failed: u32 = types.JPEGERR_OK,
    /// The end of stream's eight bytes, which the firmware sends as a
    /// bulk of their own: into a line of their own in here.
    scratch: [192]u8 = undefined,

    fn log(d: *Decode, comptime fmt: []const u8, args: anytype) void {
        exec.kprintf(d.sys, "%s: the firmware's decoder: " ++ fmt ++ "\n", .{types.JPEGNAME} ++ args);
    }

    fn fail(d: *Decode, why: u32) void {
        if (d.failed == types.JPEGERR_OK) d.failed = why;
    }

    fn refused(d: *Decode, what: [*:0]const u8) u32 {
        d.log("ril.image_decode refused %s", .{what});
        return types.JPEGERR_NO_ENGINE;
    }

    /// The component made, its ports set and enabled.
    fn start(d: *Decode) u32 {
        const opened = d.c.open(d.vq);
        if (opened != vchiq.VCHIQERR_OK) {
            d.log("the mmal service did not open (%u)", .{opened});
            return types.JPEGERR_NO_ENGINE;
        }
        d.open = true;
        var reply: mmal.ComponentCreateReply = undefined;
        if (d.c.create("ril.image_decode", 0, &reply) != vchiq.VCHIQERR_OK or reply.status != mmal.STATUS_SUCCESS) {
            d.log("the firmware made no ril.image_decode", .{});
            return types.JPEGERR_NO_ENGINE;
        }
        d.component = reply.component_handle;
        d.made = true;
        const handle = d.component;
        if (d.c.portInfo(handle, mmal.PORT_INPUT, 0, &d.input) != mmal.STATUS_SUCCESS or
            d.c.portInfo(handle, mmal.PORT_OUTPUT, 0, &d.output) != mmal.STATUS_SUCCESS) return d.refused("its ports");
        if (d.input.port.buffer_num_min > in_count) return d.refused("three input buffers");
        const whole: u32 = @intCast((d.file.len + 4095) & ~@as(usize, 4095));
        d.piece = @max(d.input.port.buffer_size_min, @min(whole, piece_most));
        d.input.format.encoding = mmal.ENCODING_JPEG;
        d.input.format.encoding_variant = 0;
        d.input.port.buffer_num = in_count;
        d.input.port.buffer_size = d.piece;
        if (d.c.setPort(&d.input) != mmal.STATUS_SUCCESS) return d.refused("its input");
        d.output.format.encoding = mmal.ENCODING_I420;
        if (d.c.setPort(&d.output) != mmal.STATUS_SUCCESS) return d.refused("its output");
        if (d.c.component(mmal.MSG_COMPONENT_ENABLE, handle) != mmal.STATUS_SUCCESS) return d.refused("to be enabled");
        if (d.c.portAction(&d.output, mmal.ACTION_ENABLE) != mmal.STATUS_SUCCESS) return d.refused("its output enabled");
        d.out_enabled = true;
        if (d.c.portAction(&d.input, mmal.ACTION_ENABLE) != mmal.STATUS_SUCCESS) return d.refused("its input enabled");
        return types.JPEGERR_OK;
    }

    /// The component destroyed and the service closed, before what the
    /// firmware may still have been reading or writing is freed.
    fn end(d: *Decode) void {
        if (d.made) {
            _ = d.c.component(mmal.MSG_COMPONENT_DISABLE, d.component);
            _ = d.c.component(mmal.MSG_COMPONENT_DESTROY, d.component);
        }
        if (d.open) d.c.close();
        d.made = false;
        d.open = false;
        if (d.received) |memory| d.sys.FreeMem(memory, d.received_size);
        d.received = null;
    }

    /// The file fed and the picture taken, within `time_us`.
    fn run(d: *Decode, time_us: u64) u32 {
        const until = d.sys.UptimeUs() + time_us;
        while (!d.done) {
            d.feed();
            if (d.failed != types.JPEGERR_OK) return d.failed;
            const now = d.sys.UptimeUs();
            if (now >= until) {
                d.log("no picture after %u ms (%u of %u bytes sent)", .{ @as(u32, @intCast(time_us / 1000)), @as(u32, @intCast(d.sent)), @as(u32, @intCast(d.file.len)) });
                return types.JPEGERR_FAILED;
            }
            _ = d.pump(@min(until - now, 20_000));
            if (d.failed != types.JPEGERR_OK) return d.failed;
        }
        return types.JPEGERR_OK;
    }

    // --- the file in ----------------------------------------------------------

    /// As many pieces of the file handed over as there are free buffers.
    fn feed(d: *Decode) void {
        while (d.sent < d.file.len) {
            const index = for (&d.inputs, 0..) |*i, n| {
                if (i.free()) break n;
            } else return;
            const slot = &d.inputs[index];
            const n: u32 = @intCast(@min(d.file.len - d.sent, d.piece));
            var flags: u32 = 0;
            if (d.sent == 0) flags |= mmal.BUFFER_FLAG_FRAME_START;
            if (d.sent + n == d.file.len) flags |= mmal.BUFFER_FLAG_FRAME_END | mmal.BUFFER_FLAG_EOS;
            const context: u32 = @intCast(index + 1);
            var m: mmal.BufferMessage = .{
                .drvbuf = .{ .component_handle = d.component, .port_handle = d.input.port_handle, .client_context = context },
                .buffer = .{ .data = context, .alloc_size = d.piece, .length = n, .flags = flags },
            };
            m.h.context = context;
            if (d.c.send(&m) != vchiq.VCHIQERR_OK) {
                d.log("an input buffer could not go", .{});
                return d.fail(types.JPEGERR_NO_ENGINE);
            }
            slot.with_vpu = true;
            // A whole number of words: the firmware may read up to three
            // bytes past the file's end, and uses none of them.
            slot.bulk = .{ .data = @ptrCast(@constCast(d.file.ptr + d.sent)), .size = mmal.bulkBytes(n), .direction = vchiq.VCHIQBULK_TRANSMIT };
            const queued = d.vq.QueueBulk(d.c.service, &slot.bulk);
            if (queued != vchiq.VCHIQERR_OK) {
                slot.bulk = .{};
                d.log("a piece of the file could not go (%u)", .{queued});
                return d.fail(types.JPEGERR_NO_ENGINE);
            }
            d.sent += n;
        }
    }

    // --- what the component sends ---------------------------------------------

    /// One message from the component dealt with, waiting up to `wait`
    /// for it: false when none came.
    fn pump(d: *Decode, wait: u64) bool {
        var m: mmal.Message = .{};
        const got = d.c.next(&m, wait);
        if (got == vchiq.VCHIQERR_TIMEOUT) return false;
        if (got != vchiq.VCHIQERR_OK) {
            d.log("the mmal service closed (%u)", .{got});
            d.fail(types.JPEGERR_NO_ENGINE);
            return false;
        }
        switch (m.header().type) {
            mmal.MSG_BUFFER_TO_HOST => {
                const b = m.as(mmal.BufferMessage).?;
                if (b.drvbuf.port_handle == d.input.port_handle) {
                    const n = b.drvbuf.client_context;
                    if (n >= 1 and n <= in_count) d.inputs[n - 1].with_vpu = false;
                    if (b.buffer.flags & mmal.BUFFER_FLAG_TRANSMISSION_FAILED != 0) {
                        d.log("the firmware could not take a piece of the file", .{});
                        d.fail(types.JPEGERR_NO_ENGINE);
                    }
                } else if (b.drvbuf.port_handle == d.output.port_handle) {
                    d.outputBack(b);
                }
            },
            mmal.MSG_EVENT_TO_HOST => d.event(m.as(mmal.EventToHost).?),
            else => d.log("message %u not known", .{m.header().type}),
        }
        return true;
    }

    fn event(d: *Decode, e: *const mmal.EventToHost) void {
        switch (e.cmd) {
            mmal.EVENT_FORMAT_CHANGED => d.formatChanged(@ptrCast(@alignCast(&e.data))),
            mmal.EVENT_ERROR => {
                const code = @as(u32, e.data[0]) | @as(u32, e.data[1]) << 8 | @as(u32, e.data[2]) << 16 | @as(u32, e.data[3]) << 24;
                d.log("the component stopped on the file (%u)", .{code});
                d.fail(types.JPEGERR_FAILED);
            },
            else => {},
        }
    }

    /// The picture's format: the output port set to it, the room for the
    /// picture made, and the port's buffers handed to the component.
    fn formatChanged(d: *Decode, f: *const mmal.FormatChanged) void {
        const changed: mmal.FormatChanged = f.*;
        if (d.out_enabled) {
            _ = d.c.portAction(&d.output, mmal.ACTION_DISABLE);
            d.out_enabled = false;
        }
        d.output.format = changed.format;
        d.output.format.encoding = mmal.ENCODING_I420;
        d.output.es = changed.es;
        d.output.port.buffer_num = @max(changed.buffer_num_min, 1);
        d.output.port.buffer_size = @max(changed.buffer_size_min, changed.buffer_size_recommended);
        if (d.c.setPort(&d.output) != mmal.STATUS_SUCCESS) {
            d.log("its output did not take the picture's format", .{});
            return d.fail(types.JPEGERR_UNSUPPORTED);
        }
        const es = d.output.es;
        // The whole picture, however many buffers it comes in.
        const whole = @as(usize, es.width) * es.height * 3 / 2;
        const room = (@max(whole, d.output.port.buffer_size) + 63) & ~@as(usize, 63);
        if (d.received == null or room > d.room) {
            if (d.received) |memory| d.sys.FreeMem(memory, d.received_size);
            d.received_size = room + 64;
            d.received = d.sys.AllocMem(d.received_size, exec.MEMF_ANY) orelse {
                d.received_size = 0;
                return d.fail(types.JPEGERR_NO_MEMORY);
            };
            d.data = @ptrFromInt((@intFromPtr(d.received.?) + 63) & ~@as(usize, 63));
            d.room = room;
        }
        d.length = 0;
        if (d.c.portAction(&d.output, mmal.ACTION_ENABLE) != mmal.STATUS_SUCCESS) {
            d.log("its output was not enabled", .{});
            return d.fail(types.JPEGERR_NO_ENGINE);
        }
        d.out_enabled = true;
        var n: u32 = 0;
        while (n < d.output.port.buffer_num) : (n += 1) d.giveOutput(n + 1);
    }

    fn giveOutput(d: *Decode, context: u32) void {
        var m: mmal.BufferMessage = .{
            .drvbuf = .{ .component_handle = d.component, .port_handle = d.output.port_handle, .client_context = context },
            .buffer = .{ .data = context, .alloc_size = d.output.port.buffer_size },
        };
        m.h.context = context;
        if (d.c.send(&m) != vchiq.VCHIQERR_OK) d.fail(types.JPEGERR_NO_ENGINE);
    }

    /// An output buffer back: its bytes received after what came before,
    /// and the picture done at the frame's end; the buffer handed back
    /// while more is to come.
    fn outputBack(d: *Decode, b: *const mmal.BufferMessage) void {
        const flags = b.buffer.flags;
        const ends = flags & (mmal.BUFFER_FLAG_FRAME_END | mmal.BUFFER_FLAG_EOS) != 0;
        if (b.buffer.cmd != 0) {
            d.log("event %x in an output buffer", .{b.buffer.cmd});
            return d.giveOutput(b.drvbuf.client_context);
        }
        if (b.buffer.length == 0) {
            if (flags & mmal.BUFFER_FLAG_EOS != 0) {
                // Its eight bytes come as a bulk all the same.
                const line: *anyopaque = @ptrFromInt((@intFromPtr(&d.scratch) + 63) & ~@as(usize, 63));
                d.rx_bulk = .{ .data = line, .size = 8, .direction = vchiq.VCHIQBULK_RECEIVE };
                if (d.vq.QueueBulk(d.c.service, &d.rx_bulk) != vchiq.VCHIQERR_OK or d.vq.WaitBulk(&d.rx_bulk, bulk_us) != vchiq.VCHIQERR_OK) {
                    d.log("the end of stream's bytes did not come", .{});
                    return d.fail(types.JPEGERR_NO_ENGINE);
                }
                if (d.length == 0) {
                    d.log("the stream ended without a picture", .{});
                    return d.fail(types.JPEGERR_FAILED);
                }
                d.done = true;
            } else if (!d.done) {
                d.giveOutput(b.drvbuf.client_context);
            }
            return;
        }
        if (d.received == null) {
            d.log("a picture came before its format", .{});
            return d.fail(types.JPEGERR_FAILED);
        }
        if (d.length == 0) {
            d.planes = b.planes;
            d.plane_offset = b.plane_offset[0..3].*;
            d.plane_pitch = b.plane_pitch[0..3].*;
        }
        const length: usize = b.buffer.length;
        if (d.length + length > d.room) {
            d.log("a picture of more than %u bytes", .{@as(u32, @intCast(d.room))});
            return d.fail(types.JPEGERR_FAILED);
        }
        if (b.payload_in_message != 0) {
            const n = @min(b.payload_in_message, mmal.short_data, length);
            @memcpy(d.data[d.length..][0..n], b.short_data[0..n]);
        } else {
            const asked: u32 = @intCast(@min(mmal.bulkBytes(@intCast(length)), d.room - d.length));
            d.rx_bulk = .{ .data = d.data + d.length, .size = asked, .direction = vchiq.VCHIQBULK_RECEIVE };
            const queued = d.vq.QueueBulk(d.c.service, &d.rx_bulk);
            if (queued != vchiq.VCHIQERR_OK or d.vq.WaitBulk(&d.rx_bulk, bulk_us) != vchiq.VCHIQERR_OK) {
                d.log("the picture's bytes did not come (%u)", .{queued});
                return d.fail(types.JPEGERR_NO_ENGINE);
            }
        }
        d.length += length;
        if (ends) {
            d.done = true;
        } else {
            d.giveOutput(b.drvbuf.client_context);
        }
    }

    // --- the picture out ------------------------------------------------------

    /// The firmware's planes into the caller's picture: turned into blue,
    /// green and red, or the brightness rows copied for grey. Where the
    /// first buffer gave no planes they lie one after the other, the
    /// colour planes half as wide and as high as the brightness one.
    fn copyOut(d: *Decode, h: *const Header, out: [*]u8, pitch: u32) u32 {
        const es = d.output.es;
        const down: usize = 2;
        const given = d.planes >= 3 and d.plane_pitch[0] != 0 and d.plane_pitch[1] != 0;
        const y_pitch: usize = if (given) d.plane_pitch[0] else es.width;
        const c_pitch: usize = if (given) d.plane_pitch[1] else es.width / 2;
        const y_at: usize = if (given) d.plane_offset[0] else 0;
        const cb_at: usize = if (given) d.plane_offset[1] else y_pitch * es.height;
        const cr_at: usize = if (given) d.plane_offset[2] else cb_at + c_pitch * (es.height / down);
        const left: usize = @intCast(@max(es.crop.x, 0));
        const top: usize = @intCast(@max(es.crop.y, 0));
        const width: usize = h.width;
        const height: usize = h.height;
        // The last byte each plane is read at, past which nothing came.
        const y_end = y_at + (top + height - 1) * y_pitch + left + width;
        const c_row_end = ((top + height - 1) / down) * c_pitch + (left + width + 1) / 2;
        const fits = es.crop.width >= h.width and es.crop.height >= h.height and left % 2 == 0 and top % down == 0 and
            y_pitch >= left + width and c_pitch >= (left + width + 1) / 2 and
            y_end <= d.length and (d.grey or (cb_at + c_row_end <= d.length and cr_at + c_row_end <= d.length));
        if (!fits) {
            d.log("a picture of %dx%d, %u and %u bytes a row, %u bytes, for one of %ux%u", .{ es.crop.width, es.crop.height, @as(u32, @intCast(y_pitch)), @as(u32, @intCast(c_pitch)), @as(u32, @intCast(d.length)), h.width, h.height });
            return types.JPEGERR_FAILED;
        }
        const y = d.data + y_at + top * y_pitch + left;
        if (d.grey) {
            var row: usize = 0;
            while (row < height) : (row += 1) @memcpy((out + row * pitch)[0..width], (y + row * y_pitch)[0..width]);
        } else {
            const c_first = (top / down) * c_pitch + left / 2;
            ycc.planarToBgr(y, y_pitch, d.data + cb_at + c_first, d.data + cr_at + c_first, c_pitch, true, out, pitch, width, height);
        }
        return types.JPEGERR_OK;
    }
};

test "the firmware takes 4:2:0 and grey, not the files whose colour it would halve" {
    const testing = @import("std").testing;
    try testing.expect(takes(types.JPEGSAMP_420));
    try testing.expect(takes(types.JPEGSAMP_GREY));
    try testing.expect(!takes(types.JPEGSAMP_422));
    try testing.expect(!takes(types.JPEGSAMP_444));
}
