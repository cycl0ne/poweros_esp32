# audiocodec.library

audiocodec.library's functions: sound decoded from what it is coded
in - WAV, MP3, FLAC, Ogg Vorbis - into 16-bit samples, a piece at a
time. Open it with OpenLibrary("audiocodec.library", 1); the
structures are in sdk.audiocodec.

Generated from the source by `./zig build autodoc`.

## Index

- [AudioErrorText](#audioerrortext) - Says what an error code means.
- [CloseAudioStream](#closeaudiostream) - Closes a stream.
- [DecodeAudio](#decodeaudio) - Decodes the next frames of a stream.
- [GetAudioStreamAttrs](#getaudiostreamattrs) - Says what a stream's tags say, each answer where its tag points.
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
- Process: a task will do: the one that has the stream - the one that
  opened it, or one it was handed to (SINCE 1.3) - never two at once.

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
brought to 16 bits, an MP3's frames, a FLAC's blocks, an Ogg Vorbis
stream's packets decoded one at a time and handed out across calls. An
MP3 is cut where its encoder said the music begins and ends, an Ogg
Vorbis stream where its pages' positions say, so a song played after
another follows it without a gap. A FLAC frame that is damaged - its
CRC wrong - is handed out as silence. A read function is asked for the
bytes of the frames handed out and `AUDIO_READ_AHEAD` more at most
(SINCE 1.4 said).

**CONTEXT**

- Waits: yes, on the source when the read-ahead runs low.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a task will do: the one that has the stream - the one that
  opened it, or one it was handed to (SINCE 1.3) - never two at once.

**OWNERSHIP**

`buffer` is the caller's.

**NOTES**

An MP3 frame is 1152 frames of samples at 32 kHz and up, 576 below; a
buffer of a few thousand frames costs the fewest calls. Decoding an
MP3 takes about a tenth of a core at 44.1 kHz in stereo. A FLAC block
is mostly 4096 frames, a Vorbis packet up to 1024. A stream read
through a function (ACA_ReadFunc) calls it on the task that decodes.

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

## GetAudioStreamAttrs

Says what a stream's tags say, each answer where its tag points.

**SYNOPSIS**

```zig
fn GetAudioStreamAttrs(base: *AudioCodecBase, stream: *ac.AudioStream, tags: ?[*]const utility.TagItem) u32
```

**SINCE**

1.1. LVO -48.

**INPUTS**

- `stream`: an open stream.
- `tags`: what is asked, each tag's data the address its answer goes
  to: `ACA_Title`, `ACA_Artist`, `ACA_Album`, `ACA_AlbumArtist`,
  `ACA_Composer`, `ACA_Genre` and `ACA_Comment` a `*[*:0]const u8`;
  `ACA_Year`, `ACA_Track`, `ACA_Tracks` and `ACA_Chapters` a `*u32`;
  `ACA_Picture` a `*?*const ac.AudioPicture`; `ACA_ChapterList` a
  `*?[*]const ac.AudioChapter`.

**RESULT**

How many of the tags it answered; one it does not know is left as it
is and not counted.

**BEHAVIOR**

The answers are what the stream's tags said when it was opened: an
MP3's ID3v2 tag, over an ID3v1 tag at its end, a WAV's INFO list, or
the Vorbis comments of a FLAC or an Ogg Vorbis stream (SINCE 1.2).
A text the tags do not hold is empty, a number 0. The names are whole,
up to 127 characters - the info's are cut at 63 - and a comment up to
255. A genre an MP3 gives by ID3v1's number is named. `ACA_Picture` is
null unless the stream was opened with `ACA_KeepPicture` and its tags
hold a picture: then it is that picture, the front cover where there
are several - an ID3v2 tag's, a FLAC's PICTURE block, an Ogg stream's
METADATA_BLOCK_PICTURE comment. The chapters are an ID3v2 tag's CHAP
frames, each with the title of its own TIT2, or the CHAPTERnnn and
CHAPTERnnnNAME comments, each ending where the next begins - up to 256
of them.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a task will do.

**OWNERSHIP**

Every text, the picture and the chapters are the stream's: read them,
and keep a copy of what is needed after `CloseAudioStream`.

**NOTES**

Texts are Latin-1; a character past it is a `?`.

**BUGS**

None known.

**SEE ALSO**

`OpenAudioStream`, `GetAudioStreamInfo`

**EXAMPLES**

```zig
var genre: [*:0]const u8 = "";
var year: u32 = 0;
var cover: ?*const ac.AudioPicture = null;
_ = acb.GetAudioStreamAttrs(stream, &[_]utility.TagItem{
    .{ .tag = ac.ACA_Genre, .data = @intFromPtr(&genre) },
    .{ .tag = ac.ACA_Year, .data = @intFromPtr(&year) },
    .{ .tag = ac.ACA_Picture, .data = @intFromPtr(&cover) },
    .{},
});
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
frame. A FLAC's is its STREAMINFO's. An Ogg Vorbis file's is its last
page's position, exact; read through a function it is 0. The bit rate
of a FLAC is the average its size and length give, of a Vorbis the
one its header names.

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

ACODEC_WAV, ACODEC_MP3, ACODEC_FLAC, ACODEC_VORBIS, or ACODEC_UNKNOWN.

**BEHAVIOR**

A RIFF header naming WAVE is a WAV. "fLaC" is a FLAC, alone or behind
an ID3v2 tag that ends among the bytes given. An Ogg page whose first
packet is Vorbis's header is ACODEC_VORBIS, FLAC's is ACODEC_FLAC (and
refused when it is opened); another, such as Opus, is unknown. Any
other ID3v2 tag is an MP3, and so are
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
  function) - and `ACA_Codec`, the kind, when the program knows it;
  `ACA_KeepPicture` keeps the picture the tags hold (SINCE 1.1).
- `err`: where to say why it failed (ACERR_*), or null.

**RESULT**

The stream, at its first sample; or null, with `err` set.

**BEHAVIOR**

The stream reads ahead of the decoder into a buffer of its own, and
finds the kind by the first bytes (as `IdentifyAudio`) unless
`ACA_Codec` says. Then the kind's header is read: a WAV's chunks up to
its data, an MP3's tags in front of the sound and its first frame -
with what its encoder wrote about the rest, when it did - a FLAC's
metadata blocks, an Ogg Vorbis stream's three header packets; and the
stream's info is filled in. A read function is asked for the header's
bytes and `AUDIO_READ_AHEAD` more at most. An Ogg Vorbis file's last
page is looked for at its end, for its length. A file's end is looked
at first: tags there (ID3v1, APE) are not read as sound, and an ID3v1
tag's names count where the front says nothing. An ID3v2 tag is read whole, frame by
frame, however large; its picture is read into memory of its own only
with `ACA_KeepPicture` - the front cover, where there are several - and
passed over otherwise. A file can seek; a read function cannot.

**CONTEXT**

- Waits: yes, on the file.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a process for a file (ACA_Name, ACA_FileHandle); a task will
  do with ACA_ReadFunc.

**OWNERSHIP**

The stream is the caller's, given back with `CloseAudioStream`. It may
be handed to another task, which then decodes, moves and closes it
(SINCE 1.3): a program opens the next song - its tags and its cover
read - while the task that decodes plays this one. Two tasks never use
one stream at once. A file opened with ACA_Name is closed with it; a handle given with
ACA_FileHandle stays the program's, and must stay open until then.

**NOTES**

A stream takes about 44 KiB: the read-ahead, the samples of a frame,
an MP3 decoder's state and the tags; a kept picture is as large as it
is. A FLAC adds a block of samples for each channel - 32 KiB for the
usual 4096 in stereo - and an Ogg Vorbis its setup, tables and
buffers: about 250 KiB at 44.1 kHz.

FLAC (SINCE 1.2) is decoded at 4 to 24 bits a sample; an Ogg Vorbis
stream (SINCE 1.2) of floor type 1, as every encoder writes. One or
two channels; more are refused, as is FLAC carried in Ogg. A chained
Ogg file - streams one after another - ends with the first.

**BUGS**

None known.

**SEE ALSO**

`CloseAudioStream`, `DecodeAudio`, `GetAudioStreamInfo`,
`GetAudioStreamAttrs`, `IdentifyAudio`

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

A WAV, a FLAC and an Ogg Vorbis file go to the frame exactly: a FLAC
from its seek table's point before it, or a frame a search halving the
file finds, an Ogg Vorbis from the page a like search finds, decoding
on to the frame. An MP3 goes to the frame its encoder's
table of contents points to, or the bit rate when it has none - exact
for a constant rate, near for a variable one - and the frame or two
after it may be left out, until the reservoir of bits they reach back
into is filled again. Frame 0 is exact for every kind: an MP3 starts
again where its encoder said the music begins (SINCE 1.3).

**CONTEXT**

- Waits: yes, on the file.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a task will do: the one that has the stream - the one that
  opened it, or one it was handed to (SINCE 1.3) - never two at once.

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
