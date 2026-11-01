# acodec

A sound module's functions (SINCE audiocodec 1.10): what
audiocodec.library calls a kind of sound's code in LIBS:codecs/ with
(sdk/libs/audiocodec/acodec.zig); the base is the module's, opened with
OpenLibrary("codecs/<kind>.acodec"). A stream is read and decoded by
whichever task has it, one at a time. A module answers ACERR_UNSUPPORTED
to a stream whose layout is not its own.

Generated from the source by `./zig build autodoc`.

## Index

- [CloseACodec](#closeacodec) - What the module holds of the stream given back, if it made anything: after a failed open too.
- [DecodeACodec](#decodeacodec) - Up to `frames` frames of samples into `out`, the channels interleaved: how many, 0 at the end, ACERR_* below 0.
- [OpenACodec](#openacodec) - The stream's source read from where it is: its headers and tags, the info filled in, and the stream at its first sound: 0, or ACERR_* for bytes it cannot decode.
- [OpenACodecTrack](#openacodectrack) - A track of the stream's container: the codec's setup from `track`, the info filled in; packets come through `stream.media`.
- [SeekACodec](#seekacodec) - The stream moved so that the next frame decoded is `frame`: 0, or ACERR_*.

## CloseACodec

What the module holds of the stream given back, if it made anything: after a failed open too.

**SYNOPSIS**

```zig
void CloseACodec(*acodec.ACodecStream stream)
```

**BEHAVIOR**

The stream, its file and its tags stay the library's.

## DecodeACodec

Up to `frames` frames of samples into `out`, the channels interleaved: how many, 0 at the end, ACERR_* below 0.

**SYNOPSIS**

```zig
i32 DecodeACodec(*acodec.ACodecStream stream, [*]i16 out, u32 frames)
```

## OpenACodec

The stream's source read from where it is: its headers and tags, the info filled in, and the stream at its first sound: 0, or ACERR_* for bytes it cannot decode.

**SYNOPSIS**

```zig
i32 OpenACodec(*acodec.ACodecStream stream)
```

**BEHAVIOR**

On what opened the stream, which it reads.

## OpenACodecTrack

A track of the stream's container: the codec's setup from `track`, the info filled in; packets come through `stream.media`.

**SYNOPSIS**

```zig
i32 OpenACodecTrack(*acodec.ACodecStream stream, *const media.MediaTrack track)
```

**BEHAVIOR**

0, or ACERR_*; ACERR_UNSUPPORTED from a kind no container carries.
`track` is the caller's for the call alone.

## SeekACodec

The stream moved so that the next frame decoded is `frame`: 0, or ACERR_*.

**SYNOPSIS**

```zig
i32 SeekACodec(*acodec.ACodecStream stream, u32 frame)
```

**BEHAVIOR**

What it held decoded is dropped by the library.
