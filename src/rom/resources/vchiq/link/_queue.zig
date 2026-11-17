// SPDX-License-Identifier: MPL-2.0
//! The queue at work: started at the first OpenService, the ARM's
//! messages written into its slots, the firmware's read by the
//! resource's task, and the bulks' pagelists.
//!
//! **Starting**: the slot zero laid out in the kept memory, the ARM's
//! side said to be ready, the memory's address handed to the firmware
//! (the mailbox's VCHIQ_INIT, answered with 0), the firmware's side
//! waited for, then the CONNECTs exchanged.
//!
//! **Sending**: one task at a time (`tx_lock`) writes its message after
//! the last, says so in the ARM's `tx_pos` and tells the firmware's
//! `trigger`. A message that does not fit in what is left of a slot
//! pads it and goes into the next slot of the ARM's `slot_queue`, once
//! the firmware has given that slot back: a sender waits for that on the
//! doorbell alone (`space`), so it never waits on the task.
//!
//! **Reading**: the doorbell's server wakes the resource's task (`rung`),
//! which reads the firmware's messages up to its `tx_pos`. Each is dealt
//! with at once - a service's message copied out to it, an answer to an
//! OPEN or a CLOSE taken, a bulk's end told - so the firmware's slot is
//! given back as soon as it is read to its end. The task looks every
//! tenth of a second too, should a ring be missed.
//!
//! **Bulks**: the firmware moves them itself. The ARM describes the
//! memory in a pagelist in the kept block and names it in a BULK_TX (the
//! firmware reads) or BULK_RX (it writes) message; the firmware's
//! BULK_TX_DONE or BULK_RX_DONE ends the oldest of that direction. The
//! ends of what the firmware writes that are not whole cache lines come
//! in a fragment, copied over once the rest is in memory.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const barrier = sdk.hardware.barrier;
const videocore = sdk.hardware.videocore;
const systimer = sdk.hardware.systimer;
const vchiq = sdk.resources.vchiq;
const ExecBase = sdk.interface.exec.ExecBase;
const layout = @import("_layout.zig");
const base = @import("../vchiq_base.zig");
const VchiqBase = base.VchiqBase;
const Service = base.Service;
const Message = base.Message;
const VchiqBulk = vchiq.VchiqBulk;

const NAME = vchiq.VCHIQNAME;

/// The firmware's property tag that hands it the queue's memory.
const TAG_VCHIQ_INIT: u32 = 0x0004_8010;

/// The doorbells: the ARM's, read to clear, bit 2 when the firmware rang
/// it; the firmware's, rung by any write.
const BELL0: usize = 0x00;
const BELL2: usize = 0x08;
const BELL_RUNG: u32 = 1 << 2;

/// What the ARM's OPEN says it is, to the firmware's logs.
const client_id: u32 = 1;

/// The task's priority and stack.
const task_pri: i8 = 10;
const task_stack: usize = 16 * 1024;
/// How often the task looks without a ring, in microseconds.
const poll_us: u64 = 100_000;
/// How long the firmware has to say it is ready, to connect, and to give
/// a slot back.
const ready_us: u64 = 100_000;
const connect_us: u64 = 1_000_000;
const space_us: u64 = 2_000_000;

fn zero(vb: *VchiqBase) *volatile layout.SlotZero {
    return @ptrFromInt(vb.memory);
}

fn slotAt(vb: *VchiqBase, slot: u32) usize {
    return vb.memory + @as(usize, slot) * layout.slot_size;
}

fn reg(vb: *VchiqBase, offset: usize) *volatile u32 {
    return @ptrFromInt(vb.regs + offset);
}

fn log(vb: *VchiqBase, comptime fmt: []const u8, args: anytype) void {
    exec.kprintf(vb.sys_base, NAME ++ ": " ++ fmt ++ "\n", args);
}

// --- starting ---------------------------------------------------------------

