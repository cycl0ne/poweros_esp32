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
const regs = @import("regs.zig");
const controller = @import("controller.zig");
const Controller = controller.Controller;
const codec_file = @import("codec.zig");
const verbs = @import("verbs.zig");

const MODULE_NAME = "rta-hda";
const DRIVER_NAME = "hda";
const VERSION = 1;
const REVISION = 0;
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
};

/// A sink's own instance, which rta.library allocates beside the sink.
/// Empty until there are sinks to make.
const Instance = struct {
    state: *State,
};

const driver_ops: rta.sinks.RtaDriverOps = .{};

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
    // The libraries stay open and the state stays allocated: the
    // controllers are this module's from here on.
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
    if (state.timer_open) {
        sys.CloseDevice(&state.timer_io.node);
        sys.FreeSignal(@intCast(state.timer_port.sig_bit));
        state.timer_open = false;
    }
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

/// A verb that reads a node's parameter, and the parameter that is the
/// vendor and device the codec says it is.
const verb_get_parameter: u20 = 0xf_0000;
const parameter_vendor_id: u20 = verb_get_parameter | 0x00;

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
