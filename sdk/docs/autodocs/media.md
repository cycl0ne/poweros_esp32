# media.library

media.library's functions: container files - MP4 - opened, their
tracks listed, and each track's packets handed out as they are coded,
for a decoder. Open it with OpenLibrary("media.library", 1); the
structures are in sdk.media.

Generated from the source by `./zig build autodoc`.

## Index

- [CloseMedia](#closemedia) - Closes a container file.
- [GetMediaAttrs](#getmediaattrs) - Says what a container file's tags say, each answer where its tag points.
- [GetMediaInfo](#getmediainfo) - Says what a container file is.
- [GetMediaTrack](#getmediatrack) - Says what a track of a container file is.
- [IdentifyMedia](#identifymedia) - Says what kind of container a file is, by its first bytes.
- [MediaErrorText](#mediaerrortext) - Says what an error code means, in words.
- [OpenMedia](#openmedia) - Opens a container file - MP4 - and reads its index.
- [ReadMediaPacket](#readmediapacket) - Hands out a track's next packet, as it is coded.
- [SeekMedia](#seekmedia) - Moves a track to the packet a decoder can start at, at or before a time.

## CloseMedia

Closes a container file.

**SYNOPSIS**

```zig
fn CloseMedia(base: *MediaBase, file: ?*media.MediaFile) void
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `file`: what OpenMedia made, or null.

**RESULT**

None.

**BEHAVIOR**

A file it opened (MDA_Name) is closed; its index, its tracks' buffers
and its chapters are freed with it.

**CONTEXT**

- Waits: yes, on the file it closes.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a task will do; a process when it closes a file it opened.

**OWNERSHIP**

The file is gone after the call, and every packet, setup, text and
picture it handed out with it. No track may be read while it closes. A
handle the program gave (MDA_FileHandle) is still the program's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`OpenMedia`

**EXAMPLES**

```zig
mb.CloseMedia(film);
```

## GetMediaAttrs

Says what a container file's tags say, each answer where its tag points.

**SYNOPSIS**

```zig
fn GetMediaAttrs(base: *MediaBase, file: *media.MediaFile, tags: ?[*]const utility.TagItem) u32
```

**SINCE**

1.0. LVO -52.

**INPUTS**

- `file`: an open file.
- `tags`: what is asked, each tag's data the address its answer goes
  to: `MDA_Title`, `MDA_Artist`, `MDA_Album`, `MDA_AlbumArtist`,
  `MDA_Composer`, `MDA_Genre` and `MDA_Comment` a `*[*:0]const u8`;
  `MDA_Year`, `MDA_Track`, `MDA_Tracks` and `MDA_Chapters` a `*u32`;
  `MDA_Picture` a `*?*const media.MediaPicture`; `MDA_ChapterList` a
  `*?[*]const media.MediaChapter`.

**RESULT**

How many of the tags it answered; one it does not know is left as it
is and not counted.

**BEHAVIOR**

The answers are an MP4's iTunes items: `©nam`, `©ART`, `©alb`, `aART`,
`©wrt`, `©gen` - or `gnre`, ID3's number, named - `©cmt`, the year of
`©day`, `trkn`. A text the tags do not hold is empty, a number 0; the
names are whole up to 127 characters, a comment up to 255.
`MDA_Picture` is null unless the file was opened with
`MDA_KeepPicture` and holds a cover (`covr`): then it is the first,
a JPEG or a PNG. The chapters are Nero's list (`chpl`), else the text
track a track names for them - read from a file only - each ending
where the next begins, up to 1000.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a task will do.

**OWNERSHIP**

Every text, the picture and the chapters are the file's, good until
`CloseMedia`.

**NOTES**

Texts are Latin-1; a character past it is a `?`.

**BUGS**

None known.

**SEE ALSO**

`OpenMedia`, `GetMediaInfo`

**EXAMPLES**

```zig
var year: u32 = 0;
var cover: ?*const media.MediaPicture = null;
_ = mb.GetMediaAttrs(song, &[_]utility.TagItem{
    .{ .tag = media.MDA_Year, .data = @intFromPtr(&year) },
    .{ .tag = media.MDA_Picture, .data = @intFromPtr(&cover) },
    .{},
});
```

## GetMediaInfo

Says what a container file is.

**SYNOPSIS**

```zig
fn GetMediaInfo(base: *MediaBase, file: *media.MediaFile, info: *media.MediaInfo) void
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `file`: an open file.
- `info`: where it goes.

**RESULT**

None: `info` is filled in.

**BEHAVIOR**

Its kind (MEDIA_MP4), how many tracks it has, how long it lasts - the
longest track, or what the file says, in microseconds - whether its
tracks can seek, the first track of pictures and of sound, and the
title, the artist and the album its tags name, cut at 63 characters.

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

`GetMediaTrack`, `GetMediaAttrs`

**EXAMPLES**

```zig
var info: media.MediaInfo = .{};
mb.GetMediaInfo(film, &info);
if (info.video == ~@as(u32, 0)) return; // no pictures
```

## GetMediaTrack

Says what a track of a container file is.

**SYNOPSIS**

```zig
fn GetMediaTrack(base: *MediaBase, file: *media.MediaFile, track: u32, info: *media.MediaTrack) i32
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `file`: an open file.
- `track`: which, from 0 to the info's `tracks` less one.
- `info`: where it goes.

**RESULT**

MERR_OK, or MERR_NOTRACK - and `info` is left as it is - for a number
past the last.

**BEHAVIOR**

Its kind and codec (MTRACK_*, MCODEC_*) - a codec the library does not
know is MCODEC_UNKNOWN, its packets handed out all the same - its
number in the file, how many packets it has, its timescale, the
priming before what it presents and how much it presents in that
timescale (its first edit, or iTunes's note for sound without one),
how long it lasts in microseconds; a picture's size and its frames a
second times 1000; a sound's rate, channels and coded bits; the bits a
second it averages, its largest packet; the setup its codec wants -
the avcC or hvcC record, the AudioSpecificConfig - its language and
its handler's name.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a task will do.

**OWNERSHIP**

`info` is the caller's; the setup it points to is the file's, good
until it is closed.

**NOTES**

For sound counted in its rate - nearly every file - `delay` and
`length` are frames of samples: an AAC encoder's priming is 1024 or
2112, which a decoder decodes and does not play.

**BUGS**

None known.

**SEE ALSO**

`GetMediaInfo`, `ReadMediaPacket`

**EXAMPLES**

```zig
var track: media.MediaTrack = .{};
if (mb.GetMediaTrack(film, info.audio, &track) != media.MERR_OK) return;
if (track.codec != media.MCODEC_AAC) return;
```

## IdentifyMedia

Says what kind of container a file is, by its first bytes.

**SYNOPSIS**

```zig
fn IdentifyMedia(base: *MediaBase, bytes: [*]const u8, length: u32) u32
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `bytes`: the first bytes of the file.
- `length`: how many; `MEDIA_IDENTIFY_BYTES` are enough.

**RESULT**

MEDIA_MP4, or MEDIA_UNKNOWN.

**BEHAVIOR**

An MP4 begins with a box: its size - 8 at least, or 1 for a size of 64
bits after it - and a kind one begins with: ISO's `ftyp`, or
QuickTime's `moov`, `mdat`, `wide`, `free`, `skip`, `pnot`. What
OpenMedia then reads may still turn out to be no MP4.

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

`OpenMedia`

**EXAMPLES**

```zig
if (mb.IdentifyMedia(&first, got) == media.MEDIA_MP4) playFilm(name);
```

## MediaErrorText

Says what an error code means, in words.

**SYNOPSIS**

```zig
fn MediaErrorText(base: *MediaBase, code: i32) [*:0]const u8
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `code`: an MERR_* code.

**RESULT**

A sentence fragment, lower case, no full stop: "the track has no more
packets".

**BEHAVIOR**

A code it does not know is "unknown error".

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

`OpenMedia`, `ReadMediaPacket`

**EXAMPLES**

```zig
_ = Printf(dl, "%s\n", .{mb.MediaErrorText(err)});
```

## OpenMedia

Opens a container file - MP4 - and reads its index.

**SYNOPSIS**

```zig
fn OpenMedia(base: *MediaBase, tags: ?[*]const utility.TagItem, err: ?*i32) ?*media.MediaFile
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `tags`: where the bytes come from - one of `MDA_Name` (a file to
  open), `MDA_FileHandle` (a file the program has open, the container
  beginning where it is) or `MDA_ReadFunc` with `MDA_ReadData` (a
  function of the program's) - and `MDA_Kind` to say what it is rather
  than have it found out, `MDA_KeepPicture` to have the cover kept.
- `err`: where why it failed goes (MERR_*), or null.

**RESULT**

The file, or null - and `err` says why: MERR_OPEN without a source or
when the file would not open, MERR_UNKNOWN for bytes that are not a
container the library knows, MERR_UNSUPPORTED for an MP4 in fragments
or one whose index lies behind its packets read through a function,
MERR_READ, MERR_CORRUPT, MERR_NOMEMORY.

**BEHAVIOR**

The kind is found by the first bytes: an MP4 begins with a box of the
kinds one begins with - `ftyp`, or QuickTime's `moov`, `mdat`, `wide`,
`free`. Its index, the `moov` box, is read whole into memory, wherever
it lies in a file; through a read function the boxes before it are
passed, and the packets must come after it. Each track is made out of
it - its kind, its codec and the codec's setup, its sample tables, its
edits - and every track's cursor is at its first packet. Up to 16
tracks are read; past them, tracks are passed over. The tags, the
chapters - Nero's list, or the text track a track names for them,
read from a file - and iTunes's note of the priming are read with it.

**CONTEXT**

- Waits: yes, on the file.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a process for a file (MDA_Name, MDA_FileHandle); a task will
  do with MDA_ReadFunc.

**OWNERSHIP**

The file is the caller's, given back with `CloseMedia`. A file opened
with MDA_Name is closed with it; a handle given with MDA_FileHandle
stays the program's, and must stay open until then.

**NOTES**

It takes the index's size in memory - a few megabytes for a film of
hours - and 64 KiB or its largest packet for each track read.

**BUGS**

None known.

**SEE ALSO**

`CloseMedia`, `GetMediaInfo`, `GetMediaTrack`, `ReadMediaPacket`,
`IdentifyMedia`

**EXAMPLES**

```zig
var err: i32 = 0;
const film = mb.OpenMedia(&[_]utility.TagItem{
    .{ .tag = media.MDA_Name, .data = @intFromPtr("SD0:Films/trip.mp4") },
    .{},
}, &err) orelse return;
defer mb.CloseMedia(film);
```

## ReadMediaPacket

Hands out a track's next packet, as it is coded.

**SYNOPSIS**

```zig
fn ReadMediaPacket(base: *MediaBase, file: *media.MediaFile, track: u32, packet: *media.MediaPacket) i32
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `file`: an open file.
- `track`: which track, as GetMediaTrack numbers them.
- `packet`: where it goes.

**RESULT**

MERR_OK; MERR_END after the track's last packet; MERR_NOTRACK,
MERR_READ, MERR_NOMEMORY, or MERR_NOSEEK for a packet behind what a
read function has read. Only with MERR_OK is `packet` filled in.

**BEHAVIOR**

The packet the track's cursor is at - its first after OpenMedia, the
one a seek found after SeekMedia - and the cursor on to the next, in
the order they are decoded. Its bytes, its size, whether a decoder can
start at it (MPKT_KEY), when it is due and when it is decoded in
microseconds from the start of what the file presents - below 0 for
priming - how long it lasts, its number in the track, and its decode
time in the track's own ticks. The bytes are read with the rest of
their chunk, as far as the track's buffer holds them, so the packets
after it come out of the buffer.

**CONTEXT**

- Waits: yes, on the file, and while another task reads another track
  of it.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a process for a file; a task will do with MDA_ReadFunc.

**OWNERSHIP**

The bytes are the library's, good until the next ReadMediaPacket or
SeekMedia on the same track, or CloseMedia.

**NOTES**

Two tasks may each read a track of their own at once - the sound and
the picture of a film; the file is read by one of them at a time. One
track is read by one task at a time.

**BUGS**

None known.

**SEE ALSO**

`SeekMedia`, `GetMediaTrack`

**EXAMPLES**

```zig
var packet: media.MediaPacket = .{};
while (mb.ReadMediaPacket(film, info.video, &packet) == media.MERR_OK) {
    decode(packet.data.?[0..packet.size], packet.pts);
}
```

## SeekMedia

Moves a track to the packet a decoder can start at, at or before a time.

**SYNOPSIS**

```zig
fn SeekMedia(base: *MediaBase, file: *media.MediaFile, track: u32, time: i64) i32
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `file`: an open file.
- `track`: which track.
- `time`: microseconds from the start of what the file presents.

**RESULT**

MERR_OK; MERR_NOTRACK; MERR_NOSEEK for a file read through
MDA_ReadFunc.

**BEHAVIOR**

The packet decoded last at or before `time` is found in the track's
times - the first when `time` is before them all, the last when it is
past them - and from it the last one a decoder can start at (MPKT_KEY):
for pictures the key frame before it, for sound that packet itself.
The next ReadMediaPacket on the track hands that packet out; its `pts`
says where the track landed. The other tracks stay where they are.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a task will do: the one that reads the track.

**OWNERSHIP**

The last packet handed out of the track is gone.

**NOTES**

A film is moved by moving its pictures first, then its sound to the
time the picture's key frame landed on. A sound decoder that overlaps
its packets - AAC - wants the packet before the one it plays from, to
begin.

**BUGS**

None known.

**SEE ALSO**

`ReadMediaPacket`

**EXAMPLES**

```zig
_ = mb.SeekMedia(film, info.video, 90 * 1_000_000); // a minute and a half in
```
