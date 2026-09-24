// SPDX-License-Identifier: MIT
//! sd.device: the card in the board's slot as a block device. Unit 0 is
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
//! **Every command runs on the device's own task.** A transfer waits for
//! the controller's interrupt, and BeginIO may be called from anywhere -
//! including from a caller that must not wait. So BeginIO checks what it
//! can and queues the rest - TD_CHANGESTATE on an empty slot included,
//! since only speaking to the slot finds a card put in since -
//! as flash.device does; unlike flash.device the
//! stack may be anywhere, because nothing here suspends a cache.
//!
//! **What the DMA can reach.** The controller's DMA reaches internal
//! memory only, and a caller's buffer is usually external, so every
//! transfer passes through the buffer in `_sd.zig`'s work block. A
//! transfer longer than that buffer is done in rounds of it.
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
const card = @import("card.zig");
const _sd = @import("_sd.zig");
const SdBase = _sd.SdBase;
const Work = _sd.Work;

pub const DEVICE_NAME = _sd.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "23.9.2026";
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
    const sb: *SdBase = @ptrCast(@alignCast(is_data.?));
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
fn saidSoFar(sb: *SdBase) struct { status: u32, dma: u32 } {
    const sys = sb.sys_base;
    const work = sb.work.?;
    sys.Disable();
    defer sys.Enable();
    return .{ .status = work.status, .dma = work.dma_status };
}

