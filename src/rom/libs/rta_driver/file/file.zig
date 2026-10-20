// SPDX-License-Identifier: MPL-2.0
//! A sink that plays into a file (`sdk/libs/rta/filesink.zig`): what it
//! is handed is written to a WAV file, in time, as a speaker would hear
//! it.
//!
//! A module of its own. At cold start it opens rta.library and hands in a
//! driver of the sink kind, "file"; it makes no sink. A program makes
//! each, naming the file.
//!
//! **Time** is kept as an output's DMA keeps it: started, the sink opens
//! timer.device on the E-clock and asks to be woken when its first buffer
//! would have played, on a port that raises the starting task's signal.
//! Each buffer asked for sets the next wake, counted from the start so it
//! does not drift; a caller too late for a wake is told of the buffers it
//! missed, as `underruns`.
//!
//! **Writing** is a process's, since the task that plays through a sink
//! is no process: each sink has one, made with it and ended with it. A
//! buffer handed back is copied into a ring the process empties into the
//! file - the writer's own pace, a disk's - and one that finds the ring
//! full is lost and counted. Each start has the process open the file
//! anew and write a WAV header with its lengths open; it leaves out the
//! buffers that are silent until the first that is not, so the file
//! begins with the sound. Each stop has it write what is left, fill the
//! lengths in and close the file, before the stop returns.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rta = sdk.rta;
const filesink = rta.filesink;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const RtaBase = sdk.interface.rta.RtaBase;
const timer = sdk.devices.timer;
const TimerBase = sdk.interface.timer.TimerBase;
const err = rta.errors;

const MODULE_NAME = "rta-file";
const DRIVER_NAME = filesink.FILE_DRIVER_NAME;
const VERSION = 1;
const REVISION = 0;
const BUILD_DATE = "20.10.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The ring as a real output's: a buffer of 256 frames, two of them.
const buffer_frames: u32 = 256;
const buffer_samples: usize = buffer_frames * 2;
const buffers: u32 = 2;
const rates = [_]u32{ 48_000, 44_100 };
const mode_names = [_][*:0]const u8{ "48000 Hz stereo", "44100 Hz stereo" };

/// The buffers waiting for the writer: two thirds of a second at 48 kHz.
const queued_buffers: u32 = 128;

/// The writer: above the shells, so the file keeps up.
const writer_pri = 1;
const writer_stack = 4096;

/// A WAV header: RIFF, the format chunk, the data chunk's head.
const header_bytes = 44;

/// Everything the driver has that changes, allocated once by the init.
const State = struct {
    driver: rta.RtaDriver = .{},
    sys: *ExecBase,
    utility: *sdk.interface.utility.UtilityBase,
};

fn stateOf(driver: *rta.RtaDriver) *State {
    return @fieldParentPtr("driver", driver);
}

/// What the writer is told: open the file, close it, end.
const Order = extern struct {
    message: exec.Message = .{},
    what: u32 = 0,
    result: i32 = 0,
};
const order_open: u32 = 1;
const order_close: u32 = 2;
const order_quit: u32 = 3;

/// One sink's own.
const Instance = struct {
    sys: *ExecBase,
    dos: *DosBase,
    modes: [rates.len]rta.AudioMode = @splat(.{}),
    /// The buffer handed out to be filled.
    frames: [buffer_samples]i16 = @splat(0),
    /// The file, with its NUL.
    name: [filesink.FILE_NAME_LEN]u8 = @splat(0),
    /// Time, while it is started: the port the timer's request comes back
    /// to - the starting task's, on its own signal - the request, the
    /// E-clock at the start and its rate, the rate of the frames, the
    /// buffers played since.
    port: exec.MsgPort = .{},
    timer_io: timer.TimeRequest = .{},
    waiting: bool = false,
    rate: u32 = rates[0],
    start_ticks: u64 = 0,
    eclock_hz: u64 = 0,
    played: u64 = 0,
    /// The writer: its port for orders, the signal that tells it buffers
    /// are queued, and who waits for it to have started.
    writer: ?*exec.MsgPort = null,
    writer_task: ?*exec.Task = null,
    data_mask: u32 = 0,
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    /// The buffers queued for it while started: the ring, how many were
    /// put in and taken out (counted round), and those lost to a full one.
    queue: ?[*][buffer_samples]i16 = null,
    put: u32 = 0,
    taken: u32 = 0,
    lost: u32 = 0,
};

