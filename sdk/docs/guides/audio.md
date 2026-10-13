# Sound

`audio.device` plays sound out of the board: through an ES8311 codec
and the speaker or jack behind it, or straight into I2S amplifiers - the
CrowPanel's two speakers. It is in the ROM of every board that has one of
these. A program opens a **stream**, says what its samples are, and
writes buffers to it; the device mixes every stream into the output.

This guide is a stream first, then writing to it as it plays, what the
board has, the master volume, and sound decoded from a file
(audiocodec.library).

## A stream

Each OpenDevice of unit 0 is a stream of its own. Up to sixteen play at
once, and nothing is taken from anyone: a program that wants music and a
click at the same time opens the device twice.

What a stream plays is given in the request at the open:

| Field | What |
|---|---|
| `format` | `AUDIO_S8`, `AUDIO_S16` or `AUDIO_S32` - signed, in the machine's byte order; a 24-bit sample is a 32-bit one with its low byte zero |
| `channels` | 1, or 2 interleaved, left first |
| `rate` | frames a second, 1 to 192000 - converted to the output's rate |
| `volume` | `AUDIO_VOLUME_UNITY` is as recorded, up to four times that |
| `pan` | `-AUDIO_PAN_FULL` left only, 0 both alike, `AUDIO_PAN_FULL` right only |

```zig
const audio = sdk.devices.audio;

const port = sys.CreateMsgPort() orelse return;
defer sys.DeleteMsgPort(port);
const io: *audio.IOAudio = @ptrCast(@alignCast(sys.CreateIORequest(port, @sizeOf(audio.IOAudio)) orelse return));
defer sys.DeleteIORequest(&io.std.req);
io.format = audio.AUDIO_S16;
io.channels = 2;
io.rate = 44_100;
if (sys.OpenDevice(audio.AUDIONAME, audio.AUDIO_UNIT_PLAY, &io.std.req, 0) != 0) return;
defer sys.CloseDevice(&io.std.req);
```

A form, a channel count or a rate the device does not take fails the open
with `AUDIOERR_BADFORMAT`; a seventeenth stream with `AUDIOERR_NOSTREAM`.
`AUDIOCMD_SETPARAMS` changes them later: the rate, volume and pan at once,
the form for the writes sent after it - each write keeps the form it was
sent in.

## Writing

`CMD_WRITE` plays a buffer - `std.data`, `std.length` in bytes, whole
frames - `loops` times over (1 by default; 0 plays it until it is flushed
or aborted, which is what a sound repeated for a while is). It is replied
when its last frame has been played, with `std.actual` the bytes played,
and until then the memory is the device's to read.

Writes queue without a limit and follow one another without a gap, so a
program that makes its sound as it goes - music decoded a piece at a
time - keeps two or three buffers going round: it fills one while the
others play, writes it, and fills the next as each comes back.

```zig
var requests: [2]*audio.IOAudio = .{ io, second }; // second: a copy of io
var buffers: [2][4096]i16 = undefined;
for (requests, &buffers) |request, *buffer| {
    const frames = decode(buffer); // stereo frames written into buffer
    request.std.req.command = exec.CMD_WRITE;
    request.std.data = buffer;
    request.std.length = frames * 4;
    request.loops = 1;
    sys.SendIO(&request.std.req);
}
var next: usize = 0;
while (true) {
    _ = sys.WaitIO(&requests[next].std.req); // this buffer has been heard
    const frames = decode(&buffers[next]);
    if (frames == 0) break;
    requests[next].std.length = frames * 4;
    sys.SendIO(&requests[next].std.req);
    next = 1 - next;
}
```

The rest, on the stream the request was opened on:

- `CMD_STOP` holds the stream where it is; `CMD_START` goes on.
- `CMD_FLUSH` answers every write `IOERR_ABORTED`; `CMD_RESET` does the
  same and starts a stopped stream.
- `AbortIO` takes one write back: one that waits, or the one that plays,
  which stops, the next going on.
- `CloseDevice` answers whatever writes are left with `IOERR_ABORTED`.

## What the board has

`AUDIOCMD_QUERY` writes an `AudioInfo` to `std.data` - when it is not
null and `std.length` is large enough - and answers the stream's
`position`, the frames it has played since it was opened:

| Field | What |
|---|---|
| `rate` | the rate the output runs at |
| `channels` | 1 for one speaker or a codec with one output, 2 for two speakers |
| `bits` | bits a sample at the output |
| `latency` | frames between a write's first frame being mixed and its being heard |
| `streams`, `max_streams` | streams open now, and how many may be |
| `master` | the master volume |
| `has_input` | whether unit 1 records on this board |
| `output` | the part the sound comes out of, as the board names it |

A stereo stream on a board with one output is heard as its two sides
together, so every program is heard whole on every board; the position
and the latency are what a picture is kept in step with sound by.

## The master volume

`AUDIOCMD_MASTER` sets the device's volume from `volume`, over every
stream: `AUDIO_VOLUME_UNITY` leaves them as they are. The streams are
summed and the master goes over the sum; a sum past what the output
holds is clipped, so many loud streams are better turned down here than
left to clip.

## Decoding: audiocodec.library

`LIBS:audiocodec.library` turns a sound file into the 16-bit samples a
stream plays: WAV (PCM of 8 to 32 bits, or float) and MP3 (MPEG-1, 2 and
2.5, Layer III). `OpenAudioStream` opens a file by name (`ACA_Name`), a
file the program has open (`ACA_FileHandle`), or bytes a function of the
program's hands over (`ACA_ReadFunc`, `ACA_ReadData`) - a download, a
network stream - and finds the kind by its first bytes. `DecodeAudio`
then fills a buffer with as many frames as asked for, until the end; the
file is decoded as it plays, never whole.

```zig
const acb: *sdk.interface.audiocodec.AudioCodecBase = @ptrCast(sys.OpenLibrary(ac.AUDIOCODECNAME, 1) orelse return);
defer sys.CloseLibrary(@ptrCast(acb));
var err: i32 = 0;
const stream = acb.OpenAudioStream(&[_]utility.TagItem{
    .{ .tag = ac.ACA_Name, .data = @intFromPtr("SD0:Music/song.mp3") },
    .{},
}, &err) orelse return;
defer acb.CloseAudioStream(stream);
var info: ac.AudioStreamInfo = .{};
acb.GetAudioStreamInfo(stream, &info);
// open audio.device with format AUDIO_S16, info.channels, info.rate,
// then as above: decode into a buffer, write it, decode the next
const got = acb.DecodeAudio(stream, &buffer, 4096); // frames, 0 at the end
```

`GetAudioStreamInfo` says the kind, rate, channels and length - exact
for an MP3 whose encoder wrote an Info or Xing frame, worked out from the
bit rate otherwise - and the title, artist and album from ID3 tags or a
WAV's INFO list. An MP3 is cut where its encoder says the music begins
and ends, so one song follows another without a gap. `SeekAudio` moves a
file's stream to a frame: a WAV exactly, an MP3 by its encoder's table or
its bit rate. Decoding an MP3 takes about a tenth of a core at 44.1 kHz in
stereo.

`C:Play FILE` plays a file this way, with `VOLUME` and `START` (seconds
in); Ctrl-C stops it.

## Recording

Unit 1 is the way in - the ES8311's input, the CrowPanel's microphones.
It is not driven yet: opening it fails with `AUDIOERR_NOINPUT`.

## From the shell

`C:test/Audio` says what the board has and plays a note:

```
Audio                         440 Hz for two seconds
Audio HZ 220 SECONDS 5 PAN -100
Audio CHORD                   a major chord, three streams at once
```
