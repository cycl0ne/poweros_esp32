# Boing

The Amiga's bouncing ball of 1984: red and white, leaping in front of its
purple grid with a shadow behind it, and a thud each time it touches the floor
or a wall, from the side it touches on.

## Starting it

Type `Boing` in a shell. It opens a screen of its own.
**Esc** or a click of the left mouse button ends it, and so does Ctrl-C from the
shell it was started in.

It draws through `facet.library`, on the GPU where the machine has one and on
the cores if not.

## In a shell

`Boing VOLUME/K/N,FRAMES/K/N,CORES/S,TO/K,WINDOW/S,HIRES/S,MORPH/K/N`

- **VOLUME** is how loud the thud is, in percent of as recorded (60); 0 for
  silence.
- **FRAMES** ends it after so many frames and says how many were shown a second.
- **CORES** draws on the cores even where there is a GPU.
- **TO** writes one still picture of 672 x 480 to a file, a PPM, and shows
  nothing.
- **WINDOW** bounces it in a window on the desktop, which can be moved and
  sized. Its close gadget or Esc ends it there.
- **HIRES** makes the ball round where it was faceted, lit from the upper left
  with a shine on it, its shadow soft at the edge and the grid's lines thinner.
  The checks stay the original's.
- **MORPH** turns the ball from the original's into that one every so many
  seconds, and back: `Boing MORPH 10`, say.

## What is not the original's

The picture was measured from a still of the original. The ball's movement and
its thud are made here: the thud is not the Amiga's sample. Whatever is wider or
narrower than the original's picture has plain grey beside it.
