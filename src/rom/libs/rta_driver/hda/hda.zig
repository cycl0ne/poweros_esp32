// SPDX-License-Identifier: MPL-2.0
//! The machine's high definition audio controllers as sound outputs: a
//! unit for each controller and a sink for each output its codec turns
//! out to have.
//!
//! **A controller is found, not described.** It is a function on PCI of
//! class 04 03 00 - an audio device with this programming interface - so
//! pci.library's walk is what says how many a machine has and where they
//! are, and no board writes any of it down. A machine often has two: the
//! chip's own codec, behind the jacks and the speakers, and the one on
//! the display side of the same chip, which is the sound that goes out
//! over a display link. They are the same controller twice, so they are
//! the same driver twice.
//!
//! **A codec is read.** The controller is a known register block, but
//! what is behind it is a graph the codec describes when asked: function
//! groups, converters that turn a stream into samples on a pin, pins
//! that leave the chip, and the mixers and selectors between them. So
//! nothing about a particular codec is written here. What a pin is for -
//! a green jack, a black one, a built-in speaker, a display link - is in
//! the pin's own configuration default, which is also where its name
//! comes from.
//!
//! **A sink is one way out.** Every pin a codec can reach from a
//! converter becomes a sink of its own, named and ordered by what the
//! pin is for: the speakers of a machine before a jack, a jack before a
//! display link, so a machine plays through what the person in front of
//! it expects without being asked. Each sink takes a stream descriptor
//! of the controller when it is started and gives it back when it is
//! stopped, so two of them play at once on a controller that has two
//! descriptors free.
//!
//! **The ring is the controller's own.** A started sink is a buffer
//! descriptor list the controller walks round for ever, with an
//! interrupt at the end of every buffer: the interrupt signals the task
//! that started the sink, and the task fills the buffer just played.
//! Nothing is ever started again and nothing reads a position.
//!
//! **It comes up with the cold start**, as the other sound drivers do:
//! it opens rta.library, hands in a driver of the sink kind, and makes
//! its sinks. pci.library is in the ROM of a board that has this and
//! comes up ahead of it, so the functions are found and their registers
//! placed by the time this looks for them.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const rta = sdk.rta;
const timer = sdk.devices.timer;
const pci = sdk.pci;
const PCIBase = sdk.interface.pci.PCIBase;
const RtaBase = sdk.interface.rta.RtaBase;
const TagItem = sdk.utility.TagItem;
const regs = @import("regs.zig");
const controller = @import("controller.zig");
const Controller = controller.Controller;
const codec_file = @import("codec.zig");
const stream_file = @import("stream.zig");
const verbs = @import("verbs.zig");
const err = rta.errors;

const MODULE_NAME = "rta-hda";
const DRIVER_NAME = "hda";
const VERSION = 1;
const REVISION = 1;
const BUILD_DATE = "06.11.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The class of a function this drives: a multimedia device, of the
/// audio kind, with the high definition audio programming interface.
/// The interface byte is part of it - an AC97 function is the same class
/// and subclass with another interface, and is not this.
const class_hda: u32 = 0x04_03_00;

/// How many controllers are driven. A machine has one or two; the
/// ceiling is here so that the state is one allocation, and a machine
/// that has more says so in the log rather than losing one quietly.
const max_controllers = 4;

/// The ring a started sink runs on: buffers of this many stereo frames
/// each, which the controller plays round for ever. Four buffers of 256
/// frames at 48000 Hz is twenty milliseconds of sound in hand, and the
/// task that fills them is woken every five: long enough that a machine
/// doing something else as well keeps up, and short enough that a
/// program hears its own sound begin when it asked for it.
const buffer_frames: u32 = 256;
const buffer_samples: u32 = buffer_frames * 2;
const buffer_bytes: u32 = buffer_samples * 2;
const buffers: u32 = 4;
const ring_bytes: u32 = buffer_bytes * buffers;

/// How many sinks are made at most, over every controller and every
/// codec: a machine has a handful of ways out and this is past all of
/// them.
const max_sinks = 16;

/// How many modes a sink offers: the two rates sound is played at.
const max_modes = 2;

/// The bytes of a name a sink is made with, with its NUL.
const name_len = 32;

