// SPDX-License-Identifier: MPL-2.0
//! rta.library: the sound outputs and inputs of this machine, and the
//! drivers that drive them.
//!
//! The library itself drives nothing. It holds a list of drivers and the
//! sinks, sources and lines they made, allocates the handles a driver
//! fills in, keeps which mode a sink or a source is in and whether it has
//! been started, and passes the calls through. What is on the other side - a codec set up
//! over I2C, an amplifier on a pad, a stream that goes nowhere - is the
//! driver's business and nobody else's.
//!
//! Every driver makes its own sinks, at its own init: it asks
//! expansion.library for the board's parts it can drive, and makes a sink
//! for each - over a line first, for a part fed over I2S - and a source
//! for a part that has a way in, on the same line. audio.device plays
//! through the first sink on the list and records from the first source;
//! nothing above the drivers knows a part's name.
//!
//! The base is opened with OpenLibrary("rta.library", 1). Its functions
//! are sdk/fd/rta_lib.fd, its types sdk/libs/rta/.
//!
//! Each call is a file of its own in the folder for its category -
//! driver/, sink/, source/, transport/ and errors/. The jump table is rta_lvo.zig,
//! the ROM tag and init rta_init.zig, the base rta_base.zig. This file
//! holds the names the rest of the kernel reaches the library by, and the
//! tests of calls working together. The drivers are in `../rta_driver/`:
//! i2s/ (the chip's I2S controller, a line), es8311/ and i2samp/ (the
//! parts on it), null/ (a stream that goes nowhere, and one that hears
//! it), and capture/ for the host tests.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const rta = sdk.rta;

