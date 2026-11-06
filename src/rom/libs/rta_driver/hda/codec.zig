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
};

/// What one codec turned out to have.
pub const Codec = struct {
    /// Which codec on the link it is.
    address: u4 = 0,
    /// What it says it is.
    vendor: u16 = 0,
    device: u16 = 0,
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
        const converter = converterFor(c, codec, node, search_depth) orelse continue;
        const pcm = convertersPcm(c, codec, converter);
        const converter_amp = ask(c, address, converter, verbs.parameter(verbs.param_out_amp_cap)) orelse 0;
        const pin_amp = ask(c, address, node, verbs.parameter(verbs.param_out_amp_cap)) orelse 0;
        const has_converter_amp = verbs.ampSteps(converter_amp) != 0;
        codec.outputs[codec.output_count] = .{
            .converter = converter,
            .pin = node,
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
/// from. The node itself is the answer where it is a converter, so the
/// search ends on the first one it meets.
fn converterFor(c: *Controller, codec: *Codec, node: u8, depth: u32) ?u8 {
    if (depth == 0) return null;
    const address = codec.address;
    const capability = ask(c, address, node, verbs.parameter(verbs.param_widget_cap)) orelse return null;
    const kind = verbs.widgetKind(capability);
    if (kind == verbs.widget_output) return node;
    if (capability & verbs.widget_conn_list == 0) return null;
    const length = ask(c, address, node, verbs.parameter(verbs.param_connections)) orelse return null;
    const entries = length & verbs.connections_count;
    const long = length & verbs.connections_long != 0;
    var index: u8 = 0;
    while (index < entries) : (index += 1) {
        const from = connection(c, codec, node, index, long) orelse continue;
        if (from == 0) continue;
        if (converterFor(c, codec, from, depth - 1)) |found| return found;
    }
    return null;
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
