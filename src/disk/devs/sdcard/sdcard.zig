// SPDX-License-Identifier: MIT
//! sdcard.device: the card in the board's slot as a block device. Unit 0 is
//! the whole card. Its API is the block device API
//! (sdk/devices/trackdisk.zig), as flash.device's is.
//!
//!   CMD_READ         io_Length bytes from io_Offset into io_Data. Both
//!                    are multiples of 512 and the range is on the card.
//!   CMD_WRITE        io_Length bytes from io_Data at io_Offset.
//!   TDCMD_ERASE      answers: a card erases for itself, and
//!                    TD_GETGEOMETRY's erase_size of 0 says so.
//!   CMD_UPDATE       nothing is buffered below the handler, so it
//!   CMD_CLEAR        answers.
//!   TD_GETGEOMETRY   into io_Data: 512-byte blocks, how many there are,
//!                    and DGF_REMOVABLE.
//!   TD_GETNUMTRACKS  io_Actual: the card's blocks.
//!   TD_PROTSTATUS    io_Actual: not 0 if the card refuses to be written.
//!   TD_CHANGENUM     io_Actual: how often a card has been identified.
//!   TD_CHANGESTATE   io_Actual: 0 while a card is in.
//!
//! **Two ways a slot is wired.** The board's card-slot part says which.
//! On the chip's SD/MMC host (`sdmmc.zig`) the card is spoken to in its
//! own mode, four bits wide where it can. On SPI (`sdspi.zig`, over SPI3)
//! it is one bit each way and a chip select, which the board may have put
//! on the IO expander; the select is then held low for as long as a card
//! is in use, because it is the only part on that bus and every change of
//! it costs an I2C write. Everything above the card - the unit, the task,
//! the queue, the geometry, what a card change means - is the same for
//! both.
//!
//! **Every command runs on the device's own task.** A transfer waits for
//! the card, and BeginIO may be called from anywhere -
//! including from a caller that must not wait. So BeginIO checks what it
//! can and queues the rest - TD_CHANGESTATE on an empty slot included,
//! since only speaking to the slot finds a card put in since -
//! as flash.device does; unlike flash.device the
//! stack may be anywhere, because nothing here suspends a cache.
//!
//! **What the DMA can reach.** The SD/MMC host's DMA reaches internal
//! memory only, and a caller's buffer is usually external, so every
//! transfer passes through the buffer in `_sdcard.zig`'s work block. A
//! transfer longer than that buffer is done in rounds of it. On SPI a
//! block received goes by DMA through a buffer of one block in a smaller
//! work block; everything sent, and everything shorter, goes through the
//! controller's own 64-byte buffer, which the CPU fills and empties.
//!
//! **A card can be taken out.** Nothing here is told when that happens -
//! the slot has no switch - so it is found out the next time the card is
//! spoken to and does not answer. The unit then says there is no card,
//! counts the change, and tries to identify one afresh on the next
//! command. A handler that asks TD_CHANGENUM before each packet sees it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const td = sdk.devices.trackdisk;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const intbits = sdk.hardware.intbits;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const BoardPin = expansion.BoardPin;
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;
const sdmmc = @import("sdmmc.zig");
const sdspi = @import("sdspi.zig");
const card = @import("card.zig");
const pads = sdk.hardware.gpio;
const spi = sdk.hardware.gpspi.spi3;
const expander_resource = sdk.resources.expander;
const ExpanderBase = sdk.interface.expander.ExpanderBase;
const _sdcard = @import("_sdcard.zig");
const SdCardBase = _sdcard.SdCardBase;
const Work = _sdcard.Work;

pub const DEVICE_NAME = _sdcard.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 1;
const BUILD_DATE = "28.09.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// Enough for the bring-up and a transfer; nothing here recurses.
const stack_size = 4096;
/// Above dos's processes, below the kernel's tick users, as flash.device
/// is: a file system waits on this and nothing else does.
const task_pri = 5;

// --- the interrupt --------------------------------------------------------

/// The controller's one interrupt, which carries both what the command
/// engine has to say and what its DMA has. Both status registers are read
/// and cleared here - the source is a level, so leaving either standing
/// would raise it again at once - and what they said is left for the task.
fn intServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const sb: *SdCardBase = @ptrCast(@alignCast(is_data.?));
    const work = sb.work orelse return 0;
    const said = sdmmc.takeStatus();
    const dma_said = sdmmc.takeDmaStatus();
    if (said == 0 and dma_said == 0) return 0;
    work.status |= said;
    work.dma_status |= dma_said;
    sb.sys_base.Signal(&sb.task, sb.int_mask);
    return 1;
}

/// What the controller has said since the last transfer began, taken
/// without the interrupt changing it underneath.
fn saidSoFar(sb: *SdCardBase) struct { status: u32, dma: u32 } {
    const sys = sb.sys_base;
    const work = sb.work.?;
    sys.Disable();
    defer sys.Enable();
    return .{ .status = work.status, .dma = work.dma_status };
}

/// A clean slate before a command. The controller's own bits and what
/// the server has collected are dropped together: an interrupt between
/// the two would leave the next command reading the last one's answer.
fn forgetStatus(sb: *SdCardBase) void {
    const sys = sb.sys_base;
    const work = sb.work.?;
    sys.Disable();
    defer sys.Enable();
    _ = sdmmc.takeStatus();
    _ = sdmmc.takeDmaStatus();
    work.status = 0;
    work.dma_status = 0;
}

// --- waiting --------------------------------------------------------------

fn portMask(sb: *SdCardBase) u32 {
    return sb.port.?.sigMask();
}

/// How often an empty slot is looked at. Long enough that the looking
/// costs nothing worth counting, short enough that a card put in is
/// noticed while the hand is still moving away.
const empty_poll_us: u32 = 1_000_000;

/// `us` microseconds on the timer, as a deadline to wait against.
fn armDeadline(sb: *SdCardBase, us: u32) void {
    sb.timer_io.node.command = timer.TR_ADDREQUEST;
    sb.timer_io.time = timer.TimeVal.fromMicros(us);
    sb.sys_base.SendIO(&sb.timer_io.node);
}

fn dropDeadline(sb: *SdCardBase) void {
    const sys = sb.sys_base;
    _ = sys.AbortIO(&sb.timer_io.node);
    _ = sys.WaitIO(&sb.timer_io.node);
}

