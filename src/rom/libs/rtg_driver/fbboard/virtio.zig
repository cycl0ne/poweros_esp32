// SPDX-License-Identifier: MPL-2.0
//! QEMU's virtio GPU (CHIP_VIRTIO_GPU) on one of the virt machine's
//! virtio-mmio transports: `-device virtio-gpu-device`. Its 2D commands
//! alone, which are all a picture in RAM needs.
//!
//! Unlike the ramfb it does not read the machine's RAM by itself: a
//! picture is a resource, a copy the emulator keeps, whose backing is the
//! buffer in RAM. A rectangle written into the picture shown is copied
//! into that copy (TRANSFER_TO_HOST_2D) and shown (RESOURCE_FLUSH) at
//! once. One written into another buffer is only noted: what was written
//! there since, gathered into one rectangle, is copied when the buffer is
//! shown, by naming its resource (SET_SCANOUT) - a buffer drawn ahead
//! costs one copy at the flip, not one a drawing. Each buffer the display
//! may show is a resource of its own, made the first time it is shown:
//! the library cuts buffers wherever its arena has room, so one resource
//! over all of them would not have their rows where they are.
//!
//! The pointer is the device's cursor, an image 64 pixels square that the
//! emulator's window lays over the picture itself - with a tablet, as the
//! host's own pointer - set and moved on a queue of its own.
//!
//! Commands go to the device on a virtqueue: a table of descriptors, each
//! a stretch of RAM; a ring the driver names the commands it hands over
//! in; a ring the device names those it is done with in. A command is two
//! stretches of a slot of its own, what it asks and room for the answer,
//! and the slot is free again once the device has named it. The device is
//! told by a register write (QueueNotify). Nothing waits for it unless the
//! next step needs it done: the screen's size at the start, an image for
//! the cursor, a slot when every one is with the device.
//!
//! virtio-mmio comes in two versions: 1, the legacy one, which QEMU gives
//! unless told otherwise (`-global virtio-mmio.force-legacy=false`), is
//! told where a queue is by its page; 2 by the addresses of its three
//! parts. Both are taken. Its interrupts are not used: the rings are
//! looked at.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const reg = sdk.hardware.mmio.reg;
const barrier = sdk.hardware.barrier;

// --- the transport ----------------------------------------------------------------

const MAGIC = 0x000;
const VERSION = 0x004;
const DEVICE_ID = 0x008;
const DEVICE_FEATURES = 0x010;
const DEVICE_FEATURES_SEL = 0x014;
const DRIVER_FEATURES = 0x020;
const DRIVER_FEATURES_SEL = 0x024;
/// Version 1's: the page size its queues' places are counted in.
const GUEST_PAGE_SIZE = 0x028;
const QUEUE_SEL = 0x030;
const QUEUE_NUM_MAX = 0x034;
const QUEUE_NUM = 0x038;
/// Version 1's: where the device's ring starts, and the queue's page.
const QUEUE_ALIGN = 0x03C;
const QUEUE_PFN = 0x040;
/// Version 2's: the queue taken, and its parts' addresses, low word first.
const QUEUE_READY = 0x044;
const QUEUE_NOTIFY = 0x050;
const STATUS = 0x070;
const QUEUE_DESC = 0x080;
const QUEUE_DRIVER = 0x090;
const QUEUE_DEVICE = 0x0A0;

/// "virt", little-endian.
const MAGIC_VALUE: u32 = 0x7472_6976;
const DEVICE_GPU: u32 = 16;

const STATUS_ACKNOWLEDGE: u32 = 1;
const STATUS_DRIVER: u32 = 2;
const STATUS_DRIVER_OK: u32 = 4;
const STATUS_FEATURES_OK: u32 = 8;

/// VIRTIO_F_VERSION_1, feature 32: the second word's first bit. Version 2
/// is refused without it.
const FEATURE_VERSION_1: u32 = 1 << 0;

// --- the queues ----------------------------------------------------------------------

const page = 4096;

