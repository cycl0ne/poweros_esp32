// SPDX-License-Identifier: MPL-2.0
//! ser <unit|usb> query|break|params ...|read ...: serial.device's (usb:
//! usbserial.device's) own commands, on a request the shell opens for
//! them, shared as the console's is. OpenDevice fills in its fields with
//! the unit's parameters.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const uptime = @import("../../../../../arch/esp32s3/timer.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const serial = sdk.devices.serial;
const usbserial = sdk.devices.usbserial;

pub const name = "ser";
pub const usage = "ser <unit|usb> query|break|params <baud> [bits] [n|e|o] [stop] [buffer] [break-us]|read <length> [termchar]...";
pub const help =
    \\  ser <unit|usb> query  SDCMD_QUERY on serial.device's unit (usb: usbserial.device): bytes, io_Status, parameters
    \\  ser <unit|usb> params <baud> [bits] [n|e|o] [stop] [buffer] [break-us]  SDCMD_SETPARAMS
    \\  ser <unit|usb> break     SDCMD_BREAK: the line low for io_BrkTime (unit 0)
    \\  ser <unit|usb> read <length> [termchar]...  CMD_READ; termination characters (e.g. 13)
    \\                       set io_TermArray and EOF mode
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const sys = shell.base.iface();
    const which = args.next() orelse return error.Usage;
    const usb = _shell.same(which, "usb");
    const device: [*:0]const u8 = if (usb) usbserial.USBSERIALNAME else serial.SERIALNAME;
    const unit: u32 = if (usb) 0 else _shell.parseNumber(which) orelse return error.Usage;
    const what = args.next() orelse return error.Usage;
    var request: serial.IOExtSer = .{
        .io_ser = .{ .req = .{ .message = .{ .reply_port = shell.con_port, .length = @sizeOf(serial.IOExtSer) } } },
        .ser_flags = serial.SERF_SHARED,
    };
    const open_err = sys.OpenDevice(device, unit, &request.io_ser.req, 0);
    if (open_err != 0) {
        shell.print("OpenDevice %s unit %d: error %d\n", .{ device, unit, open_err });
        return;
    }
    defer sys.CloseDevice(&request.io_ser.req);
    if (_shell.same(what, "query")) {
        query(shell, &request);
    } else if (_shell.same(what, "break")) {
        request.io_ser.req.command = serial.SDCMD_BREAK;
        const start = uptime.uptimeUs();
        const err = sys.DoIO(&request.io_ser.req);
        shell.print("SDCMD_BREAK: error %d, after %ld us (io_BrkTime %d)\n", .{ err, uptime.uptimeUs() - start, request.brk_time });
    } else if (_shell.same(what, "params")) {
        try params(shell, &request, device, unit, args);
    } else if (_shell.same(what, "read")) {
        try read(shell, &request, device, unit, args);
    } else return error.Usage;
}

fn parityName(ser_flags: u8) [*:0]const u8 {
    if (ser_flags & serial.SERF_PARTY_ON == 0) return "none";
    return if (ser_flags & serial.SERF_PARTY_ODD != 0) "odd" else "even";
}

/// A status bit's name when it says the line is active: the modem lines
/// are active low, the rest active high.
fn active(status: u16, bit: u16, low: bool, word: [*:0]const u8) [*:0]const u8 {
    const set = status & bit != 0;
    return if (set != low) word else "";
}

/// SDCMD_QUERY, then the parameters the request shows.
fn query(shell: *Shell, request: *serial.IOExtSer) void {
    request.io_ser.req.command = serial.SDCMD_QUERY;
    const err = shell.base.iface().DoIO(&request.io_ser.req);
    const s = request.status;
    shell.print("SDCMD_QUERY: error %d, %ld bytes waiting, io_Status 0x%04x, active:%s%s%s%s%s%s%s%s%s%s\n", .{
        err,                                                         request.io_ser.actual,                                          s,
        active(s, serial.IO_STATF_DSR, true, " DSR"),                active(s, serial.IO_STATF_CTS, true, " CTS"),                   active(s, serial.IO_STATF_CD, true, " CD"),
        active(s, serial.IO_STATF_RTS, true, " RTS"),                active(s, serial.IO_STATF_DTR, true, " DTR"),                   active(s, serial.IO_STATF_OVERRUN, false, " overrun"),
        active(s, serial.IO_STATF_WROTEBREAK, false, " break-sent"), active(s, serial.IO_STATF_READBREAK, false, " break-received"), active(s, serial.IO_STATF_XOFFWRITE, false, " xoff-write"),
        active(s, serial.IO_STATF_XOFFREAD, false, " xoff-read"),
    });
    const xon: [*:0]const u8 = if (request.ser_flags & serial.SERF_XDISABLED != 0) "off" else "on";
    shell.print("%d baud, %d/%d bits, %d stop, parity %s, xON/xOFF %s (0x%08x), buffer %d, break %d us, io_SerFlags 0x%02x\n", .{
        request.baud,                  request.read_len,  request.write_len, request.stop_bits,
        parityName(request.ser_flags), xon,               request.ctl_char,  request.rbuf_len,
        request.brk_time,              request.ser_flags,
    });
}

