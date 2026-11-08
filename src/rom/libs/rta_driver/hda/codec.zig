// SPDX-License-Identifier: MPL-2.0
//! The codec read: what it has, and a way from a stream to each pin that
//! leaves the chip.
//!
//! **A codec describes itself.** Its root node says how many function
//! groups are below it and where they start; a function group says what
//! it is for and what is below it in turn; and each of those widgets says
//! what it is - a converter that turns a stream into samples, a pin that
//! leaves the chip, a mixer or a selector that chooses between inputs -
//! and which other widgets it takes its input from. So this walks what
//! is there instead of knowing a part, and a codec nobody has seen
//! before is read the same as a known one.
//!
//! **A way out is searched for from the pin backwards.** Each pin that
//! can drive something and has something wired to it is taken, and its
//! connections are followed - through mixers and selectors, which are
//! what a codec puts between its converters and its pins - until a
//! converter is reached. That converter and that pin are an output.
//! Searching from the pin rather than from the converter is what makes
//! the answer useful: a pin is a thing on the outside of the machine
//! with a name and a colour, and a converter is an implementation
//! detail of how to feed it.
//!
//! **What a pin is for comes from the pin.** Its configuration default
//! says whether it is a jack or something fixed inside the machine, what
//! kind of thing it is meant for, and what colour it is - so `Line out`,
//! `Headphones`, `Speaker` and `HDMI` are read off the hardware rather
//! than guessed from a codec's name.
//!
//! **The way is kept, so that it can be switched on.** Each step of the
//! search is written down with the input it was reached through, and
//! switching the output on walks that list the other way: a selector is
//! told which of its inputs to take, a mixer has that input's amplifier
//! opened, every node's own amplifier is unmuted and set to the step
//! that neither raises nor lowers, and the pin is told to drive what is
//! wired to it. A codec whose converter happens to sit straight on its
//! pin has an empty list and the same code switches it on.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const controller = @import("controller.zig");
const Controller = controller.Controller;
const verbs = @import("verbs.zig");

/// How deep a search from a pin back to a converter goes. A codec puts a
/// mixer or a selector or two between them; anything deeper than this is
/// a graph with a loop in it, which is a codec that lied.
const search_depth = 8;

/// How many outputs are kept. A codec has a handful of pins that leave
/// the chip - a line out, headphones, a speaker, one or two display
/// links - and this is past all of them.
pub const max_outputs = 8;

/// One node on the way from a pin to a converter, and which of that
/// node's inputs the way goes through.
pub const Step = struct {
    node: u8 = 0,
    from: u8 = 0,
};

/// One way out of the chip: the converter that feeds it, the pin it
/// leaves by, and what that pin is.
pub const Output = struct {
    /// The converter, which the stream is given to.
    converter: u8 = 0,
    /// The pin, which is switched on and whose amplifier is set.
    pin: u8 = 0,
    /// What the pin's configuration default says it is for, and where it
    /// is: a jack on the outside, or something fixed inside.
    device: u4 = 0,
    connectivity: u2 = 0,
    colour: u4 = 0,
    /// Whether the pin is a display link rather than an analog one,
    /// which changes what starting it takes.
    display: bool = false,
    /// Whether the pin has an external amplifier to power.
    eapd: bool = false,
    /// What the converter takes: the rate bits and sample size bits of
    /// `param_pcm`, as the specification lays them out.
    pcm: u32 = 0,
    /// The converter's output amplifier, where it has one of its own:
    /// how many steps and whether it mutes. Zero where the gain is not
    /// the converter's to set.
    amp: u32 = 0,
    /// Where the gain is set, which is the converter where it has an
    /// amplifier of its own and the pin otherwise.
    gain_at: u8 = 0,
    /// The nodes between the pin and the converter, the pin first, each
    /// with the input the way goes through: what switching the output on
    /// has to set.
    path: [search_depth]Step = @splat(.{}),
    path_len: u8 = 0,
};

/// What one codec turned out to have.
pub const Codec = struct {
    /// Which codec on the link it is.
    address: u4 = 0,
    /// What it says it is, and which revision of it.
    vendor: u16 = 0,
    device: u16 = 0,
    revision: u32 = 0,
    /// Its audio function group, which everything below is under. Zero
    /// where it has none, which is a codec with nothing to play through.
    group: u8 = 0,
    outputs: [max_outputs]Output = @splat(.{}),
    output_count: u32 = 0,
};

