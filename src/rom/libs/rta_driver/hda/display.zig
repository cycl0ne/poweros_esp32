// SPDX-License-Identifier: MPL-2.0
//! A display link as an output: what is at the far end of it, and the
//! three things a link wants told that an analog pin does not.
//!
//! **A link carries the sound inside the picture.** The samples go out
//! in packets between the lines of video, and what reads them at the far
//! end is told what they are in a packet of its own - the audio
//! infoframe - rather than working it out from the samples. So a stream
//! on a display pin is not playing until three more things have been
//! said: how many channels the converter is sending, which channel goes
//! in which of the link's slots, and the infoframe, which is written a
//! byte at a time into the pin's packet buffer and then switched on.
//!
//! **One vendor's codec is told the same through verbs of its own.** The
//! codec in front of that vendor's display engine has no packet buffer
//! and no standard slot verb: the engine builds the infoframe itself out
//! of the shape of the samples and what the codec was told, and the
//! codec is told which channel each slot carries - with each slot
//! switched on, since a slot that is not carries nothing - and which
//! speakers the packet names, through verbs only it has. Which codec it
//! is comes from its vendor; whether it takes the slots one at a time or
//! in pairs, from its device and revision.
//!
//! **The far end describes itself**, in the data the display driver's
//! link left in the pin: its name, how many channels it takes and at
//! which rates, as a baseline block of the kind a monitor's capability
//! data holds. It is read for two reasons - to say in the log which
//! monitor the sound is going to, and to refuse a rate the far end has
//! said it does not take - and a link that describes nothing is played
//! through all the same, since a monitor that answers nothing is still a
//! monitor.
//!
//! **A pin with nothing plugged into it is not played through.** A
//! machine has a display socket for every link its chip has, and most of
//! them have nothing in them; a sink that would play into one of those
//! says there is no output, so that the machine moves on to the next
//! output rather than playing into a socket. Nor is it listed: the
//! driver looks at every link every few seconds (`present`), and a link
//! has a sink only while something is at its far end.

const sdk = @import("sdk");
const exec = sdk.exec;
const controller = @import("controller.zig");
const Controller = controller.Controller;
const codec_file = @import("codec.zig");
const verbs = @import("verbs.zig");

/// The bytes of the far end's description that are read. A baseline
/// block is a header, a name of up to 31 bytes and a few descriptors of
/// three bytes each; this is past all of it.
const max_eld = 128;

/// The bytes of a monitor's name that are kept.
pub const max_name = 32;

/// What is at the far end of a link.
pub const Far = struct {
    /// Something is plugged in.
    present: bool = false,
    /// It described itself, and the rest of this is from that
    /// description.
    described: bool = false,
    /// The most channels it takes.
    channels: u8 = 0,
    /// Which rates it takes, as `verbs.pcm_rate_*`.
    rates: u32 = 0,
    /// What it calls itself, with a NUL.
    name: [max_name]u8 = @splat(0),
};

/// What the pin says is at the far end: whether anything is, and what it
/// described itself as.
pub fn look(c: *Controller, codec: *codec_file.Codec, output: *const codec_file.Output) Far {
    const address = codec.address;
    // Awake before it is asked: a pin that is asleep answers what it saw
    // when it last was awake, which for a pin that has been asleep since
    // the machine started is nothing at all.
    _ = ask(c, address, codec.group, verbs.powerSet(verbs.power_d0));
    _ = ask(c, address, output.pin, verbs.powerSet(verbs.power_d0));
    const capability = ask(c, address, output.pin, verbs.parameter(verbs.param_pin_cap)) orelse 0;
    // A pin that asks to be triggered answers what it last saw until it
    // is told to look again.
    if (capability & verbs.pin_cap_trigger != 0) {
        _ = ask(c, address, output.pin, verbs.pin_sense_trigger);
    }
    const sense = ask(c, address, output.pin, verbs.pin_sense_get) orelse return .{};
    sdk.exec.klog(c.sys, exec.LOG_DEBUG, "rta-hda: pin %d: what it can do %x, what it sees %x\n", .{
        @as(u32, output.pin), capability, sense,
    });
    var far: Far = .{ .present = sense & verbs.pin_sense_present != 0 };
    if (sense & verbs.pin_sense_described == 0) return far;
    describe(c, codec, output, &far);
    return far;
}

