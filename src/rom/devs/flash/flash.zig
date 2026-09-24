// SPDX-License-Identifier: MPL-2.0
//! flash.device: the board's SPI flash as a block device. Unit 0 is the
//! disk area, everything past the kernel image: from the board's
//! SYSTAG_DiskOffset (2 MiB unless the build says otherwise) to the end of
//! the chip (SYSTAG_FlashSize). Its API is trackdisk.device's
//! (sdk/devices/trackdisk.zig).
//!
//!   CMD_READ         io_Length bytes from io_Offset into io_Data. Served
//!                    in BeginIO from the mapped window, so DoIO gets it as
//!                    quick I/O: a read costs a memcpy, no SPI at all.
//!   CMD_WRITE        io_Length bytes from io_Data at io_Offset, a 256-byte
//!                    page at a time. The range must be erased first.
//!   TDCMD_ERASE      the 4 KiB sectors io_Offset .. io_Offset+io_Length,
//!                    both multiples of 4096.
//!   TD_FORMAT        erases the whole unit (minutes: 3840 sectors).
//!   CMD_UPDATE       nothing is buffered, so it only answers.
//!   CMD_CLEAR        the same.
//!   TD_GETGEOMETRY   into io_Data: the unit's size, its erase and program
//!                    units, and where it is mapped.
//!   TD_GETNUMTRACKS  io_Actual: the unit's 4 KiB sectors.
//!   TD_PROTSTATUS    io_Actual: 0, the medium is writable.
//!   TD_CHANGENUM     io_Actual: 0, it never changed.
//!   TD_CHANGESTATE   io_Actual: 0, a medium is in.
//!
//! **Every erase and program runs on the device's own task**, not in the
//! caller's BeginIO, because SPI1 shares the bus with the caches: while a
//! command runs both caches are suspended, and then neither the code in
//! flash nor anything in PSRAM may be touched - including the stack, and a
//! task's stack is in PSRAM. The device's task has one in internal SRAM.
//! Interrupts are off for the same reason (the exception dispatcher is in
//! flash), one sector or one page at a time: an erase is tens of
//! milliseconds, a page well under one. The kernel's tick loses a few
//! counts per erase; the E-clock and uptime (SYSTIMER) don't.
//!
//! The caller's buffer may be in PSRAM too, so every write goes through the
//! 256-byte buffer src/rom/devs/flash/spiflash.zig keeps in internal SRAM.
//!
//! io_Offset and io_Length are bytes, 64-bit; there is no motor, no
//! seeking, no removal and no ETD_*; TDCMD_ERASE exists since flash must be
//! erased before it is written. The device never
//! expunges: it owns its task and the unit's mapping, and dos's file system
//! sits on it (dos.library keeps itself for the same reason).

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const td = sdk.devices.trackdisk;
const ExecBase = sdk.interface.exec.ExecBase;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const spiflash = @import("spiflash.zig");

pub const DEVICE_NAME = td.FLASHNAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "16.9.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The task's stack, in internal SRAM (MEMF_INTERNAL): a flash command runs
/// with the data cache suspended, so a stack in PSRAM would fault on the
/// first register-window spill.
const stack_size = 4096;
/// Above dos's processes, below the kernel's tick users: a flash command
/// holds the CPU anyway, and the file system waits for it.
const task_pri = 5;

const vec = exec.libraries.vec;

/// The device's base. One unit, whose port is the task's work queue.
const FlashBase = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    unit: exec.Unit,
    /// The task every erase and program runs on.
    task: exec.Task,
    /// Its stack, as AllocMem gave it.
    stack: ?*anyopaque = null,
    /// The chip's size, from the board's SYSTAG_FlashSize.
    chip_size: u32 = 0,
    /// The unit's first byte in flash and its size.
    offset: u32 = 0,
    size: u32 = 0,
    /// The unit's first byte in the CPU's address space, 0 if the mapping
    /// failed.
    map: usize = 0,
    /// The task that started this one, and the signal it waits on until
    /// the chip is set up. Cleared once that is done.
    starter: ?*exec.Task = null,
    start_signal: u8 = 0,
};

fn flashBase(dev: *exec.Device) *FlashBase {
    return @fieldParentPtr("dev", dev);
}

/// The base of the request's unit.
fn baseOf(io: *exec.IORequest) *FlashBase {
    const unit = io.unit.?;
    return @fieldParentPtr("unit", unit);
}

fn stdReq(io: *exec.IORequest) *exec.IOStdReq {
    return @alignCast(@fieldParentPtr("req", io));
}

