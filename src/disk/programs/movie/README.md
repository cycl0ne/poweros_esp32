# Movie

Movie plays films in a window: MP4 and QuickTime's MOV, their pictures
in H.264, H.265 or Motion JPEG and their sound in AAC. H.264 and H.265
are decoded by the machine's video decoder where it has one - the
VisionFive 2's - and Motion JPEG by the processor, which is enough for
small pictures.

Its menus and requesters are in the language chosen on Prefs' Region
page when there is a catalog for it - German is on the disk, in
`LOCALE:Catalogs/deutsch/programs/Movie.catalog` - and in English
otherwise.

## Starting it

Double-click a `.mp4`, `.m4v` or `.mov` file, or type in a shell:

```
Movie FILE,VOLUME/K/N,FULL/S
```

- `FILE` is the film. Without one - Movie's icon double-clicked - a file
  requester asks for it first.
- `VOLUME` is in percent of as recorded: 100, as it is, unless given.
- `FULL` starts with the film over the whole screen.

A film that cannot be played says why in the shell: one whose pictures
nothing here decodes - H.264 on a machine without a video decoder,
MPEG-4 Part 2 anywhere - and one that is not a film. A film whose sound
nothing decodes plays without it.

## The window

The picture, over a row of controls. The picture keeps its shape in
whatever size the window is given, black where it does not reach; the
window opens with the picture at its own size, or two thirds of the
screen when it is larger. The window's title is the file's name.

- **The tape deck**: back ten seconds, play and pause, on ten seconds,
  stop - back to the start.
- **The slider** is the place in the film. Dragged, the time beside it
  follows; let go, the film goes there.
- **The time**: where the film is, and how long it lasts.
- **The volume**, in percent.

A double-click on the picture shows the film over the whole screen,
without a pointer; F, Esc or a click goes back to the window.

| Key | Does |
|---|---|
| Space | pause, and go on |
| Left, Right | ten seconds back, and on |
| Up, Down | the volume, in steps of five |
| F | the whole screen |

The keys work over the whole screen too.

**Project > Open...** plays another film; **About** says what Movie
is; **Quit**, or the close gadget, ends it.

## How it keeps time

The sound sets the time: the picture shown is the one whose time has
come in what is heard. A picture that is late by more than a frame is
left out - a few in a row at most, so a film too much for the machine
still moves. A film without sound, or whose sound ends before its
pictures, keeps time by the clock.

Moving - the slider, the keys, the deck - goes to the key frame at or
before the time asked for, where a decoder can start: in most films
they are a second or two apart.

## How the picture is shown

Where the screen's display has a video layer - the VisionFive 2's does -
the film is shown on it: the display reads each picture as the decoder
made it, scales it and turns it into colours itself, so the processor
does none of that. The layer lies under the screen and is seen through
the picture's place in the window, which is filled with a colour of its
own, a black with a touch of purple; a window, a menu or a requester in
front of the film hides it as it would hide anything. The film follows
the window when it is moved or sized.

Elsewhere - or for a film the layer cannot take: one scaled more than
three times up or ten times down, Motion JPEG whose rows are not laid
out for it - the processor puts each picture into the window itself.

## Notes

- On the VisionFive 2 a 1080p film takes its video decoder about 7 ms a
  picture. On the layer that is all it costs; put into the window by the
  processor at another size it takes about as long again.
- While a window is being dragged the film stays where it was, and
  follows once the window is let go.
- A film read from the network plays as one from a disk does, as fast as
  it can be read.
