// SPDX-License-Identifier: MPL-2.0
//! The sound an AMD display's link carries, and what the engine says of
//! it: the half of a display's sound that is the display engine's.
//!
//! A link that carries a picture can carry sound with it, and the
//! firmware that lit the picture leaves that switched off. The sound
//! itself is the machine's audio driver's - a codec on the high
//! definition audio bus, whose converters feed the engine's endpoints -
//! but which endpoint a link carries, the clock the samples are counted
//! out by, the numbers the monitor rebuilds that clock from and the
//! packets the samples go in are registers of the display engine
//! (`dcn.zig`). `soundUp` sets them for the link the firmware lit each
//! time the board is put in a mode - the mode's pixel clock, what the
//! monitor plays - and `soundDown` has the link carry none; the audio
//! driver has its sinks already and asks the codec what is at the far
//! end of a link when a sink is started.
//!
//! `tellAudio` reads the same registers back and says them on the log,
//! with the engine's own lines (`dcn.tell`): what this writes is read on
//! a machine whose state after its firmware is not known beforehand.
//!
//! The registers are named as the engine's headers name them.
//!
//! ## What the endpoints answer
//!
//! A display link carries sound as packets between the pictures, and the
//! codec that the machine's audio controller talks to does not hold the
//! answers about that link: the display engine does. Every pin of that
//! codec is backed by an endpoint here, and what the pin answers when it
//! is asked whether anything is plugged into it, what the monitor is
//! called and which rates it takes is what the engine was told to answer
//! - by the driver that lit the link, after it read the monitor. A
//! firmware that only lit the link tells it nothing, so the pin answers
//! that there is nothing there, and the audio driver believes it, which
//! is right: a link whose audio packets are not being sent is not an
//! output, whatever is plugged into it.
//!
//! So those registers are read here, along with what each link's packet
//! part is doing and where the sample clock comes from - and then
//! written: the endpoint is told what the far end has and allowed to
//! answer, the link's packet part is told whose samples to carry, its
//! store for them is switched on and the description of the sound is
//! sent, and the clock the samples are counted out by is set from the
//! mode's pixel clock. What the endpoint is told is the monitor's own
//! description of its sound, as rtg.library read it from the EDID - its
//! uncompressed sound's channels, rates and sizes, its speakers, its
//! maker, product and name - with the rates the mode's blanking has no
//! room for left out; only uncompressed sound is described, the only
//! kind the audio driver makes. What is left is the audio driver's: the
//! codec's converter and slots, which it reaches through verbs like any
//! other codec's.

const sdk = @import("sdk");
const dcn = @import("dcn.zig");
const exec = sdk.exec;
const reg = sdk.hardware.mmio.reg;
const rtg = sdk.rtg;

/// An audio endpoint's window: the register that latches which of the
/// endpoint's own registers is wanted, and the one that reads it. One
/// pair per endpoint, a fixed distance apart, and more endpoints than a
/// part has links.
const endpoint_index = 0x0386;

const endpoint_data = 0x0387;

const endpoint_stride = 6;

const endpoints = 8;

/// The endpoint's own registers, by the number latched in its index: what
/// kind of socket the pin is to answer that it is, what it answers when
/// asked what is plugged into it, whether it answers at all, how the
/// channels sit, the first of the descriptions of a kind of sound the
/// monitor takes - one for each kind, uncompressed sound's first - and
/// who the monitor is: its maker and product, the length of its name and
/// the name itself, four letters a register.
const pin_default = 0x0056;

const pin_sense = 0x0023;

const pin_hotplug = 0x0054;

const pin_speaker = 0x0025;

const pin_descriptor = 0x0028;

const pin_sink = 0x003a;

const pin_sink_name_length = 0x003b;

const pin_sink_name = 0x003e;

/// How many kinds of sound the endpoint describes, and the two of them
/// it has no description for - one-bit audio and DST, the ninth and the
/// thirteenth - whose places are not written.
const descriptions = 14;

const description_one_bit = 8;

const description_dst = 12;

/// The most letters of a name the endpoint holds.
const name_most = 18;

/// A link: the front that takes a pipe's pixels and the back that drives
/// the wire, what the link is driven as where it is driven as this kind
/// of link, and - where it is driven as the other kind - whether a
/// picture is going out on it and whether it carries sound.
const dig_front = 0x208b;

const dig_back = 0x20b1;

const hdmi_control = 0x2094;

const hdmi_audio = 0x2096;

const hdmi_clock = 0x2097;

const port_config = 0x210b;

const port_picture = 0x210c;

const port_sound = 0x212b;

/// The part of a link that puts packets between the pictures: whether
/// samples are being sent, which of the controller's streams they are
/// taken from, and what the link is told about the sound it carries.
const afmt_audio = 0x2082;

const afmt_infoframe = 0x2083;

const afmt_source = 0x2085;

/// One of each per link, a fixed distance apart, and more links than a
/// part has sockets.
const link_stride = 0x100;

const links = 6;

