// SPDX-License-Identifier: MIT
//! Sound over BR/EDR: the Advanced Audio Distribution Profile's numbers -
//! its services' classes, the codecs and SBC's element - and those of the
//! transport protocol under it, AVDTP: its signals, the parts of a
//! message, the categories of a stream end point's capabilities and the
//! errors a device refuses a command with. Both of AVDTP's channels open
//! to l2cap.PSM_AVDTP: the first between two devices is the signalling,
//! the next, opened after a stream's OPEN, that stream's media.
//!
//! **A signalling message** begins with a byte: the transaction label in
//! its upper four bits - a command's, which its answer carries back -
//! the packet type in the next two (AVDTP_PACKET_*) and the message type
//! in the lowest two (AVDTP_COMMAND, AVDTP_ACCEPT, AVDTP_REJECT,
//! AVDTP_GENERAL_REJECT). A single packet's second byte holds the signal
//! (AVDTP_DISCOVER and on) in its lower six bits; a message longer than
//! the channel takes is a start packet - its second byte the number of
//! packets, its third the signal - continue packets and an end packet,
//! the last two with the first byte alone. A stream end point's ID, its
//! SEID, is six bits, in a byte's upper six (AVDTP_SEID_SHIFT).
//!
//! **A stream end point** - one end of a stream - is listed by DISCOVER
//! in two bytes: its SEID, with AVDTP_IN_USE where a stream has it; its
//! media type in the second byte's upper four bits (AVDTP_MEDIA_*), with
//! AVDTP_TSEP_SNK where it is a sink. Its capabilities, and a
//! configuration, are service capabilities one after another: a category
//! (AVDTP_CAT_*), the length of what follows, and that many bytes - for
//! the codec its media type in the upper four bits of the first, the
//! codec (A2DP_CODEC_*) and the codec's element.
//!
//! **SBC's element** is four bytes: the rates and the channel modes in
//! the first (A2DP_SBC_16000 to A2DP_SBC_JOINT_STEREO), the blocks, the
//! subbands and the allocation in the second, the least bitpool in the
//! third and the most in the fourth. The capabilities of an end point
//! may set several bits of a field; a configuration sets one.
//!
//! **A media packet** is an RTP header (RTP_HDR bytes): RTP_VERSION in
//! the first byte, the payload type in the second, the sequence number
//! counting the packets, the timestamp of the first sample counting the
//! samples, and the source's identifier, each big-endian; then a byte
//! whose lower four bits count the SBC frames after it.

/// The services' classes (BTService.class16): a device that sends sound,
/// a device that plays it, the profile both records name, and the
/// protocol they name after L2CAP.
pub const UUID_AUDIO_SOURCE: u16 = 0x110A;
pub const UUID_AUDIO_SINK: u16 = 0x110B;
pub const UUID_ADVANCED_AUDIO: u16 = 0x110D;
pub const UUID_AVDTP: u16 = 0x0019;

/// The versions a record names: AVDTP's after its UUID, the profile's
/// after UUID_ADVANCED_AUDIO - 1.3 each, which has delay reports.
pub const AVDTP_VERSION: u16 = 0x0103;
pub const A2DP_VERSION: u16 = 0x0103;

/// An audio record's supported features: what the device is - a sink's
/// A2DP_SINK_*, a source's A2DP_SOURCE_*.
pub const ATTR_SUPPORTED_FEATURES: u16 = 0x0311;
pub const A2DP_SINK_HEADPHONE: u16 = 1 << 0;
pub const A2DP_SINK_SPEAKER: u16 = 1 << 1;
pub const A2DP_SINK_RECORDER: u16 = 1 << 2;
pub const A2DP_SINK_AMPLIFIER: u16 = 1 << 3;
pub const A2DP_SOURCE_PLAYER: u16 = 1 << 0;
pub const A2DP_SOURCE_MICROPHONE: u16 = 1 << 1;
pub const A2DP_SOURCE_TUNER: u16 = 1 << 2;
pub const A2DP_SOURCE_MIXER: u16 = 1 << 3;

/// A message's packet type: bits 3 and 2 of its first byte.
pub const AVDTP_PACKET_SINGLE: u8 = 0;
pub const AVDTP_PACKET_START: u8 = 1;
pub const AVDTP_PACKET_CONTINUE: u8 = 2;
pub const AVDTP_PACKET_END: u8 = 3;