const Descriptor = extern struct {
    address: u64,
    length: u32,
    flags: u16,
    next: u16,
};
const DESC_NEXT: u16 = 1;
const DESC_WRITE: u16 = 2;

/// The driver's ring's flags: no interrupt wanted.
const AVAIL_NO_INTERRUPT: u16 = 1;

const Used = extern struct {
    id: u32,
    length: u32,
};

/// Where a queue of `size` entries has the device's ring, as version 1
/// lays it out and version 2 is told: past the descriptors and the
/// driver's ring, on a page of its own.
fn usedAt(size: u32) usize {
    return std.mem.alignForward(usize, 16 * size + 2 * (3 + size), page);
}

/// The whole of such a queue, in pages.
fn queueBytes(size: u32) usize {
    return std.mem.alignForward(usize, usedAt(size) + 2 * 3 + 8 * size, page);
}

/// One queue, as the driver sees it: its three parts, the driver's next
/// entry, and the device's next to look at.
const Queue = struct {
    size: u16 = 0,
    descriptors: [*]volatile Descriptor = undefined,
    /// Flags, index, then the ring.
    avail: [*]volatile u16 = undefined,
    /// Flags and index; the ring is `done`.
    used: [*]volatile u16 = undefined,
    done: [*]volatile Used = undefined,
    next: u16 = 0,
    seen: u16 = 0,

    fn at(address: usize, size: u16) Queue {
        return .{
            .size = size,
            .descriptors = @ptrFromInt(address),
            .avail = @ptrFromInt(address + 16 * @as(usize, size)),
            .used = @ptrFromInt(address + usedAt(size)),
            .done = @ptrFromInt(address + usedAt(size) + 4),
        };
    }

    /// The command whose first descriptor is `head` handed to the device:
    /// its entry in the ring before the index that says it is there.
    fn hand(queue: *Queue, head: u16) void {
        queue.avail[2 + queue.next % queue.size] = head;
        barrier.full();
        queue.next +%= 1;
        queue.avail[1] = queue.next;
    }
};

/// The control queue: two descriptors a command, a slot each. Its most
/// entries: a device that offers fewer gets a queue of its size, and the
/// slots past it go unused - QEMU's GPU offers 64.
const control_size = 128;
const control_slots = control_size / 2;
/// The cursor queue: a descriptor a command, with no answer; its most
/// entries as well.
const cursor_size = 16;

/// A control command: what it asks, and room for the answer it gets.
const Slot = extern struct {
    request: [64]u8 align(8),
    response: [32]u8 align(8),
};

// --- the commands --------------------------------------------------------------------

const CMD_GET_DISPLAY_INFO: u32 = 0x0100;
const CMD_RESOURCE_CREATE_2D: u32 = 0x0101;
const CMD_RESOURCE_UNREF: u32 = 0x0102;
const CMD_SET_SCANOUT: u32 = 0x0103;
const CMD_RESOURCE_FLUSH: u32 = 0x0104;
const CMD_TRANSFER_TO_HOST_2D: u32 = 0x0105;
const CMD_RESOURCE_ATTACH_BACKING: u32 = 0x0106;
const CMD_UPDATE_CURSOR: u32 = 0x0300;
const CMD_MOVE_CURSOR: u32 = 0x0301;
const RESP_OK_DISPLAY_INFO: u32 = 0x1101;
/// The first answer that says a command failed.
const RESP_ERR_UNSPEC: u32 = 0x1200;

/// The formats, by the order of their bytes in memory: bgra32's, without
/// its alpha for a picture and with it for the cursor.
const FORMAT_B8G8R8A8: u32 = 1;
const FORMAT_B8G8R8X8: u32 = 2;

const Header = extern struct {
    type: u32,
    flags: u32 = 0,
    fence_id: u64 = 0,
    ctx_id: u32 = 0,
    ring_idx: u8 = 0,
    padding: [3]u8 = @splat(0),
};

/// A rectangle of a resource, in pixels.
pub const Rect = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

const DisplayInfo = extern struct {
    header: Header,
    modes: [16]extern struct {
        r: Rect,
        enabled: u32,
        flags: u32,
    },
};

