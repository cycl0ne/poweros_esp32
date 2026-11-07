# videoparse.library

videoparse.library's functions: an H.264 stream read for a decoder -
its parameter sets and slice headers, its pictures' order counts and
references, the lists each slice decodes from and the order the
pictures are shown in - event by event (sdk/libs/videoparse/). Open
it with OpenLibrary("videoparse.library", 1).

Generated from the source by `./zig build autodoc`.

## Index

- [CloseVideoParser](#closevideoparser) - Closes a parser.
- [NextVideoEvent](#nextvideoevent) - Reads the stream on to its next event.
- [OpenVideoParser](#openvideoparser) - Makes a parser for a video stream, and reads its track's setup.
- [ParseVideoPacket](#parsevideopacket) - Hands a parser the stream's next packet.
- [ReleaseVideoSlot](#releasevideoslot) - Gives a slot back to the parser once the caller is done with it.
- [ResetVideoParser](#resetvideoparser) - Drops what a parser holds of the stream, for a seek.

## CloseVideoParser

Closes a parser.

**SYNOPSIS**

```zig
fn CloseVideoParser(base: *VideoParseBase, parser: ?*vp.VideoParser) void
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `parser`: what OpenVideoParser made, or null.

**RESULT**

None.

**BEHAVIOR**

Its parameter sets, its pictures' bookkeeping and its buffers are
freed, whatever it was doing: events not asked for are dropped, and
the slots are gone with it, those the caller has not given back too.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a task will do.

**OWNERSHIP**

The parser is gone after the call, and everything its events pointed
at. The packet's bytes are still the caller's.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`OpenVideoParser`

**EXAMPLES**

```zig
vpb.CloseVideoParser(parser);
```

## NextVideoEvent

Reads the stream on to its next event.

**SYNOPSIS**

```zig
fn NextVideoEvent(base: *VideoParseBase, parser: *vp.VideoParser, event: *vp.VideoEvent) i32
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `parser`: what OpenVideoParser made.
- `event`: where the event goes.

**RESULT**

- VPERR_OK: `event` holds the next event.
- VPERR_NEED_DATA: the packet is read through; the next is to be
  handed over with `ParseVideoPacket`.
- VPERR_END: after VPPKT_END, every event said.
- VPERR_FULL: a picture needs a slot and none is free; one is to be
  given back with `ReleaseVideoSlot` before the next call.
- VPERR_CORRUPT: a unit that is not right was passed over - or the
  rest of the packet, where a unit's length went past its end.
- VPERR_UNSUPPORTED: a unit the library does not read was passed over
  (a picture larger than VPA_MaxWidth or VPA_MaxHeight).
- VPERR_NOMEMORY: a unit was passed over for want of memory.

After an error the next call goes on with the next unit.

**BEHAVIOR**

The events of a picture come in this order: VPEV_SEQUENCE when it
begins a sequence that is new or says something else than the last
one did (the pictures of the last one shown first where its pictures'
size or kind changes); VPEV_MISSING for each frame a gap in H.264's
frame numbers skipped; VPEV_PICTURE; a VPEV_SLICE for each slice;
VPEV_DECODE once its slices are all given - when the next picture
begins, its access unit or the stream ends. After VPEV_DECODE come the
pictures the marking and the buffer let go of: VPEV_SHOW for each
picture due, in the order shown, VPEV_FREE for each slot the stream
needs no more.

VPEV_SEQUENCE's `sequence` is what the active sequence parameter set
says. VPEV_PICTURE's `picture` holds the picture's slot - the second
field of a pair in its first field's - its order counts, its parameter
sets and the reference pictures the stream holds before the picture is
marked, the first field of its own frame among them. VPEV_SLICE's
`slice` holds the unit as it came, its payload unescaped and the bit
its data starts at, the parsed header and its two lists, each entry
with its picture's slot, number and order counts. VPEV_MISSING's
`picture` holds the missing frame's slot, number and order counts: the
caller fills it - with grey, or a copy of the last reference - and it
is referred to as if it were there; it is never shown. VPEV_SHOW's
`slot` and `time` say which picture is due and when, VPEV_FREE's
`slot` which the stream let go of.

A slice whose parameter sets were never given, a picture that names
another picture parameter set than its first slice did, a redundant
picture's slices are passed over.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a task will do.

**OWNERSHIP**

What an event points at - the sequence, the picture, the slice, the
parameter sets and the header, and the slice's units and payload - is
the parser's, and good until the next call on it. A slot an event
hands out is the caller's until it gives it back (`ReleaseVideoSlot`).

**NOTES**

The pictures are numbered too (`uid`), the missing ones with them, and
a number is never given twice: a list entry and a reference name their
picture by it as well as by its slot, which a later picture reuses.

**BUGS**

None known.

**SEE ALSO**

`ParseVideoPacket`, `ReleaseVideoSlot`, `ResetVideoParser`

**EXAMPLES**

```zig
var event: vp.VideoEvent = .{};
while (true) {
    switch (vpb.NextVideoEvent(parser, &event)) {
        vp.VPERR_OK => {},
        vp.VPERR_NEED_DATA, vp.VPERR_END => break,
        vp.VPERR_FULL => return, // a shown picture is to be given back first
        else => continue, // a unit passed over
    }
    switch (event.kind) {
        vp.VPEV_SLICE => decodeSlice(event.slice.?),
        vp.VPEV_SHOW => show(event.slot, event.time),
        vp.VPEV_FREE => vpb.ReleaseVideoSlot(parser, event.slot),
        else => {},
    }
}
```

## OpenVideoParser

Makes a parser for a video stream, and reads its track's setup.

**SYNOPSIS**

```zig
fn OpenVideoParser(base: *VideoParseBase, codec: u32, setup: ?[*]const u8, bytes: u32, tags: ?[*]const utility.TagItem, err: ?*i32) ?*vp.VideoParser
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `codec`: what the stream is: VPCODEC_H264 or VPCODEC_HEVC.
- `setup`, `bytes`: the track's setup as its container holds it - an
  MP4's `avcC` or `hvcC`, a Matroska track's CodecPrivate - or null
  (or 0 bytes) for a stream in Annex B form, its parameter sets among
  its units.
- `tags`: `VPA_Slots`, the slots the caller keeps beyond the stream's
  own (pictures it has lent out, or reads on cores of its own after
  the stream let go of them; at most 32, default 0); `VPA_MaxWidth`
  and `VPA_MaxHeight`, the largest picture taken, in samples (default
  8192 each).
- `err`: where why it failed goes (VPERR_*), or null.

**RESULT**

The parser, or null - and `err` says why: VPERR_UNSUPPORTED for a
codec the library does not read or more than 32 slots of the caller's,
VPERR_CORRUPT for a setup that is not right, VPERR_NOMEMORY.

**BEHAVIOR**

An `avcC` or `hvcC` says how many bytes each unit's length takes in
the packets, and its parameter sets are read now; without one, each
packet's units follow start codes. The parameter sets are kept by
their ids, as many as the stream has (H.264's 32 sequence and 256
picture parameter sets, HEVC's 16 and 64), and a later one with the
same id takes the earlier one's place.

The slots go from 0 to 17 plus `VPA_Slots`: sixteen frames the stream
may hold, the picture being decoded, and a first field waiting for its
second (H.264) - HEVC's sixteen pictures hold the one being decoded,
and two more stand for references the stream names and lacks.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a task will do.

**OWNERSHIP**

The parser is the caller's, given back with `CloseVideoParser`. The
setup's bytes are read during the call and are not kept.

**NOTES**

An H.264 parser takes some 265 KiB, most of it the 256 picture
parameter sets; an HEVC parser some 330 KiB, most of it the sixteen
sequence parameter sets with their reference picture sets and the 64
picture parameter sets. Each takes as much again as the largest unit
for its unescaped copy.

**BUGS**

None known.

**SEE ALSO**

`CloseVideoParser`, `ParseVideoPacket`, `NextVideoEvent`

**EXAMPLES**

```zig
var err: i32 = 0;
const parser = vpb.OpenVideoParser(vp.VPCODEC_H264, track.setup, track.setup_bytes, &[_]utility.TagItem{
    .{ .tag = vp.VPA_Slots, .data = 4 },
    .{},
}, &err) orelse return err;
defer vpb.CloseVideoParser(parser);
```

## ParseVideoPacket

Hands a parser the stream's next packet.

**SYNOPSIS**

```zig
fn ParseVideoPacket(base: *VideoParseBase, parser: *vp.VideoParser, packet: *const vp.VideoPacket) i32
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `parser`: what OpenVideoParser made.
- `packet`: its bytes (`data`, `bytes`) - units after start codes, or
  each after its length where the setup said so - when its picture is
  shown (`time`, in the caller's units), and `flags`:
  `VPPKT_ACCESS_UNIT` where the packet is one access unit, as an MP4's
  or a Matroska track's is, so its picture ends with it;
  `VPPKT_END` at the stream's end, with or without bytes: every
  picture held is shown, and every slot let go of (VPEV_FREE).

**RESULT**

VPERR_OK; VPERR_FULL while the packet before still has events to ask
for - the packet is not taken.

**BEHAVIOR**

Nothing is read yet: `NextVideoEvent` reads the packet a unit at a
time, and answers VPERR_NEED_DATA once it is read through, which is
when the next is to be handed over. A picture whose packet did not say
VPPKT_ACCESS_UNIT ends when the next picture's first slice comes, or
a unit that comes only between pictures (a parameter set, an access
unit delimiter, SEI).

A picture takes the time of the packet its first slice came in. Where
pictures come out in another order than they came in, each is shown
at the earliest time of those waiting: the same where the container
gave each packet the time its picture is shown, and still rising
where it gave the time it is decoded.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a task will do.

**OWNERSHIP**

The bytes stay the caller's, and must stay as they are until
`NextVideoEvent` answers VPERR_NEED_DATA or VPERR_END, the parser is
reset or closed. The packet structure itself is copied.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`NextVideoEvent`, `ResetVideoParser`

**EXAMPLES**

```zig
const packet: vp.VideoPacket = .{ .data = got.data, .bytes = got.bytes, .flags = vp.VPPKT_ACCESS_UNIT, .time = got.time };
_ = vpb.ParseVideoPacket(parser, &packet);
```

## ReleaseVideoSlot

Gives a slot back to the parser once the caller is done with it.

**SYNOPSIS**

```zig
fn ReleaseVideoSlot(base: *VideoParseBase, parser: *vp.VideoParser, slot: u32) void
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `parser`: what OpenVideoParser made.
- `slot`: a slot VPEV_PICTURE or VPEV_MISSING handed out.

**RESULT**

None.

**BEHAVIOR**

A slot is the caller's from the event that handed it out until it
gives it back, and the stream's until it said VPEV_FREE of it; it is
handed out again only when it is neither. The caller gives each slot
back once, when the stream let go of it and its own use of it is
over: at once for a decoder that is done with a picture when the
stream is, later for one whose cores still read the picture or that
has lent it out. A slot given back before VPEV_FREE is free once the
stream lets go of it.

After `ResetVideoParser` no VPEV_FREE comes for the slots the caller
holds: it gives each back when its own use of it is over.

A slot past the last one is passed over.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a task will do; not while another task calls the parser.

**OWNERSHIP**

What the caller keeps by the slot - samples, a chip's surface - is
still its own; the slot's next picture is a new one.

**NOTES**

A picture waiting for a slot (VPERR_FULL) takes the slot given back
when `NextVideoEvent` is called next.

**BUGS**

None known.

**SEE ALSO**

`NextVideoEvent`

**EXAMPLES**

```zig
if (event.kind == vp.VPEV_FREE) vpb.ReleaseVideoSlot(parser, event.slot);
```

## ResetVideoParser

Drops what a parser holds of the stream, for a seek.

**SYNOPSIS**

```zig
fn ResetVideoParser(base: *VideoParseBase, parser: *vp.VideoParser) void
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `parser`: what OpenVideoParser made.

**RESULT**

None.

**BEHAVIOR**

The packet being read is let go of, the events not asked for are
dropped, and the pictures the stream held - references, pictures
waiting to be shown, the one being read - are forgotten without a
VPEV_SHOW or VPEV_FREE. The parameter sets stay: the next packet is
read as a stream's first - VPEV_SEQUENCE comes again with its first
picture - and pictures before its first IDR picture that refer to
others are read with the references they lack.

The slots the caller holds stay its own: it gives each back with
`ReleaseVideoSlot` when its own use of it is over. A slot handed out
by an event that was dropped is free at once.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a task will do.

**OWNERSHIP**

The last packet's bytes are the caller's again.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ParseVideoPacket`, `ReleaseVideoSlot`

**EXAMPLES**

```zig
_ = mb.SeekMedia(film, track, time);
vpb.ResetVideoParser(parser);
```