/// One controller: the function it is, its registers and rings, and
/// which codecs answered on it.
const Card = struct {
    function: *pci.PCIDevice,
    hw: Controller,
    /// A bit per serial data in line, as the controller reported after
    /// its reset.
    codecs: u16 = 0,
    /// What each codec that answered turned out to have. One controller
    /// has one codec on all but the oddest machines; the link numbers
    /// fifteen.
    read: [max_codecs]codec_file.Codec = @splat(.{}),
    read_count: u32 = 0,
    /// Which of its output stream descriptors are taken, a bit each. A
    /// bit is claimed with one read-modify-write, so that two sinks
    /// started at once cannot both take the same descriptor.
    busy: u32 = 0,
};

/// How many codecs on one controller are read.
const max_codecs = 4;

/// The driver's own state, allocated once at cold start and kept for
/// good: the driver is on rta's list from then on.
const State = struct {
    sys: *ExecBase,
    pb: *PCIBase,
    /// rta.library, opened where there is a sink to hand it.
    rb: ?*RtaBase = null,
    driver: rta.sinks.RtaDriver = .{},
    /// What the waits while a controller is set up are measured by.
    timer_io: timer.TimeRequest = .{},
    timer_port: exec.MsgPort = .{},
    timer_open: bool = false,
    cards: [max_controllers]?*Card = @splat(null),
    card_count: u32 = 0,
    /// The sinks made, so that a start can see whether another of them
    /// is already playing through the converter it wants.
    made: [max_sinks]?*Instance = @splat(null),
    made_count: u32 = 0,
    /// Which way out the sink now being made is for. A sink of this
    /// driver is made by this driver, from an output it has just found
    /// and holds the only pointer to; a create from anywhere else has no
    /// output to be made for and is refused.
    making: ?Making = null,
};

/// What the sink now being made is a way out of.
const Making = struct {
    card: *Card,
    codec: *codec_file.Codec,
    output: *const codec_file.Output,
};

fn stateOf(driver: *rta.sinks.RtaDriver) *State {
    return @fieldParentPtr("driver", driver);
}

/// A sink's own instance, which rta.library allocates beside the sink in
/// internal memory: the interrupt reads it.
const Instance = struct {
    sys: *ExecBase,
    state: *State,
    card: *Card,
    codec: *codec_file.Codec,
    output: *const codec_file.Output,
    modes: [max_modes]rta.AudioMode = @splat(.{}),
    /// The stream it plays on, which is one only while it is started:
    /// `held` says whether a descriptor is taken, `up` whether it runs.
    out: stream_file.Stream,
    held: bool = false,
    up: bool = false,
    /// The ring, as allocated and as the controller reads it: the first
    /// is what is freed, the second is where the buffers start inside it.
    memory: ?*anyopaque = null,
    ring: usize = 0,
    int: exec.Interrupt = .{},
    int_added: bool = false,
    /// The gain the sink was given last, which a start sets the
    /// amplifier to again.
    gain: u32 = rta.sinks.AUDIOGAIN_UNITY,
    /// The task the interrupt signals and with what; the buffers the
    /// controller has finished, and the count at the last take - more
    /// than one between two takes is a buffer that was played again
    /// before the task had filled it.
    task: ?*exec.Task = null,
    signal_mask: u32 = 0,
    ended: u32 = 0,
    taken: u32 = 0,
};

fn instanceOf(sink: *rta.AudioSink) *Instance {
    return @ptrCast(@alignCast(sink.instance.?));
}

const ops = rta.AudioSinkOps{
    .start = &start,
    .stop = &stop,
    .buffer = &buffer,
    .play = &play,
    .control = &controlSink,
};

const driver_ops = rta.sinks.RtaDriverOps{ .create_sink = &createSink };

