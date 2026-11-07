// SPDX-License-Identifier: MPL-2.0
//! OpenVideoDecoder: a decoder for a codec, the chip woken and its
//! firmware started for the first - the JH7110's WAVE511, or an AMD
//! graphics device's decoder.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const types = sdk.resources.videodec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const base = @import("../videodec_base.zig");
const VideoDecBase = base.VideoDecBase;
const _decoder = @import("_decoder.zig");
const Decoder = _decoder.Decoder;
const Block = _decoder.Block;
const wave511 = @import("../codec/_wave511.zig");
const vcn = @import("../codec/_vcn.zig");
const Session = @import("_session.zig").Session;
const engine = @import("../videodec_init.zig").engine;
const amdgpu = sdk.resources.amdgpu;
const watchdog = sdk.resources.watchdog;
const WatchdogBase = sdk.interface.watchdog.WatchdogBase;
const datatypes = sdk.datatypes;

/// Where the firmware is read from.
pub const FIRMWARE = "DEVS:firmware/wave511_dec_fw.bin";

/// The stream's ring: its size by default, and the least and most a
/// caller may ask for.
const ring_default: u32 = 2 * 1024 * 1024;
const ring_least: u32 = 64 * 1024;
const ring_most: u32 = 64 * 1024 * 1024;