/// rta.library's base (rta_base.zig).
const rta_base = @import("rta_base.zig");
/// rta.library's ROM tag and init routine (rta_init.zig).
const rta_init = @import("rta_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from rta.library.
comptime {
    _ = &rta_init.rta_library_tag;
}

/// The library's base, for the modules that keep a pointer to it.
pub const RtaBase = rta_base.RtaBase;
/// What the library is on exec's list as.
pub const LIBRARY_NAME = rta_init.LIBRARY_NAME;
/// The ROM tag, for the host tests that make the library from it.
pub const rta_library_tag = rta_init.rta_library_tag;

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
/// The library's interface as the SDK has it, for the tests' calls.
const interface = sdk.interface.rta;
const err = rta.errors;
const kexec = @import("../exec/exec.zig");
const kutility = @import("../utility/utility.zig");
const capture = @import("../rta_driver/capture/capture.zig");

test {
    _ = rta_base;
    _ = rta_init;
    _ = @import("rta_lvo.zig");
    _ = @import("driver/_driver.zig");
    _ = @import("driver/addrtadriver.zig");
    _ = @import("driver/remrtadriver.zig");
    _ = @import("driver/findrtadriver.zig");
    _ = @import("driver/lockrtadrivers.zig");
    _ = @import("driver/unlockrtadrivers.zig");
    _ = @import("driver/nextrtadriver.zig");
    _ = @import("sink/_sink.zig");
    _ = @import("sink/createsinktaglist.zig");
    _ = @import("sink/deletesink.zig");
    _ = @import("sink/nextsink.zig");
    _ = @import("sink/findsink.zig");
    _ = @import("sink/sinkmode.zig");
    _ = @import("sink/startsink.zig");
    _ = @import("sink/stopsink.zig");
    _ = @import("sink/sinkbuffer.zig");
    _ = @import("sink/playsinkbuffer.zig");
    _ = @import("sink/sinkcontrol.zig");
    _ = @import("sink/nextsinkmode.zig");
    _ = @import("sink/findsinkmode.zig");
    _ = @import("sink/setsinkmode.zig");
    _ = @import("transport/_transport.zig");
    _ = @import("transport/createaudiotransporttaglist.zig");
    _ = @import("transport/deleteaudiotransport.zig");
    _ = @import("transport/startaudiotransport.zig");
    _ = @import("transport/stopaudiotransport.zig");
    _ = @import("transport/audiotransportbuffer.zig");
    _ = @import("transport/playaudiotransportbuffer.zig");
    _ = @import("transport/startaudiotransportinput.zig");
    _ = @import("transport/stopaudiotransportinput.zig");
    _ = @import("transport/audiotransportinput.zig");
    _ = @import("source/_source.zig");
    _ = @import("source/createsourcetaglist.zig");
    _ = @import("source/deletesource.zig");
    _ = @import("source/nextsource.zig");
    _ = @import("source/nextsourcemode.zig");
    _ = @import("source/startsource.zig");
    _ = @import("source/stopsource.zig");
    _ = @import("source/sourcebuffer.zig");
    _ = @import("errors/rtalasterror.zig");
    _ = @import("errors/rtaerrortext.zig");
    _ = capture;
}

/// exec on its test RAM, utility.library and rta.library from their tags,
/// with the capture sink's driver registered. For audio.device's tests
/// too, which play into it.
pub fn setUpForTests() !*RtaBase {
    try kexec.setUp();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    const made = kexec.InitResident(kexec.SysBase, &rta_library_tag, null) orelse return error.NoRta;
    const rb: *RtaBase = @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
    const state = capture.create(rb.sys_base) orelse return error.NoDriver;
    if (!base(rb).AddRtaDriver(&state.driver)) return error.NoDriver;
    return rb;
}

/// The capture driver's own state, found the way anything finds a
/// driver's: through the node it registered.
pub fn captureOf(rb: *RtaBase) *capture.State {
    return capture.stateOf(base(rb).FindRtaDriver(capture.DRIVER_NAME).?);
}

/// Neither library expunges itself: take the driver off, close utility for
/// rta, free both, and check that nothing is left.
pub fn tearDownForTests(rb: *RtaBase) !void {
    const state = captureOf(rb);
    try testing.expect(base(rb).RemRtaDriver(&state.driver));
    capture.destroyState(state);
    const ub: *kutility.UtilityBase = @ptrCast(@alignCast(rb.utility_base));
    _ = kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    kexec.Remove(kexec.SysBase, &rb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &rb.lib);
    kutility.freeForTests(ub);
    try kexec.expectNoLeaks();
}

/// The library through the SDK's interface, the way a caller reaches it.
fn base(rb: *RtaBase) *interface.RtaBase {
    return @ptrCast(rb);
}

test "rta.library: made from its tag, opened by name" {
    const rb = try setUpForTests();
    defer kexec.deinit();
    try testing.expectEqual(&rb.lib, kexec.OpenLibrary(kexec.SysBase, LIBRARY_NAME, 1).?);
    try testing.expectEqual(@as(u16, 1), rb.lib.version);
    try testing.expect(kexec.OpenLibrary(kexec.SysBase, LIBRARY_NAME, 2) == null);
    kexec.CloseLibrary(kexec.SysBase, &rb.lib);
    try testing.expectEqualStrings("no such sound driver", std.mem.span(base(rb).RtaErrorText(err.RTAERR_NO_DRIVER)));
    try testing.expectEqualStrings("unknown error", std.mem.span(base(rb).RtaErrorText(err.RTAERR_LAST - 1)));
    try tearDownForTests(rb);
}

test "drivers: found by name, walked by priority, and never twice" {
    const rb = try setUpForTests();
    defer kexec.deinit();
    const state = captureOf(rb);

    try testing.expectEqual(&state.driver, base(rb).FindRtaDriver("capture").?);
    try testing.expect(base(rb).FindRtaDriver("nothing") == null);
    // The same name is refused, and so is a driver that makes nothing.
    try testing.expect(!base(rb).AddRtaDriver(&state.driver));
    var empty_ops = rta.RtaDriverOps{};
    var empty = rta.RtaDriver{ .node = .{ .name = "empty" }, .ops = &empty_ops };
    try testing.expect(!base(rb).AddRtaDriver(&empty));

    var line_ops = rta.RtaDriverOps{ .create_transport = @ptrFromInt(0x1000) };
    var line = rta.RtaDriver{
        .node = .{ .name = "line", .pri = 10 },
        .ops = &line_ops,
        .type = rta.sinks.RTADT_TRANSPORT,
    };
    try testing.expect(base(rb).AddRtaDriver(&line));
    base(rb).LockRtaDrivers();
    // Highest priority first: "line" at 10 before "capture" at 0.
    try testing.expectEqual(&line, base(rb).NextRtaDriver(null).?);
    try testing.expectEqual(&state.driver, base(rb).NextRtaDriver(&line).?);
    try testing.expect(base(rb).NextRtaDriver(&state.driver) == null);
    base(rb).UnlockRtaDrivers();
    // A line driver makes no sink.
    try testing.expect(base(rb).CreateSinkTagList("line", null) == null);
    try testing.expectEqual(err.RTAERR_NO_DRIVER, base(rb).RtaLastError());

    try testing.expect(base(rb).RemRtaDriver(&line));
    try testing.expect(!base(rb).RemRtaDriver(&line));
    try tearDownForTests(rb);
}

test "a sink: named, in its default mode, on the list by priority, its driver held" {
    const rb = try setUpForTests();
    defer kexec.deinit();
    const state = captureOf(rb);

    var why: i32 = 1;
    const low_tags = [_]TagItem{
        .{ .tag = rta.tags.RTAA_Priority, .data = @bitCast(@as(isize, -5)) },
        .{ .tag = rta.tags.RTAA_ErrorPtr, .data = @intFromPtr(&why) },
        .{},
    };
    const low = base(rb).CreateSinkTagList("capture", &low_tags).?;
    try testing.expectEqual(err.RTAERR_OK, why);
    const high_tags = [_]TagItem{
        .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr("speaker") },
        .{ .tag = rta.tags.RTAA_Priority, .data = 5 },
        .{},
    };
    const high = base(rb).CreateSinkTagList("capture", &high_tags).?;

    // Named after the driver and a number, or as asked.
    try testing.expectEqualStrings("capture0", std.mem.span(low.node.name.?));
    try testing.expectEqualStrings("speaker", std.mem.span(high.node.name.?));
    try testing.expectEqual(high, base(rb).FindSink("speaker").?);
    // The most wanted first.
    try testing.expectEqual(high, base(rb).NextSink(null).?);
    try testing.expectEqual(low, base(rb).NextSink(high).?);
    try testing.expect(base(rb).NextSink(low) == null);
    // Each its own instance and mode; the default made the current one.
    try testing.expect(low.instance != high.instance);
    const mode = base(rb).SinkMode(low).?;
    try testing.expectEqual(capture.rate, mode.rate);
    try testing.expect(mode.flags & rta.sinks.AUDIOMF_CURRENT != 0);
    try testing.expectEqual(@as(u16, 2), state.driver.open_cnt);
    // The driver stays while its sinks do.
    try testing.expect(!base(rb).RemRtaDriver(&state.driver));
    // A name nobody registered.
    try testing.expect(base(rb).CreateSinkTagList("nothing", &low_tags) == null);
    try testing.expectEqual(err.RTAERR_NO_DRIVER, why);
    try testing.expectEqual(@as(isize, 7 + capture.control_answer), base(rb).SinkControl(low, rta.sinks.AUDIOCTRL_DRIVER, 7));
    try testing.expectEqual(@as(isize, err.RTAERR_NOT_SUPPORTED), base(rb).SinkControl(low, 1, 0));

    base(rb).DeleteSink(low);
    base(rb).DeleteSink(high);
    try testing.expectEqual(@as(u16, 0), state.driver.open_cnt);
    try testing.expectEqual(@as(u32, 2), state.log.destroyed);
    try tearDownForTests(rb);
}