fn instanceOf(sink: *rta.AudioSink) *Instance {
    return @ptrCast(@alignCast(sink.instance.?));
}

// --- time -------------------------------------------------------------------------

/// When buffer `n` has played, on the E-clock, worked out wide.
fn deadline(instance: *const Instance, n: u64) u64 {
    const since: u128 = @as(u128, n) * buffer_frames * instance.eclock_hz / instance.rate;
    return instance.start_ticks +% @as(u64, @truncate(since));
}

fn arm(instance: *Instance) void {
    const eclock: *timer.EClockVal = @ptrCast(&instance.timer_io.time);
    eclock.* = timer.EClockVal.fromTicks(deadline(instance, instance.played + 1));
    instance.timer_io.node.command = timer.TR_ADDREQUEST;
    instance.sys.SendIO(&instance.timer_io.node);
    instance.waiting = true;
}

fn clockStart(instance: *Instance, task: *exec.Task, signal_mask: u32) bool {
    const sys = instance.sys;
    instance.port = .{
        .flags = exec.PA_SIGNAL,
        .sig_bit = @intCast(@ctz(signal_mask)),
        .sig_task = task,
    };
    instance.port.msg_list.init(.message);
    instance.timer_io = .{};
    instance.timer_io.node.message.reply_port = &instance.port;
    instance.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_WAITECLOCK, &instance.timer_io.node, 0) != 0) return false;
    const device: *TimerBase = @ptrCast(instance.timer_io.node.device.?);
    var now: timer.EClockVal = .{};
    instance.eclock_hz = device.ReadEClock(&now);
    instance.start_ticks = now.toTicks();
    instance.played = 0;
    arm(instance);
    return true;
}

fn clockStop(instance: *Instance) void {
    const sys = instance.sys;
    if (instance.waiting) {
        _ = sys.AbortIO(&instance.timer_io.node);
        _ = sys.WaitIO(&instance.timer_io.node);
        instance.waiting = false;
    }
    if (instance.timer_io.node.device != null) sys.CloseDevice(&instance.timer_io.node);
    instance.timer_io = .{};
}

// --- the writer -------------------------------------------------------------------

/// An order sent to the writer and waited for, on a port of the caller's:
/// what it answered.
fn tell(instance: *Instance, what: u32) i32 {
    const sys = instance.sys;
    const writer = instance.writer orelse return err.RTAERR_IO;
    const reply = sys.CreateMsgPort() orelse return err.RTAERR_NO_MEMORY;
    defer sys.DeleteMsgPort(reply);
    var order: Order = .{ .what = what };
    order.message.reply_port = reply;
    order.message.length = @sizeOf(Order);
    sys.PutMsg(writer, &order.message);
    while (sys.GetMsg(reply) == null) _ = sys.WaitPort(reply);
    return order.result;
}

/// What the writer has of the file it writes.
const Writing = struct {
    file: ?*dos.FileHandle = null,
    written: u64 = 0,
    /// A buffer that is not silent has come: every one after is written.
    heard: bool = false,
    failed: bool = false,
};