/// Whether anything is at the far end of the link, asked as `look` asks
/// but without a line in the log and without its description read: what
/// the look at the display links (`hda.watch`) asks every few seconds.
pub fn present(c: *Controller, codec: *codec_file.Codec, output: *const codec_file.Output) bool {
    const address = codec.address;
    _ = ask(c, address, codec.group, verbs.powerSet(verbs.power_d0));
    _ = ask(c, address, output.pin, verbs.powerSet(verbs.power_d0));
    const capability = ask(c, address, output.pin, verbs.parameter(verbs.param_pin_cap)) orelse 0;
    if (capability & verbs.pin_cap_trigger != 0) {
        _ = ask(c, address, output.pin, verbs.pin_sense_trigger);
    }
    const sense = ask(c, address, output.pin, verbs.pin_sense_get) orelse return false;
    return sense & verbs.pin_sense_present != 0;
}

/// The far end's own description read out of the pin and taken apart: a
/// name, and a descriptor per kind of sound it takes.
fn describe(c: *Controller, codec: *codec_file.Codec, output: *const codec_file.Output, far: *Far) void {
    const address = codec.address;
    const answer = ask(c, address, output.pin, verbs.eld_size) orelse return;
    const length = @min(@as(usize, answer & 0xff), max_eld);
    sdk.exec.klog(c.sys, exec.LOG_DEBUG, "rta-hda: pin %d: %d byte(s) of description\n", .{
        @as(u32, output.pin), @as(u32, @intCast(length)),
    });
    // A block shorter than its own header has nothing in it to read.
    if (length < 20) return;
    var raw: [max_eld]u8 = @splat(0);
    var at: usize = 0;
    while (at < length) : (at += 1) {
        const byte = ask(c, address, output.pin, verbs.eldByte(@intCast(at))) orelse return;
        if (byte & verbs.eld_byte_valid == 0) return;
        raw[at] = @truncate(byte & verbs.eld_byte_data);
    }
    const name_length: usize = raw[4] & 0x1f;
    const descriptors: usize = raw[5] >> 4;
    if (20 + name_length + descriptors * 3 > length) return;
    far.described = true;
    var which: usize = 0;
    while (which < name_length and which < max_name - 1) : (which += 1) {
        const byte = raw[20 + which];
        // A name is written out as it is, with anything unprintable left
        // out rather than sent to a console as a control character.
        far.name[which] = if (byte >= ' ' and byte < 0x7f) byte else ' ';
    }
    far.name[which] = 0;
    which = 0;
    while (which < descriptors) : (which += 1) {
        const descriptor = raw[20 + name_length + which * 3 ..][0..3];
        // Only the uncompressed kind is of any use here: the others are
        // a format this does not make.
        if ((descriptor[0] >> 3) & 0xf != sound_lpcm) continue;
        const channels: u8 = (descriptor[0] & 0x07) + 1;
        if (channels > far.channels) far.channels = channels;
        far.rates |= ratesOf(descriptor[1]);
    }
}

/// What a descriptor calls uncompressed sound.
const sound_lpcm: u8 = 1;

/// The rates a descriptor's bits stand for, as the codec's own rate
/// bits, so that the two can be held against each other.
fn ratesOf(bits: u8) u32 {
    var rates: u32 = 0;
    if (bits & (1 << 0) != 0) rates |= verbs.pcm_rate_32000;
    if (bits & (1 << 1) != 0) rates |= verbs.pcm_rate_44100;
    if (bits & (1 << 2) != 0) rates |= verbs.pcm_rate_48000;
    if (bits & (1 << 3) != 0) rates |= verbs.pcm_rate_88200;
    if (bits & (1 << 4) != 0) rates |= verbs.pcm_rate_96000;
    if (bits & (1 << 5) != 0) rates |= verbs.pcm_rate_176400;
    if (bits & (1 << 6) != 0) rates |= verbs.pcm_rate_192000;
    return rates;
}

/// The link told what is coming: how many channels, which of them goes
/// in which slot, and the infoframe that says the same thing to whatever
/// reads the link at the far end.
pub fn prepare(c: *Controller, codec: *codec_file.Codec, output: *const codec_file.Output, channels: u8) void {
    const address = codec.address;
    _ = ask(c, address, output.converter, verbs.channelCountSet(channels));
    if (codec.vendor == verbs.vendor_amd) {
        prepareAmd(c, codec, output, channels);
        return;
    }
    // Channel n in slot n, which is what the infoframe's allocation of
    // nothing says as well: a link of two channels is the left in the
    // first slot and the right in the second.
    var slot: u4 = 0;
    while (slot < channels and slot < 8) : (slot += 1) {
        _ = ask(c, address, output.pin, verbs.channelSlotSet(slot, slot));
    }
    infoframe(c, codec, output, channels);
}