test "a sink's number: the same for the same driver and name, never shared, never 0" {
    const rb = try setUpForTests();
    defer kexec.deinit();
    const named = [_]TagItem{ .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr("speaker") }, .{} };
    const other = [_]TagItem{ .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr("jack") }, .{} };

    const speaker = base(rb).CreateSinkTagList("capture", &named).?;
    const id = speaker.id;
    try testing.expect(id != 0);
    const jack = base(rb).CreateSinkTagList("capture", &other).?;
    try testing.expect(jack.id != id);
    // Made again - the next boot, or the part plugged in again - it has
    // the same number.
    base(rb).DeleteSink(speaker);
    const again = base(rb).CreateSinkTagList("capture", &named).?;
    try testing.expectEqual(id, again.id);
    // A second of the same name and driver moves on.
    const twin = base(rb).CreateSinkTagList("capture", &named).?;
    try testing.expectEqual(id +% 1, twin.id);

    base(rb).DeleteSink(twin);
    base(rb).DeleteSink(again);
    base(rb).DeleteSink(jack);
    try tearDownForTests(rb);
}

test "a sink's modes: walked, found by rate, set while it is stopped" {
    const rb = try setUpForTests();
    defer kexec.deinit();
    const no_tags = [_]TagItem{.{}};
    const sink = base(rb).CreateSinkTagList("capture", &no_tags).?;
    const other = base(rb).CreateSinkTagList("capture", &no_tags).?;

    const first = base(rb).NextSinkMode(sink, null).?;
    const second = base(rb).NextSinkMode(sink, first).?;
    try testing.expect(base(rb).NextSinkMode(sink, second) == null);
    try testing.expectEqual(first, base(rb).FindSinkMode(sink, 0, 0).?);
    const cd = base(rb).FindSinkMode(sink, capture.cd_rate, 2).?;
    try testing.expectEqual(second, cd);
    try testing.expect(base(rb).FindSinkMode(sink, capture.cd_rate, 1) == null);

    try testing.expectEqual(err.RTAERR_OK, base(rb).SetSinkMode(sink, cd));
    try testing.expectEqual(cd, base(rb).SinkMode(sink).?);
    try testing.expect(cd.flags & rta.sinks.AUDIOMF_CURRENT != 0);
    try testing.expect(first.flags & rta.sinks.AUDIOMF_CURRENT == 0);
    // Started in it, and held in it while started.
    try testing.expectEqual(err.RTAERR_OK, base(rb).StartSink(sink, kexec.SysBase.iface().FindTask(null).?, 1));
    try testing.expectEqual(capture.cd_rate, capture.instanceOf(sink).started_rate);
    try testing.expectEqual(err.RTAERR_IN_USE, base(rb).SetSinkMode(sink, null));
    base(rb).StopSink(sink);
    // Another sink's mode is not this one's; null is the default again.
    try testing.expectEqual(err.RTAERR_BAD_MODE, base(rb).SetSinkMode(sink, base(rb).NextSinkMode(other, null)));
    try testing.expectEqual(err.RTAERR_OK, base(rb).SetSinkMode(sink, null));
    try testing.expectEqual(first, base(rb).SinkMode(sink).?);

    base(rb).DeleteSink(other);
    base(rb).DeleteSink(sink);
    try tearDownForTests(rb);
}