/// The request a message on the unit's port belongs to.
fn requestOf(msg: *exec.Message) *exec.IORequest {
    return @fieldParentPtr("message", msg);
}

// --- the medium -----------------------------------------------------------

/// Whether a range is inside the unit. An empty one at the very end is
/// fine, as a read of no bytes is.
fn inside(fb: *FlashBase, offset: u64, len: u64) bool {
    return offset <= fb.size and len <= fb.size - offset;
}

/// The unit's bytes, if it is mapped.
fn window(fb: *FlashBase) ?[]const u8 {
    if (fb.map == 0) return null;
    const p: [*]const u8 = @ptrFromInt(fb.map);
    return p[0..fb.size];
}

/// `len` bytes from the unit's `offset` into `dest`. Through the mapping if
/// there is one, else over SPI1 in page-sized pieces through the buffer in
/// internal SRAM (the caller's may be in PSRAM, which a flash command can't
/// reach).
fn read(fb: *FlashBase, offset: u32, dest: [*]u8, len: u32) bool {
    if (window(fb)) |bytes| {
        @memcpy(dest[0..len], bytes[offset..][0..len]);
        return true;
    }
    const sys = fb.sys_base;
    const buffer = spiflash.pageBuffer();
    var done: u32 = 0;
    while (done < len) {
        const piece: u32 = @min(spiflash.page_size, len - done);
        sys.Disable();
        const ok = spiflash.readRaw(fb.offset + offset + done, @ptrCast(buffer), piece);
        sys.Enable();
        if (!ok) return false;
        @memcpy(dest[done..][0..piece], buffer[0..piece]);
        done += piece;
    }
    return true;
}

/// `len` bytes from `src` at the unit's `offset`, one program at a time and
/// never across a page boundary. The range must have been erased.
///
/// The ROM's write takes whole words at a word-aligned address, so a piece
/// that doesn't start or end on one is padded with 0xFF: programming a one
/// bit clears nothing, so the bytes around the piece keep what they hold.
fn program(fb: *FlashBase, offset: u32, src: [*]const u8, len: u32) bool {
    const sys = fb.sys_base;
    const buffer = spiflash.pageBuffer();
    var done: u32 = 0;
    while (done < len) {
        const at = fb.offset + offset + done;
        const start = at & ~@as(u32, 3);
        const lead = at - start;
        const piece: u32 = @min(spiflash.page_size - at % spiflash.page_size, len - done);
        const whole = std.mem.alignForward(u32, lead + piece, 4);
        @memset(buffer[0..whole], 0xFF);
        @memcpy(buffer[lead..][0..piece], src[done..][0..piece]);
        sys.Disable();
        const ok = spiflash.programPage(start, whole);
        sys.Enable();
        if (!ok) return false;
        done += piece;
    }
    return true;
}

/// The sectors of a range, erased one at a time. Both bounds are whole
/// sectors; the caller checked that.
fn erase(fb: *FlashBase, offset: u32, len: u32) bool {
    const sys = fb.sys_base;
    var at = fb.offset + offset;
    const end = at + len;
    while (at < end) : (at += spiflash.sector_size) {
        sys.Disable();
        const ok = spiflash.eraseSector(at / spiflash.sector_size);
        sys.Enable();
        if (!ok) return false;
    }
    return true;
}

fn geometry(fb: *FlashBase, into: *td.DriveGeometry) void {
    into.* = .{
        .sector_size = spiflash.sector_size,
        .total_sectors = fb.size / spiflash.sector_size,
        .cylinders = fb.size / spiflash.sector_size,
        .cyl_sectors = 1,
        .heads = 1,
        .track_sectors = 1,
        .buf_mem_type = exec.MEMF_ANY,
        .device_type = td.DG_DIRECT_ACCESS,
        .flags = 0,
        .erase_size = spiflash.sector_size,
        .write_size = spiflash.page_size,
        .map_base = fb.map,
    };
}

// --- the task -------------------------------------------------------------

/// Erases and programs, which must not run on the caller's stack. The port
/// is made to signal here before the first message is taken, so a request
/// that came in while the device was starting is not missed.
fn flashTask(sys: *ExecBase) callconv(.c) void {
    const fb: *FlashBase = @fieldParentPtr("task", sys.FindTask(null).?);
    const port = &fb.unit.msg_port;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return;
    sys.Disable();
    port.sig_bit = @intCast(signal);
    port.sig_task = &fb.task;
    port.flags = exec.PA_SIGNAL;
    sys.Enable();

    setUp(fb);
    // The init is waiting for the mapping before it lets anything open the
    // device.
    if (fb.starter) |starter| {
        const bit: u5 = @intCast(fb.start_signal);
        fb.starter = null;
        sys.Signal(starter, @as(u32, 1) << bit);
    }

    while (true) {
        while (sys.GetMsg(port)) |msg| {
            const io = requestOf(msg);
            slowIO(fb, io);
            sys.ReplyIO(io);
        }
        _ = sys.Wait(port.sigMask());
    }
}