/// The queue started, if it is not: VCHIQERR_OK, or VCHIQERR_NO_FIRMWARE
/// - and then it stays dead. The caller holds `start_lock`.
pub fn start(vb: *VchiqBase) u32 {
    if (vb.state == base.STATE_RUNNING) return vchiq.VCHIQERR_OK;
    if (vb.state == base.STATE_DEAD) return vchiq.VCHIQERR_NO_FIRMWARE;
    if (bringUp(vb)) {
        vb.state = base.STATE_RUNNING;
        log(vb, "connected with the firmware, the queue at 0x%08x", .{vb.bus});
        return vchiq.VCHIQERR_OK;
    }
    vb.state = base.STATE_DEAD;
    return vchiq.VCHIQERR_NO_FIRMWARE;
}

fn bringUp(vb: *VchiqBase) bool {
    const sys = vb.sys_base;
    if (vb.memory == 0 or vb.memory_bytes < layout.bytes_needed) {
        log(vb, "no memory kept for the queue", .{});
        return false;
    }
    layOut(vb);
    vb.task = sys.CreateTask(NAME, task_pri, &taskCode, task_stack) orelse {
        log(vb, "no memory for its task", .{});
        return false;
    };
    vb.server = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = NAME },
        .data = vb,
        .code = &doorbell,
    };
    sys.AddIntServer(vb.irq, &vb.server);
    vb.hooked = true;
    barrier.full();
    zero(vb).slave.initialised = 1;
    barrier.full();
    if (!handOver(vb)) {
        log(vb, "the firmware did not take the queue", .{});
        return false;
    }
    const until = systimer.uptimeUs() + ready_us;
    while (zero(vb).master.initialised == 0) {
        if (systimer.uptimeUs() > until) {
            log(vb, "the firmware's side was not ready", .{});
            return false;
        }
        sleep(sys, 1000);
    }
    if (send(vb, layout.msgid(layout.MSG_CONNECT, 0, 0), &.{}) != vchiq.VCHIQERR_OK) return false;
    const waits = [_]*exec.Waitable{&vb.connected};
    if (sys.WaitForAny(&waits, waits.len, connect_us) == exec.WAIT_TIMEOUT) {
        log(vb, "the firmware did not connect", .{});
        return false;
    }
    return true;
}

/// The slot zero and the ARM's side laid out, the rest of what the queue
/// takes cleared: each side's slots, the fragments' address, the ARM's
/// slots all free, its sync slot free, and its events armed for good.
fn layOut(vb: *VchiqBase) void {
    const block: [*]u8 = @ptrFromInt(vb.memory);
    @memset(block[0..layout.bytes_needed], 0);
    barrier.full();
    const z = zero(vb);
    z.magic = layout.magic;
    z.version = layout.version;
    z.version_min = layout.version_min;
    z.slot_zero_size = @sizeOf(layout.SlotZero);
    z.slot_size = layout.slot_size;
    z.max_slots = layout.max_slots;
    z.max_slots_per_side = layout.max_slots_per_side;
    z.platform_data[0] = vb.bus + @as(u32, @intCast(layout.fragments_at));
    z.platform_data[1] = layout.fragment_count;
    z.master.slot_sync = layout.master_sync;
    z.master.slot_first = layout.master_first;
    z.master.slot_last = layout.master_last;
    z.slave.slot_sync = layout.slave_sync;
    z.slave.slot_first = layout.slave_first;
    z.slave.slot_last = layout.slave_last;
    var i: u32 = 0;
    while (i < layout.slave_slots) : (i += 1) z.slave.slot_queue[i] = layout.slave_first + i;
    z.slave.slot_queue_recycle = layout.slave_slots;
    z.slave.sync_release.fired = 1;
    z.slave.debug[0] = layout.debug_entries;
    z.slave.trigger.armed = 1;
    z.slave.recycle.armed = 1;
    z.slave.sync_trigger.armed = 1;
    vb.tx_pos = 0;
    vb.rx_pos = 0;
}

/// The memory's address handed to the firmware: whether it said 0.
fn handOver(vb: *VchiqBase) bool {
    const sys = vb.sys_base;
    const bytes = 2 * videocore.buffer_bytes;
    const memory = sys.AllocMem(bytes, exec.MEMF_DMA) orelse return false;
    defer sys.FreeMem(memory, bytes);
    const buffer = videocore.bufferIn(memory) orelse return false;
    var value = [_]u32{vb.bus};
    if (!videocore.call(sys, vb.mailbox, buffer, TAG_VCHIQ_INIT, &value)) return false;
    return value[0] == 0;
}

