// SPDX-License-Identifier: MIT
//! The serial line Terminal is joined to: a unit of a device that speaks
//! serial.device's commands, opened for this program alone.
//!
//! A read of one byte is always waiting on the line, on a port of its
//! own, so the line's bytes are waited for together with the window's
//! messages and the keys. When it comes back, the line is asked how many
//! more wait (SDCMD_QUERY) and they are read at once: a burst costs two
//! requests, not one per byte. Writes, the query and the settings go
//! through a second request on a port of its own, and are done with
//! DoIO - serial.device writes inside BeginIO.
//!
//! A line's parameters cannot change while a read waits on it, so a new
//! speed or frame takes the read back, sets them, and puts it out again.

const sdk = @import("sdk");
const exec = sdk.exec;
const serial = sdk.devices.serial;
const ExecBase = sdk.interface.exec.ExecBase;
const settings_file = @import("settings.zig");
const Settings = settings_file.Settings;

/// The input buffer the line is opened with: what may wait while the
/// program is busy elsewhere - in a requester, say - before bytes are
/// lost.
const rbuf_len = 8192;
/// How long a break holds the line low: a quarter of a second.
const break_us = 250_000;

pub const Line = struct {
    sys: *ExecBase,
    read_port: ?*exec.MsgPort = null,
    write_port: ?*exec.MsgPort = null,
    reader: serial.IOExtSer = .{},
    writer: serial.IOExtSer = .{},
    open: bool = false,
    /// The read is out.
    waiting: bool = false,
    /// What came in, the byte the waiting read took first.
    buffer: [512]u8 = @splat(0),

    /// The line `settings` names opened and set up, its read put out.
    /// Null when it is open, else why it is not.
    pub fn openLine(line: *Line, settings: *const Settings) ?[*:0]const u8 {
        line.closeLine();
        const device = settings.deviceName() orelse return "no line is chosen";
        const sys = line.sys;
        line.read_port = sys.CreateMsgPort() orelse return "no memory";
        line.write_port = sys.CreateMsgPort() orelse {
            line.freePorts();
            return "no memory";
        };
        line.reader = .{};
        line.reader.io_ser.req.message.reply_port = line.read_port;
        line.reader.io_ser.req.message.length = @sizeOf(serial.IOExtSer);
        line.reader.rbuf_len = rbuf_len;
        const err = sys.OpenDevice(device.ptr, settings.unit, &line.reader.io_ser.req, 0);
        if (err != 0) {
            line.freePorts();
            return switch (err) {
                serial.SerErr_DevBusy => "it is in use",
                serial.SerErr_BufErr => "there is no memory for its buffer",
                else => "it cannot be opened",
            };
        }
        line.writer = line.reader;
        line.writer.io_ser.req.message.reply_port = line.write_port;
        line.open = true;
        if (!line.setUp(settings)) {
            line.closeLine();
            return "it does not take these settings";
        }
        line.startRead();
        return null;
    }

    fn freePorts(line: *Line) void {
        if (line.read_port) |port| line.sys.DeleteMsgPort(port);
        if (line.write_port) |port| line.sys.DeleteMsgPort(port);
        line.read_port = null;
        line.write_port = null;
    }

    /// The read taken back, if it is out.
    fn stopRead(line: *Line) void {
        if (!line.waiting) return;
        const sys = line.sys;
        if (sys.CheckIO(&line.reader.io_ser.req) == null) _ = sys.AbortIO(&line.reader.io_ser.req);
        _ = sys.WaitIO(&line.reader.io_ser.req);
        line.waiting = false;
    }

    fn startRead(line: *Line) void {
        if (!line.open or line.waiting) return;
        line.reader.io_ser.req.command = exec.CMD_READ;
        line.reader.io_ser.data = &line.buffer;
        line.reader.io_ser.length = 1;
        line.sys.SendIO(&line.reader.io_ser.req);
        line.waiting = true;
    }

    pub fn closeLine(line: *Line) void {
        if (line.open) {
            line.stopRead();
            line.sys.CloseDevice(&line.reader.io_ser.req);
            line.open = false;
        }
        line.freePorts();
    }

    /// The speed, the frame and the handshake given to the line, with no
    /// read out while they are. False when the line refuses them.
    fn setUp(line: *Line, settings: *const Settings) bool {
        const frame = settings.frameOf();
        const w = &line.writer;
        w.io_ser.req.command = serial.SDCMD_SETPARAMS;
        w.baud = settings.baud;
        w.read_len = frame.bits;
        w.write_len = frame.bits;
        w.stop_bits = frame.stop_bits;
        w.rbuf_len = rbuf_len;
        w.brk_time = break_us;
        w.ctl_char = 0x1113_0000;
        w.ext_flags = 0;
        var flags: u8 = 0;
        switch (frame.parity) {
            .none => {},
            .even => flags |= serial.SERF_PARTY_ON,
            .odd => flags |= serial.SERF_PARTY_ON | serial.SERF_PARTY_ODD,
        }
        if (settings.handshake != .xonxoff) flags |= serial.SERF_XDISABLED;
        w.ser_flags = flags;
        return line.sys.DoIO(&w.io_ser.req) == 0;
    }

    /// New settings for the line that is open: the read taken back while
    /// they are set. False when the line refuses them.
    pub fn change(line: *Line, settings: *const Settings) bool {
        if (!line.open) return false;
        line.stopRead();
        defer line.startRead();
        return line.setUp(settings);
    }

    /// The signal the waiting read comes back with; 0 with no line.
    pub fn signal(line: *const Line) u32 {
        const port = line.read_port orelse return 0;
        return port.sigMask();
    }

    /// What came in since the last call, the read put out again: empty
    /// when the read has not come back. A read that ended in an error -
    /// a break, a parity or framing error, an overrun - still hands over
    /// what it took.
    pub fn received(line: *Line) []const u8 {
        if (!line.open or !line.waiting) return &.{};
        const sys = line.sys;
        if (sys.CheckIO(&line.reader.io_ser.req) == null) return &.{};
        _ = sys.WaitIO(&line.reader.io_ser.req);
        line.waiting = false;
        var count: usize = @intCast(line.reader.io_ser.actual);
        // The bytes that waited behind it.
        const w = &line.writer;
        w.io_ser.req.command = serial.SDCMD_QUERY;
        if (sys.DoIO(&w.io_ser.req) == 0 and w.io_ser.actual > 0) {
            const more: usize = @intCast(@min(w.io_ser.actual, line.buffer.len - count));
            w.io_ser.req.command = exec.CMD_READ;
            w.io_ser.data = line.buffer[count..].ptr;
            w.io_ser.length = more;
            if (sys.DoIO(&w.io_ser.req) == 0 or w.io_ser.actual > 0) count += @intCast(w.io_ser.actual);
        }
        line.startRead();
        return line.buffer[0..count];
    }

    /// `bytes` sent on the line, whole.
    pub fn send(line: *Line, bytes: []const u8) void {
        if (!line.open or bytes.len == 0) return;
        const w = &line.writer;
        w.io_ser.req.command = exec.CMD_WRITE;
        w.io_ser.data = @constCast(bytes.ptr);
        w.io_ser.length = bytes.len;
        _ = line.sys.DoIO(&w.io_ser.req);
    }

    /// The line held low for a quarter of a second.
    pub fn sendBreak(line: *Line) void {
        if (!line.open) return;
        const w = &line.writer;
        w.io_ser.req.command = serial.SDCMD_BREAK;
        _ = line.sys.DoIO(&w.io_ser.req);
    }
};