/// The unit's area into the data window, the chip's real size to the ROM,
/// and its write protection off. On the task, so the stack is in internal
/// SRAM while the caches are down.
fn setUp(fb: *FlashBase) void {
    const sys = fb.sys_base;
    sys.Disable();
    fb.map = spiflash.map(fb.offset, fb.size);
    const sized = spiflash.setSize(fb.chip_size);
    const unlocked = spiflash.unlock();
    sys.Enable();
    if (!sized) {
        sdk.exec.kprintf(sys, "%s: the chip's size stays %d bytes\n", .{ DEVICE_NAME, spiflash.size() });
    }
    if (!unlocked) {
        sdk.exec.kprintf(sys, "%s: the flash chip stays write-protected\n", .{DEVICE_NAME});
    }
}

/// The commands that talk to the chip. On the task, so the stack is in
/// internal SRAM.
fn slowIO(fb: *FlashBase, io: *exec.IORequest) void {
    const req = stdReq(io);
    switch (io.command) {
        exec.CMD_READ => {
            if (read(fb, @intCast(req.offset), @ptrCast(req.data.?), @intCast(req.length))) {
                req.actual = req.length;
            } else {
                io.err = td.TDERR_NotSpecified;
            }
        },
        exec.CMD_WRITE => {
            const src: [*]const u8 = @ptrCast(req.data.?);
            if (program(fb, @intCast(req.offset), src, @intCast(req.length))) {
                req.actual = req.length;
            } else {
                io.err = td.TDERR_NotSpecified;
            }
        },
        td.TDCMD_ERASE => {
            if (erase(fb, @intCast(req.offset), @intCast(req.length))) {
                req.actual = req.length;
            } else {
                io.err = td.TDERR_NotSpecified;
            }
        },
        td.TD_FORMAT => {
            if (erase(fb, 0, fb.size)) {
                req.actual = fb.size;
            } else {
                io.err = td.TDERR_NotSpecified;
            }
        },
        else => io.err = exec.IOERR_NOCMD,
    }
}

// --- the device -----------------------------------------------------------

/// Whether `io` can wait: it will be replied, so it needs a reply port
/// (as serial.device's canWait).
fn canWait(io: *exec.IORequest) bool {
    if (io.message.reply_port != null) return true;
    io.err = exec.IOERR_NOREPLYPORT;
    io.flags |= exec.IOF_QUICK;
    return false;
}

/// Onto the task's queue; it will be replied, so not quick I/O.
fn queue(fb: *FlashBase, io: *exec.IORequest) void {
    if (!canWait(io)) return fb.sys_base.ReplyIO(io);
    io.flags &= ~exec.IOF_QUICK;
    fb.sys_base.PutMsg(&fb.unit.msg_port, &io.message);
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    _ = dev;
    const fb = baseOf(io);
    const req = stdReq(io);
    io.err = 0;
    req.actual = 0;
    switch (io.command) {
        exec.CMD_READ => {
            if (!inside(fb, req.offset, req.length)) {
                io.err = exec.IOERR_BADADDRESS;
            } else if (window(fb) == null) {
                // No mapping, so the bytes have to come over SPI1 with the
                // caches down - which is the task's stack, not this one's.
                return queue(fb, io);
            } else if (read(fb, @intCast(req.offset), @ptrCast(req.data.?), @intCast(req.length))) {
                req.actual = req.length;
            } else {
                io.err = td.TDERR_NotSpecified;
            }
        },
        exec.CMD_WRITE => {
            if (!inside(fb, req.offset, req.length)) {
                io.err = exec.IOERR_BADADDRESS;
            } else {
                return queue(fb, io);
            }
        },
        td.TDCMD_ERASE => {
            if (!inside(fb, req.offset, req.length)) {
                io.err = exec.IOERR_BADADDRESS;
            } else if (req.offset % spiflash.sector_size != 0 or req.length % spiflash.sector_size != 0) {
                io.err = exec.IOERR_BADADDRESS;
            } else {
                return queue(fb, io);
            }
        },
        td.TD_FORMAT => return queue(fb, io),
        exec.CMD_UPDATE, exec.CMD_CLEAR => {}, // nothing is buffered
        td.TD_GETGEOMETRY => {
            if (req.data) |data| {
                geometry(fb, @ptrCast(@alignCast(data)));
            } else {
                io.err = exec.IOERR_BADADDRESS;
            }
        },
        td.TD_GETNUMTRACKS => req.actual = fb.size / spiflash.sector_size,
        td.TD_PROTSTATUS, td.TD_CHANGENUM, td.TD_CHANGESTATE => req.actual = 0,
        else => io.err = exec.IOERR_NOCMD,
    }
    fb.sys_base.ReplyIO(io);
}