test "a started sink: a buffer when one has been played, what is handed back played; deleted, it goes once it is stopped" {
    const rb = try setUpForTests();
    defer kexec.deinit();
    const state = captureOf(rb);
    const sink = base(rb).CreateSinkTagList("capture", null).?;
    const me = kexec.SysBase.iface().FindTask(null).?;

    // Not started: no buffer, nothing played.
    try testing.expect(base(rb).SinkBuffer(sink) == null);
    var frames: [capture.buffer_frames * 2]i16 = @splat(0);
    try testing.expectEqual(err.RTAERR_NOT_RUNNING, base(rb).PlaySinkBuffer(sink, &frames));

    try testing.expectEqual(err.RTAERR_OK, base(rb).StartSink(sink, me, 0x100));
    try testing.expectEqual(me, state.log.last_task.?);
    try testing.expectEqual(@as(u32, 0x100), state.log.last_mask);
    try testing.expectEqual(err.RTAERR_IN_USE, base(rb).StartSink(sink, me, 0x100));
    // Nothing played yet.
    try testing.expect(base(rb).SinkBuffer(sink) == null);

    capture.played(sink);
    const first = base(rb).SinkBuffer(sink).?;
    for (0..capture.buffer_frames * 2) |at| first[at] = @intCast(at);
    try testing.expectEqual(err.RTAERR_OK, base(rb).PlaySinkBuffer(sink, first));
    try testing.expect(base(rb).SinkBuffer(sink) == null);
    // Three played while nobody asked: the latest is given, two were gaps.
    capture.played(sink);
    capture.played(sink);
    capture.played(sink);
    const second = base(rb).SinkBuffer(sink).?;
    try testing.expect(second != first);
    try testing.expectEqual(@as(u32, 2), sink.underruns);
    @memset(second[0 .. capture.buffer_frames * 2], -1);
    _ = base(rb).PlaySinkBuffer(sink, second);
    const heard = capture.capturedOf(sink);
    try testing.expectEqual(@as(usize, capture.buffer_frames * 4), heard.len);
    try testing.expectEqual(@as(i16, 5), heard[5]);
    try testing.expectEqual(@as(i16, -1), heard[capture.buffer_frames * 2]);

    // Something plays through it: it leaves the list at once, its player
    // is told, and it goes when the player stops it.
    const sys = kexec.SysBase.iface();
    _ = sys.SetSignal(0, 0x100);
    base(rb).DeleteSink(sink);
    try testing.expect(base(rb).NextSink(null) == null);
    try testing.expect(sink.flags & rta.sinks.AUDIOSF_GONE != 0);
    try testing.expect(sys.SetSignal(0, 0x100) & 0x100 != 0);
    try testing.expectEqual(@as(u32, 0), state.log.destroyed);
    capture.played(sink);
    try testing.expect(base(rb).SinkBuffer(sink) != null);
    base(rb).StopSink(sink);
    try testing.expectEqual(@as(u32, 1), state.log.stopped);
    try testing.expectEqual(@as(u32, 1), state.log.destroyed);
    try tearDownForTests(rb);
}