const Create2d = extern struct {
    header: Header = .{ .type = CMD_RESOURCE_CREATE_2D },
    resource_id: u32,
    format: u32,
    width: u32,
    height: u32,
};

const Unref = extern struct {
    header: Header = .{ .type = CMD_RESOURCE_UNREF },
    resource_id: u32,
    padding: u32 = 0,
};

const AttachBacking = extern struct {
    header: Header = .{ .type = CMD_RESOURCE_ATTACH_BACKING },
    resource_id: u32,
    entries: u32 = 1,
    address: u64,
    length: u32,
    padding: u32 = 0,
};

const SetScanout = extern struct {
    header: Header = .{ .type = CMD_SET_SCANOUT },
    r: Rect,
    scanout_id: u32 = 0,
    resource_id: u32,
};

const Flush = extern struct {
    header: Header = .{ .type = CMD_RESOURCE_FLUSH },
    r: Rect,
    resource_id: u32,
    padding: u32 = 0,
};

const Transfer = extern struct {
    header: Header = .{ .type = CMD_TRANSFER_TO_HOST_2D },
    r: Rect,
    offset: u64,
    resource_id: u32,
    padding: u32 = 0,
};

const Cursor = extern struct {
    header: Header,
    scanout_id: u32 = 0,
    x: u32,
    y: u32,
    padding: u32 = 0,
    resource_id: u32,
    hot_x: u32 = 0,
    hot_y: u32 = 0,
    padding2: u32 = 0,
};

// --- the device ----------------------------------------------------------------------

/// The cursor's image, each way: QEMU's cursor, which takes nothing else.
pub const cursor_side = 64;

/// A buffer the display may show: its pixels, its rows' pitch, how many.
pub const Picture = struct {
    pixels: usize,
    pitch: u32,
    height: u32,
};

/// A picture the display may be shown: which buffer it is (pixels 0: the
/// entry is free), its resource (id 0: none yet, it has not been shown),
/// when it was last handed on, and what was written into it since its
/// copy was brought up to date - columns `left` up to `right`, rows `top`
/// up to `end`; `right` 0 for nothing.
const Resource = struct {
    pixels: usize = 0,
    pitch: u32 = 0,
    height: u32 = 0,
    id: u32 = 0,
    used: u32 = 0,
    left: u32 = 0,
    top: u32 = 0,
    right: u32 = 0,
    end: u32 = 0,

    /// `rect` written: gathered with what was before.
    fn note(resource: *Resource, rect: Rect) void {
        const right = rect.x + rect.width;
        const end = rect.y + rect.height;
        if (resource.right == 0) {
            resource.left = rect.x;
            resource.top = rect.y;
            resource.right = right;
            resource.end = end;
            return;
        }
        resource.left = @min(resource.left, rect.x);
        resource.top = @min(resource.top, rect.y);
        resource.right = @max(resource.right, right);
        resource.end = @max(resource.end, end);
    }
};

/// The most pictures followed at once: every buffer the board holds, the
/// composed frame, and room for buffers given back and made again
/// elsewhere. The one used longest ago goes first.
const max_resources = 8;

/// How many times the rings are looked at before the wait for one is
/// given up: the first times at once, then a millisecond apart.
const spins = 64;
const patience = spins + 1000;

/// The block the queues and the commands are in, page by page.
const layout = struct {
    const control = 0;
    const cursor = control + queueBytes(control_size);
    const slots = cursor + queueBytes(cursor_size);
    const cursors = slots + control_slots * @sizeOf(Slot);
    const answer = std.mem.alignForward(usize, cursors + cursor_size * @sizeOf(Cursor), 8);
    const bytes = answer + @sizeOf(DisplayInfo);
};