/// The clock the samples are counted out by: which pipe's clock it is
/// taken from, and the two halves of the ratio it is divided by. These
/// are counted from the engine's other block, not the one the pipes are
/// in.
const audio_dto_source = 0x00ab;

const audio_dto_phase = 0x00ac;

const audio_dto_module = 0x00ad;

/// The rest of a link's packet part: how the channels are laid out and
/// how many are on, what each side's channel is called in the status that
/// goes out with the samples, whether the part's own clock is running,
/// and the numbers by which the far end rebuilds the sample clock from
/// the pixel clock - a pair for each rate that can be sent.
const afmt_layout = 0x2075;

const afmt_status_left = 0x2078;

const afmt_status_right = 0x2079;

const afmt_clock = 0x20b0;

const acr_32_cycle = 0x20a8;

const acr_32_samples = 0x20a9;

const acr_44_cycle = 0x20aa;

const acr_44_samples = 0x20ab;

const acr_48_cycle = 0x20ac;

const acr_48_samples = 0x20ad;

/// What a link of this kind sends between the pictures besides the
/// samples: which of the packets that fill the blanking go out, which
/// descriptions go out and on which line of the blanking, and what the
/// general control packet says.
const hdmi_general_packet = 0x2098;

const hdmi_sending = 0x2099;

const hdmi_sending_line = 0x209a;

const hdmi_general = 0x209e;

/// The store a link's packet part keeps the samples in on their way into
/// the packets. A firmware that lit the link for a picture can leave it
/// forced into its low-power state, in which no sample passes through it,
/// so it is switched on - the low-power state not allowed and none
/// forced - before the rest of the link's sound is set.
const afmt_memory = 0x2087;

const memory_low_power_off: u32 = 1 << 0;

const memory_force_shift = 4;

const memory_force_mask: u32 = 0x3;

/// What the rest of the channels are called in the status that goes with
/// the samples, a nibble each from the third channel on.
const afmt_status_rest = 0x207f;

const status_rest_mask: u32 = 0xffffff;

const status_rest_channels: u32 = 3 | 4 << 4 | 5 << 8 | 6 << 12 | 7 << 16 | 8 << 20;

/// In a link's front: which pipe's pixels it takes, and that its clock is
/// running, which is what tells the link the firmware lit from the rest.
const front_pipe_shift = 0;

const front_pipe_mask: u32 = 0x7;

const front_running: u32 = 1 << 24;

/// In an endpoint's socket: what it is connected to. Zero there is a
/// socket on the machine's outside; anything else is an endpoint no
/// socket is wired to.
const socket_wired_shift = 30;

const socket_wired_mask: u32 = 0x3;

/// In an endpoint's answering: that it may answer at all, and that its
/// registers are not to be clock-gated while they are written, which is
/// how they are reached and then let go of again.
const answering_on: u32 = 1 << 31;

const answering_awake: u32 = 1 << 0;

/// In an endpoint's channels: which speakers the far end has, as the
/// speaker allocation block names them; how loud the low frequencies
/// play, which is not said; which kind of link it is on; and the first
/// bit of what more is said of the connection, which is nothing.
const speakers_mask: u32 = 0x7f;

const speakers_lfe_level: u32 = 0x3 << 24;

const speakers_wire: u32 = 1 << 16;

const speakers_port: u32 = 1 << 17;

const speakers_extra: u32 = 1 << 18;

/// In an endpoint's description of uncompressed sound: the channels less
/// one, the rates, the sizes of a sample, and the rates again for two
/// channels, each as the monitor's audio block holds them.
const description_rates_shift = 8;

const description_sizes_shift = 16;

const description_stereo_shift = 24;

/// In a link's audio: that samples are being sent, and that the status
/// that goes with them is to be taken up.
const samples_sending: u32 = 1 << 0;

const samples_status_again: u32 = 1 << 26;

/// In what the link is told about the sound: that the description of it
/// is to be taken up again.
const description_again: u32 = 1 << 7;

/// In a link's layout: that neither the layout nor the oversampling is
/// being overridden, and which channels are on - the first two.
const layout_override: u32 = 1 << 0;

const layout_oversampling: u32 = 1 << 28;

const layout_channels_shift = 8;

const layout_channels_mask: u32 = 0xff;

/// In the status that goes with the samples: what each side's channel is
/// called, and how accurate the clock is said to be.
const status_channel_shift = 20;

const status_channel_mask: u32 = 0xf;

const status_accuracy_shift = 28;

const status_accuracy_mask: u32 = 0x3;

/// In a link's own clock: that it is to run.
const link_clock_on: u32 = 1 << 0;

/// In what a link sends between the pictures: that the description of the
/// sound is among it, that it goes out with every frame rather than once -
/// which is also what has a later change to it sent at all - and which
/// line of the blanking it goes on, the second, which is where there is
/// room for it. The description itself is the codec's, which is what the
/// engine takes it from unless it is told to take it from registers of
/// its own, and it is not told to.
const sending_sound_description: u32 = 1 << 4;

const sending_sound_description_always: u32 = 1 << 5;

