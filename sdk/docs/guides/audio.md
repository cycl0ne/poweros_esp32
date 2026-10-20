# Sound

`audio.device` plays sound out of the board: through an ES8311 codec
and the speaker or jack behind it, or straight into I2S amplifiers - the
CrowPanel's two speakers. It is in the ROM of every board that has one of
these, and of both QEMUs, where the sound goes into nothing in time. A
program opens a **stream**, says what its samples are, and writes buffers
to it; the device mixes every stream into the output. Unit 1 is the way
the other round: the **recording**, read from the codec's microphone
input in the form the program asks for.

This guide is a stream first, then writing to it as it plays, what the
board has, the master volume, sound decoded from a file
(audiocodec.library), the outputs and ways in underneath (rta.library),
and recording.

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
null, as much of it as `std.length` holds, `std.actual` saying how much,
so a program built when the structure was shorter gets the fields it
knows - and answers the stream's `position`, the frames it has played
since it was opened:

| Field | What |
|---|---|
| `rate` | the rate the output runs at |
| `channels` | 1 for one speaker or a codec with one output, 2 for two speakers |
| `bits` | bits a sample at the output |
| `latency` | frames between a write's first frame being mixed and its being heard |
| `streams`, `max_streams` | streams open now, and how many may be |
| `master` | the master volume |
| `has_input` | 1 when unit 1 records on this board: it has a way in |
| `output` | the output played through: the part the sound comes out of, as the board names it, or `null` |
| `underruns` | buffers the output played again because the next was not mixed in time - each a gap heard - since its driver made it |
| `output_id` | the output's number (below), since version 3 |
| `triggers`, `max_triggers` | sounds playing by trigger now, and how many may, since version 4 |
| `input`, `input_id` | the way in recorded from - or that a recording would be - and its number, since version 5 |
| `input_channels` | the most sides it hears: 1 for one microphone |
| `input_rate` | the rate it runs at while a recording runs, else 0 |
| `overruns` | buffers of it lost - filled before the one before was taken, or heard while no read waited between two reads - each a gap in a recording |

A stereo stream on a board with one output is heard as its two sides
together, so every program is heard whole on every board; the position
and the latency are what a picture is kept in step with sound by.

## The output's rate

An output may run at more than one rate - the codecs and amplifiers
here at 48 kHz and at a CD's 44.1 kHz - and the device runs it at the
rate the open streams play in with the least converting: the mode whose
rate the most of them have. A tie goes to the output's default mode,
then to the mode with more sides, then to the higher rate; a stream at
a rate no mode has counts for none. So a player that opens one stream
at 44.1 kHz on a quiet machine has its samples go out unconverted.

The device chooses when it starts an output and again when a write
would start sound on a device that is quiet - no stream has a write.
While anything plays, the rate stays, so a change never cuts into sound
being heard: a 48 kHz click during a 44.1 kHz song is converted, and
the song goes on unbroken. The query's `rate` says what the output runs
at now.

A stream at another rate is converted by following the line between
its frames, to a 32768th of the way from one to the next, and rounded
to the nearest sample. Every sample is worked on at 16 bits: a 32-bit
one is rounded to the nearest 16-bit one, and every gain - a stream's
volume and pan, the master - is rounded the same way, so no stream is
pulled down by a fraction of a step.

## Choosing an output

A machine may have more than one output - a jack and a speaker, a DAC
plugged in - and the device plays through one of them at a time: the
**preferred** one when it is there, else the first on the list, until
a program picks another. Each output has a **number** that stays the
same from one boot to the next, worked out from its driver's name and
its own; it is what a program or a preference keeps to name it by.
These commands read it from the request's `output` - the first three
since version 3, the fourth since version 6:

