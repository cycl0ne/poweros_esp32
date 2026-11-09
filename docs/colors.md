# Colours

The pictures the system paints in colour - the command pictures of the
tool buttons and ribbons, the docklets, the Clock - use one palette and one
way of building a picture up. This page has the colours, the rules and
examples of each.

- The palette page, with every command picture drawn at every size, on
  each screen ground, and the layers of one picture shown one at a time:
  [claude.ai/artifact/1517CMM6DdzJ6bo9Tiz2Km](https://claude.ai/artifact/1517CMM6DdzJ6bo9Tiz2Km).
- The same page to read without the network:
  [malkasten.html](malkasten.html), in German. Open it in a browser; it
  draws every picture itself and loads nothing.
- In code: [`sdk/libs/gadgets/shapes.zig`](../sdk/libs/gadgets/shapes.zig)
  (`sdk.gadgets.shapes`), where every colour below is a pen,
  `0xAARRGGBB`.

## The palette

Eleven hues, each in three tones. The light tone and the hue itself are
the gradient a shape is filled with, top to bottom; the dark tone is its
rim.

| Hue | Light | Base | Dark | What it paints |
|---|---|---|---|---|
| `blue` | `#A6D0FF` | `#3D8BEB` | `#1D58AC` | a floppy disk, a lens, arrows, lines on paper; the Clock's figures |
| `yellow` | `#FFE69A` | `#F5BF3A` | `#B07F0C` | a folder |
| `green` | `#A8E9A4` | `#3DB85A` | `#1D7A34` | new, paste, a sum, a lamp that is on |
| `red` | `#FFA59A` | `#E5483B` | `#A3271F` | delete, the handles of scissors, an underline; the Clock's second hand |
| `orange` | `#FFCA92` | `#F28C28` | `#AE560C` | wrap, replace |
| `violet` | `#D4BBFF` | `#8B5CF6` | `#5631B0` | sort, a formula, a context tab |
| `teal` | `#96EAE2` | `#1FB0A6` | `#11756F` | settings, the network |
| `brown` | `#E9C397` | `#B9804A` | `#774A22` | a clipboard |
| `metal` | `#F4F6F9` | `#B9C0CA` | `#666E7B` | blades, a clip, a printer, a cog; the Clock's bezel and marks |
| `iron` | `#9AA3B0` | `#5A6371` | `#30353D` | handles, slots, screws; the Clock's hands and its panel |
| `paper` | `#FFFFFF` | `#EEF1F5` | `#8F99A6` | sheets of paper, labels; the Clock's face |

```zig
const shapes = sdk.gadgets.shapes;
const blue = shapes.tones(.blue); // .light, .base, .dark
```

What stands on the ground itself - the letter of Bold, the lines of the
alignment pictures, a line of text - is not in the palette: it is ink, the
screen's text pen, so it reads on every ground.

## How a picture is built

A picture is drawn in its own square, in design units: 0 to 100 across
and down, made into whole pixels for each size it is drawn at. It is
painted again for every size, never scaled.

Each shape of one hue is laid down in layers (`Painter.solid`):

1. **The shadow**: black at 22 % (`0x38000000`), moved a 48th of the
   size to the right and a 24th down, laid once for all the shapes so that
   where two meet it is no darker.
2. **The rim**: the whole shape in the dark tone.
3. **The body**: the shape set in by the rim, light tone at its top to
   the hue at its bottom.
4. **The gloss**: white at 55 % fading out by the middle, over the top
   half.

Then the details on top, each its own shape. The rim is a pixel wide up
to 63 pixels and a 32nd of the size above that.

- **Shaded** (`.shade = true`): the back of something, a folder's - the
  hue going darker downward, and a darker rim.
- **Flat** (`.flat = true`): one colour inside the rim, no gradient and
  no gloss.
- **Small**: under 20 pixels there is no shadow, gloss or shading, only
  the hue and its rim, so nothing blurs.
- **Disabled**: every colour its grey, faded most of the way into the
  ground.

Every edge is smooth: a pixel is covered by the share of sixteen points in
it that lie inside the shape, so shapes meet exactly where their numbers
say. A picture can be laid into a kept picture of its own (`Painter.into`)
and put down in one `BlendPixelArray` as often as it is wanted.

```zig
var p = shapes.Painter.begin(frame, shapes.Look.of(draw_info, false));
defer p.end();
p.solid(&.{p.rr(8, 12, 74, 94, 7)}, .brown, .{}); // the clipboard
p.solid(&.{p.rr(24, 4, 58, 20, 4)}, .metal, .{ .no_shadow = true }); // its clip
p.ink(&.{p.rr(22, 10, 42, 90, 0)}); // a stroke in the text pen
```

## The screen's ground

A picture sits on the screen's background pen. The palette page shows each
picture on three grounds:

| Ground | Background | Text | Fill |
|---|---|---|---|
| grey, the built-in one | `#AAAAAA` | `#000000` | `#6688BB` |
| light | `#E5E8EC` | `#1D2128` | `#3D8BEB` |
| dark | `#2A2E35` | `#E6E8EB` | `#5B9BF0` |

The screen's own pens are set on Prefs' Palette page and kept in
`ENVARC:Sys/palette.prefs` ([styles guide](../sdk/docs/guides/styles.md)).

## Examples

**Command pictures** (`command.image`):

- Save: a blue disk, a metal shutter with a dark blue slot, a paper label
  with two blue lines.
- Open: a shaded yellow folder back, a paper sheet, a yellow front.
- Cut: two metal blades, red handles, an iron screw.
- Paste: a brown clipboard, a metal clip, a paper sheet with blue lines.
- Find: an iron handle, a metal ring, a lens from white to light blue.
- Settings: a flat metal cog round a teal hub.

**The Clock** (`SYS:System/Clock`):

- The dial: a soft shadow under it; a metal bezel, shaded and glossed;
  its edge into the face in metal's dark tone; a paper face from the base
  at its top to white at its bottom, with a faint shadow along its top,
  so it sits back in the bezel; the minutes' marks in metal's dark tone;
  the hours' marks iron with a shadow each, the quarters longest.
- The hands: iron, a rim darker than iron's dark tone round a body from
  iron to its dark tone, each with a shadow at 25 %, the minute hand's
  farther than the hour hand's; the second hand red with a weight at its
  tail, a dark red ring round its pin and the pin in metal's light tone.
- The figures: a panel from iron's dark tone to darker, with an edge
  between iron's dark tone and the hue; lit segments from blue's light tone
  to the hue, with two rings of glow in the hue at 19 % and 9 %; unlit
  segments white at 10 %; the date in metal, AM and PM in blue's light
  tone.

**Docklets** draw on the same shapes in the screen's pens: the clock's
face in the shine pen ringed in the text pen, the CPU's bars in the fill
pen, the battery red once it is low.
