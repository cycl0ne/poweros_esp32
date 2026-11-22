// SPDX-License-Identifier: MIT
//! cyw43455bt.device's worker: a DOS process that sets the controller up,
//! offers it to bluetooth.library, and from then on carries its packets.
//!
//! **The setup** (`setUp`): the line's pins given to the mini UART, the
//! line started at 115200 bit/s with RTS held up, the interrupt hooked,
//! the controller's power taken away and given back (BT_REG_ON low for
//! 50 ms, then high, and 120 ms for it to start), RTS and CTS handed to
//! the hardware.
//! Then, each a command waiting for its answer: HCI_Reset; the line's rate
//! raised to 921600 bit/s, on both ends; the controller asked what it is
//! (Read Local Version Information), which names its patch; the patch
//! from `DEVS:bluetooth/firmware/broadcom/` (broadcom.zig), after which
//! the controller is back at 115200 bit/s and is reset and raised to the
//! working rate again; and the address the board gives it set. Without
//! the file the controller runs the firmware in its ROM, and the log says
//! which file was missing.
//!
//! **Offered either way**: set up, the unit opens and the worker hands it
//! to bluetooth.library (AddBTController); failed, the unit answers
//! IOERR_OPENFAIL, the worker hands it over all the same - the library
//! keeps it on its list as failed - and the worker stops the line, takes
//! the controller's power away and ends.
//!
//! **Packets out**: one write at a time, in the order they came: the
//! interrupt sends its kind byte and its bytes, and the write is answered
//! once the last of them is in the FIFO.
//!
//! **Packets in**: the bytes the interrupt took are put together into
//! packets (h4.zig) and kept, eight at most, until a read takes them,
//! oldest first. While the ring is full the bytes wait in theirs, and
//! once that is full too the line's RTS holds the controller back.

const sdk = @import("sdk");
const exec = sdk.exec;
const timer = sdk.devices.timer;
const hci = sdk.bluetooth.hci;
const hcidev = sdk.devices.hci;
const bluetooth = sdk.bluetooth;
const ExecBase = sdk.interface.exec.ExecBase;
const _bt = @import("_cyw43455bt.zig");
const h4 = @import("h4.zig");
const broadcom = @import("broadcom.zig");
const miniuart = @import("miniuart.zig");
const BtBase = _bt.BtBase;

/// Where the patches are.
const firmware_dir = "DEVS:bluetooth/firmware/broadcom/";
/// How long a command of the setup is given to be answered.
const answer_us: u32 = 2_000_000;
/// How long the controller's power is away, and how long it is given to
/// start once it is back.
const power_off_us: u32 = 50_000;
const power_on_us: u32 = 120_000;
/// What the stack's packets may be: a command up to its 255 bytes of
/// parameters, ACL data up to the longest packet the reads take.
const COMMAND_MAX = hci.HCI_COMMAND_HDR + hci.HCI_MAX_PARAMS;

fn name() [*:0]const u8 {
    return _bt.DEVICE_NAME;
}

// --- the process -----------------------------------------------------------

pub fn workerMain(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const base: *BtBase = @ptrCast(@alignCast(me.user_data orelse return));
    const starter = base.starter orelse return;
    const start_mask = @as(u32, 1) << @intCast(base.start_signal);
    base.starter = null;
    if (!begin(base, me)) {
        // The device is not made, and its base is gone once the starter
        // has the signal: everything of the worker's let go before.
        closeTimer(base);
        sys.Signal(starter, start_mask);
        return;
    }
    base.running = 1;
    sys.Signal(starter, start_mask);
    if (setUp(base)) {
        @atomicStore(u8, &base.ready, 1, .release);
        offer(base);
        serve(base);
    }
    @atomicStore(u8, &base.failed, 1, .release);
    letGo(base);
    offer(base);
    if (base.bt_base) |library| sys.CloseLibrary(@ptrCast(@alignCast(library)));
    base.bt_base = null;
    closeTimer(base);
    base.worker = null;
}

