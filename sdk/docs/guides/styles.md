# Styles

How gadgets, windows and menus get their look: what a style is, where one
comes from, how a property is found, and what a class or a program does to
draw in it. The calls are in the reference: [intuition](../autodocs/intuition.md)
(`DrawPart`, `GetStyleAttr`, `StylePens`, `SetStyle`) and
[graphics](../autodocs/graphics.md) for the fill styles.

- [What a style is](#what-a-style-is)
- [Parts](#parts)
- [States](#states)
- [Properties](#properties)
- [Where a style comes from](#where-a-style-comes-from)
- [How a property is found](#how-a-property-is-found)
- [Giving a screen or a gadget a style](#giving-a-screen-or-a-gadget-a-style)
- [The system's style and style.prefs](#the-systems-style-and-styleprefs)
- [Drawing a part in a class](#drawing-a-part-in-a-class)
- [Hover and focus](#hover-and-focus)
- [Tools](#tools)

## What a style is

A style is a tag list (`sdk/libs/intuition/style.zig`). `STYLE_Part` and
`STYLE_State` are markers: the properties after them belong to that part
in that state, until the next marker.

```zig
const style = sdk.intuition.style;

const blue_buttons = [_]TagItem{
    .{ .tag = style.STYLE_Part, .data = style.PART_MAIN },
    .{ .tag = style.STYLE_Border, .data = style.BORDER_FLAT },
    .{ .tag = style.STYLE_BorderRGB, .data = 0xFF40_4850 },
    .{ .tag = style.STYLE_Radius, .data = 6 },
    .{ .tag = style.STYLE_State, .data = style.STATE_PRESSED },
    .{ .tag = style.STYLE_BackgroundRGB, .data = 0xFF3A_6EA5 },
    .{ .tag = style.STYLE_TextRGB, .data = 0xFFFF_FFFF },
    .{},
};
```

Until the first `STYLE_Part` the part is `PART_MAIN`; until the first
`STYLE_State`, and again after each `STYLE_Part`, the state is
`STATE_NORMAL`. Within one list the first value given for a part, a state
and a property is the one that counts, `TAG_MORE` included, so a list can
put its own lines in front of another's and link to it.

Intuition reads the list once and keeps what it read: the list may go as
soon as the call that took it returns. Drawing never walks a tag list.

A style says only what differs. Everything it leaves out comes from
somewhere else - the next style asked, and in the end the system's
default, which is the look the system has with no style anywhere.

## Parts

A gadget is drawn as parts, each a number:

| Part | What it is |
|------|------------|
| `PART_MAIN` | a gadget's body and border: a button, a field, a list's box |
| `PART_GROUP` | a framed group's border and the title in its edge |
| `PART_INDICATOR` | what shows a value: a bar's level, a tick, a radio's dot |
| `PART_KNOB` | what is dragged: a slider's or a scroller's knob |
| `PART_TRACK` | what a knob or a level runs in |
| `PART_SELECTION` | what is chosen: a list's line, marked text |
| `PART_TITLE` | the active window's title bar and its gadgets |

A class may name parts of its own: `style.classPart(base, n)` is the `n`th
part of the class that falls back to `base`. Its low byte is the base, so
a style that does not name the class's part exactly gives it the base
part's look. Intuition's own (`sdk/libs/intuition/imageclass.zig`):

| Part | Falls back to | What it is |
|------|---------------|------------|
| `PART_FRAME_PLAIN` | MAIN | frameiclass's plain frame, round a field |
| `PART_CHECK`, `PART_RADIO` | MAIN | a check box's box, a radio button's ring |
| `PART_FIELD` | MAIN | the line a string gadget edits |
| `PART_MENU` | MAIN | a menu's panel |
| `PART_FRAME_DROPBOX` | GROUP | an icon's drop box |
| `PART_REQUESTER` | GROUP | a requester's ground |
| `PART_CHECKMARK`, `PART_RADIOMARK` | INDICATOR | the tick, the dot |
| `PART_TITLE_INACTIVE` | TITLE | an inactive window's title bar |
| `PART_WINDOW_BORDER` | TITLE | the frame round a window |
| `PART_SCREEN_BAR` | TITLE | a screen's bar |

## States

| State | When |
|-------|------|
| `STATE_NORMAL` | at rest |
| `STATE_HOVERED` | a mouse's pointer is over it and nothing is held |
| `STATE_PRESSED` | it is held down, or being dragged |
| `STATE_CHECKED` | it is on: a check box, a toggle |
| `STATE_FOCUSED` | it has the input: the keyboard reaches it |
| `STATE_DISABLED` | it cannot be used |

States are bits: `STATE_PRESSED | STATE_FOCUSED` is a state of its own
that a style may name exactly.

## Properties

| Tag | Takes |
|-----|-------|
| `STYLE_Background` / `RGB` / `Fill` | a screen pen, a colour `0xAARRGGBB`, or a `*const graphics.FillStyle` (a gradient or a tile) |
| `STYLE_Border` | `BORDER_NONE`, `FLAT`, `RAISED`, `RECESSED`, `RIDGE`, `GROOVE` |
| `STYLE_BorderPen` / `RGB` | a flat border's colour |
| `STYLE_ShinePen` / `RGB`, `STYLE_ShadowPen` / `RGB` | a bevel's light and dark sides |
| `STYLE_BorderWidth`, `BorderX`, `BorderY` | the border's thickness: both, the sides, the top and bottom |
| `STYLE_Joins` | `JOINS_NONE` or `JOINS_ANGLED`: how a bevel's corners meet |
| `STYLE_Radius` | how far the corners are rounded; a round part is drawn with smooth edges |
| `STYLE_TextPen` / `RGB` | the colour of text on it |
| `STYLE_Padding`, `PaddingX`, `PaddingY` | room between the border and what is inside |
| `STYLE_Opacity` | 255 opaque down to 0: how much lands over what is behind |
| `STYLE_Transition` | milliseconds a change into the state takes: the part fades from its old look to the new one (see the [animation guide](animation.md)) |

A colour given as a pen is the screen's pen, looked up when the part is
drawn, so a style in pens follows the screen's colours. A colour given as
`0xAARRGGBB` is that colour on every screen.

## Where a style comes from

Four styles may be asked, in this order:

1. **the gadget's own** - `GA_Style`, for one gadget;
2. **its screen's** - `SA_Style` when the screen opened, or `SetStyle`
   with the screen;
3. **the system's** - `SetStyle` with no screen, which `C:StylePrefs`
   gives from `ENV:Sys/style.prefs`;
4. **the system's default** - in the ROM, the look with no style anywhere.

## How a property is found

Each property is found on its own:

1. the most particular state first: the exact combination of the states
   the part is in, then each single state in the order disabled, pressed,
   checked, focused, hovered, then normal;
2. for each state, the four styles above in their order;
3. within each style, the exact part, then the part it falls back to.

So a screen style that gives a pressed button a colour and nothing else
leaves the pressed border to the default's pressed border, and a button
under the pointer with no hovered entry anywhere looks as it does at rest.

## Giving a screen or a gadget a style

```zig
// A screen, and every window opened on it.
const screen = ib.OpenScreenTagList(&[_]TagItem{
    .{ .tag = sc.SA_Style, .data = @intFromPtr(&blue_buttons) },
    .{ .tag = sc.SA_LikeWorkbench, .data = 1 },
    .{},
});

// One gadget, over whatever its screen says.
const ok = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
    .{ .tag = gc.GA_Text, .data = @intFromPtr("_OK") },
    .{ .tag = gc.GA_Style, .data = @intFromPtr(&red_ok) },
    .{},
});

// A screen already open, given another; its windows are drawn again.
if (!ib.SetStyle(screen, &darker)) {
    // no memory: the one before stays
}
```

A screen made public with a style of its own and set as the default
public screen gives that look to programs that know nothing of styles:
they open their windows there. `C:test/Styles` does exactly this.

## The system's style and style.prefs

`ENV:Sys/style.prefs` holds a line per part and state, read by
`C:StylePrefs` at boot and whenever it is run again:

```
PART=MAIN BORDER=FLAT BORDERCOLOUR=#404850 BORDERWIDTH=1 RADIUS=6 BACKGROUND=#FAFBFC..#D8DCE2
PART=MAIN STATE=HOVERED BORDERCOLOUR=#3A6EA5
PART=MAIN STATE=PRESSED BACKGROUND=#3A6EA5 TEXT=#FFFFFF
PART=FIELD STATE=FOCUSED BORDERCOLOUR=#3A6EA5 BACKGROUND=#E8F0FF
PART=SELECTION BACKGROUND=FILL TEXT=FILLTEXT
```

- `PART` is a part's name - `MAIN`, `GROUP`, `INDICATOR`, `KNOB`,
  `TRACK`, `SELECTION`, `TITLE`, `FRAME`, `DROPBOX`, `CHECK`, `RADIO`,
  `CHECKMARK`, `RADIOMARK`, `TITLEINACTIVE`, `FIELD`, `WINDOWBORDER`,
  `SCREENBAR`, `MENU`, `REQUESTER` - or a number.
- `STATE` is `NORMAL`, `HOVERED`, `PRESSED`, `CHECKED`, `FOCUSED`,
  `DISABLED`, or several joined by `+`.
- A colour is a screen pen's name (`TEXT`, `SHINE`, `SHADOW`, `FILL`,
  `FILLTEXT`, `BACKGROUND`, `HIGHLIGHTTEXT`, `DETAIL`, `BLOCK`,
  `BARDETAIL`, `BARBLOCK`, `BARTRIM`), `#RRGGBB` or `#AARRGGBB`; a
  `BACKGROUND` of `#top..#bottom` is shaded from top to bottom.
- `BORDER`, `JOINS`, and the numbers `BORDERWIDTH`, `BORDERX`,
  `BORDERY`, `RADIUS`, `PADDING`, `PADDINGX`, `PADDINGY`, `OPACITY`.

The file on the disk has the system's default written out in comments,
which makes it its own reference, and a flatter look to try. The
system's style reaches every screen, those open too, under a screen's own
style. `StylePrefs RESET` leaves the default alone.

Every window on a screen whose style changes has its gadgets laid out
again and drawn, and hears `IDCMP_NEWPREFS` for what it draws itself. A
window keeps the border sizes it opened with.

## Drawing a part in a class

A class asks for its look; it never decides it.

**A part whole** - border, inside, the room left for what goes in it:

```zig
const box = graphics.Rect{ .min_x = b.left, .min_y = b.top,
    .max_x = b.left + b.width, .max_y = b.top + b.height };
var inside: graphics.Rect = undefined;
ib.DrawPart(rp, dri, g.style, style.PART_MAIN, states, 0, &box, &inside);
// draw the label inside `inside`
```

With a null RastPort `DrawPart` only measures: `inside` is what the border
and padding leave, which is how a frame says how much bigger it is than
what it holds. `DPF_EDGES_ONLY` draws the border alone, `DPF_INVERT`
turns it the other way.

**A single property** - a label's colour, a mark's:

```zig
const ink = ib.GetStyleAttr(dri, g.style, style.PART_MAIN,
    style.STATE_PRESSED, style.STYLE_TextPen);
```

A colour comes back as `0xAARRGGBB` whether the style gave a pen or a
colour, ready for `RPTAG_APen`.

**A class that draws with the screen's pens** keeps its drawing and takes
its pens from the style: `StylePens` answers the screen's pens with the
six that stand for a look - background, text, fill, fill text, shine,
shadow - taken from a part. The gadget classes on the disk do this through
`sdk/libs/gadgets/support.zig`:

```zig
// The pens for the body; the fill pens from the selection part, for a
// list's chosen line.
const styled = support.pensFor(ib, dri, gc.gadget(o).style,
    style.PART_MAIN, style.PART_SELECTION);
const pens: [*]const graphics.Pen = &styled;

// The ground alone.
const ground = support.background(ib, dri, gc.gadget(o).style, style.PART_MAIN);
```

Under the system's default every one of these answers what the screen's
own pens are, so a class that draws through them looks exactly as it did
before styles.

**A frame image** (`frameiclass`) draws through `DrawPart`, its part
chosen by its frame type or named with `IA_StylePart`. Its state comes from
the image state (`IDS_`) and, for what an image state cannot say,
`ImpDraw.style_state`. A gadget that draws a frame round itself hands it
its own style in `ImpDraw.style` and `ImpFrameBox.style`, so the frame is
drawn and measured with the gadget's `GA_Style` over the screen's:

```zig
var draw = ic.ImpDraw{
    .method_id = ic.IM_DRAWFRAME, .rast_port = rp,
    .offset = .{ .x = b.left, .y = b.top }, .state = ids, .draw_info = dri,
    .dimensions = .{ .width = b.width, .height = b.height },
    .style = gc.gadget(o).style,
};
_ = ib.SendMessage(frame, @ptrCast(&draw));
```

## Hover and focus

Intuition marks two things on a gadget, and nothing else sets them:

- `GFLG_HOVERED` - a mouse's pointer is over it with nothing held. A
  finger has no hover, so on a touch screen nothing is marked until a
  mouse has been used. The gadget marked is the innermost one a press
  would reach: the button in a layout, not the layout.
- `GFLG_FOCUSED` - it has the input, whatever gave it: a press, Tab, or
  `ActivateGadget`.

`gadgetclass.styleStates(flags)` turns them into `STATE_HOVERED` and
`STATE_FOCUSED`; a class adds them to the states it draws in, and passes
them to its frame in `ImpDraw.style_state`:

```zig
var draw = ic.ImpDraw{
    .method_id = ic.IM_DRAWFRAME,
    .rast_port = rp,
    .state = ids,
    .draw_info = dri,
    .dimensions = .{ .width = b.width, .height = b.height },
    .style_state = gc.styleStates(gc.gadget(o).flags),
};
```

A gadget made of a gadget of its own - a string field inside a frame -
hands the marks on before the inner one draws: `support.passMarks(o,
inner)`.

A hovered gadget is drawn again as the pointer comes and goes only when
a style it is drawn from names the hovered state at all; under the
default nothing is drawn for it. A focused one is drawn by its class as
it goes active and inactive, which it does anyway.

## Tools

| Command | What it does |
|---------|--------------|
| `C:StylePrefs` | sets the system's style from `ENV:Sys/style.prefs`, or `FROM` another file; `RESET` back to the default |
| `C:test/Styles` | a public screen in a style of its own, made the default public screen; `DARK` with dark pens and a style to match |
| `C:test/Gadgets`, `C:test/Layout`, `C:test/ListView` | windows of gadgets to look at in either |