/// Until every bit of `want` has been said, or something went wrong, or
/// the deadline passed. A deadline that passes is reported as a card that
/// did not answer, because that is what it means: nothing came back.
fn waitFor(sb: *SdCardBase, want: u32, us: u32) card.Fault {
    const sys = sb.sys_base;
    armDeadline(sb, us);
    defer dropDeadline(sb);
    while (true) {
        const said = saidSoFar(sb);
        const fault = _sdcard.faultOf(said.status, said.dma);
        if (fault.any()) return fault;
        if (said.status & want == want) return .{};
        const got = sys.Wait(sb.int_mask | portMask(sb));
        if (got & portMask(sb) != 0 and sys.CheckIO(&sb.timer_io.node) != null) {
            return .{ .no_answer = true };
        }
    }
}

/// `us` microseconds, waited out.
fn delay(sb: *SdCardBase, us: u32) void {
    sb.timer_io.node.command = timer.TR_ADDREQUEST;
    sb.timer_io.time = timer.TimeVal.fromMicros(us);
    _ = sb.sys_base.DoIO(&sb.timer_io.node);
}

// --- commands -------------------------------------------------------------

/// What a command came back with.
const Answer = struct {
    fault: card.Fault = .{},
    resp: [4]u32 = @splat(0),

    fn ok(self: Answer) bool {
        return !self.fault.any();
    }
};

/// The blocks that go with a command: where they pass through, which way
/// they travel, and how the controller should count them. `stop` asks the
/// controller to end a run of them itself.
const Blocks = struct {
    chain: *sdmmc.Descriptor,
    way: sdmmc.Direction,
    block_size: u32,
    count: u32,
    stop: bool = false,
};

/// One command to the card, and its answer.
fn command(
    sb: *SdCardBase,
    index: u32,
    argument: u32,
    response: sdmmc.Response,
    data: ?Blocks,
) Answer {
    forgetStatus(sb);
    if (data) |blocks| {
        sdmmc.prepareData(blocks.chain, blocks.block_size, blocks.count);
    } else {
        sdmmc.prepareData(null, 0, 0);
    }
    const way: ?sdmmc.Direction = if (data) |blocks| blocks.way else null;
    const stop = if (data) |blocks| blocks.stop else false;
    sdmmc.sendCommand(index, argument, response, way, stop);

    var want: u32 = sdmmc.int_command_done;
    if (data != null) {
        want |= sdmmc.int_data_over;
        if (stop) want |= sdmmc.int_auto_command_done;
    }
    var answer = Answer{ .fault = waitFor(sb, want, _sdcard.command_timeout_us) };
    if (!answer.ok()) {
        // Whatever the controller was in the middle of is abandoned, so
        // the next command starts from a known state.
        if (data != null) sdmmc.sendStop();
        sdmmc.resetTransfer();
        return answer;
    }
    if (response != .none) sdmmc.response(&answer.resp);
    // The card may still be working when the controller is finished: an
    // answer that says so, and every write, leave it programming. The
    // next command would be refused, so it is waited out here.
    const wrote = if (data) |blocks| blocks.way == .to_card else false;
    if (response == .short_busy or wrote) waitIdle(sb);
    return answer;
}

/// Until the card has finished what it was given. The card holds a data
/// line down while it programs, and the controller reports that; the
/// count is a last resort, so that a card which never lets go cannot hang
/// the machine.
fn waitIdle(sb: *SdCardBase) void {
    _ = sb;
    var spins: u32 = 0;
    while (sdmmc.busy() and spins < 2_000_000) spins += 1;
}

/// A command the card only listens to after APP_CMD.
fn appCommand(
    sb: *SdCardBase,
    index: u32,
    argument: u32,
    response: sdmmc.Response,
    data: ?Blocks,
) Answer {
    const address: u32 = @as(u32, sb.card.address) << 16;
    const first = command(sb, card.APP_CMD, address, .short, null);
    if (!first.ok()) return first;
    return command(sb, index, argument, response, data);
}

// --- the card -------------------------------------------------------------

fn say(sb: *SdCardBase, what: [*:0]const u8) void {
    sdk.exec.kprintf(sb.sys_base, "%s: %s\n", .{ DEVICE_NAME, what });
}

/// The card in the slot, identified and made ready: block addressing,
/// four bits wide, and the fast clock. False if there is no card, or if
/// it is one this driver cannot use.
///
/// The order is the card's own: it is reset, asked what voltages it
/// takes, told to power up until it says it is ready, then asked who it
/// is and given an address to answer to. Only once it is selected will it
/// say anything about itself that matters here.
fn identify(sb: *SdCardBase) bool {
    sb.card = .{};
    sdmmc.setWide(false);
    sdmmc.setClock(sdmmc.identify_hz);

    // Reset. The card says nothing back, so nothing is checked but that
    // the controller took the command.
    _ = command(sb, card.GO_IDLE_STATE, 0, .none, null);
    delay(sb, 2_000);

    // Which voltages it takes, and whether it is a card new enough to
    // understand the question. One that is not simply never answers.
    const voltage = command(sb, card.SEND_IF_COND, card.if_cond_arg, .short, null);
    const modern = voltage.ok() and (voltage.resp[0] & 0xFF) == card.if_cond_pattern;

    // Powering up. The card answers busy until it is ready, and says at
    // the same time whether it counts in blocks. A card that is still
    // busy when the allowance runs out is not a card this can use.
    var ocr: u32 = 0;
    var waited: u32 = 0;
    while (waited < _sdcard.identify_timeout_us) : (waited += 10_000) {
        const arg = if (modern) card.op_cond_arg else card.op_cond_arg & ~@as(u32, 1 << 30);
        const answer = appCommand(sb, card.SD_SEND_OP_COND, arg, .short_unchecked, null);
        if (!answer.ok()) return false;
        ocr = answer.resp[0];
        if (ocr & (1 << 31) != 0) break;
        delay(sb, 10_000);
    }
    if (ocr & (1 << 31) == 0) return false;
    sb.card.kind = if (ocr & (1 << 30) != 0) .high_capacity else .standard;

    // Who it is, and the address it will answer to from here on.
    const cid = command(sb, card.ALL_SEND_CID, 0, .long, null);
    if (!cid.ok()) return false;
    sb.card.cid = card.decodeCid(&cid.resp);

    const address = command(sb, card.SEND_RELATIVE_ADDR, 0, .short, null);
    if (!address.ok()) return false;
    sb.card.address = card.addressOf(address.resp[0]);

    // What it says about itself, which is asked before it is selected -
    // the card answers this one from its stand-by state.
    const csd = command(sb, card.SEND_CSD, @as(u32, sb.card.address) << 16, .long, null);
    if (!csd.ok()) return false;
    sb.card.csd = card.decodeCsd(&csd.resp) orelse return false;
    if (sb.card.csd.blocks == 0) return false;

    // Selected: from here it will move data.
    const selected = command(sb, card.SELECT_CARD, @as(u32, sb.card.address) << 16, .short_busy, null);
    if (!selected.ok()) return false;

    // Its configuration, which is sent as eight bytes of data rather than
    // as an answer, and says whether it will work four bits wide.
    if (readRegister(sb, card.SEND_SCR, 8)) |raw| {
        sb.card.scr = card.decodeScr(raw[0..8]);
    }

    // Four bits, if the card offers them: the card is told first, then
    // the controller, because a controller that widened first would be
    // listening on lines the card is not yet driving.
    if (sb.card.scr.four_bit) {
        const wide = appCommand(sb, card.SET_BUS_WIDTH, card.bus_width_4, .short, null);
        if (wide.ok()) {
            sdmmc.setWide(true);
            sb.card.wide = true;
        }
    }

    // The block length, which a card that counts in blocks fixes at 512
    // anyway and one that counts in bytes has to be told.
    const length = command(sb, card.SET_BLOCKLEN, @intCast(card.block_bytes), .short, null);
    if (!length.ok()) return false;

    sdmmc.setClock(sdmmc.fast_hz);
    sb.card.clock_hz = sdmmc.fast_hz;
    return true;
}

