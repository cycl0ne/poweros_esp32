# videodec.resource

videodec.resource's functions: the chip's video decoder, a stream fed
a picture at a time and its frames handed out in the order they are
shown (sdk/resources/videodec.zig). A resource: no Open or Close, its
first function in the first slot. The base comes from
OpenResource("videodec.resource").

Generated from the source by `./zig build autodoc`.

## Index

- [CloseVideoDecoder](#closevideodecoder) - Closes a decoder OpenVideoDecoder made.
- [DecodeVideoFrame](#decodevideoframe) - Hands out a decoder's next frame, decoding as many pictures as that takes.
- [FeedVideoDecoder](#feedvideodecoder) - Feeds a decoder one picture of its stream.
- [FlushVideoDecoder](#flushvideodecoder) - Drops what a decoder was fed and has not shown yet, for a seek.
- [GetVideoDecoderInfo](#getvideodecoderinfo) - Says what a decoder's stream is, once its sequence is read.
- [OpenVideoDecoder](#openvideodecoder) - Opens a decoder for one of the chip's codecs.
- [ReleaseVideoFrame](#releasevideoframe) - Gives a frame DecodeVideoFrame handed out back to the decoder.
- [VideoDecCodecs](#videodeccodecs) - Says which codecs the chip's decoder takes.

## CloseVideoDecoder

Closes a decoder OpenVideoDecoder made.

**SYNOPSIS**

```zig
fn CloseVideoDecoder(vb: *VideoDecBase, decoder: ?*VideoDecoder) void
```

**SINCE**

1.0. LVO -12.

**INPUTS**

- `decoder` - the decoder; null is left alone.

**RESULT**

Nothing.

**BEHAVIOR**

A picture the chip is still decoding for it is waited for, what is
queued dropped, its instance ended on the chip, and its memory freed -
the stream's ring, the work buffer and every frame. The chip itself
keeps running, for the next decoder.

**CONTEXT**

- Waits: yes, for the chip. - Interrupts: no.
- Locks: the resource's, around the chip. - Process: a Task will do.

**OWNERSHIP**

The decoder is gone, and so are the frames it handed out, given back
or not: nothing may read them afterwards.

**NOTES**

When the chip will not end the instance, its memory is kept, as the
chip may still write into it.

**BUGS**

None known.

**SEE ALSO**

`OpenVideoDecoder`

**EXAMPLES**

```zig
defer vb.CloseVideoDecoder(decoder);
```

## DecodeVideoFrame

Hands out a decoder's next frame, decoding as many pictures as that takes.

**SYNOPSIS**

```zig
fn DecodeVideoFrame(vb: *VideoDecBase, decoder: *VideoDecoder,
    frame: *VideoDecFrame) u32
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `decoder` - the decoder.
- `frame` - filled in.

**RESULT**

VDERR_OK, and `frame` holds the next frame to be shown (see
VideoDecFrame), lent until ReleaseVideoFrame. Otherwise `frame` is
left as it was, and: VDERR_NEED_DATA when every picture fed is decoded
and none is due yet - feed more; VDERR_END when the stream was ended
and its last frame handed out; VDERR_FULL when every frame buffer is
lent - give some back; VDERR_UNSUPPORTED for a stream the chip does
not take (10-bit H.264, too large, changing its size); VDERR_NO_MEMORY for
its frames; VDERR_CORRUPT when the chip stopped on the stream or did
not answer in half a second, after which the decoder does nothing
more.

**BEHAVIOR**

The first call reads the stream's sequence from what was fed - its
parameter sets and first picture; what comes before them is passed
over - and makes the decoder's frames. Each call then has the chip
decode the next picture fed, until one is due to be shown: with B
frames the chip holds pictures back, so a frame may come out only
after the next ones are fed. After VDFEED_END the ones held back come
out, one a call, then VDERR_END. The caller's task waits for the chip
meanwhile, the CPU free.

The frame's bytes are dropped from the caches before it is handed
out; they are the chip's, written by it - read them, do not write.

**CONTEXT**

- Waits: yes, for the chip. - Interrupts: no.
- Locks: the resource's, around the chip: decoders on other tasks wait
  meanwhile. - Process: a Task will do.

**OWNERSHIP**

The frame's planes are the decoder's, lent to the caller until
ReleaseVideoFrame or CloseVideoDecoder; the decoder does not write
them until then.

**NOTES**

A frame's time is the time of the picture it shows as it was fed: of
the pictures decoded and not yet shown, the earliest.

**BUGS**

None known.

**SEE ALSO**

`FeedVideoDecoder`, `ReleaseVideoFrame`, `GetVideoDecoderInfo`

**EXAMPLES**

```zig
var frame: videodec.VideoDecFrame = .{};
if (vb.DecodeVideoFrame(decoder, &frame) == videodec.VDERR_OK) {
    defer vb.ReleaseVideoFrame(decoder, &frame);
    show(frame.y.?, frame.cbcr.?, frame.pitch, frame.width, frame.height);
}
```

## FeedVideoDecoder

Feeds a decoder one picture of its stream.

**SYNOPSIS**

```zig
fn FeedVideoDecoder(vb: *VideoDecBase, decoder: *VideoDecoder,
    data: ?[*]const u8, length: u32, time: u64, flags: u32) u32
```

**SINCE**

1.0. LVO -16.

**INPUTS**

- `decoder` - the decoder.
- `data` - the picture's units in Annex B form, each after a start
  code; the parameter sets in front of the first picture.
- `length` - how many bytes; 0 with VDFEED_END alone.
- `time` - when the picture is shown, in the caller's units
  (microseconds, say); handed back with its frame.
- `flags` - VDFEED_END with the stream's last picture, or after it.

**RESULT**

VDERR_OK; VDERR_FULL when the stream's ring has no room for it yet, or
64 pictures wait to be decoded - DecodeVideoFrame makes room, then the
picture is fed again; VDERR_END after the stream was ended, until
FlushVideoDecoder; VDERR_CORRUPT when the decoder stopped on the
stream before, or the chip did not take the data.

**BEHAVIOR**

The bytes are copied into the ring the chip reads, written back out
of the caches, and the chip told where they end. Nothing is decoded
here: DecodeVideoFrame does it.

**CONTEXT**

- Waits: yes, for the chip to take the command. - Interrupts: no.
- Locks: the resource's, around the chip. - Process: a Task will do.

**OWNERSHIP**

`data` is copied: the caller's again when the call returns.

**NOTES**

One picture per call keeps each frame's time right; a call with the
parameter sets alone counts as a picture of its own.

**BUGS**

None known.

**SEE ALSO**

`DecodeVideoFrame`, `FlushVideoDecoder`

**EXAMPLES**

```zig
while (vb.FeedVideoDecoder(decoder, unit.ptr, @intCast(unit.len), pts, 0) == videodec.VDERR_FULL) {
    if (vb.DecodeVideoFrame(decoder, &frame) == videodec.VDERR_OK) show(&frame);
}
```

## FlushVideoDecoder

Drops what a decoder was fed and has not shown yet, for a seek.

**SYNOPSIS**

```zig
fn FlushVideoDecoder(vb: *VideoDecBase, decoder: *VideoDecoder) void
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `decoder` - the decoder.

**RESULT**

Nothing.

**BEHAVIOR**

A picture the chip is decoding is waited for, then everything queued
for the decoder dropped: the pictures fed and not decoded, the frames
decoded and not shown. The stream is no longer ended (VDFEED_END), so
it can be fed again - from a key frame, as after a seek. The sequence
and the frames stay: a stream fed after it is one of the same size.

**CONTEXT**

- Waits: yes, for the chip. - Interrupts: no.
- Locks: the resource's, around the chip. - Process: a Task will do.

**OWNERSHIP**

The frames handed out stay the caller's, to give back as before.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`FeedVideoDecoder`, `DecodeVideoFrame`

**EXAMPLES**

```zig
vb.FlushVideoDecoder(decoder);
feedFrom(keyFrameBefore(target));
```

## GetVideoDecoderInfo

Says what a decoder's stream is, once its sequence is read.

**SYNOPSIS**

```zig
fn GetVideoDecoderInfo(vb: *VideoDecBase, decoder: *VideoDecoder,
    info: *VideoDecInfo) u32
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `decoder` - the decoder.
- `info` - filled in.

**RESULT**

VDERR_OK, and `info` holds the stream's size as shown and as coded,
its bit depth, profile and frame rate (see VideoDecInfo), and how many
frames the decoder made. VDERR_NEED_DATA, and `info` all zero, while
what was fed holds no sequence yet; otherwise what DecodeVideoFrame
would answer for the stream (VDERR_UNSUPPORTED, VDERR_NO_MEMORY,
VDERR_CORRUPT).

**BEHAVIOR**

A decoder whose sequence is not read yet has the chip read it from
what was fed, and makes its frames, as the first DecodeVideoFrame
would; no picture is decoded.

**CONTEXT**

- Waits: yes, for the chip. - Interrupts: no.
- Locks: the resource's, around the chip. - Process: a Task will do.

**OWNERSHIP**

Nothing is kept.

**NOTES**

H.264's frame rate is its timing's half rate (fields): `rate_den` is
twice the stream's num_units_in_tick.

**BUGS**

None known.

**SEE ALSO**

`FeedVideoDecoder`, `DecodeVideoFrame`

**EXAMPLES**

```zig
var info: videodec.VideoDecInfo = .{};
if (vb.GetVideoDecoderInfo(decoder, &info) == videodec.VDERR_OK) open(info.width, info.height);
```

## OpenVideoDecoder

Opens a decoder for one of the chip's codecs.

**SYNOPSIS**

```zig
fn OpenVideoDecoder(vb: *VideoDecBase, codec: u32,
    tags: ?[*]const TagItem, err: ?*u32) ?*VideoDecoder
```

**SINCE**

1.0. LVO -8.

**INPUTS**

- `codec` - one VDCODEC_*, of those VideoDecCodecs answers.
- `tags` - VDA_StreamSize, VDA_HeldFrames; null for neither.
- `err` - VDERR_OK, or why it failed; null if not wanted.

**RESULT**

The decoder, or null and in `err` why not: VDERR_NO_ENGINE when the
board has no decoder, its firmware is not in
DEVS:firmware/wave511_dec_fw.bin, or it would not wake or start;
VDERR_UNSUPPORTED for a codec it does not take; VDERR_BUSY when eight
decoders are open; VDERR_NO_MEMORY.

**BEHAVIOR**

The first decoder wakes the chip - its power domain, clocks and
resets - reads the firmware into a buffer below 4 GiB and starts it;
the chip runs from then on. Each decoder is an instance on the chip,
with a work buffer of 1784 KiB and the stream's ring
(VDA_StreamSize, 2 MiB by default, 64 KiB to 64 MiB). Its frames are
made when its first picture is decoded, or its stream asked about
(GetVideoDecoderInfo): as many compressed frames as the stream needs
and one, as many shown frames as that and VDA_HeldFrames (2 by
default, at most 16) - about 3 MiB each at 1080p.

**CONTEXT**

- Waits: yes, for the chip; the first open for the firmware's file.
- Interrupts: no. - Locks: the resource's, around the chip.
- Process: the first open, which reads the firmware with dos.library;
  once the chip runs a Task will do.

**OWNERSHIP**

The decoder is the caller's until CloseVideoDecoder; another task may
use it, one at a time. Its memory is the system's: the chip writes it,
and a task that ends with it open leaves it to the chip.

**NOTES**

The firmware is Chips&Media's, as StarFive ships it for their kernel
driver (scripts/fetch-vpu.sh fetches it into toolchain/, and the
build puts it on the disk); its licence is
DEVS:firmware/wave511.licence.

**BUGS**

None known.

**SEE ALSO**

`VideoDecCodecs`, `CloseVideoDecoder`, `FeedVideoDecoder`,
`DecodeVideoFrame`

**EXAMPLES**

```zig
var err: u32 = 0;
const decoder = vb.OpenVideoDecoder(videodec.VDCODEC_H264, null, &err) orelse return;
defer vb.CloseVideoDecoder(decoder);
```

## ReleaseVideoFrame

Gives a frame DecodeVideoFrame handed out back to the decoder.

**SYNOPSIS**

```zig
fn ReleaseVideoFrame(vb: *VideoDecBase, decoder: *VideoDecoder,
    frame: *VideoDecFrame) void
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `decoder` - the decoder it came from.
- `frame` - as DecodeVideoFrame filled it in.

**RESULT**

Nothing. `frame` is all zero afterwards.

**BEHAVIOR**

The chip may decode into the frame's buffer again. A frame not handed
out - all zero - or given back already is left alone.

**CONTEXT**

- Waits: yes, for the chip to take the command. - Interrupts: no.
- Locks: the resource's, around the chip. - Process: a Task will do.

**OWNERSHIP**

The planes are the decoder's again: nothing may read them afterwards.

**NOTES**

Frames may be given back in any order.

**BUGS**

None known.

**SEE ALSO**

`DecodeVideoFrame`

**EXAMPLES**

```zig
defer vb.ReleaseVideoFrame(decoder, &frame);
```

## VideoDecCodecs

Says which codecs the chip's decoder takes.

**SYNOPSIS**

```zig
fn VideoDecCodecs(vb: *VideoDecBase) u32
```

**SINCE**

1.0. LVO -4.

**INPUTS**

None.

**RESULT**

A VDCODEC_* bit for each codec: VDCODEC_H264 | VDCODEC_H265 on the
JH7110. 0 when the board has no decoder, or it would not wake or its
firmware would not start.

**BEHAVIOR**

Answered from what the board lists; the chip is not woken. Whether the
firmware is on the disk only the first OpenVideoDecoder finds out.

**CONTEXT**

- Waits: no. - Interrupts: yes.
- Locks: none taken. - Process: a Task will do.

**OWNERSHIP**

Nothing.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`OpenVideoDecoder`

**EXAMPLES**

```zig
if (vb.VideoDecCodecs() & videodec.VDCODEC_H264 != 0) { ... }
```