fn writerProcess(sys: *ExecBase) callconv(.c) void {
    const process = sys.FindTask(null).?;
    const instance: *Instance = @ptrCast(@alignCast(process.user_data orelse return));
    const signal = sys.AllocSignal(-1);
    const orders = if (signal >= 0) sys.CreateMsgPort() else null;
    if (orders != null) {
        instance.writer = orders;
        instance.writer_task = process;
        instance.data_mask = @as(u32, 1) << @intCast(signal);
    }
    if (instance.starter) |starter| {
        instance.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(instance.start_signal));
    }
    const port = orders orelse return;
    var writing: Writing = .{};
    while (true) {
        const got = sys.Wait(port.sigMask() | instance.data_mask);
        if (got & instance.data_mask != 0) drain(instance, &writing);
        while (sys.GetMsg(port)) |message| {
            const order: *Order = @fieldParentPtr("message", message);
            switch (order.what) {
                order_open => order.result = openFile(instance, &writing),
                order_close => closeFile(instance, &writing),
                else => {
                    closeFile(instance, &writing);
                    sys.DeleteMsgPort(port);
                    sys.FreeSignal(signal);
                    // Nothing of the sink is touched past this: it is freed
                    // once the order is back.
                    sys.ReplyMsg(message);
                    return;
                },
            }
            sys.ReplyMsg(message);
        }
    }
}

/// The file opened anew and its header written, lengths open.
fn openFile(instance: *Instance, writing: *Writing) i32 {
    closeFile(instance, writing);
    const dl = instance.dos;
    const file = dl.Open(@ptrCast(&instance.name), dos.MODE_NEWFILE) orelse return err.RTAERR_IO;
    var head: [header_bytes]u8 = undefined;
    waveHeader(&head, instance.rate, 0);
    if (dl.Write(file, &head, header_bytes) != header_bytes) {
        _ = dl.Close(file);
        return err.RTAERR_IO;
    }
    writing.* = .{ .file = file };
    return err.RTAERR_OK;
}

/// What is queued written, the lengths filled in, the file closed; the
/// buffers lost said.
fn closeFile(instance: *Instance, writing: *Writing) void {
    const file = writing.file orelse return;
    const dl = instance.dos;
    drain(instance, writing);
    var head: [header_bytes]u8 = undefined;
    waveHeader(&head, instance.rate, @intCast(@min(writing.written, 0xFFFF_FFFF - header_bytes)));
    if (dl.Seek(file, 0, dos.OFFSET_BEGINNING) < 0 or dl.Write(file, &head, header_bytes) != header_bytes) writing.failed = true;
    _ = dl.Close(file);
    if (writing.failed) {
        exec.kprintf(instance.sys, "%s: %s: not all of it written\n", .{ MODULE_NAME, @as([*:0]const u8, @ptrCast(&instance.name)) });
    } else if (instance.lost != 0) {
        exec.kprintf(instance.sys, "%s: %s: %u buffers lost\n", .{ MODULE_NAME, @as([*:0]const u8, @ptrCast(&instance.name)), instance.lost });
    }
    writing.* = .{};
}

/// Every buffer queued written to the file, from the first that is not
/// silent on.
fn drain(instance: *Instance, writing: *Writing) void {
    const queue = instance.queue orelse return;
    const dl = instance.dos;
    var at = instance.taken;
    const end = @atomicLoad(u32, &instance.put, .acquire);
    while (at != end) : (at +%= 1) {
        const frames = &queue[at % queued_buffers];
        if (!writing.heard) {
            for (frames) |sample| {
                if (sample != 0) break;
            } else continue;
            writing.heard = true;
        }
        const file = writing.file orelse continue;
        if (writing.failed) continue;
        const bytes: [*]const u8 = @ptrCast(frames);
        const length: isize = buffer_samples * 2;
        if (dl.Write(file, bytes, length) != length) {
            writing.failed = true;
            continue;
        }
        writing.written += buffer_samples * 2;
    }
    @atomicStore(u32, &instance.taken, at, .release);
}

/// A WAV header for `data_bytes` bytes of 16-bit stereo at `rate`.
fn waveHeader(head: *[header_bytes]u8, rate: u32, data_bytes: u32) void {
    const block: u32 = 4;
    @memcpy(head[0..4], "RIFF");
    put32(head[4..8], data_bytes + header_bytes - 8);
    @memcpy(head[8..12], "WAVE");
    @memcpy(head[12..16], "fmt ");
    put32(head[16..20], 16);
    put16(head[20..22], 1);
    put16(head[22..24], 2);
    put32(head[24..28], rate);
    put32(head[28..32], rate * block);
    put16(head[32..34], block);
    put16(head[34..36], 16);
    @memcpy(head[36..40], "data");
    put32(head[40..44], data_bytes);
}