/// The unit's port given the worker's signal, and the worker's timer
/// opened: false without either.
fn begin(base: *BtBase, me: *exec.Task) bool {
    const sys = base.sys_base;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return false;
    base.work_mask = @as(u32, 1) << @intCast(signal);
    sys.Disable();
    base.unit.msg_port.sig_bit = @intCast(signal);
    base.unit.msg_port.sig_task = me;
    base.unit.msg_port.flags = exec.PA_SIGNAL;
    sys.Enable();
    base.worker = me;
    return openTimer(base);
}

fn openTimer(base: *BtBase) bool {
    const sys = base.sys_base;
    const port = sys.CreateMsgPort() orelse return false;
    base.timer_port = port;
    base.timer_io = .{};
    base.timer_io.node.message.reply_port = port;
    base.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &base.timer_io.node, 0) != 0) return false;
    base.timer_open = 1;
    return true;
}

fn closeTimer(base: *BtBase) void {
    const sys = base.sys_base;
    if (base.timer_open != 0) sys.CloseDevice(&base.timer_io.node);
    base.timer_open = 0;
    if (base.timer_port) |port| sys.DeleteMsgPort(port);
    base.timer_port = null;
}

/// `micros` waited.
fn pause(base: *BtBase, micros: u32) void {
    base.timer_io.node.command = timer.TR_ADDREQUEST;
    base.timer_io.time = timer.TimeVal.fromMicros(micros);
    _ = base.sys_base.DoIO(&base.timer_io.node);
}

/// Waited until the interrupt or a request wakes the worker, or `micros`
/// have passed: whether it was woken.
fn waitWork(base: *BtBase, micros: u64) bool {
    const sys = base.sys_base;
    const timer_mask = @as(u32, 1) << @intCast(base.timer_port.?.sig_bit);
    // A time-out taken back leaves its signal set: cleared before each.
    _ = sys.SetSignal(0, timer_mask);
    base.timer_io.node.command = timer.TR_ADDREQUEST;
    base.timer_io.time = timer.TimeVal.fromMicros(micros);
    sys.SendIO(&base.timer_io.node);
    const got = sys.Wait(base.work_mask | timer_mask);
    if (sys.CheckIO(&base.timer_io.node) == null) _ = sys.AbortIO(&base.timer_io.node);
    _ = sys.WaitIO(&base.timer_io.node);
    _ = sys.SetSignal(0, timer_mask);
    return got & base.work_mask != 0;
}

/// The worker's loop once the controller is set up: the opener's
/// requests, the write going out, the bytes in.
fn serve(base: *BtBase) noreturn {
    const sys = base.sys_base;
    while (true) {
        while (sys.GetMsg(&base.unit.msg_port)) |message| request(base, _bt.requestOf(message));
        if (base.sending != null and @atomicLoad(u8, &base.tx_busy, .acquire) == 0) written(base);
        while (true) {
            pump(base);
            if (!deliver(base)) break;
        }
        _ = sys.Wait(base.work_mask);
    }
}

/// The unit offered to bluetooth.library, which is opened for it: set up,
/// the library opens it and brings it up; failed, the library keeps it as
/// failed.
fn offer(base: *BtBase) void {
    const sys = base.sys_base;
    if (base.bt_base == null) {
        base.bt_base = @ptrCast(sys.OpenLibrary(bluetooth.BLUETOOTHNAME, 1));
        if (base.bt_base == null) {
            exec.kprintf(sys, "%s: there is no %s to offer the controller to\n", .{ name(), @as([*:0]const u8, bluetooth.BLUETOOTHNAME) });
            return;
        }
    }
    const result = base.bt_base.?.AddBTController(_bt.OPEN_NAME, 0);
    if (result < 0 and base.failed == 0) {
        exec.kprintf(sys, "%s: bluetooth.library did not take the controller (%ld)\n", .{ name(), @as(i64, result) });
    }
}