/// **The hardware first.** A machine need have no audio controller of
/// this kind at all, and one that has none wants no driver of this on
/// rta's list: there would be nothing for it to make a sink out of. So
/// the functions are looked for before anything is handed in, and a
/// machine with none has this module cost it an allocation and a walk of
/// a list it has already made.
fn init(seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*anyopaque {
    _ = seg_list;
    const pci_lib = sys.OpenLibrary(pci.PCINAME, 1) orelse {
        step(sys, "no pci.library: nothing to find a controller on");
        return @ptrCast(sys);
    };
    const memory = sys.AllocVec(@sizeOf(State), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        step(sys, "no memory for the driver");
        sys.CloseLibrary(pci_lib);
        return @ptrCast(sys);
    };
    const state: *State = @ptrCast(@alignCast(memory));
    state.* = .{ .sys = sys, .pb = @ptrCast(pci_lib) };
    openTimer(state);
    findAll(state);
    if (state.card_count == 0) {
        step(sys, "no audio controller of this kind on the machine");
        giveBack(state);
        sys.FreeVec(memory);
        sys.CloseLibrary(pci_lib);
        return @ptrCast(sys);
    }
    const library = sys.OpenLibrary(rta.RTANAME, rta.RTA_VERSION) orelse {
        step(sys, "no rta.library: nothing to hand a sink to");
        giveBack(state);
        sys.FreeVec(memory);
        sys.CloseLibrary(pci_lib);
        return @ptrCast(sys);
    };
    const rb: *RtaBase = @ptrCast(library);
    state.rb = rb;
    state.driver = .{
        .node = .{ .name = DRIVER_NAME, .pri = 0 },
        .version = VERSION,
        .revision = REVISION,
        .id_string = VERSION_STRING[1..],
        .type = rta.sinks.RTADT_SINK,
        .flags = rta.sinks.RTADF_INTERNAL_INSTANCE,
        .ops = &driver_ops,
        .instance_size = @sizeOf(Instance),
    };
    if (!rb.AddRtaDriver(&state.driver)) {
        step(sys, "rta.library would not take the driver");
        giveBack(state);
        sys.FreeVec(memory);
        sys.CloseLibrary(library);
        sys.CloseLibrary(pci_lib);
        return @ptrCast(sys);
    }
    makeSinks(state, rb);
    releaseTimer(state);
    // The libraries stay open and the state stays allocated: the
    // controllers are this module's from here on, and the driver is on
    // rta's list for good.
    return @ptrCast(sys);
}

/// Everything a run that found nothing took: the timer, and the
/// allocations of any controller that was set up before another failed.
fn giveBack(state: *State) void {
    const sys = state.sys;
    for (state.cards[0..state.card_count]) |maybe| {
        const card = maybe orelse continue;
        state.pb.ReleasePCIDevice(card.function);
        sys.FreeMem(card, @sizeOf(Card));
    }
    state.card_count = 0;
    releaseTimer(state);
}

/// The timer given back once the cold start is over, and the controllers
/// left to count turns instead.
///
/// A request belongs to the task that opened it - its reply is signalled
/// to that task - and the task that starts a sink is not the one the
/// machine came up on. Everything the timer measures happens here: a
/// controller's reset, and the verbs a codec is read with. The one wait
/// after this is a stream descriptor's reset, which the specification
/// gives a few hundred nanoseconds.
fn releaseTimer(state: *State) void {
    const sys = state.sys;
    if (!state.timer_open) return;
    for (state.cards[0..state.card_count]) |maybe| {
        if (maybe) |card| card.hw.io = null;
    }
    sys.CloseDevice(&state.timer_io.node);
    sys.FreeSignal(@intCast(state.timer_port.sig_bit));
    state.timer_open = false;
}

/// timer.device's microsecond unit, which the waits while a controller
/// is reset are measured by. A machine without one is driven all the
/// same: the waits count their turns instead.
fn openTimer(state: *State) void {
    const sys = state.sys;
    state.timer_port = .{ .flags = exec.PA_SIGNAL, .sig_task = sys.FindTask(null) };
    state.timer_port.msg_list.init(.message);
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return;
    state.timer_port.sig_bit = @intCast(signal);
    state.timer_io.node.message.reply_port = &state.timer_port;
    state.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &state.timer_io.node, 0) != 0) {
        sys.FreeSignal(signal);
        return;
    }
    state.timer_open = true;
}

