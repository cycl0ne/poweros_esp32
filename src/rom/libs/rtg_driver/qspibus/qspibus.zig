// SPDX-License-Identifier: MPL-2.0
//! A display's command bus on the chip's SPI2 controller, as QSPI panel
//! controllers want it.
//!
//! A module of its own: it opens rtg.library at cold start, hands in a
//! driver of the transport kind, and from then on anything that asks
//! rtg.library for a "qspi" bus gets one of these. What it does is turn
//! TxParam, TxColor and RxParam into SPI transactions.
//!
//! Every transaction starts with an opcode and a 24-bit address, both on
//! one line; the command is the address's middle byte. The opcode says
//! what follows: parameters on one line, pixels on all four, or bytes read
//! back on one. Which opcode means which is the part's business, so it is
//! configured, with the values these controllers commonly use as defaults.
//!
//! Parameters of up to 64 bytes go through the controller's own buffer;
//! longer runs, and every run of pixels, through a GDMA channel from
//! internal memory, which reads it in bursts: a word at a time it can
//! fall behind a bus on four lines, and the bus does not wait for it.
//! Each call waits for its transaction to end, so the bytes are the
//! caller's again when it returns, and says RTGERR_UNDERRUN when the
//! DMA fell behind part way.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const rtg = sdk.rtg;
const dmares = sdk.resources.dma;
const TagItem = sdk.utility.TagItem;
const err = rtg.errors;
const tags = rtg.tags;
const RtgBase = sdk.interface.rtg.RtgBase;

const gpspi = @import("gpspi.zig");
const gpio = @import("sdk").hardware.gpio;
const st = sdk.expansion.systemtags;
const BoardPin = sdk.expansion.BoardPin;
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;

const MODULE_NAME = "rtg-qspi";
const DRIVER_NAME = "qspi";
const VERSION = 1;
const REVISION = 0;
const BUILD_DATE = "22.9.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The most bytes one call sends: what one transaction can carry.
const max_run = gpspi.max_bytes;
/// Descriptors enough for the longest run.
const descriptors = (max_run + dmares.DMA_CHUNK - 1) / dmares.DMA_CHUNK;

/// How long a transaction may take before the bus counts as stuck, in
/// polls of the controller: far longer than the longest run takes at the
/// slowest clock this driver is given.
const stuck_after = 20_000_000;

/// The internal data RAM, which the DMA reads without help. A run of
/// pixels has to come from here.
const internal_lower: usize = 0x3FC8_8000;
const internal_upper: usize = 0x3FD0_0000;

/// Everything this driver has that changes, allocated once by the init.
const State = struct {
    driver: rtg.RtgDriver = .{},
    sys: *ExecBase,
    /// The bus while one exists. There is one controller, so there is at
    /// most one.
    transport: ?*rtg.RtgTransport = null,
};

fn stateOf(driver: *rtg.RtgDriver) *State {
    return @fieldParentPtr("driver", driver);
}

/// What one bus keeps. In internal memory (RTGDF_INTERNAL_INSTANCE), which
/// is where the DMA reads its descriptors.
const Instance = struct {
    sys: *ExecBase,
    dma: ?*dmares.DmaBase = null,
    channel: u32 = 0,
    has_channel: bool = false,
    param_opcode: u8 = 0x02,
    color_opcode: u8 = 0x32,
    read_opcode: u8 = 0x03,
    /// The clock the bus runs at.
    hz: u32 = 0,
    /// The bus's pads - chip select, clock, D0 to D3 - and gpio.resource,
    /// which they are taken from while the bus exists.
    pads: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    gpio_base: ?*GpioBase = null,
    chain: [descriptors]dmares.DMADescriptor = @splat(.{}),
};

fn instanceOf(io: *rtg.RtgTransport) *Instance {
    return @ptrCast(@alignCast(io.instance.?));
}