/// A codec read: its root, its audio function group, and a way out for
/// each pin that has one. False where it has no audio in it at all.
pub fn read(c: *Controller, codec: *Codec, address: u4) bool {
    codec.* = .{ .address = address };
    const id = ask(c, address, 0, verbs.parameter(verbs.param_vendor_id)) orelse {
        trace(c, "codec %d: its root node will not say what it is", .{@as(u32, address)});
        return false;
    };
    codec.vendor = @truncate(id >> 16);
    codec.device = @truncate(id);
    codec.revision = ask(c, address, 0, verbs.parameter(verbs.param_revision)) orelse 0;

    // The root node's children are the function groups; the audio one is
    // what everything below hangs off.
    const groups = ask(c, address, 0, verbs.parameter(verbs.param_node_count)) orelse {
        trace(c, "codec %d: its root node will not say what is below it", .{@as(u32, address)});
        return false;
    };
    const first_group: u8 = @truncate(groups >> 16);
    const group_count: u8 = @truncate(groups);
    trace(c, "codec %d: %d function group(s) from node %d", .{
        @as(u32, address), @as(u32, group_count), @as(u32, first_group),
    });
    var at: u8 = 0;
    while (at < group_count) : (at += 1) {
        const node = first_group + at;
        const kind = ask(c, address, node, verbs.parameter(verbs.param_function_type)) orelse continue;
        trace(c, "codec %d: node %d is a function group of kind %d", .{
            @as(u32, address), @as(u32, node), @as(u32, @as(u8, @truncate(kind))),
        });
        if (@as(u8, @truncate(kind)) != verbs.function_audio) continue;
        codec.group = node;
        break;
    }
    if (codec.group == 0) return false;

    // The group is told to work before anything below it is asked to.
    _ = ask(c, address, codec.group, verbs.powerSet(verbs.power_d0));
    findOutputs(c, codec);
    return true;
}

/// Every pin of the group that can leave the chip, and a converter for
/// it where one can be reached.
fn findOutputs(c: *Controller, codec: *Codec) void {
    const address = codec.address;
    const widgets = ask(c, address, codec.group, verbs.parameter(verbs.param_node_count)) orelse return;
    const first: u8 = @truncate(widgets >> 16);
    const count: u8 = @truncate(widgets);
    trace(c, "codec %d: %d widget(s) from node %d", .{
        @as(u32, address), @as(u32, count), @as(u32, first),
    });
    var at: u8 = 0;
    while (at < count) : (at += 1) {
        if (codec.output_count == max_outputs) return;
        const node = first + at;
        const capability = ask(c, address, node, verbs.parameter(verbs.param_widget_cap)) orelse continue;
        trace(c, "codec %d: node %d is a widget of kind %d", .{
            @as(u32, address), @as(u32, node), @as(u32, verbs.widgetKind(capability)),
        });
        if (verbs.widgetKind(capability) != verbs.widget_pin) continue;
        const pin_cap = ask(c, address, node, verbs.parameter(verbs.param_pin_cap)) orelse continue;
        if (pin_cap & verbs.pin_cap_output == 0) continue;
        const config = ask(c, address, node, verbs.pin_config_default) orelse continue;
        const connectivity = verbs.pinConnectivity(config);
        // A pin with nothing wired to it is not a way out of the machine,
        // whatever it can do.
        if (connectivity == verbs.connectivity_none) continue;
        var path: [search_depth]Step = @splat(.{});
        var path_len: u8 = 0;
        const converter = converterFor(c, codec, node, search_depth, &path, &path_len) orelse continue;
        const pcm = convertersPcm(c, codec, converter);
        const converter_amp = outAmpCap(c, codec, converter);
        const pin_amp = outAmpCap(c, codec, node);
        const has_converter_amp = verbs.ampSteps(converter_amp) != 0;
        codec.outputs[codec.output_count] = .{
            .converter = converter,
            .pin = node,
            .path = path,
            .path_len = path_len,
            .device = verbs.pinDevice(config),
            .connectivity = connectivity,
            .colour = verbs.pinColour(config),
            .display = pin_cap & (verbs.pin_cap_hdmi | verbs.pin_cap_display_port) != 0,
            .eapd = pin_cap & verbs.pin_cap_eapd != 0,
            .pcm = pcm,
            .amp = if (has_converter_amp) converter_amp else pin_amp,
            .gain_at = if (has_converter_amp) converter else node,
        };
        codec.output_count += 1;
    }
}

