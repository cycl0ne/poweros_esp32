// SPDX-License-Identifier: MIT
//! A sound module for a host test that claims a kind and then refuses
//! every stream of it: WAV, at a priority above wav.acodec's, so the
//! library tries it first and must give the sound to wav.acodec after it
//! - a decoder of its own that turns out not to take this file.

const sdk = @import("sdk");
const exec = sdk.exec;
const ac = sdk.audiocodec;
const acodec = sdk.acodec;
const media = sdk.media;
const module = @import("../acodec_module.zig");

const Stream = acodec.ACodecStream;

/// How often it was asked to open sound: a test sees it was tried first.
pub var asked: u32 = 0;

const Kind = struct {
    /// Nothing is ever kept of a stream: it opens none.
    pub const State = struct { nothing: u32 };

    pub fn open(_: *Stream) i32 {
        asked += 1;
        return ac.ACERR_UNSUPPORTED;
    }

    pub fn openTrack(_: *Stream, _: *const media.MediaTrack) i32 {
        asked += 1;
        return ac.ACERR_UNSUPPORTED;
    }

    pub fn decode(_: *Stream, _: *State, _: [*]i16, _: u32) i32 {
        return ac.ACERR_UNSUPPORTED;
    }

    pub fn seek(_: *Stream, _: *State, _: u32) i32 {
        return ac.ACERR_UNSUPPORTED;
    }
};

pub const Module = module.Module(0, Kind, Kind.State);

pub export const refuse_acodec_tag: acodec.ResidentACodec = .{
    .resident = .{
        .match_tag = @ptrCast(&refuse_acodec_tag),
        .flags = exec.RTF_AUTOINIT,
        .version = 1,
        .type = .library,
        .pri = 0,
        .name = "refuse.acodec",
        .id_string = "refuse.acodec 1.0 (a test's)",
        .init = &Module.init_table,
    },
    .codecs = acodec.codecBit(ac.ACODEC_WAV),
    .priority = 10,
};
