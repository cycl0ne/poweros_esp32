# vcodec

A codec module's functions (SINCE videocodec 1.4): what
videocodec.library calls a decoder of pictures in LIBS:codecs/ with,
after a module's tag in its file said it decodes the track's codec.
Every module has them (sdk/libs/videocodec/vcodec.zig); the base is
the module's, opened with OpenLibrary("codecs/<file>"). One task calls
a decoder at a time - the one that decodes the film's pictures.

Generated from the source by `./zig build autodoc`.

## Index

- [CloseVCodec](#closevcodec) - The decoder closed, its memory freed - and the frames it still has lent, which may not be shown after.
- [FlushVCodec](#flushvcodec) - Everything sent and not yet handed out forgotten, for a seek: the next packet is a key packet, and the frames lent stay lent.
- [GetVCodecInfo](#getvcodecinfo) - What the decoder read from the stream, into `info`: 0, or VCERR_NEED_DATA while it has read nothing to say it from.
- [OpenVCodec](#openvcodec) - A decoder for a track, or null and why in `err`: VCERR_NOCODEC when this module cannot decode it here - the board has not its chip, or the codec is not one of its own - VCERR_BUSY when its chip runs no more, VCERR_UNSUPPORTED, VCERR_CORRUPT for a setup it cannot read, VCERR_NOMEMORY.
- [ReceiveVCodecFrame](#receivevcodecframe) - The next frame in the order frames are shown, into `frame`: 0; VCERR_NEED_DATA when the decoder wants a packet first; VCERR_END after the last frame, once the end was sent; VCERR_UNSUPPORTED for a stream it turns out it cannot decode - before its first frame, the next module is given the track; VCERR_CORRUPT for a picture it stopped on, which it is called again after; VCERR_BUSY with `held` frames lent; VCERR_NOMEMORY.
- [ReleaseVCodecFrame](#releasevcodecframe) - A frame the decoder lent given back, as ReceiveVCodecFrame filled it in; frames come back in any order.
- [SendVCodecPacket](#sendvcodecpacket) - A packet of the track in, or its end (VCPKT_END): 0, or VCERR_FULL when it has no room for it yet - a frame is to be taken (ReceiveVCodecFrame) and the packet sent again - or VCERR_NOMEMORY, VCERR_CORRUPT.

## CloseVCodec

The decoder closed, its memory freed - and the frames it still has lent, which may not be shown after.

**SYNOPSIS**

```zig
void CloseVCodec(?*vcodec.VCodecDecoder decoder)
```

## FlushVCodec

Everything sent and not yet handed out forgotten, for a seek: the next packet is a key packet, and the frames lent stay lent.

**SYNOPSIS**

```zig
void FlushVCodec(*vcodec.VCodecDecoder decoder)
```

## GetVCodecInfo

What the decoder read from the stream, into `info`: 0, or VCERR_NEED_DATA while it has read nothing to say it from.

**SYNOPSIS**

```zig
i32 GetVCodecInfo(*vcodec.VCodecDecoder decoder, *vcodec.VCodecInfo info)
```

**BEHAVIOR**

The size is the pictures' as they are shown, cropped; the rate 0 / 0
when the stream does not say it. A task will do; it does not wait.

## OpenVCodec

A decoder for a track, or null and why in `err`: VCERR_NOCODEC when this module cannot decode it here - the board has not its chip, or the codec is not one of its own - VCERR_BUSY when its chip runs no more, VCERR_UNSUPPORTED, VCERR_CORRUPT for a setup it cannot read, VCERR_NOMEMORY.

**SYNOPSIS**

```zig
?*vcodec.VCodecDecoder OpenVCodec(*const vcodec.VCodecParams params, ?*i32 err)
```

**BEHAVIOR**

`params` and what it points at are the caller's for the call alone. On a
process: a chip's decoder may load its firmware.

## ReceiveVCodecFrame

The next frame in the order frames are shown, into `frame`: 0; VCERR_NEED_DATA when the decoder wants a packet first; VCERR_END after the last frame, once the end was sent; VCERR_UNSUPPORTED for a stream it turns out it cannot decode - before its first frame, the next module is given the track; VCERR_CORRUPT for a picture it stopped on, which it is called again after; VCERR_BUSY with `held` frames lent; VCERR_NOMEMORY.

**SYNOPSIS**

```zig
i32 ReceiveVCodecFrame(*vcodec.VCodecDecoder decoder, *videocodec.VideoFrame frame)
```

**BEHAVIOR**

The frame's planes are the decoder's, lent until ReleaseVCodecFrame, its
`time` the packet's that made it, its `private` the decoder's.

## ReleaseVCodecFrame

A frame the decoder lent given back, as ReceiveVCodecFrame filled it in; frames come back in any order.

**SYNOPSIS**

```zig
void ReleaseVCodecFrame(*vcodec.VCodecDecoder decoder, *videocodec.VideoFrame frame)
```

## SendVCodecPacket

A packet of the track in, or its end (VCPKT_END): 0, or VCERR_FULL when it has no room for it yet - a frame is to be taken (ReceiveVCodecFrame) and the packet sent again - or VCERR_NOMEMORY, VCERR_CORRUPT.

**SYNOPSIS**

```zig
i32 SendVCodecPacket(*vcodec.VCodecDecoder decoder, *const vcodec.VCodecPacket packet)
```

**BEHAVIOR**

The bytes are the caller's for the call alone: the decoder copies what
it keeps. A packet marked VCPKT_DROP is due before what is shown, and
may be decoded only as far as later pictures need it.
