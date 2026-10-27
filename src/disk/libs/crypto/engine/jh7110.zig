// SPDX-License-Identifier: MIT
//! The JH7110's crypto engine (CHIP_JH7110_CRYPTO, the VisionFive 2): AES
//! in ECB, CBC, CTR and GCM over a whole buffer at once, fed and emptied
//! by two of dma.resource's PL080 channels - not a block at a time through
//! registers, as the S3's engine in `aes.zig` is - and SHA-224, SHA-256,
//! SHA-384 and SHA-512, plain or as HMAC, over any number of buffers fed
//! by the first channel alone; and the PKA's Montgomery multiplications,
//! for ModExp on numbers of up to 2048 bits.
//!
//! The data goes through two buffers of the library's, `room` bytes each
//! and below 4 GiB, as the PL080 needs: the caller copies its input into
//! `State.input`, the engine leaves its output in `State.output`, and the
//! caller copies it from there - GCM's opening only once the tag is
//! right. A longer message is the caller's to split (UpdateCipher) or to
//! leave to software (GCM). `give` clears both buffers.
//!
//! A hash cannot be left half done: the engine has no way to give back
//! the state between blocks, nor to take it again. So it hashes only a
//! message it is given whole (HashPieces, HmacPieces), from `hashBegin`
//! through as many buffers of `hashFeed` as it takes to `hashEnd`, with
//! the library's lock held all the while.
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
//! **The PKA** multiplies two numbers of up to 64 words in Montgomery
//! form, one product a command, ~12.5 us for 2048 bits; the
//! exponentiation around it is the CPU's (`modExp`). Every window of the
//! exponent costs the same - its squarings and one multiplication by its
//! entry in a table, picked without a branch or an address that depends
//! on it - whatever its bits are. It is given a modulus of 16 to 64
//! words whose top bit is set, an RSA key's: with that bit clear its
//! set-up does not finish, and on one word its answers are wrong. A
//! set-up (~140 us for 2048 bits) wants the control cleared and N
//! written again, so `modExp` makes one, and works R mod N out itself.
//! It needs nothing of the engine's set-up but the registers, and runs
//! under ModExp's lock beside whatever AES or SHA does meanwhile. A PKA
//! that once stops answering leaves ModExp to software, and the rest of
//! the engine as it was. After Linux's jh7110-rsa.c, which multiplies
//! only for the exponent's 1 bits.
//!
//! After Linux's jh7110-aes.c and jh7110-hash.c - the registers, and the
//! order they are written in - and what the board measured through the
//! library: 42 MB/s through AES-CTR or GCM, against 2.6 MB/s for the
//! software AES; 66 MB/s through SHA-256, against 33 MB/s, and already
//! 40 against 28 on a message of 512 bytes.

const sdk = @import("sdk");
const exec = sdk.exec;
const hardware = sdk.hardware;
const timer = sdk.devices.timer;
const dmares = sdk.resources.dma;
const st = sdk.expansion.systemtags;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("../crypto_base.zig");
const CryptoBase = _base.CryptoBase;
const Numbers = _base.Numbers;
const _engine = @import("_engine.zig");

/// Whether this chip can have the engine: the RISC-V 64 boards, of which
/// the board's parts say whether this one does.
pub const compiled = hardware.chip == .rv64sbi;
const pl080 = hardware.pl080;
const reg = hardware.mmio.reg;

/// Bytes each buffer holds: smb-handler's largest message - a READ's
/// answer or a WRITE of 1 MiB - and its headers, so that its signature
/// or its seal is one run; a TLS record and an SSH packet easily.
pub const room: u32 = 1024 * 1024 + 4096;
/// The least whole-block data the engine is worth starting for: below,
/// the software AES is as quick.
pub const least: u32 = 64;
/// The least message the engine hashes. It is quicker from 256 bytes
/// (28 MB/s against 24 for SHA-256), and 1.4 times as quick from 512;
/// below that the little it saves is not worth holding the one engine,
/// while the software hashes on every core at once.
pub const hash_least: u32 = 512;
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
    /// Nonzero once the PKA has stopped answering.
    pka_broken: u32 = 0,
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
    /// feeding one, 2 the emptying one), and whether one failed; and the
    /// channels the run started, which it waits for.
    finished: u32 = 0,
    failed: u32 = 0,
    expect: u32 = 0,
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
// SHA's, from 0x300: the control, the digest read a word at a time, the
// HMAC key written a word (or a byte) at a time, and its length.
const SHA_CSR = 0x300;
const SHA_RDR = 0x308;
const SHA_WKR = 0x320;
const SHA_WKLEN = 0x324;