/// Opens a decoder for one of the chip's codecs.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenVideoDecoder(vb: *VideoDecBase, codec: u32,
///     tags: ?[*]const TagItem, err: ?*u32) ?*VideoDecoder
/// ```
///
/// SINCE: 1.0. LVO -8.
///
/// INPUTS:
/// - `codec` - one VDCODEC_*, of those VideoDecCodecs answers.
/// - `tags` - VDA_StreamSize, VDA_HeldFrames; null for neither.
/// - `err` - VDERR_OK, or why it failed; null if not wanted.
///
/// RESULT:
/// The decoder, or null and in `err` why not: VDERR_NO_ENGINE when the
/// board has no decoder, its firmware is not in
/// DEVS:firmware/wave511_dec_fw.bin, or it would not wake or start - and
/// on an AMD graphics device while the watchdog is not armed, where its
/// firmware or the security processor's table of contents is not in
/// DEVS:firmware/amdgpu/, or without videoparse.library; VDERR_UNSUPPORTED
/// for a codec it does not take; VDERR_BUSY when eight decoders are open;
/// VDERR_NO_MEMORY.
///
/// BEHAVIOR:
/// The first decoder wakes the chip - its power domain, clocks and
/// resets - reads the firmware into a buffer below 4 GiB and starts it;
/// the chip runs from then on. Each decoder is an instance on the chip,
/// with a work buffer of 1784 KiB and the stream's ring
/// (VDA_StreamSize, 2 MiB by default, 64 KiB to 64 MiB). Its frames are
/// made when its first picture is decoded, or its stream asked about
/// (GetVideoDecoderInfo): as many compressed frames as the stream needs
/// and one, as many shown frames as that and VDA_HeldFrames (2 by
/// default, at most 16) - about 3 MiB each at 1080p.
///
/// On an AMD graphics device the first decoder, opened while the
/// watchdog is armed, has amdgpu.resource power the decoder up, start
/// the security processor with its table of contents and load the
/// decoder's firmware - both files read from DEVS:firmware/amdgpu/,
/// named for the blocks' versions - then has the security processor
/// apply the decoder's start, a list of its register writes, and checks
/// that the firmware reads its ring. Each decoder reads its stream with
/// videoparse.library (opened here, from LIBS:) and is a stream on the
/// device, made when its sequence is read: in the device's memory a
/// context (128 KiB, and for H.264 192 bytes a macroblock for each
/// reference and the picture decoded, for H.265 about 3 MiB at 1080p,
/// for VP9 about 10.4 MiB at any size, the default probabilities written
/// into it), a surface for each of those, and the surface pictures are
/// written to - about 26 MiB at 1080p with four H.264 references, 24 MiB
/// for H.265 with five pictures in its buffer, 188 MiB for 10-bit H.265
/// at 4K with six, 41 MiB for VP9 at 1080p with its nine.
/// Its frames are in the system's memory, one for each picture the
/// stream holds and VDA_HeldFrames and two more; VDA_StreamSize is not
/// read.
///
/// CONTEXT:
/// - Waits: yes, for the chip; the first open for the firmware's file.
/// - Interrupts: no. - Locks: the resource's, around the chip.
/// - Process: the first open, which reads the firmware with dos.library;
///   once the chip runs a Task will do.
///
/// OWNERSHIP:
/// The decoder is the caller's until CloseVideoDecoder; another task may
/// use it, one at a time. Its memory is the system's: the chip writes it,
/// and a task that ends with it open leaves it to the chip.
///
/// NOTES:
/// The firmware is Chips&Media's, as StarFive ships it for their kernel
/// driver (scripts/fetch-vpu.sh fetches it into toolchain/, and the
/// build puts it on the disk); its licence is
/// DEVS:firmware/wave511.licence.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `VideoDecCodecs`, `CloseVideoDecoder`, `FeedVideoDecoder`,
/// `DecodeVideoFrame`
///
/// EXAMPLES:
/// ```zig
/// var err: u32 = 0;
/// const decoder = vb.OpenVideoDecoder(videodec.VDCODEC_H264, null, &err) orelse return;
/// defer vb.CloseVideoDecoder(decoder);
/// ```
pub fn OpenVideoDecoder(vb: *VideoDecBase, codec: u32, tags: ?[*]const utility.TagItem, err: ?*u32) ?*types.VideoDecoder {
    const sys = vb.sys_base;
    if (comptime engine == .vcn) return openSession(vb, codec, tags, err);
    if (vb.vpu == 0) return failed(err, types.VDERR_NO_ENGINE);
    if (codec == 0 or codec & (codec - 1) != 0 or codec & vb.codecs == 0) return failed(err, types.VDERR_UNSUPPORTED);

    var ring_size = ring_default;
    var held: u32 = 2;
    if (tags != null) {
        const utility_lib = sys.OpenLibrary(utility.UTILITYNAME, 0) orelse return failed(err, types.VDERR_NO_MEMORY);
        defer sys.CloseLibrary(utility_lib);
        const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
        const asked = ub.GetTagData(types.VDA_StreamSize, ring_default, tags);
        ring_size = @intCast(@max(ring_least, @min(ring_most, asked)));
        ring_size = (ring_size + 1023) & ~@as(u32, 1023);
        held = @intCast(@min(_decoder.held_max, ub.GetTagData(types.VDA_HeldFrames, 2, tags)));
    }

    sys.ObtainSemaphore(&vb.lock);
    defer sys.ReleaseSemaphore(&vb.lock);
    if (vb.state == base.STATE_ASLEEP) start(vb);
    if (vb.state != base.STATE_RUNNING) return failed(err, types.VDERR_NO_ENGINE);

    const slot = for (vb.decoders, 0..) |d, n| {
        if (d == null) break n;
    } else return failed(err, types.VDERR_BUSY);

    const memory = sys.AllocMem(@sizeOf(Decoder), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return failed(err, types.VDERR_NO_MEMORY);
    const d: *Decoder = @ptrCast(@alignCast(memory));
    d.* = .{
        .vb = vb,
        .instance = .{
            .regs = vb.vpu,
            .id = @intCast(slot),
            .std = if (codec == types.VDCODEC_H264) wave511.STD_AVC else wave511.STD_HEVC,
        },
        .codec = codec,
        .held = held,
        .ring_size = ring_size,
    };
    const ok = blk: {
        d.work = Block.alloc(sys, wave511.work_size) orelse break :blk false;
        d.ring = Block.alloc(sys, ring_size) orelse break :blk false;
        break :blk true;
    };
    if (!ok) {
        d.ring.free(sys);
        d.work.free(sys);
        sys.FreeMem(memory, @sizeOf(Decoder));
        return failed(err, types.VDERR_NO_MEMORY);
    }
    // On the server's table before the chip can answer for it.
    sys.Disable();
    vb.decoders[slot] = d;
    sys.Enable();
    if (!d.instance.create(d.work.bus(), d.ring.bus(), ring_size)) {
        sys.Disable();
        vb.decoders[slot] = null;
        sys.Enable();
        d.ring.free(sys);
        d.work.free(sys);
        sys.FreeMem(memory, @sizeOf(Decoder));
        return failed(err, types.VDERR_NO_ENGINE);
    }
    if (err) |e| e.* = types.VDERR_OK;
    return d.handle();
}

fn failed(err: ?*u32, code: u32) ?*types.VideoDecoder {
    if (err) |e| e.* = code;
    return null;
}

/// The chip woken and its firmware started: STATE_RUNNING, or
/// STATE_DEAD when either failed - or STATE_ASLEEP still when the caller
/// could not read the firmware (a Task, no file), to be tried again.
fn start(vb: *VideoDecBase) void {
    if (comptime engine != .wave511) return;
    const sys = vb.sys_base;
    const task = sys.FindTask(null) orelse return;
    if (task.node.type != .process) return;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    // The code and temp buffers on a 1 MiB boundary, as the remap pages
    // want them.
    const want = wave511.code_size + wave511.temp_size;
    const block_size = want + wave511.remap_page;
    const block = sys.AllocMem(block_size, exec.MEMF_DMA | exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return;
    const code = (@intFromPtr(block) + wave511.remap_page - 1) & ~@as(usize, wave511.remap_page - 1);
    if (code + want > 0x1_0000_0000 or !readFirmware(dl, @ptrFromInt(code))) {
        sys.FreeMem(block, block_size);
        return;
    }
    var length: u32 = want;
    _ = sys.CachePreDMA(@ptrFromInt(code), &length, exec.DMAF_ReadFromRAM);

    if (!wave511.wake(vb.vpu, sys, Sleep{ .sys = sys })) {
        sys.FreeMem(block, block_size);
        vb.state = base.STATE_DEAD;
        exec.kprintf(sys, "%s: the jh7110 vdec does not wake\n", .{types.VIDEODECNAME});
        return;
    }
    const version = wave511.boot(vb.vpu, @intCast(code)) orelse {
        wave511.halt(sys);
        sys.FreeMem(block, block_size);
        vb.state = base.STATE_DEAD;
        exec.kprintf(sys, "%s: the wave511 firmware does not start\n", .{types.VIDEODECNAME});
        return;
    };
    vb.code_block = block;
    vb.code_block_size = block_size;
    vb.code = @intCast(code);
    vb.firmware = version;
    vb.state = base.STATE_RUNNING;
}

/// A decoder on an AMD graphics device's decoder: the decoder started
/// for the first, a parser opened for the stream, which is made on the
/// decoder when its sequence is read.
fn openSession(vb: *VideoDecBase, codec: u32, tags: ?[*]const utility.TagItem, err: ?*u32) ?*types.VideoDecoder {
    const sys = vb.sys_base;
    if (vb.codecs == 0) return failed(err, types.VDERR_NO_ENGINE);
    if (codec == 0 or codec & (codec - 1) != 0 or codec & vb.codecs == 0) return failed(err, types.VDERR_UNSUPPORTED);
    var held: u32 = 2;
    if (tags != null) {
        const utility_lib = sys.OpenLibrary(utility.UTILITYNAME, 0) orelse return failed(err, types.VDERR_NO_MEMORY);
        defer sys.CloseLibrary(utility_lib);
        const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
        held = @intCast(@max(1, @min(_decoder.held_max, ub.GetTagData(types.VDA_HeldFrames, 2, tags))));
    }
    sys.ObtainSemaphore(&vb.lock);
    defer sys.ReleaseSemaphore(&vb.lock);
    if (vb.state == base.STATE_ASLEEP) startVcn(vb);
    if (vb.state != base.STATE_RUNNING) return failed(err, types.VDERR_NO_ENGINE);

    const slot = for (vb.decoders, 0..) |d, n| {
        if (d == null) break n;
    } else return failed(err, types.VDERR_BUSY);
    const memory = sys.AllocMem(@sizeOf(Session), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return failed(err, types.VDERR_NO_MEMORY);
    const s: *Session = @ptrCast(@alignCast(memory));
    s.* = .{ .vb = vb, .slot = @intCast(slot), .codec = codec, .held = held };
    const started = s.start();
    if (started != types.VDERR_OK) {
        s.end();
        sys.FreeMem(memory, @sizeOf(Session));
        return failed(err, started);
    }
    vb.decoders[slot] = s;
    if (err) |e| e.* = types.VDERR_OK;
    return s.handle();
}

/// The AMD graphics device's decoder started: STATE_RUNNING, or
/// STATE_DEAD when the security processor, the firmware or the decoder
/// failed - or STATE_ASLEEP still when it may not be started yet: the
/// watchdog not armed, the caller a Task, a file missing.
fn startVcn(vb: *VideoDecBase) void {
    if (comptime engine != .vcn) return;
    const sys = vb.sys_base;
    const gpu = vb.vcn.gpu orelse return;
    const wb: *WatchdogBase = @ptrCast(@alignCast(sys.OpenResource(watchdog.WATCHDOGNAME) orelse return));
    if (wb.ReadWatchdog() == 0) return;
    const task = sys.FindTask(null) orelse return;
    if (task.node.type != .process) return;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var toc_room: [64]u8 = undefined;
    var firmware_room: [64]u8 = undefined;
    const toc_name = vcn.firmwareName(&toc_room, "psp_", vb.vcn.security, "_toc.bin");
    const firmware_name = vcn.firmwareName(&firmware_room, "vcn_", vb.vcn.video, ".bin");
    const toc = readFile(sys, dl, toc_name) orelse return;
    defer sys.FreeVec(toc.ptr);
    const firmware = readFile(sys, dl, firmware_name) orelse return;
    defer sys.FreeVec(firmware.ptr);

    var address: u64 = 0;
    if (!gpu.StartGPUSecurity(toc.ptr, @intCast(toc.len)) or
        !gpu.LoadGPUFirmware(amdgpu.GPUFIRMWARE_VIDEO, firmware.ptr, @intCast(firmware.len), &address))
    {
        exec.kprintf(sys, "%s: the AMD video decoder's firmware is not loaded\n", .{types.VIDEODECNAME});
        vb.state = base.STATE_DEAD;
        return;
    }
    if (!vcn.wake(sys, &vb.vcn, address)) {
        vb.state = base.STATE_DEAD;
        return;
    }
    vb.state = base.STATE_RUNNING;
}

/// The file `name` read whole, or null with why said.
fn readFile(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8) ?[]u8 {
    const lock = dl.Lock(name, dos.SHARED_LOCK) orelse {
        exec.kprintf(sys, "%s: no %s\n", .{ types.VIDEODECNAME, name });
        return null;
    };
    defer dl.UnLock(lock);
    return switch (datatypes.subclass.readWhole(sys, dl, lock)) {
        .got => |bytes| bytes,
        else => {
            exec.kprintf(sys, "%s: %s cannot be read\n", .{ types.VIDEODECNAME, name });
            return null;
        },
    };
}

/// The firmware's file read into `into`: false when it is missing,
/// unreadable, or larger than the code buffer.
fn readFirmware(dl: *DosBase, into: [*]u8) bool {
    const file = dl.Open(FIRMWARE, dos.MODE_OLDFILE) orelse return false;
    defer _ = dl.Close(file);
    const got = dl.Read(file, into, wave511.code_size);
    if (got <= 0 or got >= wave511.code_size) return false;
    return true;
}

/// A wait of so many microseconds, for waking the chip.
const Sleep = struct {
    sys: *ExecBase,

    pub fn wait(s: Sleep, us: u32) void {
        var never: exec.Waitable = .{};
        const list = [_]*exec.Waitable{&never};
        _ = s.sys.WaitForAny(&list, 1, us);
    }
};