/// A request the task hasn't started yet is taken off its queue and
/// replied; one it is busy with can't be stopped.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const fb = flashBase(dev);
    const sys = fb.sys_base;
    sys.Disable();
    defer sys.Enable();
    var it = fb.unit.msg_port.msg_list.iterator();
    while (it.next()) |n| {
        const msg: *exec.Message = @fieldParentPtr("node", n);
        if (requestOf(msg) != io) continue;
        sys.Remove(n);
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
        return 0;
    }
    return -1;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const fb = flashBase(dev);
    if (unit_number != 0) return td.TDERR_BadUnitNum;
    if (fb.map == 0 and fb.size == 0) return exec.IOERR_OPENFAIL;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    fb.unit.open_cnt += 1;
    io.unit = &fb.unit;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const fb = baseOf(io);
    _ = abortIO(dev, io);
    fb.unit.open_cnt -= 1;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: it owns its task and the unit's mapping, and a file
/// system sits on it (dos.library keeps itself the same way).
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

/// The chip's size and where the disk starts on it, from the board's
/// system tag list: unit 0 runs from SYSTAG_DiskOffset to the end of the
/// chip. False if expansion.library is not there, or the two do not make
/// a disk of whole 64 KiB pages.
fn findDisk(fb: *FlashBase) bool {
    const sys = fb.sys_base;
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return false;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return false;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const root = eb.SystemTags();
    const chip_size: u32 = @truncate(ub.GetTagData(st.SYSTAG_FlashSize, 0, root));
    const offset: u32 = @truncate(ub.GetTagData(st.SYSTAG_DiskOffset, 0, root));
    const page = 64 * 1024;
    if (offset == 0 or offset >= chip_size or offset % page != 0 or chip_size % page != 0) return false;
    fb.chip_size = chip_size;
    fb.offset = offset;
    fb.size = chip_size - offset;
    return true;
}

/// exec has copied the tag's name, version and ID string into the base.
/// The unit's area is mapped into the data window for reading, the chip's
/// write protection comes off, and the task that does the slow work gets a
/// stack in internal SRAM.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    _ = seg_list;
    dev.revision = DEVICE_REVISION;
    const fb = flashBase(dev);
    fb.sys_base = sys_base;
    if (!findDisk(fb)) {
        sdk.exec.kprintf(sys_base, "%s: the board names no flash disk\n", .{DEVICE_NAME});
        return null;
    }
    // PA_IGNORE until the task has a signal for it: a request that comes
    // in while the device starts is queued, and the task takes it then.
    fb.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    fb.unit.msg_port.msg_list.init(.message);

    // Nothing here talks to the chip. Every one of those calls suspends
    // both caches, and then a stack in PSRAM cannot be touched - not even
    // by the register-window spill a call makes. This runs on whichever
    // task started the device, whose stack AllocMem put wherever it liked,
    // so the chip work waits for the task below and its stack in internal
    // SRAM. (A machine with no PSRAM never notices the difference, which
    // is why this stood so long.)
    const stack = sys_base.AllocMem(stack_size, exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse {
        sdk.exec.kprintf(sys_base, "%s: no internal memory for the task's stack\n", .{DEVICE_NAME});
        return null;
    };
    fb.stack = stack;
    fb.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };

    // The mapping has to be there before init returns: a read is served on
    // the caller's task straight out of it. So the task is started and
    // this one waits for it to say the chip is set up.
    const signal = sys_base.AllocSignal(-1);
    if (signal >= 0) {
        fb.starter = sys_base.FindTask(null);
        fb.start_signal = @intCast(signal);
    }
    _ = sys_base.AddTask(&fb.task, &flashTask, null);
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
    .data_size = @sizeOf(FlashBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// Before dos.library (-128), after timer.device (50): the file system
/// opens it as soon as dos starts a handler on it.
export const flash_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &flash_device_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = DEVICE_VERSION,
    .pri = 40,
    .type = .device,
    .name = DEVICE_NAME,
    .id_string = DEVICE_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