const ALG_START: u32 = 1 << 0;
const ALG_AES_DMA: u32 = 1 << 1;
const ALG_HASH_DMA: u32 = 1 << 3;
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

/// SHA_CSR: start, the unit's reset, the first block, the hash (4-6),
/// the last, HMAC, the key taken, the key coming, HMAC done, busy.
const SHA_START: u32 = 1 << 0;
const SHA_RESET: u32 = 1 << 1;
const SHA_FIRST: u32 = 1 << 3;
const SHA_MODE_SHIFT: u5 = 4;
const SHA_FINAL: u32 = 1 << 8;
const SHA_HMAC: u32 = 1 << 11;
const SHA_KEY_DONE: u32 = 1 << 13;
const SHA_KEY_FLAG: u32 = 1 << 14;
const SHA_HMAC_DONE: u32 = 1 << 15;
const SHA_BUSY: u32 = 1 << 16;

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
/// asked, what they raised it for noted, and once those the run started
/// have finished, or one failed, the waiter woken.
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
    if (!failed and finished & state.expect != state.expect) return 1;
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

/// What a run does with the input buffer: AES's whole words go through
/// the engine into the output buffer; a hash's bytes go into the engine
/// alone, moved as whole words of which it takes the bytes it is told.
const Flow = enum { through, into };

/// `length` bytes of the input buffer through the engine, set up for
/// them, as `flow` says. False when a channel failed or the run took
/// longer than a second: the engine is left alone from then on.
fn run(cb: *CryptoBase, state: *State, length: u32, flow: Flow) bool {
    const sys = cb.sys_base;
    const fifo = state.regs + ALG_FIFO;
    const tx_items: [*]pl080.Item = @ptrFromInt(state.tx_items);
    const rx_items: [*]pl080.Item = @ptrFromInt(state.rx_items);
    const moved = (length + 3) & ~@as(u32, 3);
    _ = pl080.fill(tx_items[0..list_items], .{ .address = state.in, .burst = .thirty_two }, .{ .address = fifo, .step = false, .master = 1, .burst = .thirty_two }, moved, 0) orelse return broken(state);
    var bytes: u32 = moved;
    _ = sys.CachePreDMA(@ptrFromInt(state.in), &bytes, exec.DMAF_ReadFromRAM);
    if (flow == .through) {
        _ = pl080.fill(rx_items[0..list_items], .{ .address = fifo, .step = false, .master = 1 }, .{ .address = state.out }, length, 0) orelse return broken(state);
        bytes = length;
        _ = sys.CachePreDMA(@ptrFromInt(state.out), &bytes, 0);
    }
    bytes = 2 * list_bytes;
    _ = sys.CachePreDMA(@ptrFromInt(state.tx_items), &bytes, exec.DMAF_ReadFromRAM);

    write(state, ALG_CR, ALG_START | (if (flow == .through) ALG_AES_DMA else ALG_HASH_DMA));
    write(state, DMA_IN_LEN, length);
    if (flow == .through) write(state, DMA_OUT_LEN, length);
    const expect: u32 = if (flow == .through) 3 else 1;
    const bit: i8 = if (length >= wait_bytes) sys.AllocSignal(-1) else -1;
    var good: bool = undefined;
    if (bit >= 0) {
        const task = sys.FindTask(null).?;
        const mask = @as(u32, 1) << @intCast(bit);
        state.finished = 0;
        state.failed = 0;
        state.expect = expect;
        state.signals = mask;
        state.port.sig_task = task;
        state.port.sig_bit = @intCast(bit);
        @atomicStore(?*exec.Task, &state.waiter, task, .release);
        state.clock.node.command = timer.TR_ADDREQUEST;
        state.clock.time = timer.TimeVal.fromMicros(1_000_000);
        sys.SendIO(&state.clock.node);
        if (flow == .through) pl080.start(state.pl, state.rx, rx_items, .peripheral_to_memory, REQUEST_RX, 0, true);
        pl080.start(state.pl, state.tx, tx_items, .memory_to_peripheral, 0, REQUEST_TX, true);
        while (@atomicLoad(u32, &state.finished, .acquire) != expect and @atomicLoad(u32, &state.failed, .acquire) == 0) {
            if (sys.CheckIO(&state.clock.node) != null) break;
            _ = sys.Wait(mask);
        }
        @atomicStore(?*exec.Task, &state.waiter, null, .release);
        _ = sys.AbortIO(&state.clock.node);
        _ = sys.WaitIO(&state.clock.node);
        good = @atomicLoad(u32, &state.finished, .acquire) == expect and @atomicLoad(u32, &state.failed, .acquire) == 0;
        _ = sys.SetSignal(0, mask);
        sys.FreeSignal(bit);
    } else {
        if (flow == .through) pl080.start(state.pl, state.rx, rx_items, .peripheral_to_memory, REQUEST_RX, 0, false);
        pl080.start(state.pl, state.tx, tx_items, .memory_to_peripheral, 0, REQUEST_TX, false);
        var reads: u32 = 0;
        while (busy(state) and reads < 10_000_000) : (reads += 1) {}
        good = !busy(state) and !pl080.failed(state.pl, state.tx) and (flow == .into or !pl080.failed(state.pl, state.rx));
    }
    write(state, ALG_CR, ALG_CLEAR);
    if (!good) {
        pl080.stop(state.pl, state.tx);
        pl080.stop(state.pl, state.rx);
        return broken(state);
    }
    if (flow == .through) {
        bytes = length;
        sys.CachePostDMA(@ptrFromInt(state.out), &bytes, 0);
    }
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
    return run(cb, state, length, .through);
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
    if (!run(cb, state, padded, .through)) return false;
    if (!waitFor(state, AES_CSR, CSR_BUSY, false)) return broken(state);
    for (0..4) |index| _engine.storeLittle(tag[4 * index ..].ptr, read(state, AES_NONCE0 + 4 * index));
    return true;
}