/// A register the card sends over the data lines rather than as an
/// answer: `bytes` of it, into the work buffer. Null if the card did not
/// send it.
///
/// The controller is told the register's own length is a whole block, or
/// it would wait for the rest of a 512-byte one that is never coming.
fn readRegister(sb: *SdCardBase, index: u32, bytes: u32) ?[]const u8 {
    const work = sb.work.?;
    @memset(work.buffer[0..bytes], 0);
    work.chain[0].set(
        &work.buffer,
        bytes,
        sdmmc.Descriptor.first | sdmmc.Descriptor.last,
        null,
    );
    const answer = appCommand(sb, index, 0, .short, .{
        .chain = &work.chain[0],
        .way = .from_card,
        .block_size = bytes,
        .count = 1,
    });
    if (!answer.ok()) return null;
    return work.buffer[0..bytes];
}

// --- transfers ------------------------------------------------------------

/// The work buffer's descriptors, laid over `bytes` of it and handed to
/// the controller.
fn layChain(sb: *SdCardBase, bytes: u32) *sdmmc.Descriptor {
    const work = sb.work.?;
    var left = bytes;
    var at: u32 = 0;
    var i: u32 = 0;
    while (left > 0) : (i += 1) {
        const piece = @min(left, sdmmc.dma_buffer_max);
        var flags: u32 = 0;
        if (i == 0) flags |= sdmmc.Descriptor.first;
        if (piece == left) flags |= sdmmc.Descriptor.last;
        const next: ?*sdmmc.Descriptor = if (piece == left) null else &work.chain[i + 1];
        work.chain[i].set(&work.buffer[at], piece, flags, next);
        at += piece;
        left -= piece;
    }
    return &work.chain[0];
}

/// A run of blocks, one round of the work buffer at a time. `out` is the
/// caller's buffer; for a write the bytes are copied in first, for a read
/// they are copied out after.
fn transfer(sb: *SdCardBase, way: sdmmc.Direction, block: u64, count: u32, bytes: [*]u8) i8 {
    if (sb.slot.spi != 0) return transferSpi(sb, way, block, count, bytes);
    const work = sb.work.?;
    var done: u32 = 0;
    while (done < count) {
        const piece = @min(count - done, _sdcard.chunk_blocks);
        const piece_bytes = piece * @as(u32, @intCast(card.block_bytes));
        const at = done * @as(u32, @intCast(card.block_bytes));
        if (way == .to_card) @memcpy(work.buffer[0..piece_bytes], bytes[at..][0..piece_bytes]);

        const many = piece > 1;
        const index: u32 = switch (way) {
            .from_card => if (many) card.READ_MULTIPLE_BLOCK else card.READ_SINGLE_BLOCK,
            .to_card => if (many) card.WRITE_MULTIPLE_BLOCK else card.WRITE_BLOCK,
        };
        const answer = command(sb, index, sb.card.blockArg(block + done), .short, .{
            .chain = layChain(sb, piece_bytes),
            .way = way,
            .block_size = @intCast(card.block_bytes),
            .count = piece,
            .stop = many,
        });
        if (!answer.ok()) {
            lost(sb);
            return answer.fault.code();
        }
        if (answer.resp[0] & card.r1_errors != 0) return td.TDERR_NotSpecified;
        if (way == .from_card) @memcpy(bytes[at..][0..piece_bytes], work.buffer[0..piece_bytes]);
        done += piece;
    }
    return 0;
}

/// A card going in or out told to input.device, which hands it to
/// intuition, which tells every window that asked
/// (`IDCMP_DISKINSERTED`, `IDCMP_DISKREMOVED`). Nothing here waits on
/// it or minds if it cannot be sent: it is how a window showing what is
/// mounted hears that it should look again.
fn announce(sb: *SdCardBase, class: u32) void {
    const sys = sb.sys_base;
    const io = sb.input_io orelse blk: {
        const port = sb.port orelse return;
        const made = sys.CreateIORequest(port, @sizeOf(exec.IOStdReq)) orelse return;
        const req: *exec.IOStdReq = @ptrCast(@alignCast(made));
        if (sys.OpenDevice(sdk.devices.input.INPUTNAME, 0, &req.req, 0) != 0) {
            sys.DeleteIORequest(@ptrCast(req));
            return;
        }
        sb.input_io = req;
        break :blk req;
    };
    sb.input_event = .{ .class = class };
    io.req.command = sdk.devices.input.IND_WRITEEVENT;
    io.length = @sizeOf(sdk.devices.inputevent.InputEvent);
    io.data = @ptrCast(&sb.input_event);
    _ = sys.DoIO(&io.req);
}

/// The card stopped answering. Whatever it was is gone; the next command
/// looks for one afresh, and the change count tells a handler its locks
/// are worthless.
fn lost(sb: *SdCardBase) void {
    if (sb.present == 0) return;
    sb.present = 0;
    sb.change_num +%= 1;
    say(sb, "the card stopped answering");
    announce(sb, sdk.devices.inputevent.IECLASS_DISKREMOVED);
}

