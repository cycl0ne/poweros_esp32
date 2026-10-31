// SPDX-License-Identifier: MIT
//! A codec module's structures (SINCE videocodec 1.4): a decoder of
//! pictures as a library of its own in `LIBS:codecs/`, which
//! videocodec.library finds and chooses for a film's picture track. The
//! calls every module has are in `sdk.interface.vcodec`
//! (sdk/fd/vcodec_lib.fd).
//!
//! **Finding them.** When a film is opened, every file in `LIBS:codecs/`
//! is read for its ROM tag, as usb.library reads `DEVS:usb/`
//! (sdk/libs/dos/loadfile.zig): a library's tag followed by
//! `VCODEC_MAGIC` is a module's, a `ResidentVCodec`, and says which codecs
//! it decodes, whether it is a chip's decoder or software, and its
//! priority. Nothing is loaded for that; a file is read again only when it
//! changed.
//!
//! **Choosing one.** The modules that decode a track's codec are tried
//! in turn - a chip's first, then software, the higher priority first
//! among each - and the first whose `OpenVCodec` takes the track decodes
//! it. One that answers `VCERR_NOCODEC` (the board has not its chip) or
//! another error is closed again and the next is tried. A decoder that
//! finds out only from the stream that it cannot decode it - the WAVE511
//! and 10-bit H.264 - answers `VCERR_UNSUPPORTED` before its first frame,
//! and the next module is given the track again from its key packet.
//!
//! **Decoding.** videocodec reads the track's packets and sends them
//! (`SendVCodecPacket`) whenever the decoder asks for more
//! (`ReceiveVCodecFrame` answering `VCERR_NEED_DATA`); the decoder hands
//! out its frames in the order they are shown, each its own memory lent
//! until `ReleaseVCodecFrame`. A packet's bytes are videocodec's, for the
//! call alone: a decoder copies what it keeps. `FlushVCodec` forgets what
//! was sent, for a seek.
//!
//! **Frames** are as `DecodeVideoFrame` hands them to a program: an
//! `rtg.RtgYuv` in 8 bits, 4:2:0 (NV12 or I420), each plane and each of
//! its rows starting on 16 bytes, where a display's video layer reads them
//! - below 4 GiB on the 64-bit machines where there is room there - and
//! written out of the caches. A frame's `private` is the module's;
//! `number` is videocodec's.

const exec = @import("../exec/exec.zig");
const videocodec = @import("videocodec.zig");

/// Where the modules are.
pub const VCODEC_DIR = "LIBS:codecs";

/// What follows a module's Resident in its ROM tag: "VCOD".
pub const VCODEC_MAGIC: u32 = 0x5643_4F44;

/// `ResidentVCodec.kind`: a chip's decoder, tried before software.
pub const VCMOD_CHIP: u32 = 1;
/// `ResidentVCodec.kind`: decoded by the processor.
pub const VCMOD_SOFTWARE: u32 = 2;

/// The most frames a decoder is asked to lend at once.
pub const VCODEC_MOST_HELD: u32 = 8;

/// A codec module's ROM tag: a library's, with what it decodes after it.
pub const ResidentVCodec = extern struct {
    resident: exec.Resident,
    magic: u32 = VCODEC_MAGIC,
    /// The codecs it decodes, a bit each: `codecBit(VCODEC_H264)`.
    codecs: u32,
    /// VCMOD_CHIP or VCMOD_SOFTWARE.
    kind: u32,
    /// Among the modules of a kind for a codec, the higher is tried first.
    priority: i32 = 0,
};

/// A codec's bit in `ResidentVCodec.codecs`.
pub fn codecBit(codec: u32) u32 {
    return if (codec < 32) @as(u32, 1) << @intCast(codec) else 0;
}

/// A decoder a module opened: the module's own.
pub const VCodecDecoder = opaque {};

/// What `OpenVCodec` is given: the track to decode.
pub const VCodecParams = extern struct {
    /// VCODEC_*.
    codec: u32,
    /// The container's setup for the codec - an MP4's `avcC` or `hvcC`, a
    /// Matroska track's CodecPrivate - or null when it has none; the
    /// caller's for the call alone.
    config: ?[*]const u8 = null,
    config_size: u32 = 0,
    /// The pictures' size as the container says it; 0 when it does not.
    width: u32 = 0,
    height: u32 = 0,
    /// The largest packet, as the container says it; 0 when it does not.
    max_packet: u32 = 0,
    /// How many frames are lent out at once at most, up to
    /// VCODEC_MOST_HELD.
    held: u32 = videocodec.VIDEO_HELD_FRAMES,
};

/// A packet `SendVCodecPacket` is given.
pub const VCodecPacket = extern struct {
    /// Its bytes as the container holds them - for H.264 and H.265 its
    /// units each after its length, as `config` says how long - or null
    /// with VCPKT_END.
    data: ?[*]const u8 = null,
    size: u32 = 0,
    /// When its picture is shown, in microseconds.
    time: i64 align(4) = 0,
    /// VCPKT_*.
    flags: u32 = 0,
};

/// A key packet: a decoder can start at it.
pub const VCPKT_KEY: u32 = 1 << 0;
/// No packet: the track ended, and the frames held back are handed out.
pub const VCPKT_END: u32 = 1 << 1;
/// Its picture is due before the frames that are shown - after a seek -
/// so its frame may be left out; a decoder whose pictures stand alone
/// need not decode it.
pub const VCPKT_DROP: u32 = 1 << 2;

/// What `GetVCodecInfo` says of what a decoder read from the stream.
pub const VCodecInfo = extern struct {
    /// The pictures' size as they are shown - cropped - in pixels.
    width: u32 = 0,
    height: u32 = 0,
    /// Frames a second as `rate_num` / `rate_den`; both 0 when the
    /// stream does not say.
    rate_num: u32 = 0,
    rate_den: u32 = 0,
    /// The bits of a sample in the stream (the frames have 8).
    depth: u32 = 0,
};