/// SHA_CSR's number for the library's HASH_* `algorithm`; null for one
/// the engine has not (SHA-1, MD5, MD4).
pub fn shaMode(algorithm: u32) ?u32 {
    return switch (algorithm) {
        sdk.crypto.HASH_SHA224 => 3,
        sdk.crypto.HASH_SHA256 => 4,
        sdk.crypto.HASH_SHA384 => 5,
        sdk.crypto.HASH_SHA512 => 6,
        else => null,
    };
}

/// The SHA unit reset and set to the hash `mode` (from `shaMode`): a
/// plain hash for an empty `key`, else HMAC with `key` - 1 byte to a
/// block, the caller having hashed a longer one. False when the engine
/// failed.
pub fn hashBegin(state: *State, mode: u32, key: []const u8) bool {
    if (comptime !compiled) return false;
    write(state, ALG_CR, ALG_CLEAR);
    write(state, SHA_CSR, SHA_RESET);
    if (!waitFor(state, SHA_CSR, SHA_BUSY, false)) return broken(state);
    if (key.len == 0) {
        write(state, SHA_CSR, mode << SHA_MODE_SHIFT | SHA_START | SHA_FIRST);
        return true;
    }
    write(state, SHA_WKLEN, @intCast(key.len));
    write(state, SHA_CSR, mode << SHA_MODE_SHIFT | SHA_HMAC | SHA_KEY_FLAG);
    const words = key.len / 4;
    for (0..words) |index| write(state, SHA_WKR, _engine.loadLittle(key[4 * index ..].ptr));
    // The bytes after the last whole word, a byte at a time.
    for (key[4 * words ..]) |byte| hardware.mmio.reg8(state.regs + SHA_WKR).* = byte;
    return waitFor(state, SHA_CSR, SHA_KEY_DONE, true) or broken(state);
}

/// `length` bytes (1 to `room`) of the input buffer into the hash
/// begun. Every buffer but the message's last must be a multiple of the
/// hash's block. False when the engine failed.
pub fn hashFeed(cb: *CryptoBase, state: *State, length: u32) bool {
    if (comptime !compiled) return false;
    state.used = @max(state.used, (length + 3) & ~@as(u32, 3));
    return run(cb, state, length, .into);
}

/// The hash ended: its `length`-byte digest, or HMAC's MAC, into
/// `digest`. False when the engine failed, and nothing is written.
pub fn hashEnd(state: *State, digest: [*]u8, length: u32, hmac: bool) bool {
    if (comptime !compiled) return false;
    write(state, SHA_CSR, read(state, SHA_CSR) & ~SHA_FIRST | SHA_FINAL);
    if (!waitFor(state, SHA_CSR, SHA_BUSY, false)) return broken(state);
    if (hmac and !waitFor(state, SHA_CSR, SHA_HMAC_DONE, true)) return broken(state);
    for (0..length / 4) |index| _engine.storeLittle(digest + 4 * index, read(state, SHA_RDR));
    return true;
}

