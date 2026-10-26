// SPDX-License-Identifier: MIT
//! The JH7110's crypto engine (CHIP_JH7110_CRYPTO, the VisionFive 2): AES
//! in ECB, CBC, CTR and GCM over a whole buffer at once, fed and emptied
//! by two of dma.resource's PL080 channels - not a block at a time through
//! registers, as the S3's engine in `aes.zig` is.
//!
//! The data goes through two buffers of the library's, `room` bytes each
//! and below 4 GiB, as the PL080 needs: the caller copies its input into
//! `State.input`, the engine leaves its output in `State.output`, and the
//! caller copies it from there - GCM's opening only once the tag is
//! right. A longer message is the caller's to split (UpdateCipher) or to
//! leave to software (GCM). `give` clears both buffers.
//!
//! The first call that wants the engine sets it up: the engine and the
//! PL080 found among the board's parts, two channels taken from
//! dma.resource, the buffers allocated, timer.device opened and a server
//! put on the PL080's interrupt. A board without the engine, a set-up
//! that fails, and an engine that once stops answering leave the work to
//! software: the security block shares its reset with the TRNG and the
//! PL080, so the library does not reset it.
//!
//! A short run is waited for by watching the channels; a long one by
//! sleeping until the interrupt, with a second of timer.device as the
//! limit.
//!
//! After Linux's jh7110-aes.c - the registers, and the order they are
//! written in - and what the board measured: 50 MB/s through AES-CTR or
//! GCM, against 2.6 MB/s for the software AES.

const sdk = @import("sdk");
const exec = sdk.exec;
const hardware = sdk.hardware;
const timer = sdk.devices.timer;
const dmares = sdk.resources.dma;
const st = sdk.expansion.systemtags;
const ExecBase = sdk.interface.exec.ExecBase;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _engine = @import("_engine.zig");

/// Whether this chip can have the engine: the RISC-V 64 boards, of which
/// the board's parts say whether this one does.
pub const compiled = hardware.chip == .rv64sbi;
const pl080 = hardware.pl080;
const reg = hardware.mmio.reg;

/// Bytes each buffer holds: an SMB message of 64 KiB and its headers, a
/// TLS record, an SSH packet.
pub const room: u32 = 68 * 1024;
/// The least whole-block data the engine is worth starting for: below,
/// the software AES is as quick.
pub const least: u32 = 64;
/// A run this long or longer sleeps until the interrupt; a shorter one is
/// watched.
const wait_bytes: u32 = 16 * 1024;

const status_unknown: u32 = 0;
const status_ready: u32 = 1;
const status_absent: u32 = 2;

/// The engine's state, in the library's base. Everything but `status`
/// is set up once, and touched only by the caller holding `aes_lock`, or
/// by the interrupt server.
pub const State = extern struct {
    /// status_unknown until the first call looks; then status_ready, or
    /// status_absent for good.
    status: u32 = status_unknown,
    /// The engine's registers and the PL080's.
    regs: usize = 0,
    pl: usize = 0,
    /// The PL080's channels the engine is fed by and emptied by, as
    /// dma.resource numbers them and as the controller does.
    units: [2]u32 = .{ 0, 0 },
    tx: u32 = 0,
    rx: u32 = 0,
    int_number: u32 = 0,
    dma_base: ?*dmares.DmaBase = null,
    /// The allocation, and the buffers and lists in it, on cache lines.
    block: ?*anyopaque = null,
    in: usize = 0,
    out: usize = 0,
    tx_items: usize = 0,
    rx_items: usize = 0,
    /// The most bytes of the buffers a caller used since `take`.
    used: u32 = 0,
    /// What the server saw of a run: the channels that finished (1 the
    /// feeding one, 2 the emptying one), and whether one failed.
    finished: u32 = 0,
    failed: u32 = 0,
    /// The task sleeping until a run ends, and its signal; null when none
    /// is.
    waiter: ?*exec.Task = null,
    signals: u32 = 0,
    server: exec.Interrupt = .{},
    /// The time limit's request, and its port, which takes the waiter's
    /// task and signal for each run.
    port: exec.MsgPort = .{},
    clock: timer.TimeRequest = .{},

    pub fn input(state: *State) []u8 {
        const bytes: [*]u8 = @ptrFromInt(state.in);
        return bytes[0..room];
    }

    pub fn output(state: *State) []u8 {
        const bytes: [*]u8 = @ptrFromInt(state.out);
        return bytes[0..room];
    }
};

