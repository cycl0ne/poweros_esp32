// SPDX-License-Identifier: MIT
//! SCSI: a disk unit asked what it is, with SCSI commands sent through
//! the device (HD_SCSICMD). Built against the SDK only.
//!
//!   SCSI UNIT/N,DEVICE/K
//!
//! UNIT (default 0) of DEVICE (default usb/disk.device, whose unit n is
//! `USB<n>:`) is sent INQUIRY - its type, whether its medium comes out,
//! its vendor and product - and TEST UNIT READY: ready, or the sense key
//! and codes the command ended with, which the device reads with
//! SCSIF_AUTOSENSE. A unit with nothing bound to it has no device behind
//! it to ask.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const scsidisk = sdk.devices.scsidisk;
const td = sdk.devices.trackdisk;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "SCSI";
const VERSION_STRING = "\x00$VER: SCSI 1.0 (12.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "UNIT/N,DEVICE/K";
const arg_unit = 0;
const arg_device = 1;

/// The device and its unit, a request on them, and what a command needs.
const Asker = struct {
    sys: *ExecBase,
    io: exec.IOStdReq = .{},
    cmd: scsidisk.SCSICmd = .{},
    sense: [18]u8 = @splat(0),

    /// `command` sent, its data phase into `into`: io_Error.
    fn ask(asker: *Asker, command: []const u8, into: ?[]u8) i8 {
        asker.cmd = .{
            .data = if (into) |bytes| bytes.ptr else null,
            .length = if (into) |bytes| @intCast(bytes.len) else 0,
            .command = command.ptr,
            .cmd_length = @intCast(command.len),
            .flags = scsidisk.SCSIF_READ | scsidisk.SCSIF_AUTOSENSE,
            .sense_data = &asker.sense,
            .sense_length = asker.sense.len,
        };
        asker.io.req.command = scsidisk.HD_SCSICMD;
        asker.io.data = &asker.cmd;
        asker.io.length = @sizeOf(scsidisk.SCSICmd);
        _ = asker.sys.DoIO(&asker.io.req);
        return asker.io.req.err;
    }
};

const device_types = [_][*:0]const u8{ "disk", "tape", "printer", "processor", "write-once", "CD/DVD", "scanner", "optical memory", "changer", "communications" };

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const unit: u32 = if (argv[arg_unit] != 0) @bitCast(@as(*const i32, @ptrFromInt(argv[arg_unit])).*) else 0;
    const device: [*:0]const u8 = if (argv[arg_device] != 0) @ptrFromInt(argv[arg_device]) else td.USBDISKNAME;

    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    var asker = Asker{ .sys = sys };
    asker.io.req.message.reply_port = port;
    asker.io.req.message.length = @sizeOf(exec.IOStdReq);
    if (sys.OpenDevice(device, unit, &asker.io.req, 0) != 0) {
        _ = Printf(dl, "%s: cannot open %s unit %u\n", .{ COMMAND_NAME, device, unit });
        return dos.RETURN_ERROR;
    }
    defer sys.CloseDevice(&asker.io.req);

    // INQUIRY, 36 bytes.
    var inquiry: [36]u8 = @splat(0);
    const inquiry_command = [_]u8{ 0x12, 0, 0, 0, inquiry.len, 0 };
    const asked = asker.ask(&inquiry_command, &inquiry);
    if (asked == td.TDERR_NoCard) {
        _ = Printf(dl, "%s unit %u: nothing in it\n", .{ device, unit });
        return dos.RETURN_WARN;
    }
    if (asked != 0) {
        _ = Printf(dl, "%s unit %u: INQUIRY failed (error %d, status %u)\n", .{ device, unit, @as(i32, asked), @as(u32, asker.cmd.status) });
        return dos.RETURN_WARN;
    }
    var vendor: [9]u8 = @splat(0);
    var product: [17]u8 = @splat(0);
    copyName(&vendor, inquiry[8..16]);
    copyName(&product, inquiry[16..32]);
    const kind = inquiry[0] & 0x1F;
    const kind_name: [*:0]const u8 = if (kind < device_types.len) device_types[kind] else "other";
    _ = Printf(dl, "%s unit %u: %s %s, %s%s\n", .{
        device,
        unit,
        @as([*:0]const u8, @ptrCast(&vendor)),
        @as([*:0]const u8, @ptrCast(&product)),
        kind_name,
        @as([*:0]const u8, if (inquiry[1] & 0x80 != 0) ", removable" else ""),
    });

    // TEST UNIT READY: no data, the sense read for us when it fails.
    const ready_command = [_]u8{ 0, 0, 0, 0, 0, 0 };
    if (asker.ask(&ready_command, null) == 0) {
        _ = Printf(dl, "ready\n", .{});
        return dos.RETURN_OK;
    }
    if (asker.cmd.sense_actual >= 14) {
        _ = Printf(dl, "not ready: sense key %x, code %x, qualifier %x\n", .{
            @as(u32, asker.sense[2] & 0x0F),
            @as(u32, asker.sense[12]),
            @as(u32, asker.sense[13]),
        });
    } else {
        _ = Printf(dl, "not ready (status %u)\n", .{@as(u32, asker.cmd.status)});
    }
    return dos.RETURN_WARN;
}

/// A name padded with spaces, without them.
fn copyName(into: []u8, name: []const u8) void {
    var end = name.len;
    while (end > 0 and (name[end - 1] == ' ' or name[end - 1] == 0)) end -= 1;
    var start: usize = 0;
    while (start < end and name[start] == ' ') start += 1;
    @memcpy(into[0 .. end - start], name[start..end]);
}
