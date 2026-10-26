// SPDX-License-Identifier: MPL-2.0
//! dma [copy <bytes> [<channel>]]: dma.resource's channels and who holds
//! them, or a memory-to-memory copy through it.
//!
//! The copy runs on the channel named, or the first free general one, at
//! the highest priority: two chains from AllocDMAChain (OUT over the
//! source, IN over the destination), the IN side's interrupt through an
//! exec server, a timer.device request of a second as the timeout. The
//! buffers are whole cache lines, written back before and invalidated
//! after where the data cache covers internal memory, and so is the IN
//! chain before its descriptors are read.
//!
//! A chip whose only channels for memory are a PL080's (the JH7110's
//! security block) copies on one of those instead: a list from
//! `sdk.hardware.pl080` in memory below 4 GiB, the channel watched until
//! it turns itself off, for a second at the most.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const uptime = @import("../../../../../arch/arch.zig").timer;
const Shell = _shell.Shell;
const Args = _shell.Args;
const dmares = sdk.resources.dma;
const timer = sdk.devices.timer;

/// The most `dma copy` moves: two internal-memory buffers of it.
const max_copy = 0x10000;

pub const name = "dma";
pub const usage = "dma [copy <bytes> [<channel>]]";
pub const help =
    \\  dma                  dma.resource's channels and their owners
    \\  dma copy <bytes> [<channel>]
    \\                       a memory-to-memory DMA copy (1-65536 bytes) through dma.resource
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const db: *dmares.DmaBase = @ptrCast(shell.base.iface().OpenResource(dmares.DMANAME) orelse {
        shell.print("no %s\n", .{dmares.DMANAME});
        return;
    });
    const word = args.next() orelse {
        shell.print("channel  owner\n", .{});
        var channel: u32 = 0;
        while (channel < dmares.DMA_ALL_CHANNELS) : (channel += 1) {
            const owner: [*:0]const u8 = db.DMAChannelOwner(channel) orelse "-";
            if (channel < dmares.DMA2D_CHANNEL0) {
                shell.print("%7d  %s\n", .{ channel, owner });
            } else if (channel < dmares.DWDMA_CHANNEL0) {
                shell.print("%7d  %s (2D-DMA %d)\n", .{ channel, owner, channel - dmares.DMA2D_CHANNEL0 });
            } else if (channel < dmares.PL080_CHANNEL0) {
                shell.print("%7d  %s (DesignWare DMA %d)\n", .{ channel, owner, channel - dmares.DWDMA_CHANNEL0 });
            } else {
                shell.print("%7d  %s (PL080 %d)\n", .{ channel, owner, channel - dmares.PL080_CHANNEL0 });
            }
        }
        return;
    };
    if (!_shell.same(word, "copy")) return error.Usage;
    const bytes = try args.number();
    if (bytes == 0 or bytes > max_copy) return error.Usage;
    const wanted: ?u32 = if (args.peek() != null) try args.number() else null;
    if (comptime pl_copies) {
        if (wanted) |channel| if (channel < dmares.PL080_CHANNEL0 or channel >= dmares.DMA_ALL_CHANNELS) return error.Usage;
        try plCopy(shell, db, bytes, wanted);
    } else {
        if (wanted) |channel| if (channel >= dmares.DMA_CHANNELS) return error.Usage;
        try copy(shell, db, bytes, wanted);
    }
}

/// Whether the copy runs on a PL080 channel: the chip has no general ones.
const pl_copies = dmares.DMA_CHANNELS == 0 and dmares.PL080_CHANNELS != 0;

/// What the copy's interrupt server works with.
const Copy = struct {
    shell: *Shell,
    db: *dmares.DmaBase,
    channel: u32,
    task: *sdk.exec.Task,
    signals: u32,
    status: u32 = 0,
};

/// The IN side's interrupt: clear it, note it, wake the shell.
fn copyServer(data: ?*anyopaque, _: u32) callconv(.c) i32 {
    const state: *Copy = @ptrCast(@alignCast(data.?));
    const status = state.db.DMAIntStatus(state.channel, dmares.DMA_IN);
    if (status == 0) return 0;
    state.db.ClearDMAInts(state.channel, dmares.DMA_IN, status);
    state.status |= status;
    state.shell.base.iface().Signal(state.task, state.signals);
    return 1;
}

/// A cache line, and room for a buffer of up to `max_copy` bytes in
/// whole ones.
const line = sdk.hardware.DCACHE_LINE_SIZE;
const room = max_copy + 2 * line;