| Command | What |
|---|---|
| `AUDIOCMD_NEXTOUTPUT` | the output after the one `output` names - 0 for the first - its number back in `output` and its `AudioOutputInfo` to `std.data`; `AUDIOERR_NOOUTPUT` past the last |
| `AUDIOCMD_SETOUTPUT` | the device plays through that output from now on, for every program; 0 is the first on the list again |
| `AUDIOCMD_GETOUTPUT` | the output played through: its number in `output`, its `AudioOutputInfo` to `std.data` |
| `AUDIOCMD_PREFEROUTPUT` | that output preferred, there or not (0: none) - played through at once when it is there; the number of the one played through after it in `output`. Preferring the one preferred already changes nothing |

`AudioOutputInfo` holds the number, its flags - `AUDIOOF_DEFAULT` for
the first on the list, `AUDIOOF_CURRENT` for the one played through,
`AUDIOOF_PREFERRED` for the preferred one - the most sides it plays,
the rates it runs at (`rate_count` of `rates`, lowest first), its name
and, since version 6, its `volume`. As with the query, as much of it is
written as `std.length` holds; `AudioInfo.preferred_id` is the
preferred output's number, whether it is there or not.

```zig
var info: audio.AudioOutputInfo = .{};
io.std.req.command = audio.AUDIOCMD_NEXTOUTPUT;
io.std.data = &info;
io.std.length = @sizeOf(audio.AudioOutputInfo);
io.output = 0;
while (sys.DoIO(&io.std.req) == 0) {
    // info.name, info.id; io.output is info.id, so the next DoIO goes on
}
```

A change of output does not interrupt anything: every stream goes on
from the frame it had got to, on the new output at its own rate, and
`position` goes on counting from where it was. One that will not start
leaves the one before playing and answers `AUDIOERR_NOOUTPUT`.

An output that goes while the device plays through it - a USB speaker
unplugged, a file sink a program deletes - leaves the device playing
through the preferred output, or the first on the list without it,
every stream going on where it was. With none left, writes and
triggers are answered `AUDIOERR_NOOUTPUT` until one comes, and the
next write plays through it; a machine whose only outputs come over
USB starts that way.

The preferred output coming - headphones plugged in, the USB speaker
the machine was told to prefer at boot - takes the sound over within
half a second, whatever plays and whichever output a program picked;
an output picked with `AUDIOCMD_SETOUTPUT` after it plays until the
next one comes or goes. Since a preferred output may be named before it
is there, a prefs file can name a speaker that is plugged in later.

`output` is a field at the end of `IOAudio` that version 2 had not got.
A request of that size still opens and does everything else; only the
output commands refuse it, with `IOERR_BADLENGTH`.

## The master volume

`AUDIOCMD_MASTER` sets the device's volume from `volume`, over every
stream: `AUDIO_VOLUME_UNITY` leaves them as they are. The streams are
summed and the master goes over the sum; a sum past what the output
holds is clipped, so many loud streams are better turned down here than
left to clip.

Since version 6 **each output has its own volume** - the headphones
quieter than the speaker - and the master is the volume of the output
played through. With `output` naming an output, `AUDIOCMD_MASTER` sets
that one's volume, kept for it while it is not there and in force
whenever it plays; with `output` 0, or from a request of version 2,
the one played through. An output no volume was set for plays at the
volume in force when it takes over. The device keeps
`AUDIO_MAX_VOLUMES` (16) of them, forgetting the one set longest ago
past that.

## Choosing from a program: `sdk.devices.audiocontrol`

A program that only chooses - a shell command, a preferences editor, a
window with a volume slider - opens the device with `AUDIOF_TRIGGER`,
which takes none of its streams. `audiocontrol.Control.open(sys)` does
that on a port of its own, and refuses a device older than version 6;
its calls are a DoIO each:

```zig
var control = audiocontrol.Control.open(sys) orelse return;
defer control.close();
var outputs: audiocontrol.Outputs = .{};
outputs.read(&control);              // the list, with a chooser's labels
_ = control.play(outputs.infos[1].id);
control.setVolume(0, 60);            // the one played through, at 60%
_ = control.prefer(0x24B61A00);      // there or not
```

A volume there is in percent of as recorded, 0 to 100, as a person sets
it; `percentOf` and `volumeOf` turn it into the device's and back.

## The settings kept: `audio.prefs`

