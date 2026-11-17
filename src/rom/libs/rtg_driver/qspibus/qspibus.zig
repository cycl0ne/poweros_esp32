// SPDX-License-Identifier: MPL-2.0
//! A display's command bus on the chip's SPI2 controller, as QSPI panel
//! controllers want it.
//!
//! A module of its own: a description of a driver of the transport kind
//! behind a ROM tag, which rtg.library puts on its list. It makes the bus
//! of a part reached over SPI (`BUS_SPI`): the driver of such a panel
//! asks rtg.library for its device's bus (`OpenTransport`) and gets one
//! of these. What it does is turn TxParam, TxColor and RxParam into SPI
//! transactions.
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
//! Longer parameters from elsewhere - a board's bring-up, in flash - are
//! copied there first.
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

const gpspi = sdk.hardware.gpspi.spi2;
const gpio = sdk.hardware.gpio;
const st = sdk.expansion.systemtags;
const BoardPin = sdk.expansion.BoardPin;
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;

const MODULE_NAME = "rtg-qspi";
const DRIVER_NAME = "qspi";
const VERSION = 1;
const REVISION = 5;
const BUILD_DATE = "17.11.2026";
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
const internal_lower: usize = sdk.hardware.map.DRAM_START;
const internal_upper: usize = sdk.hardware.map.DRAM_END;

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
    const rb = made_by.rtg_base;
    // There is one controller: a second bus on it is refused.
    if (made_by.buses != 0) return err.RTGERR_IN_USE;
    const sys = made_by.sys_base;
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

    _ = gpspi.init(@truncate(rb.GetRtgTagData(tags.RTGA_QSPI_ClockHz, 40_000_000, tag_list)));
    connect(instance.pads[0], instance.pads[1], instance.pads[2..6]);

    io.ops = &ops;
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
    if (size > gpspi.buffer_bytes) return sendLong(instance, cmd, param, size);
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
    // The wait for the transaction's end is inside: the bytes are the
    // caller's again when this returns, after an underrun too.
    return send(instance, instance.color_opcode, cmd, .write_four, color, size);
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

/// Parameters longer than the controller's buffer, which the DMA sends:
/// from where they are when that is internal memory, else from a copy
/// there for the one transaction.
fn sendLong(instance: *Instance, cmd: i32, param: ?*const anyopaque, size: u32) i32 {
    const from = @intFromPtr(param orelse return err.RTGERR_BAD_ARG);
    if (from >= internal_lower and from + size <= internal_upper) {
        return send(instance, instance.param_opcode, cmd, .write_one, param, size);
    }
    if (size > max_run) return err.RTGERR_BAD_ARG;
    const sys = instance.sys;
    const copy: [*]u8 = @ptrCast(sys.AllocVec(size, exec.MEMF_INTERNAL | exec.MEMF_DMA) orelse return err.RTGERR_NO_MEMORY);
    defer sys.FreeVec(copy);
    const bytes: [*]const u8 = @ptrFromInt(from);
    @memcpy(copy[0..size], bytes[0..size]);
    return send(instance, instance.param_opcode, cmd, .write_one, copy, size);
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

const ops = rtg.RtgTransportOps{
    .destroy = &destroy,
    .tx_param = &txParam,
    .tx_color = &txColor,
    .rx_param = &rxParam,
};

const driver_ops = rtg.RtgDriverOps{ .create_transport = &createTransport };

/// What it makes the bus of: a part reached over SPI.
const matches = [_]rtg.RtgMatch{
    .{ .fields = rtg.drivers.RTGMATCH_BUS, .bus = st.BUS_SPI },
    .{},
};

/// The driver's tag: a description and no init. rtg.library reads it at
/// its own init and puts the driver on its list; nothing of this module
/// runs until a bus is asked for.
export const rtg_qspi_tag: rtg.ResidentRtgDriver linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&rtg_qspi_tag),
        .version = VERSION,
        .type = .rtg_driver,
        .name = MODULE_NAME,
        .id_string = VERSION_STRING[1..], // past the NUL: a C string
    },
    .spec = .{
        .name = DRIVER_NAME,
        .id_string = VERSION_STRING[1..],
        .version = VERSION,
        .revision = REVISION,
        .kind = rtg.drivers.RTGDT_TRANSPORT,
        // The DMA reads its descriptors out of the instance.
        .flags = rtg.drivers.RTGDF_INTERNAL_INSTANCE,
        .matches = &matches,
        .ops = &driver_ops,
        .instance_size = @sizeOf(Instance),
    },
};