fn sleep(sys: *ExecBase, us: u64) void {
    var never: exec.Waitable = .{};
    const waits = [_]*exec.Waitable{&never};
    _ = sys.WaitForAny(&waits, waits.len, us);
}

/// The doorbell: the ARM's read, which clears it, and the task and a
/// waiting sender woken when the firmware rang.
fn doorbell(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const vb: *VchiqBase = @ptrCast(@alignCast(is_data.?));
    if (reg(vb, BELL0).* & BELL_RUNG == 0) return 0;
    vb.sys_base.SignalWaitable(&vb.rung);
    vb.sys_base.SignalWaitable(&vb.space);
    return 1;
}

/// One of the firmware's events told: what was written before it in
/// memory first, and its doorbell rung if it waits.
fn tell(vb: *VchiqBase, event: *volatile layout.RemoteEvent) void {
    barrier.toDevice();
    event.fired = 1;
    barrier.full();
    if (event.armed != 0) reg(vb, BELL2).* = 0;
}

// --- sending ----------------------------------------------------------------

/// A message sent after those before it: VCHIQERR_OK, or
/// VCHIQERR_TIMEOUT when the firmware gave no slot back.
pub fn send(vb: *VchiqBase, id: u32, data: []const u8) u32 {
    const sys = vb.sys_base;
    sys.ObtainSemaphore(&vb.tx_lock);
    defer sys.ReleaseSemaphore(&vb.tx_lock);
    return sendLocked(vb, id, data);
}

/// `send`, for a caller that holds `tx_lock`.
pub fn sendLocked(vb: *VchiqBase, id: u32, data: []const u8) u32 {
    const size: u32 = @intCast(data.len);
    const need = layout.stride(size);
    var pos = vb.tx_pos;
    const left = layout.slot_size - (pos & layout.slot_mask);
    if (need > left) {
        const h: *volatile layout.Header = @ptrFromInt(slotAt(vb, txSlot(vb, pos)) + (pos & layout.slot_mask));
        h.size = left - 8;
        h.msgid = layout.MSG_PADDING;
        pos +%= left;
    }
    if (pos & layout.slot_mask == 0 and !free(vb, pos)) {
        vb.tx_pos = pos;
        publish(vb);
        if (!waitForSlot(vb, pos)) {
            log(vb, "the firmware gave no slot back", .{});
            return vchiq.VCHIQERR_TIMEOUT;
        }
    }
    const at = slotAt(vb, txSlot(vb, pos)) + (pos & layout.slot_mask);
    const bytes: [*]u8 = @ptrFromInt(at + 8);
    @memcpy(bytes[0..data.len], data);
    const h: *volatile layout.Header = @ptrFromInt(at);
    h.size = size;
    h.msgid = id;
    vb.tx_pos = pos +% need;
    publish(vb);
    return vchiq.VCHIQERR_OK;
}

/// The ARM's slot that the bytes at `pos` are in.
fn txSlot(vb: *VchiqBase, pos: u32) u32 {
    return zero(vb).slave.slot_queue[(pos / layout.slot_size) & 63];
}

/// Whether the slot that starts at `pos` is the ARM's to write: the
/// firmware has given it back (or it never had it).
fn free(vb: *VchiqBase, pos: u32) bool {
    const recycled = zero(vb).slave.slot_queue_recycle;
    barrier.reads();
    const ahead: i32 = @bitCast((recycled *% layout.slot_size) -% pos);
    return ahead > 0;
}

/// What the ARM wrote up to `tx_pos` handed to the firmware.
fn publish(vb: *VchiqBase) void {
    barrier.toDevice();
    zero(vb).slave.tx_pos = vb.tx_pos;
    tell(vb, &zero(vb).master.trigger);
}

fn waitForSlot(vb: *VchiqBase, pos: u32) bool {
    const sys = vb.sys_base;
    const until = systimer.uptimeUs() + space_us;
    const waits = [_]*exec.Waitable{&vb.space};
    while (true) {
        sys.ResetWaitable(&vb.space);
        if (free(vb, pos)) return true;
        if (systimer.uptimeUs() > until) return false;
        _ = sys.WaitForAny(&waits, waits.len, 10_000);
    }
}

