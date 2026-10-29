# Player

Player plays sound files - WAV, MP3, FLAC and Ogg Vorbis - and internet
stations in a window, with a picture of the sound under its controls: a
plasma, the wave, the spectrum's bars, left against right, or a meter
for each side - in the window or over the whole screen.

Its menus, tabs, buttons, lists' headings, the lines beside the cover
and why a station or a search failed are in the language chosen on
Prefs' Region page when there is a catalog for it - German is on the
disk, in `LOCALE:Catalogs/deutsch/programs/Player.catalog` - and in
English otherwise.

## Starting it

Double-click its icon, double-click a `.mp3`, `.wav`, `.flac` or `.ogg`
file - or a list, `.m3u`, `.m3u8` or `.pls` - or type in a shell:

```
Player FILES/M,ADD/S,VOLUME/K/N,LOOK/K
```

- `FILES` make the playlist, played one after another - or shuffled,
  with **Shuffle**. A drawer adds its sound files by name, then those of
  the drawers in it; an address - `http://...` or `https://...` - adds
  a station (see *Stations*); a list adds what it names (see *Lists*).
- `ADD` adds the files to the list there is - the one the Player kept -
  instead, and plays none of them.
- `VOLUME` is in percent of as recorded (100), up to 200: up to 100 as
  loud as it sounds - half way is -18 dB - and past it a boost, 200
  twice as loud as recorded.
- `LOOK` is the picture to start with: `PLASMA`, `WAVE`, `BARS`, `SCOPE`
  or `METERS`.

Each left out is as the Player was left; started without files, it opens
with the list it had and the song it showed, paused where it stopped
(see *Remembered*).

There is one Player. Started while it runs, it hands what it was given
to the one running and ends at once: the files are added to that list
and the first played - with `ADD` only added - and `VOLUME` and `LOOK`
are set. Without `ADD` the window comes to the front and is made
active, which is all `Player` alone does - and what a click on the
dock's Player docklet runs. The docklet shows what plays as a note in a
ring that fills with the song, two bars while it pauses; it asks the
Player at its port twice a second (`sdk.player`). A song double-clicked
on the desktop plays in the Player that is open. A name is handed over as the
file's full name, so a name typed in a shell's drawer is found.

Files dropped on the window from the desktop are added to the
playlist - a drawer its sound files - and the first is played when
nothing plays. **Project > Open...** picks songs, several at once, that
are added and the first played; **Project > Open drawer...** picks a
drawer, whose sound files are added and played the same way. The file
requester starts in the drawer of the song shown; the sound and the
picture go on while it is up. **Project > Open URL...** asks for a
station's address, and the **Radio** page has stations to pick and finds
more (see *Radio*).

## What the window shows

The window's title is the song's: `Fire - Player`.

- The song's cover: the picture its tags hold, or one lying beside the
  file - `cover.jpg`, `folder.jpg`, `front.jpg`, `cover.png` or
  `folder.png`. A picture that is not square shows its middle. The cover
  grows with the window, square, from 64 to 160 pixels, with round
  corners in a sunk edge; a song without one shows a note. A click on the
  cover shows it at its own size in a window of its own - as much of it
  as the screen holds, kept in its shape when the window is sized - which
  its close gadget or Esc closes. That window follows the songs: the
  next song's cover takes the last one's place in it, and a song without
  one closes it.
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
  song of an hour or more shows its hours (`1:02:33`). With no song, or
  one that cannot be read, the slider is empty and still.
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
  in the list. Last, **EQ**: that output's equalizer by its preset -
  Flat, Classical, Jazz, Rock, Speech, More bass, Small speaker and the
  rest, as `Audio EQ` and Prefs' Sound page name them - or Custom when
  its bands are none of them, which the list holds only then; a preset
  picked is heard at once, and one set elsewhere shows within a second
  while a song plays. It is ghosted when the device has no equalizer. In
  a window too narrow for the whole row, it stands in two lines or more,
  and the window grows to keep everything in it.

