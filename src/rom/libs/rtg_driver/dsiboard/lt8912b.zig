// SPDX-License-Identifier: MPL-2.0
//! The LT8912B, a bridge from MIPI-DSI to HDMI, as the DSI board brings
//! it up over I2C - and the monitor behind it, read on the same bus.
//!
//! The bridge answers at three addresses: its main page (the part's
//! PART_Address), the page for its DSI receiver one above, and the page
//! for the AVI infoframe it sends the monitor two above. It takes RGB888
//! on one to four lanes and regenerates the pixel clock from what arrives
//! (its DDS), so its own registers only need the timings the link carries
//! - and the DDS's starting frequency: it follows the stream only slowly,
//! and started far from the pixel clock it takes minutes to get there,
//! the picture flickering and its lines shifting meanwhile. Left to follow
//! a link with nothing on it, it drifts away just as far; so once the
//! stream runs, the DDS is started again at the pixel clock and the
//! receiver reset (`follow`). (The transmitter is switched on with the
//! rest of the bring-up: switched on only after that, the picture comes
//! and goes on its own.)
//! Its bring-up is a fixed program - clocks, the analog parts, the DSI
//! receiver, the DDS, the video timings, the infoframe, a reset of the
//! receiver, the HDMI transmitter on - written as ESP-IDF's
//! esp_lcd_lt8912b component (v1) writes it.
//!
//! **The monitor** keeps its description (EDID) in a memory at 0x50 on
//! the HDMI connector's DDC lines, which this board joins to the bridge's
//! bus: a monitor is there when that memory answers.
//!
//! The bus is i2c.device's, reached through a request the caller opens
//! for the task it runs on (`I2c`); everything here waits on it.

const sdk = @import("sdk");
const exec = sdk.exec;
const i2c = sdk.devices.i2c;
const ExecBase = sdk.interface.exec.ExecBase;
const systimer = sdk.hardware.systimer;

/// A request on one unit of i2c.device, for the task that opened it.
pub const I2c = struct {
    sys: *ExecBase,
    request: *i2c.IOExtI2C,

    pub fn open(sys: *ExecBase, unit: u32) ?I2c {
        const port = sys.CreateMsgPort() orelse return null;
        const io = sys.CreateIORequest(port, @sizeOf(i2c.IOExtI2C)) orelse {
            sys.DeleteMsgPort(port);
            return null;
        };
        if (sys.OpenDevice(i2c.DEVICE_NAME, unit, io, 0) != 0) {
            sys.DeleteIORequest(io);
            sys.DeleteMsgPort(port);
            return null;
        }
        return .{ .sys = sys, .request = @ptrCast(@alignCast(io)) };
    }

    pub fn close(bus: I2c) void {
        const io = &bus.request.req.req;
        const port = io.message.reply_port;
        bus.sys.CloseDevice(io);
        bus.sys.DeleteIORequest(io);
        bus.sys.DeleteMsgPort(port);
    }

    fn run(bus: I2c, command: u16, address: u32) bool {
        const r = bus.request;
        r.req.req.command = command;
        r.address = @intCast(address);
        return bus.sys.DoIO(&r.req.req) == 0;
    }

    /// Whether anything answers at `address`.
    pub fn probe(bus: I2c, address: u32) bool {
        bus.request.req.length = 0;
        return bus.run(i2c.I2CCMD_PROBE, address) and bus.request.req.actual == 1;
    }

    /// One register written.
    pub fn write(bus: I2c, address: u32, register: u8, value: u8) bool {
        var bytes = [2]u8{ register, value };
        bus.request.req.data = &bytes;
        bus.request.req.length = 2;
        return bus.run(exec.CMD_WRITE, address);
    }

    /// `into.len` bytes read from register `register` on.
    pub fn read(bus: I2c, address: u32, register: u8, into: []u8) bool {
        var which = [1]u8{register};
        const r = bus.request;
        r.wr_data = &which;
        r.wr_length = 1;
        r.req.data = into.ptr;
        r.req.length = @intCast(into.len);
        return bus.run(i2c.I2CCMD_WRITEREAD, address) and r.req.actual == into.len;
    }
};

/// The monitor's description, and where it answers.
const edid_address = 0x50;
pub const Edid = [128]u8;

/// Whether a monitor's EDID answers on the bus.
pub fn monitorThere(bus: I2c) bool {
    return bus.probe(edid_address);
}