fn createTransport(made_by: *rtg.RtgDriver, io: *rtg.RtgTransport, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(made_by);
    const rb: *RtgBase = io.rtg_base.?;
    if (state.transport != null) return err.RTGERR_IN_USE;
    const sys = state.sys;
    const instance = instanceOf(io);
    instance.* = .{ .sys = sys };

    // The panel part's lines, each a pad of the chip.
    const lines = [_]u32{ st.PART_PinSelect, st.PART_PinClock, st.PART_PinData0, st.PART_PinData1, st.PART_PinData2, st.PART_PinData3 };
    for (lines, 0..) |tag, at| {
        const line = BoardPin.of(rb.GetRtgTagData(tag, 0, tag_list));
        if (line.kind != sdk.expansion.boardpin.BPIN_GPIO or line.number > gpio.max_pin) return err.RTGERR_BAD_TAGS;
        instance.pads[at] = line.number;
    }
    if (sys.OpenResource(gpio_resource.GPIONAME)) |found| {
        const gb: *GpioBase = @ptrCast(@alignCast(found));
        if (gpio_resource.allocPads(gb, &instance.pads, MODULE_NAME)) |refused| {
            exec.kprintf(sys, "%s: GPIO%d is %s's\n", .{ MODULE_NAME, refused.pad, refused.holder });
            return err.RTGERR_IN_USE;
        }
        instance.gpio_base = gb;
    }

    instance.param_opcode = @truncate(rb.GetRtgTagData(tags.RTGA_QSPI_ParamOpcode, 0x02, tag_list));
    instance.color_opcode = @truncate(rb.GetRtgTagData(tags.RTGA_QSPI_ColorOpcode, 0x32, tag_list));
    instance.read_opcode = @truncate(rb.GetRtgTagData(tags.RTGA_QSPI_ReadOpcode, 0x03, tag_list));
    io.cmd_bits = 8;
    io.param_bits = 8;

    const db: *dmares.DmaBase = @ptrCast(sys.OpenResource(dmares.DMANAME) orelse {
        giveBack(instance);
        return err.RTGERR_NO_DISPLAY;
    });
    instance.dma = db;
    var ch: u32 = 0;
    while (ch < dmares.DMA_CHANNELS) : (ch += 1) {
        if (db.AllocDMAChannel(ch, MODULE_NAME) == null) break;
    } else {
        giveBack(instance);
        return err.RTGERR_IN_USE;
    }
    instance.channel = ch;
    instance.has_channel = true;
    // Data in bursts: four lines at 40 MHz take 20 MB/s, and the bus
    // clocks on whether the FIFO behind it has anything or not.
    if (!db.ConnectDMAChannel(ch, dmares.DMAPERI_SPI2, dmares.DMACF_BURST)) {
        giveBack(instance);
        return err.RTGERR_NO_DISPLAY;
    }
    // First on the bus among the DMA channels, for the same reason: a
    // channel that waits its turn leaves the FIFO empty under a running
    // clock.
    _ = db.SetDMAPriority(ch, dmares.DMA_OUT, dmares.DMA_MAXPRI);

    instance.hz = gpspi.init(@truncate(rb.GetRtgTagData(tags.RTGA_QSPI_ClockHz, 40_000_000, tag_list)));
    connect(instance.pads[0], instance.pads[1], instance.pads[2..6]);

    io.ops = &ops;
    state.transport = io;
    return err.RTGERR_OK;
}

/// The pads onto the controller through the GPIO matrix. The controller
/// drives each one's output enable itself, which is what lets a data line
/// go from sending to listening within a transaction.
fn connect(cs: u8, clock_pin: u8, data_pins: []const u8) void {
    gpio.toMatrix(cs);
    gpio.connectOut(cs, gpspi.signal_cs0, false);
    gpio.toMatrix(clock_pin);
    gpio.connectOut(clock_pin, gpspi.signal_clock, false);
    for (data_pins, gpspi.data_signals) |pin, signal| {
        gpio.toMatrix(pin);
        gpio.inputEnable(pin, true);
        gpio.connectOut(pin, signal, false);
        gpio.connectIn(signal, pin);
    }
}