/// A line's driver for the tests: a ring of one buffer each way that is
/// always due, and a count of what it was asked.
const TestLine = struct {
    driver: rta.RtaDriver = .{},
    started: u32 = 0,
    stopped: u32 = 0,
    destroyed: u32 = 0,
    inputs_started: u32 = 0,
    inputs_stopped: u32 = 0,
    input_rate: u32 = 0,
    ring: [8]i16 = @splat(0),
    in_ring: [8]i16 = @splat(0),

    fn of(io: *rta.AudioTransport) *TestLine {
        return @fieldParentPtr("driver", io.driver.?);
    }
    fn create(_: *rta.RtaDriver, io: *rta.AudioTransport, _: ?[*]const TagItem) callconv(.c) i32 {
        io.ops = &line_ops;
        io.buffer_frames = 4;
        io.buffers = 1;
        return err.RTAERR_OK;
    }
    fn destroy(io: *rta.AudioTransport) callconv(.c) void {
        of(io).destroyed += 1;
    }
    fn start(io: *rta.AudioTransport, _: *const rta.AudioMode, _: *exec.Task, _: u32) callconv(.c) i32 {
        of(io).started += 1;
        return err.RTAERR_OK;
    }
    fn stop(io: *rta.AudioTransport) callconv(.c) void {
        of(io).stopped += 1;
    }
    fn buffer(io: *rta.AudioTransport) callconv(.c) ?[*]i16 {
        return &of(io).ring;
    }
    fn startInput(io: *rta.AudioTransport, mode: *const rta.AudioMode, _: *exec.Task, _: u32) callconv(.c) i32 {
        of(io).inputs_started += 1;
        of(io).input_rate = mode.rate;
        return err.RTAERR_OK;
    }
    fn stopInput(io: *rta.AudioTransport) callconv(.c) void {
        of(io).inputs_stopped += 1;
    }
    fn inputBuffer(io: *rta.AudioTransport) callconv(.c) ?[*]const i16 {
        return &of(io).in_ring;
    }
    const line_ops = rta.AudioTransportOps{
        .destroy = &destroy,
        .start = &start,
        .stop = &stop,
        .buffer = &buffer,
        .start_input = &startInput,
        .stop_input = &stopInput,
        .input_buffer = &inputBuffer,
    };
    const driver_ops = rta.RtaDriverOps{ .create_transport = &create };
};