const sending_line_shift = 8;

const sending_line_mask: u32 = 0x3f;

const sending_line = 2;

/// In a link's control of this kind: that it adds no empty packets of its
/// own beyond the ones it is asked for, which is how the engine is set
/// wherever a link carries sound.
const control_no_extra_empty: u32 = 1 << 3;

/// In the general control the link carries: that the far end is to mute.
/// Cleared, since the point of all of this is that it does not.
const general_mute: u32 = 1 << 0;

/// In the general control packet: that it is sent, that it keeps being
/// sent, and that the gaps between packets are filled with empty ones -
/// which is what makes the blanking of this kind of link a place packets
/// can live at all.
const packet_empty: u32 = 1 << 0;

const packet_general: u32 = 1 << 4;

const packet_general_always: u32 = 1 << 5;

/// In a link's back end: which kind of link it is driving. A wire of this
/// shape carries either kind, and the two differ in exactly what this is
/// about - the one has blanking with nothing in it, the other has packets
/// there, which is where sound goes. A firmware that only wants a picture
/// has no reason to choose the second, and leaves the first; such a link
/// is left as the firmware drove it, and carries no sound.
const back_kind_shift = 16;

const back_kind_mask: u32 = 0x7;

const back_kind_with_packets = 3;

/// In what tells the far end how to rebuild the sample clock: that the
/// numbers are sent by themselves, that the engine works out the cycle
/// rather than taking what is written here, and that they do not come
/// before the picture.
const acr_sending: u32 = 1 << 12;

const acr_from_what_is_written: u32 = 1 << 8;

const acr_before_the_picture: u32 = 1 << 31;

const acr_cycle_shift = 12;

const acr_cycle_mask: u32 = 0xfffff;

const acr_samples_shift = 0;

const acr_samples_mask: u32 = 0xfffff;

/// In the sample clock: which pipe it follows and which of the two is in
/// use, and what it is divided down to - 24 MHz, in the hundreds of hertz
/// both halves of the ratio are counted in.
const dto_pipe_shift = 0;

const dto_pipe_mask: u32 = 0xf;

const dto_which_shift = 4;

const dto_which_mask: u32 = 0x7;

const dto_phase_hundreds = 240_000;

const hertz_in_a_hundred = 100;

/// Which endpoint's samples a link takes.
const link_from_shift = 0;

const link_from_mask: u32 = 0x7;

/// What the engine's audio side is holding. Read only: every line is what
/// the engine answers, and the machine it is read on is not the author's,
/// so the numbers themselves are the finding.
///
/// An endpoint whose kind is zero is one no pin of the codec is backed
/// by, and is passed over. A link whose registers are all zero is one
/// that is not driven, and is passed over as well, so that what is said
/// is the one link the firmware lit and the endpoint it answers from.
pub fn tellAudio(engine: dcn.Engine) void {
    var which: u32 = 0;
    while (which < endpoints) : (which += 1) {
        const kind = readEndpoint(engine, which, pin_default);
        if (kind == 0) continue;
        exec.kprintf(engine.sys, "%s:   endpoint %d: socket %x, sees %x, answers %x, channels %x, first rate %x, name %x\n", .{
            dcn.owner,
            which,
            kind,
            readEndpoint(engine, which, pin_sense),
            readEndpoint(engine, which, pin_hotplug),
            readEndpoint(engine, which, pin_speaker),
            readEndpoint(engine, which, pin_descriptor),
            readEndpoint(engine, which, pin_sink),
        });
    }
    which = 0;
    while (which < links) : (which += 1) {
        exec.kprintf(engine.sys, "%s:   link %d: front %x, back %x, as a wire %x, a picture %x of %x\n", .{
            dcn.owner,
            which,
            readLink(engine, which, dig_front),
            readLink(engine, which, dig_back),
            readLink(engine, which, hdmi_control),
            readLink(engine, which, port_picture),
            readLink(engine, which, port_config),
        });
        exec.kprintf(engine.sys, "%s:   link %d sound: samples %x, from stream %x, told %x, packets %x, counted %x, on the other kind %x\n", .{
            dcn.owner,
            which,
            readLink(engine, which, afmt_audio),
            readLink(engine, which, afmt_source),
            readLink(engine, which, afmt_infoframe),
            readLink(engine, which, hdmi_audio),
            readLink(engine, which, hdmi_clock),
            readLink(engine, which, port_sound),
        });
    }
    exec.kprintf(engine.sys, "%s:   the sample clock is %x of %x, taken from %x\n", .{
        dcn.owner,
        readClock(engine, audio_dto_phase),
        readClock(engine, audio_dto_module),
        readClock(engine, audio_dto_source),
    });
}

/// A register of the engine, by its number in 32-bit words from the block
/// the table named.
fn readRegister(engine: dcn.Engine, offset: u32) u32 {
    return reg(engine.registers + (engine.block + offset) * 4).*;
}

fn writeRegister(engine: dcn.Engine, offset: u32, value: u32) void {
    reg(engine.registers + (engine.block + offset) * 4).* = value;
}

