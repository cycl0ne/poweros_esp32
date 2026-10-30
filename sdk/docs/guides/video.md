# Video

A film is two things side by side in one file: pictures, coded in H.264,
H.265 or Motion JPEG, and sound, mostly AAC. **videocodec.library** opens
the film and hands out both - the pictures as frames, in the order they
are shown and with the time each is due, the sound as 16-bit samples for
audio.device. Underneath, media.library reads the container (MP4,
QuickTime's MOV and Matroska's MKV) and hands out each track's packets,
the chip's decoder
(videodec.resource, the WAVE511 on the VisionFive 2) decodes H.264 and
H.265, the library decodes Motion JPEG itself, and audiocodec.library
decodes the sound. A display's video layer (rtg's `ShowVideoFrame`)
shows a frame as it comes out; graphics' `WriteYUVPixelArray` and
`ScaleYUVPixelArray` put one into a window where there is none.

This guide is opening a film, its pictures, showing them on a video
layer, its sound, keeping them together, moving in it, and what decodes
what.

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
the chip's decoder, MPEG-4 Part 2 anywhere. One whose sound nothing
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
an `rtg.RtgYuv` with its layout and colours set - NV12 in BT.709 for a
chip's frame 720 rows high or more, BT.601 below; I420 in JFIF's full
range for Motion JPEG - so graphics takes it as it is. `time` is in
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
const layer = rb.OpenVideoLayer(@ptrFromInt(board), null);
// The film's box in the window filled with layer.key, the layer moved there.
const all = rtg.RtgRect{ .width = @intCast(frame.width), .height = @intCast(frame.height) };
if (rb.ShowVideoFrame(layer, &frame.picture, &all) == rtg.errors.RTGERR_OK) {
    if (shown) |*old| vcb.ReleaseVideoFrame(film, old);
    shown = frame;
}
```

Every frame videocodec hands out - the chip's, and its own Motion JPEG
ones - is where a layer reads it, with nothing of it left in the
caches. The frame shown stays lent until the next is shown: the
`VIDEO_HELD_FRAMES` are then one on the layer, one waiting, and one
being decoded. A program follows its window with the layer - on
`IDCMP_CHANGEWINDOW`, windowclass's `WMHI_CHANGEWINDOW` - and closes the
layer before it gives back the last frame. Movie does all of this, and
puts the film through graphics where it gets no layer.

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

## What decodes what

| Pictures | Decoded by | On the VisionFive 2 |
|---|---|---|
| H.264 (baseline, main, high), H.265 (main), 8-bit | the chip, videodec.resource | 1080p about 145 frames a second, 720p about 300 |
| Motion JPEG, baseline: grey, 4:2:0, 4:2:2, 4:4:4 | the library, on the calling task | about a second for a 1080p picture: small pictures only |
| MPEG-4 Part 2 | nothing | - |

The sound is audiocodec.library's: AAC-LC
([AAC and MP4](audio.md#aac-and-mp4)), and in a Matroska file MP3, FLAC
and Vorbis too ([Matroska](audio.md#matroska)); another codec - AC-3,
DTS, Opus - leaves the film without sound. A Matroska film's pictures
in VP8, VP9 or AV1 are known to nothing here.

## From the shell

`C:test/Film FILE` decodes a film as fast as it goes, shows nothing and
plays nothing, and says how fast: `FRAME n TO file` writes a frame's
planes to compare with ffmpeg's, `SEEK s` moves to a second at the end,
`TOGETHER` decodes the sound on a process of its own while the pictures
are decoded. `C:test/VideoDec` feeds the chip's decoder an elementary
stream (Annex B) without a container.