// --- the line ------------------------------------------------------------------

/// The interrupts the worker's flags say, set: inside Disable.
fn applyInterrupts(base: *BtBase) void {
    miniuart.setInterrupts(&base.line, base.rx_on != 0, base.tx_on != 0);
}

/// The mini UART's interrupt: the receive FIFO into the ring while it has
/// room, the transmit FIFO filled from the packet going out; the worker
/// woken for either.
pub fn intServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const base: *BtBase = @ptrCast(@alignCast(is_data.?));
    const line = &base.line;
    if (!miniuart.interrupting(line)) return 0;
    var wake = false;
    if (base.rx_on != 0) {
        const buffers = base.buffers.?;
        const out = @atomicLoad(u32, &base.rx_out, .acquire);
        var in = base.rx_in;
        while (miniuart.hasByte(line)) {
            if (in -% out == _bt.RX_BYTES) {
                base.rx_on = 0;
                @atomicStore(u8, &base.rx_held, 1, .release);
                break;
            }
            buffers.rx[in % _bt.RX_BYTES] = miniuart.readByte(line);
            in +%= 1;
        }
        if (in != base.rx_in or base.rx_on == 0) wake = true;
        @atomicStore(u32, &base.rx_in, in, .release);
    }
    if (base.tx_on != 0) {
        const frame = 1 + base.tx_length;
        while (base.tx_at < frame and miniuart.hasRoom(line)) {
            miniuart.writeByte(line, if (base.tx_at == 0) base.tx_kind else base.tx_data.?[base.tx_at - 1]);
            base.tx_at += 1;
        }
        if (base.tx_at == frame) {
            base.tx_on = 0;
            @atomicStore(u8, &base.tx_busy, 0, .release);
            wake = true;
        }
    }
    applyInterrupts(base);
    if (wake) base.sys_base.Signal(base.worker.?, base.work_mask);
    return 1;
}

fn hookInterrupt(base: *BtBase) bool {
    if (base.irq == 0) return false;
    base.interrupt = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = _bt.DEVICE_NAME },
        .data = base,
        .code = &intServer,
    };
    base.sys_base.AddIntServer(base.irq, &base.interrupt);
    base.int_hooked = 1;
    return true;
}

/// A packet sent: its kind byte and `bytes`, which stay where they are
/// until `tx_busy` is clear.
fn send(base: *BtBase, kind: u8, bytes: []const u8) void {
    const sys = base.sys_base;
    sys.Disable();
    defer sys.Enable();
    base.tx_kind = kind;
    base.tx_data = bytes.ptr;
    base.tx_length = bytes.len;
    base.tx_at = 0;
    @atomicStore(u8, &base.tx_busy, 1, .release);
    base.tx_on = 1;
    applyInterrupts(base);
}

/// The bytes the interrupt took put together into packets, and the
/// whole ones into the ring while it has room; the receive interrupt on
/// again once the bytes have room.
fn pump(base: *BtBase) void {
    const sys = base.sys_base;
    const buffers = base.buffers.?;
    const parser = &buffers.parser;
    const in = @atomicLoad(u32, &base.rx_in, .acquire);
    var out = base.rx_out;
    while (true) {
        if (parser.whole) {
            if (!buffers.ring.put(parser.packet_type, parser.packet())) break;
            parser.clear();
        }
        if (out == in) break;
        const start = out % _bt.RX_BYTES;
        const run = @min(in -% out, _bt.RX_BYTES - start);
        out +%= @intCast(parser.take(buffers.rx[start..][0..run]));
    }
    @atomicStore(u32, &base.rx_out, out, .release);
    if (@atomicLoad(u8, &base.rx_held, .acquire) != 0 and in -% out < _bt.RX_BYTES) {
        sys.Disable();
        defer sys.Enable();
        base.rx_held = 0;
        base.rx_on = 1;
        applyInterrupts(base);
    }
}