/// The rates and sizes a converter takes, which it answers for itself
/// where it may and the function group answers for otherwise.
fn convertersPcm(c: *Controller, codec: *Codec, converter: u8) u32 {
    const capability = ask(c, codec.address, converter, verbs.parameter(verbs.param_widget_cap)) orelse 0;
    if (capability & verbs.widget_format_override != 0) {
        const own = ask(c, codec.address, converter, verbs.parameter(verbs.param_pcm)) orelse 0;
        if (own != 0) return own;
    }
    return ask(c, codec.address, codec.group, verbs.parameter(verbs.param_pcm)) orelse 0;
}

/// A converter reachable from `node`, following what it takes its input
/// from, with every node it went through written into `path` and the
/// input it was reached through. The node itself is the answer where it
/// is a converter, so the search ends on the first one it meets and the
/// path holds everything before it.
fn converterFor(c: *Controller, codec: *Codec, node: u8, depth: u32, path: *[search_depth]Step, length: *u8) ?u8 {
    if (depth == 0) return null;
    const address = codec.address;
    const capability = ask(c, address, node, verbs.parameter(verbs.param_widget_cap)) orelse return null;
    const kind = verbs.widgetKind(capability);
    if (kind == verbs.widget_output) return node;
    if (capability & verbs.widget_conn_list == 0) return null;
    const count = ask(c, address, node, verbs.parameter(verbs.param_connections)) orelse return null;
    const entries = count & verbs.connections_count;
    const long = count & verbs.connections_long != 0;
    const here = length.*;
    if (here == search_depth) return null;
    var index: u8 = 0;
    while (index < entries) : (index += 1) {
        const from = connection(c, codec, node, index, long) orelse continue;
        if (from == 0) continue;
        // Written down before the step is taken, and taken back off
        // where it led nowhere, so what comes back is the way that
        // reached a converter and not everywhere the search went.
        path[here] = .{ .node = node, .from = index };
        length.* = here + 1;
        if (converterFor(c, codec, from, depth - 1, path, length)) |found| return found;
    }
    length.* = here;
    return null;
}

/// What a node's output amplifier can do, and what its input amplifiers
/// can. A node says for itself only where it overrides the function
/// group; the rest take the group's answer, which is what applies to
/// them. Zero for a node with no amplifier of that kind at all.
fn outAmpCap(c: *Controller, codec: *Codec, node: u8) u32 {
    const capability = ask(c, codec.address, node, verbs.parameter(verbs.param_widget_cap)) orelse return 0;
    if (capability & verbs.widget_out_amp == 0) return 0;
    if (capability & verbs.widget_amp_override != 0) {
        return ask(c, codec.address, node, verbs.parameter(verbs.param_out_amp_cap)) orelse 0;
    }
    return ask(c, codec.address, codec.group, verbs.parameter(verbs.param_out_amp_cap)) orelse 0;
}

fn inAmpCap(c: *Controller, codec: *Codec, node: u8) u32 {
    const capability = ask(c, codec.address, node, verbs.parameter(verbs.param_widget_cap)) orelse return 0;
    if (capability & verbs.widget_in_amp == 0) return 0;
    if (capability & verbs.widget_amp_override != 0) {
        return ask(c, codec.address, node, verbs.parameter(verbs.param_in_amp_cap)) orelse 0;
    }
    return ask(c, codec.address, codec.group, verbs.parameter(verbs.param_in_amp_cap)) orelse 0;
}

/// Entry `index` of a node's connection list. The answer carries several
/// entries at once - four bytes or two shorts - so the one wanted is
/// picked out of the answer for the group it is in.
fn connection(c: *Controller, codec: *Codec, node: u8, index: u8, long: bool) ?u8 {
    const per_answer: u8 = if (long) 2 else 4;
    const group = (index / per_answer) * per_answer;
    const answer = ask(c, codec.address, node, verbs.connectionList(group)) orelse return null;
    const within = index % per_answer;
    if (long) {
        const entry: u16 = @truncate(answer >> (@as(u5, @intCast(within)) * 16));
        // A long entry's high bit says it is the end of a range, which
        // this does not walk: a range's first entry is taken and the
        // rest left, since a codec puts a range where a pin can take
        // any of a row of inputs and the first will do.
        return @truncate(entry & 0x7fff);
    }
    const entry: u8 = @truncate(answer >> (@as(u5, @intCast(within)) * 8));
    return entry & 0x7f;
}

/// A verb sent and its answer, with the codec's address filled in.
fn ask(c: *Controller, address: u4, node: u8, payload: u20) ?u32 {
    return controller.verb(c, address, node, payload);
}

