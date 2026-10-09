# Intuition

intuition.library is how a program shows itself: the screens on a
display, the windows on a screen, the gadgets in a window, the menus in a
screen's bar and the requesters that ask a question. It is in the ROM.
Gadgets, images and windows of gadgets are objects, all made and worked
with one set of calls. This guide is how those parts work together. Every
call is in the [reference](../autodocs/intuition.md); how things look is
the [styles guide](styles.md).

The smallest programs are in [Writing programs](programs.md): a window
drawn into ([Hello, world - in a window](programs.md#hello-world---in-a-window))
and a window of buttons ([Buttons in a window](programs.md#buttons-in-a-window)).
This guide builds on them.

## Opening it

```zig
const sdk = @import("sdk");
const intuition = sdk.intuition;
const sc = intuition.screens;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const icc = intuition.icclass;
const mn = intuition.menus;
const classusr = intuition.classusr;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;

const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse return dos.RETURN_FAIL;
defer sys.CloseLibrary(int_lib);
const ib: *IntuitionBase = @ptrCast(int_lib);
```

The calls are methods of `IntuitionBase`; the structures, tags and
constants are in `sdk.intuition`, a file per part in
`sdk/libs/intuition/`. Most calls take a tag list ending in an empty
`.{}`. A tag's data is a `usize`: a pointer goes in by `@intFromPtr`, a
negative number by its bits (`@bitCast(@as(isize, -20))`). The examples
also use `sys`, `dl` (dos.library), `gb` (graphics.library) and `lb`
(layers.library, `sdk.layers.LAYERSNAME`), each opened by its name as
intuition.library is.

## Screens

A screen is a display's picture: as big as the display, in a buffer of
its own, with a title bar, a font, a set of pens and a
[style](styles.md) that everything on it is drawn in. Several can be
open on one display, as many as its memory holds; the display shows the
one in front (`ScreenToFront`, `ScreenToBack`), and that one can be
pulled down by its bar to show the one behind.

A program opens its windows on the default public screen - the
Workbench screen, unless `SetDefaultPubScreen` named another.
`LockPubScreen(null)` finds it, opening it the first time, and keeps it
open until `UnlockPubScreen`. A window opened on it keeps it open by
itself, so the lock is needed while the program reads the screen and
opens its window:

```zig
const screen = ib.LockPubScreen(null) orelse return dos.RETURN_FAIL; // no display
defer ib.UnlockPubScreen(null, screen);
```

A screen is opaque: `GetScreenAttrs` reads it, each tag's data a
`*usize` the value is written to - `SA_Width`, `SA_Height`,
`SA_BarHeight`, `SA_Font` (its bar's and menus' font), and
`SA_WBorTop`, `SA_WBorLeft`, `SA_WBorRight` and `SA_WBorBottom`, the
borders a window on it gets, for sizing a window before it is opened.

### Pens and the DrawInfo

Everything on a screen is drawn in its pens, each named for what it is
for. A pen is a colour, `0xAARRGGBB`, never an index into a palette.
`GetScreenDrawInfo` hands out the screen's own DrawInfo - the pens, the
font and the depth, read only - and `FreeScreenDrawInfo` gives it back:

```zig
const dri = ib.GetScreenDrawInfo(screen);
defer ib.FreeScreenDrawInfo(screen, dri);
const ink = dri.pens[sc.TEXTPEN];
const paper = dri.pens[sc.BACKGROUNDPEN];
```

| Pen | For |
|---|---|
| `TEXTPEN`, `BACKGROUNDPEN` | text, and the ground it is on |
| `SHINEPEN`, `SHADOWPEN` | the light and the dark edge of something raised |
| `FILLPEN`, `FILLTEXTPEN` | an active window's border or a selected gadget, and text over it |
| `HIGHLIGHTTEXTPEN` | text that stands out |
| `BARDETAILPEN`, `BARBLOCKPEN`, `BARTRIMPEN` | the title bar and the menus: text, fill, the line under the bar |
| `DETAILPEN`, `BLOCKPEN` | what a window's own two pens default to |

A program that draws in these pens looks like the screen it is on, and
stays so: when the pens change ([the screens' pens](styles.md#the-screens-pens)),
every window that listens is told `IDCMP_NEWPREFS`, reads them again and
draws.

### A screen of its own

`OpenScreenTagList` opens a screen with a look of its own (`SA_Pens`,
`SA_Style`, `SA_LikeWorkbench`), or one a program draws every pixel of
(`SA_Quiet`); `SA_ErrorCode` says why it could not be opened.
`SA_PubName` makes it public, but private until
`PubScreenStatus(screen, 0)` lets visitors in, and `CloseScreen` answers
false while a visitor - a lock or a window - remains.

## Windows

A window is a layer of its screen with a border intuition draws - a
frame, a title bar and the border gadgets it asked for - and, when it
asks, a message port it is heard through. A program has one of two
kinds: a window opened from tags with `OpenWindowTagList`, which the
program draws in and reads the messages of, or a
[window object](#a-window-object) that opens a window round a layout of
gadgets and hands its messages over as words.

### A window from tags

| Tags | |
|---|---|
| `WA_Left`, `WA_Top`, `WA_Width`, `WA_Height` | where and how big, border included |
| `WA_InnerWidth`, `WA_InnerHeight` | how big inside the border, in place of the size |
| `WA_Position` | `WPOS_CENTERSCREEN` or `WPOS_CENTERMOUSE`, in place of a place |
| `WA_MinWidth`, `WA_MinHeight`, `WA_MaxWidth`, `WA_MaxHeight` | how far it may be sized |
| `WA_PubScreen`, `WA_PubScreenName`, `WA_CustomScreen` | the screen; the default public one without any |
| `WA_Title`, `WA_ScreenTitle` | its title, not copied, and the screen bar's while it is active |
| `WA_CloseGadget`, `WA_DragBar`, `WA_DepthGadget`, `WA_SizeGadget` | its border gadgets |
| `WA_Activate` | made the active window as it opens |
| `WA_SimpleRefresh`, `WA_GimmeZeroZero`, `WA_Borderless`, `WA_Backdrop` | what kind of window |
| `WA_IDCMP` | the messages it sends; without it, no port |
| `WA_UserPort` | a port of the program's own its messages go to, shared with its other windows |
| `WA_Gadgets` | gadgets, linked with `GA_Previous`, added and drawn as it opens |

A window is opaque too, read with `GetWindowAttrs` and the same tags, and
a few that are read only: `WA_RastPort`, `WA_Layer`, `WA_UserPort`,
`WA_Screen`, `WA_Active`, and the border's widths `WA_BorderLeft`,
`WA_BorderTop`, `WA_BorderRight` and `WA_BorderBottom`.
`SetWindowTitles` changes the title (`wn.TITLE_UNCHANGED` leaves one as
it is); `ChangeWindowBox`, `MoveWindow`, `SizeWindow`, `WindowLimits`,
`ZipWindow`, `WindowToFront` and `ActivateWindow` move, size and order
it; `SetWindowPointerA` with `WA_BusyPointer` shows the busy pointer
while the program works at length, and `WA_PointerDelay` keeps it from
showing for work that ends at once. When the active window closes, the
window on its screen that was active before it is active again - a
program's window when its requester goes, the desktop when a program it
started ends.

A window is kept wholly on its screen as it is moved and sized, by the
calls and by its title bar and sizing gadget alike; `SizeWindow` grows it
no further than the screen's edges and never moves it. With
`IPREFS_OffScreen` set - `OFFSCREEN=YES` in `intuition.prefs`, "Windows
past edges" in `SYS:Programs/Prefs` - a window may hang past the left,
right and bottom edges, as long as enough of it stays to take hold of
again: its top edge never above the screen's, 64 pixels of its width
across, and its title bar above the bottom. A window always opens wholly
on its screen, and `WA_Left` reads back signed, negative past the left
edge.

### Drawing in a window

The RastPort's (0, 0) is the window's top-left corner, border included,
so the part to draw in starts at the border's left and top widths; with
`WA_GimmeZeroZero` the inside is a layer of its own and (0, 0) is its
corner. **A program draws with the window's layer held** - `LockLayer`
on `WA_Layer` - because intuition draws the border and the gadgets from
its own task. Text, lines and images from a description (`PrintIText`,
`DrawBorder`, `DrawImage`) are in
[Text from a description](fonts.md#text-from-a-description).

A smart-refresh window, the default, keeps what is covered and puts it
back by itself. A simple-refresh one keeps nothing and sends
`IDCMP_REFRESHWINDOW`; the program draws between `BeginRefresh` and
`EndRefresh`, which let through only the part that needs it, so it may
draw everything; when nothing is left to draw - the part was covered
again before the program got to it - nothing it draws lands. The
window's layer is held from one to the other, so
no window moves over it meanwhile: in between, only draw - no intuition
call. `IDCMP_NEWSIZE` says the size changed:

```zig
const graphics = sdk.graphics;

/// One of a window's numbers.
fn windowAttr(ib: *IntuitionBase, window: *intuition.Window, attr: sdk.utility.Tag) usize {
    var value: usize = 0;
    ib.GetWindowAttrs(window, &[_]TagItem{ .{ .tag = attr, .data = @intFromPtr(&value) }, .{} });
    return value;
}

/// Everything inside the border, with the layer held.
fn draw(window: *intuition.Window) void {
    const rp: *graphics.RastPort = @ptrFromInt(windowAttr(ib, window, wn.WA_RastPort));
    const layer: *sdk.layers.Layer = @ptrFromInt(windowAttr(ib, window, wn.WA_Layer));
    lb.LockLayer(layer);
    defer lb.UnlockLayer(layer);
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = ink }, .{} });
    // ... from WA_BorderLeft and WA_BorderTop to WA_Width and WA_Height
    //     less WA_BorderRight and WA_BorderBottom ...
}
```

In the loop of [Hello, world - in a window](programs.md#hello-world---in-a-window),
for a window opened with `WA_SimpleRefresh` and those two classes in
`WA_IDCMP`:

```zig
switch (class) {
    wn.IDCMP_NEWSIZE => draw(window),
    wn.IDCMP_REFRESHWINDOW => {
        ib.BeginRefresh(window);
        draw(window);
        ib.EndRefresh(window, true);
    },
    else => {},
}
```

### Messages

Each thing a window was asked to tell (`WA_IDCMP`, changed later with
`ModifyIDCMP`) comes as an `IntuiMessage`: `class`, one `IDCMP_` bit;
`code` and `iaddress`, which the class gives a meaning; `qualifier`, the
keys and buttons held; `mouse_x` and `mouse_y` in the window's
coordinates; and the time, `seconds` and `micros`. `WaitIMsg` waits for
the window, and for other signals as well; `GetIMsg` takes the next
message and never waits; `ReplyIMsg` hands it back. One wake can mean
several messages, so a program takes them until `GetIMsg` answers null.

**Copy what is needed and reply at once.** The message is intuition's
again after the reply, one not replied holds back the moves and key
repeats behind it, and every one is replied before the window closes.

**One port for many windows.** A program with several windows can give
each the same port of its own (`WA_UserPort`) and wait on that one
signal: each message's `window` says whose it is. The port stays the
program's - `CloseWindow` and `ModifyIDCMP(window, 0)` take only that
window's messages off it - and is deleted after the last window on it
has closed.

| Class | When | `code`, `iaddress` |
|---|---|---|
| `IDCMP_CLOSEWINDOW` | the close gadget let go over; the window stays open until the program closes it | |
| `IDCMP_NEWSIZE`, `IDCMP_CHANGEWINDOW` | sized; moved or sized | |
| `IDCMP_REFRESHWINDOW` | a simple-refresh window has a part to draw again | |
| `IDCMP_GADGETUP` | a `GA_RelVerify` gadget finished | its termination value; the gadget |
| `IDCMP_GADGETDOWN` | a `GA_Immediate` gadget pressed | the gadget |
| `IDCMP_MENUPICK` | the menus used | the first item's menu number |
| `IDCMP_VANILLAKEY` | a key that makes one character | the character, Latin-1 |
| `IDCMP_RAWKEY` | a key down or up | the raw key |
| `IDCMP_ACTIVEWINDOW`, `IDCMP_INACTIVEWINDOW` | it became, or stopped being, the active window | |
| `IDCMP_IDCMPUPDATE` | a gadget told the window what changed | see [Telling the window](#telling-the-window) |
| `IDCMP_MOUSEWHEEL` | the wheel turned over the window and no gadget took it | the notches, read with `wn.wheelDown` and `wn.wheelAcross` |

`IDCMP_MOUSEBUTTONS`, `IDCMP_NEWPREFS` and `IDCMP_INTUITICKS` (ten a
second while active) are the others. A gadget in `iaddress` is the
program's and outlives the message, so its ID may be read after the
reply: `GetAttr(gc.GA_ID, gadget, &id)`.

### Dragging a picture

`BeginDrag(window, picture, hot_x, hot_y)` takes a picture along with
the pointer - an icon picked up, a few drawn together - over every
window until `EndDrag`. The display lays it over its picture on the way
to the glass, as it lays the pointer: windows go on drawing under it and
nothing waits. Its coverage shows as a pattern of dots, so a soft edge
keeps its look; a picture is at most `RTG_OVERLAY_MAX` (160) pixels each
way, and it shows on a touch panel too, where the pointer does not.

```zig
// The button went down on an icon: take hold of it where it was pressed.
const picture = rtg.Surface{ .pixels = pixels, .width = 48, .height = 48, .pitch = 48 * 4, .format = .rgba32 };
dragging = ib.BeginDrag(window, &picture, press_x, press_y);
// ... SELECTUP: let go.
const target = ib.EndDrag(window, if (taken) 0 else intuition.DRAGF_FLYBACK);
```

`EndDrag` answers the window under the pointer - the program's own,
another program's, or null over the screen's ground - and with
`DRAGF_FLYBACK` first flies the picture back to where it was taken
from. One drag at a time; a window closed while it drags ends it.
`C:test/Drag` drags the five default icons.

## A window object

A window object (`classusr.WINDOWCLASS`, as in
[Buttons in a window](programs.md#buttons-in-a-window)) holds what a
window is to be - its `WA_` tags and a layout of gadgets,
`WINDOWA_Layout` - and opens it on `WM_OPEN`: as big as the layout looks
right at unless a `WA_` size says otherwise, in the middle of its screen
unless told where, and never smaller than the layout fits in. `WM_OPEN`
answers the window, or 0. `WM_CLOSE` closes it and keeps the object to
open again; `DisposeObject` closes it and disposes of the layout and
every gadget in it. The window is an ordinary one: `WM_OPEN`'s answer,
or `GetAttr(wc.WINDOWA_Window, ...)` later, is what the window calls
take - menus, titles, `ActivateGadget`, gadgets in the border. `WA_Title`
set on the object changes the title and keeps it for the next open.

The window always hears `IDCMP_CLOSEWINDOW`, `IDCMP_GADGETUP`,
`IDCMP_GADGETDOWN`, `IDCMP_MENUPICK` and `IDCMP_VANILLAKEY`; `WA_IDCMP`
adds to them. `WM_HANDLEINPUT` takes the next message, replies to it and
answers what it was as one word: the kind in the upper half
(`WMHI_CLASSMASK`), a number in the lower, or `WMHI_LASTMSG` when there
is nothing more. The message's whole `code` goes where `WmHandleInput`'s
`code` points.

| Word | What | Lower half |
|---|---|---|
| `WMHI_CLOSEWINDOW` | the close gadget | |
| `WMHI_GADGETUP` | a gadget finished; `code` is what it finished with - a box's state, a choice, a level, the key that ended a line | its `GA_ID` (`WMHI_GADGETMASK`) |
| `WMHI_GADGETDOWN` | a `GA_Immediate` gadget pressed | its `GA_ID` |
| `WMHI_MENUPICK` | the menus used | the first item's menu number (`WMHI_MENUMASK`) |
| `WMHI_VANILLAKEY` | a character no gadget took | the character (`WMHI_KEYMASK`) |
| `WMHI_RAWKEY` | a raw key, with `IDCMP_RAWKEY` | the key |
| `WMHI_NEWSIZE` | sized, with `IDCMP_NEWSIZE` | |
| `WMHI_ACTIVE`, `WMHI_INACTIVE` | active or not, with `IDCMP_ACTIVEWINDOW`, `IDCMP_INACTIVEWINDOW` | |
| `WMHI_IDCMPUPDATE` | a gadget told the window, with `IDCMP_IDCMPUPDATE` | its `ICSPECIAL_CODE` |
| `WMHI_MOUSEWHEEL` | the wheel, with `IDCMP_MOUSEWHEEL`, where no gadget took it | the notches down, as an `i16`'s bits; `code` has both directions |

`WMHI_NEWPREFS`, `WMHI_DISKINSERTED` and `WMHI_DISKREMOVED` follow
their classes too.

Several windows: `WINDOWA_SigMask` is the signal a window object's
messages arrive on, 0 while it is closed. A program with several
windows, or a window and a timer, waits on all of them with `Wait` and
asks each window that woke it until it answers `WMHI_LASTMSG` - as
`SYS:Programs/Notepad` does with its find window:

```zig
var main_mask: usize = 0;
var tools_mask: usize = 0;
_ = ib.GetAttr(wc.WINDOWA_SigMask, main_object, &main_mask);
_ = ib.GetAttr(wc.WINDOWA_SigMask, tools_object, &tools_mask); // asked again after it reopens
const got = sys.Wait(@as(u32, @truncate(main_mask | tools_mask)) | exec.SIGBREAKF_CTRL_C);
if (got & main_mask != 0) mainWindow();
if (got & tools_mask != 0) toolsWindow();
```

## Objects

Gadgets, images, window objects and the connections between them are
objects of classes. A class is found by its name, or used by its pointer
when it is a private one; intuition's own are in the ROM, named in
`classusr.zig` ([intuition's classes](../README.md#intuitions-classes)),
and the gadget classes on the disk are libraries a program opens first
([Gadget classes](../README.md#gadget-classes)).

- Attributes are tags: given to `NewObjectTagList`, changed with
  `SetAttrsTagList`, read one at a time with `GetAttr`. The headers of
  the classes on the disk say of each whether it is made, set or read.
- Methods are messages: `SendMessage(object, &msg)`, a structure that
  starts with its method ID - `WM_OPEN`, `OM_ADDMEMBER`, a class's own.
  A method that has a gadget draw goes through `DoGadgetMethodA`, which
  fills in the gadget's window first (`TEM_FIND` on a textedit.gadget).
- The object is the program's until `DisposeObject`, which takes
  null as well. A layout disposes of its children, a window object of
  its layout and a model of its members: what one of those holds is not
  disposed of again.

`GetAttr` writes a `usize` and answers 0 when no class of the object
knows the attribute. A pointer comes back by `@ptrFromInt`, a signed
number by its bits: `@as(i32, @truncate(@as(isize, @bitCast(stored))))`
for a slider's `SLIDER_Level`.

**A gadget in a window is changed with `SetGadgetAttrsTagList`**, which
hands the class the window so that it can show the change;
`SetAttrsTagList` changes it without it showing. A class draws what
changed itself and answers 0; one that answers nonzero left the drawing
to the caller, who draws it with `RefreshGList`. `OffGadget` and
`OnGadget` disable a gadget and let it be pressed again.

## Connecting objects

An object can tell another what changed in it, without the program in
between. A gadget's `ICA_TARGET` is the object it tells, and `ICA_MAP`
translates the tags on the way: pairs, each turning the tag in `tag` into
the one in `data`, ending in `.{}`. The map is not copied, so it lives
as long as the connection. Every update carries the sender's `GA_ID`,
which a target that is a gadget would take as its own: the map drops it
by turning it into `TAG_IGNORE`. A slider that shows its level on a
gauge as well, while it is dragged:

```zig
const sl = sdk.gadgets.slider;
const fg = sdk.gadgets.fuelgauge;

const level_to_gauge = [_]TagItem{
    .{ .tag = sl.SLIDER_Level, .data = fg.GAUGE_Level },
    .{ .tag = gc.GA_ID, .data = sdk.utility.TAG_IGNORE },
    .{},
};

const gauge = ib.NewObjectTagList(null, fg.GAUGE_CLASS, &[_]TagItem{
    .{ .tag = fg.GAUGE_Max, .data = 64 },
    .{ .tag = fg.GAUGE_Format, .data = @intFromPtr("%ld") },
    .{},
});
const volume = ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
    .{ .tag = gc.GA_ID, .data = ID_VOLUME },
    .{ .tag = sl.SLIDER_Max, .data = 64 },
    .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(gauge) },
    .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&level_to_gauge) },
    .{},
});
```

A connection that is already passing something on passes nothing more,
so two objects that are each other's target stop after one round.

An `icclass` object (`classusr.ICCLASS`) is a connection on its own: it
passes what it is told to its `ICA_TARGET` through its `ICA_MAP`. A
`modelclass` object is a connection with members (`OM_ADDMEMBER`, an
`OpMember` sent with `SendMessage`): what it is told goes to every member
and then to its own target, which keeps one value that several things
show in step. `SYS:Programs/MultiView` joins its scroll bars to a
picture so: each bar's target is a model, whose icclass member carries
the top of the view on to the picture.

### Telling the window

The target `ICTARGET_IDCMP` is the gadget's window: the update arrives as
`IDCMP_IDCMPUPDATE`, which the window asks for in `WA_IDCMP` like any
other class. Its `iaddress` is the changed attributes as a tag list,
mapped, which belongs to the message and goes with the reply, so it is
read before; a tag the map turns into `ICSPECIAL_CODE` has its value in
`code` as well. A window object hands it over as `WMHI_IDCMPUPDATE` with
that code, the list already gone, and the program reads what it wants
from the gadget with `GetAttr`. This is how a program hears from a
gadget as it changes - a getfile gadget's chosen file
([More than buttons](programs.md#more-than-buttons)), a canvas pressed,
a textedit.gadget's view moving.

## Gadgets and layouts

intuition's own gadgets are buttons (`BUTTONGCLASS`, `FRBUTTONCLASS`), a
line of text (`STRGCLASS`), a proportional knob (`PROPGCLASS`), groups
and layouts. The rest are classes on the disk, in `SYS:classes/gadgets/`,
each a library of its own: opened before anything is made of it, and
closed after its objects are disposed of. Each has a header in
`sdk/libs/gadgets/` with its library's name, its class's name and its
tags; [More than buttons](programs.md#more-than-buttons) lists them.
`GA_ID` is the number a program tells its gadgets apart by, and
`GA_RelVerify` has a gadget report when it finishes - some classes set
it for themselves, and giving it again does no harm.

### A layout

A layout (`classusr.LAYOUTGCLASS`) sizes and places the gadgets in it,
from its own box and what each one says it needs; nothing in it is given
a place. It is a gadget itself, so layouts nest: rows in a column,
framed groups in a window. Along its row or column each child gets its
smallest size first, then grows towards the size it looks right at as
far as there is room, and what is left is shared by weight, no child past
its largest size. Across, a child with a weight fills the layout; one
with weight 0 keeps its own size.

| Tag | |
|---|---|
| `LAYOUTA_Orientation` | `LORIENT_VERT` (a column, the default), `LORIENT_HORIZ` (a row), `LORIENT_GRID` |
| `LAYOUTA_Spacing`, `LAYOUTA_Margin` | pixels between children (4) and round them (0) |
| `LAYOUTA_AddChild` | a gadget, the layout's from then on; the `CHILDA_` tags after it are about it |
| `CHILDA_Label` | text on its left; the labels of a column line up |
| `CHILDA_WeightWidth`, `CHILDA_WeightHeight` | its share of the spare room in a row, in a column (100) |
| `CHILDA_MinWidth` ... `CHILDA_MaxHeight` | its smallest and largest size - a button big enough for a finger; the largest is also the most it asks for, so an editor that wants a page can be kept to a few lines |
| `CHILDA_Align` | `CALIGN_` across and down, for a child smaller than its room |
| `LAYOUTA_Frame`, `LAYOUTA_FrameTitle` | a frame round it, with a title in its top edge |
| `LAYOUTA_Columns`, `CHILDA_Column`, `CHILDA_Row`, `CHILDA_ColumnSpan` | a grid's columns and cells |
| `LAYOUTA_Wrap` | a row too narrow for its children goes on in rows beneath |

What a child reports reaches the window in its own name: a button in a
layout in a layout is `WMHI_GADGETUP` with that button's `GA_ID`. A
window object sets its layout to fill the window. In a window from
tags, a layout fills it when it is given `GA_Left` and `GA_Top` at the
border and `GA_RelWidth` and `GA_RelHeight` less the borders.

### A window of settings

The program of [Buttons in a window](programs.md#buttons-in-a-window)
with a column of settings: a string.gadget `name` with `GA_TabCycle`, a
checkbox.gadget `backups`, the slider and gauge above, and an OK button,
each added with a `CHILDA_Label` - `"_Name"`, `"_Backups"`, `"_Volume"` -
whose underlined letter works it from the keyboard. Each class is opened
first and each gadget checked before it goes into the layout: what a
layout took is the layout's to dispose of, what none took the program's
(`C:test/Gadgets` does the same). The window object has
`.{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_ACTIVEWINDOW }` among its tags,
so the field can be given the keyboard once the window is active, and
its words are read with a `code`:

```zig
var code: u32 = 0;
var handle = wc.WmHandleInput{ .code = &code };
while (true) {
    const word = ib.SendMessage(object, @ptrCast(&handle));
    if (word == wc.WMHI_LASTMSG) break;
    switch (word & wc.WMHI_CLASSMASK) {
        wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
        // Active now: the field takes the keys.
        wc.WMHI_ACTIVE => _ = ib.ActivateGadget(name, window, null),
        wc.WMHI_GADGETUP => if (word & wc.WMHI_GADGETMASK == ID_OK) {
            var text: usize = 0;
            var ticked: usize = 0;
            _ = ib.GetAttr(gc.STRINGA_TextVal, name, &text);
            _ = ib.GetAttr(sdk.gadgets.checkbox.CHECKBOX_Checked, backups, &ticked);
            const typed: [*:0]const u8 = if (text != 0) @ptrFromInt(text) else "";
            _ = dos.stdio.Printf(dl, "%s, backups %s\n", .{ typed, @as([*:0]const u8, if (ticked != 0) "on" else "off") });
            return dos.RETURN_OK;
        },
        else => {},
    }
}
```

### The keyboard

An `_` in a gadget's `GA_Text`, or in the `CHILDA_Label` a layout gives
it, marks the next character as its key (`GA_Key`): the `_` is not drawn
and the character is underlined. A window object offers every character
typed to its layout first. The gadget whose key it is is worked as a
press would work it and reports `WMHI_GADGETUP` in its own name; a line
of text is given the keyboard instead; only a character no gadget
answers to reaches the program, as `WMHI_VANILLAKEY`.

Tab and Shift-Tab move the keyboard between the fields that have
`GA_TabCycle`, in the layout's order - row by row in a grid - and a field
reports `WMHI_GADGETUP` when it is left with Return or Tab.
`ActivateGadget` gives a gadget the keyboard without a press, and only in
the active window; a window is not always active the moment it opens, so
a program waits for `WMHI_ACTIVE` as above. A gadget that hands the
program a key it does not take - a textedit.gadget passing on a menu's
shortcut or Control-C - lets the keyboard go, and the program gives it
back with `ActivateGadget` once it has done what the key asked.

On a board with no keyboard, a field with the keyboard - a string
gadget, or one of a class that sets `GFLG_TYPING` as it makes it - brings
one up on the screen, across its bottom and at most half its height, and
takes it away when the field lets go:
[A keyboard on the screen](programs.md#a-keyboard-on-the-screen).

### Gadgets in the border

A gadget can live in a window's border: a scroll bar down the right
edge, one along the bottom. `GA_RightBorder` or `GA_BottomBorder` puts it
there, drawn with the border each time the border is; it is placed from
the edge it sits at (`GA_RelRight`, `GA_RelBottom`) and sized against
the window (`GA_RelWidth`, `GA_RelHeight`), so it stays there as the
window is sized. `WA_SizeBRight` and `WA_SizeBBottom` together give the
sizing gadget room in both borders, which makes each deep enough for a
bar that stops short of the corner. How deep the borders came out is
known once the window is open, so the bars are made then, added with
`AddGList` and drawn with `RefreshWindowFrame`.

A bar joined to a textedit.gadget made with `TEXTEDIT_Scrollers` false
moves the text as it is dragged. The other way round, the text tells the
window (`ICTARGET_IDCMP`) when its view moves, and on `WMHI_IDCMPUPDATE`
and `WMHI_NEWSIZE` the program sets the bar's `SCROLLER_Total`,
`SCROLLER_Visible` and `SCROLLER_Top` from `TEXTEDIT_TotalVert`,
`TEXTEDIT_VisibleVert` and `TEXTEDIT_TopVert` with
`SetGadgetAttrsTagList`:

```zig
const sr = sdk.gadgets.scroller;
const te = sdk.gadgets.textedit;
const pg = intuition.propgclass;

const vert_map = [_]TagItem{
    .{ .tag = sr.SCROLLER_Top, .data = te.TEXTEDIT_TopVert },
    .{ .tag = gc.GA_ID, .data = sdk.utility.TAG_IGNORE },
    .{},
};

// After WM_OPEN.
const top: isize = @intCast(windowAttr(ib, window, wn.WA_BorderTop));
const right: isize = @intCast(windowAttr(ib, window, wn.WA_BorderRight));
const bottom: isize = @intCast(windowAttr(ib, window, wn.WA_BorderBottom));
const bar = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &[_]TagItem{
    .{ .tag = gc.GA_RightBorder, .data = 1 },
    .{ .tag = gc.GA_RelRight, .data = @bitCast(-(right - 1)) },
    .{ .tag = gc.GA_Top, .data = @bitCast(top) },
    .{ .tag = gc.GA_Width, .data = @bitCast(right) },
    .{ .tag = gc.GA_RelHeight, .data = @bitCast(-(top + bottom)) },
    .{ .tag = pg.PGA_Freedom, .data = pg.FREEVERT },
    .{ .tag = sr.SCROLLER_Arrows, .data = @bitCast(bottom) },
    .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(editor) },
    .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&vert_map) },
    .{},
}) orelse return dos.RETURN_FAIL;
_ = ib.AddGList(window, bar, -1, 1);
ib.RefreshWindowFrame(window);
```

The bar is the program's, not the window object's: the window is closed
first (`WM_CLOSE`), which takes the bar out of it, and the bar disposed
of after. `SYS:Programs/Notepad` has both bars this way, and
`SYS:Programs/MultiView` has them round a picture
([Showing one](datatypes.md#showing-one)).

scrollgroup.gadget and listbrowser.gadget take bars in the border the
same way: made with `SCROLLGROUP_Scrollers` or `LISTBROWSER_Scrollers`
false, they tell where their view is - `SCROLLGROUP_Top`,
`SCROLLGROUP_TotalHeight` and `SCROLLGROUP_VisibleHeight` (and the same
across), `LISTBROWSER_Top`, `LISTBROWSER_Total` and
`LISTBROWSER_Visible` - and a bar's `ICA_MAP` turns `SCROLLER_Top` into
their top. `C:test/Scroll` and `C:test/ListBrowser` are built so.

### The wheel

A mouse's wheel goes to the window the pointer is over, active or not,
and in it to the gadget under the pointer, whether another gadget has
the keyboard or not. intuition sends that gadget `GM_WHEEL`
(`gc.GpWheel`): the notches `down` (up negative) and `across` (left
negative), with the pointer in the gadget's own coordinates. A wheel of
one direction turned with Shift held comes as `across`. A group, and so
every layout, hands it on to the member under the pointer. A gadget that
moves something answers non-zero; one that answers 0 - or a point with
no gadget under it - leaves it to the window, which tells its program
`IDCMP_MOUSEWHEEL` (a window object: `WMHI_MOUSEWHEEL`) if it asked.
A window behind a requester takes no wheel.

A notch that changes a gadget's value is reported as a press let go is:
the gadget answers `GMWR_VERIFY` with its code, and a gadget made with
`GA_RelVerify` reaches its program as `IDCMP_GADGETUP` (`WMHI_GADGETUP`)
in its own name, through any groups round it - a slider's level, an
integer field's number. A notch that only moves a view (`GMWR_TAKEN`) is
told to the target and no more.

What a notch does in the classes that take it:

| Class | A notch |
|---|---|
| `textedit.gadget` | three rows down the text, an eighth of the field across it when rows do not wrap |
| `propgclass`, `scroller.gadget` | the knob an eighth of the view along the bar, the target told as at the end of a drag - so a bar in a window's border scrolls what it is joined to |
| `scrollgroup.gadget` | three lines of its contents, where the contents under the pointer take none |
| `listbrowser.gadget` | three rows |
| `listview.gadget` | three lines |
| a data type object | an eighth of what shows, its target told the new tops - so MultiView's bars follow |
| `integer.gadget` | its `INTEGER_Step`, up for more |
| `slider.gadget`, `gradientslider.gadget` | about a thirty-second of the range (gradientslider: its skip), the knob going the way the wheel turns |
| `arc.gadget` with a knob | about a thirty-second of the range, up for more |
| `roller.gadget` | one choice, down for the next |

A class of its own takes the wheel by answering `GM_WHEEL`;
`gc.wheelNotches(msg, vertical)` gives a gadget that moves one way the
notches for that way, or the other way's when its own are 0. It moves
what it shows, draws it, and tells its target as it would after a key
or a drag; when its value changed it answers `gc.wheelVerify(msg,
code)`. It never becomes active for it.

## How a gadget is drawn again

A program changes what a gadget shows; when the drawing happens depends
on how it asked.

- `SetGadgetAttrsTagList` hands the class the window. intuition's own
  buttons draw the change there and then. The classes on the disk ask
  intuition, which draws them soon on its own task: aside into a picture
  first and then onto the window in one copy, so a gadget is never seen
  half drawn, and several changes that come before it gets there are
  drawn once, in the newest state. The new value is the gadget's at once
  - `GetAttr` reads it - and the display follows a moment later.
- `SetAttrsTagList` stores the value and draws nothing;
  `QueueGadgetRefresh` then has intuition draw the gadget as above.
  It never waits, so it is the call for a task that must not wait for a
  window - an animation's step ([Moving a gadget](motion.md#moving-a-gadget)),
  a worker of the program's own - and for a picture the program changed
  itself: `C:test/Widgets` draws a dot into a canvas.gadget's RastPort
  and queues the canvas.
- `RefreshGList` draws gadgets now, in place, on the caller's task:
  after `AddGList`, or for a class that left its drawing to the caller.

`SetGadgetAttrsTagList` and `RefreshGList` are not called with the
window's layer held: drawing a gadget takes it.

### Only part of it showing

A gadget may lie partly outside what shows of it: in a
`scrollgroup.gadget`, a form larger than the window is seen through a
view, and a field half past the view's edge is half drawn. That is a
gadget's clip, `GA_ClipRect`: a rectangle in the coordinates of its box,
everything until something narrows it. A group hands its clip on to its
members, intuition puts it in the GadgetInfo it makes for the gadget
(`GadgetInfo.clip`), and the RastPort `ObtainGIRPort` gives out draws
inside it and nowhere else - so a class draws as it always does, through
whichever RastPort it is handed, and a part that does not show is simply
not drawn. A class that holds gadgets of its own and shows only part of
them sets their clip, and narrows the clip in the GadgetInfo of whatever
it hands on to them while they handle it.

## Menus

A window's menus are a strip of titles in its screen's bar, each with a
panel of items, and an item with a panel of subitems. A program writes
them as a table of `NewMenu`s; `CreateMenusA` makes the strip,
`LayoutMenusA` places it for a screen and `SetMenuStrip` gives it to a
window. `ClearMenuStrip` takes it off before the strip is changed or
freed and before the window closes, and `FreeMenus` frees it.

```zig
const menu_table = [_]mn.NewMenu{
    .{ .type = mn.NM_TITLE, .label = "Project" },
    .{ .type = mn.NM_ITEM, .label = "Open...", .comm_key = "O" },
    .{ .type = mn.NM_ITEM, .label = "Export" },
    .{ .type = mn.NM_SUB, .label = "Text" },
    .{ .type = mn.NM_ITEM, .label = mn.NM_BARLABEL },
    .{ .type = mn.NM_ITEM, .label = "Quit", .comm_key = "Q" },
    .{ .type = mn.NM_TITLE, .label = "View" },
    .{ .type = mn.NM_ITEM, .label = "Grid", .flags = mn.CHECKIT | mn.MENUTOGGLE | mn.CHECKED },
    .{ .type = mn.NM_ITEM, .label = "Small", .flags = mn.CHECKIT, .mutual_exclude = 0b100 },
    .{ .type = mn.NM_ITEM, .label = "Large", .flags = mn.CHECKIT | mn.CHECKED, .mutual_exclude = 0b010 },
    .{ .type = mn.NM_END },
};

const strip = ib.CreateMenusA(&menu_table, null) orelse return dos.RETURN_FAIL;
defer ib.FreeMenus(strip);
_ = ib.LayoutMenusA(strip, screen, null);
_ = ib.SetMenuStrip(window, strip);
defer ib.ClearMenuStrip(window);
```

`comm_key` is an item's shortcut: the right-Amiga key with that
character picks it without the menus being shown, and the panel shows it
at the item's right (`NM_COMMANDSTRING` shows `comm_key` as words
there instead). `CHECKIT` makes an item that is checked or not, `CHECKED`
checks it to begin with, `MENUTOGGLE` lets a second pick uncheck it, and
`mutual_exclude` names the items of the same panel a pick unchecks, a
bit for each by its place, bit 0 the first. `NM_BARLABEL` is a
separator, which counts as an item. `NM_MENUDISABLED` and
`NM_ITEMDISABLED` disable a title or an item; `OffMenu` and `OnMenu`
change it later by menu number - `mn.FULLMENUNUM(1, mn.NOITEM, mn.NOSUB)`
is all of View. `user_data` is kept with an item
(`mn.GTMENUITEM_USERDATA`).

A pick arrives as `IDCMP_MENUPICK`, or `WMHI_MENUPICK` from a window
object, with a menu number: which menu, which item and which
subitem, taken apart with `MENUNUM`, `ITEMNUM` and `SUBNUM` and put
together with `FULLMENUNUM`; `MENUNULL` is no pick at all. The select
button pressed while the menu button is held picks several items in one
go, so each item picked names the next in its `next_select`.
`ItemAddress` finds an item from its number, and a checked item's
`CHECKED` says how it stands now:

```zig
wc.WMHI_MENUPICK => {
    var number: u32 = @truncate(word & wc.WMHI_MENUMASK);
    while (number != mn.MENUNULL) {
        const item = ib.ItemAddress(strip, number) orelse break;
        switch (mn.MENUNUM(number)) {
            0 => switch (mn.ITEMNUM(number)) {
                0 => openFile(),
                1 => exportText(), // Export's subitem 0
                3 => return dos.RETURN_OK, // Quit: the bar is item 2
                else => {},
            },
            1 => if (mn.ITEMNUM(number) == 0) showGrid(item.flags & mn.CHECKED != 0),
            else => {},
        }
        number = item.next_select;
    }
},
```

### By a finger

On a touch panel there is no menu button. A tap on the screen's bar - a
finger down and lifted where it came down - opens the active window's
menus, and they stay: a tap on a title opens its panel, a finger lifted
over an item picks it and closes the menus, and a tap anywhere else
closes them with `MENUNULL`. The program hears nothing it would not hear
from the button. A window with `WA_RMBTrap` gets no menus by a tap
either, and a finger dragged along the bar past its wobble pulls the
screen down as before.

A finger's pointer events say they are one: input.device marks the
`IECLASS_NEWPOINTERPOS` it makes for the pointer finger with
`IESUBCLASS_FINGER`. intuition lets a finger's press on a drag bar or a
size gadget wobble `TOUCH_SLOP` (8) pixels before it moves anything. A
program that wants a double click by place as well as by time - the same
word of a line of text, where a finger's second tap lands a character
off - asks `DoubleTap` with both presses as `Tap`s; one that compares what
was pressed (a row, an icon) needs only `DoubleClick`.
`C:test/Tap X Y` taps at a place, `TOX TOY` drags there, for a display
with no touch panel; `C:test/Tap DEMO` opens a screen with menus to tap.

## Requesters

`EasyRequestArgs` puts up a window with a message and a row of buttons
and waits for one to be pressed; `sdk.intuition.requesters.EasyRequest`
takes the values as a tuple and checks them against the formats when the
program is built. The message's lines are separated by `\n` and the
buttons by `|`, both RawDoFmt formats taking their values from one
stream, the message's first. The answer is 1, 2, ... for the buttons
from the left and **0 for the rightmost**, where a cancel goes:

```zig
switch (intuition.requesters.EasyRequest(ib, window, .{
    .title = "Notes",
    .text_format = "%s has changed.\nSave it first?",
    .gadget_format = "Save|Don't save|Cancel",
}, null, .{name})) {
    1 => save(),
    2 => {}, // Don't save
    else => return, // Cancel
}
```

It opens on the window's screen, or on the default public screen for a
null window. A program that goes on while the question is up opens it
with `BuildEasyRequestArgs`, asks `SysReqHandler` for the answer as the
requester's messages come (`SYSREQ_PENDING` until one counts) and closes
it with `FreeSysRequest`. A requester can also be put up inside a
window - a `Requester` with gadgets of its own, put up with `Request` and
taken down by `EndRequest` or a gadget made with `GA_EndGadget`, the
window's own gadgets not pressed while it is up (`C:test/Intuition
REQUESTER`). `DisplayBeep(screen)` flashes a screen, for what needs no
answer.

### Files and fonts

asl.library asks for a file, a font or a screen mode. A requester is
made once with `AllocAslRequest`, put up as often as wanted with
`AslRequest` and freed with `FreeAslRequest`; the answer is in the
request structure, which holds until the next `AslRequest` or until it
is freed:

```zig
const asl = sdk.asl;

// ab: asl.library's base (sdk.interface.asl.AslBase), opened by asl.ASLNAME.
const request = ab.AllocAslRequest(asl.ASL_FileRequest, &[_]TagItem{
    .{ .tag = asl.ASLFR_TitleText, .data = @intFromPtr("Open a text") },
    .{ .tag = asl.ASLFR_Window, .data = @intFromPtr(window) },
    .{ .tag = asl.ASLFR_SleepWindow, .data = 1 },
    .{},
}) orelse return dos.RETURN_FAIL;
defer ab.FreeAslRequest(request);
if (ab.AslRequest(request, null)) {
    const answer: *asl.FileRequester = @ptrCast(@alignCast(request));
    // answer.drawer and answer.file, joined with dos's AddPart
}
```

`ASLFR_Window` opens it on the window's screen, `ASLFR_SleepWindow`
keeps the window from taking input while it is up, and
`ASLFR_DoSaveMode` makes it ask for a name to save under.
`ASL_FontRequest` asks for a font, and its `FontRequester`'s `attr` is
ready for `OpenDiskFont` ([Choosing and opening a font](fonts.md#choosing-and-opening-a-font)).
In a window of gadgets, getfile.gadget and getfont.gadget are a field
with a button beside it that opens these requesters
([More than buttons](programs.md#more-than-buttons)). While the desktop
runs, a file dragged from it and let go on the file requester goes to
its drawer with its name in the File field
([Programs on the desktop](anvil.md#programs-on-the-desktop)).

## Trying it

| Command | Shows |
|---|---|
| `C:test/Intuition` | the default screen's size and pens; `WINDOWS` refresh, `GADGETS`, `SLIDERS`, `TEXT`, `MENUS`, `REQUEST`, `REQUESTER` |
| `C:test/Screens SWITCH` | two screens, a window on each, switched with buttons |
| `C:test/Layout` | weights, alignment, labels, wrapping and `GRID` |
| `C:test/Gadgets` | the gadget classes in one layout, each worked by its key |
| `C:test/Settings` | tabs over pages joined by `ICA_MAP`, framed groups |
| `C:test/Widgets` | meters, a canvas drawn into and queued, codes, a chart |
| `C:test/Asl` | the file and font requesters |
| `SYS:Programs/Notepad` | a window object with menus, border scroll bars, a second window, requesters |
| `SYS:Programs/MultiView` | border scroll bars joined to a picture through a model |