/// Everything the line had: the FIFOs, the ring, the packet being put
/// together and those waiting.
fn clearLine(base: *BtBase) void {
    const sys = base.sys_base;
    const buffers = base.buffers.?;
    sys.Disable();
    defer sys.Enable();
    miniuart.clearFifos(&base.line);
    base.rx_in = 0;
    base.rx_out = 0;
    base.rx_held = 0;
    buffers.parser.reset();
    buffers.ring.clear();
}

/// The line's rate changed on both ends: the controller told and, once it
/// has answered at the old rate, the mini UART changed.
fn raiseRate(base: *BtBase, baud: u32) bool {
    const params = broadcom.baudParams(baud);
    if (!commandOk(base, broadcom.OP_UPDATE_UART_BAUD_RATE, &params, "the line's rate")) return false;
    base.baud = miniuart.setRate(base.sys_base, &base.line, baud);
    return true;
}

// --- the setup -------------------------------------------------------------------

/// What Command Complete answered `opcode` - its parameters after the
/// opcode, the status first - or Command Status a failure of it, as a
/// status alone: null for another packet.
fn answerOf(slot: *const h4.Ring.Slot, opcode: u16) ?[]const u8 {
    if (slot.packet_type != hcidev.HCI_EVENT_PKT) return null;
    const packet = slot.packet();
    if (packet.len < hci.HCI_EVENT_HDR) return null;
    switch (packet[0]) {
        hci.HCI_EV_COMMAND_COMPLETE => {
            if (packet.len < 6) return null;
            if ((@as(u16, packet[3]) | @as(u16, packet[4]) << 8) != opcode) return null;
            return packet[5..];
        },
        hci.HCI_EV_COMMAND_STATUS => {
            if (packet.len < 6 or packet[2] == 0) return null;
            if ((@as(u16, packet[4]) | @as(u16, packet[5]) << 8) != opcode) return null;
            return packet[2..3];
        },
        else => return null,
    }
}

/// A command sent and its answer waited for: what Command Complete
/// answered - the status first - in the buffers' `answer`, or null when
/// none came in time.
fn exchange(base: *BtBase, opcode: u16, params: []const u8) ?[]const u8 {
    const sys = base.sys_base;
    const buffers = base.buffers.?;
    const command = &buffers.command;
    command[0] = @truncate(opcode);
    command[1] = @truncate(opcode >> 8);
    command[2] = @intCast(params.len);
    @memcpy(command[hci.HCI_COMMAND_HDR..][0..params.len], params);
    send(base, hcidev.HCI_COMMAND_PKT, command[0 .. hci.HCI_COMMAND_HDR + params.len]);
    const until = sys.UptimeUs() + answer_us;
    while (true) {
        pump(base);
        while (buffers.ring.first()) |slot| {
            const found = answerOf(slot, opcode);
            if (found) |answer| {
                @memcpy(buffers.answer[0..answer.len], answer);
                buffers.answer_length = answer.len;
            }
            buffers.ring.drop();
            if (found != null) return buffers.answer[0..buffers.answer_length];
        }
        const time = sys.UptimeUs();
        if (time >= until) return null;
        _ = waitWork(base, until - time);
    }
}

/// A command answered with success: false, and the log says what of the
/// setup failed, when it was not.
fn commandOk(base: *BtBase, opcode: u16, params: []const u8, comptime what: [:0]const u8) bool {
    const sys = base.sys_base;
    const answer = exchange(base, opcode, params) orelse {
        exec.kprintf(sys, "%s: the controller did not answer (" ++ what ++ ", %u bit/s)\n", .{ name(), base.baud });
        return false;
    };
    if (answer.len == 0 or answer[0] != 0) {
        exec.kprintf(sys, "%s: the controller refused a command (" ++ what ++ "): status %u\n", .{ name(), @as(u32, if (answer.len != 0) answer[0] else 0xFF) });
        return false;
    }
    return true;
}