/// The monitor's EDID, its first block: false when it does not read, or
/// does not begin as an EDID does.
pub fn readEdid(bus: I2c, into: *Edid) bool {
    if (!bus.read(edid_address, 0, into)) return false;
    const header = [8]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    for (header, 0..) |byte, i| {
        if (into[i] != byte) return false;
    }
    return true;
}

/// The monitor's name from its EDID (descriptor 0xFC), up to 13
/// characters and NUL-terminated in `into`; empty if it gives none.
pub fn monitorName(edid: *const Edid, into: *[14]u8) void {
    into.* = @splat(0);
    var at: usize = 54;
    while (at + 18 <= 126) : (at += 18) {
        const d = edid[at..][0..18];
        if (d[0] != 0 or d[1] != 0 or d[3] != 0xFC) continue;
        var n: usize = 0;
        while (n < 13 and d[5 + n] != 0x0A) : (n += 1) into[n] = d[5 + n];
        return;
    }
}

/// What the bridge sends the monitor: the picture's size, its timings in
/// pixel clocks and lines, the sync pulses' polarity, the pixel clock.
pub const Mode = struct {
    width: u32,
    height: u32,
    hsync: u32,
    hbp: u32,
    hfp: u32,
    vsync: u32,
    vbp: u32,
    vfp: u32,
    hsync_high: bool,
    vsync_high: bool,
    pixel_hz: u32,
};

/// The DDS's frequency word for a pixel clock: 0x16C16 a megahertz.
fn ddsWord(pixel_hz: u32) u32 {
    return @intCast(@as(u64, pixel_hz) * 0x16C16 / 1_000_000);
}

/// A register and what goes into it.
const Write = struct { u8, u8 };

/// The main page: the digital clocks on.
const digital_clocks = [_]Write{ .{ 0x02, 0xF7 }, .{ 0x08, 0xFF }, .{ 0x09, 0xFF }, .{ 0x0A, 0xFF }, .{ 0x0B, 0x7C }, .{ 0x0C, 0xFF } };
/// The main page: the HDMI transmitter's, the CBUS's and the HDMI PLL's
/// analog parts; the DSI receiver's (no P/N swap, its equaliser).
const analog = [_]Write{
    .{ 0x31, 0xE1 }, .{ 0x32, 0xE1 }, .{ 0x33, 0x0C }, .{ 0x37, 0x00 }, .{ 0x38, 0x22 }, .{ 0x60, 0x82 },
    .{ 0x39, 0x45 }, .{ 0x3A, 0x00 }, .{ 0x3B, 0x00 }, .{ 0x44, 0x31 }, .{ 0x55, 0x44 }, .{ 0x57, 0x01 },
    .{ 0x5A, 0x02 }, .{ 0x3E, 0xD6 }, .{ 0x3F, 0xD4 }, .{ 0x41, 0x3C },
};
/// The DSI page: the DDS that makes the pixel clock from the stream - its
/// FIFO's fill thresholds, its timer and trend steps; its starting
/// frequency word comes first (`setUp`).
const dds = [_]Write{
    .{ 0x1E, 0x4F }, .{ 0x1F, 0x5E }, .{ 0x20, 0x01 }, .{ 0x21, 0x2C },
    .{ 0x22, 0x01 }, .{ 0x23, 0xFA }, .{ 0x24, 0x00 }, .{ 0x25, 0xC8 },
    .{ 0x26, 0x00 }, .{ 0x27, 0x5E }, .{ 0x28, 0x01 }, .{ 0x29, 0x2C },
    .{ 0x2A, 0x01 }, .{ 0x2B, 0xFA }, .{ 0x2C, 0x00 }, .{ 0x2D, 0xC8 },
    .{ 0x2E, 0x00 }, .{ 0x42, 0x64 }, .{ 0x43, 0x00 }, .{ 0x44, 0x04 },
    .{ 0x45, 0x00 }, .{ 0x46, 0x59 }, .{ 0x47, 0x00 }, .{ 0x48, 0xF2 },
    .{ 0x49, 0x06 }, .{ 0x4A, 0x00 }, .{ 0x4B, 0x72 }, .{ 0x4C, 0x45 },
    .{ 0x4D, 0x00 }, .{ 0x52, 0x08 }, .{ 0x53, 0x00 }, .{ 0x54, 0xB2 },
    .{ 0x55, 0x00 }, .{ 0x56, 0xE4 }, .{ 0x57, 0x0D }, .{ 0x58, 0x00 },
    .{ 0x59, 0xE4 }, .{ 0x5A, 0x8A }, .{ 0x5B, 0x00 }, .{ 0x5C, 0x34 },
    .{ 0x51, 0x00 },
};
/// The AVI page: HDMI's I2S audio settings, left as the bridge wants them.
const audio = [_]Write{ .{ 0x06, 0x08 }, .{ 0x07, 0xF0 }, .{ 0x34, 0xD2 }, .{ 0x0F, 0x2B } };
/// The main page: the LVDS path powered and bypassed - its PLL from the
/// pixel clock, the core PLL reset, the scaler off - then its output off.
const lvds = [_]Write{
    .{ 0x44, 0x30 }, .{ 0x51, 0x05 }, .{ 0x50, 0x24 }, .{ 0x51, 0x2D }, .{ 0x52, 0x04 }, .{ 0x69, 0x0E },
    .{ 0x69, 0x8E }, .{ 0x6A, 0x00 }, .{ 0x6C, 0xB8 }, .{ 0x6B, 0x51 }, .{ 0x04, 0xFB }, .{ 0x04, 0xFF },
    .{ 0x7F, 0x00 }, .{ 0xA8, 0x13 }, .{ 0x44, 0x31 },
};