test "a line: made by its own driver, held while a sink names it, started and stopped by the sink" {
    const rb = try setUpForTests();
    defer kexec.deinit();
    var line: TestLine = .{};
    line.driver = .{ .node = .{ .name = "testline" }, .type = rta.sinks.RTADT_TRANSPORT, .ops = &TestLine.driver_ops };
    try testing.expect(base(rb).AddRtaDriver(&line.driver));

    // A sink driver makes no line.
    try testing.expect(base(rb).CreateAudioTransportTagList("capture", null) == null);
    const io = base(rb).CreateAudioTransportTagList("testline", null).?;
    try testing.expectEqualStrings("testline0", std.mem.span(io.node.name.?));
    const on_line = [_]TagItem{ .{ .tag = rta.tags.RTAA_Transport, .data = @intFromPtr(io) }, .{} };
    const sink = base(rb).CreateSinkTagList("capture", &on_line).?;
    try testing.expectEqual(io, sink.transport.?);
    try testing.expectEqual(@as(u16, 1), io.open_cnt);
    // A sink names it: it stays.
    base(rb).DeleteAudioTransport(io);
    try testing.expectEqual(err.RTAERR_IN_USE, base(rb).RtaLastError());

    // What a sink's driver does from its own start: the line runs, and its
    // buffers are there to fill.
    const mode = base(rb).SinkMode(sink).?;
    const me = kexec.SysBase.iface().FindTask(null).?;
    try testing.expect(base(rb).AudioTransportBuffer(io) == null);
    try testing.expectEqual(err.RTAERR_OK, base(rb).StartAudioTransport(io, mode, me, 1));
    try testing.expectEqual(err.RTAERR_IN_USE, base(rb).StartAudioTransport(io, mode, me, 1));
    try testing.expectEqual(@as(?[*]i16, &line.ring), base(rb).AudioTransportBuffer(io));
    // A line that takes no buffers back says so.
    try testing.expectEqual(err.RTAERR_NOT_SUPPORTED, base(rb).PlayAudioTransportBuffer(io, &line.ring));
    base(rb).StopAudioTransport(io);
    base(rb).StopAudioTransport(io);
    try testing.expectEqual(@as(u32, 1), line.started);
    try testing.expectEqual(@as(u32, 1), line.stopped);
    try testing.expectEqual(err.RTAERR_NOT_RUNNING, base(rb).PlayAudioTransportBuffer(io, &line.ring));

    base(rb).DeleteSink(sink);
    try testing.expectEqual(@as(u16, 0), io.open_cnt);
    try testing.expect(!base(rb).RemRtaDriver(&line.driver));
    base(rb).DeleteAudioTransport(io);
    try testing.expectEqual(@as(u32, 1), line.destroyed);
    try testing.expect(base(rb).RemRtaDriver(&line.driver));
    try tearDownForTests(rb);
}

