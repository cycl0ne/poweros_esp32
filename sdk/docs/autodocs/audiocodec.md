# audiocodec.library

audiocodec.library's functions: sound decoded from what it is coded
in - WAV, MP3 - into 16-bit samples, a piece at a time. Open it with
OpenLibrary("audiocodec.library", 1); the structures are in
sdk.audiocodec.

Generated from the source by `./zig build autodoc`.

## Index

- [AudioErrorText](#audioerrortext) - Says what an error code means.
- [CloseAudioStream](#closeaudiostream) - Closes a stream.
- [DecodeAudio](#decodeaudio) - Decodes the next frames of a stream.
- [GetAudioStreamInfo](#getaudiostreaminfo) - Says what a stream is.
- [IdentifyAudio](#identifyaudio) - Says what some sound is.
- [OpenAudioStream](#openaudiostream) - Opens a stream on sound.
- [SeekAudio](#seekaudio) - Moves a stream to a frame.

## AudioErrorText

Says what an error code means.

**SYNOPSIS**

```zig
fn AudioErrorText(base: *AudioCodecBase, code: i32) [*:0]const u8
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `code`: an ACERR_*.

**RESULT**

A sentence for a person, never null: "unknown error" for a code the
library does not have.

**BEHAVIOR**

None beyond the result.

**CONTEXT**

- Waits: no.
- Interrupts: yes.
- Locks: none.
- Process: a task will do.

**OWNERSHIP**

The text is the library's, and does not change.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`OpenAudioStream`, `DecodeAudio`, `SeekAudio`

**EXAMPLES**

```zig
_ = Printf(dl, "%s\n", .{acb.AudioErrorText(err)});
```

## CloseAudioStream

Closes a stream.

**SYNOPSIS**

```zig
fn CloseAudioStream(base: *AudioCodecBase, stream: ?*ac.AudioStream) void
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `stream`: what OpenAudioStream made, or null.

**RESULT**

None.

**BEHAVIOR**

A file the stream opened (ACA_Name) is closed; the stream is freed.

**CONTEXT**

- Waits: yes, on the file it closes.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the stream.

**OWNERSHIP**

The stream is gone after the call. A handle the program gave
(ACA_FileHandle) is still the program's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`OpenAudioStream`

**EXAMPLES**

```zig
acb.CloseAudioStream(stream);
```

## DecodeAudio

Decodes the next frames of a stream.

**SYNOPSIS**

```zig
fn DecodeAudio(base: *AudioCodecBase, stream: *ac.AudioStream, buffer: [*]i16, frames: u32) i32
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `stream`: an open stream.
- `buffer`: room for `frames` frames: a sample a channel, the channels
  interleaved, left first.
- `frames`: how many frames are wanted.

**RESULT**

How many frames went into `buffer`: `frames` until the end comes, then
fewer, then 0. Below 0 an ACERR_* - the source would not be read.

**BEHAVIOR**

The samples are signed 16-bit, at the rate and channels
GetAudioStreamInfo gives, whatever the file holds: a WAV's samples
brought to 16 bits, an MP3's frames decoded one at a time and handed
out across calls. An MP3 is cut where its encoder said the music begins
and ends, so a song played after another follows it without a gap.

**CONTEXT**

- Waits: yes, on the source when the read-ahead runs low.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the stream.

**OWNERSHIP**

`buffer` is the caller's.

**NOTES**

An MP3 frame is 1152 frames of samples at 32 kHz and up, 576 below; a
buffer of a few thousand frames costs the fewest calls. Decoding an
MP3 takes about a tenth of a core at 44.1 kHz in stereo.

**BUGS**

None known.

**SEE ALSO**

`OpenAudioStream`, `SeekAudio`, `GetAudioStreamInfo`

**EXAMPLES**

```zig
var samples: [4096 * 2]i16 = undefined;
const got = acb.DecodeAudio(stream, &samples, 4096);
if (got <= 0) return; // the end, or an error
```

## GetAudioStreamInfo

Says what a stream is.

**SYNOPSIS**

```zig
fn GetAudioStreamInfo(base: *AudioCodecBase, stream: *ac.AudioStream, info: *ac.AudioStreamInfo) void
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `stream`: an open stream.
- `info`: filled in.

**RESULT**

None.

**BEHAVIOR**

The kind, the rate and channels of the samples DecodeAudio hands out,
the bits a sample has in the file, the bit rate, whether the stream can
seek, the length in frames, and the title, artist and album its tags
name. An MP3's length is exact when its encoder wrote it down (a Xing
or Info frame), worked out from its bit rate and the file's size
otherwise, and 0 for a stream read through a function without that
frame.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a task will do.

**OWNERSHIP**

`info` is the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`OpenAudioStream`, `DecodeAudio`

**EXAMPLES**

```zig
var info: ac.AudioStreamInfo = .{};
acb.GetAudioStreamInfo(stream, &info);
// a stream of AUDIO_S16 for audio.device at info.rate, info.channels
```

## IdentifyAudio

Says what some sound is.

**SYNOPSIS**

```zig
fn IdentifyAudio(base: *AudioCodecBase, bytes: [*]const u8, length: u32) u32
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `bytes`, `length`: the first bytes of it - `AUDIO_IDENTIFY_BYTES` are
  enough.

**RESULT**

ACODEC_WAV, ACODEC_MP3, or ACODEC_UNKNOWN.

**BEHAVIOR**

A RIFF header naming WAVE is a WAV. An ID3v2 tag is an MP3, and so are
MPEG audio frames: a header that can be, followed by others at the
distances it gives - one header-like run of bytes alone is not enough.
An MP3 of layer I or II is identified as one, and refused when it is
opened.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a task will do.

**OWNERSHIP**

None.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`OpenAudioStream`

**EXAMPLES**

```zig
if (acb.IdentifyAudio(&head, got) == ac.ACODEC_UNKNOWN) return;
```

## OpenAudioStream

Opens a stream on sound.

**SYNOPSIS**

```zig
fn OpenAudioStream(base: *AudioCodecBase, tags: ?[*]const utility.TagItem, err: ?*i32) ?*ac.AudioStream
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `tags`: where the bytes come from - one of `ACA_Name` (a file to
  open), `ACA_FileHandle` (a file the program has open, read from where
  it is) or `ACA_ReadFunc` with `ACA_ReadData` (the program's own
  function) - and `ACA_Codec`, the kind, when the program knows it.
- `err`: where to say why it failed (ACERR_*), or null.

**RESULT**

The stream, at its first sample; or null, with `err` set.

**BEHAVIOR**

The stream reads ahead of the decoder into a buffer of its own, and
finds the kind by the first bytes (as `IdentifyAudio`) unless
`ACA_Codec` says. Then the kind's header is read: a WAV's chunks up to
its data, an MP3's tags in front of the sound and its first frame -
with what its encoder wrote about the rest, when it did - and the
stream's info is filled in. A file's end is looked at first: tags there
(ID3v1, APE) are not read as sound, and an ID3v1 tag's names count
where the front says nothing. A file can seek; a read function cannot.

**CONTEXT**

- Waits: yes, on the file.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a process for a file (ACA_Name, ACA_FileHandle); a task will
  do with ACA_ReadFunc.

**OWNERSHIP**

The stream is the caller's, given back with `CloseAudioStream`. A file
opened with ACA_Name is closed with it; a handle given with
ACA_FileHandle stays the program's, and must stay open until then.

**NOTES**

A stream takes about 42 KiB: the read-ahead, the samples of a frame,
and an MP3 decoder's state.

**BUGS**

None known.

**SEE ALSO**

`CloseAudioStream`, `DecodeAudio`, `GetAudioStreamInfo`, `IdentifyAudio`

**EXAMPLES**

```zig
var err: i32 = 0;
const stream = acb.OpenAudioStream(&[_]utility.TagItem{
    .{ .tag = ac.ACA_Name, .data = @intFromPtr("SD0:Music/song.mp3") },
    .{},
}, &err) orelse return;
defer acb.CloseAudioStream(stream);
```

## SeekAudio

Moves a stream to a frame.

**SYNOPSIS**

```zig
fn SeekAudio(base: *AudioCodecBase, stream: *ac.AudioStream, frame: u32) i32
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `stream`: an open stream on a file.
- `frame`: the frame to go on from, counted from 0.

**RESULT**

0, or an ACERR_*: ACERR_NOSEEK for a stream read through a function.

**BEHAVIOR**

A WAV goes to the frame exactly. An MP3 goes to the frame its encoder's
table of contents points to, or the bit rate when it has none - exact
for a constant rate, near for a variable one - and the frame or two
after it may be left out, until the reservoir of bits they reach back
into is filled again.

**CONTEXT**

- Waits: yes, on the file.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the stream.

**OWNERSHIP**

None.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`DecodeAudio`, `GetAudioStreamInfo`

**EXAMPLES**

```zig
_ = acb.SeekAudio(stream, info.rate * 30); // half a minute in
```