fn writeAll(bus: I2c, address: u32, writes: []const Write) bool {
    for (writes) |w| {
        if (!bus.write(address, w[0], w[1])) return false;
    }
    return true;
}

/// The bridge brought up for `mode` on `lanes` lanes, its HDMI output on;
/// false at the first write it does not take.
pub fn setUp(bus: I2c, main: u32, lanes: u32, lane_mbps: u32, mode: Mode) bool {
    const dsi = main + 1;
    const avi = main + 2;
    if (!writeAll(bus, main, &digital_clocks)) return false;
    if (!writeAll(bus, main, &analog)) return false;

    // The DSI receiver: its test pattern off - the bridge has no reset
    // line, and keeps what it was last given through a reboot of the
    // chip - termination on, its settle time (128 ns, in the lane's byte
    // clocks: 0x10 at 1 Gbit/s), the lanes (0 means four), no lane swap,
    // the sync shifts.
    const settle: u8 = @intCast(@max(lane_mbps * 16 / 1000, 4));
    const receiver = [_]Write{ .{ 0x70, 0x00 }, .{ 0x10, 0x01 }, .{ 0x11, settle }, .{ 0x13, @intCast(lanes & 3) }, .{ 0x14, 0x00 }, .{ 0x15, 0x00 }, .{ 0x1A, 0x03 }, .{ 0x1B, 0x03 } };
    if (!writeAll(bus, dsi, &receiver)) return false;
    // The DDS started at the stream's own pixel clock, then let follow it.
    const word = ddsWord(mode.pixel_hz);
    if (!writeAll(bus, dsi, &.{ .{ 0x4E, @truncate(word) }, .{ 0x4F, @truncate(word >> 8) }, .{ 0x50, @truncate(word >> 16) }, .{ 0x51, 0x80 } })) return false;
    if (!writeAll(bus, dsi, &dds)) return false;
    if (!videoTimings(bus, dsi, mode)) return false;
    if (!infoframe(bus, main, avi, mode)) return false;

    if (!receiverReset(bus, main)) return false;
    // HDMI rather than DVI: infoframes are sent.
    if (!bus.write(main, 0xB2, 0x01)) return false;
    if (!writeAll(bus, avi, &audio)) return false;
    if (!writeAll(bus, main, &lvds)) return false;
    // The HDMI transmitter on.
    return bus.write(main, 0x33, 0x0E);
}

/// The timings the DSI receiver is to find in the stream.
fn videoTimings(bus: I2c, dsi: u32, mode: Mode) bool {
    const htotal = mode.hsync + mode.hbp + mode.width + mode.hfp;
    const vtotal = mode.vsync + mode.vbp + mode.height + mode.vfp;
    const writes = [_]Write{
        .{ 0x18, @truncate(mode.hsync) },    .{ 0x19, @truncate(mode.vsync) },
        .{ 0x1C, @truncate(mode.width) },    .{ 0x1D, @truncate(mode.width >> 8) },
        .{ 0x2F, 0x0C },                     .{ 0x34, @truncate(htotal) },
        .{ 0x35, @truncate(htotal >> 8) },   .{ 0x36, @truncate(vtotal) },
        .{ 0x37, @truncate(vtotal >> 8) },   .{ 0x38, @truncate(mode.vbp) },
        .{ 0x39, @truncate(mode.vbp >> 8) }, .{ 0x3A, @truncate(mode.vfp) },
        .{ 0x3B, @truncate(mode.vfp >> 8) }, .{ 0x3C, @truncate(mode.hbp) },
        .{ 0x3D, @truncate(mode.hbp >> 8) }, .{ 0x3E, @truncate(mode.hfp) },
        .{ 0x3F, @truncate(mode.hfp >> 8) },
    };
    return writeAll(bus, dsi, &writes);
}

