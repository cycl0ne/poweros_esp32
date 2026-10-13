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
///   it is) or `ACA_ReadFunc` with `ACA_ReadData` (the program's own
///   function) - and `ACA_Codec`, the kind, when the program knows it;
///   `ACA_KeepPicture` keeps the picture the tags hold (SINCE 1.1).
/// - `err`: where to say why it failed (ACERR_*), or null.
///
/// RESULT:
/// The stream, at its first sample; or null, with `err` set.
///
/// BEHAVIOR:
/// The stream reads ahead of the decoder into a buffer of its own, and
/// finds the kind by the first bytes (as `IdentifyAudio`) unless
/// `ACA_Codec` says. Then the kind's header is read: a WAV's chunks up to
/// its data, an MP3's tags in front of the sound and its first frame -
/// with what its encoder wrote about the rest, when it did - and the
/// stream's info is filled in. A file's end is looked at first: tags there
/// (ID3v1, APE) are not read as sound, and an ID3v1 tag's names count
/// where the front says nothing. An ID3v2 tag is read whole, frame by
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
/// The stream is the caller's, given back with `CloseAudioStream`. A file
/// opened with ACA_Name is closed with it; a handle given with
/// ACA_FileHandle stays the program's, and must stay open until then.
///
/// NOTES:
/// A stream takes about 44 KiB: the read-ahead, the samples of a frame,
/// an MP3 decoder's state and the tags; a kept picture is as large as it
/// is.
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

    // Cleared: every field of a stream starts at zero.
    const memory = sys.AllocVec(@sizeOf(Stream), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return failed(err, ac.ACERR_NOMEMORY);
    const stream: *Stream = @ptrCast(@alignCast(memory));
    stream.base = base;
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
    } else {
        sys.FreeVec(memory);
        return failed(err, ac.ACERR_OPEN);
    }
    stream.info.seekable = @intFromBool(stream.file != null);

    _stream.fill(stream);
    const codec = if (hint != ac.ACODEC_UNKNOWN) hint else _identify.identify(_stream.available(stream));
    const result = switch (codec) {
        ac.ACODEC_WAV => wav.open(stream),
        ac.ACODEC_MP3 => mp3.open(stream),
        else => if (stream.failed) ac.ACERR_READ else ac.ACERR_UNKNOWN,
    };
    if (result != ac.ACERR_OK) {
        _stream.destroy(stream);
        return failed(err, result);
    }
    _stream.nameInfo(stream);
    if (err) |out| out.* = ac.ACERR_OK;
    return _stream.publicOf(stream);
}

fn failed(err: ?*i32, code: i32) ?*ac.AudioStream {
    if (err) |out| out.* = code;
    return null;
}