/// The walk as it goes, for a machine whose codec is not what this
/// expected: which nodes were there and what each said it was. Debug
/// lines, so a kernel built to keep them has the whole graph and every
/// other boot has none of it.
fn trace(c: *Controller, comptime text: [:0]const u8, args: anytype) void {
    sdk.exec.klog(c.sys, exec.LOG_DEBUG, "rta-hda: " ++ text ++ "\n", args);
}

/// What an output is called, from what its pin is for. The name is the
/// thing on the outside of the machine, not the chip behind it.
pub fn nameOf(output: *const Output) [*:0]const u8 {
    if (output.display) return "HDMI";
    return switch (output.device) {
        verbs.device_line_out => if (output.connectivity == verbs.connectivity_fixed) "Speaker" else "Line out",
        verbs.device_speaker => "Speaker",
        verbs.device_headphone => "Headphones",
        verbs.device_spdif_out => "Digital out",
        verbs.device_digital_out => "Digital out",
        else => "Line out",
    };
}

/// Which output a machine should play through before any other, highest
/// first. What a listener expects is the speakers of the machine in
/// front of them, then a jack they have plugged something into, and a
/// display link last - a monitor is often on and silent.
pub fn rankOf(output: *const Output) i8 {
    if (output.display) return 10;
    return switch (output.device) {
        verbs.device_speaker => 40,
        verbs.device_headphone => 35,
        verbs.device_line_out => 30,
        verbs.device_spdif_out, verbs.device_digital_out => 15,
        else => 20,
    };
}

/// The way out switched on: the function group and every node on the way
/// awake, each told which of its inputs the sound comes in on, every
/// amplifier on the way opened, and the pin driving what is wired to it.
///
/// Nothing here is particular to a codec. A pin that is only ever fed by
/// one converter has an empty path and is switched on by the last few
/// lines; one behind a selector and a mixer has both set on the way.
pub fn routeOn(c: *Controller, codec: *Codec, output: *const Output) void {
    const address = codec.address;
    _ = ask(c, address, codec.group, verbs.powerSet(verbs.power_d0));
    _ = ask(c, address, output.converter, verbs.powerSet(verbs.power_d0));
    unmuteOut(c, codec, output.converter);
    // A converter that leaves the chip as a digital stream passes nothing
    // until it is told to, which is asked of the converter itself and of
    // nothing else on the way. An analog one has no such bit and is not
    // asked. Whether it is one is the converter's own answer.
    if (isDigital(c, codec, output.converter)) {
        _ = ask(c, address, output.converter, verbs.digitalSet(verbs.digital_enable));
    }
    for (output.path[0..output.path_len]) |step| {
        _ = ask(c, address, step.node, verbs.powerSet(verbs.power_d0));
        const capability = ask(c, address, step.node, verbs.parameter(verbs.param_widget_cap)) orelse continue;
        const kind = verbs.widgetKind(capability);
        if (kind == verbs.widget_mixer) {
            // A mixer sums what comes in, so there is nothing to choose:
            // the input the sound arrives on is opened and the others are
            // left as they were, which is how a codec keeps the rest of
            // its machine out of this output.
            unmuteIn(c, codec, step.node, step.from);
        } else if (capability & verbs.widget_conn_list != 0) {
            const count = ask(c, address, step.node, verbs.parameter(verbs.param_connections)) orelse 0;
            if (count & verbs.connections_count > 1) {
                _ = ask(c, address, step.node, verbs.connectionSelectSet(step.from));
            }
        }
        if (kind != verbs.widget_pin) unmuteOut(c, codec, step.node);
    }
    unmuteOut(c, codec, output.pin);
    _ = ask(c, address, output.pin, verbs.powerSet(verbs.power_d0));
    var control: u8 = verbs.pin_control_out;
    // A pin meant for headphones drives them from its own amplifier.
    if (output.device == verbs.device_headphone) control |= verbs.pin_control_headphone;
    _ = ask(c, address, output.pin, verbs.pinControlSet(control));
    // An amplifier outside the chip is powered once and left powered
    // while the machine is up: switching it with every start and stop is
    // a click out of the speakers each time.
    if (output.eapd) _ = ask(c, address, output.pin, verbs.eapdSet(verbs.eapd_enable));
}