/// A message's type: bits 1 and 0 of its first byte. A general reject
/// answers a signal the device does not know.
pub const AVDTP_COMMAND: u8 = 0;
pub const AVDTP_GENERAL_REJECT: u8 = 1;
pub const AVDTP_ACCEPT: u8 = 2;
pub const AVDTP_REJECT: u8 = 3;

/// The signals.
pub const AVDTP_DISCOVER: u8 = 0x01;
pub const AVDTP_GET_CAPABILITIES: u8 = 0x02;
pub const AVDTP_SET_CONFIGURATION: u8 = 0x03;
pub const AVDTP_GET_CONFIGURATION: u8 = 0x04;
pub const AVDTP_RECONFIGURE: u8 = 0x05;
pub const AVDTP_OPEN: u8 = 0x06;
pub const AVDTP_START: u8 = 0x07;
pub const AVDTP_CLOSE: u8 = 0x08;
pub const AVDTP_SUSPEND: u8 = 0x09;
pub const AVDTP_ABORT: u8 = 0x0A;
pub const AVDTP_SECURITY_CONTROL: u8 = 0x0B;
pub const AVDTP_GET_ALL_CAPABILITIES: u8 = 0x0C;
pub const AVDTP_DELAYREPORT: u8 = 0x0D;

/// A SEID's place in its byte, 1 to 62.
pub const AVDTP_SEID_SHIFT = 2;
/// DISCOVER's first byte of an end point: a stream has it.
pub const AVDTP_IN_USE: u8 = 1 << 1;
/// Its second byte: a sink rather than a source, and the media type
/// above bit 4.
pub const AVDTP_TSEP_SNK: u8 = 1 << 3;
pub const AVDTP_MEDIA_SHIFT = 4;
pub const AVDTP_MEDIA_AUDIO: u8 = 0x0;
pub const AVDTP_MEDIA_VIDEO: u8 = 0x1;
pub const AVDTP_MEDIA_MULTIMEDIA: u8 = 0x2;

/// The categories of service capabilities.
pub const AVDTP_CAT_MEDIA_TRANSPORT: u8 = 0x01;
pub const AVDTP_CAT_REPORTING: u8 = 0x02;
pub const AVDTP_CAT_RECOVERY: u8 = 0x03;
pub const AVDTP_CAT_CONTENT_PROTECTION: u8 = 0x04;
pub const AVDTP_CAT_HEADER_COMPRESSION: u8 = 0x05;
pub const AVDTP_CAT_MULTIPLEXING: u8 = 0x06;
pub const AVDTP_CAT_MEDIA_CODEC: u8 = 0x07;
pub const AVDTP_CAT_DELAY_REPORTING: u8 = 0x08;

/// What a device refuses a command with. A refused SET_CONFIGURATION or
/// RECONFIGURE names the category that failed before it; a refused START
/// or SUSPEND the SEID.
pub const AVDTP_BAD_HEADER_FORMAT: u8 = 0x01;
pub const AVDTP_BAD_LENGTH: u8 = 0x11;
pub const AVDTP_BAD_ACP_SEID: u8 = 0x12;
pub const AVDTP_SEP_IN_USE: u8 = 0x13;
pub const AVDTP_SEP_NOT_IN_USE: u8 = 0x14;
pub const AVDTP_BAD_SERV_CATEGORY: u8 = 0x17;
pub const AVDTP_BAD_PAYLOAD_FORMAT: u8 = 0x18;
pub const AVDTP_NOT_SUPPORTED_COMMAND: u8 = 0x19;
pub const AVDTP_INVALID_CAPABILITIES: u8 = 0x1A;
pub const AVDTP_BAD_RECOVERY_TYPE: u8 = 0x22;
pub const AVDTP_BAD_MEDIA_TRANSPORT_FORMAT: u8 = 0x23;
pub const AVDTP_BAD_RECOVERY_FORMAT: u8 = 0x25;
pub const AVDTP_BAD_ROHC_FORMAT: u8 = 0x26;
pub const AVDTP_BAD_CP_FORMAT: u8 = 0x27;
pub const AVDTP_BAD_MULTIPLEXING_FORMAT: u8 = 0x28;
pub const AVDTP_UNSUPPORTED_CONFIGURATION: u8 = 0x29;
pub const AVDTP_BAD_STATE: u8 = 0x31;
/// The profile's own, for a configuration refused.
pub const A2DP_INVALID_CODEC_TYPE: u8 = 0xC1;
pub const A2DP_NOT_SUPPORTED_CODEC_TYPE: u8 = 0xC2;
pub const A2DP_INVALID_SAMPLING_FREQUENCY: u8 = 0xC3;
pub const A2DP_NOT_SUPPORTED_SAMPLING_FREQUENCY: u8 = 0xC4;
pub const A2DP_INVALID_CHANNEL_MODE: u8 = 0xC5;
pub const A2DP_NOT_SUPPORTED_CHANNEL_MODE: u8 = 0xC6;
pub const A2DP_INVALID_SUBBANDS: u8 = 0xC7;
pub const A2DP_NOT_SUPPORTED_SUBBANDS: u8 = 0xC8;
pub const A2DP_INVALID_ALLOCATION_METHOD: u8 = 0xC9;
pub const A2DP_NOT_SUPPORTED_ALLOCATION_METHOD: u8 = 0xCA;
pub const A2DP_INVALID_MINIMUM_BITPOOL_VALUE: u8 = 0xCB;
pub const A2DP_NOT_SUPPORTED_MINIMUM_BITPOOL_VALUE: u8 = 0xCC;
pub const A2DP_INVALID_MAXIMUM_BITPOOL_VALUE: u8 = 0xCD;
pub const A2DP_NOT_SUPPORTED_MAXIMUM_BITPOOL_VALUE: u8 = 0xCE;
pub const A2DP_INVALID_BLOCK_LENGTH: u8 = 0xDD;
pub const A2DP_INVALID_CP_TYPE: u8 = 0xE0;
pub const A2DP_INVALID_CP_FORMAT: u8 = 0xE1;
pub const A2DP_INVALID_CODEC_PARAMETER: u8 = 0xE2;
pub const A2DP_NOT_SUPPORTED_CODEC_PARAMETER: u8 = 0xE3;

