// SPDX-License-Identifier: MIT
//! slip.device's own state: the base, a line per unit, and the line's
//! side of the unit - the serial line it runs on, RFC 1055's framing both
//! ways, and what is being read.
//!
//! **Framing** (RFC 1055): a packet goes out between two ENDs (0xC0) - the
//! first one ends whatever noise the line had picked up - with every END
//! in it sent as ESC (0xDB) ESC_END (0xDC) and every ESC as ESC ESC_ESC
//! (0xDD). Coming in, the bytes up to an END are a packet, the escapes
//! undone; an empty one, between two ENDs, is nothing. A packet longer
//! than the MTU, or an ESC followed by anything but the two, makes the
//! packet damaged: it is dropped to its END and counted.
//!
//! **Reading** is one serial CMD_READ always out, in EOF mode with END as
//! the termination character, so the read comes back at the end of each
//! packet - or when its buffer is full, for a long one, whose bytes are
//! kept for the next. **Writing** encodes the packet and hands it to the
//! serial device, one at a time, on the device's task.

const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const serial = sdk.devices.serial;
const slip = sdk.devices.slip;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const TimerBase = sdk.interface.timer.TimerBase;
const unit_file = sdk.devices.network.unit;

pub const DEVICE_NAME = "slip.device";

/// RFC 1055's special bytes.
pub const end: u8 = 0xC0;
pub const esc: u8 = 0xDB;
pub const esc_end: u8 = 0xDC;
pub const esc_esc: u8 = 0xDD;

/// What one serial read takes before it comes back without an END.
pub const read_bytes = 512;
/// A packet encoded at its worst: every byte escaped, an END either side.
pub const encoded_max = 2 * slip.SLIP_MTU + 2;
/// The serial device's input buffer: a few packets, should the task be
/// slow to read them.
pub const serial_buffer_bytes = 8192;

/// The line a unit runs on unless its first opener names another.
pub const default_serial_unit = 1;
pub const default_baud = 115200;

pub const Unit = unit_file.Unit(Line);

/// One unit: the serial line under it and the requests' side above.
pub const Line = extern struct {
    /// The exec unit the openers' requests name; its port is the task's
    /// work queue for this line.
    unit: exec.Unit = .{},
    base: ?*SlipBase = null,
    /// The line's serial requests: one to read, kept out while the unit
    /// runs, and one to write; their answers come to `serial_port`, the
    /// task's.
    reader: serial.IOExtSer = .{},
    writer: serial.IOExtSer = .{},
    serial_port: exec.MsgPort = .{},
    /// The serial device is open, a read is out, the unit runs.
    serial_open: u8 = 0,
    reading: u8 = 0,
    running: u8 = 0,
    /// The packet coming in is past an ESC; it is damaged and dropped to
    /// its END.
    escaped: u8 = 0,
    dropping: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// The serial line the first opener named.
    serial_name: [64]u8 = @splat(0),
    serial_unit: u32 = default_serial_unit,
    baud: u32 = default_baud,
    /// The packet coming in so far.
    packet: [slip.SLIP_MTU]u8 = @splat(0),
    packet_length: u32 = 0,
    /// The serial read's buffer, a packet to send, and that packet
    /// encoded.
    input: [read_bytes]u8 = @splat(0),
    outgoing: [slip.SLIP_MTU]u8 = @splat(0),
    encoded: [encoded_max]u8 = @splat(0),
    /// The requests' side.
    net: Unit,

    // --- the unit's link --------------------------------------------------

    pub const framing = unit_file.Framing.point_to_point;
    pub const wire_type = net.S2WireType_SLIP;
    pub const mtu = slip.SLIP_MTU;
    /// What a serial line runs at, as the unit says it.
    pub const bps: u64 = default_baud;

    /// A line has no address of its own.
    pub fn setStation(line: *Line, address: *const [6]u8) void {
        _ = line;
        _ = address;
    }

    /// Every packet goes to the other end: there is nothing to filter.
    pub fn setFilter(line: *Line, groups: []const unit_file.Group, promiscuous: bool) void {
        _ = line;
        _ = groups;
        _ = promiscuous;
    }

    /// The line set to its speed, eight bits and no xON/xOFF - a packet's
    /// bytes are anything - with END ending a read, and the first read
    /// out; or the read taken back.
    pub fn setRunning(line: *Line, on: bool) void {
        const sys = line.base.?.sys_base;
        if (!on) {
            line.running = 0;
            if (line.reading != 0) {
                _ = sys.AbortIO(&line.reader.io_ser.req);
                _ = sys.WaitIO(&line.reader.io_ser.req);
                line.reading = 0;
            }
            return;
        }
        if (line.serial_open == 0) return;
        var set = line.reader;
        set.io_ser.req.command = serial.SDCMD_SETPARAMS;
        set.baud = line.baud;
        set.read_len = 8;
        set.write_len = 8;
        set.stop_bits = 1;
        set.ser_flags = (set.ser_flags & ~(serial.SERF_PARTY_ON | serial.SERF_PARTY_ODD | serial.SERF_7WIRE)) | serial.SERF_XDISABLED;
        set.term_array = @splat(end);
        _ = sys.DoIO(&set.io_ser.req);
        line.packet_length = 0;
        line.escaped = 0;
        line.dropping = 0;
        line.running = 1;
        line.read();
    }

    /// Every write waiting, encoded and sent, one at a time.
    pub fn startWrites(line: *Line) void {
        const sys = line.base.?.sys_base;
        while (line.running != 0) {
            const req = line.net.nextWrite() orelse return;
            const length = line.net.buildFrame(req, &line.outgoing);
            if (length == 0) continue;
            const encoded_length = encode(line.outgoing[0..length], &line.encoded);
            line.writer.io_ser.req.command = exec.CMD_WRITE;
            line.writer.io_ser.data = &line.encoded;
            line.writer.io_ser.length = encoded_length;
            const failed = sys.DoIO(&line.writer.io_ser.req) != 0;
            line.net.written(req, !failed);
        }
    }

    pub fn now(line: *Line) timer.TimeVal {
        var time: timer.TimeVal = .{};
        const base = line.base.?;
        if (base.timer_open != 0) {
            const timer_base: *TimerBase = @ptrCast(@alignCast(base.timer_io.node.device.?));
            timer_base.GetSysTime(&time);
        }
        return time;
    }

    // --- the task's side ---------------------------------------------------

    /// The next serial read out: up to `read_bytes`, or an END.
    pub fn read(line: *Line) void {
        const sys = line.base.?.sys_base;
        line.reader.io_ser.req.command = exec.CMD_READ;
        line.reader.io_ser.data = &line.input;
        line.reader.io_ser.length = read_bytes;
        line.reader.ser_flags |= serial.SERF_EOFMODE;
        line.reading = 1;
        sys.SendIO(&line.reader.io_ser.req);
    }

    /// The serial read came back: its bytes decoded, each packet handed to
    /// the unit, and the next read out while the unit runs.
    pub fn readDone(line: *Line) void {
        line.reading = 0;
        const got: usize = @intCast(@min(line.reader.io_ser.actual, read_bytes));
        // A read that fails - a framing error, a break - spoils the packet
        // it was in.
        if (line.reader.io_ser.req.err != 0 and line.reader.io_ser.req.err != exec.IOERR_ABORTED) line.dropping = 1;
        line.decode(line.input[0..got]);
        if (line.running != 0) line.read();
    }

    /// `bytes` from the line, taken into the packet coming in; each END
    /// hands it over.
    pub fn decode(line: *Line, bytes: []const u8) void {
        for (bytes) |byte| {
            if (byte == end) {
                if (line.dropping != 0) {
                    line.net.damaged();
                } else if (line.packet_length > 0) {
                    line.net.receive(line.packet[0..line.packet_length]);
                }
                line.packet_length = 0;
                line.escaped = 0;
                line.dropping = 0;
                continue;
            }
            if (line.dropping != 0) continue;
            var value = byte;
            if (line.escaped != 0) {
                line.escaped = 0;
                value = switch (byte) {
                    esc_end => end,
                    esc_esc => esc,
                    else => {
                        line.dropping = 1;
                        continue;
                    },
                };
            } else if (byte == esc) {
                line.escaped = 1;
                continue;
            }
            if (line.packet_length == line.packet.len) {
                line.dropping = 1;
                continue;
            }
            line.packet[line.packet_length] = value;
            line.packet_length += 1;
        }
    }
};

