// SPDX-License-Identifier: MIT
//! videoparse.library's structures and constants: an H.264 or HEVC
//! stream read - its parameter sets, its pictures' slice headers, their
//! order counts, the reference pictures each one holds and the lists it
//! decodes from, and the order the pictures are shown in - for a decoder,
//! which decodes the samples. The calls are in `sdk.interface.videoparse`;
//! the syntax structures in `sdk.videoparse.h264` and `sdk.videoparse.hevc`.
//!
//! **A parser** (`OpenVideoParser`) is given a track's setup - an MP4's
//! avcC or hvcC, a Matroska track's CodecPrivate - or nothing, for a
//! stream in Annex B form. A packet is handed over (`ParseVideoPacket`),
//! and what it says is asked for event by event (`NextVideoEvent`) until
//! the parser answers VPERR_NEED_DATA: it reads one unit at a time, as the
//! events are asked for, so the packet's bytes stay the caller's to keep
//! until then.
//!
//! **The events**, in their order for each picture:
//!
//! - `VPEV_SEQUENCE` - a sequence starts, or its size changes: what the
//!   pictures are and how many slots may be in use at once.
//! - `VPEV_MISSING` - a slot stands for a picture the stream lacks (a gap
//!   in H.264's frame numbers, a reference HEVC's reference picture set
//!   names that is not there): the caller fills it, with grey or a copy
//!   of the last reference, as it is referred to as if it were there.
//! - `VPEV_PICTURE` - a picture begins: its slot, its order counts, its
//!   parameter sets and the reference pictures it holds, before it is
//!   marked.
//! - `VPEV_SLICE` - one of its slices: the unit as it came, its payload
//!   unescaped, the parsed header and its two reference lists.
//! - `VPEV_DECODE` - its slices are all given: a decoder that decodes a
//!   picture whole decodes it now.
//! - `VPEV_SHOW` - a picture is due: its slot, and when.
//! - `VPEV_FREE` - the stream needs a slot no more.
//!
//! **A slot** names a picture: 0 to the sequence's `slots` minus 1,
//! handed out lowest first by `VPEV_PICTURE` and `VPEV_MISSING`. What the
//! caller keeps of a picture - its samples, a chip's reference surface -
//! it keeps by slot. A slot stays the picture's until the parser said
//! `VPEV_FREE` of it and the caller gave it back (`ReleaseVideoSlot`),
//! once its own use of it is over; a picture shown may still be a
//! reference, and a reference may be read by a decoder's other cores
//! after the stream let go of it. Where no slot is free a new picture
//! waits: VPERR_FULL, and the event is asked for again once one was given
//! back. Every picture also has a number of its own (`uid`) that is never
//! given twice, for telling pictures apart over the reuse of a slot.
//!
//! A pointer an event carries is the parser's, valid until the next call
//! on it.

const utility = @import("../utility/utility.zig");
pub const h264 = @import("h264.zig");
pub const hevc = @import("hevc.zig");

pub const VIDEOPARSENAME = "videoparse.library";

/// A stream being read: the library's own, from `OpenVideoParser`, given
/// back with `CloseVideoParser`.
pub const VideoParser = opaque {};

/// The codecs a parser reads.
pub const VPCODEC_H264: u32 = 1;
pub const VPCODEC_HEVC: u32 = 2;

/// An entry or a reference without a picture.
pub const VP_NO_SLOT: u8 = 0xFF;

// --- the events -------------------------------------------------------------------

pub const VPEV_SEQUENCE: u32 = 1;
pub const VPEV_PICTURE: u32 = 2;
pub const VPEV_SLICE: u32 = 3;
pub const VPEV_DECODE: u32 = 4;
pub const VPEV_MISSING: u32 = 5;
pub const VPEV_SHOW: u32 = 6;
pub const VPEV_FREE: u32 = 7;

/// What `NextVideoEvent` fills in. `slot` and `time` are SHOW's, FREE's
/// and MISSING's; `sequence`, `picture` and `slice` point at what
/// SEQUENCE, PICTURE (and MISSING) and SLICE say, and are null otherwise.
pub const VideoEvent = extern struct {
    kind: u32 = 0,
    slot: u32 = 0,
    time: i64 align(4) = 0,
    sequence: ?*const VideoSequence = null,
    picture: ?*const VideoPicture = null,
    slice: ?*const VideoSlice = null,
};