/// One GPU, from `find` on; `start` brings it up.
pub const Gpu = struct {
    /// Its transport's registers, and the transport's version.
    base: usize,
    version: u32,
    sys: *ExecBase = undefined,
    /// The block the queues and the commands are in, as AllocMem gave it.
    memory: ?*anyopaque = null,
    memory_size: usize = 0,
    control: Queue = .{},
    cursor: Queue = .{},
    slots: [*]Slot = undefined,
    cursors: [*]Cursor = undefined,
    answer: *DisplayInfo = undefined,
    /// Which control slots and which cursor commands are with the device.
    busy: u64 = 0,
    cursor_busy: u16 = 0,
    /// Held while the queues, or what the device has been told, change:
    /// any task may draw, the pointer moves on another.
    lock: exec.SignalSemaphore = .{},
    /// The pictures' resources, the ids the next one and the cursor's
    /// two images get, and which are shown.
    resources: [max_resources]Resource = @splat(.{}),
    uses: u32 = 0,
    next_id: u32 = 1,
    shown: u32 = 0,
    cursor_ids: [2]u32 = .{ 0, 0 },
    cursor_id: u32 = 0,
    /// Whether a command failing has been said on the raw port: once.
    told: bool = false,

    fn read(gpu: *const Gpu, offset: usize) u32 {
        return reg(gpu.base + offset).*;
    }

    fn write(gpu: *const Gpu, offset: usize, value: u32) void {
        reg(gpu.base + offset).* = value;
    }

    fn write64(gpu: *const Gpu, offset: usize, value: usize) void {
        gpu.write(offset, @truncate(value));
        gpu.write(offset + 4, @truncate(@as(u64, value) >> 32));
    }
};

/// The first of `count` transports `stride` bytes apart from `base` that
/// has a GPU behind it. QEMU puts the first `-device` on the last
/// transport, so all are looked at.
pub fn find(base: usize, count: u32, stride: usize) ?Gpu {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const at = base + i * stride;
        if (reg(at + MAGIC).* != MAGIC_VALUE) continue;
        const version = reg(at + VERSION).*;
        if (version != 1 and version != 2) continue;
        if (reg(at + DEVICE_ID).* != DEVICE_GPU) continue;
        return .{ .base = at, .version = version };
    }
    return null;
}

/// The device reset and brought up with both queues, in a block of its
/// own. False, and nothing kept, when it will not come up.
pub fn start(gpu: *Gpu, sys: *ExecBase) bool {
    gpu.sys = sys;
    sys.InitSemaphore(&gpu.lock);
    gpu.memory_size = layout.bytes + page;
    gpu.memory = sys.AllocMem(gpu.memory_size, exec.MEMF_DMA | exec.MEMF_CLEAR) orelse {
        gpu.memory_size = 0;
        return false;
    };
    const base = std.mem.alignForward(usize, @intFromPtr(gpu.memory.?), page);
    gpu.slots = @ptrFromInt(base + layout.slots);
    gpu.cursors = @ptrFromInt(base + layout.cursors);
    gpu.answer = @ptrFromInt(base + layout.answer);

    gpu.write(STATUS, 0);
    var status = STATUS_ACKNOWLEDGE | STATUS_DRIVER;
    gpu.write(STATUS, status);
    // None of its features: no 3D, no EDID. Version 2 wants to hear that
    // it is spoken to as version 1 of the standard says.
    if (gpu.version == 2) {
        gpu.write(DEVICE_FEATURES_SEL, 1);
        if (gpu.read(DEVICE_FEATURES) & FEATURE_VERSION_1 == 0) return fail(gpu);
        gpu.write(DRIVER_FEATURES_SEL, 1);
        gpu.write(DRIVER_FEATURES, FEATURE_VERSION_1);
        gpu.write(DRIVER_FEATURES_SEL, 0);
        gpu.write(DRIVER_FEATURES, 0);
        status |= STATUS_FEATURES_OK;
        gpu.write(STATUS, status);
        if (gpu.read(STATUS) & STATUS_FEATURES_OK == 0) return fail(gpu);
    } else {
        gpu.write(DRIVER_FEATURES_SEL, 0);
        gpu.write(DRIVER_FEATURES, 0);
        gpu.write(GUEST_PAGE_SIZE, page);
    }
    if (!setUpQueue(gpu, 0, &gpu.control, base + layout.control, control_size)) return fail(gpu);
    if (!setUpQueue(gpu, 1, &gpu.cursor, base + layout.cursor, cursor_size)) return fail(gpu);
    // What a smaller queue has no room for is held from the start, so it
    // is never handed out.
    const slots = gpu.control.size / 2;
    gpu.busy = if (slots < control_slots) ~@as(u64, 0) << @intCast(slots) else 0;
    gpu.cursor_busy = if (gpu.cursor.size < cursor_size) ~@as(u16, 0) << @intCast(gpu.cursor.size) else 0;
    gpu.write(STATUS, status | STATUS_DRIVER_OK);
    return true;
}