/// Every audio function of this kind on the machine, taken in the order
/// pci.library found them.
fn findAll(state: *State) void {
    const sys = state.sys;
    const pb = state.pb;
    var function = pb.FindPCIClass(null, class_hda, pci.PCI_CLASS_SUB_MASK);
    while (function) |each| : (function = pb.FindPCIClass(each, class_hda, pci.PCI_CLASS_SUB_MASK)) {
        if (state.card_count == max_controllers) {
            sdk.exec.kprintf(sys, "%s: more than %d controllers; the rest are left alone\n", .{
                MODULE_NAME, @as(u32, max_controllers),
            });
            return;
        }
        if (pb.ClaimPCIDevice(each, MODULE_NAME)) |held| {
            sdk.exec.kprintf(sys, "%s: the controller at %x is %s's\n", .{
                MODULE_NAME, @as(u32, each.device_id), held,
            });
            continue;
        }
        if (make(state, each)) |card| {
            state.cards[state.card_count] = card;
            state.card_count += 1;
        } else {
            pb.ReleasePCIDevice(each);
        }
    }
}

/// One controller set up: its registers placed, its rings allocated, out
/// of reset, and what answered on it said in the log. Null where it
/// cannot be driven, and nothing of it left allocated.
fn make(state: *State, function: *pci.PCIDevice) ?*Card {
    const sys = state.sys;
    const at = place(state, function) orelse return null;
    const memory = sys.AllocMem(@sizeOf(Card), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return null;
    const card: *Card = @ptrCast(@alignCast(memory));
    card.* = .{
        .function = function,
        .hw = .{
            .sys = sys,
            .io = if (state.timer_open) &state.timer_io else null,
            .at = at,
            .coherent = coherent(state, function),
        },
    };
    const answered = controller.reset(&card.hw) orelse {
        sdk.exec.kprintf(sys, "%s: the controller at %x does not come out of reset\n", .{
            MODULE_NAME, @as(u32, function.device_id),
        });
        sys.FreeMem(memory, @sizeOf(Card));
        return null;
    };
    card.codecs = answered;
    report(state, card);
    return card;
}

/// What a controller is, as the log has it: which function, what it says
/// it can do, and which codecs answered.
fn report(state: *State, card: *Card) void {
    const sys = state.sys;
    sdk.exec.kprintf(sys, "%s: %04lx:%04lx at %ld.%ld.%ld: version %d.%d, %d out, %d in\n", .{
        MODULE_NAME,
        @as(i64, card.function.vendor_id),
        @as(i64, card.function.device_id),
        @as(i64, card.function.bus),
        @as(i64, card.function.device),
        @as(i64, card.function.function),
        @as(u32, regs.read8(card.hw.at, regs.vmaj)),
        @as(u32, regs.read8(card.hw.at, regs.vmin)),
        card.hw.out_streams,
        card.hw.in_streams,
    });
    readCodecs(state, card);
}

/// Each codec that answered, read for what it has. One with no audio
/// function group in it is left out: there is nothing to play through.
fn readCodecs(state: *State, card: *Card) void {
    var address: u4 = 0;
    while (true) : (address += 1) {
        if (card.codecs & (@as(u16, 1) << address) != 0 and card.read_count < max_codecs) {
            const into = &card.read[card.read_count];
            if (codec_file.read(&card.hw, into, address)) {
                card.read_count += 1;
                reportCodec(state, into);
            } else {
                sdk.exec.klog(state.sys, exec.LOG_DEBUG, "%s: codec %d has no audio in it\n", .{
                    MODULE_NAME, @as(u32, address),
                });
            }
        }
        if (address == 15) break;
    }
}

/// What one codec turned out to be, and the way out of each of its pins.
fn reportCodec(state: *State, codec: *const codec_file.Codec) void {
    const sys = state.sys;
    sdk.exec.kprintf(sys, "%s: codec %d: %04lx:%04lx, %d output(s)\n", .{
        MODULE_NAME,
        @as(u32, codec.address),
        @as(i64, codec.vendor),
        @as(i64, codec.device),
        codec.output_count,
    });
    for (codec.outputs[0..codec.output_count]) |*output| {
        sdk.exec.kprintf(sys, "%s:   %s: converter %d through pin %d%s, %s\n", .{
            MODULE_NAME,
            codec_file.nameOf(output),
            @as(u32, output.converter),
            @as(u32, output.pin),
            @as([*:0]const u8, if (output.eapd) " with an amplifier to power" else ""),
            rates(output.pcm),
        });
    }
}

/// The rates an output takes, as a line: the ones a sink is made of.
fn rates(pcm: u32) [*:0]const u8 {
    const has48 = pcm & verbs.pcm_rate_48000 != 0;
    const has44 = pcm & verbs.pcm_rate_44100 != 0;
    if (has48 and has44) return "44100 and 48000 Hz";
    if (has48) return "48000 Hz";
    if (has44) return "44100 Hz";
    if (pcm == 0) return "no rate it would say";
    return "some other rate";
}

/// A line for a boot that stops in here, or one where the machine turns
/// out to have nothing this drives. Debug lines, so a kernel built to
/// keep them has them and every other boot is quiet.
fn step(sys: *ExecBase, comptime text: [:0]const u8) void {
    sdk.exec.klog(sys, exec.LOG_DEBUG, MODULE_NAME ++ ": " ++ text ++ "\n", .{});
}

/// The controller's register block, from the first BAR, with the
/// function told to answer in memory and to master the bus - it reads
/// and writes the rings itself.
fn place(state: *State, function: *pci.PCIDevice) ?usize {
    const pb = state.pb;
    var command = pb.ReadPCIConfig(function, pci.PCI_COMMAND, 2);
    command |= pci.PCI_COMMAND_MEMORY | pci.PCI_COMMAND_MASTER;
    pb.WritePCIConfig(function, pci.PCI_COMMAND, 2, command);
    const bar = function.bars[0];
    if (bar.address == 0 or bar.flags & pci.PCIBAR_IO != 0) {
        sdk.exec.kprintf(state.sys, "%s: the controller at %x has no register block in memory\n", .{
            MODULE_NAME, @as(u32, function.device_id),
        });
        return null;
    }
    return @intCast(bar.address);
}

/// Whether what the controller reads and writes sees the processors'
/// caches, so that nothing is written back or thrown away around the
/// rings.
fn coherent(state: *State, function: *pci.PCIDevice) bool {
    const lib: *exec.Library = @ptrCast(@alignCast(state.pb));
    return lib.revision >= 1 and function.dma_coherent;
}

/// A sink for every way out of every codec of every controller, named
/// for what its pin is and ordered so that a machine plays through the
/// one in front of the person using it.
///
/// Two ways out of a kind - two line outs, two display links - would be
/// one name twice, and rta works a sink's number out from its name, so
/// the second of a kind and every one after it gets a number after the
/// name: what remembers which output a machine played through then means
/// one of them and not either.
fn makeSinks(state: *State, rb: *RtaBase) void {
    const sys = state.sys;
    var seen: [max_sinks]?[*:0]const u8 = @splat(null);
    var seen_count: u32 = 0;
    for (state.cards[0..state.card_count]) |maybe| {
        const card = maybe orelse continue;
        for (card.read[0..card.read_count]) |*codec| {
            for (codec.outputs[0..codec.output_count]) |*output| {
                if (state.made_count == max_sinks) {
                    sdk.exec.kprintf(sys, "%s: more ways out than sinks; the rest are left alone\n", .{MODULE_NAME});
                    return;
                }
                const called = codec_file.nameOf(output);
                var number: u32 = 1;
                for (seen[0..seen_count]) |each| {
                    if (each == called) number += 1;
                }
                seen[seen_count] = called;
                seen_count += 1;
                var text: [name_len]u8 = undefined;
                const rank: i32 = codec_file.rankOf(output);
                const sink_tags = [_]TagItem{
                    .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr(numbered(&text, called, number)) },
                    .{ .tag = rta.tags.RTAA_Priority, .data = @bitCast(@as(isize, rank)) },
                    .{},
                };
                state.making = .{ .card = card, .codec = codec, .output = output };
                const made = rb.CreateSinkTagList(DRIVER_NAME, &sink_tags);
                state.making = null;
                if (made) |sink| {
                    state.made[state.made_count] = instanceOf(sink);
                    state.made_count += 1;
                    sdk.exec.kprintf(sys, "%s: %s is a sink at priority %d\n", .{
                        MODULE_NAME, sink.node.name orelse called, rank,
                    });
                } else {
                    sdk.exec.kprintf(sys, "%s: no sink for %s: %s\n", .{
                        MODULE_NAME, called, rb.RtaErrorText(rb.RtaLastError()),
                    });
                }
            }
        }
    }
}