/// The audio infoframe written into the pin's packet buffer and switched
/// on, the way the specification lays the packet out: a header of three
/// bytes, a checksum, and ten of data. The whole buffer is written, so
/// that nothing of a packet sent before is left in the bytes this one
/// does not use.
///
/// The two fields that say what the samples are - how often and how wide
/// - are left at "as the stream says", which is what a link reads out of
/// the stream itself; the count of channels is not among those, which is
/// why it is here. The allocation of channels to speakers is zero: the
/// first channel left, the second right.
fn infoframe(c: *Controller, codec: *codec_file.Codec, output: *const codec_file.Output, channels: u8) void {
    const address = codec.address;
    var packet: [14]u8 = @splat(0);
    packet[0] = packet_audio;
    packet[1] = packet_version;
    packet[2] = packet_length;
    // The count of channels, with the coding type left at zero: the
    // stream says what kind of sound it is.
    packet[4] = channels - 1;
    var sum: u32 = 0;
    for (packet) |byte| sum += byte;
    packet[3] = @truncate(0x100 - (sum & 0xff));
    // Switched off while it is written, so that nothing half of this
    // packet and half of the one before goes out on the link.
    _ = ask(c, address, output.pin, verbs.dipTransmitSet(0));
    _ = ask(c, address, output.pin, verbs.dipIndexSet(0));
    for (packet) |byte| _ = ask(c, address, output.pin, verbs.dipDataSet(byte));
    _ = ask(c, address, output.pin, verbs.dipTransmitSet(verbs.dip_transmit_best));
}

/// The same told to the codec that takes it through verbs of its own:
/// channel n in slot n with every slot that carries a channel switched on
/// and the rest switched off, the allocation of nothing - the first
/// channel left, the second right - and nothing said against mixing
/// down. The packet that says so at the far end is the engine's to build.
///
/// A codec that takes the slots one at a time is put in that mode first
/// and has its converter's ramp set; one that takes them in pairs has a
/// verb for every other slot, the pair's first channel naming both.
fn prepareAmd(c: *Controller, codec: *codec_file.Codec, output: *const codec_file.Output, channels: u8) void {
    const address = codec.address;
    const single = codec.device == verbs.amd_single_device and
        codec.revision & verbs.amd_revision_mask >= verbs.amd_single_revision;
    _ = ask(c, address, output.pin, verbs.amdDownmixSet(0));
    var slot: u4 = 0;
    if (single) {
        _ = ask(c, address, output.pin, verbs.amdModeSet(verbs.amd_mode_single));
        while (slot < 8) : (slot += 1) {
            const at: u3 = @intCast(slot);
            _ = ask(c, address, output.pin, if (slot < channels) verbs.amdSlotSet(at, slot) else verbs.amdSlotOff(at));
        }
        _ = ask(c, address, output.converter, verbs.amdRampSet(verbs.amd_ramp_sound));
    } else {
        while (slot < 8) : (slot += 2) {
            const at: u3 = @intCast(slot);
            _ = ask(c, address, output.pin, if (slot < channels) verbs.amdSlotSet(at, slot) else verbs.amdSlotOff(at));
        }
    }
    _ = ask(c, address, output.pin, verbs.amdSpeakersSet(0));
    tellAmd(c, codec, output, single);
}

/// What the codec answers for the slots it was just told about, read
/// back. Debug: it is read every time a stream starts on a link.
fn tellAmd(c: *Controller, codec: *codec_file.Codec, output: *const codec_file.Output, single: bool) void {
    const address = codec.address;
    sdk.exec.klog(c.sys, exec.LOG_DEBUG, "rta-hda: pin %d: slots %s (mode %x), the first two %x and %x, speakers %x; converter %d ramps at %x; revision %x\n", .{
        @as(u32, output.pin),
        @as([*:0]const u8, if (single) "one at a time" else "in pairs"),
        ask(c, address, output.pin, verbs.amd_mode_get) orelse 0,
        ask(c, address, output.pin, verbs.amdSlotGet(0)) orelse 0,
        ask(c, address, output.pin, verbs.amdSlotGet(1)) orelse 0,
        ask(c, address, output.pin, verbs.amd_speakers_get) orelse 0,
        @as(u32, output.converter),
        ask(c, address, output.converter, verbs.amd_ramp_get) orelse 0,
        codec.revision,
    });
}

/// The packet's header: which packet it is, the version of it this
/// writes, and how many bytes of data follow the checksum.
const packet_audio: u8 = 0x84;
const packet_version: u8 = 0x01;
const packet_length: u8 = 0x0a;

fn ask(c: *Controller, address: u4, node: u8, payload: u20) ?u32 {
    return controller.verb(c, address, node, payload);
}