`ENVARC:Sys/audio.prefs` holds a line per output - its number, its
volume in percent, its name for reading, and which one is preferred:

```
OUTPUT=24B61A00 VOLUME=80 NAME=es8311
OUTPUT=ECD5FB99 VOLUME=40 NAME="QEMU USB Audio" PREFERRED=YES
```

S:Startup-Sequence's `C:SetPrefs` hands it to the device at boot,
before the first sound, and `SetPrefs SHOW` lists what the device has
then: every output there is with its volume, and the preferred one -
by its number when it is not there. `sdk.prefs.audio` reads and writes it: `apply` hands
settings to the device, `gather` reads what the device has into them,
keeping the lines of outputs that are not plugged in.

Three places set it:

- `C:Audio` in the shell (below);
- the **Sound** page of `SYS:Programs/Prefs`: the preferred output, a
  volume per output, and the beep (what `sound.prefs` holds), with a
  Test button; Use and Save keep them, Cancel puts back what was;
- `SYS:Programs/Volume`, from its icon or the desktop's Anvil menu
  (**Volume...**): the output played through and its volume, kept when
  the window closes.

Player has an Output chooser of its own, beside its file, which plays
every sound through the output picked.

## Sounds for a moment: triggers

A click, a beep, a chime is a trigger: `AUDIOCMD_TRIGGER` plays the
request's samples at once, in the request's own `format`, `channels`,
`rate`, `volume` and pan, `loops` times over, and replies when they
have played. There is no queue and nothing to feed, no process and no
timer: the samples are the program's until the reply, and that is all.

```zig
const click = sys.CreateIORequest(port, @sizeOf(audio.IOAudio)) orelse return;
const io: *audio.IOAudio = @ptrCast(@alignCast(click));
if (sys.OpenDevice(audio.AUDIONAME, audio.AUDIO_UNIT_PLAY, &io.std.req, audio.AUDIOF_TRIGGER) != 0) return;
io.std.req.command = audio.AUDIOCMD_TRIGGER;
io.std.data = @constCast(&samples);
io.std.length = @sizeOf(@TypeOf(samples));
io.format = audio.AUDIO_S16;
io.channels = 1;
io.rate = 48_000;
sys.SendIO(&io.std.req); // replied when it has played
```

Triggers play on `AUDIO_MAX_TRIGGERS` (8) voices of their own, beside
the streams, so a trigger never takes a stream's place and a stream is
never cut for one. When all eight play, a new trigger takes the voice
of the one of lowest priority - the `pri` of the request's message node
- and of those the one that has played longest, so long as that is not
above its own; the one that gives way comes back `IOERR_ABORTED`, and a
trigger no voice gives way to `AUDIOERR_NOVOICE`. The system's beep
plays at 85, above a program's sounds at 0. `AbortIO` takes a trigger
back.

An open with `AUDIOF_TRIGGER` in OpenDevice's flags takes no stream: it
sends triggers, asks the query and the output commands and sets the
master, and a write on it is `IOERR_NOCMD`. A stream's open may send
triggers too. A trigger plays on after its open is closed; the query's
`triggers` says how many play now.

## Decoding: audiocodec.library

`LIBS:audiocodec.library` turns a sound file into the 16-bit samples a
stream plays: WAV (PCM of 8 to 32 bits, or float), MP3 (MPEG-1, 2 and
2.5, Layer III), FLAC (4 to 24 bits) and Ogg Vorbis, in one channel or
two. `OpenAudioStream` opens a file by name (`ACA_Name`), a
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
bit rate otherwise; a FLAC's from its STREAMINFO, an Ogg Vorbis file's
from its last page - and the title, artist and album from ID3 tags, a
WAV's INFO list or Vorbis comments. An MP3 is cut where its encoder says
the music begins and ends, an Ogg Vorbis stream where its pages' granule
positions say, so one song follows another without a gap. `SeekAudio`
moves a file's stream to a frame: a WAV, a FLAC (by its seek table, or a
search halving the file) and an Ogg Vorbis file (by such a search over
its pages) exactly, an MP3 by its encoder's table or its bit rate.
Decoding an MP3 takes about a tenth of a core at 44.1 kHz in stereo. A
FLAC stream holds a block of samples for each channel, 32 KiB for the
usual 4096 in stereo; an Ogg Vorbis one its codebooks and tables, about
250 KiB. A FLAC frame whose CRC is wrong plays as silence; an Ogg page
whose CRC is wrong is passed over.