/// A card in the slot, identified if it has not been already. False if
/// the slot is empty or the card cannot be used.
fn ready(sb: *SdCardBase) bool {
    if (sb.present != 0) return true;
    if (sb.slot.spi != 0) {
        var bus = SpiBus{ .sb = sb };
        // A card the chip was reset on - part way through a run of
        // blocks, say - has been seen to miss the first wake-up and take
        // the second. An empty slot fails both at once.
        if (!Spi.identify(&bus, &sb.card) and !Spi.identify(&bus, &sb.card)) return false;
    } else {
        if (!sdmmc.cardPresent()) return false;
        // The reset puts the controller's interrupt gates back where they
        // start, so what this device wants raised has to be said again.
        sdmmc.reset();
        sdmmc.interruptsOn(sdmmc.int_wanted, sdmmc.dma_int_wanted);
        if (!identify(sb)) return false;
    }
    sb.present = 1;
    sb.change_num +%= 1;
    report(sb);
    announce(sb, sdk.devices.inputevent.IECLASS_DISKINSERTED);
    return true;
}

fn report(sb: *SdCardBase) void {
    const sys = sb.sys_base;
    var name: [6]u8 = @splat(0);
    @memcpy(name[0..5], &sb.card.cid.name);
    if (sb.slot.spi != 0) {
        sdk.exec.kprintf(sys, "%s: %s, %ld MB, SPI at %d kHz\n", .{
            DEVICE_NAME,
            @as([*:0]const u8, @ptrCast(&name)),
            sb.card.bytes() / (1024 * 1024),
            sb.card.clock_hz / 1000,
        });
        return;
    }
    sdk.exec.kprintf(sys, "%s: %s, %ld MB, %d bits at %d kHz\n", .{
        DEVICE_NAME,
        @as([*:0]const u8, @ptrCast(&name)),
        sb.card.bytes() / (1024 * 1024),
        @as(u32, if (sb.card.wide) 4 else 1),
        sb.card.clock_hz / 1000,
    });
}

/// Whether the card may not be written: its own say, or the slot's
/// write-protect switch where it has one.
fn writeProtected(sb: *SdCardBase) bool {
    if (sb.card.readOnly()) return true;
    return sb.slot.spi == 0 and sdmmc.writeProtected();
}

// --- the SPI slot ---------------------------------------------------------

/// The bus `sdspi.zig` speaks to the card over: SPI3, the slot's chip
/// select wherever the board put it, and the task's timer.
///
/// What fits the controller's own 64-byte buffer - a command, an answer,
/// a token, a chunk listened to while the card is busy - goes through it,
/// the CPU filling and emptying it, and so does everything sent. A block
/// received goes by DMA, through the work block's buffer in internal
/// memory, in one transaction, and the task sleeps on the controller's
/// interrupt until it is over: the CPU is another task's for the fifth of
/// a millisecond a block takes.
const SpiBus = struct {
    sb: *SdCardBase,

    pub fn select(bus: *SpiBus, on: bool) bool {
        const line = BoardPin.of(bus.sb.slot.select);
        const high = on != (line.active_low != 0);
        switch (line.kind) {
            expansion.boardpin.BPIN_GPIO => {
                pads.setLevel(line.number, high);
                return true;
            },
            expansion.boardpin.BPIN_EXPANDER => {
                const eb = bus.sb.expander orelse return false;
                return eb.SetPin(line.number, high);
            },
            else => return false,
        }
    }

    pub fn exchange(bus: *SpiBus, bytes: []u8) void {
        _ = bus;
        var at: usize = 0;
        while (at < bytes.len) {
            const piece = @min(bytes.len - at, spi.buffer_bytes);
            spi.exchange(bytes[at..][0..piece]);
            at += piece;
        }
    }

    /// A block by DMA, anything shorter through the controller's buffer.
    /// The DMA only receives whole words: given a length that is not one,
    /// it reports the frame done and writes nothing. So the odd bytes at
    /// the front - there are some whenever part of a block came in with
    /// its start token - go through the controller's buffer first.
    pub fn receive(bus: *SpiBus, into: []u8) void {
        if (into.len <= spi.buffer_bytes) return spi.receive(into);
        const odd = into.len % 4;
        if (odd != 0) spi.receive(into[0..odd]);
        receiveByDma(bus.sb, into[odd..]);
    }

    /// Always through the controller's buffer, which the CPU fills before
    /// the transaction starts. A send by DMA ran dry when the panel's
    /// channels held the bus, and the card then took a block with holes
    /// in it; a buffer filled first cannot run dry. Writing waits on the
    /// card's programming far longer than on this.
    pub fn send(bus: *SpiBus, bytes: []const u8) void {
        _ = bus;
        var scratch: [64]u8 = undefined;
        var at: usize = 0;
        while (at < bytes.len) {
            const piece = @min(bytes.len - at, scratch.len);
            @memcpy(scratch[0..piece], bytes[at..][0..piece]);
            spi.exchange(scratch[0..piece]);
            at += piece;
        }
    }

    pub fn setClock(bus: *SpiBus, hz: u32) u32 {
        _ = bus;
        return spi.setClock(hz);
    }

    pub fn delay(bus: *SpiBus, us: u32) void {
        const sb = bus.sb;
        sb.timer_io.node.command = timer.TR_ADDREQUEST;
        sb.timer_io.time = timer.TimeVal.fromMicros(us);
        _ = sb.sys_base.DoIO(&sb.timer_io.node);
    }
};

const Spi = sdspi.Protocol(SpiBus);

/// How long a DMA channel is given to fetch its descriptor
/// before the controller starts: 5 us at the CPU's 240 MHz.
const descriptor_fetch_cycles: u32 = 5 * 240;

/// SPI3's interrupt: a transaction the task is waiting on has ended. The
/// source is a level, so the mark is cleared here; what it said is left
/// in the work block for the task.
fn spiIntServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const sb: *SdCardBase = @ptrCast(@alignCast(is_data.?));
    const work = sb.spi_work orelse return 0;
    if (!spi.takeDone()) return 0;
    work.done = 1;
    sb.sys_base.Signal(&sb.task, sb.int_mask);
    return 1;
}

