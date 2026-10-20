// SPDX-License-Identifier: MIT
//! rta.library: the sound outputs of this machine, and the drivers that
//! drive them.
//!
//! A sound driver is a module of its own. It registers with AddRtaDriver
//! and makes a **sink** for each output it finds: a codec behind a jack,
//! an amplifier on a speaker, a stream that goes nowhere. A sink has the
//! modes it can run in and a stream of buffers - the caller is signalled
//! each time one has been played, asks for the next with SinkBuffer, fills
//! it and hands it back with PlaySinkBuffer. Nothing above the driver
//! knows what kind of output it feeds; nothing below it knows what is
//! being played.
//!
//! The buffers are always the same thing: 16-bit stereo frames, the left
//! side first, `buffer_frames` of them. A sink whose part wants another
//! width converts them when they are handed back; what the two halves of
//! a frame carry - both sides, one of them, or the two swapped - is its
//! mode's `sides`.
//!
//! Two kinds of thing are registered, as in rtg.library: a **sink**,
//! which is an output, and a **transport**, which is the line a part is
//! fed over - an I2S controller and the DMA ring behind it. A part that
//! takes I2S is a sink on a transport; a stream that makes its own way
//! out needs none.
//!
//! Sound coming in is the same the other way round: a driver makes a
//! **source** for each way in - a codec's microphone input - with modes and
//! a ring of buffers of the same form, which the caller is signalled for
//! each time one has been filled and takes with SourceBuffer. A part that
//! is read over I2S is a source on the transport its sink plays over.
//!
//! audio.device is what plays through a sink; a program opens that, not
//! this. Open it with OpenLibrary(RTANAME, 1); its functions are in
//! sdk/interface/rta.zig.

/// The library's name, for OpenLibrary.
pub const RTANAME = "rta.library";
/// The version a caller of this SDK asks for.
pub const RTA_VERSION = 1;

pub const sinks = @import("sinks.zig");
pub const sources = @import("sources.zig");
pub const transport = @import("transport.zig");
pub const errors = @import("errors.zig");
pub const tags = @import("tags.zig");

pub const RtaBase = @import("../../interface/rta.zig").RtaBase;

// The types and constants flat, so a caller writes rta.AudioSink and not
// rta.sinks.AudioSink.

pub const AudioMode = sinks.AudioMode;
pub const AudioSink = sinks.AudioSink;
pub const AudioSinkOps = sinks.AudioSinkOps;
pub const RtaDriver = sinks.RtaDriver;
pub const RtaDriverOps = sinks.RtaDriverOps;
pub const AudioSource = sources.AudioSource;
pub const AudioSourceOps = sources.AudioSourceOps;
pub const AudioTransport = transport.AudioTransport;
pub const AudioTransportOps = transport.AudioTransportOps;

pub const AUDIOSIDES_LEFT_FIRST = sinks.AUDIOSIDES_LEFT_FIRST;
pub const AUDIOSIDES_RIGHT_FIRST = sinks.AUDIOSIDES_RIGHT_FIRST;
pub const AUDIOSIDES_MONO = sinks.AUDIOSIDES_MONO;