### Tags, covers and chapters

`GetAudioStreamAttrs` gives the rest of what the tags say, each answer
where its tag points: the title, artist and album at full length, the
album's own artist, the composer, the genre (an ID3v1 number is named),
a comment, the year, the track and the album's count of them. An MP3's
ID3v2 tag is read whole, frame by frame, however large; an ID3v1 tag at
the end counts where it says nothing, and a WAV's INFO list says the
same. A FLAC's and an Ogg Vorbis stream's Vorbis comments say it too
(TITLE, ARTIST, ALBUM, ALBUMARTIST, COMPOSER, GENRE, DATE, TRACKNUMBER,
TRACKTOTAL, COMMENT). Texts are Latin-1: quotes and dashes become their plain kin, an
emoji is left out, anything else past Latin-1 is a `?`.

The picture the tags hold - a cover, the front one where there are
several - is kept only for a stream opened with `ACA_KeepPicture`, so a
program that does not show it does not read it. `ACA_Picture` then
answers the bytes of an image file - a JPEG or PNG - for
datatypes.library to read - an ID3v2 picture, a FLAC's PICTURE block,
or an Ogg stream's METADATA_BLOCK_PICTURE comment. The chapters a mix or
an audiobook is marked in (ID3v2 `CHAP` frames, or the `CHAPTER001` and
`CHAPTER001NAME` comments) come with `ACA_Chapters` and
`ACA_ChapterList`: where each starts and ends, in milliseconds, and its
title.

```zig
const stream = acb.OpenAudioStream(&[_]utility.TagItem{
    .{ .tag = ac.ACA_Name, .data = @intFromPtr("SD0:Music/song.mp3") },
    .{ .tag = ac.ACA_KeepPicture, .data = 1 },
    .{},
}, &err) orelse return;
var year: u32 = 0;
var cover: ?*const ac.AudioPicture = null;
var chapters: u32 = 0;
_ = acb.GetAudioStreamAttrs(stream, &[_]utility.TagItem{
    .{ .tag = ac.ACA_Year, .data = @intFromPtr(&year) },
    .{ .tag = ac.ACA_Picture, .data = @intFromPtr(&cover) },
    .{ .tag = ac.ACA_Chapters, .data = @intFromPtr(&chapters) },
    .{},
});
```

Everything handed out is the stream's, good until it is closed.

