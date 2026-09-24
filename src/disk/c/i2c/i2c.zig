// SPDX-License-Identifier: MIT
//! I2C: look at an I2C bus and talk to what is on it. Built against the
//! SDK only.
//!
//!   I2C UNIT/K/N,SCAN/S,ADDRESS=ADDR/K,READ/S,WRITE/S,REG/K,COUNT/K/N,
//!       DATA/M,SPEED/K/N,SCL/K/N,SDA/K/N
//!
//!   I2C                      the unit's pins and speed
//!   I2C SCAN                 every address on the bus, as a grid
//!   I2C ADDR 24 READ COUNT 4 four bytes from that slave
//!   I2C ADDR 24 REG 1 READ COUNT 2
//!                            register 1 of it: the register number is
//!                            written and the bytes read back without
//!                            letting go of the bus
//!   I2C ADDR 24 WRITE 01 FF  two bytes to it
//!   I2C SPEED 100000 SCL 9 SDA 8
//!                            the unit's parameters
//!
//! Addresses, register numbers and data bytes are hexadecimal, because
//! that is how every data sheet writes them; a leading 0x or $ is allowed
//! and makes no difference. COUNT, SPEED, SCL, SDA and UNIT are decimal.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const i2c = sdk.devices.i2c;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "I2C";
const VERSION_STRING = "\x00$VER: I2C 1.0 (16.9.2026)\r\n";

// UNIT is a keyword, not a position: DATA/M takes the bare words on the
// line, and a positional UNIT would take the first of them instead.
const template =
    "UNIT/K/N,SCAN/S,ADDRESS=ADDR/K,READ/S,WRITE/S,REG/K,COUNT/K/N," ++
    "DATA/M,SPEED/K/N,SCL/K/N,SDA/K/N";
const arg_unit = 0;
const arg_scan = 1;
const arg_address = 2;
const arg_read = 3;
const arg_write = 4;
const arg_reg = 5;
const arg_count = 6;
const arg_data = 7;
const arg_speed = 8;
const arg_scl = 9;
const arg_sda = 10;

/// The addresses a scan walks. Below 8 and above 0x77 the bus reserves
/// them for its own framing, and a slave may not answer there.
const first_address: u16 = 0x08;
const last_address: u16 = 0x77;

/// The most bytes one READ or WRITE moves. A command line is not where a
/// long transfer belongs.
const max_bytes: u32 = 256;

const MSG_NODEVICE = "%s unit %d: no such device or unit\n";
const MSG_NOADDR = "an address is needed: ADDR <hex>\n";
const MSG_BADHEX = "%s is not a hexadecimal number\n";
const MSG_RANGE = "%s is not an address between 00 and 7F\n";
const MSG_ONEOF = "only one of SCAN, READ or WRITE allowed\n";
const MSG_NODATA = "WRITE needs bytes to write\n";
const MSG_TOOMANY = "at most %d bytes at a time\n";

