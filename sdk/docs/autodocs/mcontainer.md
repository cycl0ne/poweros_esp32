# mcontainer

A container module's functions (SINCE media 1.5): what media.library
calls a kind of container's code in LIBS:codecs/ with
(sdk/libs/media/mcontainer.zig); the base is the module's, opened with
OpenLibrary("codecs/<kind>.container"). Two tasks may each read a track
of their own at once; `file.lock` lets one at a time at the source. A
module answers MERR_UNSUPPORTED to a file whose layout is not its own.

Generated from the source by `./zig build autodoc`.

## Index

- [CloseContainer](#closecontainer) - What the module holds of the file given back, if it made anything: after a failed open too.
- [OpenContainer](#opencontainer) - The file's index read, its tracks and tags made out of it, and every track at its first packet: 0, or MERR_*.
- [ReadContainerPacket](#readcontainerpacket) - The track's next packet into `packet`: 0, MERR_END, or MERR_*.
- [SeekContainer](#seekcontainer) - The track moved to the key packet at or before `time`, in microseconds: 0, or MERR_*.

## CloseContainer

What the module holds of the file given back, if it made anything: after a failed open too.

**SYNOPSIS**

```zig
void CloseContainer(*mcontainer.MediaContainerFile file)
```

**BEHAVIOR**

The file and its tracks' buffers stay the library's.

## OpenContainer

The file's index read, its tracks and tags made out of it, and every track at its first packet: 0, or MERR_*.

**SYNOPSIS**

```zig
i32 OpenContainer(*mcontainer.MediaContainerFile file, bool check)
```

**BEHAVIOR**

With `check`, MERR_UNKNOWN when the bytes are not its kind's. On what
opened the file, which it reads.

## ReadContainerPacket

The track's next packet into `packet`: 0, MERR_END, or MERR_*.

**SYNOPSIS**

```zig
i32 ReadContainerPacket(*mcontainer.MediaContainerFile file, u32 track, *media.MediaPacket packet)
```

**BEHAVIOR**

Its bytes are in the track's buffer, good until the track's next read or
seek.

## SeekContainer

The track moved to the key packet at or before `time`, in microseconds: 0, or MERR_*.

**SYNOPSIS**

```zig
i32 SeekContainer(*mcontainer.MediaContainerFile file, u32 track, i64 time)
```

**BEHAVIOR**

The file can seek; `track` is one it has.