// --- reading ----------------------------------------------------------------

/// The resource's task: what the firmware sent read whenever it rings,
/// and every tenth of a second besides.
fn taskCode(sys: *ExecBase) callconv(.c) void {
    const vb: *VchiqBase = @ptrCast(@alignCast(sys.OpenResource(NAME) orelse return));
    const waits = [_]*exec.Waitable{&vb.rung};
    while (true) {
        _ = sys.WaitForAny(&waits, waits.len, poll_us);
        sys.ResetWaitable(&vb.rung);
        poll(vb);
    }
}

/// Everything the firmware has sent, dealt with: its sync slot's message,
/// then its slots up to its `tx_pos`. Each event is cleared before what
/// it tells of is read, so that one told while that is read is not lost.
fn poll(vb: *VchiqBase) void {
    const z = zero(vb);
    if (z.slave.sync_trigger.fired != 0) {
        z.slave.sync_trigger.fired = 0;
        barrier.full();
        syncSlot(vb);
    }
    z.slave.trigger.fired = 0;
    z.slave.recycle.fired = 0;
    barrier.full();
    while (true) {
        const tx = z.master.tx_pos;
        barrier.reads();
        if (vb.rx_pos == tx) return;
        const slot = z.master.slot_queue[(vb.rx_pos / layout.slot_size) & 63];
        barrier.reads();
        const offset = vb.rx_pos & layout.slot_mask;
        const at = slotAt(vb, slot) + offset;
        const h: *volatile layout.Header = @ptrFromInt(at);
        const id = h.msgid;
        const size = h.size;
        var step: u32 = layout.slot_size - offset;
        if (size <= layout.max_message and offset + layout.stride(size) <= layout.slot_size) {
            step = layout.stride(size);
            const bytes: [*]const u8 = @ptrFromInt(at + 8);
            handle(vb, id, bytes[0..size]);
        } else log(vb, "message %08x of %u bytes runs past its slot", .{ id, size });
        vb.rx_pos +%= step;
        if (vb.rx_pos & layout.slot_mask == 0) giveBack(vb, slot);
    }
}

/// The firmware's slot `slot` read to its end, given back to it.
fn giveBack(vb: *VchiqBase, slot: u32) void {
    const z = zero(vb);
    const n = z.master.slot_queue_recycle;
    z.master.slot_queue[n & 63] = slot;
    barrier.toDevice();
    z.master.slot_queue_recycle = n +% 1;
    tell(vb, &z.master.recycle);
}

/// The message in the firmware's sync slot, if there is one, dealt with
/// as any other and its slot given back.
fn syncSlot(vb: *VchiqBase) void {
    const z = zero(vb);
    const at = slotAt(vb, layout.master_sync);
    const h: *volatile layout.Header = @ptrFromInt(at);
    const id = h.msgid;
    if (id == layout.MSG_PADDING) return;
    const size = @min(h.size, layout.max_message);
    const bytes: [*]const u8 = @ptrFromInt(at + 8);
    handle(vb, id, bytes[0..size]);
    h.msgid = layout.MSG_PADDING;
    tell(vb, &z.master.sync_release);
}

/// One of the firmware's messages dealt with.
fn handle(vb: *VchiqBase, id: u32, bytes: []const u8) void {
    const sys = vb.sys_base;
    const src = layout.srcOf(id);
    const dst = layout.dstOf(id);
    switch (layout.kindOf(id)) {
        layout.MSG_PADDING => {},
        layout.MSG_CONNECT => sys.SignalWaitable(&vb.connected),
        // The ARM offers no services: an OPEN is refused.
        layout.MSG_OPEN => _ = send(vb, layout.msgid(layout.MSG_CLOSE, 0, src), &.{}),
        layout.MSG_OPENACK => opened(vb, src, dst, bytes),
        layout.MSG_CLOSE => closed(vb, src, dst),
        layout.MSG_DATA => arrived(vb, src, dst, bytes),
        layout.MSG_BULK_RX_DONE => bulkDone(vb, vchiq.VCHIQBULK_RECEIVE, src, dst, bytes),
        layout.MSG_BULK_TX_DONE => bulkDone(vb, vchiq.VCHIQBULK_TRANSMIT, src, dst, bytes),
        layout.MSG_PAUSE => if (!vb.paused) {
            sys.ObtainSemaphore(&vb.tx_lock);
            _ = sendLocked(vb, layout.msgid(layout.MSG_PAUSE, 0, 0), &.{});
            vb.paused = true;
        },
        layout.MSG_RESUME => if (vb.paused) {
            vb.paused = false;
            sys.ReleaseSemaphore(&vb.tx_lock);
        },
        layout.MSG_REMOTE_USE => _ = send(vb, layout.msgid(layout.MSG_REMOTE_USE_ACTIVE, 0, 0), &.{}),
        layout.MSG_REMOTE_RELEASE, layout.MSG_REMOTE_USE_ACTIVE => {},
        else => log(vb, "message %08x from the firmware is not known", .{id}),
    }
}