/// A sequence: what its pictures are.
pub const VideoSequence = extern struct {
    codec: u32 = 0,
    /// The pictures as coded, in samples, and the part of them shown.
    coded_width: u32 = 0,
    coded_height: u32 = 0,
    left: u32 = 0,
    top: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// The pictures the stream's buffer holds, and how many of them may
    /// wait to be shown before the first must be.
    dpb_frames: u32 = 0,
    reorder: u32 = 0,
    /// The slots that may be in use at once: the buffer's, the picture
    /// being decoded, a field waiting for its pair or a missing
    /// reference, and the caller's own (VPA_Slots).
    slots: u32 = 0,
    /// Frames a second as rate_num / rate_den; 0 / 0 where the stream
    /// does not say.
    rate_num: u32 = 0,
    rate_den: u32 = 0,
    bit_depth_luma: u8 = 8,
    bit_depth_chroma: u8 = 8,
    /// 0 grey, 1 4:2:0, 2 4:2:2, 3 4:4:4.
    chroma_format: u8 = 1,
    /// The VUI's: full range, and the colour descriptions (2 where
    /// unspecified).
    full_range: bool = false,
    matrix: u8 = 2,
    colour_primaries: u8 = 2,
    transfer: u8 = 2,
    /// profile_idc and level_idc.
    profile: u8 = 0,
    level: u8 = 0,
    /// The sequence parameter set, of an H.264 stream.
    h264_sps: ?*const h264.H264Sps = null,
    /// The sequence parameter set, of an HEVC stream.
    hevc_sps: ?*const hevc.HevcSps = null,
};

/// A reference picture a picture holds: H.264's buffer before the
/// picture is marked, HEVC's reference picture set once it was applied.
pub const VideoRef = extern struct {
    slot: u8 = VP_NO_SLOT,
    long_term: bool = false,
    /// It stands for a picture the stream lacks (VPEV_MISSING).
    missing: bool = false,
    /// Its fields marked as references: 1 top, 2 bottom, 3 both (3 for
    /// HEVC).
    fields: u8 = 0,
    /// FrameNum, or LongTermFrameIdx for a long-term reference (0 for
    /// HEVC).
    frame_num: u32 = 0,
    /// Its fields' order counts, top and bottom.
    poc: [2]i32 = .{ 0, 0 },
    uid: u32 = 0,
};

/// A picture.
pub const VideoPicture = extern struct {
    slot: u8 = VP_NO_SLOT,
    /// 1 top field, 2 bottom field, 3 frame.
    structure: u8 = 3,
    /// The second field of a pair, in its first field's slot.
    second_field: bool = false,
    /// An IDR picture: nothing before it is referred to.
    idr: bool = false,
    /// It is a reference picture (nal_ref_idc not 0).
    reference: bool = false,
    /// How many of `refs` are filled.
    ref_count: u8 = 0,
    uid: u32 = 0,
    frame_num: u32 = 0,
    /// TopFieldOrderCnt and BottomFieldOrderCnt; a field's other is the
    /// first field's, or its own until the second comes.
    poc: [2]i32 = .{ 0, 0 },
    /// When it is shown, as its packet said.
    time: i64 align(4) = 0,
    /// The parameter sets it is decoded with, of an H.264 stream or of an
    /// HEVC one. They stay as they are until its VPEV_DECODE: a parameter
    /// set that comes ends the picture before it is stored.
    h264_sps: ?*const h264.H264Sps = null,
    h264_pps: ?*const h264.H264Pps = null,
    hevc_sps: ?*const hevc.HevcSps = null,
    hevc_pps: ?*const hevc.HevcPps = null,
    /// HEVC's: nal_unit_type of its slices; an IRAP picture, and its
    /// NoRaslOutputFlag (it begins a sequence: no picture before it is
    /// referred to, and its RASL pictures are passed over).
    nal_type: u8 = 0,
    irap: bool = false,
    no_rasl_output: bool = false,
    /// How many of `refs` each set of its reference picture set holds:
    /// VP_RPS_ST_CURR_BEFORE and the four after it.
    rps_count: [5]u8 = @splat(0),
    /// The bits its slice headers' own st_ref_pic_set( ) took (0 when it
    /// names one of the SPS's).
    st_rps_bits: u32 = 0,
    /// Each set's pictures as indices into `refs`, in the standard's
    /// order (8.3.2): RefPicSetStCurrBefore, RefPicSetStCurrAfter,
    /// RefPicSetStFoll, RefPicSetLtCurr, RefPicSetLtFoll. A picture of a
    /// Foll set the stream lacks is left out; one of a Curr set is a
    /// VPEV_MISSING's.
    rps: [5][16]u8 = @splat(@splat(0)),
    refs: [16]VideoRef = @splat(.{}),
};