Under them, as big as the window lets it be, three tabs: **Now playing**
with the picture, **Playlist** with the list, and **Radio** with the
stations.

## The picture

Sunk in a frame, one of five:

- **Plasma**: waves of colour that move faster with the bass, turn their
  colours with the treble and light up with the loudness.
- **Wave**: the sound itself, about a hundredth of a second of it, held
  still where it crosses the middle going up; what was drawn before fades
  away behind it.
- **Bars**: the spectrum from 40 Hz at the left to 16 kHz at the right,
  each bar a share of an octave and a pixel from the next, with a mark
  where its peak was.
- **Scope**: left against right, a point for each moment: what both
  sides share stands upright, what is only on the left leans up to the
  left and only on the right up to the right, and a sound wide apart
  spreads across. What was drawn before fades away behind it.
- **Meters**: a bar for each side, the left above the right, as long as
  the side is loud - from 48 dB down to full - with a tick every 6 dB
  between them and a mark where its peak was, held for a moment and
  then let fall.

With a cover, the plasma, the bars and the meters are drawn in its
colours: the two it has most of, grey, black and white left out. The
plasma runs from one to the other and back, the bars go from the first
at the foot to the second at the top, and the meters from the first at
their left end to the second at their right. Without a cover, or with one of hardly any colour, they
keep their own.

A press on the picture goes to the next one; the **Picture** menu picks
one and ticks the one shown.

**Over the whole screen**: Picture > Whole screen, the F key, or a
double-click on the picture - which shows the one it was before the
first press - shows the picture over everything on the screen, the dock
too, with no pointer. At each new song its title and artist fade in at
the lower left, stay three seconds and fade out. A key or a press of any
button ends it, and the picture is back in the window. The picture keeps in step with what is
heard, not with what has been decoded: the sound card's own delay is
taken off. When the sound stops, the picture settles for two
seconds and then rests until something plays.

## The playlist

Each song's place, title, artist and length, the one shown in bold with
a mark at its start. A song added shows its file's name at first; its
tags are read a few songs at a time while the window has nothing else
to do, and its row fills in. "song 3 of 12" beside the kind of file is
the song's place in the list.

- A double-click on a song, or Return, plays it.
- **Remove**, or Del, takes the song selected out of the list. The song
  shown taken out makes way for the one after it, which starts as the
  deck was; after the last there is no song.
- **Clear** takes every song out.
- **Add...** picks songs to add, several at once; a drawer named adds
  its sound files.
- A song dragged up or down moves in the list. A press on a heading
  sorts the list by it - the time by how long - and a second press turns
  the order round; the list stays sorted as songs come and their tags
  are read.

With shuffle on, a song added goes to a random place among the songs
still to come, and a song picked to play starts a new shuffle from it.

## Lists

A list file names songs and stations, a line each: M3U (`.m3u`), its
UTF-8 form M3U8 (`.m3u8`), or PLS (`.pls`). Wherever a file can be
given - in a shell, by **Open...** or **Add...**, dropped on the window,
or double-clicked on the desktop - a list adds what it names, in its
order:

- A name is found from the list's own drawer: `Demo.mp3`, `More/Demo.mp3`,
  `../Tones/A.mp3` one drawer up, `/Music/A.mp3` from the root of the
  list's volume; a full name (`Work:Music/A.mp3`) and an address stand
  as they are. `\` parts names as `/` does.
- A list named in a list is read too, four deep at most.
- `#EXTINF` lines give a title and a length, which stand in the row until
  the song's own tags are read; a PLS's `Title` and `Length` the same.
  A station keeps its title.
- An M3U without `#EXTM3U` is a plain list of names. The text is read as
  UTF-8 when it is valid UTF-8, and as Latin-1 otherwise.

**Project > Save playlist...** writes the list as an M3U file, with the
save requester: `#EXTINF` lines with each song's title and length, in
UTF-8. A song in the drawer the list is saved in, or below it, is named
from there, so the drawer can move with its list; any other by its full
name. A name without `.m3u` or `.m3u8` gets `.m3u`.