const Run = struct {
    sys: *ExecBase,
    dl: *DosBase,
    io: *i2c.IOExtI2C,
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [11]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    var asked: u32 = 0;
    if (argv[arg_scan] != 0) asked += 1;
    if (argv[arg_read] != 0) asked += 1;
    if (argv[arg_write] != 0) asked += 1;
    if (asked > 1) {
        _ = dl.PutStr(MSG_ONEOF);
        return dos.RETURN_ERROR;
    }

    const unit: u32 = if (argv[arg_unit] != 0) @intCast(numberAt(argv[arg_unit])) else 0;

    const port = sys.CreateMsgPort() orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.DeleteMsgPort(port);
    const request = sys.CreateIORequest(port, @sizeOf(i2c.IOExtI2C)) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.DeleteIORequest(request);
    const io: *i2c.IOExtI2C = @ptrCast(@alignCast(request));

    if (sys.OpenDevice(i2c.DEVICE_NAME, unit, request, 0) != 0) {
        _ = Printf(dl, MSG_NODEVICE, .{ i2c.DEVICE_NAME, unit });
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(request);

    var run: Run = .{ .sys = sys, .dl = dl, .io = io };

    // Parameters first: a line may set the bus up and then use it.
    if (argv[arg_speed] != 0 or argv[arg_scl] != 0 or argv[arg_sda] != 0) {
        const rc = setParams(&run, &argv);
        if (rc != dos.RETURN_OK) return rc;
    }

    if (argv[arg_scan] != 0) return scan(&run, unit);
    if (argv[arg_read] != 0 or argv[arg_write] != 0) return transfer(&run, &argv);
    return showParams(&run, unit);
}

// --- the unit -------------------------------------------------------------

fn command(run: *Run, code: u16) i8 {
    run.io.req.req.command = code;
    run.io.req.req.err = 0;
    _ = run.sys.DoIO(&run.io.req.req);
    return run.io.req.req.err;
}

fn showParams(run: *Run, unit: u32) i32 {
    const dl = run.dl;
    run.io.speed = 0;
    run.io.scl_pin = 0;
    run.io.sda_pin = 0;
    if (command(run, i2c.I2CCMD_GETPARAMS) != 0) {
        _ = Printf(dl, MSG_NODEVICE, .{ i2c.DEVICE_NAME, unit });
        return dos.RETURN_FAIL;
    }
    _ = Printf(dl, "Unit %d\n", .{unit});
    if (run.io.scl_pin == i2c.PIN_KEEP or run.io.sda_pin == i2c.PIN_KEEP) {
        _ = dl.PutStr("  pins     none yet - set them with SCL and SDA\n");
    } else {
        _ = Printf(dl, "  pins     SCL on GPIO %d, SDA on GPIO %d\n", .{ run.io.scl_pin, run.io.sda_pin });
    }
    _ = Printf(dl, "  speed    %d Hz\n", .{run.io.speed});
    return dos.RETURN_OK;
}

fn setParams(run: *Run, argv: *const [11]usize) i32 {
    const dl = run.dl;
    run.io.speed = if (argv[arg_speed] != 0) @intCast(numberAt(argv[arg_speed])) else 0;
    run.io.scl_pin = if (argv[arg_scl] != 0) @intCast(numberAt(argv[arg_scl]) & 0xFF) else i2c.PIN_KEEP;
    run.io.sda_pin = if (argv[arg_sda] != 0) @intCast(numberAt(argv[arg_sda]) & 0xFF) else i2c.PIN_KEEP;
    const err = command(run, i2c.I2CCMD_SETPARAMS);
    if (err != 0) {
        _ = Printf(dl, "the unit will not take those parameters (%s)\n", .{errorText(err)});
        return dos.RETURN_ERROR;
    }
    return dos.RETURN_OK;
}

// --- the scan -------------------------------------------------------------

/// Every address on the bus, laid out the way a data sheet numbers them:
/// the row is the high nibble, the column the low one. A dot is silence,
/// the address itself is an answer, and "--" is an address the bus keeps
/// for its own framing.
fn scan(run: *Run, unit: u32) i32 {
    const dl = run.dl;
    // A unit with no pins would answer every address the same way, which
    // is a grid of a hundred identical failures and no information.
    run.io.scl_pin = 0;
    run.io.sda_pin = 0;
    if (command(run, i2c.I2CCMD_GETPARAMS) == 0 and
        (run.io.scl_pin == i2c.PIN_KEEP or run.io.sda_pin == i2c.PIN_KEEP))
    {
        _ = Printf(dl, "Unit %d has no pins yet - set them with SCL and SDA\n", .{unit});
        return dos.RETURN_ERROR;
    }
    _ = Printf(dl, "Scanning i2c.device unit %d\n\n", .{unit});
    _ = dl.PutStr("     0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f\n");

    var found: u32 = 0;
    var row: u16 = 0;
    while (row < 8) : (row += 1) {
        _ = Printf(dl, "%02x: ", .{row << 4});
        var col: u16 = 0;
        while (col < 16) : (col += 1) {
            if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
                _ = dl.PutStr("\n");
                _ = dl.PrintFault(dos.ERROR_BREAK, null);
                return dos.RETURN_WARN;
            }
            const addr = (row << 4) | col;
            if (addr < first_address or addr > last_address) {
                _ = dl.PutStr(" --");
                continue;
            }
            run.io.address = addr;
            run.io.req.length = 0;
            run.io.req.data = null;
            const err = command(run, i2c.I2CCMD_PROBE);
            if (err != 0) {
                _ = dl.PutStr("  ?"); // the bus itself is in trouble
            } else if (run.io.req.actual != 0) {
                _ = Printf(dl, " %02x", .{addr});
                found += 1;
            } else {
                _ = dl.PutStr("  .");
            }
        }
        _ = dl.PutStr("\n");
    }
    if (found == 1) {
        _ = dl.PutStr("\n1 device answered.\n");
    } else {
        _ = Printf(dl, "\n%d devices answered.\n", .{found});
    }
    return dos.RETURN_OK;
}