fn fail(gpu: *Gpu) bool {
    stop(gpu);
    return false;
}

/// The device reset - which lets go of its queues and every resource -
/// and the block given back.
pub fn stop(gpu: *Gpu) void {
    gpu.write(STATUS, 0);
    if (gpu.memory) |memory| gpu.sys.FreeMem(memory, gpu.memory_size);
    gpu.memory = null;
    gpu.memory_size = 0;
}

/// Queue `index` at `address`, as many entries as the device offers up to
/// `most`, told to the device as its version wants it. False when it
/// offers too few for a command.
fn setUpQueue(gpu: *Gpu, index: u32, queue: *Queue, address: usize, most: u16) bool {
    gpu.write(QUEUE_SEL, index);
    const offered = gpu.read(QUEUE_NUM_MAX);
    if (offered < 2) return false;
    const size: u16 = @intCast(@min(offered, most));
    queue.* = Queue.at(address, size);
    queue.avail[0] = AVAIL_NO_INTERRUPT;
    gpu.write(QUEUE_NUM, size);
    if (gpu.version == 1) {
        gpu.write(QUEUE_ALIGN, page);
        gpu.write(QUEUE_PFN, @truncate(address / page));
    } else {
        gpu.write64(QUEUE_DESC, address);
        gpu.write64(QUEUE_DRIVER, address + 16 * @as(usize, size));
        gpu.write64(QUEUE_DEVICE, address + usedAt(size));
        gpu.write(QUEUE_READY, 1);
    }
    return true;
}

/// The device told to look at queue `index`.
fn kick(gpu: *Gpu, index: u32) void {
    barrier.toDevice();
    gpu.write(QUEUE_NOTIFY, index);
}

/// Waited for a moment, the `tries`th time: at once at first, then with
/// the CPU given away.
fn rest(tries: u32, waiter: anytype) void {
    if (tries < spins) {
        std.atomic.spinLoopHint();
    } else {
        waiter.wait(1000);
    }
}

/// The control commands the device is done with, their slots free again;
/// the first that failed said on the raw port.
fn reclaim(gpu: *Gpu) void {
    const queue = &gpu.control;
    const done = queue.used[1];
    barrier.reads();
    while (queue.seen != done) : (queue.seen +%= 1) {
        const slot = queue.done[queue.seen % queue.size].id / 2;
        if (slot >= control_slots) continue;
        const asked: *const Header = @ptrCast(&gpu.slots[slot].request);
        const answer: *const Header = @ptrCast(&gpu.slots[slot].response);
        if (answer.type >= RESP_ERR_UNSPEC and !gpu.told) {
            exec.kprintf(gpu.sys, "rtg-fb: the virtio GPU answered 0x%x to command 0x%x\n", .{ answer.type, asked.type });
            gpu.told = true;
        }
        gpu.busy &= ~(@as(u64, 1) << @intCast(slot));
    }
}

/// A slot the device is not holding, waited for while every one is - the
/// device told first, since commands handed over without a `kick` yet
/// may be what fills a small queue.
fn freeSlot(gpu: *Gpu, waiter: anytype) ?u32 {
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        reclaim(gpu);
        if (~gpu.busy != 0) return @ctz(~gpu.busy);
        if (tries == 0) kick(gpu, 0);
        if (tries == patience) return null;
        rest(tries, waiter);
    }
}