/// The audio side of the link the firmware lit, set for the mode
/// `timings` and the monitor `said` - what `GetBoardMonitor` answers.
///
/// A codec answers for a display link out of what the display engine was
/// told, and a firmware that only lit the link tells it nothing: the pin
/// answers that there is nothing plugged into it and offers no rates, and
/// the audio driver leaves it alone, which is the right answer for a link
/// whose packets are not being sent. Three things turn that around, and
/// all three are here rather than in the audio driver, because all three
/// are registers of this engine:
///
/// - the clock the samples are counted out by, set from the mode's pixel
///   clock;
/// - the link's packet part: driven as the kind of link that carries
///   packets, its store for the samples out of its low-power state, told
///   which endpoint's samples to carry, which channels the monitor's
///   speakers take, what to say in the status that rides with them and
///   how the far end is to rebuild the sample clock at the mode's pixel
///   clock, and sending the description of the sound;
/// - the endpoint itself, told which speakers the far end has, what it
///   plays of uncompressed sound - the rates the mode's blanking has no
///   room for left out (`ratesFor`) - and who it is, and then allowed to
///   answer.
///
/// The endpoint is allowed to answer last, so that the pin never reports
/// a monitor before the rest of the way is standing. Set again in a mode
/// it is in, nothing changes; in another, the clock and the numbers
/// follow the new pixel clock while a stream plays on.
///
/// After this the link is the audio driver's like any other: its pin
/// reports a monitor, and the driver takes the converter, sets the shape
/// and the stream, switches the converter's digital output on and gives
/// the link's slots their channels, and the samples it writes leave the
/// machine. What the far end does with them is the far end's to say.
///
/// False where the link carries no sound: no link takes the pipe that is
/// scanning, no endpoint is wired to a socket, the link is driven for a
/// picture alone, the monitor plays no sound - the endpoint then stops
/// answering (`soundDown`) - or the mode names no pixel clock, which
/// leaves the link as it was. Each is said out loud.
pub fn soundUp(engine: dcn.Engine, timings: *const rtg.RtgTimings, said: *const rtg.RtgMonitorInfo) bool {
    const link = litLink(engine) orelse {
        exec.kprintf(engine.sys, "%s: no link takes pipe %d, so its sound is left alone\n", .{ dcn.owner, engine.pipe });
        return false;
    };
    const endpoint = wiredEndpoint(engine) orelse {
        exec.kprintf(engine.sys, "%s: no audio endpoint is wired to a socket, so link %d's sound is left alone\n", .{ dcn.owner, link });
        return false;
    };
    // A link driven for a picture alone has blanking that carries
    // nothing: the monitor takes no packets, so it is sent no sound.
    if (readLink(engine, link, dig_back) >> back_kind_shift & back_kind_mask != back_kind_with_packets) {
        exec.kprintf(engine.sys, "%s: link %d is driven for a picture alone, so it carries no sound\n", .{ dcn.owner, link });
        soundDown(engine);
        return false;
    }
    if (said.flags & rtg.modes.RTGMON_AUDIO == 0 or said.audio_channels == 0) {
        exec.kprintf(engine.sys, "%s: the monitor plays no sound, so link %d carries none\n", .{ dcn.owner, link });
        soundDown(engine);
        return false;
    }
    const pixel_khz = timings.pixel_clock_hz / 1000;
    if (pixel_khz == 0) {
        exec.kprintf(engine.sys, "%s: the mode names no pixel clock, so link %d's sound is left as it is\n", .{ dcn.owner, link });
        return false;
    }
    const description = descriptionOf(timings, said);
    clockUp(engine, timings.pixel_clock_hz);
    linkUp(engine, link, endpoint, timings.pixel_clock_hz, channelsOf(said.speakers));
    endpointUp(engine, endpoint, description, said);

    exec.kprintf(engine.sys, "%s: link %d carries sound from endpoint %d at %d kHz pixels: %d channel(s), rates %x (%x in two), sizes %x, speakers %x; the pin now sees %x\n", .{
        dcn.owner,
        link,
        endpoint,
        pixel_khz,
        @as(u32, said.audio_channels),
        description >> description_rates_shift & 0xff,
        description >> description_stereo_shift,
        description >> description_sizes_shift & 0xff,
        said.speakers,
        readEndpoint(engine, endpoint, pin_sense),
    });
    return true;
}

/// The link the firmware lit carries no sound: its samples no longer
/// sent and its endpoint no longer answering, so that the pin says
/// nothing is plugged in and the audio driver plays elsewhere. Nothing
/// where no link takes the pipe or no endpoint is wired.
pub fn soundDown(engine: dcn.Engine) void {
    if (litLink(engine)) |link| andLink(engine, link, afmt_audio, ~samples_sending);
    const endpoint = wiredEndpoint(engine) orelse return;
    orEndpoint(engine, endpoint, pin_hotplug, answering_awake);
    andEndpoint(engine, endpoint, pin_hotplug, ~answering_on);
    andEndpoint(engine, endpoint, pin_hotplug, ~answering_awake);
}