// The engine's registers: the common ones, AES's from 0x100.
const ALG_CR = 0x0;
const ALG_FIFO = 0x4;
const DMA_IN_LEN = 0x10;
const DMA_OUT_LEN = 0x14;
const AES_KEY0 = 0x104;
const AES_CSR = 0x124;
const AES_IV0 = 0x128;
/// GCM's tag comes out here.
const AES_NONCE0 = 0x13C;
const AES_ALEN0 = 0x14C;
const AES_ALEN1 = 0x150;
const AES_MLEN0 = 0x154;
const AES_MLEN1 = 0x158;
const AES_IVLEN = 0x15C;

const ALG_START: u32 = 1 << 0;
const ALG_AES_DMA: u32 = 1 << 1;
const ALG_CLEAR: u32 = 1 << 8;

/// AES_CSR: decrypt (bit 0), the key's length (1-2), busy, the key
/// ready, the unit's reset, the mode (9-11), GCM's start and done.
const CSR_DECRYPT: u32 = 1 << 0;
const CSR_KEYMODE_SHIFT: u5 = 1;
const CSR_BUSY: u32 = 1 << 3;
const CSR_KEY_READY: u32 = 1 << 5;
const CSR_RESET: u32 = 1 << 6;
const CSR_MODE_SHIFT: u5 = 9;
const CSR_GCM_START: u32 = 1 << 12;
const CSR_GCM_DONE: u32 = 1 << 13;

/// The modes the engine runs, as AES_CSR numbers them.
pub const Mode = enum(u32) { ecb = 0, cbc = 1, ctr = 4, gcm = 6 };

/// The engine's request lines on the PL080 (Linux's device tree), and
/// the bursts its FIFO takes.
const REQUEST_RX: u32 = 0;
const REQUEST_TX: u32 = 1;

const line = hardware.DCACHE_LINE_SIZE;
const list_items = pl080.itemsFor(room, .word);
const list_bytes = list_items * @sizeOf(pl080.Item);
const allocation = 2 * room + 2 * list_bytes + line;

inline fn read(state: *const State, offset: usize) u32 {
    return reg(state.regs + offset).*;
}

inline fn write(state: *const State, offset: usize, value: u32) void {
    reg(state.regs + offset).* = value;
}

/// A register bit waited for, a bounded number of reads.
fn waitFor(state: *const State, offset: usize, mask: u32, set: bool) bool {
    var reads: u32 = 0;
    while (reads < 2_000_000) : (reads += 1) {
        if ((read(state, offset) & mask != 0) == set) return true;
    }
    return false;
}

/// The engine for one call, set up the first time: null on a board
/// without it, or once it has stopped answering, and the caller does the
/// work in software. Given back with `give`.
pub fn take(cb: *CryptoBase) ?*State {
    if (comptime !compiled) return null;
    const state = &cb.sec;
    if (@atomicLoad(u32, &state.status, .acquire) == status_absent) return null;
    const sys = cb.sys_base;
    sys.ObtainSemaphore(&cb.aes_lock);
    if (state.status == status_unknown) {
        @atomicStore(u32, &state.status, if (setUp(cb)) status_ready else status_absent, .release);
    }
    if (state.status != status_ready) {
        sys.ReleaseSemaphore(&cb.aes_lock);
        return null;
    }
    state.used = 0;
    return state;
}

/// The engine given back, and what the call left in the buffers cleared.
pub fn give(cb: *CryptoBase, state: *State) void {
    if (state.used != 0) {
        const used = state.used;
        for ([_][]u8{ state.input()[0..used], state.output()[0..used] }) |bytes| {
            @memset(bytes, 0);
            asm volatile ("" ::: .{ .memory = true });
        }
    }
    cb.sys_base.ReleaseSemaphore(&cb.aes_lock);
}

