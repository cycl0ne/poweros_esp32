// SPDX-License-Identifier: MPL-2.0
//! What a codec is asked and told, by the names the specification gives.
//!
//! **A verb is twenty bits**: either twelve of verb and eight of
//! payload, or four and sixteen. Which it is belongs to the verb, so
//! each one here is a function that builds the whole twenty bits from
//! what it takes, and nothing has to remember which shape a verb has.
//!
//! **Reading is a parameter, mostly.** One verb - get parameter - reads
//! everything a node says about itself, with a parameter number saying
//! which thing; the rest read and write state. A node that does not have
//! a parameter answers zero for it, which is why a codec can be walked
//! without knowing what it is.

/// Get a parameter of a node: twelve bits of verb, the parameter in the
/// low eight.
pub fn parameter(which: u8) u20 {
    return 0xf_0000 | @as(u20, which);
}

/// The parameters a node may have.
pub const param_vendor_id: u8 = 0x00;
pub const param_revision: u8 = 0x02;
/// Which nodes are below this one: the first of them in the high half,
/// how many in the low.
pub const param_node_count: u8 = 0x04;
/// What a function group is for: an audio one answers 1 in its low byte.
pub const param_function_type: u8 = 0x05;
/// What a widget is and what it can do.
pub const param_widget_cap: u8 = 0x09;
/// The rates and sample sizes a converter takes.
pub const param_pcm: u8 = 0x0a;
/// The kinds of stream it takes.
pub const param_stream_formats: u8 = 0x0b;
/// What a pin can do.
pub const param_pin_cap: u8 = 0x0c;
/// What its amplifiers can do, on the way in and on the way out.
pub const param_in_amp_cap: u8 = 0x0d;
pub const param_out_amp_cap: u8 = 0x12;
/// How many nodes this one can take its input from.
pub const param_connections: u8 = 0x0e;
/// Which power states it has.
pub const param_power_states: u8 = 0x0f;

/// An audio function group, as `param_function_type` answers.
pub const function_audio: u8 = 0x01;

/// What a widget is, in the high bits of `param_widget_cap`.
pub const widget_output: u4 = 0x0;
pub const widget_input: u4 = 0x1;
pub const widget_mixer: u4 = 0x2;
pub const widget_selector: u4 = 0x3;
pub const widget_pin: u4 = 0x4;
pub const widget_power: u4 = 0x5;
pub const widget_volume_knob: u4 = 0x6;
pub const widget_beep: u4 = 0x7;

pub fn widgetKind(capability: u32) u4 {
    return @truncate(capability >> 20);
}

/// `param_widget_cap`'s own bits.
pub const widget_stereo: u32 = 1 << 0;
pub const widget_in_amp: u32 = 1 << 1;
pub const widget_out_amp: u32 = 1 << 2;
pub const widget_amp_override: u32 = 1 << 3;
pub const widget_format_override: u32 = 1 << 4;
pub const widget_striped: u32 = 1 << 5;
pub const widget_unsolicited: u32 = 1 << 7;
pub const widget_conn_list: u32 = 1 << 8;
pub const widget_digital: u32 = 1 << 9;
pub const widget_power_control: u32 = 1 << 10;

/// One entry of a node's connection list. The answer holds several
/// entries at once - four of a byte each, or two of a short - and which
/// it is comes from the length the node reported.
pub fn connectionList(from: u8) u20 {
    return 0xf_0200 | @as(u20, from);
}

/// Which one of a node's inputs it takes, for a node that takes one at a
/// time: a selector's choice, and a pin's where it has more than one
/// thing wired to it. A mixer has no choice to make - it sums what comes
/// in - and is opened by its input amplifiers instead.
pub const connection_select_get: u20 = 0xf_0100;
pub fn connectionSelectSet(index: u8) u20 {
    return 0x7_0100 | @as(u20, index);
}