## How it plays

A song is shown as it starts: its names and its cover first, then its
sound. The sound plays on a process of its own, so nothing the window
does - reading a cover, opening the large one, a requester, the window
being sized - makes it stumble.

One song runs into the next without a gap: the song that follows is
opened a few seconds before this one ends, and its sound joins this
one's, from the first frame of its music - an MP3 as its encoder marked
where the music begins and ends. A song at another rate than the one
before follows once the sound has played out, after a short pause.
Repeat one plays a song into itself the same way. A change to the list,
the order or repeat in the last moment still counts: the song that
would have followed is taken back unheard.

An Ogg file can hold several songs one after another, each with its own
tags - a chain. Each is shown as the song once it is heard: its names,
its cover, its kind and its length, the time counted from its start,
and the slider moves within it. One at another rate follows after a
short pause, as a song of another rate does. Played again from the
start, the file starts with its first song.

On a machine with no sound the window opens all the same and says so,
and a song picked still shows its cover and tags - as it does when all
sixteen of the sound's streams are in use.

## Stations

An address in the playlist is a station: an internet radio that sends
MP3 or Ogg Vorbis over `http://` or `https://`. **Project > Open URL...**
asks for one in a small window: Return or **Open** adds it to the list
and plays it, Esc or **Cancel** closes the window. An address typed
without `http://` gets it put in front.

An address that answers with a list - a `.pls` or `.m3u`, as a
station's site hands out - stands for the first station the list names,
which is called instead; HLS, a list of a stream's pieces, is not
played, and says so.

A station is called when it is played. The window says *Calling the
station*, then *Buffering* and how far, and the sound starts once two
seconds of it have come. Then it shows the station: its name where an
album's goes - and as its row's title in the list - its genre, the title
it sends, taken apart into artist and title when it sends
`Artist - Title`, and its address under them. An Ogg station sends each
song with tags of its own: their title and artist are shown as each song
is heard, with its rate and channels, and the time counts from its
start. The times say `live`, and
the slider stays still: a station has no place to go to. When the sound
comes more slowly than it plays, the window says *buffering* and the
sound waits until two seconds have come again.

A connection lost is called again, up to three times in a row - after a
second, a second and five seconds - and the sound goes on. A station
that cannot be reached, answers with an error or sends AAC says why at
once; one that stops sending says so after the third call. A station on
`https://` needs the clock set to check its certificate, and says so
when it is not (`C:net/TimeSync` sets it).

Stop ends the call, and play calls the station again. A station kept in
the list is shown when the Player starts again, not called: play calls
it.

## Radio

The third page holds stations, one list at a time; the chooser at its
top left turns between them:

- **Your stations**: the stations kept, their names and addresses. A
  fresh disk has six to start with: SomaFM's Groove Salad and Drone Zone,
  Deutschlandfunk, Deutschlandfunk Kultur, FluxFM and Radio Paradise.
- **Found**: what the last search found - each station's name, country,
  bit rate and genres - the most listened to first.

A double-click on a station, or Return, plays it: it goes into the
playlist under its name, or the row there with its address plays.
**Keep** keeps the station selected in Found, while Found is shown -
or else the station playing, one opened with **Open URL...** too - and
says so under the list. **Remove**, or Del, takes the kept station selected out.

**Find** and **Search** look in radio-browser.info, a list of stations
its listeners keep: type a word or two and press Return or **Search**.
The chooser beside the field says what the words are looked for in:
**Name**, **Genre** or **Country** - a country's name, or its two-letter
code (`DE`, `FR`). The search asks for stations that send MP3 or Ogg
Vorbis and were found working, fifty of each, and the page turns to
Found; the line under the list says which of the service's servers it
asks, how many stations came, or why none did. A search runs on a
process of its own, so the sound and the window go on while it waits;
Esc in the field leaves it without searching. A station from Found that
is played is counted by the service, as it asks of a player.