/// The endpoint's description of uncompressed sound for a monitor in a
/// mode: its channels less one, its rates, its sizes, and the rates two
/// channels take - each kind of rate only where the mode has room for
/// it.
fn descriptionOf(timings: *const rtg.RtgTimings, said: *const rtg.RtgMonitorInfo) u32 {
    const channels = @max(said.audio_channels, 1);
    const rates = ratesFor(said.audio_rates, channels, timings);
    const stereo = ratesFor(said.audio_stereo_rates | said.audio_rates, @min(channels, 2), timings);
    return (@as(u32, channels) - 1) |
        @as(u32, rates) << description_rates_shift |
        @as(u32, said.audio_sizes) << description_sizes_shift |
        @as(u32, stereo) << description_stereo_shift;
}

/// The rates of `rates` that `channels` channels can be sent at in the
/// mode `timings`, by HDMI 1.3's table 7.5. More than two channels go no
/// faster than 48 kHz in a picture of up to 576 lines at up to 27 MHz,
/// and no faster than 176.4 kHz up to 54 MHz. Any count of them goes no
/// faster than the blanking has room for: a line's blanking less the
/// 58 pixels of its guard bands and preambles and the 16 of its control
/// period, in packets of 32 pixels, each line of the picture and each
/// frame a second, a sample of each channel in each packet.
fn ratesFor(rates: u8, channels: u8, timings: *const rtg.RtgTimings) u8 {
    const pixel_100hz = timings.pixel_clock_hz / 100;
    var fastest: u8 = rates_any;
    if (channels > 2 and timings.v_active <= 576) {
        if (pixel_100hz <= 270_000) {
            fastest = rates_to_48000;
        } else if (pixel_100hz <= 540_000) {
            fastest = rates_to_176400;
        }
    }
    const h_blank = timings.h_front + timings.h_sync + timings.h_back;
    const room = if (h_blank > blank_kept_pixels) h_blank - blank_kept_pixels else 0;
    const h_total: u64 = timings.h_active + h_blank;
    const v_total: u64 = timings.v_active + timings.v_front + timings.v_sync + timings.v_back;
    const refresh_hz: u64 = if (h_total * v_total == 0) 0 else timings.pixel_clock_hz / (h_total * v_total);
    const samples = @as(u64, room) * 10 / packet_pixels * timings.v_active * refresh_hz / 10;
    if (samples < 88_200) {
        fastest &= rates_to_48000;
    } else if (samples < 96_000) {
        fastest &= rates_to_88200;
    } else if (samples < 176_400) {
        fastest &= rates_to_96000;
    } else if (samples < 192_000) {
        fastest &= rates_to_176400;
    }
    return rates & fastest;
}

/// The rates of an audio block, up to each of them; the pixels of a
/// line's blanking that carry no packet, and the pixels a packet takes.
const rates_any: u8 = 0x7f;
const rates_to_48000: u8 = 0x07;
const rates_to_88200: u8 = 0x0f;
const rates_to_96000: u8 = 0x1f;
const rates_to_176400: u8 = 0x3f;
const blank_kept_pixels = 58 + 16;
const packet_pixels = 32;

/// The link's channels that the monitor's speakers take, as the slots of
/// its layout: the front pair, the low frequencies and the centre one to
/// one; the rear pair, then the rear centre in the seventh slot, or the
/// rear centre in the fifth where there is no rear pair; the pairs either
/// side of a centre, front before rear, in the seventh and eighth.
fn channelsOf(speakers: u32) u32 {
    var on: u32 = 0;
    if (speakers & rtg.modes.RTGSPEAKER_FRONT != 0) on |= slot_front_left | slot_front_right;
    if (speakers & rtg.modes.RTGSPEAKER_LFE != 0) on |= slot_lfe;
    if (speakers & rtg.modes.RTGSPEAKER_CENTRE != 0) on |= slot_centre;
    if (speakers & rtg.modes.RTGSPEAKER_REAR != 0) {
        on |= slot_fifth | slot_sixth;
        if (speakers & rtg.modes.RTGSPEAKER_REAR_CENTRE != 0) on |= slot_seventh;
    } else if (speakers & rtg.modes.RTGSPEAKER_REAR_CENTRE != 0) {
        on |= slot_fifth;
    }
    if (speakers & (rtg.modes.RTGSPEAKER_FRONT_CENTRES | rtg.modes.RTGSPEAKER_REAR_CENTRES) != 0) {
        on |= slot_seventh | slot_eighth;
    }
    return on;
}

const slot_front_left: u32 = 1 << 0;
const slot_front_right: u32 = 1 << 1;
const slot_lfe: u32 = 1 << 2;
const slot_centre: u32 = 1 << 3;
const slot_fifth: u32 = 1 << 4;
const slot_sixth: u32 = 1 << 5;
const slot_seventh: u32 = 1 << 6;
const slot_eighth: u32 = 1 << 7;