/// `param_connections`: how many entries, and whether they are shorts.
pub const connections_count: u32 = 0x7f;
pub const connections_long: u32 = 1 << 7;

/// A pin's configuration default: what the machine's maker wired it to,
/// which is where what a pin is for comes from.
pub const pin_config_default: u20 = 0xf_1c00;

/// Its fields.
pub fn pinConnectivity(config: u32) u2 {
    return @truncate(config >> 30);
}
pub fn pinDevice(config: u32) u4 {
    return @truncate(config >> 20);
}
pub fn pinColour(config: u32) u4 {
    return @truncate(config >> 12);
}
pub fn pinLocation(config: u32) u6 {
    return @truncate(config >> 24);
}

/// What `pinConnectivity` says: a jack on the outside of the machine,
/// nothing at all, something fixed inside it, or both.
pub const connectivity_jack: u2 = 0;
pub const connectivity_none: u2 = 1;
pub const connectivity_fixed: u2 = 2;
pub const connectivity_both: u2 = 3;

/// What `pinDevice` says a pin is for.
pub const device_line_out: u4 = 0x0;
pub const device_speaker: u4 = 0x1;
pub const device_headphone: u4 = 0x2;
pub const device_cd: u4 = 0x3;
pub const device_spdif_out: u4 = 0x4;
pub const device_digital_out: u4 = 0x5;
pub const device_modem_line: u4 = 0x6;
pub const device_modem_handset: u4 = 0x7;
pub const device_line_in: u4 = 0x8;
pub const device_aux: u4 = 0x9;
pub const device_mic: u4 = 0xa;
pub const device_telephony: u4 = 0xb;
pub const device_spdif_in: u4 = 0xc;
pub const device_digital_in: u4 = 0xd;
pub const device_other: u4 = 0xf;

/// `param_pin_cap`'s bits: what a pin can do at all.
pub const pin_cap_impedance: u32 = 1 << 0;
pub const pin_cap_trigger: u32 = 1 << 1;
pub const pin_cap_presence: u32 = 1 << 2;
pub const pin_cap_headphone: u32 = 1 << 3;
pub const pin_cap_output: u32 = 1 << 4;
pub const pin_cap_input: u32 = 1 << 5;
pub const pin_cap_balanced: u32 = 1 << 6;
pub const pin_cap_hdmi: u32 = 1 << 7;
pub const pin_cap_vref: u32 = 0x0000_ff00;
pub const pin_cap_eapd: u32 = 1 << 16;
pub const pin_cap_display_port: u32 = 1 << 24;
pub const pin_cap_high_bit_rate: u32 = 1 << 27;

/// A pin's control: whether it drives what is plugged into it, hears it,
/// and whether its headphone amplifier is on.
pub const pin_control_get: u20 = 0xf_0700;
pub fn pinControlSet(bits: u8) u20 {
    return 0x7_0700 | @as(u20, bits);
}
pub const pin_control_out: u8 = 1 << 6;
pub const pin_control_in: u8 = 1 << 5;
pub const pin_control_headphone: u8 = 1 << 7;

/// A pin's external amplifier, where it has one to power.
pub const eapd_get: u20 = 0xf_0c00;
pub fn eapdSet(bits: u8) u20 {
    return 0x7_0c00 | @as(u20, bits);
}
pub const eapd_btl: u8 = 1 << 0;
pub const eapd_enable: u8 = 1 << 1;
pub const eapd_left_right_swap: u8 = 1 << 2;

/// Which stream a converter takes its samples from, and which channel of
/// it is its first: the stream in the high four bits, the channel in the
/// low four.
pub const stream_channel_get: u20 = 0xf_0600;
pub fn streamChannelSet(stream: u4, channel: u4) u20 {
    return 0x7_0600 | (@as(u20, stream) << 4) | @as(u20, channel);
}