/// The service at the ARM's port `dst`, if the firmware's `src` is its
/// port or it has none yet. The caller holds `list_lock`.
fn serviceAt(vb: *VchiqBase, src: u32, dst: u32) ?*Service {
    if (dst >= base.max_services) return null;
    const s = vb.services[dst] orelse return null;
    if (s.state != base.SERVICE_OPENING and s.remoteport != src) return null;
    return s;
}

fn opened(vb: *VchiqBase, src: u32, dst: u32, bytes: []const u8) void {
    const sys = vb.sys_base;
    sys.ObtainSemaphore(&vb.list_lock);
    defer sys.ReleaseSemaphore(&vb.list_lock);
    const s = serviceAt(vb, src, dst) orelse return;
    if (s.state != base.SERVICE_OPENING) return;
    s.remoteport = src;
    if (bytes.len >= 2) s.peer_version = std.mem.readInt(u16, bytes[0..2], .little);
    s.state = base.SERVICE_OPEN;
    sys.SignalWaitable(&s.changed);
}

/// A CLOSE from the firmware: the answer to an OPEN it refused, to the
/// ARM's CLOSE, or its own - answered with the ARM's. The service's bulks
/// are given up with it.
fn closed(vb: *VchiqBase, src: u32, dst: u32) void {
    const sys = vb.sys_base;
    var answer: ?u32 = null;
    {
        sys.ObtainSemaphore(&vb.list_lock);
        defer sys.ReleaseSemaphore(&vb.list_lock);
        // A refused OPEN's CLOSE goes to port 0, from the port the
        // firmware had begun to give it.
        const s = serviceAt(vb, src, dst) orelse return;
        switch (s.state) {
            base.SERVICE_OPENING => s.state = base.SERVICE_REFUSED,
            base.SERVICE_OPEN => {
                answer = layout.msgid(layout.MSG_CLOSE, s.localport, s.remoteport);
                s.state = base.SERVICE_CLOSED;
            },
            base.SERVICE_CLOSESENT => s.state = base.SERVICE_CLOSED,
            else => return,
        }
        for (&s.bulks) |*bulks| {
            while (take(bulks)) |bulk| finish(vb, bulk, -1);
        }
        sys.SignalWaitable(&s.changed);
        sys.SignalWaitable(&s.arrived);
    }
    if (answer) |id| _ = send(vb, id, &.{});
}

/// A service's message, copied out to it.
fn arrived(vb: *VchiqBase, src: u32, dst: u32, bytes: []const u8) void {
    const sys = vb.sys_base;
    const total = @sizeOf(Message) + bytes.len;
    const memory = sys.AllocMem(total, exec.MEMF_SYSTEM) orelse {
        log(vb, "no memory for a message of %u bytes: dropped", .{@as(u32, @intCast(bytes.len))});
        return;
    };
    const m: *Message = @ptrCast(@alignCast(memory));
    m.* = .{ .size = @intCast(bytes.len) };
    @memcpy(m.bytes()[0..bytes.len], bytes);
    sys.ObtainSemaphore(&vb.list_lock);
    defer sys.ReleaseSemaphore(&vb.list_lock);
    const s = serviceAt(vb, src, dst) orelse return sys.FreeMem(memory, total);
    if (s.state != base.SERVICE_OPEN) return sys.FreeMem(memory, total);
    if (s.last) |last| last.next = m else s.first = m;
    s.last = m;
    sys.SignalWaitable(&s.arrived);
}

