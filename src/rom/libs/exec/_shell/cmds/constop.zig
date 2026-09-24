// SPDX-License-Identifier: MPL-2.0
//! constop <ms>: CMD_STOP on the console's units for `ms`, then
//! CMD_START, with copies of the shell's write requests. A write sent
//! while a unit is stopped must wait for CMD_START. The shell prints
//! nothing meanwhile: its own writes would wait too, with nobody left to
//! send CMD_START.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const serial = sdk.devices.serial;

pub const name = "constop";
pub const usage = "constop <ms>";
pub const help =
    \\  constop <ms>         CMD_STOP the console (serial.device 0, usbserial.device) for <ms>, then CMD_START;
    \\                       a write sent meanwhile waits for CMD_START
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const sys = shell.base.iface();
    const ms = try args.number();
    const text = "(written while stopped, out after CMD_START)\r\n";
    var control: [shell.con_units.len]serial.IOExtSer = undefined;
    var held: [shell.con_units.len]serial.IOExtSer = undefined;
    var stop_err: i32 = 0;
    var waited = true;
    for (&shell.con_units, &control, &held) |*unit, *stop, *write| {
        if (!unit.open) continue;
        stop.* = unit.write;
        stop.io_ser.req.command = sdk.exec.CMD_STOP;
        stop_err |= sys.DoIO(&stop.io_ser.req);
        write.* = unit.write;
        write.io_ser.req.command = sdk.exec.CMD_WRITE;
        write.io_ser.data = @constCast(text.ptr);
        write.io_ser.length = text.len;
        sys.SendIO(&write.io_ser.req);
        waited = waited and sys.CheckIO(&write.io_ser.req) == null;
    }
    _shell.sleepMs(shell, ms);
    var start_err: i32 = 0;
    var held_err: i32 = 0;
    var actual: u64 = 0;
    for (&shell.con_units, &control, &held) |*unit, *start, *write| {
        if (!unit.open) continue;
        start.io_ser.req.command = sdk.exec.CMD_START;
        start_err |= sys.DoIO(&start.io_ser.req);
        held_err |= sys.WaitIO(&write.io_ser.req);
        actual = write.io_ser.actual;
    }
    const verdict: [*:0]const u8 = if (waited) "waited" else "did NOT wait";
    shell.print("CMD_STOP: error %d; the writes %s; CMD_START: error %d, the writes: error %d, actual %ld\n", .{
        stop_err, verdict, start_err, held_err, actual,
    });
}