/// A control command handed over, its answer into `answer` - the slot's
/// own room when null. Its slot; null when none came free. The device is
/// told by the next `kick`.
fn send(gpu: *Gpu, request: anytype, answer: ?[]u8, waiter: anytype) ?u32 {
    const slot = freeSlot(gpu, waiter) orelse return null;
    const at = &gpu.slots[slot];
    const asked = std.mem.asBytes(request);
    @memcpy(at.request[0..asked.len], asked);
    const into = answer orelse at.response[0..];
    @as(*Header, @ptrCast(&at.response)).type = 0;
    const head: u16 = @intCast(2 * slot);
    gpu.control.descriptors[head] = .{ .address = @intFromPtr(&at.request), .length = @intCast(asked.len), .flags = DESC_NEXT, .next = head + 1 };
    gpu.control.descriptors[head + 1] = .{ .address = @intFromPtr(into.ptr), .length = @intCast(into.len), .flags = DESC_WRITE, .next = 0 };
    gpu.busy |= @as(u64, 1) << @intCast(slot);
    gpu.control.hand(head);
    return slot;
}

/// Until the device is done with the command in `slot`. False when it was
/// not within a second.
fn finish(gpu: *Gpu, slot: u32, waiter: anytype) bool {
    const bit = @as(u64, 1) << @intCast(slot);
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        reclaim(gpu);
        if (gpu.busy & bit == 0) return true;
        if (tries == patience) return false;
        rest(tries, waiter);
    }
}

/// A cursor command handed over and the device told: the cursor queue's
/// commands are carried out before the write that tells it returns, so a
/// slot is free again by the next.
fn sendCursor(gpu: *Gpu, command: Cursor) void {
    const queue = &gpu.cursor;
    const done = queue.used[1];
    barrier.reads();
    while (queue.seen != done) : (queue.seen +%= 1) {
        const index = queue.done[queue.seen % queue.size].id;
        if (index < cursor_size) gpu.cursor_busy &= ~(@as(u16, 1) << @intCast(index));
    }
    // A move nobody waits for is dropped rather than waited for.
    if (~gpu.cursor_busy == 0) return;
    const index: u16 = @ctz(~gpu.cursor_busy);
    gpu.cursors[index] = command;
    queue.descriptors[index] = .{ .address = @intFromPtr(&gpu.cursors[index]), .length = @sizeOf(Cursor), .flags = 0, .next = 0 };
    gpu.cursor_busy |= @as(u16, 1) << @intCast(index);
    queue.hand(index);
    kick(gpu, 1);
}

/// The size of the picture the emulator's window has for the display,
/// when it says one.
pub fn displaySize(gpu: *Gpu, waiter: anytype) ?struct { width: u32, height: u32 } {
    gpu.sys.ObtainSemaphore(&gpu.lock);
    defer gpu.sys.ReleaseSemaphore(&gpu.lock);
    gpu.answer.header.type = 0;
    const asked = Header{ .type = CMD_GET_DISPLAY_INFO };
    const slot = send(gpu, &asked, std.mem.asBytes(gpu.answer), waiter) orelse return null;
    kick(gpu, 0);
    if (!finish(gpu, slot, waiter)) return null;
    if (gpu.answer.header.type != RESP_OK_DISPLAY_INFO) return null;
    const first = gpu.answer.modes[0];
    if (first.enabled == 0 or first.r.width < 16 or first.r.height < 16) return null;
    return .{ .width = first.r.width, .height = first.r.height };
}

/// A resource of `format`, `pitch / 4` by `height`, backed by the bytes at
/// `pixels`: its id, 0 when the commands could not be handed over.
fn makeResource(gpu: *Gpu, pixels: usize, pitch: u32, height: u32, format: u32, waiter: anytype) u32 {
    const id = gpu.next_id;
    const made = Create2d{ .resource_id = id, .format = format, .width = pitch / 4, .height = height };
    _ = send(gpu, &made, null, waiter) orelse return 0;
    gpu.next_id += 1;
    const backing = AttachBacking{ .resource_id = id, .address = pixels, .length = pitch * height };
    _ = send(gpu, &backing, null, waiter) orelse return 0;
    return id;
}