/// The DMA transaction set up and its channel started, run, and waited
/// out on the interrupt. The mark is cleared before the flag, so an
/// interrupt left over from an earlier transaction cannot pass for this
/// one; the interrupt is on only while it runs. A transaction that never
/// ends - a controller that has stopped - is given up after a deadline.
///
/// **The channel has to be ready before the controller starts,** or the
/// bytes are dropped or never there: `descriptor_fetch_cycles` pass
/// between the two.
///
/// **The controller finishing is not the data being in memory.** Its
/// interrupt comes when the last bit is on the wire; the DMA may still be
/// emptying its FIFO into the buffer then. So a receive also waits for the
/// channel to say the whole frame is written (IN_SUC_EOF) - without it the
/// last bytes of a block were those of the one before, which only showed
/// on blocks that were not all alike.
fn runDma(sb: *SdCardBase, side: u32, link: *sdk.resources.dma.DMADescriptor) void {
    const sys = sb.sys_base;
    const work = sb.spi_work.?;
    const db = sb.dma_base.?;
    const dma_resource = sdk.resources.dma;
    _ = spi.takeDone();
    work.done = 0;
    db.ClearDMAInts(sb.dma_channel, side, 0xFFFF_FFFF);
    _ = db.StartDMA(sb.dma_channel, side, link);
    // A channel needs time after it is started to fetch its descriptor.
    // Bytes the controller sends it before then are dropped, and the frame
    // ends with nothing in it. With the panel's copy channel busy on the
    // bus, 1 us was too little for 7 receives in a thousand; 5 us has been
    // enough for every one measured.
    {
        const cpu = sdk.hardware.cpu;
        const since = cpu.ccount();
        while (cpu.ccount() -% since < descriptor_fetch_cycles) {}
    }
    spi.doneInterrupt(true);
    spi.begin();
    armDeadline(sb, _sdcard.command_timeout_us);
    const done: *volatile u32 = &work.done;
    while (done.* == 0) {
        const got = sys.Wait(sb.int_mask | portMask(sb));
        if (got & portMask(sb) != 0 and sys.CheckIO(&sb.timer_io.node) != null) break;
    }
    dropDeadline(sb);
    spi.doneInterrupt(false);
    // Stopped whatever came of it, so a transaction abandoned by the
    // deadline cannot write into the buffer under the next one.
    var spins: u32 = 0;
    while (spi.busy() and spins < 1_000_000) spins += 1;
    if (side == dma_resource.DMA_IN) {
        spins = 0;
        while (db.DMARawIntStatus(sb.dma_channel, side) & dma_resource.DMAINTF_IN_SUC_EOF == 0 and spins < 1_000_000) spins += 1;
    }
    db.StopDMA(sb.dma_channel, side);
}

/// `into` from the card by DMA, a block of the work buffer at a time. Its
/// length is whole words (`SpiBus.receive` sees to it).
fn receiveByDma(sb: *SdCardBase, into: []u8) void {
    const work = sb.spi_work.?;
    const db = sb.dma_base.?;
    var at: usize = 0;
    while (at < into.len) {
        const piece: u32 = @intCast(@min(into.len - at, _sdcard.spi_dma_bytes));
        work.in_link = sdk.resources.dma.DMADescriptor.init(&work.buffer, work.buffer.len, 0, sdk.resources.dma.DMADF_OWNER);
        db.ResetDMA(sb.dma_channel, sdk.resources.dma.DMA_IN);
        spi.receiveByDma(piece);
        runDma(sb, sdk.resources.dma.DMA_IN, &work.in_link);
        @memcpy(into[at..][0..piece], work.buffer[0..piece]);
        at += piece;
    }
}

/// A run of blocks over SPI, straight between the caller's buffer and the
/// controller's. A card that stopped answering, or whose data did not
/// check out, is taken for gone, as on the SD/MMC host.
fn transferSpi(sb: *SdCardBase, way: sdmmc.Direction, block: u64, count: u32, bytes: [*]u8) i8 {
    var bus = SpiBus{ .sb = sb };
    const outcome = switch (way) {
        .from_card => Spi.read(&bus, &sb.card, block, count, bytes),
        .to_card => Spi.write(&bus, &sb.card, block, count, bytes),
    };
    if (outcome.lost()) lost(sb);
    return outcome.code();
}

/// SPI3 on the slot's pads, and its chip select: claimed on the expander,
/// or a pad driven high until a card is spoken to. False if the select
/// cannot be had.
fn setUpSpi(sb: *SdCardBase) bool {
    const sys = sb.sys_base;
    const slot = sb.slot;
    const line = BoardPin.of(slot.select);
    switch (line.kind) {
        expansion.boardpin.BPIN_EXPANDER => {
            const resource = sys.OpenResource(expander_resource.EXPANDERNAME) orelse {
                say(sb, "no IO expander for the card's chip select");
                return false;
            };
            const eb: *ExpanderBase = @ptrCast(@alignCast(resource));
            if (!eb.ClaimPin(line.number, DEVICE_NAME)) {
                say(sb, "the card's chip select is another driver's");
                return false;
            }
            sb.expander = eb;
        },
        expansion.boardpin.BPIN_GPIO => {
            pads.toMatrix(line.number);
            pads.setLevel(line.number, line.active_low != 0);
            pads.outputEnable(line.number, true);
        },
        else => return false,
    }

    _ = spi.init(sdspi.identify_hz);
    // The controller drives the clock's and MOSI's output enable itself;
    // MISO is only read, and the board's pull-up holds it high while no
    // card drives it, which is what an empty slot reads as.
    pads.toMatrix(slot.clock);
    pads.connectOut(slot.clock, spi.signal_clock, false);
    pads.toMatrix(slot.command);
    pads.connectOut(slot.command, spi.signal_d, false);
    const miso = slot.data[0];
    pads.toMatrix(miso);
    pads.inputEnable(miso, true);
    pads.pullUp(miso, true);
    pads.connectIn(spi.signal_q, miso);

    // A DMA channel, the first one free, connected to SPI3.
    const dma_resource = sdk.resources.dma;
    const db: *dma_resource.DmaBase = @ptrCast(@alignCast(sys.OpenResource(dma_resource.DMANAME) orelse {
        say(sb, "no dma.resource");
        return false;
    }));
    var channel: u32 = 0;
    while (channel < dma_resource.DMA_CHANNELS) : (channel += 1) {
        if (db.AllocDMAChannel(channel, DEVICE_NAME) == null) break;
    } else {
        say(sb, "no DMA channel free");
        return false;
    }
    if (!db.ConnectDMAChannel(channel, dma_resource.DMAPERI_SPI3, 0)) {
        db.FreeDMAChannel(channel);
        say(sb, "the DMA channel would not connect to SPI3");
        return false;
    }
    // Just under the top, level with the panel's own copy channel on a
    // board with an RGB panel: that copy moves its picture out of PSRAM
    // all the time, and a channel below it waits so long for the bus that
    // its FIFO overflows and blocks come in with holes. Level with it the
    // two take turns, and the card needs a small share of them. The top
    // is left to the panel, which cannot wait at all.
    const priority = dma_resource.DMA_MAXPRI - 1;
    _ = db.SetDMAPriority(channel, dma_resource.DMA_IN, priority);
    _ = db.SetDMAPriority(channel, dma_resource.DMA_OUT, priority);
    sb.dma_base = db;
    sb.dma_channel = channel;

    // The block the DMA and the interrupt reach: internal, on a cache
    // line of its own.
    const cache_line = 64;
    const memory = sys.AllocMem(@sizeOf(_sdcard.SpiWork) + cache_line, exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse {
        say(sb, "no internal memory for the card's buffer");
        return false;
    };
    sb.spi_work_memory = memory;
    const aligned = (@intFromPtr(memory) + cache_line - 1) & ~@as(usize, cache_line - 1);
    const work: *_sdcard.SpiWork = @ptrFromInt(aligned);
    work.* = .{};
    work.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = DEVICE_NAME },
        .data = sb,
        .code = &spiIntServer,
    };
    sb.spi_work = work;
    sys.AddIntServer(intbits.INTB_SPI3, &work.int);
    return true;
}