/// `called` with a number after it where it is not the first of its
/// kind, written into the caller's buffer.
fn numbered(text: *[name_len]u8, called: [*:0]const u8, number: u32) [*:0]const u8 {
    if (number <= 1) return called;
    var at: usize = 0;
    while (called[at] != 0 and at + 4 < name_len) : (at += 1) text[at] = called[at];
    text[at] = ' ';
    at += 1;
    if (number >= 10) {
        text[at] = '0' + @as(u8, @intCast(number / 10 % 10));
        at += 1;
    }
    text[at] = '0' + @as(u8, @intCast(number % 10));
    text[at + 1] = 0;
    return @ptrCast(text);
}

/// The sink filled in for the way out it is being made for: its ops, the
/// rates it can run at, and the ring's geometry. Nothing of the hardware
/// is touched until it is started.
fn createSink(made_by: *rta.sinks.RtaDriver, sink: *rta.AudioSink, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    _ = tag_list;
    const state = stateOf(made_by);
    const making = state.making orelse return err.RTAERR_BAD_TAGS;
    const instance = instanceOf(sink);
    instance.* = .{
        .sys = state.sys,
        .state = state,
        .card = making.card,
        .codec = making.codec,
        .output = making.output,
        .out = .{ .hw = &making.card.hw, .count = buffers, .bytes = buffer_bytes },
    };
    instance.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = MODULE_NAME },
        .data = instance,
        .code = &server,
    };
    if (addModes(instance, sink) == 0) return err.RTAERR_BAD_MODE;
    sink.ops = &ops;
    sink.buffer_frames = buffer_frames;
    sink.buffers = buffers;
    return err.RTAERR_OK;
}