// --- reading and writing --------------------------------------------------

fn transfer(run: *Run, argv: *const [11]usize) i32 {
    const dl = run.dl;
    if (argv[arg_address] == 0) {
        _ = dl.PutStr(MSG_NOADDR);
        return dos.RETURN_ERROR;
    }
    const text = stringAt(argv[arg_address]);
    const addr = parseHex(text) orelse {
        _ = Printf(dl, MSG_BADHEX, .{text});
        return dos.RETURN_ERROR;
    };
    if (addr > 0x7F) {
        _ = Printf(dl, MSG_RANGE, .{text});
        return dos.RETURN_ERROR;
    }

    var out: [max_bytes]u8 = undefined;
    var in: [max_bytes]u8 = undefined;
    var out_len: u32 = 0;

    // A register number goes out ahead of whatever follows.
    if (argv[arg_reg] != 0) {
        const rtext = stringAt(argv[arg_reg]);
        const r = parseHex(rtext) orelse {
            _ = Printf(dl, MSG_BADHEX, .{rtext});
            return dos.RETURN_ERROR;
        };
        if (r > 0xFF) {
            _ = Printf(dl, MSG_BADHEX, .{rtext});
            return dos.RETURN_ERROR;
        }
        out[0] = @intCast(r);
        out_len = 1;
    }

    if (argv[arg_write] != 0) {
        if (argv[arg_data] == 0) {
            _ = dl.PutStr(MSG_NODATA);
            return dos.RETURN_ERROR;
        }
        const words: [*]const ?[*:0]const u8 = @ptrFromInt(argv[arg_data]);
        var i: usize = 0;
        while (words[i]) |word| : (i += 1) {
            if (out_len >= max_bytes) {
                _ = Printf(dl, MSG_TOOMANY, .{max_bytes});
                return dos.RETURN_ERROR;
            }
            const b = parseHex(word) orelse {
                _ = Printf(dl, MSG_BADHEX, .{word});
                return dos.RETURN_ERROR;
            };
            if (b > 0xFF) {
                _ = Printf(dl, MSG_BADHEX, .{word});
                return dos.RETURN_ERROR;
            }
            out[out_len] = @intCast(b);
            out_len += 1;
        }
        run.io.address = @intCast(addr);
        run.io.req.data = &out;
        run.io.req.length = out_len;
        const err = command(run, exec.CMD_WRITE);
        if (err != 0) return failed(run, addr, err);
        _ = Printf(dl, "%d bytes written to %02x\n", .{ out_len, addr });
        return dos.RETURN_OK;
    }

    // READ
    var count: u32 = if (argv[arg_count] != 0) @intCast(numberAt(argv[arg_count])) else 1;
    if (count == 0) count = 1;
    if (count > max_bytes) {
        _ = Printf(dl, MSG_TOOMANY, .{max_bytes});
        return dos.RETURN_ERROR;
    }
    run.io.address = @intCast(addr);
    run.io.req.data = &in;
    run.io.req.length = count;
    var err: i8 = 0;
    if (out_len != 0) {
        // The register number and the read in one request, so nothing else
        // can take the bus between them.
        run.io.wr_data = &out;
        run.io.wr_length = out_len;
        err = command(run, i2c.I2CCMD_WRITEREAD);
    } else {
        err = command(run, exec.CMD_READ);
    }
    if (err != 0) return failed(run, addr, err);

    const got: u32 = @intCast(run.io.req.actual);
    dump(run, if (out_len != 0) out[0] else 0, out_len != 0, in[0..got]);
    return dos.RETURN_OK;
}