/// The engine's address from the board's part, or null.
fn findEngine(sys: *ExecBase) ?usize {
    const utility_lib = sys.OpenLibrary(sdk.utility.UTILITYNAME, 0) orelse return null;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return null;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_CRYPTO, st.CHIP_JH7110_CRYPTO) orelse return null;
    const address = ub.GetTagData(st.PART_Address, 0, part.tags);
    return if (address == 0) null else address;
}

/// Everything the engine needs taken, or nothing and false.
fn setUp(cb: *CryptoBase) bool {
    const sys = cb.sys_base;
    const state = &cb.sec;
    state.regs = findEngine(sys) orelse return false;
    const controller = pl080.find() orelse return false;
    state.pl = controller.base;
    const db: *dmares.DmaBase = @ptrCast(@alignCast(sys.OpenResource(dmares.DMANAME) orelse return false));
    var got: usize = 0;
    var unit: u32 = dmares.PL080_CHANNEL0;
    while (unit < dmares.DMA_ALL_CHANNELS and got < 2) : (unit += 1) {
        if (db.AllocDMAChannel(unit, sdk.crypto.CRYPTONAME) == null) {
            state.units[got] = unit;
            got += 1;
        }
    }
    if (got < 2) {
        for (state.units[0..got]) |taken| db.FreeDMAChannel(taken);
        return false;
    }
    state.dma_base = db;
    state.tx = state.units[0] - dmares.PL080_CHANNEL0;
    state.rx = state.units[1] - dmares.PL080_CHANNEL0;
    state.int_number = dmares.dmaIntNumber(state.units[0], dmares.DMA_IN);

    const block = sys.AllocVec(allocation, exec.MEMF_DMA | exec.MEMF_CLEAR) orelse return giveChannels(state);
    state.block = block;
    const first = (@intFromPtr(block) + line - 1) & ~@as(usize, line - 1);
    state.in = first;
    state.out = first + room;
    state.tx_items = first + 2 * room;
    state.rx_items = state.tx_items + list_bytes;

    state.port.msg_list.init(.message);
    state.clock.node.message.node.type = .replymsg;
    state.clock.node.message.reply_port = &state.port;
    state.clock.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(timer.TIMERNAME, timer.UNIT_MICROHZ, &state.clock.node, 0) != 0) {
        sys.FreeVec(block);
        state.block = null;
        return giveChannels(state);
    }
    state.server = .{
        .node = .{ .type = .interrupt, .name = sdk.crypto.CRYPTONAME },
        .data = state,
        .code = exec.vec(server),
    };
    sys.AddIntServer(state.int_number, &state.server);
    return true;
}

fn giveChannels(state: *State) bool {
    const db = state.dma_base.?;
    for (state.units) |unit| db.FreeDMAChannel(unit);
    state.dma_base = null;
    return false;
}

/// Everything set up given back: the library's expunge.
pub fn stop(cb: *CryptoBase) void {
    if (comptime !compiled) return;
    const state = &cb.sec;
    if (state.block == null) return;
    const sys = cb.sys_base;
    sys.RemIntServer(state.int_number, &state.server);
    sys.CloseDevice(&state.clock.node);
    pl080.stop(state.pl, state.tx);
    pl080.stop(state.pl, state.rx);
    sys.FreeVec(state.block);
    state.block = null;
    _ = giveChannels(state);
}

/// The PL080's interrupt, shared by its channels: the engine's two
/// asked, what they raised it for noted, and once both have finished, or
/// one failed, the waiter woken.
fn server(data: ?*anyopaque, _: u32) callconv(.c) i32 {
    const state: *State = @ptrCast(@alignCast(data.?));
    const tx = pl080.raised(state.pl, state.tx);
    const rx = pl080.raised(state.pl, state.rx);
    if (tx == .nothing and rx == .nothing) return 0;
    const finished = @atomicLoad(u32, &state.finished, .acquire) |
        @as(u32, @intFromBool(tx == .finished)) | @as(u32, @intFromBool(rx == .finished)) << 1;
    @atomicStore(u32, &state.finished, finished, .release);
    const failed = tx == .failed or rx == .failed;
    if (failed) @atomicStore(u32, &state.failed, 1, .release);
    if (!failed and finished != 3) return 1;
    if (@atomicLoad(?*exec.Task, &state.waiter, .acquire)) |task| {
        const cb: *CryptoBase = @fieldParentPtr("sec", state);
        cb.sys_base.Signal(task, state.signals);
    }
    return 1;
}

