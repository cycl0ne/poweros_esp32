# Player

Player plays sound files - WAV, MP3, FLAC and Ogg Vorbis - in a window,
with a picture of the sound under its controls: a plasma, the wave, or
the spectrum's bars.

## Starting it

Double-click its icon, double-click a `.mp3`, `.wav`, `.flac` or `.ogg`
file, or type in a shell:

```
Player FILES/M,VOLUME/K/N,LOOK/K
```

- `FILES` are played one after another - or shuffled, with **Shuffle**.
- `VOLUME` is in percent of as recorded (100), up to 200: up to 100 as
  loud as it sounds - half way is -18 dB - and past it a boost, 200
  twice as loud as recorded.
- `LOOK` is the picture to start with: `PLASMA`, `WAVE` or `BARS`.

A file dropped on the window from the desktop, or picked with
**Project > Open...**, is played at once, in place of the files it was
playing. The file requester starts in the drawer of the song playing;
the sound and the picture go on while it is up.

## What the window shows

The window's title is the song's: `Fire - Player`.

- The song's cover: the picture its tags hold, or one lying beside the
  file - `cover.jpg`, `folder.jpg`, `front.jpg`, `cover.png` or
  `folder.png`. A picture that is not square shows its middle. The cover
  grows with the window, square, from 64 to 160 pixels.
- Beside it, one block of lines in the middle of the room, what the tags
  say: the title, large and bold - or the file's name - and the artist;
  under them, dimmer, the album and its year, the genre, the track and
  the composer; the chapter that is playing when the song is marked in
  chapters, as a DJ mix or an audiobook is, or else a comment; and the
  kind of file, its rate, mono or stereo, and its bit rate. A line the
  tags have nothing for is left out, and the window grows when a song
  needs more lines than it has room for. A line too long for the room
  ends in three dots. The title is in the window's font, half again as
  tall, when diskfont.library can render it so; the dim lines are in
  the screen's dim text colour, which **Prefs > Colours** sets as
  *Dim text*.
- A slider across that is where the song is, the time heard before it
  and the song's length after it. Drag it to go to another place; the
  time shows where while it is held. A press on the length shows what is
  left of the song instead (`-3:16`), and another the length again. A
  song of an hour or more shows its hours (`1:02:33`).
- The buttons of a tape deck. Play starts, pause holds the sound and goes
  on, stop goes back to the start; rewind and fast forward jump ten
  seconds back or on. At its ends, the song before and the song after:
  the song before goes back a song within the first three seconds of
  one, and later to the start of this one. A song reached so plays when
  the deck was playing, waits at its start when it was paused, and is
  only shown when it was stopped.
- **Shuffle** plays the list in an order of its own, from the song
  playing on; the list keeps its own order, and turned off it goes on in
  that from the song playing.
- **Repeat** goes round three ways with each press: off, the whole list
  - which starts again after its last song, shuffled anew when shuffle
  is on - and the one song, again and again (its picture with a 1). Off,
  the sound stops after the last song.
- At the right, the sound: off and on again (a press on the volume
  turns it on again too), the volume, and the output the machine plays
  through - its speaker, headphones, a USB speaker. Picking another
  plays every sound through it from then on; one plugged in or out shows
  in the list. In a window too narrow for the whole row, it stands in
  two lines or more, and the window grows to keep everything in it.

Under them, as big as the window lets it be and sunk in a frame, the
picture:

- **Plasma**: waves of colour that move faster with the bass, turn their
  colours with the treble and light up with the loudness.
- **Wave**: the sound itself, about a hundredth of a second of it, held
  still where it crosses the middle going up; what was drawn before fades
  away behind it.
- **Bars**: the spectrum from 40 Hz at the left to 16 kHz at the right,
  each bar a share of an octave, with a mark where its peak was.

A press on the picture goes to the next one; the **Picture** menu picks
one and ticks the one shown. The picture keeps in step with what is
heard, not with what has been decoded: the sound card's own delay is
taken off. When the sound stops, the picture settles for two
seconds and then rests until something plays.

A song is shown before it is heard: its names and its cover first, then
its sound. Reading a large cover takes a moment, and the sound starts
after it rather than stumbling while it is read.

On a machine with no sound the window opens all the same and says so,
and a song picked still shows its cover and tags - as it does when all
sixteen of the sound's streams are in use.

## Keys

- Space pauses and goes on; when nothing plays, it starts.
- S turns shuffle on and off, R goes round repeat's three ways, M turns
  the sound off and on, O opens the output's list.
- Right-Amiga O opens a song.
- Right-Amiga Q ends it.

## Ending it

The window's close gadget, **Project > Quit**, or Ctrl-C in the shell it
was started from.