/// The AVI infoframe: RGB, composed to be shown whole (underscanned), the
/// picture's aspect, IT content in full-range RGB - a computer's picture,
/// which a television may then show without cropping its edges or
/// treating it as video (one that takes the mode for a video format's
/// crops it all the same) - and no CEA video code: the clocks here are not
/// CEA's. The sync polarity goes on the main page.
fn infoframe(bus: I2c, main: u32, avi: u32, mode: Mode) bool {
    const aspect: u8 = if (mode.width * 3 == mode.height * 4) 1 else if (mode.width * 9 == mode.height * 16) 2 else 0;
    // PB1: RGB (0), active format given (bit 4), underscanned (2).
    const pb1: u8 = 0x10 | 0x02;
    // PB2: the picture's aspect, the active format the same (8).
    const pb2: u8 = (aspect << 4) | 0x08;
    // PB3: IT content (bit 7), full-range RGB (2 in bits 2-3).
    const pb3: u8 = 0x80 | (2 << 2);
    const vic: u8 = 0;
    // The checksum makes the header (0x82, version 2, 13 bytes) and the
    // bytes sum to zero.
    const sum: u32 = 0x82 + 0x02 + 0x0D + @as(u32, pb1) + pb2 + pb3 + vic;
    const pb0: u8 = @truncate((0x100 - (sum & 0xFF)) & 0xFF);
    const polarity: u8 = (if (mode.hsync_high) @as(u8, 2) else 0) | (if (mode.vsync_high) @as(u8, 1) else 0);
    if (!bus.write(avi, 0x3C, 0x41)) return false;
    if (!bus.write(main, 0xAB, polarity)) return false;
    return writeAll(bus, avi, &.{ .{ 0x43, pb0 }, .{ 0x44, pb1 }, .{ 0x45, pb2 }, .{ 0x46, pb3 }, .{ 0x47, vic } });
}

/// With the stream running: the DDS started again at `pixel_hz` and let
/// follow the stream, the DSI receiver and the DDS through a reset - after
/// two frames, so the receiver has a stream to find.
pub fn follow(bus: I2c, main: u32, pixel_hz: u32) bool {
    const dsi = main + 1;
    systimer.spinUs(40_000);
    const word = ddsWord(pixel_hz);
    if (!writeAll(bus, dsi, &.{ .{ 0x4E, @truncate(word) }, .{ 0x4F, @truncate(word >> 8) }, .{ 0x50, @truncate(word >> 16) }, .{ 0x51, 0x80 }, .{ 0x51, 0x00 } })) return false;
    return receiverReset(bus, main);
}

/// The DSI receiver's logic and the DDS through a reset.
fn receiverReset(bus: I2c, main: u32) bool {
    for ([_]Write{ .{ 0x03, 0x7F }, .{ 0x03, 0xFF }, .{ 0x05, 0xFB }, .{ 0x05, 0xFF } }, 0..) |w, i| {
        if (!bus.write(main, w[0], w[1])) return false;
        if (i % 2 == 0) systimer.spinUs(10_000);
    }
    return true;
}

/// Whether the bridge sees a monitor's hot-plug line.
pub fn hotPlug(bus: I2c, main: u32) bool {
    var value = [1]u8{0};
    return bus.read(main, 0xC1, &value) and value[0] & 0x80 != 0;
}

/// What the DSI receiver measures in the stream: the sync's period
/// counts, horizontal and vertical; 0 for a stream it does not see.
pub const Seen = struct { hsync: u16 = 0, vsync: u16 = 0 };

pub fn inputSeen(bus: I2c, main: u32) Seen {
    var bytes = [4]u8{ 0, 0, 0, 0 };
    if (!bus.read(main, 0x9C, &bytes)) return .{};
    return .{ .hsync = @as(u16, bytes[1]) << 8 | bytes[0], .vsync = @as(u16, bytes[3]) << 8 | bytes[2] };
}