/// The way out switched off: the pin no longer driving and the converter
/// asleep, so that an output nothing is playing through is silent rather
/// than hissing.
pub fn routeOff(c: *Controller, codec: *Codec, output: *const Output) void {
    const address = codec.address;
    _ = ask(c, address, output.pin, verbs.pinControlSet(0));
    if (isDigital(c, codec, output.converter)) {
        _ = ask(c, address, output.converter, verbs.digitalSet(0));
    }
    _ = ask(c, address, output.converter, verbs.streamChannelSet(0, 0));
    _ = ask(c, address, output.converter, verbs.powerSet(verbs.power_d3));
}

/// The converter told which stream to take its samples from and what
/// shape they are in - the same shape the stream descriptor was given.
pub fn feed(c: *Controller, codec: *Codec, output: *const Output, tag: u4, shape: u16) void {
    _ = ask(c, codec.address, output.converter, verbs.formatSet(shape));
    _ = ask(c, codec.address, output.converter, verbs.streamChannelSet(tag, 0));
}

/// Whether a node leaves the chip as a digital stream, which is what it
/// says of itself.
fn isDigital(c: *Controller, codec: *Codec, node: u8) bool {
    const capability = ask(c, codec.address, node, verbs.parameter(verbs.param_widget_cap)) orelse return false;
    return capability & verbs.widget_digital != 0;
}

/// A node's output amplifier opened: unmuted, and set to the step that
/// neither raises nor lowers what goes through it.
fn unmuteOut(c: *Controller, codec: *Codec, node: u8) void {
    const amp = outAmpCap(c, codec, node);
    if (amp == 0) return;
    const gain: u7 = @truncate(verbs.ampOffset(amp));
    _ = ask(c, codec.address, node, verbs.ampSet(true, false, true, true, 0, false, gain));
}

/// One input amplifier of a node opened, the same way.
fn unmuteIn(c: *Controller, codec: *Codec, node: u8, index: u8) void {
    const amp = inAmpCap(c, codec, node);
    if (amp == 0) return;
    const gain: u7 = @truncate(verbs.ampOffset(amp));
    _ = ask(c, codec.address, node, verbs.ampSet(false, true, true, true, index, false, gain));
}

/// The ratio between two steps of an amplifier a quarter of a decibel
/// apart: 10^(0.25/20), with 32 bits of fraction. A step's own ratio is
/// this multiplied by itself as many times as the step is quarters of a
/// decibel, which is how the gain of a step is worked out without a
/// logarithm.
///
/// The wide fraction is what makes it exact enough to count on. A gain
/// is only 16.16, but the steps are walked one at a time and each walk
/// drops what will not fit: in 16.16 a step near the bottom of a 74 dB
/// range loses several percent of itself every time, and seventy of them
/// come out four times out.
const quarter_db: u64 = 0x1_0779_af8d;

/// A gain of 1, as the steps are counted in: 32 bits of fraction.
const unity: u64 = 1 << 32;

/// A gain of 1 as the library hands one over: 16.16.
const unity_16: u32 = 0x1_0000;

/// What setting an amplifier to a gain came to.
pub const Level = struct {
    /// The step it was set to.
    step: u7 = 0,
    /// Whether it was muted instead, for no gain at all.
    silent: bool = false,
    /// The gain the buffers are still to be given: 16.16, 0x10000 where
    /// the amplifier took all of it.
    rest: u32 = unity_16,
};

/// The output's amplifier set to `gain` - 16.16, 0x10000 as played - and
/// what is left for the buffers to carry. Null for an output whose gain
/// is not the codec's to set, whose buffers carry all of it.
pub fn gainTo(c: *Controller, codec: *Codec, output: *const Output, gain: u32) ?Level {
    const amp = outAmpCap(c, codec, output.gain_at);
    const level = stepFor(amp, gain) orelse return null;
    _ = ask(c, codec.address, output.gain_at, verbs.ampSet(
        true,
        false,
        true,
        true,
        0,
        level.silent,
        if (level.silent) 0 else level.step,
    ));
    return level;
}