A program that only wants a file heard - an alarm, a notification -
leaves all of this to datatypes.library: a sound file is a
`sound.datatype` object that plays itself on a process of its own
(the [datatypes guide](datatypes.md#sounds)).

`C:Play FILE` plays a file this way, with `VOLUME` and `START` (seconds
in); Ctrl-C stops it. `SYS:Programs/Player` does it in a window, and is
what the desktop opens a `.mp3`, `.wav`, `.flac` or `.ogg` file with
(the `MP3`, `WAV`, `FLAC` and `Ogg` descriptors in `DEVS:DataTypes`),
with the song's cover and tags and the chapter of a mix that is
playing.

## Keeping a picture in step

A program that shows the sound - a level meter, a wave, a spectrum -
shows what is heard, not what it last decoded: by then, a buffer or two
is queued behind what plays. `AUDIOCMD_QUERY` with `std.data` null
answers only the stream's `position`, which is cheap enough to ask for
every picture. The frame being heard is that position less the output's
`latency`, which is in the output's frames and so is scaled by the
stream's rate over the output's:

```zig
io.std.req.command = audio.AUDIOCMD_QUERY;
io.std.data = null;
_ = sys.DoIO(&io.std.req);
const heard = io.position -% info.latency * stream_rate / info.rate;
```

Each frame written is counted from the same start, so a program keeps
what it wrote in a ring indexed by that count and reads the picture's
samples at `heard`. The request asked with is best kept on a reply port
of its own: a `DoIO` that has to wait takes its port's signal, which
would otherwise tell the program that one of its writes came back.

## Outputs and ways in: rta.library

The device plays through an **output** of rta.library, the ROM's list of
the machine's sound outputs and ways in, and the drivers behind them. A driver makes
its outputs - sinks - at its own cold start, from the parts the board's
system list names (expansion.library's `FindBoardPart`): one for each
part it can drive. audio.device takes the first sink on the list when it
is first opened and starts it; it reads only the sink's mode - its rate,
whether one side or two is heard, which half of a frame is which - and
its ring of buffers. No name of a part or a chip is in the device.

| Driver | Kind | What it makes |
|---|---|---|
| `i2s` | line | a line on the chip's I2S controller, for a part fed over I2S: a DMA ring each way, an interrupt each, its pads, the buffers it played again and those it lost; clocked for the rate of the mode its sink or source starts in |
| `es8311` | sink, source | the ES8311 codec, set up over i2c.device, on a line of its own; its amplifier's enable pad; where the board wires its data out, its microphone input as a source on the same line |
| `i2samp` | sink | an amplifier that takes I2S itself - the CrowPanel's pair, one part with two sides - on a line of its own |
| `null` | sink, source | a stream into nothing, kept in time by timer.device's E-clock: the emulators' output, at the bottom of the list; and a source that hears what it played, two buffers late |
| `file` | sink | a WAV file, written in time as a speaker would play it; none until a program makes one (below) |
| `uac` | sink | a USB speaker, headset or sound adapter of the audio class, made as it is plugged in and deleted as it goes (`DEVS:usb/uac.device`) |

A sink for a part on I2S is made over a line (`RTAA_Transport`): the
sink's driver brings its part up and starts the line, and the line runs
the buffers. Sinks are on the list by priority (`RTAA_Priority`), so a
real output always comes before `null`.

A sink's modes are its driver's: each a rate, the bits a sample its part
takes, how many sides are heard and which half of a frame is which.
`NextSinkMode` walks them, `FindSinkMode` finds one by rate and sides,
and `SetSinkMode` picks the one a stopped sink starts in. Whatever the
mode, the buffers a sink runs on are 16-bit stereo: a part that takes
more bits widens them in its driver.

```zig
const rta = sdk.rta;

const rb: *sdk.interface.rta.RtaBase = @ptrCast(sys.OpenLibrary(rta.RTANAME, rta.RTA_VERSION) orelse return);
defer sys.CloseLibrary(@ptrCast(@alignCast(rb)));
var sink = rb.NextSink(null);
while (sink) |each| : (sink = rb.NextSink(each)) {
    const mode = rb.SinkMode(each).?;
    // each.node.name, mode.rate, mode.channels, each.buffer_frames * each.buffers
}
```

A driver of a new part follows the same shape: it opens rta.library at
cold start (after 33), hands in an `RtaDriver` of the sink kind with
`AddRtaDriver`, and calls `CreateSinkTagList` for each part it finds; the
library allocates the sink and its driver's instance beside it, and calls
the driver's `create_sink` to fill in its modes, its ops and its ring.
The calls are in [rta's autodoc](../autodocs/rta.md); the types in
`sdk/libs/rta/`.

A sink deleted while it plays is taken off the list at once and marked
`AUDIOSF_GONE`, and the task playing through it is signalled with the
mask it started it with; it is freed when that task stops it. A driver
whose part goes - a USB speaker pulled out - deletes its sink and waits
for its `destroy`.

### Into a file

The `file` driver makes a sink that plays into a WAV file
(`sdk/libs/rta/filesink.zig`): `FILEA_Name` the file, 16-bit stereo at
48 or 44.1 kHz, in time, as a real output would. Each start writes the
file anew, from the first buffer that is not silent; a stop fills in the
header's lengths. A program makes one, has the device play through it,
and goes back:

```zig
const tags = [_]utility.TagItem{
    .{ .tag = rta.filesink.FILEA_Name, .data = @intFromPtr(@as([*:0]const u8, "RAM:out.wav")) },
    .{ .tag = rta.tags.RTAA_Priority, .data = @bitCast(@as(isize, -120)) },
    .{},
};
const sink = rb.CreateSinkTagList(rta.filesink.FILE_DRIVER_NAME, &tags) orelse return;
io.std.req.command = audio.AUDIOCMD_SETOUTPUT;
io.output = sink.id;
_ = sys.DoIO(&io.std.req);
// ... play ...
io.output = before; // what AUDIOCMD_GETOUTPUT said
_ = sys.DoIO(&io.std.req); // the file closed as its sink stops
rb.DeleteSink(sink);
```

A low priority keeps it from ever being the default. The file is
written by a process of the sink's own, so the task that plays never
waits on a disk; a buffer the disk is too slow for is lost, and the
count is in the console's log as the file is closed.

### USB speakers and headsets

`DEVS:usb/uac.device` drives the USB audio class: a streaming interface
with an isochronous OUT endpoint, linear PCM, one or two channels of 16,
24 or 32 bits, at 48 kHz. Each is a sink named as the device names its
product, at the bottom of the board's own outputs. Started, its
interface is put in its setting, its rate set where the endpoint has
the control, its feature unit's mute lifted and its volume set to 0 dB
(or its most below that); then three buffers of ten milliseconds go
round as isochronous transfers. It needs a controller with isochronous
transfers - xhci.device - and declines a device on any other.

A **source** is a way in, on a list of its own: a driver of the source
kind makes them with `CreateSourceTagList`, `NextSource` walks them,
`NextSourceMode` their modes. `StartSource` starts one in a mode - its
default for none - for a task and a signal, which is raised each time a
buffer has been filled; `SourceBuffer` hands out the one filled last,
and a buffer filled before the one before it was taken is counted in the
source's `overruns`. Its buffers are 16-bit stereo, as a sink's; a part
that hears one side (`AUDIOSIDES_MONO`) has it in the first half of each
frame. A source's number is worked out as a sink's, so a codec's way in
and its way out have the same one.

A line carries both ways at once - `StartAudioTransportInput` and
`AudioTransportInput` beside the output's calls - at one rate: the way
started second has to be started at the rate the first runs at, or is
refused `RTAERR_BAD_MODE`. A line with no data-in pad has no way in
(`RTAERR_NO_INPUT`).

## Recording

Unit 1 records: what the first way in on rta.library's list hears - the
ES8311's microphone input, or in QEMU the null source, which hears what
was played. One program records at a time; a second open is refused
`AUDIOERR_NOSTREAM`, and on a board with no way in the open fails
`AUDIOERR_NOINPUT`. The request at OpenDevice says what the program
wants, as for a stream: the form, the channels, the rate - the device
converts from the rate the way in runs at, the line between two heard
frames to 32768ths, as the mixer does - and the volume, a gain on what
is heard.

```zig
var rec: audio.IOAudio = .{ .format = audio.AUDIO_S16, .channels = 1, .rate = 48_000 };
rec.std.req.message.reply_port = port;
rec.std.req.message.length = @sizeOf(audio.IOAudio);
if (sys.OpenDevice(audio.AUDIONAME, audio.AUDIO_UNIT_RECORD, &rec.std.req, 0) != 0) return;
defer sys.CloseDevice(&rec.std.req);

var samples: [4800]i16 = undefined; // a tenth of a second
rec.std.req.command = sdk.exec.CMD_READ;
rec.std.data = &samples;
rec.std.length = @sizeOf(@TypeOf(samples));
_ = sys.DoIO(&rec.std.req); // back when it is full
```

`CMD_READ` fills `std.length` bytes, whole frames, and is replied when
they are, `std.actual` the bytes recorded. The way in starts with the
first read and stops at the close. Reads queue and follow each other
without a gap, so a program that records for longer keeps two or three
out and sends each again as it comes back; what is heard while none
waits is lost, and the query counts it in `overruns` once a read comes
after it. `CMD_STOP` and `CMD_START` hold the recording and go on -
nothing heard meanwhile is recorded - `CMD_FLUSH` and `AbortIO` give the
reads back `IOERR_ABORTED` with the bytes each holds, and
`AUDIOCMD_SETPARAMS` changes the rate and the volume at once and the
form for the reads sent after it. The query's `position` is the frames
recorded since the open.

A way in of the output's own part - the two halves of one codec, on one
line - runs at the rate the output runs at, and while it records, the
output is only started again in a mode at that rate; recording at
another rate is converted. A part with one microphone is recorded on
both channels of a two-channel recording, and two sides into one channel
are their middle.

The CrowPanel's two PDM microphones are not a way in yet: the board's
system list names no pads for them.

## From the shell

`C:Audio` shows and sets the outputs:

```
Audio                         the output played through, its rate and
                              volume; the preferred one; the streams
Audio LIST                    every output: name, number, sides, rates,
                              volume, which plays and which is preferred
Audio OUTPUT es8311           play through that one from now on
Audio PREFER ECD5FB99         prefer that one, there or not (NONE: none)
Audio VOLUME 60               the one played through at 60%
Audio OUTPUT es8311 VOLUME 80 SAVE
                              and kept in ENV: and ENVARC:audio.prefs
```

An output is named by its name, any case, or by its number as `LIST`
shows it; given anything to do, `Audio` prints nothing unless something
goes wrong, so S:User-Startup can set the sound up.

`C:test/Audio` says what the board has and plays a note:

```
C:test/Audio                  440 Hz for two seconds
C:test/Audio HZ 220 SECONDS 5 PAN -100
C:test/Audio CHORD            a major chord, three streams at once
C:test/Audio BENCH 16         sixteen streams for ten seconds, then the
                              gaps and the device task's share of a core
C:test/Audio OUTPUTS          every output: name, number, sides, rates
C:test/Audio OUTPUT Headphones
                              play through that one from now on
C:test/Audio TRIGGER 10       ten clicks as fast as they can be sent,
                              then what became of each, and the gaps
C:test/Audio TOFILE RAM:note.wav
                              the note into a WAV file (a file sink)
```

In QEMU the output is `null`: the sound is mixed as on a board, buffer
for buffer at 48 kHz, and goes nowhere, so a program that plays runs as
it would on a board, and `C:test/Audio BENCH` measures the mix. QEMU's virt
machine with `-device qemu-xhci -device usb-audio,audiodev=snd` and an
audiodev has a USB speaker, which uac.device plays through; with
`-audiodev wav,id=snd,path=out.wav,out.mixing-engine=off` what it was
sent lands in a WAV file on the host, sample for sample.

`./zig build audio-bench` times the mixer on the host, for 1, 4, 8 and
16 streams; the board's own figure is `C:test/Audio BENCH`'s. The mixer is held
to a reference mix byte for byte by a host test
(`src/rom/devs/audio/golden.zig`); a change to it that is meant to change
what is heard writes the reference again with `./zig build audio-golden`.

`C:Record FILE` records the way in into a WAV file until Ctrl-C, or for
`SECONDS`; by default at the output's rate, with as many channels as the
way in hears, in 16 bits:

```
Record RAM:take.wav SECONDS 10
Record RAM:voice.wav RATE 16000 CHANNELS 1 VOLUME 200
Run Play SYS:song.mp3
Record RAM:loop.wav SECONDS 5     in QEMU: what Play plays, heard back
```

It says where it records from and, at the end, how long it recorded and
how many buffers were lost; `Play` plays the file back.

`C:test/Sound FILE` plays a file through datatypes.library with no
window, waiting for the object's signal that it has played out:

```
Sound SD0:Music/song.mp3 VOLUME 50
Sound SYS:tone.8svx CYCLES 3
```