/// The codecs: SBC, which every device takes, MPEG-1 and 2 audio, AAC,
/// USAC, the ATRAC family, and one of a maker's own.
pub const A2DP_CODEC_SBC: u8 = 0x00;
pub const A2DP_CODEC_MPEG12: u8 = 0x01;
pub const A2DP_CODEC_AAC: u8 = 0x02;
pub const A2DP_CODEC_USAC: u8 = 0x03;
pub const A2DP_CODEC_ATRAC: u8 = 0x04;
pub const A2DP_CODEC_VENDOR: u8 = 0xFF;

/// SBC's element, first byte: the rates in the upper four bits, the
/// channel modes in the lower four.
pub const A2DP_SBC_16000: u8 = 0x80;
pub const A2DP_SBC_32000: u8 = 0x40;
pub const A2DP_SBC_44100: u8 = 0x20;
pub const A2DP_SBC_48000: u8 = 0x10;
pub const A2DP_SBC_MONO: u8 = 0x08;
pub const A2DP_SBC_DUAL_CHANNEL: u8 = 0x04;
pub const A2DP_SBC_STEREO: u8 = 0x02;
pub const A2DP_SBC_JOINT_STEREO: u8 = 0x01;
/// Second byte: the blocks in the upper four bits, then the subbands and
/// the allocation.
pub const A2DP_SBC_BLOCKS_4: u8 = 0x80;
pub const A2DP_SBC_BLOCKS_8: u8 = 0x40;
pub const A2DP_SBC_BLOCKS_12: u8 = 0x20;
pub const A2DP_SBC_BLOCKS_16: u8 = 0x10;
pub const A2DP_SBC_SUBBANDS_4: u8 = 0x08;
pub const A2DP_SBC_SUBBANDS_8: u8 = 0x04;
pub const A2DP_SBC_SNR: u8 = 0x02;
pub const A2DP_SBC_LOUDNESS: u8 = 0x01;
/// The bitpools, third and fourth bytes, lie within these.
pub const A2DP_SBC_BITPOOL_LEAST: u8 = 2;
pub const A2DP_SBC_BITPOOL_MOST: u8 = 250;

/// A media packet's RTP header, its version 2 in the first byte's upper
/// two bits, and the payload type of RTP's dynamic range it is sent
/// with.
pub const RTP_HDR: usize = 12;
pub const RTP_VERSION: u8 = 0x80;
pub const RTP_PAYLOAD_DYNAMIC: u8 = 96;
/// The byte after it: the SBC frames in the packet in its lower four
/// bits.
pub const A2DP_SBC_FRAMES_MASK: u8 = 0x0F;
pub const A2DP_SBC_FRAMES_MOST: usize = 15;

/// A delay report counts tenths of a millisecond.
pub const AVDTP_DELAY_PER_MS: u32 = 10;
