# Video

A film is two things side by side in one file: pictures, coded in H.264,
H.265, VP8, VP9, AV1 or Motion JPEG, and sound, mostly AAC or AC-3.
**videocodec.library** opens the film and hands out both - the pictures as frames, in the order they
are shown and with the time each is due, the sound as 16-bit samples for
audio.device. Underneath, media.library reads the container (MP4,
QuickTime's MOV and Matroska's MKV) and hands out each track's packets,
a codec module in `LIBS:codecs/` decodes the pictures - chip.vcodec
H.264 and H.265 on the chip's decoder (videodec.resource: the WAVE511
on the VisionFive 2, and an AMD graphics device's video decoder, which
takes VP9 and AV1 too),
h264.vcodec H.264 in software, hevc.vcodec H.265,
vp8.vcodec VP8, vp9.vcodec VP9 and av1.vcodec AV1 in software,
mjpeg.vcodec Motion JPEG in software - and
audiocodec.library decodes the sound. videoparse.library reads an H.264,
H.265, VP9 or AV1 stream for the decoders that decode its samples. A display's video layer (rtg's `ShowVideoFrame`)
shows a frame as it comes out; graphics' `WriteYUVPixelArray` and
`ScaleYUVPixelArray` put one into a window where there is none.

This guide is opening a film, its pictures, showing them on a video
layer, its sound, keeping them together, moving in it, its tracks and
subtitles, what decodes what, writing a codec module, and reading a
stream for a decoder.

## Opening a film

```zig
const vcb: *VideoCodecBase = @ptrCast(sys.OpenLibrary(vc.VIDEOCODECNAME, 1) orelse return);
var err: i32 = 0;
const film = vcb.OpenVideoStream(&[_]utility.TagItem{
    .{ .tag = vc.VCA_Name, .data = @intFromPtr("SD0:Films/trip.mp4") },
    .{},
}, &err) orelse {
    _ = Printf(dl, "%s\n", .{vcb.VideoErrorText(err)});
    return;
};
defer vcb.CloseVideoStream(film);
var info: vc.VideoStreamInfo = .{};
vcb.GetVideoStreamInfo(film, &info);
```

The info says what the pictures are - `codec`, `width` and `height` as
shown, the frames a second as `rate_num` / `rate_den` - how long the film
lasts, and its sound: `sound_codec` (audiocodec's `ACODEC_*`, 0 for
none), `sound_rate` and `sound_channels`. A film whose pictures nothing
here decodes does not open: `VCERR_NOCODEC` - H.264 on a machine without
the chip's decoder (no module in `LIBS:codecs/` decodes it there),
MPEG-4 Part 2 anywhere. One whose sound nothing
decodes opens without sound. `VCA_Sound` FALSE leaves the sound closed;
a film read through `VCA_ReadFunc` - a download - has its pictures only,
and cannot move.

## The pictures

```zig
var frame: vc.VideoFrame = .{};
while (vcb.DecodeVideoFrame(film, &frame) == vc.VCERR_OK) {
    waitUntil(frame.time);
    _ = gfx.ScaleYUVPixelArray(rp, &frame.picture, &.{ .x = 0, .y = 0, .w = frame.width, .h = frame.height }, &inside);
    vcb.ReleaseVideoFrame(film, &frame);
}
```

A frame is the decoder's own memory, lent: nothing is copied, and the
planes stay as they are until `ReleaseVideoFrame` gives them back. Up to
`VIDEO_HELD_FRAMES` (three) may be held at once - one shown, one waiting
its turn - and a fourth `DecodeVideoFrame` is `VCERR_BUSY`. `picture` is
an `rtg.RtgYuv` with its layout and colours set, as the stream says them
- NV12 for a chip's frame, I420 for a software decoder's, in JFIF's full
range for Motion JPEG - so graphics takes it as it is. Its `matrix`,
`transfer`, `primaries`, `range`, `depth` and `peak` are the stream's
own: a film of high dynamic range comes out in PQ or HLG, in BT.2020's
red, green and blue, often ten bits a sample, and graphics maps it into
the screen's range as it puts it down. The chip's frames of H.264 and
H.265 say it too - the hardware reports none of it, so the setup
record's parameter set is read when the stream is opened; its VP9 and
AV1 frames are taken to be what their height suggests. `time` is in
microseconds from the start of what the film presents; `number` counts
the frames handed out. `VCERR_CORRUPT` is one picture the decoder
stopped on: calling again goes on with the next. `VCERR_END` follows the
last.