// --- bulks ------------------------------------------------------------------

/// A bulk's own parts, in its `private`: the next out after it, its
/// pagelist, its fragment and one past it (0: none).
fn nextOf(bulk: *VchiqBulk) *usize {
    return &bulk.private[0];
}

fn take(bulks: *base.Bulks) ?*VchiqBulk {
    const bulk = bulks.first orelse return null;
    bulks.first = @ptrFromInt(nextOf(bulk).*);
    if (bulks.first == null) bulks.last = null;
    bulks.count -= 1;
    nextOf(bulk).* = 0;
    return bulk;
}

fn append(bulks: *base.Bulks, bulk: *VchiqBulk) void {
    nextOf(bulk).* = 0;
    if (bulks.last) |last| nextOf(last).* = @intFromPtr(bulk) else bulks.first = bulk;
    bulks.last = bulk;
    bulks.count += 1;
}

/// The last bulk appended taken off again, when its message could not go.
fn dropLast(bulks: *base.Bulks, bulk: *VchiqBulk) void {
    var at: ?*VchiqBulk = bulks.first;
    var before: ?*VchiqBulk = null;
    while (at) |here| : (at = @ptrFromInt(nextOf(here).*)) {
        if (here == bulk) break;
        before = here;
    }
    if (at == null) return;
    const after: ?*VchiqBulk = @ptrFromInt(nextOf(bulk).*);
    if (before) |b| nextOf(b).* = @intFromPtr(after) else bulks.first = after;
    if (bulks.last == bulk) bulks.last = before;
    bulks.count -= 1;
}

/// A bit of `bits` taken: its number, or null when all are in use.
fn takeBit(bits: *u64) ?u32 {
    while (true) {
        const now = @atomicLoad(u64, bits, .acquire);
        if (now == ~@as(u64, 0)) return null;
        const n: u32 = @ctz(~now);
        if (@cmpxchgWeak(u64, bits, now, now | @as(u64, 1) << @intCast(n), .acq_rel, .acquire) == null) return n;
    }
}

fn giveBit(bits: *u64, n: u32) void {
    _ = @atomicRmw(u64, bits, .And, ~(@as(u64, 1) << @intCast(n)), .acq_rel);
}

/// `bulk` put out on `s`: its pagelist written, its memory written back
/// from the caches, and its message sent. The caller holds `start_lock`'s
/// guarantee that `s` stays open (its own handle).
pub fn queueBulk(vb: *VchiqBase, s: *Service, bulk: *VchiqBulk) u32 {
    const sys = vb.sys_base;
    const data = bulk.data orelse return vchiq.VCHIQERR_SIZE;
    const address = @intFromPtr(data);
    const size = bulk.size;
    const direction = bulk.direction;
    if (size == 0 or size > layout.max_bulk or direction > vchiq.VCHIQBULK_RECEIVE) return vchiq.VCHIQERR_SIZE;
    if (address + size > 1 << 36) return vchiq.VCHIQERR_SIZE;
    sys.ObtainSemaphore(&vb.tx_lock);
    defer sys.ReleaseSemaphore(&vb.tx_lock);
    if (s.state != base.SERVICE_OPEN) return vchiq.VCHIQERR_CLOSED;
    if (s.bulks[direction].count >= vchiq.VCHIQ_MAX_BULKS) return vchiq.VCHIQERR_BUSY;
    const list = takeBit(&vb.pagelists) orelse return vchiq.VCHIQERR_BUSY;
    var kind: u32 = if (direction == vchiq.VCHIQBULK_RECEIVE) layout.PAGELIST_READ else layout.PAGELIST_WRITE;
    var fragment: usize = 0;
    if (direction == vchiq.VCHIQBULK_RECEIVE and layout.needsFragment(address, size)) {
        const n = takeBit(&vb.fragments) orelse {
            giveBit(&vb.pagelists, list);
            return vchiq.VCHIQERR_BUSY;
        };
        kind = layout.PAGELIST_READ_WITH_FRAGMENTS + n;
        fragment = n + 1;
    }
    const at = vb.memory + layout.pagelists_at + @as(usize, list) * layout.pagelist_bytes;
    var words: [layout.pagelist_bytes / 4]u32 = undefined;
    const count = layout.describe(&words, address, size, kind);
    const into: [*]u32 = @ptrFromInt(at);
    @memcpy(into[0..count], words[0..count]);
    bulk.private[1] = list;
    bulk.private[2] = fragment;
    bulk.actual = 0;
    bulk.result = vchiq.VCHIQERR_OK;
    sys.ResetWaitable(&bulk.done);
    var length = size;
    _ = sys.CachePreDMA(data, &length, if (direction == vchiq.VCHIQBULK_TRANSMIT) exec.DMAF_ReadFromRAM else 0);
    {
        sys.ObtainSemaphore(&vb.list_lock);
        defer sys.ReleaseSemaphore(&vb.list_lock);
        append(&s.bulks[direction], bulk);
    }
    const message = [2]u32{ vb.bus + @as(u32, @intCast(layout.pagelists_at + @as(usize, list) * layout.pagelist_bytes)), size };
    const kind_msg = if (direction == vchiq.VCHIQBULK_TRANSMIT) layout.MSG_BULK_TX else layout.MSG_BULK_RX;
    const sent = sendLocked(vb, layout.msgid(kind_msg, s.localport, s.remoteport), std.mem.asBytes(&message));
    if (sent != vchiq.VCHIQERR_OK) {
        sys.ObtainSemaphore(&vb.list_lock);
        defer sys.ReleaseSemaphore(&vb.list_lock);
        dropLast(&s.bulks[direction], bulk);
        release(vb, bulk);
        return sent;
    }
    return vchiq.VCHIQERR_OK;
}