/// The rates the output takes, of the two that sound is played at, as
/// the sink's modes - 48000 first, which is what it runs at when no mode
/// is asked for. None where the converter takes neither of them, or
/// takes no 16-bit samples: then there is nothing to offer and no sink
/// is made of it.
fn addModes(instance: *Instance, sink: *rta.AudioSink) u32 {
    const pcm = instance.output.pcm;
    if (pcm & verbs.pcm_bits_16 == 0) return 0;
    var count: u32 = 0;
    if (pcm & verbs.pcm_rate_48000 != 0) {
        instance.modes[count] = modeOf(48_000, count == 0);
        count += 1;
    }
    if (pcm & verbs.pcm_rate_44100 != 0) {
        instance.modes[count] = modeOf(44_100, count == 0);
        count += 1;
    }
    for (instance.modes[0..count]) |*each| instance.sys.AddTail(&sink.modes, &each.node);
    return count;
}

fn modeOf(rate: u32, first: bool) rta.AudioMode {
    return .{
        .node = .{ .name = if (rate == 48_000) "48000 Hz stereo" else "44100 Hz stereo" },
        .id = rate,
        .rate = rate,
        .bits = 16,
        .channels = 2,
        .sides = rta.AUDIOSIDES_LEFT_FIRST,
        .flags = if (first) rta.sinks.AUDIOMF_DEFAULT else 0,
    };
}

/// The sink gone: whatever it still holds given back, and it taken off
/// the driver's own list. The instance itself is rta's memory and goes
/// with the sink.
fn destroy(sink: *rta.AudioSink) callconv(.c) void {
    const instance = instanceOf(sink);
    streamDown(instance);
    const state = instance.state;
    for (state.made[0..state.made_count]) |*each| {
        if (each.* == instance) each.* = null;
    }
}

fn start(sink: *rta.AudioSink, asked: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    const instance = instanceOf(sink);
    if (instance.up) return err.RTAERR_IN_USE;
    const shape = stream_file.format(asked.rate, asked.bits, asked.channels) orelse return err.RTAERR_BAD_MODE;
    if (busyConverter(instance)) return err.RTAERR_IN_USE;
    instance.signal_mask = signal_mask;
    instance.task = task;
    const code = streamUp(instance, shape);
    if (code != err.RTAERR_OK) streamDown(instance);
    return code;
}