fn busy(state: *const State) bool {
    return pl080.running(state.pl, state.tx) or pl080.running(state.pl, state.rx);
}

/// The engine let go after a failure, for good.
fn broken(state: *State) bool {
    @atomicStore(u32, &state.status, status_absent, .release);
    return false;
}

/// `length` bytes (whole words) of the input buffer through the engine,
/// set up for them, into the output buffer. False when a channel failed
/// or the run took longer than a second: the engine is left alone from
/// then on.
fn run(cb: *CryptoBase, state: *State, length: u32) bool {
    const sys = cb.sys_base;
    const fifo = state.regs + ALG_FIFO;
    const tx_items: [*]pl080.Item = @ptrFromInt(state.tx_items);
    const rx_items: [*]pl080.Item = @ptrFromInt(state.rx_items);
    _ = pl080.fill(tx_items[0..list_items], .{ .address = state.in, .burst = .thirty_two }, .{ .address = fifo, .step = false, .master = 1, .burst = .thirty_two }, length, 0) orelse return broken(state);
    _ = pl080.fill(rx_items[0..list_items], .{ .address = fifo, .step = false, .master = 1 }, .{ .address = state.out }, length, 0) orelse return broken(state);
    var bytes: u32 = length;
    _ = sys.CachePreDMA(@ptrFromInt(state.in), &bytes, exec.DMAF_ReadFromRAM);
    bytes = 2 * list_bytes;
    _ = sys.CachePreDMA(@ptrFromInt(state.tx_items), &bytes, exec.DMAF_ReadFromRAM);
    bytes = length;
    _ = sys.CachePreDMA(@ptrFromInt(state.out), &bytes, 0);

    write(state, ALG_CR, ALG_START | ALG_AES_DMA);
    write(state, DMA_IN_LEN, length);
    write(state, DMA_OUT_LEN, length);
    const bit: i8 = if (length >= wait_bytes) sys.AllocSignal(-1) else -1;
    var good: bool = undefined;
    if (bit >= 0) {
        const task = sys.FindTask(null).?;
        const mask = @as(u32, 1) << @intCast(bit);
        state.finished = 0;
        state.failed = 0;
        state.signals = mask;
        state.port.sig_task = task;
        state.port.sig_bit = @intCast(bit);
        @atomicStore(?*exec.Task, &state.waiter, task, .release);
        state.clock.node.command = timer.TR_ADDREQUEST;
        state.clock.time = timer.TimeVal.fromMicros(1_000_000);
        sys.SendIO(&state.clock.node);
        pl080.start(state.pl, state.rx, rx_items, .peripheral_to_memory, REQUEST_RX, 0, true);
        pl080.start(state.pl, state.tx, tx_items, .memory_to_peripheral, 0, REQUEST_TX, true);
        while (@atomicLoad(u32, &state.finished, .acquire) != 3 and @atomicLoad(u32, &state.failed, .acquire) == 0) {
            if (sys.CheckIO(&state.clock.node) != null) break;
            _ = sys.Wait(mask);
        }
        @atomicStore(?*exec.Task, &state.waiter, null, .release);
        _ = sys.AbortIO(&state.clock.node);
        _ = sys.WaitIO(&state.clock.node);
        good = @atomicLoad(u32, &state.finished, .acquire) == 3 and @atomicLoad(u32, &state.failed, .acquire) == 0;
        _ = sys.SetSignal(0, mask);
        sys.FreeSignal(bit);
    } else {
        pl080.start(state.pl, state.rx, rx_items, .peripheral_to_memory, REQUEST_RX, 0, false);
        pl080.start(state.pl, state.tx, tx_items, .memory_to_peripheral, 0, REQUEST_TX, false);
        var reads: u32 = 0;
        while (busy(state) and reads < 10_000_000) : (reads += 1) {}
        good = !busy(state) and !pl080.failed(state.pl, state.tx) and !pl080.failed(state.pl, state.rx);
    }
    write(state, ALG_CR, ALG_CLEAR);
    if (!good) {
        pl080.stop(state.pl, state.tx);
        pl080.stop(state.pl, state.rx);
        return broken(state);
    }
    bytes = length;
    sys.CachePostDMA(@ptrFromInt(state.out), &bytes, 0);
    return true;
}