/// A number of the command line that has to fit a byte.
fn byte(args: *Args) !u8 {
    const value = try args.number();
    if (value > 0xFF) return error.Usage;
    return @intCast(value);
}

/// ser <unit> params <baud> [bits] [n|e|o] [stop] [buffer] [break-us]:
/// SDCMD_SETPARAMS with the request's current parameters changed.
fn params(shell: *Shell, request: *serial.IOExtSer, device: [*:0]const u8, unit: u32, args: *Args) !void {
    request.baud = try args.number();
    if (args.peek() != null) {
        const bits = try byte(args);
        request.read_len = bits;
        request.write_len = bits;
    }
    if (args.next()) |parity| {
        request.ser_flags &= ~(serial.SERF_PARTY_ON | serial.SERF_PARTY_ODD);
        if (_shell.same(parity, "e")) {
            request.ser_flags |= serial.SERF_PARTY_ON;
        } else if (_shell.same(parity, "o")) {
            request.ser_flags |= serial.SERF_PARTY_ON | serial.SERF_PARTY_ODD;
        } else if (!_shell.same(parity, "n")) return error.Usage;
    }
    if (args.peek() != null) request.stop_bits = try byte(args);
    if (args.peek() != null) request.rbuf_len = try args.number();
    if (args.peek() != null) request.brk_time = try args.number();
    const paused = _shell.pauseConsole(shell, device, unit);
    request.io_ser.req.command = serial.SDCMD_SETPARAMS;
    const err = shell.base.iface().DoIO(&request.io_ser.req);
    _shell.resumeConsole(shell, paused);
    shell.print("SDCMD_SETPARAMS: error %d\n", .{err});
    if (err == 0) query(shell, request); // on an error, the request holds what was refused
}

/// ser <unit> read <length> [termchar]...: CMD_READ of up to 63 bytes. With
/// termination characters it sets io_TermArray first - descending, filled
/// out with the lowest, which is the order the device matches in - and
/// reads in EOF mode.
fn read(shell: *Shell, request: *serial.IOExtSer, device: [*:0]const u8, unit: u32, args: *Args) !void {
    const sys = shell.base.iface();
    var data: [64]u8 = undefined;
    const length = @min(try args.number(), data.len - 1);
    var terms: [8]u8 = undefined;
    var n: usize = 0;
    while (args.peek() != null) : (n += 1) {
        if (n == terms.len) return error.Usage;
        // Into place, highest first.
        const term = try byte(args);
        var at = n;
        while (at > 0 and terms[at - 1] < term) : (at -= 1) terms[at] = terms[at - 1];
        terms[at] = term;
    }
    const paused = _shell.pauseConsole(shell, device, unit);
    defer _shell.resumeConsole(shell, paused);
    if (n > 0) {
        for (terms[n..]) |*term| term.* = terms[n - 1];
        request.term_array = terms;
        request.io_ser.req.command = serial.SDCMD_SETPARAMS;
        const err = sys.DoIO(&request.io_ser.req);
        if (err != 0) {
            shell.print("SDCMD_SETPARAMS (io_TermArray): error %d\n", .{err});
            return;
        }
        request.ser_flags |= serial.SERF_EOFMODE;
    }
    const mode: [*:0]const u8 = if (n > 0) ", EOF mode" else "";
    shell.print("CMD_READ: up to %d bytes from unit %d%s\n", .{ length, unit, mode });
    request.io_ser.req.command = sdk.exec.CMD_READ;
    request.io_ser.data = &data;
    request.io_ser.length = @intCast(length);
    const err = sys.DoIO(&request.io_ser.req);
    const got: u32 = @intCast(request.io_ser.actual);
    for (data[0..got]) |*c| {
        if (c.* < 0x20 or c.* >= 0x7F) c.* = '.';
    }
    data[got] = 0;
    shell.print("CMD_READ: error %d, %d bytes: \"%s\"\n", .{ err, got, data[0..got :0] });
}