/// `packet` encoded into `into` (`encoded_max` bytes): its length.
pub fn encode(packet: []const u8, into: []u8) u32 {
    var at: usize = 0;
    into[at] = end;
    at += 1;
    for (packet) |byte| {
        switch (byte) {
            end => {
                into[at] = esc;
                into[at + 1] = esc_end;
                at += 2;
            },
            esc => {
                into[at] = esc;
                into[at + 1] = esc_esc;
                at += 2;
            },
            else => {
                into[at] = byte;
                at += 1;
            },
        }
    }
    into[at] = end;
    return @intCast(at + 1);
}

/// The device's base: a line per unit, and the task that runs them all.
pub const SlipBase = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// The task every request and every serial answer runs on: the
    /// openers' copy calls run only there.
    task: exec.Task,
    stack: ?*anyopaque = null,
    /// utility.library, for the tag lists OpenDevice is handed.
    utility: ?*UtilityBase = null,
    /// The one signal every port of every line raises for the task.
    work_mask: u32 = 0,
    /// For the system time a unit goes online at.
    timer_io: timer.TimeRequest = .{},
    timer_open: u8 = 0,
    /// The task is ready for requests.
    ready: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
    /// The task that started this one, and the signal it waits on until
    /// the task takes requests.
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    pad2: [3]u8 = .{ 0, 0, 0 },
    lines: [slip.SLIP_UNITS]Line,
    /// What the device was loaded from, for its expunge to hand back.
    seg_list: ?*anyopaque = null,
};

pub fn slipBase(dev: *exec.Device) *SlipBase {
    return @fieldParentPtr("dev", dev);
}

/// The line of the request's unit.
pub fn lineOf(io: *exec.IORequest) *Line {
    return @fieldParentPtr("unit", io.unit.?);
}

pub fn sanaReq(io: *exec.IORequest) *net.IOSana2Req {
    return @alignCast(@fieldParentPtr("req", io));
}

/// The request a message on a port belongs to.
pub fn requestOf(msg: *exec.Message) *exec.IORequest {
    return @fieldParentPtr("message", msg);
}