/// Which step of an amplifier of `amp`'s shape plays `gain`, and what is
/// left over. Null for an amplifier with no steps, which is one there is
/// no gain to set on.
///
/// The step chosen is the lowest one that is at or above the gain asked
/// for, so what is left over is always an attenuation: the amplifier
/// takes as much of the gain as its steps reach and the buffers make up
/// the fraction between two steps, which they can do exactly and without
/// ever amplifying a sample into clipping. A gain past the top of the
/// amplifier's range is the one case where more is left over than there
/// was to start with, and then the buffers really are being asked to be
/// louder than the part can be.
pub fn stepFor(amp: u32, gain: u32) ?Level {
    const steps = verbs.ampSteps(amp);
    if (steps == 0) return null;
    if (gain == 0 and amp & verbs.amp_can_mute != 0) return .{ .step = 0, .silent = true, .rest = 0 };
    // The ratio of one step, as many quarters of a decibel as the
    // amplifier says a step is.
    var ratio: u64 = unity;
    var quarters: u32 = 0;
    while (quarters <= verbs.ampStepSize(amp)) : (quarters += 1) {
        ratio = @intCast((@as(u128, ratio) * quarter_db) >> 32);
    }
    // Walked from the step that neither raises nor lowers, which is
    // where a gain of one is and where the walk is exact, rather than
    // from the bottom of the range.
    const want = @as(u64, gain) << 16;
    var step: u32 = verbs.ampOffset(amp);
    var at: u64 = unity;
    if (want > unity) {
        while (step < steps and at < want) : (step += 1) {
            at = @intCast((@as(u128, at) * ratio) >> 32);
        }
    } else {
        // Down while the step below is still at or above the gain asked
        // for, so what is left over is an attenuation.
        while (step > 0) {
            const below: u64 = @intCast((@as(u128, at) << 32) / ratio);
            if (below < want) break;
            at = below;
            step -= 1;
        }
    }
    if (at == 0) at = 1;
    const rest = (@as(u128, want) << 16) / at;
    return .{
        .step = @truncate(step),
        .silent = false,
        .rest = @intCast(@min(rest, 4 * unity_16)),
    };
}

/// What an amplifier of 74 steps of a decibel, with no change at the top
/// of them, is: what the emulator's codec says, and the shape of a great
/// many real ones.
const an_amp: u32 = 0x8003_4a4a;

test "as played is the step the amplifier calls no change" {
    const level = stepFor(an_amp, 0x1_0000).?;
    try std.testing.expectEqual(@as(u7, 74), level.step);
    try std.testing.expectEqual(@as(u32, 0x1_0000), level.rest);
    try std.testing.expect(!level.silent);
}

test "an amplifier takes a gain to within one of its steps" {
    // Every gain from as played down to a thousandth of it, which is
    // well inside an amplifier of this range.
    var gain: u32 = 0x1_0000;
    while (gain > 0x40) : (gain = gain * 9 / 10) {
        const level = stepFor(an_amp, gain).?;
        // Never more than was asked for, so the buffers never amplify.
        try std.testing.expect(level.rest <= 0x1_0000);
        // And never more than one step of a decibel short of it, which
        // is a ratio of 1.122.
        try std.testing.expect(level.rest > 0x1_0000 * 100 / 113);
        try std.testing.expect(level.step <= 74);
    }
}

test "a louder step is a higher one" {
    var gain: u32 = 0x100;
    var last = stepFor(an_amp, gain).?.step;
    while (gain < 0x1_0000) : (gain = gain * 11 / 10) {
        const step = stepFor(an_amp, gain).?.step;
        try std.testing.expect(step >= last);
        last = step;
    }
}

test "more than the amplifier gives is left for the buffers" {
    // Its top step is the one that neither raises nor lowers, so being
    // asked for four times as played leaves all of it to the mix.
    const level = stepFor(an_amp, 4 * 0x1_0000).?;
    try std.testing.expectEqual(@as(u7, 74), level.step);
    try std.testing.expectEqual(@as(u32, 4 * 0x1_0000), level.rest);
}

test "an amplifier that can raise takes a gain above as played" {
    // 79 steps of a quarter of a decibel with no change at step 32, so
    // it reaches 11.75 dB above as played. Twice as played is 6.02 dB,
    // which is past 24 steps and inside 25.
    const raises: u32 = 0x8000_4f20;
    const level = stepFor(raises, 2 * 0x1_0000).?;
    try std.testing.expectEqual(@as(u7, 32 + 25), level.step);
    try std.testing.expect(level.rest <= 0x1_0000);
    try std.testing.expect(level.rest > 0x1_0000 * 100 / 103);
}

test "nothing at all is a muted amplifier" {
    const level = stepFor(an_amp, 0).?;
    try std.testing.expect(level.silent);
    try std.testing.expectEqual(@as(u32, 0), level.rest);
}

test "an amplifier with no steps has no gain to set" {
    try std.testing.expectEqual(@as(?Level, null), stepFor(0, 0x1_0000));
    try std.testing.expectEqual(@as(?Level, null), stepFor(0x8000_0000, 0x1_0000));
}