fn giveBack(instance: *Instance) void {
    if (instance.has_channel) {
        const db = instance.dma.?;
        db.StopDMA(instance.channel, dmares.DMA_OUT);
        db.FreeDMAChannel(instance.channel);
        instance.has_channel = false;
    }
    if (instance.gpio_base) |gb| gpio_resource.freePads(gb, &instance.pads);
    instance.gpio_base = null;
}

fn destroy(io: *rtg.RtgTransport) callconv(.c) void {
    _ = finish();
    giveBack(instanceOf(io));
    if (io.driver) |driver| stateOf(@ptrCast(@alignCast(driver))).transport = null;
}

/// Wait for the transaction on the bus to end.
fn finish() i32 {
    var polls: u32 = 0;
    while (gpspi.busy()) {
        polls += 1;
        if (polls > stuck_after) return err.RTGERR_TIMEOUT;
    }
    return err.RTGERR_OK;
}

/// The command as the address phase carries it: the middle of 24 bits.
fn addressOf(cmd: i32) u32 {
    return (@as(u32, @bitCast(cmd)) & 0xFF) << 8;
}

/// A command and its parameters, on one line.
fn txParam(io: *rtg.RtgTransport, cmd: i32, param: ?*const anyopaque, size: u32) callconv(.c) i32 {
    // Every transaction on this bus names its command in the address, so
    // there is no such thing as parameters on their own.
    if (cmd < 0) return err.RTGERR_BAD_ARG;
    const instance = instanceOf(io);
    const code = finish();
    if (code != err.RTGERR_OK) return code;
    if (size > gpspi.buffer_bytes) return send(instance, instance.param_opcode, cmd, .write_one, param, size);
    gpspi.prepare(instance.param_opcode, addressOf(cmd), .write_one, size);
    if (size != 0) {
        const bytes: [*]const u8 = @ptrCast(param orelse return err.RTGERR_BAD_ARG);
        gpspi.load(bytes[0..size]);
    }
    gpspi.start(.write_one, size);
    return finish();
}

/// A command and a run of pixels, the pixels on all four lines.
fn txColor(io: *rtg.RtgTransport, cmd: i32, color: ?*const anyopaque, size: u32) callconv(.c) i32 {
    if (cmd < 0) return err.RTGERR_BAD_ARG;
    const instance = instanceOf(io);
    const code = finish();
    if (code != err.RTGERR_OK) return code;
    const sent = send(instance, instance.color_opcode, cmd, .write_four, color, size);
    // An underrun still ended the transfer: the bytes are the caller's.
    if (sent == err.RTGERR_OK or sent == err.RTGERR_UNDERRUN) {
        if (firstBoardOn(io)) |board| _ = io.rtg_base.?.SignalRtgEvent(board, rtg.events.RTGEV_TX_DONE);
    }
    return sent;
}

/// One transaction whose data comes out of memory through the DMA, and
/// the wait for it to end. RTGERR_UNDERRUN when it ended having run dry
/// part way.
fn send(instance: *Instance, opcode: u8, cmd: i32, data: gpspi.Data, bytes: ?*const anyopaque, size: u32) i32 {
    if (size == 0 or size > max_run) return err.RTGERR_BAD_ARG;
    const from = @intFromPtr(bytes orelse return err.RTGERR_BAD_ARG);
    if (from < internal_lower or from + size > internal_upper) return err.RTGERR_BAD_ARG;

    // The chain over the run, handed to the DMA afresh each time: it gives
    // every descriptor back once it has read it.
    var at: u32 = 0;
    var i: usize = 0;
    while (at < size) : (i += 1) {
        const take = @min(size - at, dmares.DMA_CHUNK);
        const last = at + take == size;
        instance.chain[i] = dmares.DMADescriptor.init(
            @ptrFromInt(from + at),
            take,
            take,
            dmares.DMADF_OWNER | (if (last) dmares.DMADF_SUC_EOF else 0),
        );
        instance.chain[i].next = if (last) null else &instance.chain[i + 1];
        at += take;
    }

    const db = instance.dma.?;
    db.ResetDMA(instance.channel, dmares.DMA_OUT);
    gpspi.prepare(opcode, addressOf(cmd), data, size);
    gpspi.fromDma();
    if (!db.StartDMA(instance.channel, dmares.DMA_OUT, &instance.chain[0])) return err.RTGERR_IO;
    gpspi.start(data, size);
    const code = finish();
    if (code == err.RTGERR_OK and gpspi.starved()) return err.RTGERR_UNDERRUN;
    return code;
}