/// The shape of the samples a converter is given: sixteen bits of
/// payload, the same shape the controller's own stream descriptor takes.
pub const format_get: u20 = 0xa_0000;
pub fn formatSet(format: u16) u20 {
    return 0x2_0000 | @as(u20, format);
}

/// A node's power state, which has to be the working one before it does
/// anything.
pub const power_get: u20 = 0xf_0500;
pub fn powerSet(state: u8) u20 {
    return 0x7_0500 | @as(u20, state);
}
pub const power_d0: u8 = 0;
pub const power_d3: u8 = 3;

/// An amplifier's gain and whether it is muted. Reading takes which
/// amplifier and which side; writing says which of them it is setting.
pub fn ampGet(output: bool, left: bool, index: u8) u20 {
    const which: u20 = (if (output) @as(u20, 1) << 15 else 0) | (if (left) @as(u20, 1) << 13 else 0);
    return 0xb_0000 | which | @as(u20, index);
}
pub fn ampSet(output: bool, input: bool, left: bool, right: bool, index: u8, mute: bool, gain: u7) u20 {
    var payload: u20 = 0x3_0000;
    if (output) payload |= 1 << 15;
    if (input) payload |= 1 << 14;
    if (left) payload |= 1 << 13;
    if (right) payload |= 1 << 12;
    payload |= @as(u20, index) << 8;
    if (mute) payload |= 1 << 7;
    payload |= gain;
    return payload;
}

/// What an amplifier can do, as `param_out_amp_cap` answers: how many
/// steps it has, how large a step is, and which step is no change.
pub fn ampSteps(capability: u32) u8 {
    return @truncate((capability >> 8) & 0x7f);
}
pub fn ampStepSize(capability: u32) u8 {
    return @truncate((capability >> 16) & 0x7f);
}
pub fn ampOffset(capability: u32) u8 {
    return @truncate(capability & 0x7f);
}
pub const amp_can_mute: u32 = 1 << 31;

/// `param_pcm`: which rates and which sample sizes a converter takes.
pub const pcm_rate_8000: u32 = 1 << 0;
pub const pcm_rate_11025: u32 = 1 << 1;
pub const pcm_rate_16000: u32 = 1 << 2;
pub const pcm_rate_22050: u32 = 1 << 3;
pub const pcm_rate_32000: u32 = 1 << 4;
pub const pcm_rate_44100: u32 = 1 << 5;
pub const pcm_rate_48000: u32 = 1 << 6;
pub const pcm_rate_88200: u32 = 1 << 7;
pub const pcm_rate_96000: u32 = 1 << 8;
pub const pcm_rate_176400: u32 = 1 << 9;
pub const pcm_rate_192000: u32 = 1 << 10;
pub const pcm_bits_8: u32 = 1 << 16;
pub const pcm_bits_16: u32 = 1 << 17;
pub const pcm_bits_20: u32 = 1 << 18;
pub const pcm_bits_24: u32 = 1 << 19;
pub const pcm_bits_32: u32 = 1 << 20;

/// The data a display pin holds about what is at the far end of the
/// link: how long it is, and a byte of it at a time.
pub const eld_size: u20 = 0xf_2e00;
pub fn eldByte(at: u8) u20 {
    return 0xf_2f00 | @as(u20, at);
}

/// Which channels of the stream go to which of a display pin's slots.
pub fn channelSlotSet(slot: u4, channel: u4) u20 {
    return 0x7_3400 | (@as(u20, channel) << 4) | @as(u20, slot);
}

/// A display pin's data island packets: which one is being written, the
/// bytes of it, and whether it is being sent.
pub fn dipIndexSet(index: u8) u20 {
    return 0x7_3000 | @as(u20, index);
}
pub fn dipDataSet(byte: u8) u20 {
    return 0x7_3100 | @as(u20, byte);
}
pub fn dipTransmitSet(bits: u8) u20 {
    return 0x7_3200 | @as(u20, bits);
}
/// The packet is sent with every frame.
pub const dip_transmit_best: u8 = 0xc0;
