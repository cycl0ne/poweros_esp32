// SPDX-License-Identifier: MPL-2.0
//! disk [read <offset> [bytes] | write <offset> <text> | erase <offset>
//! [sectors]]: flash.device's unit 0 - its geometry, or bytes of it read,
//! written or erased.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const uptime = @import("../../../../../arch/esp32s3/timer.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const trackdisk = sdk.devices.trackdisk;

/// The most `disk read` shows at once.
const dump_max = 512;

pub const name = "disk";
pub const usage = "disk [read <offset> [bytes] | write <offset> <text> | erase <offset> [sectors]]";
pub const help =
    \\  disk                 flash.device unit 0: its geometry
    \\  disk read <offset> [bytes]   dump the disk area (through its mapping)
    \\  disk write <offset> <text>   CMD_WRITE (the range must be erased)
    \\  disk erase <offset> [sectors]  TDCMD_ERASE, timed
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const sys = shell.base.iface();
    const io = try _shell.openDisk(shell);
    const word = args.next() orelse {
        var geometry: trackdisk.DriveGeometry = .{};
        const err = _shell.blockIO(shell, io, trackdisk.TD_GETGEOMETRY, 0, 0, &geometry);
        if (err != 0) {
            shell.print("TD_GETGEOMETRY: error %d\n", .{err});
            return;
        }
        shell.print("unit 0: %ld bytes, %ld sectors of %d\n", .{
            geometry.total_sectors * geometry.sector_size, geometry.total_sectors, geometry.sector_size,
        });
        shell.print("erase %d, write %d, mapped at 0x%08x\n", .{ geometry.erase_size, geometry.write_size, geometry.map_base });
        return;
    };

    if (_shell.same(word, "read")) {
        const offset = try args.number();
        const length = @min(try args.numberOr(64), dump_max);
        const buffer = sys.AllocMem(length, sdk.exec.MEMF_INTERNAL) orelse return error.OutOfMemory;
        defer sys.FreeMem(buffer, length);
        const err = _shell.blockIO(shell, io, sdk.exec.CMD_READ, offset, length, buffer);
        if (err != 0) {
            shell.print("CMD_READ: error %d\n", .{err});
            return;
        }
        const bytes: [*]const u8 = @ptrCast(buffer);
        _shell.dump(shell, bytes[0..length], offset);
        return;
    }

    if (_shell.same(word, "write")) {
        const offset = try args.number();
        const text = args.next() orelse return error.Usage;
        const err = _shell.blockIO(shell, io, sdk.exec.CMD_WRITE, offset, text.len, @ptrCast(@constCast(text.ptr)));
        if (err != 0) {
            shell.print("CMD_WRITE: error %d\n", .{err});
            return;
        }
        shell.print("wrote %ld bytes at %d\n", .{ io.actual, offset });
        return;
    }

    if (_shell.same(word, "erase")) {
        const offset = try args.number();
        const sectors = try args.numberOr(1);
        const length = @as(u64, sectors) * 4096;
        const start = uptime.now();
        const err = _shell.blockIO(shell, io, trackdisk.TDCMD_ERASE, offset, length, null);
        const took = uptime.now() - start;
        if (err != 0) {
            shell.print("TDCMD_ERASE: error %d\n", .{err});
            return;
        }
        shell.print("erased %ld bytes at %d in %ld us\n", .{ length, offset, took });
        return;
    }

    return error.Usage;
}