## On a video layer

Where the screen's display has a video layer
([Video layers](rtg.md#video-layers)), the frame is handed to it as it
is, and the processor does nothing more for it:

```zig
var board: usize = 0;
ib.GetScreenAttrs(screen, &[_]utility.TagItem{ .{ .tag = sc.SA_Board, .data = @intFromPtr(&board) }, .{} });
// What the frames will be: a display whose controller cannot make its
// colours out of them hands out no layer at all.
const kind = [_]utility.TagItem{
    .{ .tag = rtg.RTGVA_Matrix, .data = frame.picture.matrix },
    .{ .tag = rtg.RTGVA_Transfer, .data = frame.picture.transfer },
    .{ .tag = rtg.RTGVA_Primaries, .data = frame.picture.primaries },
    .{ .tag = rtg.RTGVA_Range, .data = frame.picture.range },
    .{ .tag = rtg.RTGVA_Depth, .data = frame.picture.depth },
    .{},
};
const layer = rb.OpenVideoLayer(@ptrFromInt(board), &kind);
// The film's box in the window filled with layer.key, the layer moved there.
const all = rtg.RtgRect{ .width = @intCast(frame.width), .height = @intCast(frame.height) };
if (rb.ShowVideoFrame(layer, &frame.picture, &all) == rtg.errors.RTGERR_OK) {
    if (shown) |*old| vcb.ReleaseVideoFrame(film, old);
    shown = frame;
}
```

Every frame videocodec hands out - every codec module's, the chip's and
the Motion JPEG ones - is where a layer reads it, with nothing of it left in the
caches. The frame shown stays lent until the next is shown: the
`VIDEO_HELD_FRAMES` are then one on the layer, one waiting, and one
being decoded. A program follows its window with the layer - on
`IDCMP_CHANGEWINDOW`, windowclass's `WMHI_CHANGEWINDOW` - and closes the
layer before it gives back the last frame. Movie does all of this, and
puts the film through graphics where it gets no layer.

A layer is asked for when the first frame is in hand, since nothing
before it says what the film's colours are, and a film of high dynamic
range or of ten bits gets none: the controller's converter knows one
matrix and no curve, so such a film is put down by graphics, which maps
it into the screen's range (`ScaleYUVPixelArray`). That costs the
processor the frames it would have cost on a board with no layer at all,
and the film looks as it should.

## The sound

`DecodeVideoSound` hands out the sound as audiocodec's `DecodeAudio`
does: 16-bit samples, the channels interleaved, at the info's rate - for
an audio.device stream of `AUDIO_S16` as they are. The pictures and the
sound may be decoded by two tasks at once, and should be: the sound on a
process that keeps audio.device fed, as Player does, the pictures where
they are shown. Each half is one task's at a time.

## Keeping them together

The sound sets the time. The frame to show is the one whose `time` has
come in what is heard: audio.device's position for the stream, less the
output's latency ([Keeping a picture in step](audio.md#keeping-a-picture-in-step)),
turned into microseconds by the sound's rate. A frame whose time is past
by more than a frame is given back unshown; one not yet due waits. A
film without sound keeps time by the timer instead.

## Moving

```zig
const landed = vcb.SeekVideo(film, 60 * 1_000_000);
```

`SeekVideo` moves the pictures to the key frame at or before the time -
a decoder can only start at one, and they are often seconds apart - and
the sound to that frame's time; it answers where it landed, so the
program sets its clock there. The next frame is that key frame. It is
called by the task that decodes the pictures, and waits for a piece of
sound being decoded on the other to be done. In a Matroska file the
pictures land on the key frame the last cue before the time names - a
muxer names every key frame, or the first of each cluster - and the
sound within a millisecond of that frame's time.

## Tracks and subtitles

A film may hold several sound tracks - other languages, a commentary -
and subtitles: SubRip's or SubStation Alpha's text, or a Blu-ray's
pictures (PGS). videocodec.library 1.3 lists them and chooses among
them.

```zig
var track: media.MediaTrack = .{};
var number: u32 = 0;
while (true) : (number += 1) {
    const flags = vcb.GetVideoTrack(film, number, &track);
    if (flags < 0) break; // VCERR_END: no more
    // track.kind, .codec, .language, .name; flags: VTRK_DECODED, VTRK_CHOSEN
}
```

`GetVideoTrack` fills in a track as media.library's `GetMediaTrack`
does and says whether something here decodes it and whether it is the
one playing or shown. A film starts with the tracks it marks - a
Matroska file's default sound track, and its subtitles marked forced and
default, else default (media.library's `MDA_Subtitles`); an MP4 marks no
subtitles - or with `VCA_SoundTrack` and `VCA_Subtitles`
(`VIDEO_NO_TRACK` for none) at OpenVideoStream.

`SelectVideoTrack(film, number, time)` chooses another while the film
plays: a sound track from `time` on - the rate and the channels may be
others, so a program that plays the sound on a process stops it first,
reads the info again and starts it anew - or subtitles, or
`VIDEO_NO_TRACK` for none.

```zig
var shown: vc.VideoSubtitle = .{};
if (vcb.GetVideoSubtitle(film, frame.time, &shown) == vc.VCERR_OK) {
    if (shown.start != last.start or shown.end != last.end) draw(&shown);
}
```

`GetVideoSubtitle` says what shows at a frame's time: `VSUB_TEXT` - lines
of UTF-8 apart by `\n`, `VSUB_ITALIC` when all are in italics, SubRip's
tags and SubStation Alpha's codes taken out, of SubStation Alpha the
dialogue only (signs placed on the picture and drawings are left out) -
or `VSUB_BITMAP`: `width` by `height` pixels, 0xAARRGGBB, laid at `x`,
`y` of the frame, fitted to the film where the disc's canvas is another
size. `start` and `end` say how long the same thing shows: a program
draws it again only when they change. The subtitles are read ahead of
the film by a process of the library's, so the call never waits on the
file; after a seek they are read from five seconds before, for the
lines still showing. Movie draws text in the screen's font at an
eighteenth of the picture's height, white with a black edge, and lays a
picture over the film with graphics' `ScalePixelArray`, its coverage
mixed - over a video layer, where the film is seen through the key
colour, a pixel half covered or more is the subtitle's.

## What decodes what

| Pictures | Decoded by | On the VisionFive 2 |
|---|---|---|
| H.264 (baseline, main, high), 8-bit; H.265 (main, and main 10 shown in 8 bits); on an AMD graphics device VP9 too (profile 0, and profile 2's 10 bits shown in 8) and AV1 (main: 8 bits, and 10 shown in 8, film grain) | chip.vcodec: the chip, videodec.resource | 1080p about 145 frames a second, 720p about 300; on a Radeon 780M 1080p about 600 (H.264, H.265 and AV1), 720p H.264 about 900, 4K H.265 in 10 bits about 160, 4K AV1 in 10 bits 130 to 165, 1080p VP9 about 550, in 10 bits about 340 |
| H.264, every profile but SVC's and MVC's: up to 4:4:4 and 14 bits, fields, shown in 8 bits; what the chip refuses, and every H.264 where there is no chip | h264.vcodec: software, a worker task on each core, a picture each | 720p High 10 about 32 frames a second, 10 on one core; 1080p High about 20, 720p about 52 |
| H.265: Main, Main 10, Main Still Picture and the range extensions' profiles - grey to 4:4:4, up to 16 bits - shown in 8 bits; the base layer of a stream in layers; what the chip refuses, and every H.265 where there is no chip | hevc.vcodec: software, a worker task on each core, a picture each | 1080p about 25 frames a second, 720p about 55, 1080p 4:2:2 in 10 bits about 17 |
| VP8, every version (WebM, Matroska) | vp8.vcodec: software, a worker task on each core, a frame each | 720p about 84 frames a second, 1080p about 34; 27 and 11 on one core |
| VP9, every profile: 8, 10 and 12 bits, 4:2:0, 4:2:2, 4:4:0, 4:4:4 (WebM, Matroska), shown in 8 bits; what the chip refuses, and every VP9 where there is no chip | vp9.vcodec: software, a worker task on each core, a frame each | 720p about 53 frames a second, 1080p about 30, 720p in 10 bits about 38; 18, 9 and 12 on one core |
| AV1, every profile: 8, 10 and 12 bits, grey, 4:2:0, 4:2:2, 4:4:4, film grain (MP4, WebM, Matroska), shown in 8 bits; what the chip refuses, and every AV1 where there is no chip | av1.vcodec: software, a worker task on each core, a frame each | 1080p about 15 frames a second, 720p about 27, 720p in 10 bits with film grain about 18 |
| Motion JPEG, baseline: grey, 4:2:0, 4:2:2, 4:4:4 | mjpeg.vcodec: software, on the calling task | about a second for a 1080p picture: small pictures only |
| MPEG-4 Part 2 | nothing | - |

The software modules but mjpeg.vcodec are on the 64-bit machines' disks
alone: the ESP32s have neither the room on their flash disks nor the
speed.

The sound is audiocodec.library's: AAC-LC
([AAC and MP4](audio.md#aac-and-mp4)), AC-3 and E-AC-3 mixed into
stereo ([AC-3 and E-AC-3](audio.md#ac-3-and-e-ac-3)), DTS's core
([DTS](audio.md#dts)) on the 64-bit machines, and in a Matroska
file MP3, FLAC and Vorbis too ([Matroska](audio.md#matroska)); another
codec leaves the film without sound. Subtitles (1.3): SubRip,
SubStation Alpha (ASS and SSA), MP4's timed text and PGS, read by the
library.

## Codec modules

The pictures' decoders are libraries of their own in `LIBS:codecs/`
(1.4), so one is replaced - or a new codec added - by copying its file
there, without videocodec.library. Each has the seven calls of
`sdk.interface.vcodec` ([md](../autodocs/vcodec.md)) and a ROM tag that
says what it decodes, a `ResidentVCodec` (`sdk.vcodec`):

```zig
pub export const h264_vcodec_tag: vcodec.ResidentVCodec linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&h264_vcodec_tag),
        .flags = exec.RTF_AUTOINIT,
        .version = 1,
        .type = .library,
        .name = "h264.vcodec",
        .id_string = "h264.vcodec 1.0 (30.10.2026)\r\n",
        .init = &init_table,
    },
    .codecs = vcodec.codecBit(vc.VCODEC_H264),
    .kind = vcodec.VCMOD_SOFTWARE,
    .priority = 0,
};
```

When a film is opened, videocodec reads the tag of each file there -
without loading it, and again only when the file changed - and tries the
modules that name the track's codec: a chip's (`VCMOD_CHIP`) before
software, the higher `priority` first. The file's name is the tag's,
which ramlib loads it by. The first whose `OpenVCodec` gives a decoder
decodes the track; `VCERR_NOCODEC` - the board has not the module's chip
- or another error passes it to the next. A decoder that reads in the
stream that it cannot decode it answers `ReceiveVCodecFrame` with
`VCERR_UNSUPPORTED` before its first frame, and the next module starts
again at the key packet.

A decoder is asked for frames (`ReceiveVCodecFrame`); `VCERR_NEED_DATA`
has videocodec send the next packet (`SendVCodecPacket`), and
`VCERR_FULL` there has it take a frame first and send the packet again.
A packet's bytes are videocodec's for the call alone. Its frames are
`VideoFrame`s as a program gets them - 8-bit 4:2:0, each plane and row
on 16 bytes, where a display's video layer reads them and out of the
caches - its own memory, lent until `ReleaseVCodecFrame`, with
`private` its own. `FlushVCodec` is a seek. src/disk/libs/codecs/ has
chip.vcodec, h264.vcodec, hevc.vcodec, vp8.vcodec, vp9.vcodec,
av1.vcodec and mjpeg.vcodec, and
module.zig the base, init, Expunge and jump table every module there
shares.

media.library's containers are modules the same way (1.5):
`mp4.container` and `mkv.container` in `LIBS:codecs/`, with the calls of
`sdk.interface.mcontainer` ([md](../autodocs/mcontainer.md)) and the file
they share, `sdk.mcontainer`; the kind names the file, and without its
module a file is refused, `MERR_UNSUPPORTED`. audiocodec.library's kinds
are `.acodec` modules there ([Sound](audio.md)).

## Reading a stream

**videoparse.library** (`sdk.interface.videoparse`,
[md](../autodocs/videoparse.md)) reads an H.264, H.265, VP9 or AV1
stream for a decoder: the parameter sets, each picture's slice headers,
its order counts, the reference pictures it holds and the two lists
each slice decodes from, the references the stream lacks, and when each
picture is shown - for VP9 and AV1 each frame's uncompressed header and
its eight reference slots - and the light the film was mastered for, as
its SEI or metadata OBUs said it, with each picture (`peak_nits`). The
decoder decodes the samples - in software, as h264.vcodec, hevc.vcodec,
vp9.vcodec and av1.vcodec do, or on a chip that takes the parsed
slices. Its structures are in
`sdk.videoparse`, every field of the codecs' syntax in
`sdk.videoparse.h264`, `sdk.videoparse.hevc`, `sdk.videoparse.vp9` and
`sdk.videoparse.av1`.

```zig
const vpb: *VideoParseBase = @ptrCast(sys.OpenLibrary(vp.VIDEOPARSENAME, 1) orelse return);
defer sys.CloseLibrary(vpb.lib());
var why: i32 = 0;
// The track's avcC, hvcC or av1C, or null for Annex B; four slots of the
// caller's beyond the stream's, for pictures it still shows.
const parser = vpb.OpenVideoParser(vp.VPCODEC_HEVC, setup, setup_size, &[_]utility.TagItem{
    .{ .tag = vp.VPA_Slots, .data = 4 },
    .{},
}, &why) orelse return;
defer vpb.CloseVideoParser(parser);

var packet: vp.VideoPacket = .{ .data = bytes.ptr, .bytes = @intCast(bytes.len), .time = time, .flags = vp.VPPKT_ACCESS_UNIT };
_ = vpb.ParseVideoPacket(parser, &packet);
var event: vp.VideoEvent = .{};
while (true) {
    switch (vpb.NextVideoEvent(parser, &event)) {
        vp.VPERR_OK => {},
        vp.VPERR_NEED_DATA, vp.VPERR_END => break, // the next packet
        vp.VPERR_FULL => { // no slot free: a picture shown and given back
            showOldest(vpb, parser);
            continue;
        },
        else => continue, // a unit passed over
    }
    switch (event.kind) {
        vp.VPEV_SEQUENCE => makePictures(event.sequence.?),
        vp.VPEV_MISSING => fillGrey(event.picture.?.slot),
        vp.VPEV_PICTURE => beginPicture(event.picture.?),
        vp.VPEV_SLICE => decodeSlice(event.slice.?),
        vp.VPEV_DECODE => endPicture(),
        vp.VPEV_SHOW => queueToShow(event.slot, event.time),
        vp.VPEV_FREE => forget(event.slot), // ReleaseVideoSlot once it is not shown or read
        else => {},
    }
}
```

**A slot** names a picture, 0 up, handed out lowest first by
`VPEV_PICTURE` and `VPEV_MISSING`: a decoder keeps a picture's samples,
or a chip's reference surface, by its slot. A slot is the picture's
until the parser said `VPEV_FREE` of it and the decoder gave it back
with `ReleaseVideoSlot` - a picture may still wait to be shown, or be
read by another core, after the stream let go of it. `VPA_Slots` is
how many the decoder keeps beyond the stream's own: the frames it holds
to be shown and those its other cores still read. Where none is free
the next picture waits, `VPERR_FULL`, until one comes back.

**A packet** is the caller's until `NextVideoEvent` answers
`VPERR_NEED_DATA`: the parser reads a unit at a time as the events are
asked for. `VPPKT_ACCESS_UNIT` says the packet is a whole picture - an
MP4's or a Matroska track's is - so its `VPEV_DECODE` comes at its end
rather than with the next picture's first unit; `VPPKT_END` shows every
picture held and lets go of every slot. `ResetVideoParser` drops the
pictures for a seek and keeps the parameter sets: the next packet is
read as a stream's first, `VPEV_SEQUENCE` and all. An H.264 parser
takes some 265 KiB, an H.265 one some 330 KiB, most of it the parameter
sets.

**A VP9 stream** (`VPCODEC_VP9`, no setup) has no slices, parameter sets
or reordering: a packet is a frame, or a superframe of several - most
often a hidden one, a reference for the frames after it, and one shown.
Each frame is a `VPEV_PICTURE` with its header (`vp9`, the uncompressed
header with what stays from frame to frame applied) and the eight
reference slots as its references, in their order; one `VPEV_SLICE`
with the frame's bytes whole, the compressed header starting at
`data_bit`; `VPEV_DECODE`; and `VPEV_SHOW` when it is shown. A frame
that only shows a reference is a `VPEV_SHOW` of that slot alone, so a
slot can be shown more than once. `VPEV_SEQUENCE` comes before the first
frame and before one of another size or format; a frame may still be
predicted from references of other sizes. The stream takes nine slots
beyond `VPA_Slots`, and a VP9 parser some 26 KiB.

**An AV1 stream** (`VPCODEC_AV1`, the track's av1C as its setup, or
none) is OBUs: a packet is a temporal unit - the frames of one moment,
most often hidden ones and one shown - and is marked
`VPPKT_ACCESS_UNIT`. Each frame is a `VPEV_PICTURE` with its header
(`av1`, with what it takes from its primary reference and its
references applied), the sequence header (`av1_sequence`) and the eight
reference slots as its references, in their order; a `VPEV_SLICE` for
each tile, its bytes and its number (`tile`); and `VPEV_DECODE` after
the last. The frame a temporal unit shows - the last it shows, of a
stream in layers - is a `VPEV_SHOW` at the unit's end, whose `picture`
holds the header it is shown with: the frame's own, or for a frame
shown again that one's, with the film grain the frame was stored with.
`VPEV_SEQUENCE` comes before the first frame and before one of another
size or format. The OBUs of operating point 0 are read. The stream
takes ten slots beyond `VPA_Slots` - one more for the frame shown,
held until its unit ends - and an AV1 parser some 11 KiB.

## From the shell

`C:test/Film FILE` decodes a film as fast as it goes, shows nothing and
plays nothing, and says how fast: `FRAME n TO file` writes a frame's
planes to compare with ffmpeg's, `SEEK s` moves to a second at the end
(with `TO` and no `FRAME`, the frame it lands on is written), `TOGETHER` decodes the sound on a process of its own while the pictures
are decoded. `C:test/VideoDec` feeds the chip's decoder an elementary
stream (Annex B) without a container, or VP9 or AV1 in an IVF file.