fn copy(shell: *Shell, db: *dmares.DmaBase, bytes: u32, wanted: ?u32) !void {
    const sys = shell.base.iface();
    var channel: u32 = wanted orelse 0;
    if (wanted != null) {
        if (db.AllocDMAChannel(channel, "shell")) |owner| {
            shell.print("channel %d is %s's\n", .{ channel, owner });
            return;
        }
    } else while (channel < dmares.DMA_CHANNELS) : (channel += 1) {
        if (db.AllocDMAChannel(channel, "shell") == null) break;
    } else {
        shell.print("all DMA channels are taken\n", .{});
        return;
    }
    defer db.FreeDMAChannel(channel);
    if (!db.ConnectDMAChannel(channel, dmares.DMAPERI_MEMORY, 0)) {
        shell.print("ConnectDMAChannel %d failed\n", .{channel});
        return;
    }
    if (!db.SetDMAPriority(channel, dmares.DMA_IN, dmares.DMA_MAXPRI) or !db.SetDMAPriority(channel, dmares.DMA_OUT, dmares.DMA_MAXPRI)) {
        shell.print("SetDMAPriority failed\n", .{});
        return;
    }

    // Buffers in internal memory, which the DMA addresses directly, on
    // whole cache lines.
    const source_room = sys.AllocMem(room, sdk.exec.MEMF_INTERNAL) orelse return error.OutOfMemory;
    defer sys.FreeMem(source_room, room);
    const destination_room = sys.AllocMem(room, sdk.exec.MEMF_INTERNAL | sdk.exec.MEMF_CLEAR) orelse return error.OutOfMemory;
    defer sys.FreeMem(destination_room, room);
    const source: [*]u8 = @ptrFromInt(lineUp(@intFromPtr(source_room)));
    const destination: [*]u8 = @ptrFromInt(lineUp(@intFromPtr(destination_room)));
    for (source[0..bytes], 0..) |*b, i| b.* = @truncate(i *% 7 +% 1);
    var cached: u32 = bytes;
    _ = sys.CachePreDMA(source, &cached, sdk.exec.DMAF_ReadFromRAM);
    cached = bytes;
    _ = sys.CachePreDMA(destination, &cached, 0);
    const out_chain = db.AllocDMAChain(dmares.DMA_OUT, source, bytes, 0) orelse {
        shell.print("AllocDMAChain failed\n", .{});
        return;
    };
    defer db.FreeDMAChain(out_chain);
    const in_chain = db.AllocDMAChain(dmares.DMA_IN, destination, bytes, 0) orelse {
        shell.print("AllocDMAChain failed\n", .{});
        return;
    };
    defer db.FreeDMAChain(in_chain);

    const bit = sys.AllocSignal(-1);
    if (bit < 0) return error.NoSignal;
    defer sys.FreeSignal(bit);
    var state: Copy = .{ .shell = shell, .db = db, .channel = channel, .task = sys.FindTask(null).?, .signals = @as(u32, 1) << @intCast(bit) };
    var server: sdk.exec.Interrupt = .{
        .node = .{ .type = .interrupt, .name = "dma copy" },
        .data = &state,
        .code = sdk.exec.vec(copyServer),
    };
    const int_number = dmares.dmaIntNumber(channel, dmares.DMA_IN);
    sys.AddIntServer(int_number, &server);
    defer sys.RemIntServer(int_number, &server);
    db.EnableDMAInts(channel, dmares.DMA_IN, dmares.DMAINTF_IN_SUC_EOF | dmares.DMAINTF_IN_DSCR_ERR | dmares.DMAINTF_IN_DSCR_EMPTY);
    defer db.EnableDMAInts(channel, dmares.DMA_IN, 0);

    const req = try _shell.openTimer(shell, timer.UNIT_MICROHZ);
    defer _shell.closeTimer(shell, req);
    req.node.command = timer.TR_ADDREQUEST;
    req.time = timer.TimeVal.fromMicros(1_000_000);
    sys.SendIO(&req.node);
    const start = uptime.uptimeUs();
    const started = db.StartDMA(channel, dmares.DMA_IN, in_chain) and db.StartDMA(channel, dmares.DMA_OUT, out_chain);
    if (started) _ = sys.Wait(state.signals | req.node.message.reply_port.?.sigMask());
    const us = uptime.uptimeUs() - start;
    _ = sys.AbortIO(&req.node);
    _ = sys.WaitIO(&req.node);

    const status = @as(*volatile u32, &state.status).*;
    if (!started) {
        shell.print("StartDMA refused the chains\n", .{});
    } else if (status & dmares.DMAINTF_IN_SUC_EOF == 0) {
        db.StopDMA(channel, dmares.DMA_OUT);
        db.StopDMA(channel, dmares.DMA_IN);
        shell.print("channel %d: no end of frame after %ld us (status 0x%02x)\n", .{ channel, us, status });
    } else {
        cached = bytes;
        sys.CachePostDMA(destination, &cached, 0);
        // What IN received, and whether its frame ended on its last
        // descriptor: the chain as the DMA wrote it back.
        var links_bytes: u32 = (bytes + dmares.DMA_CHUNK - 1) / dmares.DMA_CHUNK * @sizeOf(dmares.DMADescriptor);
        sys.CachePostDMA(in_chain, &links_bytes, 0);
        var received: u32 = 0;
        var links: u32 = 0;
        var last: *dmares.DMADescriptor = in_chain;
        var descriptor: ?*dmares.DMADescriptor = in_chain;
        while (descriptor) |d| {
            received += d.received();
            links += 1;
            last = d;
            descriptor = d.next;
        }
        const at_last = if (db.DMAEOFDescriptor(channel, dmares.DMA_IN)) |eof| eof == last else false;
        const verdict: [*:0]const u8 = if (_shell.same(source[0..bytes], destination[0..bytes])) "copied" else "MISMATCH";
        const eof_text: [*:0]const u8 = if (at_last) "its last" else "NOT its last";
        shell.print("channel %d: %d bytes %s, %d received in %d descriptors, EOF at %s, status 0x%02x, %ld us\n", .{ channel, bytes, verdict, received, links, eof_text, status, us });
    }
}