// --- the task -------------------------------------------------------------

/// Every command that talks to the card. The port is given its signal
/// before the first message is taken, so a request that arrived while the
/// device was starting is not missed.
fn sdTask(sys: *ExecBase) callconv(.c) void {
    const sb: *SdCardBase = @fieldParentPtr("task", sys.FindTask(null).?);
    const queue_port = &sb.unit.msg_port;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return started(sb);
    sys.Disable();
    queue_port.sig_bit = @intCast(signal);
    queue_port.sig_task = &sb.task;
    queue_port.flags = exec.PA_SIGNAL;
    sys.Enable();

    if (!setUp(sb)) {
        started(sb);
        // Nothing can be opened, but the requests already queued still
        // have to be answered.
        while (true) {
            while (sys.GetMsg(queue_port)) |msg| {
                const io = _sdcard.requestOf(msg);
                if (io.command == td.TD_CHANGESTATE) {
                    _sdcard.stdReq(io).actual = 1;
                } else {
                    io.err = td.TDERR_NoCard;
                }
                sys.ReplyIO(io);
            }
            _ = sys.Wait(queue_port.sigMask());
        }
    }
    started(sb);

    // The first look at the slot, after the init has been let go: a card
    // may take seconds to power up, and the machine's start does not wait
    // for it. A request that comes in meanwhile waits on the queue.
    if (!ready(sb)) say(sb, "no card in the slot");

    while (true) {
        while (sys.GetMsg(queue_port)) |msg| {
            const io = _sdcard.requestOf(msg);
            slowIO(sb, io);
            sys.ReplyIO(io);
        }
        // With a card in, nothing is done until something asks: a card
        // that goes is found by the command that fails on it. With the
        // slot empty there is nothing to fail, so the slot is looked at
        // now and then - that is how a card put in is noticed by a
        // window that is only showing what is mounted, with nobody
        // reading from it.
        if (sb.present != 0 or sb.has_slot == 0) {
            _ = sys.Wait(queue_port.sigMask());
            continue;
        }
        armDeadline(sb, empty_poll_us);
        // The timer answers on the task's own port, not on the queue, so
        // the wait has to listen for both.
        const got = sys.Wait(queue_port.sigMask() | portMask(sb));
        dropDeadline(sb);
        // A request that came in is served first; the slot is looked at
        // only when nothing but the timer woke it.
        if (got & queue_port.sigMask() != 0) continue;
        _ = ready(sb);
    }
}

/// The init is waiting to hear that the task is ready for requests.
fn started(sb: *SdCardBase) void {
    sb.started = 1;
    if (sb.starter) |starter| {
        const bit: u5 = @intCast(sb.start_signal);
        sb.starter = null;
        sb.sys_base.Signal(starter, @as(u32, 1) << bit);
    }
}

/// The task's own port and timer, and the controller: the SD/MMC host and
/// its interrupt, or SPI3 and the chip select. False if there is no
/// controller here.
fn setUp(sb: *SdCardBase) bool {
    const sys = sb.sys_base;

    const int_signal = sys.AllocSignal(-1);
    if (int_signal < 0) return false;
    sb.int_mask = @as(u32, 1) << @intCast(int_signal);

    sb.port = sys.CreateMsgPort() orelse return false;
    sb.timer_io = .{};
    sb.timer_io.node.message.reply_port = sb.port;
    sb.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &sb.timer_io.node, 0) != 0) return false;

    if (sb.slot.spi != 0) {
        if (!setUpSpi(sb)) return false;
        sb.controller_ready = 1;
        return true;
    }

    const slot = sb.slot;
    if (!sdmmc.init(.{
        .clock = slot.clock,
        .command = slot.command,
        .data = slot.data,
        .detect = if (slot.detect == _sdcard.no_pin) null else slot.detect,
        .write_protect = if (slot.write_protect == _sdcard.no_pin) null else slot.write_protect,
    })) {
        say(sb, "no SD host controller on this machine");
        return false;
    }

    sys.AddIntServer(intbits.INTB_SDIO_HOST, &sb.work.?.int);
    sb.controller_ready = 1;
    sdmmc.interruptsOn(sdmmc.int_wanted, sdmmc.dma_int_wanted);

    return true;
}