/// The firmware's end of the oldest bulk of `direction` on a service.
fn bulkDone(vb: *VchiqBase, direction: u32, src: u32, dst: u32, bytes: []const u8) void {
    const sys = vb.sys_base;
    const actual: i32 = if (bytes.len >= 4) std.mem.readInt(i32, bytes[0..4], .little) else -1;
    sys.ObtainSemaphore(&vb.list_lock);
    defer sys.ReleaseSemaphore(&vb.list_lock);
    const s = serviceAt(vb, src, dst) orelse return;
    const bulk = take(&s.bulks[direction]) orelse {
        log(vb, "a bulk's end came with none out", .{});
        return;
    };
    finish(vb, bulk, actual);
}

/// A bulk done (`actual` its bytes) or given up (negative): what the
/// firmware wrote read from memory and its fragment copied over, its
/// pagelist and fragment free again, and those waiting told. The caller
/// holds `list_lock`.
fn finish(vb: *VchiqBase, bulk: *VchiqBulk, actual: i32) void {
    const sys = vb.sys_base;
    if (actual < 0) {
        bulk.result = vchiq.VCHIQERR_ABORTED;
        bulk.actual = 0;
    } else {
        bulk.result = vchiq.VCHIQERR_OK;
        bulk.actual = @min(@as(u32, @intCast(actual)), bulk.size);
    }
    if (bulk.direction == vchiq.VCHIQBULK_RECEIVE) {
        var length = bulk.size;
        sys.CachePostDMA(bulk.data.?, &length, 0);
        const fragment = bulk.private[2];
        if (fragment != 0 and bulk.result == vchiq.VCHIQERR_OK) {
            const address = @intFromPtr(bulk.data.?);
            const from: [*]const u8 = @ptrFromInt(vb.memory + layout.fragments_at + (fragment - 1) * layout.fragment_bytes);
            const e = layout.ends(address, bulk.actual);
            const to: [*]u8 = @ptrCast(bulk.data.?);
            if (e.head != 0) @memcpy(to[0..e.head], from[0..e.head]);
            if (e.tail != 0) {
                const tail: [*]u8 = @ptrFromInt(e.tail_at);
                @memcpy(tail[0..e.tail], from[layout.fragment_tail .. layout.fragment_tail + e.tail]);
            }
        }
    }
    release(vb, bulk);
    sys.SignalWaitable(&bulk.done);
}

fn release(vb: *VchiqBase, bulk: *VchiqBulk) void {
    giveBit(&vb.pagelists, @intCast(bulk.private[1]));
    if (bulk.private[2] != 0) giveBit(&vb.fragments, @intCast(bulk.private[2] - 1));
    bulk.private[2] = 0;
}