/// The bytes, sixteen to a line, hexadecimal with the printable ones
/// beside them - what a register dump is read as.
fn dump(run: *Run, base: u8, has_base: bool, bytes: []const u8) void {
    const dl = run.dl;
    var at: usize = 0;
    while (at < bytes.len) : (at += 16) {
        const end = @min(at + 16, bytes.len);
        if (has_base) {
            _ = Printf(dl, "%02x: ", .{@as(u32, base) + at});
        } else {
            _ = Printf(dl, "%04x: ", .{at});
        }
        var i = at;
        while (i < at + 16) : (i += 1) {
            if (i < end) _ = Printf(dl, "%02x ", .{bytes[i]}) else _ = dl.PutStr("   ");
        }
        _ = dl.PutStr(" ");
        i = at;
        while (i < end) : (i += 1) {
            const c = bytes[i];
            _ = Printf(dl, "%c", .{if (c >= 0x20 and c < 0x7F) c else @as(u8, '.')});
        }
        _ = dl.PutStr("\n");
    }
}

fn failed(run: *Run, addr: u32, err: i8) i32 {
    _ = Printf(run.dl, "%02x: %s\n", .{ addr, errorText(err) });
    return dos.RETURN_ERROR;
}

fn errorText(err: i8) [*:0]const u8 {
    return switch (err) {
        i2c.I2CErr_NoAck => "nothing answered",
        i2c.I2CErr_ArbLost => "another master had the bus",
        i2c.I2CErr_Timeout => "the slave held the clock down too long",
        i2c.I2CErr_BusBusy => "the bus is busy",
        i2c.I2CErr_InvParam => "the unit has no pins, or the parameters are impossible",
        exec.IOERR_UNITBUSY => "the unit is busy",
        exec.IOERR_ABORTED => "stopped",
        exec.IOERR_NOCMD => "the device does not know that command",
        else => "the transfer failed",
    };
}

// --- the argument slots ---------------------------------------------------

/// A /N slot: ReadArgs leaves a pointer to the number.
fn numberAt(slot: usize) i32 {
    const p: *const i32 = @ptrFromInt(slot);
    return p.*;
}

fn stringAt(slot: usize) [*:0]const u8 {
    return @ptrFromInt(slot);
}

/// A hexadecimal number, with an optional 0x or $ in front. Null if it is
/// not one, or if it does not fit.
fn parseHex(text: [*:0]const u8) ?u32 {
    var i: usize = 0;
    if (text[0] == '$') {
        i = 1;
    } else if (text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        i = 2;
    }
    if (text[i] == 0) return null;
    var value: u32 = 0;
    while (text[i] != 0) : (i += 1) {
        const digit: u32 = switch (text[i]) {
            '0'...'9' => text[i] - '0',
            'a'...'f' => text[i] - 'a' + 10,
            'A'...'F' => text[i] - 'A' + 10,
            else => return null,
        };
        if (value > (0xFFFF_FFFF - digit) / 16) return null;
        value = value * 16 + digit;
    }
    return value;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
