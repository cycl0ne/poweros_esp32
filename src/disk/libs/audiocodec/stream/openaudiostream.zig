// SPDX-License-Identifier: MIT
//! OpenAudioStream: a stream on sound, its kind found by its first bytes.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ac = sdk.audiocodec;
const utility = sdk.utility;
const AudioCodecBase = @import("../audiocodec_base.zig").AudioCodecBase;
const _stream = @import("_stream.zig");
const Stream = _stream.Stream;
const _identify = @import("../identify/_identify.zig");
const wav = @import("../wav/_wav.zig");
const mp3 = @import("../mp3/_mp3.zig");
const flac = @import("../flac/_flac.zig");
const vorbis = @import("../vorbis/_vorbis.zig");
const aac = @import("../aac/_aac.zig");
const ac3 = @import("../ac3/_ac3.zig");
const opus = @import("../opus/_opus.zig");
const _media = @import("_media.zig");

/// Opens a stream on sound.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenAudioStream(base: *AudioCodecBase, tags: ?[*]const utility.TagItem, err: ?*i32) ?*ac.AudioStream
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `tags`: where the bytes come from - one of `ACA_Name` (a file to
///   open), `ACA_FileHandle` (a file the program has open, read from where
///   it is), `ACA_ReadFunc` with `ACA_ReadData` (the program's own
///   function) or `ACA_Media` (a file media.library has open, SINCE 1.6)
///   - and `ACA_Codec`, the kind, when the program knows it;
///   `ACA_KeepPicture` keeps the picture the tags hold (SINCE 1.1);
///   `ACA_MediaTrack` picks a container's track (SINCE 1.6).
/// - `err`: where to say why it failed (ACERR_*), or null.
///
/// RESULT:
/// The stream, at its first sample; or null, with `err` set:
/// ACERR_UNSUPPORTED too when the disk has no module for the kind
/// (SINCE 1.10).
///
/// BEHAVIOR:
/// A kind's code is a module of its own in LIBS:codecs/, opened until
/// CloseAudioStream (SINCE 1.10): wav.acodec, mp3.acodec, flac.acodec,
/// vorbis.acodec, aac.acodec, ac3.acodec, opus.acodec, dts.acodec (SINCE
/// 1.11).
///
/// Which module decodes a kind comes from the modules' own ROM tags, read
/// out of their files without loading them, and not from their names
/// (SINCE 1.13): a codec is added to a board by dropping its module in
/// LIBS:codecs/. Where a kind has several modules each is tried - a
/// board's own decoder before software, the higher priority first - and
/// one that opens and then refuses the sound is let go and the next is
/// read it from its first byte again (SINCE 1.14); sound read through a
/// function cannot be read again, and keeps the refusal of the module
/// that read it.
///
/// The stream reads ahead of the decoder into a buffer of its own, and
/// finds the kind by the first bytes (as `IdentifyAudio`) unless
/// `ACA_Codec` says - an Ogg stream by its first page all the same, Vorbis
/// or Opus (SINCE 1.9). Then the kind's header is read: a WAV's chunks up to
/// its data, an MP3's tags in front of the sound and its first frame -
/// with what its encoder wrote about the rest, when it did - a FLAC's
/// metadata blocks, an Ogg Vorbis stream's three header packets, an AAC
/// stream's first ADTS frame, an AC-3 or E-AC-3 stream's first syncframe
/// (SINCE 1.8), an Ogg Opus stream's head and comments (SINCE 1.9) - or a
/// container's, an MP4's index or a Matroska file's header, read by
/// media.library (SINCE 1.6; Matroska SINCE 1.7), which the stream then
/// reads its track's packets from: AAC, SINCE 1.7 MP3, FLAC and Vorbis,
/// SINCE 1.8 AC-3 and E-AC-3, SINCE 1.9 Opus. A container is known by
/// its first bytes whatever `ACA_Codec` says. Then the stream's info is
/// filled in.
/// A read function is asked for the header's
/// bytes and `AUDIO_READ_AHEAD` more at most. An Ogg file's last page is
/// looked for at its end, for its length. A file's end is looked
/// at first: tags there (ID3v1, APE) are not read as sound, and an ID3v1
/// tag's names count where the front says nothing. An ID3v2 tag is read whole, frame by
/// frame, however large; its picture is read into memory of its own only
/// with `ACA_KeepPicture` - the front cover, where there are several - and
/// passed over otherwise. A file can seek; a read function cannot.
///
/// CONTEXT:
/// - Waits: yes, on the file.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a process for a file (ACA_Name, ACA_FileHandle); a task will
///   do with ACA_ReadFunc.
///
/// OWNERSHIP:
/// The stream is the caller's, given back with `CloseAudioStream`. It may
/// be handed to another task, which then decodes, moves and closes it
/// (SINCE 1.3): a program opens the next song - its tags and its cover
/// read - while the task that decodes plays this one. Two tasks never use
/// one stream at once. A file opened with ACA_Name is closed with it; a handle given with
/// ACA_FileHandle stays the program's, and must stay open until then.
///
/// NOTES:
/// A stream takes about 44 KiB: the read-ahead, the samples of a frame,
/// an MP3 decoder's state and the tags; a kept picture is as large as it
/// is. A FLAC adds a block of samples for each channel - 32 KiB for the
/// usual 4096 in stereo - and an Ogg Vorbis its setup, tables and
/// buffers: about 250 KiB at 44.1 kHz; AC-3 about 80 KiB; Opus about
/// 120 KiB, and 60 KiB more for each stream a packet of more channels
/// holds - 370 KiB for 5.1. A container
/// adds what media.library holds of it: an MP4's index, a Matroska
/// track's 256 KiB read ahead.
///
/// FLAC (SINCE 1.2) is decoded at 4 to 24 bits a sample; an Ogg Vorbis
/// stream (SINCE 1.2) of floor type 1, as every encoder writes. One or
/// two channels; more are refused, as is FLAC carried in Ogg. A chained
/// Ogg file - streams one after another - is played link by link.
///
/// Opus (SINCE 1.9) is decoded at 48 kHz, whatever rate its head says it
/// was recorded at, its output gain applied: one stream of one or two
/// channels, or up to eight channels in Vorbis's order (mapping family 1)
/// mixed into stereo - the centre and surrounds at -3 dB, the LFE left
/// out, scaled never to be louder than the loudest channel - and the
/// peaks bent below full scale. Its length and seeks are exact; a seek
/// decodes from 160 ms before the frame asked for, and the samples after
/// it are near those decoding straight through gave. A packet that will not
/// decode is concealed for as long as it plays.
///
/// AC-3 and E-AC-3 (SINCE 1.8) of any channels are mixed into stereo as
/// FFmpeg mixes them - the stream's centre and surround levels, the LFE
/// left out, never clipping - and its dynamic range words applied; a
/// mono stream stays one channel, dual mono plays both. E-AC-3 plays its
/// first program's 5.1: the frames that add channels past it, and other
/// programs, are passed over; a stream at a reduced rate (24 kHz and
/// below) or with enhanced coupling is silent. A frame whose CRC is wrong
/// is silence for its length. A file's length is worked out from the
/// frames' bytes, and a seek in one lands on its frame; a seek's first
/// samples differ from those decoding through gave by the noise the
/// stream asks for in bits it codes with none.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseAudioStream`, `DecodeAudio`, `GetAudioStreamInfo`,
/// `GetAudioStreamAttrs`, `IdentifyAudio`
///
/// EXAMPLES:
/// ```zig
/// var err: i32 = 0;
/// const stream = acb.OpenAudioStream(&[_]utility.TagItem{
///     .{ .tag = ac.ACA_Name, .data = @intFromPtr("SD0:Music/song.mp3") },
///     .{},
/// }, &err) orelse return;
/// defer acb.CloseAudioStream(stream);
/// ```
pub fn OpenAudioStream(base: *AudioCodecBase, tags: ?[*]const utility.TagItem, err: ?*i32) ?*ac.AudioStream {
    const sys = base.sys_base;
    const ub = base.utility_base;
    const dl = base.dos_base;
    const name: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(ac.ACA_Name, 0, tags));
    const handle: ?*dos.FileHandle = @ptrFromInt(ub.GetTagData(ac.ACA_FileHandle, 0, tags));
    const read_fn: ?ac.ReadFn = @ptrFromInt(ub.GetTagData(ac.ACA_ReadFunc, 0, tags));
    const read_data: ?*anyopaque = @ptrFromInt(ub.GetTagData(ac.ACA_ReadData, 0, tags));
    const hint: u32 = @truncate(ub.GetTagData(ac.ACA_Codec, ac.ACODEC_UNKNOWN, tags));
    const keep_picture = ub.GetTagData(ac.ACA_KeepPicture, 0, tags) != 0;
    const media_file: ?*sdk.media.MediaFile = @ptrFromInt(ub.GetTagData(ac.ACA_Media, 0, tags));
    const track: u32 = @truncate(ub.GetTagData(ac.ACA_MediaTrack, ~@as(u32, 0), tags));

    // Cleared: every field of a stream starts at zero.
    const memory = sys.AllocVec(@sizeOf(Stream), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return failed(err, ac.ACERR_NOMEMORY);
    const stream: *Stream = @ptrCast(@alignCast(memory));
    stream.layout = sdk.acodec.ACODEC_LAYOUT;
    stream.base = .{ .sys_base = sys, .dos_base = dl, .utility_base = ub };
    stream.tags.keep_picture = keep_picture;

    if (name) |path| {
        stream.file = dl.Open(path, dos.MODE_OLDFILE) orelse {
            sys.FreeVec(memory);
            return failed(err, ac.ACERR_OPEN);
        };
        stream.owns_file = true;
        _stream.scanTail(stream);
    } else if (handle) |file| {
        stream.file = file;
        const here = dl.Seek(file, 0, dos.OFFSET_CURRENT);
        _stream.scanTail(stream);
        if (here > 0) _ = _stream.seekSource(stream, @intCast(here));
    } else if (read_fn) |read| {
        stream.read_fn = read;
        stream.read_data = read_data;
    } else if (media_file) |file| {
        // A track of a file media.library has open: no bytes of its own.
        const result = _media.openGiven(base, stream, file, track);
        if (result != ac.ACERR_OK) {
            _stream.destroy(stream);
            return failed(err, result);
        }
        _stream.nameInfo(stream);
        if (err) |out| out.* = ac.ACERR_OK;
        return _stream.publicOf(stream);
    } else {
        sys.FreeVec(memory);
        return failed(err, ac.ACERR_OPEN);
    }
    stream.info.seekable = @intFromBool(stream.file != null);
    stream.media_track = track;

    _stream.fill(stream);
    const bytes = _stream.available(stream);
    // A container is read through media.library, whatever it holds; an
    // Ogg stream's first page says what it carries - a station's
    // "audio/ogg" may be Vorbis or Opus.
    var codec = hint;
    if (_media.container(bytes)) {
        codec = ac.ACODEC_UNKNOWN;
    } else if (hint == ac.ACODEC_UNKNOWN or _stream.same(bytes, "OggS")) {
        const found = _identify.identify(bytes);
        if (found != ac.ACODEC_UNKNOWN or hint == ac.ACODEC_UNKNOWN) codec = found;
    }
    const result = if (_media.container(bytes)) _media.open(base, stream) else openKind(base, stream, codec);
    if (result != ac.ACERR_OK) {
        _stream.destroy(stream);
        return failed(err, result);
    }
    _stream.nameInfo(stream);
    if (err) |out| out.* = ac.ACERR_OK;
    return _stream.publicOf(stream);
}

/// The stream's bytes opened by the module that decodes their kind:
/// ACERR_UNKNOWN when the bytes are not sound this library knows,
/// ACERR_UNSUPPORTED when they are a kind no module on this disk decodes.
///
/// Every module of the kind is tried, in the order their tags put them -
/// a board's own decoder before software, the higher priority first
/// (SINCE 1.14). A module that opens and then refuses the sound is let go
/// and the next is given it, from the first byte again; the error answered
/// is the first that was not plain ACERR_UNSUPPORTED - "not mine". Only a
/// file can be read again: sound read through a function keeps the refusal
/// of the module that read it, as a film's pictures do.
fn openKind(base: *AudioCodecBase, stream: *Stream, codec: u32) i32 {
    if (codec == ac.ACODEC_UNKNOWN) return if (stream.failed) ac.ACERR_READ else ac.ACERR_UNKNOWN;
    const info = stream.info;
    const from = _stream.tell(stream);
    var tried: u32 = 0;
    var why: i32 = ac.ACERR_UNSUPPORTED;
    while (_stream.openNextModule(base, stream, codec, &tried)) |module| {
        const result = module.OpenACodec(stream);
        if (result == ac.ACERR_OK) return ac.ACERR_OK;
        if (why == ac.ACERR_UNSUPPORTED) why = result;
        _stream.dropModule(base, stream, info);
        if (!_stream.seekSource(stream, from)) return result;
        _stream.fill(stream);
    }
    return why;
}

fn failed(err: ?*i32, code: i32) ?*ac.AudioStream {
    if (err) |out| out.* = code;
    return null;
}