fn put16(into: *[2]u8, value: u32) void {
    into[0] = @truncate(value);
    into[1] = @truncate(value >> 8);
}

fn put32(into: *[4]u8, value: u32) void {
    into[0] = @truncate(value);
    into[1] = @truncate(value >> 8);
    into[2] = @truncate(value >> 16);
    into[3] = @truncate(value >> 24);
}

// --- the sink ---------------------------------------------------------------------

/// The sink of the file its tags name, and its writer started.
fn createSink(made_by: *rta.RtaDriver, sink: *rta.AudioSink, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(made_by);
    const sys = state.sys;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return err.RTAERR_NO_OUTPUT;
    const instance = instanceOf(sink);
    instance.* = .{ .sys = sys, .dos = @ptrCast(dos_lib) };
    const asked: ?[*:0]const u8 = @ptrFromInt(state.utility.GetTagData(filesink.FILEA_Name, 0, tag_list));
    const name = asked orelse filesink.FILE_DEFAULT_NAME;
    var at: usize = 0;
    while (name[at] != 0 and at < instance.name.len - 1) : (at += 1) instance.name[at] = name[at];

    for (&instance.modes, rates, mode_names, 0..) |*mode, mode_rate, mode_name, n| {
        mode.* = .{
            .node = .{ .name = mode_name },
            .id = @intCast(n),
            .rate = mode_rate,
            .bits = 16,
            .channels = 2,
            .sides = rta.AUDIOSIDES_LEFT_FIRST,
            .flags = if (n == 0) rta.sinks.AUDIOMF_DEFAULT else 0,
        };
        sys.AddTail(&sink.modes, &mode.node);
    }
    sink.ops = &ops;
    sink.buffer_frames = buffer_frames;
    sink.buffers = buffers;

    // The writer, waited for until it has its port.
    const signal = sys.AllocSignal(-1);
    if (signal < 0) {
        sys.CloseLibrary(dos_lib);
        return err.RTAERR_NO_MEMORY;
    }
    defer sys.FreeSignal(signal);
    instance.starter = sys.FindTask(null);
    instance.start_signal = @intCast(signal);
    const process_tags = [_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&writerProcess) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(@as([*:0]const u8, "file sink")) },
        .{ .tag = dos.NP_StackSize, .data = writer_stack },
        .{ .tag = dos.NP_Priority, .data = @as(usize, @bitCast(@as(isize, writer_pri))) },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(instance) },
        .{},
    };
    if (instance.dos.CreateNewProc(&process_tags) == null) {
        sys.CloseLibrary(dos_lib);
        return err.RTAERR_NO_MEMORY;
    }
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    if (instance.writer == null) {
        sys.CloseLibrary(dos_lib);
        return err.RTAERR_NO_MEMORY;
    }
    return err.RTAERR_OK;
}

/// The writer ended, and dos let go.
fn destroy(sink: *rta.AudioSink) callconv(.c) void {
    const instance = instanceOf(sink);
    _ = tell(instance, order_quit);
    instance.writer = null;
    instance.sys.CloseLibrary(@ptrCast(@alignCast(instance.dos)));
}

fn start(sink: *rta.AudioSink, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    const instance = instanceOf(sink);
    const sys = instance.sys;
    if (signal_mask == 0) return err.RTAERR_BAD_ARG;
    const memory = sys.AllocVec(queued_buffers * buffer_samples * 2, exec.MEMF_ANY) orelse return err.RTAERR_NO_MEMORY;
    instance.queue = @ptrCast(@alignCast(memory));
    instance.put = 0;
    instance.taken = 0;
    instance.lost = 0;
    instance.rate = mode.rate;
    const code = tell(instance, order_open);
    if (code == err.RTAERR_OK and clockStart(instance, task, signal_mask)) return err.RTAERR_OK;
    if (code == err.RTAERR_OK) _ = tell(instance, order_close);
    instance.queue = null;
    sys.FreeVec(memory);
    return if (code == err.RTAERR_OK) err.RTAERR_NO_OUTPUT else code;
}