/// The commands that talk to the card. On the task, so they may wait.
fn slowIO(sb: *SdCardBase, io: *exec.IORequest) void {
    const req = _sdcard.stdReq(io);
    if (!ready(sb)) {
        // An empty slot is an answer to this one, not a fault.
        if (io.command == td.TD_CHANGESTATE) {
            req.actual = 1;
        } else {
            io.err = td.TDERR_NoCard;
        }
        return;
    }
    const block_bytes = card.block_bytes;
    switch (io.command) {
        exec.CMD_READ => {
            if (!_sdcard.inside(sb, req.offset, req.length)) {
                io.err = exec.IOERR_BADADDRESS;
            } else if (req.length == 0) {
                req.actual = 0;
            } else {
                io.err = transfer(
                    sb,
                    .from_card,
                    req.offset / block_bytes,
                    @intCast(req.length / block_bytes),
                    @ptrCast(req.data.?),
                );
                if (io.err == 0) req.actual = req.length;
            }
        },
        exec.CMD_WRITE => {
            if (!_sdcard.inside(sb, req.offset, req.length)) {
                io.err = exec.IOERR_BADADDRESS;
            } else if (writeProtected(sb)) {
                io.err = td.TDERR_WriteProt;
            } else if (req.length == 0) {
                req.actual = 0;
            } else {
                io.err = transfer(
                    sb,
                    .to_card,
                    req.offset / block_bytes,
                    @intCast(req.length / block_bytes),
                    @ptrCast(req.data.?),
                );
                if (io.err == 0) req.actual = req.length;
            }
        },
        td.TD_GETGEOMETRY => {
            if (req.data) |data| {
                _sdcard.geometry(sb, @ptrCast(@alignCast(data)));
            } else {
                io.err = exec.IOERR_BADADDRESS;
            }
        },
        td.TD_GETNUMTRACKS => req.actual = @intCast(sb.card.csd.blocks),
        td.TD_PROTSTATUS => req.actual = if (writeProtected(sb)) 1 else 0,
        td.TD_CHANGESTATE => req.actual = 0,
        else => io.err = exec.IOERR_NOCMD,
    }
}

// --- the device -----------------------------------------------------------

/// Whether `io` can wait: it will be replied, so it needs a reply port.
fn canWait(io: *exec.IORequest) bool {
    if (io.message.reply_port != null) return true;
    io.err = exec.IOERR_NOREPLYPORT;
    io.flags |= exec.IOF_QUICK;
    return false;
}

/// Onto the task's queue; it will be replied, so not quick I/O.
fn queue(sb: *SdCardBase, io: *exec.IORequest) void {
    if (!canWait(io)) return sb.sys_base.ReplyIO(io);
    io.flags &= ~exec.IOF_QUICK;
    sb.sys_base.PutMsg(&sb.unit.msg_port, &io.message);
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    _ = dev;
    const sb = _sdcard.baseOf(io);
    const req = _sdcard.stdReq(io);
    io.err = 0;
    req.actual = 0;
    switch (io.command) {
        // Everything that touches the card waits, so it goes to the task.
        exec.CMD_READ,
        exec.CMD_WRITE,
        td.TD_GETGEOMETRY,
        td.TD_GETNUMTRACKS,
        td.TD_PROTSTATUS,
        => return queue(sb, io),
        // A card erases for itself, and nothing below the handler is
        // buffered, so these three answer where they stand.
        td.TDCMD_ERASE, exec.CMD_UPDATE, exec.CMD_CLEAR => {},
        // What the device already knows, without asking the card: a
        // handler asks these between packets and must not be made to
        // wait for them.
        td.TD_CHANGENUM => req.actual = sb.change_num,
        // A card that is in is known. An empty slot is not: with no
        // card-detect line, only speaking to the slot finds a card put
        // in since, so that question goes to the task.
        td.TD_CHANGESTATE => if (sb.present == 0) return queue(sb, io),
        else => io.err = exec.IOERR_NOCMD,
    }
    sb.sys_base.ReplyIO(io);
}

/// A request the task hasn't started yet is taken off its queue and
/// replied; one it is busy with can't be stopped.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const sb = _sdcard.sdCardBase(dev);
    const sys = sb.sys_base;
    sys.Disable();
    defer sys.Enable();
    var it = sb.unit.msg_port.msg_list.iterator();
    while (it.next()) |n| {
        const msg: *exec.Message = @fieldParentPtr("node", n);
        if (_sdcard.requestOf(msg) != io) continue;
        sys.Remove(n);
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
        return 0;
    }
    return -1;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const sb = _sdcard.sdCardBase(dev);
    if (unit_number != 0) return td.TDERR_BadUnitNum;
    // The slot opens whether or not a card is in it: a handler that sits
    // on it has to be there before the card is, and finds out by asking.
    if (sb.controller_ready == 0) return exec.IOERR_OPENFAIL;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    sb.unit.open_cnt += 1;
    io.unit = &sb.unit;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const sb = _sdcard.baseOf(io);
    _ = abortIO(dev, io);
    sb.unit.open_cnt -= 1;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: it owns its task, its interrupt and the controller,
/// and a file system sits on it. The seglist it was loaded from is kept
/// in the base for the day it does go.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

/// Every pad the slot has, in `into`: its clock, command and data lines
/// (on SPI: the clock, MOSI and MISO), its card-detect and write-protect
/// where it has them, and a chip select that is a pad of the chip.
fn slotPads(slot: _sdcard.Slot, into: *[8]u8) []const u8 {
    into[0] = slot.clock;
    into[1] = slot.command;
    var count: usize = 2;
    for (slot.data) |data_pad| {
        if (data_pad == _sdcard.no_pin) continue;
        into[count] = data_pad;
        count += 1;
    }
    for ([_]u8{ slot.detect, slot.write_protect }) |sense_pad| {
        if (sense_pad == _sdcard.no_pin) continue;
        into[count] = sense_pad;
        count += 1;
    }
    const select = BoardPin.of(slot.select);
    if (slot.spi != 0 and select.kind == expansion.boardpin.BPIN_GPIO) {
        into[count] = select.number;
        count += 1;
    }
    return into[0..count];
}