/// What Read Local Version Information answered: the HCI revision and
/// the LMP subversion; null when it did not.
const Version = struct { hci_revision: u16, subversion: u16 };

fn readVersion(base: *BtBase) ?Version {
    if (!commandOk(base, hci.HCI_OP_READ_LOCAL_VERSION, &.{}, "its version")) return null;
    const answer = base.buffers.?.answer[0..base.buffers.?.answer_length];
    // Status, HCI version, HCI revision, LMP version, maker, LMP subversion.
    if (answer.len < 9) return null;
    return .{
        .hci_revision = @as(u16, answer[2]) | @as(u16, answer[3]) << 8,
        .subversion = @as(u16, answer[7]) | @as(u16, answer[8]) << 8,
    };
}

/// A reset, and the pause the controller takes after one.
fn reset(base: *BtBase) bool {
    if (!commandOk(base, hci.HCI_OP_RESET, &.{}, "the reset")) return false;
    pause(base, broadcom.RESET_PAUSE_US);
    return true;
}

/// The controller set up, or false and the log says why.
fn setUp(base: *BtBase) bool {
    const sys = base.sys_base;
    const line = &base.line;
    line.clock_hz = miniuart.coreClock(sys, line) orelse {
        exec.kprintf(sys, "%s: the firmware does not say the core clock the line counts from\n", .{name()});
        return false;
    };
    miniuart.pinsUp(sys, line);
    miniuart.start(sys, line, broadcom.START_BAUD);
    base.baud = miniuart.rateOf(line.clock_hz, miniuart.divisor(line.clock_hz, broadcom.START_BAUD));
    if (!hookInterrupt(base)) {
        exec.kprintf(sys, "%s: the board gives the line no interrupt\n", .{name()});
        return false;
    }
    if (!miniuart.power(sys, line, false)) {
        exec.kprintf(sys, "%s: the firmware did not switch the controller's power\n", .{name()});
        return false;
    }
    pause(base, power_off_us);
    if (!miniuart.power(sys, line, true)) {
        exec.kprintf(sys, "%s: the firmware did not switch the controller's power\n", .{name()});
        return false;
    }
    pause(base, power_on_us);
    clearLine(base);
    {
        sys.Disable();
        defer sys.Enable();
        base.rx_on = 1;
        applyInterrupts(base);
    }
    miniuart.flowOn(line);
    if (!reset(base)) {
        exec.kprintf(sys, "%s: the controller's RTS is %s, the transmitter %s\n", .{
            name(),
            @as([*:0]const u8, if (miniuart.ctsAsserted(line)) "down: it takes bytes" else "up: it takes none"),
            @as([*:0]const u8, if (miniuart.txIdle(line)) "idle" else "holding bytes"),
        });
        return false;
    }
    if (!raiseRate(base, _bt.WORK_BAUD)) return false;
    const first = readVersion(base) orelse return false;
    const chip = broadcom.chipName(first.subversion);
    describeChip(base, chip);
    if (chip) |chip_name| {
        switch (patch(base, chip_name)) {
            .failed => return false,
            .none => {},
            .loaded => {
                // The controller starts its patch at the rate it started
                // at; whatever came while the two rates differed is
                // dropped.
                base.baud = miniuart.setRate(sys, line, broadcom.START_BAUD);
                clearLine(base);
                if (!reset(base)) return false;
                if (!raiseRate(base, _bt.WORK_BAUD)) return false;
                const patched = readVersion(base) orelse return false;
                describePatch(base, chip_name, patched.hci_revision);
            },
        }
    } else {
        exec.kprintf(sys, "%s: no patch is known for the controller's LMP subversion %04x\n", .{ name(), @as(u32, first.subversion) });
    }
    if (!allZero(&base.address)) {
        if (!commandOk(base, broadcom.OP_WRITE_BD_ADDR, &base.address, "its address")) return false;
    } else {
        exec.kprintf(sys, "%s: the board gives the controller no address; it keeps its maker's\n", .{name()});
    }
    exec.kprintf(sys, "%s: the %s is set up, %u bit/s\n", .{ name(), @as([*:0]const u8, @ptrCast(&base.chip)), base.baud });
    return true;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

/// What HCICMD_QUERY says of the chip: the board's part, and the
/// controller's name for itself where it is known.
fn describeChip(base: *BtBase, chip: ?[]const u8) void {
    var at = broadcom.text(&base.chip, 0, "Infineon CYW43455");
    if (chip) |chip_name| {
        at = broadcom.text(&base.chip, at, " (");
        at = broadcom.text(&base.chip, at, chip_name);
        at = broadcom.text(&base.chip, at, ")");
    }
    base.chip[@min(at, base.chip.len - 1)] = 0;
}

/// What HCICMD_QUERY says of the patch: its file, and the build the
/// controller runs now.
fn describePatch(base: *BtBase, chip: []const u8, hci_revision: u16) void {
    var file: [32]u8 = undefined;
    const length = broadcom.fileName(&file, chip);
    var at = broadcom.text(&base.firmware, 0, file[0..length]);
    at = broadcom.text(&base.firmware, at, " (build ");
    at = broadcom.decimal(&base.firmware, at, broadcom.build(hci_revision), 4);
    at = broadcom.text(&base.firmware, at, ")");
    base.firmware[@min(at, base.firmware.len - 1)] = 0;
}

const Patched = enum { loaded, none, failed };

/// The chip's patch from its file: loaded, none (the file is not there:
/// the controller runs what is in its ROM), or failed.
fn patch(base: *BtBase, chip: []const u8) Patched {
    const sys = base.sys_base;
    var path: [firmware_dir.len + 32:0]u8 = @splat(0);
    @memcpy(path[0..firmware_dir.len], firmware_dir);
    const length = broadcom.fileName(path[firmware_dir.len..], chip);
    if (length == 0) return .none;
    var size: usize = 0;
    const bytes = base.dos_base.?.ReadFile(&path, ~@as(usize, 0), exec.MEMF_ANY, &size) orelse {
        exec.kprintf(sys, "%s: no %s: the controller runs the firmware in its ROM\n", .{ name(), @as([*:0]const u8, &path) });
        return .none;
    };
    defer sys.FreeVec(bytes);
    const file = bytes[0..size];
    const records_count = broadcom.Records.count(file) catch {
        exec.kprintf(sys, "%s: %s is damaged\n", .{ name(), @as([*:0]const u8, &path) });
        return .failed;
    };
    if (!commandOk(base, broadcom.OP_DOWNLOAD_MINIDRIVER, &.{}, "the patch's start")) return .failed;
    pause(base, broadcom.MINIDRIVER_PAUSE_US);
    var records = broadcom.Records{ .file = file };
    while (records.next() catch null) |record| {
        if (!commandOk(base, record.opcode, record.params, "the patch")) return .failed;
    }
    pause(base, broadcom.LAUNCH_PAUSE_US);
    exec.kprintf(sys, "%s: %s given, %u commands\n", .{ name(), @as([*:0]const u8, &path), records_count });
    return .loaded;
}

/// The line stopped, the interrupt unhooked and the controller's power
/// taken away: the setup failed.
fn letGo(base: *BtBase) void {
    const sys = base.sys_base;
    {
        sys.Disable();
        defer sys.Enable();
        base.rx_on = 0;
        base.tx_on = 0;
        if (base.line.regs != 0 and base.line.clock_hz != 0) miniuart.stop(&base.line);
    }
    if (base.int_hooked != 0) sys.RemIntServer(base.irq, &base.interrupt);
    base.int_hooked = 0;
    if (base.line.clock_hz != 0) _ = miniuart.power(sys, &base.line, false);
}

// --- the opener's requests ---------------------------------------------------------

fn answerIO(base: *BtBase, io: *exec.IORequest, failure: i8) void {
    io.err = failure;
    base.sys_base.ReplyIO(io);
}

/// A request the worker took from the unit's port.
fn request(base: *BtBase, io: *exec.IORequest) void {
    const sys = base.sys_base;
    io.message.node.type = .message;
    switch (io.command) {
        exec.CMD_READ => {
            sys.Disable();
            sys.AddTail(&base.reads, &io.message.node);
            sys.Enable();
            _ = deliver(base);
        },
        exec.CMD_WRITE => {
            const req = _bt.hciReq(io);
            const length = req.std.length;
            const fits = switch (req.packet_type) {
                hcidev.HCI_COMMAND_PKT => length >= hci.HCI_COMMAND_HDR and length <= COMMAND_MAX,
                hcidev.HCI_ACLDATA_PKT => length >= hci.HCI_ACL_HDR and length <= h4.MAX_PACKET,
                else => false,
            };
            if (!fits or req.std.data == null) return answerIO(base, io, hcidev.HCIERR_PACKET);
            sys.Disable();
            sys.AddTail(&base.writes, &io.message.node);
            sys.Enable();
            sendNext(base);
        },
        exec.CMD_FLUSH => {
            flushReads(base, exec.IOERR_ABORTED);
            answerIO(base, io, 0);
        },
        else => answerIO(base, io, exec.IOERR_NOCMD),
    }
}

/// Every read waiting answered with `failure`.
fn flushReads(base: *BtBase, failure: i8) void {
    const sys = base.sys_base;
    while (true) {
        sys.Disable();
        const node = sys.RemHead(&base.reads);
        sys.Enable();
        const taken = node orelse return;
        const message: *exec.Message = @fieldParentPtr("node", taken);
        answerIO(base, _bt.requestOf(message), failure);
    }
}

/// The packets waiting handed to the reads waiting, oldest to oldest; a
/// read too short for its packet is answered HCIERR_TOOLONG and the
/// packet kept. Whether a packet was handed on, which makes room for the
/// bytes behind it.
fn deliver(base: *BtBase) bool {
    const sys = base.sys_base;
    const buffers = base.buffers.?;
    var handed = false;
    while (buffers.ring.first()) |slot| {
        sys.Disable();
        const node = sys.RemHead(&base.reads);
        sys.Enable();
        const taken = node orelse break;
        const message: *exec.Message = @fieldParentPtr("node", taken);
        const io = _bt.requestOf(message);
        const req = _bt.hciReq(io);
        const packet = slot.packet();
        req.packet_type = slot.packet_type;
        req.std.actual = packet.len;
        if (req.std.length < packet.len or req.std.data == null) {
            answerIO(base, io, hcidev.HCIERR_TOOLONG);
            continue;
        }
        const into: [*]u8 = @ptrCast(req.std.data.?);
        @memcpy(into[0..packet.len], packet);
        answerIO(base, io, 0);
        buffers.ring.drop();
        handed = true;
    }
    return handed;
}

/// The first write waiting sent, if none is going out.
fn sendNext(base: *BtBase) void {
    const sys = base.sys_base;
    if (base.sending != null) return;
    sys.Disable();
    const node = sys.RemHead(&base.writes);
    sys.Enable();
    const taken = node orelse return;
    const message: *exec.Message = @fieldParentPtr("node", taken);
    const io = _bt.requestOf(message);
    base.sending = io;
    const req = _bt.hciReq(io);
    const data: [*]const u8 = @ptrCast(req.std.data.?);
    send(base, req.packet_type, data[0..req.std.length]);
}

/// The write going out is all in the FIFO: answered, and the next sent.
fn written(base: *BtBase) void {
    const io = base.sending orelse return;
    base.sending = null;
    _bt.hciReq(io).std.actual = _bt.hciReq(io).std.length;
    answerIO(base, io, 0);
    sendNext(base);
}
