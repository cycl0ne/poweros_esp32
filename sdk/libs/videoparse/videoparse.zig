// SPDX-License-Identifier: MIT
//! videoparse.library's structures and constants: an H.264, HEVC, VP9 or
//! AV1 stream read - its parameter sets, its pictures' slice headers or
//! frame headers, their order counts, the reference pictures each one
//! holds and the lists it decodes from, and the order the pictures are
//! shown in - for a decoder, which decodes the samples. The calls are in
//! `sdk.interface.videoparse`; the syntax structures in
//! `sdk.videoparse.h264`, `sdk.videoparse.hevc`, `sdk.videoparse.vp9` and
//! `sdk.videoparse.av1`.
//!
//! **A parser** (`OpenVideoParser`) is given a track's setup - an MP4's
//! avcC, hvcC or av1C, a Matroska track's CodecPrivate - or nothing, for
//! a stream in Annex B form, and for VP9, whose packets are its frames. A
//! packet is handed over (`ParseVideoPacket`), and what it says is asked
//! for event by event (`NextVideoEvent`) until the parser answers
//! VPERR_NEED_DATA: it reads one unit at a time, as the events are asked
//! for, so the packet's bytes stay the caller's to keep until then.
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
//!   marked; and the light the film was mastered for, as far as the
//!   stream said it.
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
//! **VP9** has no slices, no parameter sets and no reordering: a packet
//! is a frame, or a superframe of several (B.3) - most often a hidden
//! one, a reference for the frames after it, and one shown. Each frame is
//! a VPEV_PICTURE with its header (`vp9`) and the eight reference slots
//! as its references, in their order, a VPEV_SLICE with the frame's
//! bytes whole, VPEV_DECODE, and VPEV_SHOW when it is shown; a frame that
//! only shows a reference (show_existing_frame) is a VPEV_SHOW of that
//! reference's slot alone. VPEV_SEQUENCE comes before the first frame and
//! before one of another size or format.
//!
//! **AV1** has no parameter sets and no reordering either: a packet is a
//! temporal unit, OBUs (5.3) - the sequence header, most often with a key
//! frame, and frames, each its header and its tiles in tile groups. Each
//! frame is a VPEV_PICTURE with its header (`av1`), the sequence header
//! it is read with (`av1_sequence`) and the eight reference slots as its
//! references, in their order; a VPEV_SLICE for each tile, its bytes and
//! its number (`tile`); and VPEV_DECODE after its last tile. A temporal
//! unit shows one frame - of a stream in layers, the last one it shows -
//! with a VPEV_SHOW once the unit has ended, which points at the header
//! the frame is shown with (`picture`): its own, or for a frame shown
//! again (show_existing_frame) the one that shows it, with the film grain
//! it was stored with. VPEV_SEQUENCE comes before the first frame and
//! before one of another size or format. The OBUs of operating point 0
//! are read, the others passed by.
//!
//! A pointer an event carries is the parser's, valid until the next call
//! on it.

const utility = @import("../utility/utility.zig");
pub const h264 = @import("h264.zig");
pub const hevc = @import("hevc.zig");
pub const vp9 = @import("vp9.zig");
pub const av1 = @import("av1.zig");

pub const VIDEOPARSENAME = "videoparse.library";

/// A stream being read: the library's own, from `OpenVideoParser`, given
/// back with `CloseVideoParser`.
pub const VideoParser = opaque {};

/// The codecs a parser reads.
pub const VPCODEC_H264: u32 = 1;
pub const VPCODEC_HEVC: u32 = 2;
/// SINCE 1.1.
pub const VPCODEC_VP9: u32 = 3;
/// SINCE 1.2.
pub const VPCODEC_AV1: u32 = 4;

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
/// SEQUENCE, PICTURE (and MISSING) and SLICE say - and `picture` at the
/// header an AV1 frame is shown with, for its SHOW (SINCE 1.2) - and are
/// null otherwise.
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
    /// 0 grey, 1 4:2:0, 2 4:2:2, 3 4:4:4, 4 4:4:0 (VP9's).
    chroma_format: u8 = 1,
    /// The VUI's: full range, and the colour descriptions (2 where
    /// unspecified).
    full_range: bool = false,
    matrix: u8 = 2,
    colour_primaries: u8 = 2,
    transfer: u8 = 2,
    /// profile_idc and level_idc; VP9's profile, and no level; AV1's
    /// seq_profile and operating point 0's seq_level_idx.
    profile: u8 = 0,
    level: u8 = 0,
    /// The sequence parameter set, of an H.264 stream.
    h264_sps: ?*const h264.H264Sps = null,
    /// The sequence parameter set, of an HEVC stream.
    hevc_sps: ?*const hevc.HevcSps = null,
    /// The sequence header, of an AV1 stream (SINCE 1.2).
    av1: ?*const av1.Av1Sequence = null,
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
    /// The frame header, of a VP9 stream (SINCE 1.1); its eight reference
    /// slots are `refs`, VP_NO_SLOT where one is empty.
    vp9: ?*const vp9.Vp9Header = null,
    /// The frame header, of an AV1 stream, and the sequence header it is
    /// read with (SINCE 1.2); its eight reference slots are `refs`,
    /// VP_NO_SLOT where one is empty.
    av1: ?*const av1.Av1FrameHeader = null,
    av1_sequence: ?*const av1.Av1Sequence = null,
    /// The light the film was mastered for, in candelas a square metre,
    /// as the stream's own messages said it by this picture - H.264's
    /// and HEVC's SEI (the mastering display's colour volume, the
    /// content light level), AV1's metadata OBUs: the mastering display's
    /// maximum, or the film's brightest pixel where that is lower. 0
    /// until one said it; a VP9 stream says nothing of it (SINCE 1.3).
    peak_nits: u16 = 0,
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

/// A slice of the picture the last VPEV_PICTURE began - of a VP9
/// stream, the frame whole; of an AV1 stream, a tile.
pub const VideoSlice = extern struct {
    /// The NAL unit as it came, its header included, without a start
    /// code or a length; a VP9 frame's bytes, its headers included; an
    /// AV1 tile's bytes, without its size.
    unit: [*]const u8 = undefined,
    unit_bytes: u32 = 0,
    /// The bit the slice data starts at in `rbsp` - a VP9 frame's
    /// compressed header.
    data_bit: u32 = 0,
    /// Its payload after the header, the emulation prevention bytes taken
    /// out; a VP9 frame's bytes as they came; an AV1 tile's.
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
    /// An AV1 tile's number, in raster order across the frame's tile
    /// columns (SINCE 1.2).
    tile: u32 = 0,
};

// --- the packets ------------------------------------------------------------------

/// A packet handed to `ParseVideoPacket`: its bytes - units in Annex B
/// form, or each after its length where the setup said so; a VP9 frame or
/// superframe; AV1 OBUs, a temporal unit or part of one - when it is
/// shown, and VPPKT_* flags.
pub const VideoPacket = extern struct {
    data: ?[*]const u8 = null,
    bytes: u32 = 0,
    flags: u32 = 0,
    time: i64 align(4) = 0,
};

/// The packet is one access unit (an MP4's, a Matroska track's): its
/// picture ends with it - an AV1 temporal unit, whose frame is shown
/// then; without the flag, at the next temporal delimiter.
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