test "a line's way in: started beside its way out or alone, its buffers the source driver's, deletion refused while it runs" {
    const rb = try setUpForTests();
    defer kexec.deinit();
    var line: TestLine = .{};
    line.driver = .{ .node = .{ .name = "testline" }, .type = rta.sinks.RTADT_TRANSPORT, .ops = &TestLine.driver_ops };
    try testing.expect(base(rb).AddRtaDriver(&line.driver));
    const io = base(rb).CreateAudioTransportTagList("testline", null).?;
    const on_line = [_]TagItem{ .{ .tag = rta.tags.RTAA_Transport, .data = @intFromPtr(io) }, .{} };
    const source = base(rb).CreateSourceTagList("capture", &on_line).?;
    try testing.expectEqual(io, source.transport.?);
    try testing.expectEqual(@as(u16, 1), io.open_cnt);

    const me = kexec.SysBase.iface().FindTask(null).?;
    const cd = base(rb).NextSourceMode(source, base(rb).NextSourceMode(source, null)).?;
    try testing.expect(base(rb).AudioTransportInput(io) == null);
    try testing.expectEqual(err.RTAERR_OK, base(rb).StartAudioTransportInput(io, cd, me, 2));
    try testing.expectEqual(err.RTAERR_IN_USE, base(rb).StartAudioTransportInput(io, cd, me, 2));
    try testing.expectEqual(capture.cd_rate, line.input_rate);
    try testing.expectEqual(@as(?[*]const i16, &line.in_ring), base(rb).AudioTransportInput(io));
    // The way out is a way of its own: started and stopped beside it.
    try testing.expectEqual(err.RTAERR_OK, base(rb).StartAudioTransport(io, cd, me, 1));
    base(rb).StopAudioTransport(io);
    try testing.expectEqual(@as(?[*]const i16, &line.in_ring), base(rb).AudioTransportInput(io));

    // A line whose way in runs stays.
    base(rb).DeleteSource(source);
    try testing.expectEqual(@as(u16, 0), io.open_cnt);
    base(rb).DeleteAudioTransport(io);
    try testing.expectEqual(err.RTAERR_IN_USE, base(rb).RtaLastError());
    base(rb).StopAudioTransportInput(io);
    base(rb).StopAudioTransportInput(io);
    try testing.expectEqual(@as(u32, 1), line.inputs_started);
    try testing.expectEqual(@as(u32, 1), line.inputs_stopped);
    try testing.expect(base(rb).AudioTransportInput(io) == null);
    base(rb).DeleteAudioTransport(io);
    try testing.expectEqual(@as(u32, 1), line.destroyed);
    try testing.expect(base(rb).RemRtaDriver(&line.driver));
    try tearDownForTests(rb);
}

test "a source: named, on a list of its own by priority, numbered as a sink is, in its default mode" {
    const rb = try setUpForTests();
    defer kexec.deinit();
    const state = captureOf(rb);

    const low_tags = [_]TagItem{ .{ .tag = rta.tags.RTAA_Priority, .data = @bitCast(@as(isize, -5)) }, .{} };
    const low = base(rb).CreateSourceTagList("capture", &low_tags).?;
    const high_tags = [_]TagItem{
        .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr("microphone") },
        .{ .tag = rta.tags.RTAA_Priority, .data = 5 },
        .{ .tag = capture.mono, .data = 1 },
        .{},
    };
    const high = base(rb).CreateSourceTagList("capture", &high_tags).?;
    try testing.expectEqualStrings("capture0", std.mem.span(low.node.name.?));
    try testing.expectEqualStrings("microphone", std.mem.span(high.node.name.?));
    // The most wanted first, and no sink among them.
    try testing.expectEqual(high, base(rb).NextSource(null).?);
    try testing.expectEqual(low, base(rb).NextSource(high).?);
    try testing.expect(base(rb).NextSource(low) == null);
    try testing.expect(base(rb).NextSink(null) == null);
    // Numbered as a sink of that name would be, and never 0.
    const sink_tags = [_]TagItem{ .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr("microphone") }, .{} };
    const sink = base(rb).CreateSinkTagList("capture", &sink_tags).?;
    try testing.expect(high.id != 0);
    try testing.expectEqual(sink.id, high.id);
    try testing.expect(low.id != high.id);
    base(rb).DeleteSink(sink);
    // Its modes, the default the one it is in; the one-sided one says so.
    const first = base(rb).NextSourceMode(high, null).?;
    try testing.expectEqual(first, high.mode.?);
    try testing.expect(first.flags & rta.sinks.AUDIOMF_CURRENT != 0);
    try testing.expectEqual(rta.AUDIOSIDES_MONO, first.sides);
    try testing.expectEqual(@as(u32, 1), first.channels);
    try testing.expectEqual(rta.AUDIOSIDES_LEFT_FIRST, low.mode.?.sides);
    try testing.expectEqual(@as(u16, 2), state.driver.open_cnt);
    try testing.expect(base(rb).CreateSourceTagList("nothing", null) == null);
    try testing.expectEqual(err.RTAERR_NO_DRIVER, base(rb).RtaLastError());

    base(rb).DeleteSource(low);
    base(rb).DeleteSource(high);
    try testing.expectEqual(@as(u16, 0), state.driver.open_cnt);
    try testing.expect(base(rb).NextSource(null) == null);
    try tearDownForTests(rb);
}