fn lineUp(address: usize) usize {
    return (address + line - 1) & ~@as(usize, line - 1);
}

/// The items of a PL080 copy of up to `max_copy` bytes, a byte at a time
/// where its length is not whole words.
const pl_items = if (pl_copies) sdk.hardware.pl080.itemsFor(max_copy, .byte) else 0;

fn plCopy(shell: *Shell, db: *dmares.DmaBase, bytes: u32, wanted: ?u32) !void {
    const pl080 = sdk.hardware.pl080;
    const sys = shell.base.iface();
    const controller = pl080.find() orelse {
        shell.print("the board has no PL080\n", .{});
        return;
    };
    var channel: u32 = wanted orelse dmares.PL080_CHANNEL0;
    if (wanted != null) {
        if (db.AllocDMAChannel(channel, "shell")) |owner| {
            shell.print("channel %d is %s's\n", .{ channel, owner });
            return;
        }
    } else while (channel < dmares.DMA_ALL_CHANNELS) : (channel += 1) {
        if (db.AllocDMAChannel(channel, "shell") == null) break;
    } else {
        shell.print("all PL080 channels are taken\n", .{});
        return;
    }
    defer db.FreeDMAChannel(channel);
    const unit = channel - dmares.PL080_CHANNEL0;

    // Buffers and the list below 4 GiB, on whole cache lines.
    const source_room = sys.AllocMem(room, sdk.exec.MEMF_DMA) orelse return error.OutOfMemory;
    defer sys.FreeMem(source_room, room);
    const destination_room = sys.AllocMem(room, sdk.exec.MEMF_DMA | sdk.exec.MEMF_CLEAR) orelse return error.OutOfMemory;
    defer sys.FreeMem(destination_room, room);
    const list_room: u32 = pl_items * @sizeOf(pl080.Item) + line;
    const list_block = sys.AllocMem(list_room, sdk.exec.MEMF_DMA) orelse return error.OutOfMemory;
    defer sys.FreeMem(list_block, list_room);
    const source: [*]u8 = @ptrFromInt(lineUp(@intFromPtr(source_room)));
    const destination: [*]u8 = @ptrFromInt(lineUp(@intFromPtr(destination_room)));
    const items: [*]pl080.Item = @ptrFromInt(lineUp(@intFromPtr(list_block)));
    for (source[0..bytes], 0..) |*b, i| b.* = @truncate(i *% 7 +% 1);

    const width: pl080.Width = if (bytes % 4 == 0) .word else .byte;
    const count = pl080.fill(items[0..pl_items], .{ .address = @intFromPtr(source), .width = width, .burst = .sixteen }, .{ .address = @intFromPtr(destination), .width = width, .burst = .sixteen }, bytes, 0) orelse {
        shell.print("the buffers are not below 4 GiB\n", .{});
        return;
    };
    var cached: u32 = bytes;
    _ = sys.CachePreDMA(source, &cached, sdk.exec.DMAF_ReadFromRAM);
    cached = bytes;
    _ = sys.CachePreDMA(destination, &cached, 0);
    cached = count * @sizeOf(pl080.Item);
    _ = sys.CachePreDMA(items, &cached, sdk.exec.DMAF_ReadFromRAM);

    const start = uptime.uptimeUs();
    pl080.start(controller.base, unit, items, .memory_to_memory, 0, 0, false);
    while (pl080.running(controller.base, unit) and uptime.uptimeUs() - start < 1_000_000) {}
    const us = uptime.uptimeUs() - start;
    if (pl080.running(controller.base, unit) or pl080.failed(controller.base, unit) or !pl080.finished(controller.base, unit)) {
        const failed = pl080.failed(controller.base, unit);
        pl080.stop(controller.base, unit);
        shell.print("channel %d (PL080 %d): %s after %ld us\n", .{ channel, unit, if (failed) "an error" else "not finished", us });
        return;
    }
    cached = bytes;
    sys.CachePostDMA(destination, &cached, 0);
    const verdict: [*:0]const u8 = if (_shell.same(source[0..bytes], destination[0..bytes])) "copied" else "MISMATCH";
    shell.print("channel %d (PL080 %d): %d bytes %s in %d items, %ld us\n", .{ channel, unit, bytes, verdict, count, us });
}