fn stop(sink: *rta.AudioSink) callconv(.c) void {
    streamDown(instanceOf(sink));
}

/// Whether another sink of this driver is already playing through this
/// one's converter. Two ways out of a codec often share one - a jack and
/// the speakers behind the same mixer - and a converter takes one stream
/// at a time, so the second to be started is told the output is in use
/// rather than quietly taking the first one's sound away.
fn busyConverter(instance: *Instance) bool {
    const state = instance.state;
    for (state.made[0..state.made_count]) |maybe| {
        const other = maybe orelse continue;
        if (other == instance or !other.up) continue;
        if (other.codec == instance.codec and other.output.converter == instance.output.converter) return true;
    }
    return false;
}

/// The stream started, in the order the parts want it: the ring's
/// memory, a stream descriptor of the controller, the interrupt, the
/// codec's way out switched on with the converter told what to play, and
/// the descriptor set going. It starts on silence, which is what the
/// cleared memory is.
fn streamUp(instance: *Instance, shape: u16) i32 {
    const sys = instance.sys;
    const state = instance.state;
    const card = instance.card;
    // The buffers and the list that describes them in one block the
    // controller reaches, with room to put the buffers on the boundary
    // the controller wants them on; the list follows them on another,
    // the buffers being a whole number of boundaries long.
    const size = ring_bytes + @sizeOf(stream_file.Entry) * buffers + stream_file.alignment;
    const memory = sys.AllocVec(size, exec.MEMF_DMA | exec.MEMF_CLEAR) orelse return err.RTAERR_NO_MEMORY;
    instance.memory = memory;
    const ring = std.mem.alignForward(usize, @intFromPtr(memory), stream_file.alignment);
    instance.ring = ring;

    const which = takeStream(card) orelse {
        sdk.exec.kprintf(sys, "%s: every stream of the controller is taken\n", .{MODULE_NAME});
        return err.RTAERR_NO_OUTPUT;
    };
    instance.held = true;
    instance.out = .{
        .hw = &card.hw,
        .descriptor = card.hw.in_streams + which,
        .tag = @intCast(which + 1),
        .buffers = ring,
        .count = buffers,
        .bytes = buffer_bytes,
        .list = @ptrFromInt(ring + ring_bytes),
    };
    instance.ended = 0;
    instance.taken = 0;
    stream_file.describe(&instance.out);
    card.hw.toDevice(ring, ring_bytes);

    if (!state.pb.AddPCIIntServer(card.function, &instance.int)) {
        sdk.exec.kprintf(sys, "%s: the controller's interrupt cannot be hooked\n", .{MODULE_NAME});
        return err.RTAERR_NO_OUTPUT;
    }
    instance.int_added = true;
    const command = state.pb.ReadPCIConfig(card.function, pci.PCI_COMMAND, 2);
    state.pb.WritePCIConfig(card.function, pci.PCI_COMMAND, 2, command & ~@as(u32, pci.PCI_COMMAND_INTX_DISABLE));

    codec_file.routeOn(&card.hw, instance.codec, instance.output);
    codec_file.feed(&card.hw, instance.codec, instance.output, instance.out.tag, shape);
    _ = codec_file.gainTo(&card.hw, instance.codec, instance.output, instance.gain);
    // Running before it is started: an interrupt that arrives between
    // the two has to find a sink that will answer for it, or the line
    // stays raised with nobody to clear it.
    instance.up = true;
    if (!stream_file.up(&instance.out, shape)) {
        instance.up = false;
        sdk.exec.kprintf(sys, "%s: stream %d does not come out of reset\n", .{
            MODULE_NAME, instance.out.descriptor,
        });
        return err.RTAERR_NO_OUTPUT;
    }
    return err.RTAERR_OK;
}

/// Everything the stream took given back: the descriptor stopped, the
/// way out switched off, the interrupt out, the descriptor and the
/// memory freed. Safe to call on a start that failed half way.
fn streamDown(instance: *Instance) void {
    const sys = instance.sys;
    const card = instance.card;
    if (instance.held) stream_file.down(&instance.out);
    if (instance.up) codec_file.routeOff(&card.hw, instance.codec, instance.output);
    instance.up = false;
    if (instance.int_added) instance.state.pb.RemPCIIntServer(card.function, &instance.int);
    instance.int_added = false;
    if (instance.held) giveStream(card, instance.out.descriptor - card.hw.in_streams);
    instance.held = false;
    if (instance.memory) |memory| sys.FreeVec(memory);
    instance.memory = null;
    instance.ring = 0;
    instance.task = null;
}