/// A clean slate before a command. The controller's own bits and what
/// the server has collected are dropped together: an interrupt between
/// the two would leave the next command reading the last one's answer.
fn forgetStatus(sb: *SdBase) void {
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

fn portMask(sb: *SdBase) u32 {
    return sb.port.?.sigMask();
}

/// `us` microseconds on the timer, as a deadline to wait against.
fn armDeadline(sb: *SdBase, us: u32) void {
    sb.timer_io.node.command = timer.TR_ADDREQUEST;
    sb.timer_io.time = timer.TimeVal.fromMicros(us);
    sb.sys_base.SendIO(&sb.timer_io.node);
}

fn dropDeadline(sb: *SdBase) void {
    const sys = sb.sys_base;
    _ = sys.AbortIO(&sb.timer_io.node);
    _ = sys.WaitIO(&sb.timer_io.node);
}

/// Until every bit of `want` has been said, or something went wrong, or
/// the deadline passed. A deadline that passes is reported as a card that
/// did not answer, because that is what it means: nothing came back.
fn waitFor(sb: *SdBase, want: u32, us: u32) card.Fault {
    const sys = sb.sys_base;
    armDeadline(sb, us);
    defer dropDeadline(sb);
    while (true) {
        const said = saidSoFar(sb);
        const fault = _sd.faultOf(said.status, said.dma);
        if (fault.any()) return fault;
        if (said.status & want == want) return .{};
        const got = sys.Wait(sb.int_mask | portMask(sb));
        if (got & portMask(sb) != 0 and sys.CheckIO(&sb.timer_io.node) != null) {
            return .{ .no_answer = true };
        }
    }
}

/// `us` microseconds, waited out.
fn delay(sb: *SdBase, us: u32) void {
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
    sb: *SdBase,
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
    var answer = Answer{ .fault = waitFor(sb, want, _sd.command_timeout_us) };
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
fn waitIdle(sb: *SdBase) void {
    _ = sb;
    var spins: u32 = 0;
    while (sdmmc.busy() and spins < 2_000_000) spins += 1;
}

/// A command the card only listens to after APP_CMD.
fn appCommand(
    sb: *SdBase,
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

fn say(sb: *SdBase, what: [*:0]const u8) void {
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
fn identify(sb: *SdBase) bool {
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
    while (waited < _sd.identify_timeout_us) : (waited += 10_000) {
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
fn readRegister(sb: *SdBase, index: u32, bytes: u32) ?[]const u8 {
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
fn layChain(sb: *SdBase, bytes: u32) *sdmmc.Descriptor {
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
fn transfer(sb: *SdBase, way: sdmmc.Direction, block: u64, count: u32, bytes: [*]u8) i8 {
    const work = sb.work.?;
    var done: u32 = 0;
    while (done < count) {
        const piece = @min(count - done, _sd.chunk_blocks);
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

/// The card stopped answering. Whatever it was is gone; the next command
/// looks for one afresh, and the change count tells a handler its locks
/// are worthless.
fn lost(sb: *SdBase) void {
    if (sb.present == 0) return;
    sb.present = 0;
    sb.change_num +%= 1;
    say(sb, "the card stopped answering");
}

/// A card in the slot, identified if it has not been already. False if
/// the slot is empty or the card cannot be used.
fn ready(sb: *SdBase) bool {
    if (sb.present != 0) return true;
    if (!sdmmc.cardPresent()) return false;
    // The reset puts the controller's interrupt gates back where they
    // start, so what this device wants raised has to be said again.
    sdmmc.reset();
    sdmmc.interruptsOn(sdmmc.int_wanted, sdmmc.dma_int_wanted);
    if (!identify(sb)) return false;
    sb.present = 1;
    sb.change_num +%= 1;
    report(sb);
    return true;
}

fn report(sb: *SdBase) void {
    const sys = sb.sys_base;
    var name: [6]u8 = @splat(0);
    @memcpy(name[0..5], &sb.card.cid.name);
    sdk.exec.kprintf(sys, "%s: %s, %ld MB, %d bits at %d kHz\n", .{
        DEVICE_NAME,
        @as([*:0]const u8, @ptrCast(&name)),
        sb.card.bytes() / (1024 * 1024),
        @as(u32, if (sb.card.wide) 4 else 1),
        sb.card.clock_hz / 1000,
    });
}

// --- the task -------------------------------------------------------------

/// Every command that talks to the card. The port is given its signal
/// before the first message is taken, so a request that arrived while the
/// device was starting is not missed.
fn sdTask(sys: *ExecBase) callconv(.c) void {
    const sb: *SdBase = @fieldParentPtr("task", sys.FindTask(null).?);
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
                const io = _sd.requestOf(msg);
                if (io.command == td.TD_CHANGESTATE) {
                    _sd.stdReq(io).actual = 1;
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
            const io = _sd.requestOf(msg);
            slowIO(sb, io);
            sys.ReplyIO(io);
        }
        _ = sys.Wait(queue_port.sigMask());
    }
}

/// The init is waiting to hear that the task is ready for requests.
fn started(sb: *SdBase) void {
    sb.started = 1;
    if (sb.starter) |starter| {
        const bit: u5 = @intCast(sb.start_signal);
        sb.starter = null;
        sb.sys_base.Signal(starter, @as(u32, 1) << bit);
    }
}

/// The task's own port and timer, the controller and its interrupt. False
/// if there is no controller here.
fn setUp(sb: *SdBase) bool {
    const sys = sb.sys_base;

    const int_signal = sys.AllocSignal(-1);
    if (int_signal < 0) return false;
    sb.int_mask = @as(u32, 1) << @intCast(int_signal);

    sb.port = sys.CreateMsgPort() orelse return false;
    sb.timer_io = .{};
    sb.timer_io.node.message.reply_port = sb.port;
    sb.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &sb.timer_io.node, 0) != 0) return false;

    const slot = sb.slot;
    if (!sdmmc.init(.{
        .clock = slot.clock,
        .command = slot.command,
        .data = slot.data,
        .detect = if (slot.detect == _sd.no_pin) null else slot.detect,
        .write_protect = if (slot.write_protect == _sd.no_pin) null else slot.write_protect,
    })) {
        say(sb, "no SD host controller on this machine");
        return false;
    }

    sys.AddIntServer(intbits.INTB_SDIO_HOST, &sb.work.?.int);
    sb.hooked = 1;
    sdmmc.interruptsOn(sdmmc.int_wanted, sdmmc.dma_int_wanted);

    return true;
}

/// The commands that talk to the card. On the task, so they may wait.
fn slowIO(sb: *SdBase, io: *exec.IORequest) void {
    const req = _sd.stdReq(io);
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
            if (!_sd.inside(sb, req.offset, req.length)) {
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
            if (!_sd.inside(sb, req.offset, req.length)) {
                io.err = exec.IOERR_BADADDRESS;
            } else if (sb.card.readOnly() or sdmmc.writeProtected()) {
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
                _sd.geometry(sb, @ptrCast(@alignCast(data)));
            } else {
                io.err = exec.IOERR_BADADDRESS;
            }
        },
        td.TD_GETNUMTRACKS => req.actual = @intCast(sb.card.csd.blocks),
        td.TD_PROTSTATUS => req.actual = if (sb.card.readOnly() or sdmmc.writeProtected()) 1 else 0,
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
fn queue(sb: *SdBase, io: *exec.IORequest) void {
    if (!canWait(io)) return sb.sys_base.ReplyIO(io);
    io.flags &= ~exec.IOF_QUICK;
    sb.sys_base.PutMsg(&sb.unit.msg_port, &io.message);
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    _ = dev;
    const sb = _sd.baseOf(io);
    const req = _sd.stdReq(io);
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
    const sb = _sd.sdBase(dev);
    const sys = sb.sys_base;
    sys.Disable();
    defer sys.Enable();
    var it = sb.unit.msg_port.msg_list.iterator();
    while (it.next()) |n| {
        const msg: *exec.Message = @fieldParentPtr("node", n);
        if (_sd.requestOf(msg) != io) continue;
        sys.Remove(n);
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
        return 0;
    }
    return -1;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const sb = _sd.sdBase(dev);
    if (unit_number != 0) return td.TDERR_BadUnitNum;
    // The slot opens whether or not a card is in it: a handler that sits
    // on it has to be there before the card is, and finds out by asking.
    if (sb.work == null or sb.hooked == 0) return exec.IOERR_OPENFAIL;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    sb.unit.open_cnt += 1;
    io.unit = &sb.unit;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const sb = _sd.baseOf(io);
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

/// Every pad the slot has, in `into`: its clock, command and data lines,
/// and its card-detect and write-protect where it has them.
fn slotPads(slot: _sd.Slot, into: *[8]u8) []const u8 {
    into[0] = slot.clock;
    into[1] = slot.command;
    for (slot.data, 0..) |data_pad, line| into[2 + line] = data_pad;
    var count: usize = 6;
    for ([_]u8{ slot.detect, slot.write_protect }) |sense_pad| {
        if (sense_pad == _sd.no_pin) continue;
        into[count] = sense_pad;
        count += 1;
    }
    return into[0..count];
}

/// Which pads are the slot's: expansion.library's card-slot part, whose
/// tags say where each line is. A board without a slot - or with one this
/// driver cannot run - leaves `has_slot` clear, and there is no device.
fn findSlot(sb: *SdBase) void {
    const sys = sb.sys_base;
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_SDSLOT, st.CHIP_ANY) orelse return;
    const tags = part.tags;

    // Every line the host drives is a pad of the chip; a slot wired some
    // other way - its chip select on an expander, say - is not one this
    // driver can run.
    var slot: _sd.Slot = .{};
    slot.clock = pad(ub, st.PART_PinClock, tags) orelse return;
    slot.command = pad(ub, st.PART_PinCommand, tags) orelse return;
    const data_tags = [4]sdk.utility.Tag{ st.PART_PinData0, st.PART_PinData1, st.PART_PinData2, st.PART_PinData3 };
    for (data_tags, 0..) |tag, line| slot.data[line] = pad(ub, tag, tags) orelse return;
    slot.detect = pad(ub, st.PART_PinDetect, tags) orelse _sd.no_pin;
    slot.write_protect = pad(ub, st.PART_PinWriteProtect, tags) orelse _sd.no_pin;
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
    const sb = _sd.sdBase(dev);
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
    if (!sdmmc.present()) {
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
    // internal and on a cache line of its own.
    const line = 64;
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

    const stack = sys_base.AllocMem(stack_size, exec.MEMF_CLEAR) orelse {
        sys_base.FreeMem(memory, @sizeOf(Work) + line);
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
    .data_size = @sizeOf(SdBase),
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
export const sd_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &sd_device_tag,
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