// --- the PKA ------------------------------------------------------------------

// The PKA's, from 0x400: the control, the status, and the operands A, E
// and N, 64 words each, the least significant first and each word's
// bytes the other way round.
const PKA_CACR = 0x400;
const PKA_CASR = 0x404;
const PKA_A = 0x408;
const PKA_E = 0x508;
const PKA_N = 0x608;

/// PKA_CACR: start, the unit's reset, R^2 mod N worked out with the
/// set-up, the command (8-11), the last one's done cleared, the operands'
/// words less one (16-21) and the exponent's (24-29). PKA_CASR: done.
const PKA_START: u32 = 1 << 0;
const PKA_RESET: u32 = 1 << 1;
const PKA_PRE_EXPF: u32 = 1 << 7;
const PKA_CMD_SHIFT: u5 = 8;
const PKA_CLEAN_DONE: u32 = 1 << 15;
const PKA_OPSIZE_SHIFT: u5 = 16;
const PKA_EXPOSIZE_SHIFT: u5 = 24;
const PKA_DONE: u32 = 1 << 0;

/// The PKA's commands, R being 2 to the operands' bits, each answer in
/// A: the set-up for N; E R mod N, with R^2 from the set-up; A E / R mod
/// N; A A / R mod N.
const Command = enum(u32) { set_up = 0x0, into = 0x5, multiply = 0x6, square = 0x7 };

/// The most words of a number the PKA takes: 2048 bits.
pub const pka_words = 64;
/// The fewest it is given: 512 bits. On one word it answers wrong, and a
/// short number is quick in software.
const pka_fewest = 16;
/// The most entries of `modExp`'s table: a window of 4 bits.
pub const table_entries = if (compiled) 16 else 0;

/// The PKA's registers for `modulus`, null where there is none, it has
/// failed, or it does not take the modulus: one of 16 to 64 words whose
/// top bit is set - with that bit clear, its set-up does not finish. The
/// first call sets the engine up.
pub fn pka(cb: *CryptoBase, modulus: []const u32) ?usize {
    if (comptime !compiled) return null;
    if (modulus.len < pka_fewest or modulus.len > pka_words) return null;
    if (modulus[modulus.len - 1] >> 31 == 0) return null;
    const state = &cb.sec;
    if (@atomicLoad(u32, &state.status, .acquire) == status_unknown) {
        if (take(cb)) |taken| give(cb, taken);
    }
    if (@atomicLoad(u32, &state.status, .acquire) != status_ready) return null;
    if (@atomicLoad(u32, &state.pka_broken, .acquire) != 0) return null;
    return state.regs;
}

/// The PKA for operands of `words` words.
const Unit = struct {
    regs: usize,
    words: u32,

    fn control(unit: Unit, value: u32) void {
        reg(unit.regs + PKA_CACR).* = value;
    }

    /// `number` into an operand, 0 past its end.
    fn put(unit: Unit, operand: usize, number: []const u32) void {
        for (0..unit.words) |index| {
            reg(unit.regs + operand + 4 * index).* = @byteSwap(if (index < number.len) number[index] else 0);
        }
    }

    fn get(unit: Unit, operand: usize, number: []u32) void {
        for (number[0..unit.words], 0..) |*word, index| word.* = @byteSwap(reg(unit.regs + operand + 4 * index).*);
    }

    /// One command, waited for: false if the PKA did not finish it.
    fn run(unit: Unit, command: Command, flags: u32) bool {
        const size = (unit.words - 1) << PKA_OPSIZE_SHIFT | (unit.words - 1) << PKA_EXPOSIZE_SHIFT;
        unit.control(PKA_CLEAN_DONE | size | @intFromEnum(command) << PKA_CMD_SHIFT | flags | PKA_START);
        var reads: u32 = 0;
        while (reads < 1_000_000) : (reads += 1) {
            if (reg(unit.regs + PKA_CASR).* & PKA_DONE != 0) return true;
        }
        return false;
    }
};