// --- services ---------------------------------------------------------------

/// An OPEN for `s` sent, and its answer waited for: VCHIQERR_OK, or why
/// not. The caller holds `start_lock`; `s` is in `services` already.
pub fn open(vb: *VchiqBase, s: *Service, fourcc: u32, version: u32, version_min: u32) u32 {
    const sys = vb.sys_base;
    var payload: [12]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], fourcc, .little);
    std.mem.writeInt(u32, payload[4..8], client_id, .little);
    std.mem.writeInt(u16, payload[8..10], @truncate(version), .little);
    std.mem.writeInt(u16, payload[10..12], @truncate(version_min), .little);
    const sent = send(vb, layout.msgid(layout.MSG_OPEN, s.localport, 0), &payload);
    if (sent != vchiq.VCHIQERR_OK) return sent;
    const waits = [_]*exec.Waitable{&s.changed};
    const until = systimer.uptimeUs() + connect_us;
    while (true) {
        sys.ObtainSemaphore(&vb.list_lock);
        const state = s.state;
        sys.ResetWaitable(&s.changed);
        sys.ReleaseSemaphore(&vb.list_lock);
        switch (state) {
            base.SERVICE_OPEN => return vchiq.VCHIQERR_OK,
            base.SERVICE_OPENING => {},
            else => return vchiq.VCHIQERR_REFUSED,
        }
        const now = systimer.uptimeUs();
        if (now > until) return vchiq.VCHIQERR_TIMEOUT;
        _ = sys.WaitForAny(&waits, waits.len, until - now);
    }
}

/// `s` closed: the ARM's CLOSE sent, and the firmware's waited for, a
/// second at most. Its bulks are given up by then.
pub fn close(vb: *VchiqBase, s: *Service) void {
    const sys = vb.sys_base;
    var id: ?u32 = null;
    {
        sys.ObtainSemaphore(&vb.list_lock);
        defer sys.ReleaseSemaphore(&vb.list_lock);
        if (s.state == base.SERVICE_OPEN) {
            s.state = base.SERVICE_CLOSESENT;
            id = layout.msgid(layout.MSG_CLOSE, s.localport, s.remoteport);
        }
    }
    const sent = id orelse return;
    if (send(vb, sent, &.{}) != vchiq.VCHIQERR_OK) return;
    const waits = [_]*exec.Waitable{&s.changed};
    const until = systimer.uptimeUs() + connect_us;
    while (true) {
        sys.ObtainSemaphore(&vb.list_lock);
        const state = s.state;
        sys.ResetWaitable(&s.changed);
        sys.ReleaseSemaphore(&vb.list_lock);
        if (state != base.SERVICE_CLOSESENT) return;
        const now = systimer.uptimeUs();
        if (now > until) {
            log(vb, "the firmware did not answer a CLOSE", .{});
            return;
        }
        _ = sys.WaitForAny(&waits, waits.len, until - now);
    }
}

/// The bulks still out on `s` given up, its messages freed and its port
/// let go. The caller holds `start_lock`.
pub fn forget(vb: *VchiqBase, s: *Service) void {
    const sys = vb.sys_base;
    sys.ObtainSemaphore(&vb.list_lock);
    defer sys.ReleaseSemaphore(&vb.list_lock);
    for (&s.bulks) |*bulks| {
        while (take(bulks)) |bulk| finish(vb, bulk, -1);
    }
    while (s.first) |m| {
        s.first = m.next;
        sys.FreeMem(m, @sizeOf(Message) + m.size);
    }
    s.last = null;
    vb.services[s.localport] = null;
}

/// The next message of `s` taken off its list: null when there is none,
/// and then `arrived` is reset, under the lock the task signals it in.
pub fn nextMessage(vb: *VchiqBase, s: *Service) ?*Message {
    const sys = vb.sys_base;
    sys.ObtainSemaphore(&vb.list_lock);
    defer sys.ReleaseSemaphore(&vb.list_lock);
    const m = s.first orelse {
        if (s.state == base.SERVICE_OPEN) sys.ResetWaitable(&s.arrived);
        return null;
    };
    s.first = m.next;
    if (s.first == null) s.last = null;
    return m;
}

test {
    _ = layout;
}