/// Which pads are the slot's: expansion.library's card-slot part, whose
/// tags say where each line is. A board without a slot - or with one this
/// driver cannot run - leaves `has_slot` clear, and there is no device.
fn findSlot(sb: *SdCardBase) void {
    const sys = sb.sys_base;
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_SDSLOT, st.CHIP_ANY) orelse return;
    const tags = part.tags;

    // On SPI: the clock, MOSI and MISO on pads of the chip, and a chip
    // select wherever the board put it.
    if (ub.GetTagData(st.PART_Bus, st.BUS_SDIO, tags) == st.BUS_SPI) {
        var slot: _sdcard.Slot = .{ .spi = 1, .data = @splat(_sdcard.no_pin) };
        slot.clock = pad(ub, st.PART_PinClock, tags) orelse return;
        slot.command = pad(ub, st.PART_PinDataOut, tags) orelse return;
        slot.data[0] = pad(ub, st.PART_PinDataIn, tags) orelse return;
        const select = BoardPin.of(ub.GetTagData(st.PART_PinSelect, 0, tags));
        if (!select.wired()) return;
        slot.select = @intCast(select.data());
        sb.slot = slot;
        sb.has_slot = 1;
        return;
    }

    // On the SD/MMC host every line is a pad of the chip, which drives
    // them all.
    var slot: _sdcard.Slot = .{};
    slot.clock = pad(ub, st.PART_PinClock, tags) orelse return;
    slot.command = pad(ub, st.PART_PinCommand, tags) orelse return;
    const data_tags = [4]sdk.utility.Tag{ st.PART_PinData0, st.PART_PinData1, st.PART_PinData2, st.PART_PinData3 };
    for (data_tags, 0..) |tag, line| slot.data[line] = pad(ub, tag, tags) orelse return;
    slot.detect = pad(ub, st.PART_PinDetect, tags) orelse _sdcard.no_pin;
    slot.write_protect = pad(ub, st.PART_PinWriteProtect, tags) orelse _sdcard.no_pin;
    sb.slot = slot;
    sb.has_slot = 1;
}

/// The pad a part's line is on, or null if it has no such line or the line
/// is not a pad of the chip.
fn pad(ub: *sdk.interface.utility.UtilityBase, tag: sdk.utility.Tag, tags: ?[*]const sdk.utility.TagItem) ?u8 {
    const line = BoardPin.of(ub.GetTagData(tag, 0, tags));
    if (line.kind != expansion.boardpin.BPIN_GPIO) return null;
    return line.number;
}

/// exec has copied the tag's name, version and ID string into the base.
/// A board without a slot, or a machine without the controller, gets no
/// device at all: null, before anything is taken, so the base and the
/// file both go and nothing of the device is left behind.
/// The block the DMA and the interrupt reach is allocated internal and
/// aligned to a cache line; the task that talks to the card gets a stack;
/// and this waits until the task takes requests. It does not wait for the
/// card: the task's first look at the slot comes after, and a handler's
/// first question queues behind it, so it still gets a card or an honest
/// answer.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const sb = _sdcard.sdCardBase(dev);
    sb.sys_base = sys_base;
    sb.seg_list = seg_list;
    // No slot, or no controller behind it: there is no device to make.
    // Deciding it here, before anything is allocated or started, is what
    // lets the whole of it go - exec frees the base when this answers
    // null, and ramlib gives the file back.
    findSlot(sb);
    if (sb.has_slot == 0) {
        sdk.exec.kprintf(sys_base, "%s: no card slot on this board\n", .{DEVICE_NAME});
        return null;
    }
    if (sb.slot.spi == 0 and !sdmmc.present()) {
        sdk.exec.kprintf(sys_base, "%s: no SD host controller on this machine\n", .{DEVICE_NAME});
        return null;
    }
    // The slot's pads, the device's for as long as it exists.
    var pad_list: [8]u8 = undefined;
    const slot_pads = slotPads(sb.slot, &pad_list);
    const gb: ?*GpioBase = @ptrCast(@alignCast(sys_base.OpenResource(gpio_resource.GPIONAME)));
    if (gb) |taken_from| {
        if (gpio_resource.allocPads(taken_from, slot_pads, DEVICE_NAME)) |refused| {
            sdk.exec.kprintf(sys_base, "%s: GPIO%d is %s's\n", .{ DEVICE_NAME, refused.pad, refused.holder });
            return null;
        }
    }
    // PA_IGNORE until the task has a signal for it: a request that comes
    // in while the device starts is queued, and the task takes it then.
    sb.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    sb.unit.msg_port.msg_list.init(.message);

    // The base itself is wherever MakeLibrary put it, which on this board
    // is external memory - out of the DMA's reach, and out of an
    // interrupt's. So everything either of them touches is here instead,
    // internal and on a cache line of its own. On SPI the task makes its
    // own, smaller one when it sets the controller up.
    const line = 64;
    if (sb.slot.spi == 0) {
        const memory = sys_base.AllocMem(@sizeOf(Work) + line, exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse {
            sdk.exec.kprintf(sys_base, "%s: no internal memory for the card's buffers\n", .{DEVICE_NAME});
            if (gb) |taken_from| gpio_resource.freePads(taken_from, slot_pads);
            return null;
        };
        sb.work_memory = memory;
        const aligned = (@intFromPtr(memory) + line - 1) & ~@as(usize, line - 1);
        const work: *Work = @ptrFromInt(aligned);
        work.* = .{};
        sb.work = work;
        work.int = .{
            .node = .{ .type = .interrupt, .pri = 0, .name = DEVICE_NAME },
            .data = sb,
            .code = &intServer,
        };
    }

    const stack = sys_base.AllocMem(stack_size, exec.MEMF_CLEAR) orelse {
        if (sb.work_memory) |memory| sys_base.FreeMem(memory, @sizeOf(Work) + line);
        sb.work_memory = null;
        sb.work = null;
        if (gb) |taken_from| gpio_resource.freePads(taken_from, slot_pads);
        return null;
    };
    sb.stack = stack;
    sb.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };

    const signal = sys_base.AllocSignal(-1);
    if (signal >= 0) {
        sb.starter = sys_base.FindTask(null);
        sb.start_signal = @intCast(signal);
    }
    _ = sys_base.AddTask(&sb.task, &sdTask, null);
    if (signal >= 0) {
        _ = sys_base.Wait(@as(u32, 1) << @intCast(signal));
        sys_base.FreeSignal(@intCast(signal));
    }
    return dev;
}

/// The jump table: the six standard vectors, nothing past AbortIO.
const vectors = [_]*const anyopaque{
    vec(open),
    vec(close),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(SdCardBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// No flags but AUTOINIT: the device is on the disk, in DEVS:, and is
/// made when something opens it - ramlib loads the file and hands this
/// tag to InitResident. The priority orders nothing here.
///
/// It is in `.resident`, which program.ld KEEPs: nothing in the file
/// refers to the tag, whoever loads the file looks for it.
export const sdcard_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &sdcard_device_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = DEVICE_VERSION,
    .pri = 0,
    .type = .device,
    .name = DEVICE_NAME,
    .id_string = DEVICE_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};

/// A device is not a command. Whoever runs this file gets nothing done and
/// a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a device, not a command\n", .{DEVICE_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for. Nothing refers to
/// it, so it needs an export and a section of its own that program.ld
/// KEEPs.
export const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;