/// The maker's three letters as the endpoint takes them: the EDID's two
/// bytes - five bits a letter, 'A' being 1, the high byte first - the
/// first of them low. 0 for letters that are none.
fn makerOf(letters: [4]u8) u32 {
    var packed_letters: u32 = 0;
    for (letters[0..3]) |letter| {
        if (letter < 'A' or letter > 'Z') return 0;
        packed_letters = packed_letters << 5 | (letter - '@');
    }
    return packed_letters >> 8 | (packed_letters & 0xff) << 8;
}

/// The link the firmware lit: the one whose front takes the pipe that is
/// scanning and whose clock is running.
pub fn litLink(engine: dcn.Engine) ?u32 {
    var which: u32 = 0;
    while (which < links) : (which += 1) {
        const front = readLink(engine, which, dig_front);
        if (front & front_running == 0) continue;
        if (front >> front_pipe_shift & front_pipe_mask != engine.pipe) continue;
        return which;
    }
    return null;
}

/// The first audio endpoint wired to a socket on the machine's outside.
/// An endpoint that answers nothing for its socket is one no pin of the
/// codec is backed by; one that answers that it is wired to nothing is an
/// endpoint the part has and the machine did not bring out.
fn wiredEndpoint(engine: dcn.Engine) ?u32 {
    var which: u32 = 0;
    while (which < endpoints) : (which += 1) {
        const socket = readEndpoint(engine, which, pin_default);
        if (socket == 0) continue;
        if (socket >> socket_wired_shift & socket_wired_mask != 0) continue;
        return which;
    }
    return null;
}

/// The clock the samples are counted out by: 24 MHz divided out of the
/// pixel clock. Which pipe it follows and which of the two clocks is in
/// use are written before the ratio, which is the order this engine
/// wants them in.
fn clockUp(engine: dcn.Engine, pixel_hz: u32) void {
    setClock(engine, audio_dto_source, dto_pipe_shift, dto_pipe_mask, engine.pipe);
    setClock(engine, audio_dto_source, dto_which_shift, dto_which_mask, 0);
    writeClock(engine, audio_dto_module, pixel_hz / hertz_in_a_hundred);
    writeClock(engine, audio_dto_phase, dto_phase_hundreds);
}

/// One link's packet part set to carry the samples of one endpoint, on a
/// link that carries packets, in the slots `channels_on` names.
fn linkUp(engine: dcn.Engine, link: u32, endpoint: u32, pixel_hz: u32, channels_on: u32) void {
    // Nothing of its own between the packets it is asked to send.
    orLink(engine, link, hdmi_control, control_no_extra_empty);
    // The blanking filled: the general control sent and kept being sent,
    // and empty packets where there is nothing else, so that what is sent
    // between the pictures is a stream the far end can follow.
    orLink(engine, link, hdmi_general_packet, packet_empty | packet_general | packet_general_always);
    // The part's own clock, without which none of the rest of it moves.
    orLink(engine, link, afmt_clock, link_clock_on);
    // The store the samples pass through, out of its low-power state.
    setLink(engine, link, afmt_memory, memory_force_shift, memory_force_mask, 0);
    orLink(engine, link, afmt_memory, memory_low_power_off);
    // The packets wait for the pixels of the line they belong to.
    orLink(engine, link, hdmi_audio, 1 << 4);
    // The status that rides with the samples is taken up as written.
    orLink(engine, link, afmt_audio, samples_status_again);
    // The layout is the one the channel count gives, and the channels on
    // are the ones the monitor's speakers take.
    andLink(engine, link, afmt_layout, ~(layout_override | layout_oversampling));
    setLink(engine, link, afmt_layout, layout_channels_shift, layout_channels_mask, channels_on);
    // The far end is told how to rebuild the sample clock: the engine
    // works the cycle out, the numbers go by themselves, and they do not
    // come before the picture.
    orLink(engine, link, hdmi_clock, acr_sending);
    andLink(engine, link, hdmi_clock, ~(acr_from_what_is_written | acr_before_the_picture));
    // The pair for each rate, as rtg.library works them out: the samples
    // a cycle the standard's own number for the rate, the cycle the pixel
    // clock where the two agree.
    const pairs = [_]struct { rate: u32, samples: u32, cycle: u32 }{
        .{ .rate = 32_000, .samples = acr_32_samples, .cycle = acr_32_cycle },
        .{ .rate = 44_100, .samples = acr_44_samples, .cycle = acr_44_cycle },
        .{ .rate = 48_000, .samples = acr_48_samples, .cycle = acr_48_cycle },
    };
    if (engine.rtg_base) |rb| {
        for (pairs) |pair| {
            var n: u32 = 0;
            var cts: u32 = 0;
            if (!rb.HdmiAudioClock(pixel_hz, pair.rate, &n, &cts)) continue;
            setLink(engine, link, pair.samples, acr_samples_shift, acr_samples_mask, n);
            setLink(engine, link, pair.cycle, acr_cycle_shift, acr_cycle_mask, @min(cts, acr_cycle_mask));
        }
    }
    // Which channel each side is, and that the clock is as accurate as
    // such a clock usually is.
    setLink(engine, link, afmt_status_left, status_channel_shift, status_channel_mask, 1);
    setLink(engine, link, afmt_status_left, status_accuracy_shift, status_accuracy_mask, 0);
    setLink(engine, link, afmt_status_right, status_channel_shift, status_channel_mask, 2);
    setLink(engine, link, afmt_status_rest, 0, status_rest_mask, status_rest_channels);
    // The description of the sound - how many channels there are and what
    // kind they are - goes out between the pictures, on the second line of
    // the blanking. Without it a monitor has not been told what is coming
    // and stays quiet whatever arrives. The description is the one the
    // codec wrote, taken up again now that it is being sent.
    orLink(engine, link, hdmi_sending, sending_sound_description | sending_sound_description_always);
    setLink(engine, link, hdmi_sending_line, sending_line_shift, sending_line_mask, sending_line);
    orLink(engine, link, afmt_infoframe, description_again);
    // And the far end is not told to mute.
    andLink(engine, link, hdmi_general, ~general_mute);
    // Whose samples they are, and that they are being sent.
    writeLink(engine, link, afmt_source, (endpoint & link_from_mask) << link_from_shift);
    orLink(engine, link, afmt_audio, samples_sending);
}