/// The window's width, 1, 2 or 4 bits, that takes the fewest commands
/// for an exponent of `bits`: each bit a squaring, each window a
/// multiplication, and the table one for each entry.
fn windowBits(bits: u32) u5 {
    var best: u5 = 1;
    var fewest: u32 = 0xFFFF_FFFF;
    for ([_]u5{ 1, 2, 4 }) |width| {
        const cost = bits + (bits + width - 1) / width + (@as(u32, 1) << width);
        if (cost < fewest) {
            fewest = cost;
            best = width;
        }
    }
    return best;
}

/// The exponent's window `index`, `width` bits; the width divides 32.
fn digit(exponent: []const u32, index: u32, width: u5) u32 {
    const at = index * width;
    return (exponent[at / 32] >> @intCast(at % 32)) & ((@as(u32, 1) << width) - 1);
}

/// `table[index]` into `out`, every entry read and none chosen by a
/// branch or an address.
fn pick(table: []const [pka_words]u32, index: u32, out: *[pka_words]u32, words: u32) void {
    @memset(out[0..words], 0);
    for (table, 0..) |*entry, at| {
        const differs = @as(u32, @intCast(at)) ^ index;
        const mask = ((differs | (0 -% differs)) >> 31) -% 1;
        for (out[0..words], entry[0..words]) |*word, value| word.* |= value & mask;
    }
}

/// `numbers.result` = base ^ exponent mod modulus on the PKA, the
/// operands `words` long, at most `pka_words`, and the exponent `bits`
/// long, at least 1. The table - x^i R mod N for every value i a window
/// can have - is worked out first, then each window from the top: its
/// squarings and a multiplication by its entry. False if the PKA stopped
/// answering, which leaves it alone from then on: the numbers are as they
/// were, for software.
pub fn modExp(cb: *CryptoBase, regs: usize, numbers: *Numbers, words: u32, bits: u32) bool {
    const unit: Unit = .{ .regs = regs, .words = words };
    const width = windowBits(bits);
    const table = numbers.table[0 .. @as(u32, 1) << width];
    const one = [1]u32{1};
    var picked: [pka_words]u32 = undefined;
    defer {
        const bytes: [*]volatile u8 = @ptrCast(&picked);
        for (0..@sizeOf(@TypeOf(picked))) |index| bytes[index] = 0;
        unit.put(PKA_A, &.{});
        unit.put(PKA_E, &.{});
        unit.control(PKA_RESET);
    }
    unit.control(PKA_RESET);
    // R mod N, which is 1 in Montgomery form: R - N, N being more than
    // R / 2. Then x R mod N, from the set-up, and each entry after it the
    // one before times x.
    var borrow: u64 = 0;
    for (table[0][0..words], numbers.modulus[0..words]) |*word, subtract| {
        const difference = 0 -% @as(u64, subtract) -% borrow;
        word.* = @truncate(difference);
        borrow = (difference >> 32) & 1;
    }
    unit.control(0);
    unit.put(PKA_N, numbers.modulus[0..words]);
    if (!unit.run(.set_up, PKA_PRE_EXPF)) return pkaBroken(cb);
    unit.put(PKA_E, numbers.base_value[0..words]);
    if (!unit.run(.into, 0)) return pkaBroken(cb);
    unit.get(PKA_A, &table[1]);
    unit.put(PKA_E, table[1][0..words]);
    for (table[2..]) |*entry| {
        if (!unit.run(.multiply, 0)) return pkaBroken(cb);
        unit.get(PKA_A, entry);
    }
    var window = (bits + width - 1) / width - 1;
    pick(table, digit(numbers.exponent[0..words], window, width), &picked, words);
    unit.put(PKA_A, picked[0..words]);
    while (window > 0) {
        window -= 1;
        for (0..width) |_| {
            if (!unit.run(.square, 0)) return pkaBroken(cb);
        }
        pick(table, digit(numbers.exponent[0..words], window, width), &picked, words);
        unit.put(PKA_E, picked[0..words]);
        if (!unit.run(.multiply, 0)) return pkaBroken(cb);
    }
    // Out of Montgomery form: times 1, over R.
    unit.put(PKA_E, &one);
    if (!unit.run(.multiply, 0)) return pkaBroken(cb);
    unit.get(PKA_A, numbers.result[0..words]);
    return true;
}

fn pkaBroken(cb: *CryptoBase) bool {
    @atomicStore(u32, &cb.sec.pka_broken, 1, .release);
    return false;
}
