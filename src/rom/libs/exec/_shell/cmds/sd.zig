// SPDX-License-Identifier: MPL-2.0
//! sd [read <block> [blocks] | write <block> <text>]: the card in the
//! slot, through sd.device's unit 0 - whether one is in, how big it is and
//! how often it has been changed, or blocks of it read or written. The
//! card's maker and name are printed by the device itself when it
//! identifies one.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const trackdisk = sdk.devices.trackdisk;

/// A card block, which is what a read and a write are counted in.
const block_size = 512;

pub const name = "sd";
pub const usage = "sd [read <block> [blocks] | write <block> <text>]";
pub const help =
    \\  sd                   sd.device unit 0: whether a card is in, how big,
    \\                       and how often it has been changed
    \\  sd read <block> [blocks]     blocks read; the first one dumped
    \\  sd write <block> <text>      one block written, the rest of it zeroed
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const sys = shell.base.iface();
    const io = try _shell.openBlockDevice(shell, &shell.sd_port, &shell.sd_req, trackdisk.SDNAME);
    const word = args.next() orelse {
        _ = _shell.blockIO(shell, io, trackdisk.TD_CHANGESTATE, 0, 0, null);
        const in = io.actual == 0;
        _ = _shell.blockIO(shell, io, trackdisk.TD_CHANGENUM, 0, 0, null);
        const changes = io.actual;
        if (!in) {
            shell.print("no card in the slot (%ld changes)\n", .{changes});
            return;
        }
        var geometry: trackdisk.DriveGeometry = .{};
        const err = _shell.blockIO(shell, io, trackdisk.TD_GETGEOMETRY, 0, 0, &geometry);
        if (err != 0) {
            shell.print("TD_GETGEOMETRY: error %d\n", .{err});
            return;
        }
        _ = _shell.blockIO(shell, io, trackdisk.TD_PROTSTATUS, 0, 0, null);
        shell.print("card: %ld bytes, %ld blocks of %d\n", .{
            geometry.total_sectors * geometry.sector_size, geometry.total_sectors, geometry.sector_size,
        });
        const protection: [*:0]const u8 = if (io.actual != 0) "write-protected" else "writable";
        shell.print("%s, %ld changes\n", .{ protection, changes });
        return;
    };

    if (_shell.same(word, "read")) {
        const block = try args.number();
        const blocks = try args.numberOr(1);
        const length: u32 = blocks * block_size;
        const buffer = sys.AllocMem(length, sdk.exec.MEMF_INTERNAL) orelse return error.OutOfMemory;
        defer sys.FreeMem(buffer, length);
        const err = _shell.blockIO(shell, io, sdk.exec.CMD_READ, @as(u64, block) * block_size, length, buffer);
        if (err != 0) {
            shell.print("CMD_READ: error %d\n", .{err});
            return;
        }
        // Only the first block is shown: a run is read to prove the
        // multi-block command works, not to fill the screen.
        const bytes: [*]const u8 = @ptrCast(buffer);
        _shell.dump(shell, bytes[0..block_size], 0);
        shell.print("%ld blocks read\n", .{io.actual / block_size});
        return;
    }

    if (_shell.same(word, "write")) {
        const block = try args.number();
        const text = args.next() orelse return error.Usage;
        // A card is written a whole block at a time, so the text goes
        // into one and the rest of it is zeroed.
        const buffer = sys.AllocMem(block_size, sdk.exec.MEMF_INTERNAL | sdk.exec.MEMF_CLEAR) orelse
            return error.OutOfMemory;
        defer sys.FreeMem(buffer, block_size);
        const bytes: [*]u8 = @ptrCast(buffer);
        const put = @min(text.len, block_size);
        @memcpy(bytes[0..put], text[0..put]);
        const err = _shell.blockIO(shell, io, sdk.exec.CMD_WRITE, @as(u64, block) * block_size, block_size, buffer);
        if (err != 0) {
            shell.print("CMD_WRITE: error %d\n", .{err});
            return;
        }
        shell.print("block %d written\n", .{block});
        return;
    }

    return error.Usage;
}