fn stop(sink: *rta.AudioSink) callconv(.c) void {
    const instance = instanceOf(sink);
    clockStop(instance);
    _ = tell(instance, order_close);
    if (instance.queue) |queue| instance.sys.FreeVec(queue);
    instance.queue = null;
}

/// A buffer once its time has come; past wakes the caller was too late
/// for counted.
fn buffer(sink: *rta.AudioSink) callconv(.c) ?[*]i16 {
    const instance = instanceOf(sink);
    const sys = instance.sys;
    if (sys.GetMsg(&instance.port) == null) return null;
    instance.waiting = false;
    instance.played += 1;
    const device: *TimerBase = @ptrCast(instance.timer_io.node.device.?);
    var now: timer.EClockVal = .{};
    _ = device.ReadEClock(&now);
    while (deadline(instance, instance.played + 1) <= now.toTicks()) {
        instance.played += 1;
        sink.underruns +%= 1;
    }
    arm(instance);
    return &instance.frames;
}

/// The buffer queued for the writer, or lost to a full queue.
fn play(sink: *rta.AudioSink, frames: [*]i16) callconv(.c) i32 {
    const instance = instanceOf(sink);
    const queue = instance.queue orelse return err.RTAERR_NOT_RUNNING;
    const at = instance.put;
    if (at -% @atomicLoad(u32, &instance.taken, .acquire) >= queued_buffers) {
        instance.lost +%= 1;
        return err.RTAERR_OK;
    }
    @memcpy(&queue[at % queued_buffers], frames[0..buffer_samples]);
    @atomicStore(u32, &instance.put, at +% 1, .release);
    instance.sys.Signal(instance.writer_task.?, instance.data_mask);
    return err.RTAERR_OK;
}

const ops = rta.AudioSinkOps{
    .destroy = &destroy,
    .start = &start,
    .stop = &stop,
    .buffer = &buffer,
    .play = &play,
};

const driver_ops = rta.RtaDriverOps{ .create_sink = &createSink };

/// Cold start at 31: after rta.library (33), which it joins.
fn init(seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*anyopaque {
    _ = seg_list;
    const library = sys.OpenLibrary(rta.RTANAME, rta.RTA_VERSION) orelse return @ptrCast(sys);
    const rb: *RtaBase = @ptrCast(library);
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse {
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    };
    const memory = sys.AllocVec(@sizeOf(State), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        sys.CloseLibrary(utility_lib);
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    };
    const state: *State = @ptrCast(@alignCast(memory));
    state.* = .{ .sys = sys, .utility = @ptrCast(utility_lib) };
    state.driver = .{
        .node = .{ .name = DRIVER_NAME, .pri = 0 },
        .version = VERSION,
        .revision = REVISION,
        .id_string = VERSION_STRING[1..],
        .type = rta.sinks.RTADT_SINK,
        .ops = &driver_ops,
        .instance_size = @sizeOf(Instance),
    };
    if (!rb.AddRtaDriver(&state.driver)) {
        sys.FreeVec(memory);
        sys.CloseLibrary(utility_lib);
        sys.CloseLibrary(library);
    }
    // Otherwise the libraries stay open and the state allocated: the
    // driver is on the list for good.
    return @ptrCast(sys);
}

/// No library and no vectors: the tag's init is the whole of it.
export const rta_file_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rta_file_tag,
    .flags = exec.RTF_COLDSTART,
    .version = VERSION,
    .pri = 31,
    .type = .rta_driver,
    .name = MODULE_NAME,
    .id_string = VERSION_STRING[1..], // past the NUL: a C string
    .init = @ptrCast(@constCast(&init)),
};