/// One endpoint told what the far end has - its speakers, the
/// `description` of its uncompressed sound and none of any other kind,
/// its maker, product and name - and allowed to answer. Its registers
/// are held awake while they are written and let go of after, which is
/// how this part wants them reached.
fn endpointUp(engine: dcn.Engine, endpoint: u32, description: u32, said: *const rtg.RtgMonitorInfo) void {
    orEndpoint(engine, endpoint, pin_hotplug, answering_awake);

    var speakers = readEndpoint(engine, endpoint, pin_speaker);
    speakers = speakers & ~(speakers_mask | speakers_lfe_level | speakers_port | speakers_extra) |
        (said.speakers & speakers_mask) | speakers_wire;
    writeEndpoint(engine, endpoint, pin_speaker, speakers);

    writeEndpoint(engine, endpoint, pin_descriptor, description);
    var kind: u32 = 1;
    while (kind < descriptions) : (kind += 1) {
        if (kind == description_one_bit or kind == description_dst) continue;
        writeEndpoint(engine, endpoint, pin_descriptor + kind, 0);
    }

    writeEndpoint(engine, endpoint, pin_sink, makerOf(said.maker) | (said.product & 0xffff) << 16);
    var length: u32 = 0;
    while (length < name_most and length < said.name.len and said.name[length] != 0) : (length += 1) {}
    writeEndpoint(engine, endpoint, pin_sink_name_length, length);
    var word: u32 = 0;
    while (word * 4 < name_most) : (word += 1) {
        var letters: u32 = 0;
        var at: u32 = 0;
        while (at < 4) : (at += 1) {
            const which = word * 4 + at;
            if (which < length) letters |= @as(u32, said.name[which]) << @intCast(at * 8);
        }
        writeEndpoint(engine, endpoint, pin_sink_name + word, letters);
    }

    orEndpoint(engine, endpoint, pin_hotplug, answering_on);
    andEndpoint(engine, endpoint, pin_hotplug, ~answering_awake);
}

fn writeClock(engine: dcn.Engine, offset: u32, value: u32) void {
    reg(engine.registers + (engine.clocks + offset) * 4).* = value;
}

fn setClock(engine: dcn.Engine, offset: u32, shift: u5, mask: u32, value: u32) void {
    writeClock(engine, offset, readClock(engine, offset) & ~(mask << shift) | (value & mask) << shift);
}

fn writeLink(engine: dcn.Engine, link: u32, offset: u32, value: u32) void {
    writeRegister(engine, offset + link * link_stride, value);
}

fn orLink(engine: dcn.Engine, link: u32, offset: u32, bits: u32) void {
    writeLink(engine, link, offset, readLink(engine, link, offset) | bits);
}

fn andLink(engine: dcn.Engine, link: u32, offset: u32, bits: u32) void {
    writeLink(engine, link, offset, readLink(engine, link, offset) & bits);
}

fn setLink(engine: dcn.Engine, link: u32, offset: u32, shift: u5, mask: u32, value: u32) void {
    writeLink(engine, link, offset, readLink(engine, link, offset) & ~(mask << shift) | (value & mask) << shift);
}

/// One of an audio endpoint's own registers written, through its latch.
fn writeEndpoint(engine: dcn.Engine, endpoint: u32, offset: u32, value: u32) void {
    writeRegister(engine, endpoint_index + endpoint * endpoint_stride, offset);
    writeRegister(engine, endpoint_data + endpoint * endpoint_stride, value);
}

fn orEndpoint(engine: dcn.Engine, endpoint: u32, offset: u32, bits: u32) void {
    writeEndpoint(engine, endpoint, offset, readEndpoint(engine, endpoint, offset) | bits);
}

fn andEndpoint(engine: dcn.Engine, endpoint: u32, offset: u32, bits: u32) void {
    writeEndpoint(engine, endpoint, offset, readEndpoint(engine, endpoint, offset) & bits);
}