/// The entry of `picture`, taken for it when it has none - the one used
/// longest ago that is not shown let go for it, when all are taken.
fn entryOf(gpu: *Gpu, picture: Picture, waiter: anytype) ?*Resource {
    gpu.uses +%= 1;
    // An entry for it: a free one, else the one used longest ago.
    var spare: ?*Resource = null;
    for (&gpu.resources) |*one| {
        if (one.pixels == picture.pixels and one.pitch == picture.pitch and one.height == picture.height) {
            one.used = gpu.uses;
            return one;
        }
        if (one.id != 0 and one.id == gpu.shown) continue;
        if (spare) |best| {
            if (best.pixels == 0) continue;
            if (one.pixels == 0 or gpu.uses -% one.used > gpu.uses -% best.used) spare = one;
        } else spare = one;
    }
    const entry = spare orelse return null;
    if (entry.id != 0) {
        const gone = Unref{ .resource_id = entry.id };
        _ = send(gpu, &gone, null, waiter) orelse return null;
    }
    entry.* = .{ .pixels = picture.pixels, .pitch = picture.pitch, .height = picture.height, .used = gpu.uses };
    return entry;
}

/// `rect` of the resource `id`, whose rows are `pitch` bytes apart, copied
/// from its backing into the emulator's copy. Its slot.
fn transfer(gpu: *Gpu, id: u32, pitch: u32, rect: Rect, waiter: anytype) ?u32 {
    const copy = Transfer{ .r = rect, .offset = @as(u64, rect.y) * pitch + @as(u64, rect.x) * 4, .resource_id = id };
    return send(gpu, &copy, null, waiter);
}

/// `rect` of `picture` written: copied into the emulator's copy and shown
/// where the picture is the one shown, else noted for when it is.
pub fn update(gpu: *Gpu, picture: Picture, rect: Rect, waiter: anytype) void {
    if (rect.width == 0 or rect.height == 0) return;
    gpu.sys.ObtainSemaphore(&gpu.lock);
    defer gpu.sys.ReleaseSemaphore(&gpu.lock);
    const entry = entryOf(gpu, picture, waiter) orelse return;
    if (entry.id == 0 or entry.id != gpu.shown) return entry.note(rect);
    _ = transfer(gpu, entry.id, picture.pitch, rect, waiter) orelse return;
    const shown = Flush{ .r = rect, .resource_id = entry.id };
    _ = send(gpu, &shown, null, waiter);
    kick(gpu, 0);
}

/// The emulator's copy of the picture at `pixels` let go of, as its
/// memory is given back: a picture made there later starts afresh and is
/// copied whole. The one shown is kept.
pub fn forget(gpu: *Gpu, pixels: usize, waiter: anytype) void {
    gpu.sys.ObtainSemaphore(&gpu.lock);
    defer gpu.sys.ReleaseSemaphore(&gpu.lock);
    for (&gpu.resources) |*one| {
        if (one.pixels != pixels or one.id == 0 or one.id == gpu.shown) continue;
        const gone = Unref{ .resource_id = one.id };
        _ = send(gpu, &gone, null, waiter) orelse return;
        kick(gpu, 0);
        one.* = .{};
    }
}

/// `picture` shown, `width` by `height` of it from its top left: its
/// resource made the first time - and copied whole - and what was written
/// into it while another was shown copied first.
pub fn show(gpu: *Gpu, picture: Picture, width: u32, height: u32, waiter: anytype) bool {
    gpu.sys.ObtainSemaphore(&gpu.lock);
    defer gpu.sys.ReleaseSemaphore(&gpu.lock);
    const entry = entryOf(gpu, picture, waiter) orelse return false;
    const whole = Rect{ .x = 0, .y = 0, .width = width, .height = height };
    if (entry.id == 0) {
        entry.id = makeResource(gpu, picture.pixels, picture.pitch, picture.height, FORMAT_B8G8R8X8, waiter);
        if (entry.id == 0) return false;
        entry.note(whole);
    }
    if (entry.right != 0) {
        const written = Rect{ .x = entry.left, .y = entry.top, .width = entry.right - entry.left, .height = entry.end - entry.top };
        _ = transfer(gpu, entry.id, picture.pitch, written, waiter) orelse return false;
        entry.right = 0;
    }
    const scanout = SetScanout{ .r = whole, .resource_id = entry.id };
    _ = send(gpu, &scanout, null, waiter) orelse return false;
    const shown = Flush{ .r = whole, .resource_id = entry.id };
    _ = send(gpu, &shown, null, waiter) orelse return false;
    kick(gpu, 0);
    gpu.shown = entry.id;
    return true;
}