/// An output stream of the controller claimed, by its number among the
/// outputs. Null where they are all taken.
fn takeStream(card: *Card) ?u32 {
    var which: u32 = 0;
    while (which < card.hw.out_streams) : (which += 1) {
        // A stream's tag is its number and one, and a tag is four bits
        // with zero meaning none, so the fifteenth output stream of a
        // controller that had one could not be told apart on the link.
        if (which >= 15) return null;
        const bit = @as(u32, 1) << @intCast(which);
        if (@atomicRmw(u32, &card.busy, .Or, bit, .acq_rel) & bit == 0) return which;
    }
    return null;
}

fn giveStream(card: *Card, which: u32) void {
    _ = @atomicRmw(u32, &card.busy, .And, ~(@as(u32, 1) << @intCast(which)), .acq_rel);
}

/// The controller's interrupt, which this sink's stream shares with the
/// controller's other streams and with whatever else is on the line: a
/// buffer has been played, so the task has one to fill. What this
/// stream raised is cleared here, which is also the answer to whether
/// the interrupt was this sink's at all.
fn server(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const instance: *Instance = @ptrCast(@alignCast(is_data.?));
    if (!instance.up) return 0;
    const raised = stream_file.served(&instance.out);
    if (raised.played) {
        _ = @atomicRmw(u32, &instance.ended, .Add, 1, .release);
        if (instance.task) |task| instance.sys.Signal(task, instance.signal_mask);
    }
    return @intFromBool(raised.any());
}

/// The buffer the controller finished last, which is the one to fill: it
/// will not be played again until the ring has been round the others.
/// Null if none has ended since the last ask, and more than one counted
/// as a buffer played again.
fn buffer(sink: *rta.AudioSink) callconv(.c) ?[*]i16 {
    const instance = instanceOf(sink);
    if (!instance.up) return null;
    const count = @atomicLoad(u32, &instance.ended, .acquire);
    const behind = count -% instance.taken;
    if (behind == 0) return null;
    if (behind > 1) sink.underruns +%= behind - 1;
    instance.taken = count;
    const which = (count -% 1) % buffers;
    const frames: [*]i16 = @ptrFromInt(instance.ring);
    return frames + which * buffer_samples;
}

/// A filled buffer written back out of the caches, where the controller
/// reads it.
fn play(sink: *rta.AudioSink, frames: [*]i16) callconv(.c) i32 {
    const instance = instanceOf(sink);
    instance.card.hw.toDevice(@intFromPtr(frames), buffer_bytes);
    return err.RTAERR_OK;
}

/// AUDIOCTRL_VOLUME: the gain set at the output's own amplifier, as far
/// as its steps reach, and the answer is the gain the buffers are still
/// to be given. An output whose gain is not the codec's to set says so,
/// and its buffers carry all of it.
fn controlSink(sink: *rta.AudioSink, what: u32, value: isize) callconv(.c) isize {
    if (what != rta.sinks.AUDIOCTRL_VOLUME) return err.RTAERR_NOT_SUPPORTED;
    if (value < 0) return err.RTAERR_BAD_ARG;
    const instance = instanceOf(sink);
    const most: isize = 4 * rta.sinks.AUDIOGAIN_UNITY;
    const gain: u32 = @intCast(@min(value, most));
    const level = codec_file.gainTo(&instance.card.hw, instance.codec, instance.output, gain) orelse {
        return err.RTAERR_NOT_SUPPORTED;
    };
    instance.gain = gain;
    return @intCast(level.rest);
}

/// No library and no vectors: the tag's init is the whole of it.
export const rta_hda_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rta_hda_tag,
    .flags = exec.RTF_COLDSTART,
    .version = VERSION,
    .pri = 31,
    .type = .rta_driver,
    .name = MODULE_NAME,
    .id_string = VERSION_STRING[1..], // past the NUL: a C string
    .init = @ptrCast(@constCast(&init)),
};