/// The AES unit reset, set to `mode` and the direction, and `key` (16,
/// 24 or 32 bytes) loaded.
fn keyed(state: *State, mode: Mode, key: [*]const u8, key_length: u32, decrypt: bool) bool {
    write(state, ALG_CR, ALG_CLEAR);
    write(state, AES_CSR, CSR_RESET);
    write(state, AES_CSR, @intFromEnum(mode) << CSR_MODE_SHIFT | (key_length / 8 - 2) << CSR_KEYMODE_SHIFT | (if (decrypt) CSR_DECRYPT else 0));
    if (!waitFor(state, AES_CSR, CSR_BUSY, false)) return broken(state);
    for (0..key_length / 4) |index| write(state, AES_KEY0 + 4 * index, _engine.loadLittle(key + 4 * index));
    return waitFor(state, AES_CSR, CSR_KEY_READY, true) or broken(state);
}

/// The key overwritten in the engine.
fn unkeyed(state: *State) void {
    for (0..8) |index| write(state, AES_KEY0 + 4 * index, 0);
}

/// `length` bytes - whole blocks, at most `room` - of the input buffer
/// through AES in `mode` (ECB, CBC or CTR) with `key`, from `iv` (not
/// read for ECB), into the output buffer. False when the engine failed,
/// and the caller does the work in software.
pub fn cipher(cb: *CryptoBase, state: *State, mode: Mode, key: [*]const u8, key_length: u32, decrypt: bool, iv: *const [16]u8, length: u32) bool {
    if (comptime !compiled) return false;
    state.used = @max(state.used, length);
    defer unkeyed(state);
    if (!keyed(state, mode, key, key_length, decrypt)) return false;
    if (mode != .ecb) for (0..4) |index| write(state, AES_IV0 + 4 * index, _engine.loadLittle(iv[4 * index ..].ptr));
    return run(cb, state, length);
}

/// GCM with a 12-byte `nonce` and no associated data over `length` bytes
/// (1 to `room`) of the input buffer into the output buffer, sealing or
/// opening (`decrypt`): the engine's tag - E(K, J0) exclusive-ored with
/// GHASH over the bytes it was given (opening) or made (sealing) - into
/// `tag`. False when the engine failed.
pub fn gcm(cb: *CryptoBase, state: *State, key: [*]const u8, key_length: u32, nonce: [*]const u8, length: u32, decrypt: bool, tag: *[16]u8) bool {
    if (comptime !compiled) return false;
    const padded = (length + 15) & ~@as(u32, 15);
    state.used = @max(state.used, padded);
    @memset(state.input()[length..padded], 0);
    defer unkeyed(state);
    if (!keyed(state, .gcm, key, key_length, decrypt)) return false;
    write(state, AES_ALEN0, 0);
    write(state, AES_ALEN1, 0);
    write(state, AES_MLEN0, 0);
    write(state, AES_MLEN1, length);
    write(state, AES_IVLEN, 12);
    write(state, AES_CSR, read(state, AES_CSR) | CSR_GCM_START);
    if (!waitFor(state, AES_CSR, CSR_GCM_DONE, true)) return broken(state);
    for (0..3) |index| write(state, AES_IV0 + 4 * index, _engine.loadLittle(nonce + 4 * index));
    if (!waitFor(state, AES_CSR, CSR_GCM_DONE, true)) return broken(state);
    if (!run(cb, state, padded)) return false;
    if (!waitFor(state, AES_CSR, CSR_BUSY, false)) return broken(state);
    for (0..4) |index| _engine.storeLittle(tag[4 * index ..].ptr, read(state, AES_NONCE0 + 4 * index));
    return true;
}