/// The cursor's image: the one at `image` (`cursor_side` square, its
/// alpha in its fourth bytes), which is the buffer of turn `turn`, with
/// its hot spot at (`hot_x`, `hot_y`) of it and at (`x`, `y`) of the
/// picture. The image is in the emulator's copy before the cursor is
/// told to take it: the two queues keep no order between them.
pub fn setCursor(gpu: *Gpu, image: [*]const u8, turn: u1, hot_x: u32, hot_y: u32, x: u32, y: u32, waiter: anytype) void {
    gpu.sys.ObtainSemaphore(&gpu.lock);
    defer gpu.sys.ReleaseSemaphore(&gpu.lock);
    const pitch = cursor_side * 4;
    if (gpu.cursor_ids[turn] == 0) gpu.cursor_ids[turn] = makeResource(gpu, @intFromPtr(image), pitch, cursor_side, FORMAT_B8G8R8A8, waiter);
    const id = gpu.cursor_ids[turn];
    if (id == 0) return;
    const slot = transfer(gpu, id, pitch, .{ .x = 0, .y = 0, .width = cursor_side, .height = cursor_side }, waiter) orelse return;
    kick(gpu, 0);
    if (!finish(gpu, slot, waiter)) return;
    gpu.cursor_id = id;
    sendCursor(gpu, .{ .header = .{ .type = CMD_UPDATE_CURSOR }, .x = x, .y = y, .resource_id = id, .hot_x = hot_x, .hot_y = hot_y });
}

/// The cursor's hot spot moved to (`x`, `y`) of the picture.
pub fn moveCursor(gpu: *Gpu, x: u32, y: u32) void {
    gpu.sys.ObtainSemaphore(&gpu.lock);
    defer gpu.sys.ReleaseSemaphore(&gpu.lock);
    sendCursor(gpu, .{ .header = .{ .type = CMD_MOVE_CURSOR }, .x = x, .y = y, .resource_id = gpu.cursor_id });
}

test "the commands are as long as the device reads them" {
    try std.testing.expectEqual(24, @sizeOf(Header));
    try std.testing.expectEqual(24 + 16 * 24, @sizeOf(DisplayInfo));
    try std.testing.expectEqual(40, @sizeOf(Create2d));
    try std.testing.expectEqual(32, @sizeOf(Unref));
    try std.testing.expectEqual(48, @sizeOf(AttachBacking));
    try std.testing.expectEqual(48, @sizeOf(SetScanout));
    try std.testing.expectEqual(48, @sizeOf(Flush));
    try std.testing.expectEqual(56, @sizeOf(Transfer));
    try std.testing.expectEqual(56, @sizeOf(Cursor));
    try std.testing.expectEqual(40, @offsetOf(Transfer, "offset"));
    try std.testing.expectEqual(32, @offsetOf(AttachBacking, "address"));
}

test "a queue's device ring is on the page after its driver ring" {
    // 128 entries: 2 KiB of descriptors, 262 bytes of driver ring.
    try std.testing.expectEqual(4096, usedAt(128));
    try std.testing.expectEqual(8192, queueBytes(128));
    try std.testing.expectEqual(4096, usedAt(16));
    // A smaller queue, as QEMU's GPU offers, fits where the largest goes.
    try std.testing.expectEqual(4096, usedAt(64));
    try std.testing.expect(queueBytes(64) <= queueBytes(control_size));
    try std.testing.expect(layout.bytes <= 6 * page);
    try std.testing.expect(@sizeOf(Transfer) <= @sizeOf(@FieldType(Slot, "request")));
}