test "a started source: in the mode asked for, its latest buffer when one is filled, the ones missed counted, deletion refused" {
    const rb = try setUpForTests();
    defer kexec.deinit();
    const state = captureOf(rb);
    const source = base(rb).CreateSourceTagList("capture", null).?;
    const other = base(rb).CreateSourceTagList("capture", null).?;
    const me = kexec.SysBase.iface().FindTask(null).?;

    try testing.expect(base(rb).SourceBuffer(source) == null);
    // Another source's mode is not this one's.
    try testing.expectEqual(err.RTAERR_BAD_MODE, base(rb).StartSource(source, base(rb).NextSourceMode(other, null), me, 0x100));
    const first = base(rb).NextSourceMode(source, null).?;
    const cd = base(rb).NextSourceMode(source, first).?;
    try testing.expectEqual(err.RTAERR_OK, base(rb).StartSource(source, cd, me, 0x100));
    try testing.expectEqual(err.RTAERR_IN_USE, base(rb).StartSource(source, null, me, 0x100));
    try testing.expectEqual(cd, source.mode.?);
    try testing.expect(cd.flags & rta.sinks.AUDIOMF_CURRENT != 0);
    try testing.expect(first.flags & rta.sinks.AUDIOMF_CURRENT == 0);
    try testing.expectEqual(capture.cd_rate, capture.sourceInstanceOf(source).started_rate);
    try testing.expect(base(rb).SourceBuffer(source) == null);

    var heard: [capture.buffer_frames * 2]i16 = undefined;
    for (&heard, 0..) |*sample, at| sample.* = @intCast(at);
    capture.recorded(source, &heard);
    const got = base(rb).SourceBuffer(source).?;
    try testing.expectEqualSlices(i16, &heard, got[0 .. capture.buffer_frames * 2]);
    try testing.expect(base(rb).SourceBuffer(source) == null);
    // Three filled while nobody took one: the latest, and two lost.
    capture.recorded(source, &heard);
    @memset(&heard, 7);
    capture.recorded(source, &heard);
    @memset(&heard, -3);
    capture.recorded(source, &heard);
    try testing.expectEqual(@as(i16, -3), base(rb).SourceBuffer(source).?[0]);
    try testing.expectEqual(@as(u32, 2), source.overruns);

    // Something records from it: it stays.
    base(rb).DeleteSource(source);
    try testing.expectEqual(err.RTAERR_IN_USE, base(rb).RtaLastError());
    base(rb).StopSource(source);
    base(rb).StopSource(source);
    try testing.expectEqual(@as(u32, 1), state.log.sources_started);
    try testing.expectEqual(@as(u32, 1), state.log.sources_stopped);
    // Null is its default again.
    try testing.expectEqual(err.RTAERR_OK, base(rb).StartSource(source, null, me, 0x100));
    try testing.expectEqual(first, source.mode.?);
    base(rb).StopSource(source);

    base(rb).DeleteSource(other);
    base(rb).DeleteSource(source);
    try tearDownForTests(rb);
}