A station with a picture - one the service knows, or a kept one's
`tvg-logo`; the six a fresh disk keeps have theirs - shows it as its
cover once it has come, and a click on the cover shows it large under
the station's name. A station that names a picture beside each song it
sends (its `StreamUrl`), as Radio Paradise does, shows that one while
the song plays, large under the song's title, and its own picture again
for a song that names none. Pictures are JPEG, PNG, GIF, BMP or ICO; a
picture of another kind is not shown, and the note or the station's own
picture stays. A picture on `https://` needs the clock set
(`C:net/TimeSync`).

The kept stations are `ENVARC:Player/Stations.m3u`, an M3U list that
can be edited, or used as a playlist; they are written as the Player
ends when Keep or Remove changed them.

## Menus

- **Project**: Open..., Open drawer... and Open URL..., as above; Save
  playlist... (see *Lists*); About, which says which Player this is
  while the sound and the picture go on; Quit.
- **Playlist**: Add..., Remove and Clear, as the buttons on its page;
  Shuffle, ticked while it is on, and Repeat, with Off, All and One.
  Each follows the button beside the deck, and the button follows it.
- **Picture**: Plasma, Wave, Bars, Scope or Meters, the one shown
  ticked; Whole screen.
- **Settings**: Remember where it was, ticked while it is on;
  Equalizer, the presets, the one in force ticked - as the EQ chooser,
  which follows it. When a preset was picked, the Player keeps what the
  device then has - each output's volume and equalizer - in
  `ENV:Sys/audio.prefs` and `ENVARC:` as it ends, as Volume does, so it
  is the same after the next boot.

## Keys

- Space pauses and goes on; when nothing plays, it starts.
- N plays the song after, P the song before - as the deck's buttons at
  its ends do.
- F shows the picture over the whole screen - but on the Radio page,
  where F goes to the field.
- Cursor left and right jump ten seconds back and on; cursor up and down
  turn the volume up and down by five.
- Return plays the song selected in the playlist, Del takes it out; on
  the Radio page Return plays the station selected, Del lets a kept one
  go.
- S turns shuffle on and off, R goes round repeat's three ways, M turns
  the sound off and on, O takes the next output and Q the equalizer's
  next preset - with Shift, the one before. On the Playlist page,
  A adds, E removes and L clears; on the Radio page, F goes to the
  field, I opens what the words are looked for in, H searches, K keeps
  and V removes.
- Right-Amiga O opens songs, Right-Amiga D a drawer of them, Right-Amiga
  U a station's address, Right-Amiga S saves the playlist, Right-Amiga
  A adds songs.
- Right-Amiga Q ends it.

## Remembered

As it ends, the Player keeps how it was, in `ENV:` and in `ENVARC:`, so
that it lasts past a restart:

- `Player.prefs`, one line: the window's place and size, the page shown,
  the picture, the volume, shuffle and repeat, whether it remembers, and
  the drawer the file requester was last answered in.
- `Player.list`, a line for each song in the list, in its order; the song
  shown carries the second it was at.
- `Player/Stations.m3u`, the kept stations (see *Radio*), when they
  changed.

Started again, it opens where the window was - squeezed onto the screen
when that is smaller now - on the page it showed, with its list and the
song shown waiting where it stopped, paused: Space plays on. A song that
had played to its end waits at its start. The file requester starts in
the drawer last answered in.

Files named as it starts make the list instead, and `VOLUME` and `LOOK`
named win over what was kept. With **Settings > Remember where it was**
off, no list is kept: the next start has an empty one, and the rest is
kept all the same. A song in `Player.list` whose file is gone stays in
the list and says so when it is played, as a file named that is not
there does; a song whose name has a `"` in it is not kept. A
`Player.prefs` that cannot be read leaves the Player as it starts the
first time.

## Ending it

The window's close gadget, **Project > Quit**, or Ctrl-C in the shell it
was started from.