/// The sets of an HEVC picture's reference picture set (`rps`).
pub const VP_RPS_ST_CURR_BEFORE: u32 = 0;
pub const VP_RPS_ST_CURR_AFTER: u32 = 1;
pub const VP_RPS_ST_FOLL: u32 = 2;
pub const VP_RPS_LT_CURR: u32 = 3;
pub const VP_RPS_LT_FOLL: u32 = 4;

/// An entry of a slice's reference list.
pub const VideoListEntry = extern struct {
    slot: u8 = VP_NO_SLOT,
    /// What of the picture the entry is: 1 its top field, 2 its bottom
    /// field, 3 the frame or the pair.
    structure: u8 = 3,
    long_term: bool = false,
    uid: u32 = 0,
    /// The picture's fields' order counts, top and bottom.
    poc: [2]i32 = .{ 0, 0 },
};

/// A slice of the picture the last VPEV_PICTURE began.
pub const VideoSlice = extern struct {
    /// The NAL unit as it came, its header included, without a start
    /// code or a length.
    unit: [*]const u8 = undefined,
    unit_bytes: u32 = 0,
    /// The bit the slice data starts at in `rbsp`.
    data_bit: u32 = 0,
    /// Its payload after the header, the emulation prevention bytes taken
    /// out.
    rbsp: [*]const u8 = undefined,
    rbsp_bytes: u32 = 0,
    /// The entries of each list.
    count: [2]u8 = .{ 0, 0 },
    /// HEVC's collocated picture (8.3.5's ColPic): its slot, or
    /// VP_NO_SLOT where the slice has no temporal motion prediction.
    collocated: u8 = VP_NO_SLOT,
    /// Data partitions (H.264's Extended profile): the slice is partition
    /// A, and B's and C's payloads and the bits their data starts at
    /// follow; null where the stream had none of that kind.
    partitioned: bool = false,
    part_b: ?[*]const u8 = null,
    part_b_bytes: u32 = 0,
    part_b_bit: u32 = 0,
    part_c: ?[*]const u8 = null,
    part_c_bytes: u32 = 0,
    part_c_bit: u32 = 0,
    /// The header, of an H.264 stream; the slice segment's, of an HEVC
    /// one.
    h264: ?*const h264.H264SliceHeader = null,
    hevc: ?*const hevc.HevcSliceHeader = null,
    /// RefPicList0 and RefPicList1 as the slice decodes from them, after
    /// their modification.
    lists: [2][33]VideoListEntry = @splat(@splat(.{})),
};

// --- the packets ------------------------------------------------------------------

/// A packet handed to `ParseVideoPacket`: its bytes - units in Annex B
/// form, or each after its length where the setup said so - when it is
/// shown, and VPPKT_* flags.
pub const VideoPacket = extern struct {
    data: ?[*]const u8 = null,
    bytes: u32 = 0,
    flags: u32 = 0,
    time: i64 align(4) = 0,
};

/// The packet is one access unit (an MP4's, a Matroska track's): its
/// picture ends with it.
pub const VPPKT_ACCESS_UNIT: u32 = 1 << 0;
/// The stream ends, with the packet's bytes or without: every picture
/// held is shown, and every slot let go of.
pub const VPPKT_END: u32 = 1 << 1;

// --- OpenVideoParser's tags -----------------------------------------------------

pub const VPA_Dummy = utility.TAG_USER + 0x60F00;
/// Slots the caller keeps beyond the stream's own: pictures it has lent
/// out, or still reads on other cores (u32, default 0, at most 32).
pub const VPA_Slots = VPA_Dummy + 0x01;
/// The largest picture taken, in samples across and down (u32, default
/// 8192 each); a sequence larger is VPERR_UNSUPPORTED.
pub const VPA_MaxWidth = VPA_Dummy + 0x02;
pub const VPA_MaxHeight = VPA_Dummy + 0x03;

// --- errors -------------------------------------------------------------------------

pub const VPERR_OK: i32 = 0;
pub const VPERR_NOMEMORY: i32 = -1;
/// A codec, a profile or a size the library does not read.
pub const VPERR_UNSUPPORTED: i32 = -4;
/// A unit that is not right, passed over; the next event is asked for
/// as before.
pub const VPERR_CORRUPT: i32 = -6;
/// After the stream's end, once everything was said.
pub const VPERR_END: i32 = -8;
/// The packet is read: the next one is wanted.
pub const VPERR_NEED_DATA: i32 = -12;
/// A picture needs a slot and none is free: one is to be given back.
pub const VPERR_FULL: i32 = -13;