/// A register of the engine's clocks, which are counted from the
/// engine's other block.
fn readClock(engine: dcn.Engine, offset: u32) u32 {
    return reg(engine.registers + (engine.clocks + offset) * 4).*;
}

/// One of an audio endpoint's own registers, through its latch.
fn readEndpoint(engine: dcn.Engine, endpoint: u32, offset: u32) u32 {
    writeRegister(engine, endpoint_index + endpoint * endpoint_stride, offset);
    return readRegister(engine, endpoint_data + endpoint * endpoint_stride);
}

/// A register of one link's packet part.
fn readLink(engine: dcn.Engine, link: u32, offset: u32) u32 {
    return readRegister(engine, offset + link * link_stride);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

/// The box's monitor's own mode, as its EDID names it.
const own: rtg.RtgTimings = .{
    .pixel_clock_hz = 241_500_000,
    .h_active = 2560,
    .h_front = 48,
    .h_sync = 32,
    .h_back = 80,
    .v_active = 1440,
    .v_front = 3,
    .v_sync = 5,
    .v_back = 33,
};

test "the rates a mode has room for" {
    // 2560x1440: every rate, at any count of channels.
    try testing.expectEqual(@as(u8, 0x7f), ratesFor(0x7f, 2, &own));
    try testing.expectEqual(@as(u8, 0x7f), ratesFor(0x7f, 8, &own));
    // 640x480 at 60 Hz: no faster than 48 kHz for its blanking.
    const vga: rtg.RtgTimings = .{
        .pixel_clock_hz = 25_175_000,
        .h_active = 640,
        .h_front = 16,
        .h_sync = 96,
        .h_back = 48,
        .v_active = 480,
        .v_front = 10,
        .v_sync = 2,
        .v_back = 33,
    };
    try testing.expectEqual(@as(u8, 0x07), ratesFor(0x7f, 2, &vga));
    // 720x576 at 50 Hz, 27 MHz: more than two channels no faster than 48
    // kHz whatever the blanking.
    const pal: rtg.RtgTimings = .{
        .pixel_clock_hz = 27_000_000,
        .h_active = 720,
        .h_front = 12,
        .h_sync = 64,
        .h_back = 68,
        .v_active = 576,
        .v_front = 5,
        .v_sync = 5,
        .v_back = 39,
    };
    try testing.expectEqual(@as(u8, 0x07), ratesFor(0x7f, 6, &pal));
    // A blanking shorter than what carries no packet has room for 48 kHz.
    var short = own;
    short.h_front = 8;
    short.h_sync = 8;
    short.h_back = 8;
    try testing.expectEqual(@as(u8, 0x07), ratesFor(0x7f, 2, &short));
}

test "the monitor's description of its sound, as the endpoint takes it" {
    // The box's monitor: two channels at 32, 44.1 and 48 kHz in 16, 20
    // and 24 bits.
    const said: rtg.RtgMonitorInfo = .{
        .flags = rtg.modes.RTGMON_AUDIO,
        .audio_channels = 2,
        .audio_rates = 0x07,
        .audio_stereo_rates = 0x07,
        .audio_sizes = 0x07,
        .speakers = rtg.modes.RTGSPEAKER_FRONT,
    };
    try testing.expectEqual(@as(u32, 0x07070701), descriptionOf(&own, &said));
    // Eight channels to 48 kHz, two to 192 kHz.
    var wide = said;
    wide.audio_channels = 8;
    wide.audio_stereo_rates = 0x7f;
    try testing.expectEqual(@as(u32, 0x7f070707), descriptionOf(&own, &wide));
}

test "the slots the speakers take" {
    try testing.expectEqual(@as(u32, 0x03), channelsOf(rtg.modes.RTGSPEAKER_FRONT));
    // 5.1: the front pair, the low frequencies, the centre, the rear pair.
    const surround = rtg.modes.RTGSPEAKER_FRONT | rtg.modes.RTGSPEAKER_LFE | rtg.modes.RTGSPEAKER_CENTRE | rtg.modes.RTGSPEAKER_REAR;
    try testing.expectEqual(@as(u32, 0x3f), channelsOf(surround));
    // 7.1, the rear pair either side of the centre in the last two.
    try testing.expectEqual(@as(u32, 0xff), channelsOf(surround | rtg.modes.RTGSPEAKER_REAR_CENTRES));
    // A rear centre without a rear pair in the fifth.
    try testing.expectEqual(@as(u32, 0x13), channelsOf(rtg.modes.RTGSPEAKER_FRONT | rtg.modes.RTGSPEAKER_REAR_CENTRE));
}

test "the maker's letters as the EDID holds them" {
    // DEL: 0x10AC, high byte first.
    try testing.expectEqual(@as(u32, 0xAC10), makerOf(.{ 'D', 'E', 'L', 0 }));
    try testing.expectEqual(@as(u32, 0), makerOf(.{ 0, 0, 0, 0 }));
}