/// A command and `size` bytes read back on one line, in one transaction.
fn rxParam(io: *rtg.RtgTransport, cmd: i32, buffer: ?*anyopaque, size: u32) callconv(.c) i32 {
    if (cmd < 0) return err.RTGERR_BAD_ARG;
    if (size == 0 or size > gpspi.buffer_bytes) return err.RTGERR_BAD_ARG;
    const into: [*]u8 = @ptrCast(buffer orelse return err.RTGERR_BAD_ARG);
    const instance = instanceOf(io);
    const code = finish();
    if (code != err.RTGERR_OK) return code;
    gpspi.prepare(instance.read_opcode, addressOf(cmd), .read_one, size);
    gpspi.toBuffer();
    gpspi.start(.read_one, size);
    const done = finish();
    if (done == err.RTGERR_OK) gpspi.unload(into[0..size]);
    return done;
}

/// The first board that talks through this bus, for the events a transfer
/// raises. A bus carries one panel.
fn firstBoardOn(io: *rtg.RtgTransport) ?*rtg.RtgBoard {
    const rb = io.rtg_base.?;
    var board = rb.NextBoard(null);
    while (board) |b| : (board = rb.NextBoard(b)) {
        if (b.transport == io) return b;
    }
    return null;
}

const ops = rtg.RtgTransportOps{
    .destroy = &destroy,
    .tx_param = &txParam,
    .tx_color = &txColor,
    .rx_param = &rxParam,
};

const driver_ops = rtg.RtgDriverOps{ .create_transport = &createTransport };

/// Cold start at 21: after rtg.library (24), which it joins, and after
/// dma.resource (70), which it takes a channel from when a bus is asked
/// for.
fn init(seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*anyopaque {
    _ = seg_list;
    const library = sys.OpenLibrary(rtg.RTGNAME, VERSION) orelse return @ptrCast(sys);
    const rb: *RtgBase = @ptrCast(library);

    const memory = sys.AllocVec(@sizeOf(State), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    };
    const state: *State = @ptrCast(@alignCast(memory));
    state.* = .{ .sys = sys };
    state.driver = .{
        .node = .{ .name = DRIVER_NAME, .pri = 0 },
        .version = VERSION,
        .revision = REVISION,
        .id_string = VERSION_STRING[1..],
        .type = rtg.boards.RTGDT_TRANSPORT,
        // The DMA reads its descriptors out of the instance.
        .flags = rtg.boards.RTGDF_INTERNAL_INSTANCE,
        .ops = &driver_ops,
        .instance_size = @sizeOf(Instance),
    };
    if (!rb.AddRtgDriver(&state.driver)) {
        sys.FreeVec(memory);
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    }
    return @ptrCast(sys);
}

/// No library and no vectors: the tag's init is the whole of it.
export const rtg_qspi_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rtg_qspi_tag,
    .flags = exec.RTF_COLDSTART,
    .version = VERSION,
    .pri = 21,
    .type = .rtg_driver,
    .name = MODULE_NAME,
    .id_string = VERSION_STRING[1..], // past the NUL: a C string
    .init = @ptrCast(@constCast(&init)),
};
