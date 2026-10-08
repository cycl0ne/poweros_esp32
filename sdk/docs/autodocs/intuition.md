# intuition.library

intuition.library's functions: screens, the windows on them, and what a
program shows in a window. A screen is a display's picture, with a
title bar and a style that says how everything on it looks; one may be
pulled down by its bar to show the screens behind it. A window is a
layer on a screen with its border, its gadgets, and an IDCMP port its
program hears from. Gadgets and images are objects: every class is a
Hook handed each message, and passes what it does not handle on to the
class it was made from, up to rootclass. Around them: menus made from
a table, requesters in a window or of their own, text and lines drawn
from a description (an IntuiText is a tag list of IT_ tags), the mouse
pointer, the system's fonts and preferences, DisplayBeep and
DisplayAlert. Open it with OpenLibrary("intuition.library", 0).

Generated from the source by `./zig build autodoc`.

## Index

- [ActivateGadget](#activategadget) - Gives a gadget the input without it being pressed.
- [ActivateWindow](#activatewindow) - Makes a window the active one.
- [AddClass](#addclass) - Makes a class public.
- [AddGList](#addglist) - Puts gadgets into a window.
- [AllocScreenBuffer](#allocscreenbuffer) - Makes one more buffer for a screen to show.
- [AutoRequestTagList](#autorequesttaglist) - Asks with two buttons made from IntuiTexts and waits.
- [BeginDrag](#begindrag) - Starts dragging a picture with the pointer, over every window.
- [BeginRefresh](#beginrefresh) - Begins redrawing what a window lost.
- [BuildEasyRequestArgs](#buildeasyrequestargs) - Opens a requester and hands it back to be answered.
- [BuildSysRequestTagList](#buildsysrequesttaglist) - A two-button requester from IntuiTexts, handed back.
- [ChangeScreenBuffer](#changescreenbuffer) - Shows one of a screen's buffers.
- [ChangeWindowBox](#changewindowbox) - Moves and sizes a window at once.
- [ClearDMRequest](#cleardmrequest) - No double-click requester any more.
- [ClearMenuStrip](#clearmenustrip) - Takes a window's menus away.
- [CloseScreen](#closescreen) - Closes a screen.
- [CloseWindow](#closewindow) - Closes a window.
- [CoerceMessage](#coercemessage) - Sends a message to an object as a given class would handle it.
- [CreateMenusA](#createmenusa) - Makes a menu strip, or one panel's items, from a table.
- [CurrentTime](#currenttime) - Answers the time of the latest input event.
- [DisplayAlert](#displayalert) - Shows an alert and waits for an answer.
- [DisplayBeep](#displaybeep) - Flashes a screen, to draw the eye without a requester.
- [DisposeObject](#disposeobject) - Frees an object.
- [DoGadgetMethodA](#dogadgetmethoda) - Sends a gadget a method with its window's GadgetInfo.
- [DoubleClick](#doubleclick) - Whether two moments are close enough to be a double-click.
- [DoubleTap](#doubletap) - Whether two presses are close enough in time and in place to be a double click - of a mouse or a finger.
- [DrawBorder](#drawborder) - Draws a Border and the Borders linked after it.
- [DrawImage](#drawimage) - Draws an image.
- [DrawImageState](#drawimagestate) - Draws an image in a state.
- [DrawPart](#drawpart) - Draws a part of a gadget in a state, from its style.
- [EasyRequestArgs](#easyrequestargs) - Asks something in a requester and waits for the answer.
- [EndDrag](#enddrag) - Ends a drag `BeginDrag` started, and says which window it ended over.
- [EndRefresh](#endrefresh) - Ends a redraw begun with BeginRefresh.
- [EndRequest](#endrequest) - Takes a requester down.
- [EraseImage](#eraseimage) - Erases what an image covers.
- [FindClass](#findclass) - Finds a public class by name.
- [FreeClass](#freeclass) - Frees a class.
- [FreeMenus](#freemenus) - Gives back a strip, or a panel's items, that CreateMenusA made.
- [FreeScreenBuffer](#freescreenbuffer) - Gives back a buffer from `AllocScreenBuffer`.
- [FreeScreenDrawInfo](#freescreendrawinfo) - Hands back a DrawInfo.
- [FreeSysRequest](#freesysrequest) - Closes a requester and gives back what was made for it.
- [GadgetMouse](#gadgetmouse) - Answers where the pointer is, measured from a gadget's top-left corner.
- [GadgetStyleState](#gadgetstylestate) - The style state to draw a gadget's part in, with its transition.
- [GetAttr](#getattr) - Reads one attribute of an object.
- [GetDefPrefs](#getdefprefs) - The settings the system starts with.
- [GetDefaultPubScreen](#getdefaultpubscreen) - Names the default public screen.
- [GetIMsg](#getimsg) - Takes the next message off a window's port.
- [GetPrefs](#getprefs) - The system's settings as they are now.
- [GetScreenAttrs](#getscreenattrs) - Reads a screen.
- [GetScreenDrawInfo](#getscreendrawinfo) - The pens and font a screen's parts are drawn in.
- [GetStyleAttr](#getstyleattr) - One property of a part in a state, found as `DrawPart` finds it.
- [GetWindowAttrs](#getwindowattrs) - Reads a window.
- [HelpControl](#helpcontrol) - Turns gadget help on or off for a window and its help group.
- [InitRequester](#initrequester) - Clears a Requester to be filled in.
- [IntuiTextLength](#intuitextlength) - How wide one run of an IntuiText is, in pixels.
- [ItemAddress](#itemaddress) - The item a menu number names.
- [LayoutMenuItemsA](#layoutmenuitemsa) - Places the items of one panel, and their subitems, that CreateMenusA made from a table of items.
- [LayoutMenusA](#layoutmenusa) - Places every title, item and subitem of a strip CreateMenusA made, for a screen.
- [LendMenus](#lendmenus) - Makes one window's menu button show another window's menus.
- [LockClassList](#lockclasslist) - Holds the public class list.
- [LockIBase](#lockibase) - Holds the screens and windows still.
- [LockPubScreen](#lockpubscreen) - Locks a public screen, opening the default one if needed.
- [LockPubScreenList](#lockpubscreenlist) - Holds the list of public screens, and answers it.
- [MakeClass](#makeclass) - Makes a class.
- [ModifyIDCMP](#modifyidcmp) - Changes which messages a window gets.
- [MoveScreen](#movescreen) - Moves a screen up or down its display by an amount.
- [MoveWindow](#movewindow) - Moves a window.
- [MoveWindowInFrontOf](#movewindowinfrontof) - Puts a window just in front of another.
- [NewObjectTagList](#newobjecttaglist) - Makes an object.
- [NextObject](#nextobject) - Walks a list of objects.
- [NextPubScreen](#nextpubscreen) - Names the public screen after a given one, going round.
- [ObtainGIRPort](#obtaingirport) - The RastPort a gadget draws into, for a moment.
- [OffGadget](#offgadget) - Keeps a gadget from being pressed, and shows it so.
- [OffMenu](#offmenu) - Keeps a menu, an item or a subitem from being picked.
- [OnGadget](#ongadget) - Lets a gadget be pressed again, and shows it so.
- [OnMenu](#onmenu) - Lets a menu, an item or a subitem be picked again.
- [OpenScreenTagList](#openscreentaglist) - Opens a screen.
- [OpenSystemFont](#opensystemfont) - One of the system's fonts, opened.
- [OpenWindowTagList](#openwindowtaglist) - Opens a window.
- [PointInImage](#pointinimage) - Whether a point is inside an image.
- [PrintIText](#printitext) - Draws an IntuiText and the runs linked after it.
- [PubScreenStatus](#pubscreenstatus) - Opens a public screen to visitors, or closes it to them.
- [QueueGadgetRefresh](#queuegadgetrefresh) - A gadget drawn again by intuition soon, with whatever it holds then.
- [RefreshGList](#refreshglist) - Draws gadgets of a window.
- [RefreshWindowFrame](#refreshwindowframe) - Draws a window's border again.
- [ReleaseGIRPort](#releasegirport) - Gives back a RastPort from `ObtainGIRPort`.
- [RemoveClass](#removeclass) - Takes a class off the public list.
- [RemoveGList](#removeglist) - Takes gadgets out of a window.
- [ReplyIMsg](#replyimsg) - Hands a message from `GetIMsg` back.
- [ReportMouse](#reportmouse) - Turns the reports of the pointer's moves to a window on or off.
- [Request](#request) - Puts a requester up in a window.
- [ResetMenuStrip](#resetmenustrip) - Gives a window back a strip it already had.
- [ScreenDepth](#screendepth) - Moves a screen to the front of its display or to the back.
- [ScreenPositionTagList](#screenpositiontaglist) - Puts a screen at a place on its display, or moves it by an amount.
- [ScreenToBack](#screentoback) - Puts a screen behind the others on its display.
- [ScreenToFront](#screentofront) - Brings a screen to the front of its display.
- [ScrollWindowRaster](#scrollwindowraster) - Moves part of what a window shows, and clears what it leaves.
- [SendMessage](#sendmessage) - Sends a message to an object.
- [SendSuperMessage](#sendsupermessage) - Sends a message on to a class's superclass.
- [SetAttrsTagList](#setattrstaglist) - Changes an object's attributes.
- [SetDMRequest](#setdmrequest) - The requester a double-click of the menu button puts up.
- [SetDefaultPubScreen](#setdefaultpubscreen) - Chooses the public screen windows open on by default.
- [SetEditHook](#setedithook) - Puts the global edit hook every string gadget's keys go through first.
- [SetGadgetAttrsTagList](#setgadgetattrstaglist) - Changes a gadget's attributes, and lets it show the change.
- [SetMenuStrip](#setmenustrip) - Gives a window its menus.
- [SetMouseQueue](#setmousequeue) - Sets how many pointer moves a window may have waiting.
- [SetPrefs](#setprefs) - The system's settings changed.
- [SetPubScreenModes](#setpubscreenmodes) - Sets how public screens behave, for every program.
- [SetScreenPens](#setscreenpens) - A screen's pens, or the system's, replaced - and every screen it reaches painted again in them.
- [SetStyle](#setstyle) - A screen's style, or the system's, replaced - and every window it reaches drawn again in it.
- [SetSystemFonts](#setsystemfonts) - The fonts screens, windows and consoles use from now on.
- [SetWindowPointerA](#setwindowpointera) - Gives a window its own mouse pointer, the busy pointer, the default, or none at all.
- [SetWindowTitles](#setwindowtitles) - Changes a window's title and the screen title it shows while active.
- [ShowTitle](#showtitle) - Puts a screen's title bar in front of its backdrop windows, or behind them.
- [SizeWindow](#sizewindow) - Sizes a window.
- [StylePens](#stylepens) - The screen's pens, with the ones that stand for a gadget's look taken from a part of the style.
- [SysReqHandler](#sysreqhandler) - Reads what arrived at a requester.
- [TimedDisplayAlert](#timeddisplayalert) - Shows an alert and waits for an answer, or for the time to run out.
- [UnlockClassList](#unlockclasslist) - Lets the public class list go.
- [UnlockIBase](#unlockibase) - Lets the screens and windows go again.
- [UnlockPubScreen](#unlockpubscreen) - Unlocks a public screen.
- [UnlockPubScreenList](#unlockpubscreenlist) - Lets the list of public screens go.
- [WaitIMsg](#waitimsg) - Waits until a window has a message, or one of some other signals comes.
- [WindowLimits](#windowlimits) - Sets how small and how large a window may be sized.
- [WindowToBack](#windowtoback) - Puts a window at the back.
- [WindowToFront](#windowtofront) - Brings a window to the front.
- [ZipWindow](#zipwindow) - Flips a window to its other box and back.

## ActivateGadget

Gives a gadget the input without it being pressed.

**SYNOPSIS**

```zig
fn ActivateGadget(ib: *IntuitionBase, gadget: *Object, window: *Window, requester: ?*Requester) bool
```

**SINCE**

0.12. LVO -292.

**INPUTS**

- `gadget` - a gadget in the window - on its list, or a member of a
  layout or group that is - or of the requester in front in it.
- `window` - its window, which must be the active one.
- `requester` - the requester the gadget is in, or null for one of the
  window's own.

**RESULT**

True when the gadget has the input; false otherwise.

**BEHAVIOR**

The gadget is sent `GM_GOACTIVE` with no input event - which is how a
class tells this from a press - as Tab does when it arrives at a gadget.
If it answers `GMR_MEACTIVE` it has every event from then on until it
is done, as though it had been clicked: a strgclass line takes the keys
at once, its cursor shown. A gadget that answers anything else is done
straight away, and the window is told as for a press (`IDCMP_GADGETUP`
with `GA_RelVerify`).

Nothing is interrupted to make room for it: it fails when the window is
not the active one, when a gadget or a border gadget already has the
pointer or the input, while a menu session runs, when the gadget is
disabled or not on this window, and when `requester` is not the one it
is in. While a requester is up only a gadget of the one in front may
be given the input, since the window's own do not take any.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

A window is not necessarily active the moment `OpenWindowTagList`
returns with `WA_Activate`; a program that wants a field ready for typing
calls this when `IDCMP_ACTIVEWINDOW` arrives, and again after the field
is done if it should stay ready.

**BUGS**

None known.

**SEE ALSO**

`DoGadgetMethodA`, `AddGList`, `ActivateWindow`

**EXAMPLES**

```zig
if (message.class == IDCMP_ACTIVEWINDOW) _ = ib.ActivateGadget(name_field, window, null);
```

## ActivateWindow

Makes a window the active one.

**SYNOPSIS**

```zig
fn ActivateWindow(ib: *IntuitionBase, window: *Window) void
```

**SINCE**

0.5. LVO -164.

**INPUTS**

- `window` - the window.

**RESULT**

Nothing.

**BEHAVIOR**

Its border is drawn in the fill pen and its title in the fill-text
pen; the window that was active has its border drawn in the background
pen and is told `IDCMP_INACTIVEWINDOW`, and this one `IDCMP_ACTIVEWINDOW`.
One window is active at a time, across every screen. Its screen's bar
shows the window's screen title (`WA_ScreenTitle`, or the screen's own);
a screen the active window leaves shows its own title again.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

- Once there is input, the active window is the one keys go to.

**BUGS**

None known.

**SEE ALSO**

`OpenWindowTagList` (`WA_Activate`)

**EXAMPLES**

```zig
ib.ActivateWindow(window);
```

## AddClass

Makes a class public.

**SYNOPSIS**

```zig
fn AddClass(ib: *IntuitionBase, cl: *Class) void
```

**SINCE**

0.2. LVO -28.

**INPUTS**

- `cl` - a class from `MakeClass`, its dispatcher already set.

**RESULT**

Nothing.

**BEHAVIOR**

It goes on the front of the public list, where `FindClass` and
`NewObjectTagList` by name reach it. A private class (no name) and one
already on the list are left as they are.

**CONTEXT**

- Waits: for the class list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Still the caller's; the list only points at it.

**NOTES**

- It does not check the name again. `MakeClass` refused a taken name,
  but two classes made with one name before either was added can both
  be added, and the newer is found first.

**BUGS**

None known.

**SEE ALSO**

`RemoveClass`, `FindClass`

**EXAMPLES**

```zig
ib.AddClass(cl);
```

## AddGList

Puts gadgets into a window.

**SYNOPSIS**

```zig
fn AddGList(ib: *IntuitionBase, window: *Window, gadget: *Object,
    position: i32, count: i32) u32
```

**SINCE**

0.6. LVO -184.

**INPUTS**

- `window` - the window.
- `gadget` - the first gadget: a gadgetclass object, or one of a class
  made from it, in no window.
- `position` - how many of the window's gadgets go before it; -1, or
  more than it has, puts them at the end.
- `count` - how many, following each gadget's link to the next
  (`GA_Previous`); -1 for all of them.

**RESULT**

The position they went in at.

**BEHAVIOR**

The gadgets are linked into the window's list and from then on are
hit-tested and fed input there. Nothing is drawn: `RefreshGList` does
that.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The gadgets stay the program's. The window only holds them, until
`RemoveGList` or `CloseWindow`; they are disposed of by the program.

**NOTES**

Not while holding the window's layer lock: the input task draws gadgets
with the screen list's semaphore held and then takes that lock.

**BUGS**

None known.

**SEE ALSO**

`RemoveGList`, `RefreshGList`, `sdk.intuition.windows.WA_Gadgets`

**EXAMPLES**

```zig
_ = ib.AddGList(window, ok_button, -1, 1);
ib.RefreshGList(ok_button, window, 1);
```

## AllocScreenBuffer

Makes one more buffer for a screen to show.

**SYNOPSIS**

```zig
fn AllocScreenBuffer(ib: *IntuitionBase, screen: *Screen, flags: u32) ?*ScreenBuffer
```

**SINCE**

0.14. LVO -396.

**INPUTS**

- `screen` - the screen.
- `flags` - `SB_SCREEN_BITMAP` for the screen's own buffer, else 0 or
  `SB_COPY_BITMAP` for a new one.

**RESULT**

The buffer, or null: no memory, or no room in the display's memory for
another picture.

**BEHAVIOR**

A new buffer is a picture the screen's size in its display's memory,
black - or a copy of the screen's own with `SB_COPY_BITMAP` - with a
RastPort over the whole of it. With `SB_SCREEN_BITMAP` nothing is
allocated: the buffer is the screen's own, the one its bar, windows and
menus are drawn in, and its RastPort the screen's. Two buffers, drawn
and shown in turn with `ChangeScreenBuffer`, are double buffering.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The buffer is the caller's, to give back with `FreeScreenBuffer` before
the screen closes.

**NOTES**

A display's memory holds a few pictures, and each open screen takes
one: on a display with room for two, one screen and one more buffer is
all there is.

**BUGS**

None known.

**SEE ALSO**

`ChangeScreenBuffer`, `FreeScreenBuffer`

**EXAMPLES**

```zig
const front = ib.AllocScreenBuffer(screen, sc.SB_SCREEN_BITMAP) orelse return;
const back = ib.AllocScreenBuffer(screen, 0) orelse return;
```

## AutoRequestTagList

Asks with two buttons made from IntuiTexts and waits.

**SYNOPSIS**

```zig
fn AutoRequestTagList(ib: *IntuitionBase, window: ?*Window, tags: ?[*]const TagItem) bool
```

**SINCE**

0.13. LVO -320.

**INPUTS**

- `window` - the reference window, as for `BuildSysRequestTagList`, or
  null.
- `tags` - `SYSREQ_Body`, `SYSREQ_Positive` and `SYSREQ_Negative`, what
  it says and its two buttons, as for `BuildSysRequestTagList`;
  `SYSREQ_PositiveFlags`, IDCMP classes that answer it as the left
  button, and `SYSREQ_NegativeFlags`, as the right one.

**RESULT**

True for the left button or a class of `SYSREQ_PositiveFlags`; false
for the right button, a class of `SYSREQ_NegativeFlags`, or when the
requester could not be made.

**BEHAVIOR**

`BuildSysRequestTagList` with both sets of classes as its
`SYSREQ_IDCMPFlags`, `SysReqHandler` until it is answered, and
`FreeSysRequest`. The left Amiga key with V answers as the left button
and with B as the right one.

**CONTEXT**

- Waits: for the answer, and for the screen list's semaphore.
- Interrupts: no.
- Locks: no spinlock may be held: it waits.
- Process: a Task will do.

**OWNERSHIP**

The texts and the tags stay the caller's.

**NOTES**

`EasyRequestArgs` asks the same with formats and any number of buttons.

**BUGS**

None known.

**SEE ALSO**

`BuildSysRequestTagList`, `EasyRequestArgs`, `SysReqHandler`

**EXAMPLES**

```zig
const body = intuition.text.plainRun("Save the changes?", null);
const yes = intuition.text.plainRun("Save", null);
const no = intuition.text.plainRun("Discard", null);
const save = ib.AutoRequestTagList(window, &[_]TagItem{
    .{ .tag = SYSREQ_Body, .data = @intFromPtr(&body) },
    .{ .tag = SYSREQ_Positive, .data = @intFromPtr(&yes) },
    .{ .tag = SYSREQ_Negative, .data = @intFromPtr(&no) },
    .{},
});
```

## BeginDrag

Starts dragging a picture with the pointer, over every window.

**SYNOPSIS**

```zig
fn BeginDrag(ib: *IntuitionBase, window: *Window, image: *const rtg.Surface, hot_x: u32, hot_y: u32) bool
```

**SINCE**

0.34. LVO -512.

**INPUTS**

- `window` - the window the drag starts in: its screen is where the
  picture is shown.
- `image` - the picture: a surface in `rgba32`, `bgra32` or
  `argb1555`, at most `RTG_OVERLAY_MAX` pixels each way - an icon, or
  a few drawn together.
- `hot_x`, `hot_y` - the pixel of the picture that sits at the
  pointer's point: where it was taken hold of.

**RESULT**

True while the picture follows the pointer; false when another drag
is on, the display cannot lay a picture over itself, or the picture
will not do (too large, no alpha).

**BEHAVIOR**

The display lays the picture over everything on the way to the glass,
under the pointer, as it lays the pointer: windows go on drawing under
it, nothing waits for it, and it moves with every pointer move without
the program doing anything. Its coverage is shown as a pattern of
dots, so a soft edge or a picture made see-through keeps its look. It
is shown on a touch panel too, where the pointer itself is not. The
program goes on hearing the pointer as before - `IDCMP_MOUSEMOVE` with
`WFLG_REPORTMOUSE`, the button let go as `IDCMP_MOUSEBUTTONS` - and
ends the drag with `EndDrag` when it is let go.

**CONTEXT**

- Waits: for the screen list's semaphore, and while the display
  converts the picture.
- Interrupts: no. It allocates.
- Locks: none needed; no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The picture is read and not kept: it may be freed when the call
returns.

**NOTES**

One drag at a time on the whole system. A window closed while it
drags ends the drag.

**BUGS**

None known.

**SEE ALSO**

`EndDrag`, rtg.library's `SetBoardOverlay`

**EXAMPLES**

```zig
const picture = rtg.Surface{ .pixels = icon.pixels, .width = icon.width, .height = icon.height, .pitch = icon.width * 4, .format = .rgba32 };
if (ib.BeginDrag(window, &picture, 24, 24)) {
    // ... until the button is let go ...
    const target = ib.EndDrag(window, 0);
    _ = target;
}
```

## BeginRefresh

Begins redrawing what a window lost.

**SYNOPSIS**

```zig
fn BeginRefresh(ib: *IntuitionBase, window: *Window) void
```

**SINCE**

0.5. LVO -172.

**INPUTS**

- `window` - the window, after an `IDCMP_REFRESHWINDOW`.

**RESULT**

Nothing.

**BEHAVIOR**

Until `EndRefresh`, drawing through the window's RastPort reaches only
the part that needs it, so a program may simply draw everything. A
further IDCMP_REFRESHWINDOW can be sent from here on. For a window
with nothing to redraw it does nothing, and so does its EndRefresh.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

- The border was put back before the message was sent.

**BUGS**

None known.

**SEE ALSO**

`EndRefresh`

**EXAMPLES**

```zig
ib.BeginRefresh(window);
drawEverything(window);
ib.EndRefresh(window, true);
```

## BuildEasyRequestArgs

Opens a requester and hands it back to be answered.

**SYNOPSIS**

```zig
fn BuildEasyRequestArgs(ib: *IntuitionBase, window: ?*Window,
    easy_struct: *const EasyStruct, idcmp: u32,
    args: ?*const anyopaque) ?*Window
```

**SINCE**

0.11. LVO -252.

**INPUTS**

- `window` - the window the requester is about: it opens on this
  window's screen and takes its title. Null puts it on the default
  public screen.
- `easy_struct` - what it says: `text_format`, lines separated by `\n`,
  and `gadget_format`, the buttons from the left separated by `|`;
  `title`, or null for the window's title, or "System Request" without
  a window.
- `idcmp` - IDCMP classes of the caller's own that answer it as well,
  as `SysReqHandler`'s -1; 0 for none.
- `args` - the values for both formats, as RawDoFmt reads them: the
  message's first, then the buttons' (`sdk.exec.fmtStream`). Null when
  neither format has a `%`.

**RESULT**

The requester's window, active, or null when it could not be made:
there was no memory, no screen, or the window would not open.

**BEHAVIOR**

Both formats are expanded with RawDoFmt and then split, so a value may
add a line or a button. The message is laid out a line under the other
in the screen's font, sunk in a frame, and drawn once - the window is
smart refresh, so what is covered is kept. The buttons, framed and in a
row under it, are spread to the frame's width, a single one centred.
The frame is as wide as the message with room each side, the row of
buttons, or the title, whichever is widest, within the screen. The
window opens at the screen's top left, with a drag bar and a depth
gadget.

The buttons answer 1, 2, ... from the left and 0 for the rightmost,
which is where a cancel goes.

**CONTEXT**

- Waits: for the screen list's semaphore and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do. A process has its IoErr set: 0 when the
  requester opened, `ERROR_NO_FREE_STORE` when it did not.

**OWNERSHIP**

The window and everything made for it are the caller's until
`FreeSysRequest`. The EasyStruct and the values are read here and not
kept.

**NOTES**

- Read the answers with `SysReqHandler`, which knows what the window's
  messages mean.

**BUGS**

- A message wider than the screen is cut off by it, and so is a row of
  buttons that does not fit.

**SEE ALSO**

`EasyRequestArgs`, `SysReqHandler`, `FreeSysRequest`

**EXAMPLES**

```zig
const ask = EasyStruct{ .text_format = "Save %s?", .gadget_format = "Save|Cancel" };
const stream = sdk.exec.fmtStream(.{name});
const req = ib.BuildEasyRequestArgs(window, &ask, 0, &stream) orelse return;
defer ib.FreeSysRequest(req);
```

## BuildSysRequestTagList

A two-button requester from IntuiTexts, handed back.

**SYNOPSIS**

```zig
fn BuildSysRequestTagList(ib: *IntuitionBase, window: ?*Window, tags: ?[*]const TagItem) ?*Window
```

**SINCE**

0.13. LVO -324.

**INPUTS**

- `window` - the reference window: the requester opens on its screen,
  with its title. Null for the default public screen.
- `tags` - `SYSREQ_Body`, what it says, an IntuiText whose every run is
  a line; `SYSREQ_Positive`, the left button's text - yes, retry, go
  on - or none; `SYSREQ_Negative`, the right button's text - no,
  cancel;
  `SYSREQ_IDCMPFlags`, IDCMP classes of the caller's own that answer it too.
  The body and the right button are required.

**RESULT**

The requester's window, to be answered with `SysReqHandler` - 1 for the
left button, 0 for the right, -1 for a class of `SYSREQ_IDCMPFlags` - and
closed with `FreeSysRequest`. Null when it could not be made, or the
body or the right button is missing.

**BEHAVIOR**

The same requester `BuildEasyRequestArgs` makes: a frame with the lines
in it and the buttons under them, the left Amiga key with V and B
answering for the left and the right one. The runs' `IT_Text` is taken
as it is - no format is read in it - and their pens, fonts, styles and
places give way to the requester's own look.

**CONTEXT**

- Waits: for the screen list's semaphore and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The texts stay the caller's; the requester copies their words. The
window is the caller's until `FreeSysRequest`.

**NOTES**

A `|` in a button's text divides it into two buttons, as a
`gadget_format` would.

**BUGS**

None known.

**SEE ALSO**

`AutoRequestTagList`, `BuildEasyRequestArgs`, `SysReqHandler`,
`FreeSysRequest`

**EXAMPLES**

```zig
const second = intuition.text.plainRun("is not answering.", null);
const body = [_]TagItem{
    .{ .tag = intuition.IT_Text, .data = @intFromPtr("The printer") },
    .{ .tag = intuition.IT_Next, .data = @intFromPtr(&second) },
    .{},
};
const retry = intuition.text.plainRun("Retry", null);
const cancel = intuition.text.plainRun("Cancel", null);
const req = ib.BuildSysRequestTagList(null, &[_]TagItem{
    .{ .tag = SYSREQ_Body, .data = @intFromPtr(&body) },
    .{ .tag = SYSREQ_Positive, .data = @intFromPtr(&retry) },
    .{ .tag = SYSREQ_Negative, .data = @intFromPtr(&cancel) },
    .{},
}) orelse return;
defer ib.FreeSysRequest(req);
```

## ChangeScreenBuffer

Shows one of a screen's buffers.

**SYNOPSIS**

```zig
fn ChangeScreenBuffer(ib: *IntuitionBase, screen: *Screen, buffer: *ScreenBuffer) bool
```

**SINCE**

0.14. LVO -400.

**INPUTS**

- `screen` - the screen.
- `buffer` - one of its buffers from `AllocScreenBuffer`.

**RESULT**

True when it is shown. False while the screen's menus are up: they are
drawn in the screen's own buffer, and taking it away would leave them
working unseen. Try again with the next frame.

**BEHAVIOR**

The display takes the buffer up at the start of its next frame, whole,
and this returns when it has: the buffer shown before is no longer read
and the next frame can be drawn into it. A screen that is not in front
shows the buffer when it is brought forward.

**CONTEXT**

- Waits: for the screen list's semaphore, and for the display's next
  frame - which paces a program drawing a frame at a time to the display.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

The screen's bar, windows and menus are in its own buffer
(`SB_SCREEN_BITMAP`) and are seen while that one is shown.

**BUGS**

None known.

**SEE ALSO**

`AllocScreenBuffer`, `FreeScreenBuffer`

**EXAMPLES**

```zig
var buffers = [2]*sc.ScreenBuffer{ front, back };
var drawing: usize = 1;
while (running) {
    drawFrame(buffers[drawing].rast_port);
    if (ib.ChangeScreenBuffer(screen, buffers[drawing])) drawing ^= 1;
}
```

## ChangeWindowBox

Moves and sizes a window at once.

**SYNOPSIS**

```zig
fn ChangeWindowBox(ib: *IntuitionBase, window: *Window, left: i32,
    top: i32, width: i32, height: i32) void
```

**SINCE**

0.5. LVO -152.

**INPUTS**

- `window` - the window.
- `left`, `top`, `width`, `height` - the new box, on the screen.

**RESULT**

Nothing.

**BEHAVIOR**

The size is kept within the window's limits, never below its border,
and no larger than the screen. The place keeps it on the screen - or,
while windows may hang past the screen's edges (`IPREFS_OffScreen`),
keeps enough of it there to take hold of again: its top never above
the screen's, 64 pixels of its width across, and its title bar above
the bottom. A box that does not fit where it is given is moved. When the size
changed, what was the right and bottom border is cleared to the
background and the border drawn where it now is, and the program is
told `IDCMP_NEWSIZE`; either way it is told `IDCMP_CHANGEWINDOW`.
Whatever the change uncovered is repaired.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

- A smart window keeps its contents through a move. After a size, what
  is new inside it is the background: redraw on IDCMP_NEWSIZE.

**BUGS**

None known.

**SEE ALSO**

`MoveWindow`, `SizeWindow`

**EXAMPLES**

```zig
ib.ChangeWindowBox(window, 40, 40, 300, 200);
```

## ClearDMRequest

No double-click requester any more.

**SYNOPSIS**

```zig
fn ClearDMRequest(ib: *IntuitionBase, window: *Window) bool
```

**SINCE**

0.13. LVO -316.

**INPUTS**

- `window` - the window.

**RESULT**

True; false, and nothing changed, while the double-click requester is
up.

**BEHAVIOR**

The window has no double-click requester afterwards: a double-click of
the menu button is two presses of it, as for any window.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The requester stays the caller's, and must stay where it is until it is
cleared again - which must happen before the window closes.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`SetDMRequest`, `Request`, `sdk.intuition.windows.IDCMP_REQVERIFY`

**EXAMPLES**

```zig
_ = ib.ClearDMRequest(window);
```

## ClearMenuStrip

Takes a window's menus away.

**SYNOPSIS**

```zig
fn ClearMenuStrip(ib: *IntuitionBase, window: *Window) void
```

**SINCE**

0.12. LVO -268.

**INPUTS**

- `window` - the window.

**RESULT**

Nothing.

**BEHAVIOR**

The window has no strip afterwards: the menu button over it shows an
empty bar, and no shortcut picks anything. A session showing its menus
ends first, and the window is sent IDCMP_MENUPICK `MENUNULL`. A window
with no strip is left as it is.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The strip is the caller's to change or free once this returns.

**NOTES**

Every window that was given a strip must have it cleared before it
closes.

**BUGS**

None known.

**SEE ALSO**

`SetMenuStrip`, `ResetMenuStrip`

**EXAMPLES**

```zig
ib.ClearMenuStrip(window);
ib.CloseWindow(window);
```

## CloseScreen

Closes a screen.

**SYNOPSIS**

```zig
fn CloseScreen(ib: *IntuitionBase, screen: ?*Screen) bool
```

**SINCE**

0.4. LVO -100.

**INPUTS**

- `screen` - the screen, or null.

**RESULT**

True when it closed, or `screen` was null. False, with the screen still
open, while a public screen is locked by anyone.

**BEHAVIOR**

Its bar and LayerInfo go, and a font the screen opened for itself is
closed. Its display shows the screen behind it, or - when it was the
last - goes black. The buffer it drew in is given back to the display's
memory for another screen.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no; it frees memory.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

On true, the screen and everything read out of it - its RastPort,
LayerInfo and DrawInfo - are gone.

**NOTES**

- It will refuse while windows are open on it, once there are windows.

**BUGS**

None known.

**SEE ALSO**

`OpenScreenTagList`, `UnlockPubScreen`

**EXAMPLES**

```zig
if (!ib.CloseScreen(screen)) return; // still locked by someone
```

## CloseWindow

Closes a window.

**SYNOPSIS**

```zig
fn CloseWindow(ib: *IntuitionBase, window: ?*Window) void
```

**SINCE**

0.5. LVO -136.

**INPUTS**

- `window` - the window, or null, which does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

Its layer goes, so what it covered is uncovered and any simple-refresh
window underneath is repaired. Messages still waiting on its port are
freed with the port. If it was active, no window is. A window opened on
a public screen by name, or on the default one, ends its visit, which
may be the last the screen's owner is waiting for.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The window, its RastPort and its port are gone. Every message the
program took off the port must have been replied first.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`OpenWindowTagList`

**EXAMPLES**

```zig
ib.CloseWindow(window);
```

## CoerceMessage

Sends a message to an object as a given class would handle it.

**SYNOPSIS**

```zig
fn CoerceMessage(ib: *IntuitionBase, cl: *Class, object: ?*Object,
    msg: *Msg) usize
```

**SINCE**

0.2. LVO -76.

**INPUTS**

- `cl` - the class whose dispatcher is to handle it.
- `object` - the object, which is handed to that dispatcher as it is.
- `msg` - the message.

**RESULT**

What that class answers.

**BEHAVIOR**

The class's dispatcher is called through utility.library's
CallHookPkt, with the class as the hook. Every message to every object
ends here.

**CONTEXT**

- Waits: whatever the class does.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The message is the caller's.

**NOTES**

- The one place every message passes through, and a slot - so one
  SetFunction sees them all.

**BUGS**

None known.

**SEE ALSO**

`SendMessage`, `SendSuperMessage`

**EXAMPLES**

```zig
const made = ib.CoerceMessage(cl, @ptrCast(cl), @ptrCast(&new_msg));
```

## CreateMenusA

Makes a menu strip, or one panel's items, from a table.

**SYNOPSIS**

```zig
fn CreateMenusA(ib: *IntuitionBase, new_menu: [*]const NewMenu, tags: ?[*]const TagItem) ?*Menu
```

**SINCE**

0.17. LVO -436.

**INPUTS**

- `new_menu` - the table, ended by an entry of type `NM_END`: titles
  (`NM_TITLE`), each followed by its items (`NM_ITEM`, `IM_ITEM`), each
  of those by its subitems (`NM_SUB`, `IM_SUB`). A table that starts
  with an item is one panel's items.
- `tags` - `GTMN_FrontPen`, the text's colour until a layout sets it;
  `GTMN_FullMenu`, the table must start with a title;
  `GTMN_SecondaryError`, where to say what went wrong.

**RESULT**

The first title, or for a table of items the first item (cast to it),
with every title, item and subitem linked; null when the table is not
a menu - a subitem right after a title, nothing in it, or a fragment
under `GTMN_FullMenu` - or there is no memory. `GTMN_SecondaryError`
is told `GTMENU_INVALID`, `GTMENU_NOMEM`, `GTMENU_TRIMMED` - more
titles, items or subitems than menu numbers can name, the strip made
without them - or 0.

**BEHAVIOR**

An item's words are an IntuiText of their own, one row down: a tag
list with every `IT_` tag the layout fills in - `IT_Left`,
`IT_FrontPen`, `IT_Font` - in it, and writable. A key in `comm_key`
makes it `COMMSEQ`; with `NM_COMMANDSTRING` the words in `comm_key`
are a second run, linked by `IT_Next` and put at the item's right by
the layout. The first subitem of a text item gives that item a second
run, "»", at its right. `NM_BARLABEL` is a separator: a
fillrectclass rule two rows high, neither picked nor highlighted.
`IM_ITEM`'s image object is the item's, moved down a row; it is not
copied. `NM_MENUDISABLED` and `NM_ITEMDISABLED` make it disabled; the
rest of `flags` is the item's. Each title and item keeps the table's
`user_data` right after it (`GTMENU_USERDATA`, `GTMENUITEM_USERDATA`).
Nothing is placed: `LayoutMenusA` does that.

**CONTEXT**

- Waits: no; it allocates.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The strip is the caller's, given back with `FreeMenus` once it is off
every window. The table's words and images are the caller's and must
last as long as the strip.

**BUGS**

None known.

**SEE ALSO**

`FreeMenus`, `LayoutMenusA`, `LayoutMenuItemsA`, `SetMenuStrip`

**EXAMPLES**

```zig
const table = [_]mn.NewMenu{
    .{ .type = mn.NM_TITLE, .label = "Project" },
    .{ .type = mn.NM_ITEM, .label = "Open...", .comm_key = "O" },
    .{ .type = mn.NM_ITEM, .label = mn.NM_BARLABEL },
    .{ .type = mn.NM_ITEM, .label = "Quit", .comm_key = "Q" },
    .{ .type = mn.NM_END },
};
const strip = ib.CreateMenusA(&table, null) orelse return;
defer ib.FreeMenus(strip);
```

## CurrentTime

Answers the time of the latest input event.

**SYNOPSIS**

```zig
fn CurrentTime(ib: *IntuitionBase, seconds: *u32, micros: *u32) void
```

**SINCE**

0.14. LVO -412.

**INPUTS**

- `seconds`, `micros` - where the time goes.

**RESULT**

Nothing; the time is where the two point.

**BEHAVIOR**

The time stamp of the input event intuition handled last, in the
system time's seconds and microseconds - the clock `DoubleClick` and
IDCMP messages are measured on. With input.device running a timer
event comes ten times a second, so it is never more than a tenth of a
second behind; before any event it is 0.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

For a precise time, timer.device's `GetSysTime`.

**BUGS**

None known.

**SEE ALSO**

`DoubleClick`

**EXAMPLES**

```zig
var seconds: u32 = 0;
var micros: u32 = 0;
ib.CurrentTime(&seconds, &micros);
```

## DisplayAlert

Shows an alert and waits for an answer.

**SYNOPSIS**

```zig
fn DisplayAlert(ib: *IntuitionBase, alert_number: u32, text: [*:0]const u8, height: u32) bool
```

**SINCE**

0.14. LVO -416.

**INPUTS**

- `alert_number` - what the alert is; `AT_DeadEnd` set for one the
  system does not come back from.
- `text` - what it says, lines parted by `'\n'`, each centred.
- `height` - the least height of its box, in pixels.

**RESULT**

True for the left button or a touch on the left half of the display;
false for the right, when it could not be shown, and for a dead end.

**BEHAVIOR**

`TimedDisplayAlert` with no time-out worth the name: it stays up until
it is answered.

**CONTEXT**

- Waits: for the answer, and for an alert already up.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do; not intuition's input task.

**OWNERSHIP**

The text is read while the alert is up and not kept.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`TimedDisplayAlert`

**EXAMPLES**

```zig
if (!ib.DisplayAlert(exec.AT_Recovery, "Out of memory.\nLeft: go on   Right: stop", 0)) return;
```

## DisplayBeep

Flashes a screen, to draw the eye without a requester.

**SYNOPSIS**

```zig
fn DisplayBeep(ib: *IntuitionBase, screen: ?*Screen) void
```

**SINCE**

0.14. LVO -408.

**INPUTS**

- `screen` - the screen, or null for every screen that is shown.

**RESULT**

Nothing.

**BEHAVIOR**

For a tenth of a second the display shows, in place of the screen, a
picture of one colour - the screen's background pen turned about, dark
for a light one and light for a dark one - and then the screen again.
Both changes are flips at a frame's start, so the whole display flashes
at once and nothing of the screen is drawn over. Only a screen in front
of its display flashes: one behind has nothing seen to flash. When the
display's memory has no room for the picture, only the screen's title
bar flashes.

**CONTEXT**

- Waits: for the screen list's semaphore, and a tenth of a second.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

It is for something that needs noticing and not answering.

**BUGS**

None known.

**SEE ALSO**

`DisplayAlert`

**EXAMPLES**

```zig
ib.DisplayBeep(null); // a key with nothing bound to it
```

## DisposeObject

Frees an object.

**SYNOPSIS**

```zig
fn DisposeObject(ib: *IntuitionBase, object: ?*Object) void
```

**SINCE**

0.2. LVO -52.

**INPUTS**

- `object` - the object, or null, which does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

`OM_DISPOSE` goes to the object's own class. Each class lets go of what
it had the object hold and passes it up; rootclass frees the memory.

**CONTEXT**

- Waits: whatever its classes do.
- Interrupts: no; it frees memory.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The object is gone. It must be off any list it was put on first.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`NewObjectTagList`

**EXAMPLES**

```zig
ib.DisposeObject(image);
```

## DoGadgetMethodA

Sends a gadget a method with its window's GadgetInfo.

**SYNOPSIS**

```zig
fn DoGadgetMethodA(ib: *IntuitionBase, gadget: *Object, window: ?*Window, requester: ?*Requester, message: *Msg) usize
```

**SINCE**

0.12. LVO -296.

**INPUTS**

- `gadget` - the gadget, or a model or other object that tells gadgets.
- `window` - the window the gadget is on, or null for none.
- `requester` - the requester the gadget is in, or null. A gadget knows
  which requester it is in, so this is not read.
- `message` - the method: any message whose GadgetInfo is its second
  field, or `OM_NEW`, `OM_SET`, `OM_NOTIFY` or `OM_UPDATE`, whose
  GadgetInfo is the third.

**RESULT**

What the method answers.

**BEHAVIOR**

`SendMessage`, with the message's GadgetInfo filled in first: for the
window, as the gadget is measured in it - from its requester's corner
for a requester's gadget, and in a GimmeZeroZero window by which of its
layers the gadget is on - or null without a window. That is what lets a class draw, or ask for the
window's RastPort with `ObtainGIRPort`, whatever method it is sent: a
program makes a gadget lay itself out again with `GM_LAYOUT` this way,
or sends a method of its own class that draws.

It runs under the screen list's semaphore, so the method is never sent
while intuition's input task is sending the same gadget one.

**CONTEXT**

- Waits: for the screen list's semaphore, and whatever the method
  waits for - a drawing one for the window's layer.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The message stays the caller's. The GadgetInfo written into it lasts for
the call only and is not to be kept.

**NOTES**

A new method of a class of one's own puts its GadgetInfo second, right
after the method ID, so that this call can fill it in.

**BUGS**

None known.

**SEE ALSO**

`SetGadgetAttrsTagList`, `RefreshGList`, `SendMessage`, `ObtainGIRPort`

**EXAMPLES**

```zig
var again = GpLayout{ .initial = 0 };
_ = ib.DoGadgetMethodA(gadget, window, null, @ptrCast(&again));
```

## DoubleClick

Whether two moments are close enough to be a double-click.

**SYNOPSIS**

```zig
fn DoubleClick(ib: *IntuitionBase, start_seconds: u32, start_micros: u32, current_seconds: u32, current_micros: u32) bool
```

**SINCE**

0.13. LVO -328.

**INPUTS**

- `start_seconds`, `start_micros` - the first click, as an IntuiMessage's
  `seconds` and `micros` carry it.
- `current_seconds`, `current_micros` - the second.

**RESULT**

True when the second is within the double-click time of the first.

**BEHAVIOR**

The difference is compared with the double-click time: the
preference `IPREFS_DoubleClick`, which `SetPrefs` sets and `GetPrefs`
reads, a second and a half until it is set. A second moment before
the first is not a double-click.

**CONTEXT**

- Waits: no.
- Interrupts: yes: it reads two numbers of the base.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

It is what tells a double-click of the menu button that puts up a
window's double-click requester.

**BUGS**

None known.

**SEE ALSO**

`SetPrefs`, `GetPrefs`, `SetDMRequest`,
`sdk.intuition.windows.IntuiMessage`

**EXAMPLES**

```zig
if (ib.DoubleClick(last_secs, last_micros, msg.seconds, msg.micros)) open(item);
```

## DoubleTap

Whether two presses are close enough in time and in place to be a double click - of a mouse or a finger.

**SYNOPSIS**

```zig
fn DoubleTap(ib: *IntuitionBase, first: *const intuition.Tap, second: *const intuition.Tap) bool
```

**SINCE**

0.34. LVO -520.

**INPUTS**

- `first`, `second` - each press: its time, as an IntuiMessage's
  `seconds` and `micros` carry it, and where it was, in any coordinates
  so long as both are in the same.

**RESULT**

True when the second came within the double-click time of the first
(`DoubleClick`) and within `DOUBLETAP_DISTANCE` pixels of it, across
and down.

**BEHAVIOR**

The time is `DoubleClick`'s, from the preferences. The place allows
for a finger: two taps of one land a few pixels apart, so a program
that wanted the very same pixel - or the same character of a line of
text - would never see a finger's double tap; and two presses far
apart are two clicks, however quick.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is kept.

**NOTES**

A program comparing what was pressed - the same row of a list, the
same icon - needs only `DoubleClick`; one comparing where uses this.

**BUGS**

None known.

**SEE ALSO**

`DoubleClick`

**EXAMPLES**

```zig
const now = intuition.Tap{ .seconds = msg.seconds, .micros = msg.micros, .x = msg.mouse_x, .y = msg.mouse_y };
if (ib.DoubleTap(&last, &now)) selectWord();
last = now;
```

## DrawBorder

Draws a Border and the Borders linked after it.

**SYNOPSIS**

```zig
fn DrawBorder(ib: *IntuitionBase, rp: *graphics.RastPort,
    border: ?*const Border, left: i32, top: i32) void
```

**SINCE**

0.9. LVO -212.

**INPUTS**

- `rp` - where to draw.
- `border` - the first Border, or null, which draws nothing.
- `left`, `top` - added to each Border's own `left` and `top`, which
  are added to each of its points.

**RESULT**

Nothing.

**BEHAVIOR**

Each Border in turn: its front and back pen and its draw mode are set,
and a line is drawn from its first point to its second, on to its
third, and so on through all `count` of them - both ends of every
stretch, as graphics' `Draw` draws them. The RastPort's line pattern is
the caller's and is used as it is. A Border with no points, or only
one, draws nothing.

**CONTEXT**

- Waits: no, beyond what the RastPort's layer asks of a caller - hold
  it, as for any drawing in a window.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands. The RastPort gets its pens, draw mode and
current point back as they were.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`PrintIText`, `DrawImage`, graphics' `Draw`

**EXAMPLES**

```zig
// A 40x10 box, closed on its first corner.
const corners = [_]i32{ 0, 0, 39, 0, 39, 9, 0, 9, 0, 0 };
const box = intuition.Border{
    .front_pen = graphics.penRGB(0, 0, 0),
    .count = corners.len / 2,
    .xy = &corners,
};
ib.DrawBorder(rp, &box, 10, 20);
```

## DrawImage

Draws an image.

**SYNOPSIS**

```zig
fn DrawImage(ib: *IntuitionBase, rp: *graphics.RastPort,
    image: ?*Object, left: i32, top: i32) void
```

**SINCE**

0.3. LVO -80.

**INPUTS**

- `rp` - where to draw.
- `image` - an image object, or null, which draws nothing.
- `left`, `top` - added to the image's own left and top.

**RESULT**

Nothing.

**BEHAVIOR**

`DrawImageState` in `IDS_NORMAL` with no DrawInfo: `IM_DRAW` sent to
the image's own class.

**CONTEXT**

- Waits: whatever the image's class does; imageclass does not.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands. imageclass gives the RastPort back with its pens
and draw mode as they were.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`DrawImageState`, `EraseImage`

**EXAMPLES**

```zig
ib.DrawImage(rp, arrow, 10, 20);
```

## DrawImageState

Draws an image in a state.

**SYNOPSIS**

```zig
fn DrawImageState(ib: *IntuitionBase, rp: *graphics.RastPort,
    image: ?*Object, left: i32, top: i32, state: u32,
    draw_info: ?*ic.DrawInfo) void
```

**SINCE**

0.3. LVO -84.

**INPUTS**

- `rp` - where to draw.
- `image` - an image object, or null, which draws nothing.
- `left`, `top` - added to the image's own left and top.
- `state` - `IDS_NORMAL`, `IDS_SELECTED`, `IDS_DISABLED`, ... Which
  states look different is the image's class's to say; imageclass
  draws them all the same.
- `draw_info` - a screen's pens for an image that draws in them, or
  null.

**RESULT**

Nothing.

**BEHAVIOR**

`IM_DRAW` sent to the image's own class, so a class that draws itself
is the one that answers.

**CONTEXT**

- Waits: whatever the image's class does.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

- Nothing makes a DrawInfo yet; screens will.

**BUGS**

None known.

**SEE ALSO**

`DrawImage`, `imageclass.IM_DRAW`

**EXAMPLES**

```zig
ib.DrawImageState(rp, button_face, 0, 0, imageclass.IDS_SELECTED, null);
```

## DrawPart

Draws a part of a gadget in a state, from its style.

**SYNOPSIS**

```zig
fn DrawPart(ib: *IntuitionBase, rp: ?*graphics.RastPort,
    draw_info: ?*const DrawInfo, own: ?*const Style, part: u32,
    state: u32, flags: u32, box: *const Rect, content: ?*Rect) void
```

**SINCE**

0.20. LVO -476.

**INPUTS**

- `rp` - where to draw, or null to draw nothing and only answer
  `content`.
- `draw_info` - the screen's, for its pens and its style; null for the
  default pens and the system's default style alone.
- `own` - a gadget's own style (`GA_Style`, read back), or null.
- `part` - a `style.PART_` number, or a class's own (`style.classPart`).
- `state` - `style.STATE_` bits, or a mixed state (`style.mixState`):
  the look part of the way from one state to another, every colour
  mixed channel by channel and every number rounded.
- `flags` - `style.DPF_INVERT` to turn the border the other way,
  `style.DPF_EDGES_ONLY` to draw the border and leave the inside,
  `style.DPF_CLEAR` to clear a rounded part's corners to the
  RastPort's background first.
- `box` - where the part goes, half-open.
- `content` - where to write the room left inside the border and the
  padding, or null.

**RESULT**

Nothing. `content`, when given, is `box` less the border and the
padding on each side; a box too small for them gives an empty one at
its middle rather than a negative one.

**BEHAVIOR**

Every property is found on its own, by the order the styles header
describes: the most particular state first, then the gadget's own style
before the screen's before the default, then the exact part before the
one it falls back to.

What is drawn, in order:

- **The inside** in the background - a colour, or a fill style laid
  across the inside as a gradient or a tile - inside the border, or, for
  a part with a radius, the whole rounded shape with the border drawn
  over it. Not with `DPF_EDGES_ONLY`.
- **The border**, by its kind: a flat one in the border colour; a raised
  or recessed bevel in the shine and shadow colours, `STYLE_BorderX`
  thick at the sides and `STYLE_BorderY` at the top and bottom, its
  corners meeting as `STYLE_Joins` says; a ridge or a groove as two
  bevels, one inside the other, turned opposite ways, with
  `STYLE_BorderGap` thicknesses of the inside between them. A bevel with a
  radius is drawn by `DrawRoundBevel`: its two colours meet on the
  diagonal through the top-right and bottom-left corners.

An opacity below 255 lays every colour over what is there by that much.
A part with a radius is drawn with smooth edges (`RPTAG_Smooth`), the
RastPort's own setting given back afterwards.

The RastPort's pens, draw mode and font are put back as they were.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated, and the styles are only read.

**NOTES**

- With nothing set anywhere - a screen given no style - every part looks
  as frames always have: the default style is written to be that look.
- A class measures a part with `rp` null: the content box of a part in
  a given box is what a frame around contents needs to add.

**BUGS**

- A rounded border is as thick all round as the thicker of its two
  thicknesses.

**SEE ALSO**

`GetStyleAttr`, `SA_Style`, `GA_Style`, `DrawImageState`

**EXAMPLES**

```zig
// A button's body, and the room for its label inside it.
var inside: graphics.Rect = undefined;
ib.DrawPart(rp, draw_info, own, style.PART_MAIN,
    if (pressed) style.STATE_PRESSED else style.STATE_NORMAL, 0,
    &box, &inside);
```

## EasyRequestArgs

Asks something in a requester and waits for the answer.

**SYNOPSIS**

```zig
fn EasyRequestArgs(ib: *IntuitionBase, window: ?*Window,
    easy_struct: *const EasyStruct, idcmp_ptr: ?*u32,
    args: ?*const anyopaque) i32
```

**SINCE**

0.11. LVO -248.

**INPUTS**

- `window` - the window it is about, whose screen it opens on and whose
  title it takes, or null for the default public screen.
- `easy_struct` - what it says, as `BuildEasyRequestArgs` reads it.
- `idcmp_ptr` - null, or IDCMP classes of the caller's own that answer
  it too; the one that did is written back here.
- `args` - the values for both formats, the message's first
  (`sdk.exec.fmtStream`), or null.

**RESULT**

1, 2, ... for the buttons from the left and 0 for the rightmost; -1
(`SYSREQ_IDCMP`) when one of the caller's classes arrived. 0 as well
when the requester could not be made, and a process's IoErr is then
`ERROR_NO_FREE_STORE`, which is how the two zeros are told apart.

**BEHAVIOR**

`BuildEasyRequestArgs`, then `SysReqHandler` waiting until something
answers, then `FreeSysRequest`. The requester is closed before this
returns.

**CONTEXT**

- Waits: until it is answered.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing stays behind. The EasyStruct and the values are read and not
kept.

**NOTES**

- `sdk.intuition.requesters.EasyRequest` takes the values as a tuple
  and checks both formats against them at compile time.

**BUGS**

None known.

**SEE ALSO**

`BuildEasyRequestArgs`, `SysReqHandler`, `FreeSysRequest`

**EXAMPLES**

```zig
const ask = EasyStruct{ .text_format = "Delete %s?", .gadget_format = "Delete|Cancel" };
const stream = sdk.exec.fmtStream(.{name});
if (ib.EasyRequestArgs(window, &ask, null, &stream) == 1) delete(name);
```

## EndDrag

Ends a drag `BeginDrag` started, and says which window it ended over.

**SYNOPSIS**

```zig
fn EndDrag(ib: *IntuitionBase, window: *Window, flags: u32) ?*Window
```

**SINCE**

0.34. LVO -516.

**INPUTS**

- `window` - the window that began the drag.
- `flags` - `DRAGF_FLYBACK` to fly the picture back to where the drag
  began before it goes - a drop that was not taken; 0 to take it away
  where it is.

**RESULT**

The window under the pointer, where the drop is - the frontmost there,
which may be `window` itself or another program's; null when the
pointer is over no window (the screen's own ground or title bar), or
when `window` was not dragging.

**BEHAVIOR**

With `DRAGF_FLYBACK` the picture leaves the pointer and moves back to
where it was taken hold of in a fifth of a second, easing in as it
arrives, the call returning once it has. Then it is taken off the
display. The window under the pointer is looked for on `window`'s
screen, at the pointer's place when the call is made; the point in it
is the pointer's place less the window's corner, which
`GetWindowAttrs` gives.

**CONTEXT**

- Waits: for the screen list's semaphore; with `DRAGF_FLYBACK` for the
  fifth of a second it flies.
- Interrupts: no.
- Locks: none needed; no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The window answered is not the caller's: it may close at any time, and
a program that tells it of the drop does so through its own channels
(an AppWindow's port), not by touching it.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`BeginDrag`, rtg.library's `MoveBoardOverlay`

**EXAMPLES**

```zig
const target = ib.EndDrag(window, if (taken) 0 else intuition.DRAGF_FLYBACK);
if (target == window) {} // dropped in its own window
```

## EndRefresh

Ends a redraw begun with BeginRefresh.

**SYNOPSIS**

```zig
fn EndRefresh(ib: *IntuitionBase, window: *Window, complete: bool) void
```

**SINCE**

0.5. LVO -176.

**INPUTS**

- `window` - the window.
- `complete` - true when everything is drawn again; false keeps what
  needed drawing for another BeginRefresh.

**RESULT**

Nothing.

**BEHAVIOR**

Drawing reaches the whole window again.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`BeginRefresh`

**EXAMPLES**

```zig
ib.EndRefresh(window, true);
```

## EndRequest

Takes a requester down.

**SYNOPSIS**

```zig
fn EndRequest(ib: *IntuitionBase, requester: *Requester, window: *Window) void
```

**SINCE**

0.13. LVO -308.

**INPUTS**

- `requester` - a requester up in the window.
- `window` - the window.

**RESULT**

Nothing.

**BEHAVIOR**

The requester comes out of the window's stack wherever it is in it - the
newest, or one behind it. A gadget of it that had the input is told it
has lost it; its layer goes, and what it covered comes back - a
smart-refresh window's pixels, a simple one told to draw the part again.
The window gets `IDCMP_REQCLEAR` with the requester in `iaddress`, and
`WFLG_INREQUEST` is cleared when it was the last. A requester that is
not up in this window is left alone.

**CONTEXT**

- Waits: for the screen list's semaphore and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The requester and its gadgets are the caller's to change or free once
this returns.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`Request`, `sdk.intuition.gadgetclass.GA_EndGadget`

**EXAMPLES**

```zig
ib.EndRequest(&box, window);
```

## EraseImage

Erases what an image covers.

**SYNOPSIS**

```zig
fn EraseImage(ib: *IntuitionBase, rp: *graphics.RastPort,
    image: ?*Object, left: i32, top: i32) void
```

**SINCE**

0.3. LVO -88.

**INPUTS**

- `rp` - where it was drawn.
- `image` - the image, or null, which erases nothing.
- `left`, `top` - the offset it was drawn at.

**RESULT**

Nothing.

**BEHAVIOR**

`IM_ERASE` sent to the image's own class. imageclass fills its box with
the RastPort's own background pen.

**CONTEXT**

- Waits: whatever the image's class does.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`DrawImage`

**EXAMPLES**

```zig
ib.EraseImage(rp, arrow, 10, 20);
```

## FindClass

Finds a public class by name.

**SYNOPSIS**

```zig
fn FindClass(ib: *IntuitionBase, class_id: [*:0]const u8) ?*Class
```

**SINCE**

0.2. LVO -36.

**INPUTS**

- `class_id` - the name, compared exactly.

**RESULT**

The class, or null.

**BEHAVIOR**

It looks only at the public list; a private class is never found.

**CONTEXT**

- Waits: for the class list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The class stays its owner's. It can be freed the moment the list is let
go, so an answer is only good while the caller holds `LockClassList`.

**NOTES**

- To make an object of a public class, name it to `NewObjectTagList`,
  which finds it and keeps it from going away in one step.

**BUGS**

None known.

**SEE ALSO**

`LockClassList`, `NewObjectTagList`

**EXAMPLES**

```zig
_ = ib.LockClassList();
defer ib.UnlockClassList();
const exists = ib.FindClass("imageclass") != null;
```

## FreeClass

Frees a class.

**SYNOPSIS**

```zig
fn FreeClass(ib: *IntuitionBase, cl: ?*Class) bool
```

**SINCE**

0.2. LVO -24.

**INPUTS**

- `cl` - the class, or null.

**RESULT**

True when it was freed, or `cl` was null. False while any object of it
or any class made from it still exists.

**BEHAVIOR**

It is taken off the public list whether or not it can be freed, so no
new object is made of it by name. Freed, its superclass's subclass
count comes down.

**CONTEXT**

- Waits: for the class list's semaphore.
- Interrupts: no; it frees memory.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

On true the class's memory is gone; on false the caller still has the
class, and must keep its dispatcher's code where it is.

**NOTES**

- A library that implements a class refuses to be expunged while this
  answers false: its dispatcher is still reachable.

**BUGS**

None known.

**SEE ALSO**

`MakeClass`, `RemoveClass`

**EXAMPLES**

```zig
if (!ib.FreeClass(cl)) return null; // still in use: stay loaded
```

## FreeMenus

Gives back a strip, or a panel's items, that CreateMenusA made.

**SYNOPSIS**

```zig
fn FreeMenus(ib: *IntuitionBase, menu: ?*Menu) void
```

**SINCE**

0.17. LVO -440.

**INPUTS**

- `menu` - what CreateMenusA answered, or null, which does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The separators' rule images are disposed of and the one allocation
given back. The table's words and images are not touched: they were
never copied.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The strip is gone; it must be off every window first (`ClearMenuStrip`).

**BUGS**

None known.

**SEE ALSO**

`CreateMenusA`, `ClearMenuStrip`

**EXAMPLES**

```zig
ib.ClearMenuStrip(window);
ib.FreeMenus(strip);
```

## FreeScreenBuffer

Gives back a buffer from `AllocScreenBuffer`.

**SYNOPSIS**

```zig
fn FreeScreenBuffer(ib: *IntuitionBase, screen: *Screen, buffer: ?*ScreenBuffer) void
```

**SINCE**

0.14. LVO -404.

**INPUTS**

- `screen` - the screen it was made for.
- `buffer` - the buffer, or null.

**RESULT**

Nothing.

**BEHAVIOR**

A buffer being shown is replaced by the screen's own first, so the
screen shows its bar and windows again. A buffer made with
`SB_SCREEN_BITMAP` is the screen's and stays; only its record goes.

**CONTEXT**

- Waits: for the screen list's semaphore, and for the display's next
  frame when the buffer was shown.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The buffer and its RastPort are gone.

**NOTES**

Every buffer of a screen is given back before the screen closes.

**BUGS**

None known.

**SEE ALSO**

`AllocScreenBuffer`, `ChangeScreenBuffer`

**EXAMPLES**

```zig
ib.FreeScreenBuffer(screen, back);
```

## FreeScreenDrawInfo

Hands back a DrawInfo.

**SYNOPSIS**

```zig
fn FreeScreenDrawInfo(_: *IntuitionBase, screen: *Screen,
    draw_info: ?*intuition.DrawInfo) void
```

**SINCE**

0.4. LVO -120.

**INPUTS**

- `screen` - the screen it came from.
- `draw_info` - what `GetScreenDrawInfo` answered, or null.

**RESULT**

Nothing.

**BEHAVIOR**

Nothing to free today: the DrawInfo is the screen's own. The pairing is
kept so a DrawInfo can become something built per caller without any
caller changing.

**CONTEXT**

- Waits: no. - Interrupts: no. - Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The DrawInfo may not be used after this.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`GetScreenDrawInfo`

**EXAMPLES**

```zig
ib.FreeScreenDrawInfo(screen, dri);
```

## FreeSysRequest

Closes a requester and gives back what was made for it.

**SYNOPSIS**

```zig
fn FreeSysRequest(ib: *IntuitionBase, window: ?*Window) void
```

**SINCE**

0.11. LVO -260.

**INPUTS**

- `window` - what `BuildEasyRequestArgs` answered, or null, which does
  nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The window closes - with any message still waiting at it - and its
buttons and the words and lines they were made from are freed. A
window `BuildEasyRequestArgs` did not open is left alone.

**CONTEXT**

- Waits: for the screen list's semaphore and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The window and everything read from it are gone. Every message taken
from its port must have been replied first; `SysReqHandler` replies to
what it reads.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`BuildEasyRequestArgs`, `SysReqHandler`

**EXAMPLES**

```zig
ib.FreeSysRequest(req);
```

## GadgetMouse

Answers where the pointer is, measured from a gadget's top-left corner.

**SYNOPSIS**

```zig
fn GadgetMouse(ib: *IntuitionBase, gadget: *Object, info: *GadgetInfo, point: *graphics.Point) void
```

**SINCE**

0.14. LVO -432.

**INPUTS**

- `gadget` - the gadget.
- `info` - the GadgetInfo its method was handed: which window, and the
  room the gadget is measured in.
- `point` - where the answer goes.

**RESULT**

Nothing; the position is in `point`, negative or past the gadget's size
when the pointer is outside it.

**BEHAVIOR**

The pointer as intuition last saw it, taken into the window, into the
gadget's room (the interior of a GimmeZeroZero window, a requester) and
then to the gadget's box as it is now - right- and bottom-relative ones
worked out against that room.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do; a class calls it from its dispatcher.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

The methods that get input are handed this already, as their `mouse`;
this is for one that is not, such as `GM_RENDER` following the pointer.

**BUGS**

None known.

**SEE ALSO**

gadgetclass (`GpInput`)

**EXAMPLES**

```zig
var at = graphics.Point{};
ib.GadgetMouse(o, gi, &at);
```

## GadgetStyleState

The style state to draw a gadget's part in, with its transition.

**SYNOPSIS**

```zig
fn GadgetStyleState(ib: *IntuitionBase, gadget: *Object,
    draw_info: ?*const DrawInfo, part: u32, state: u32) u32
```

**SINCE**

0.31. LVO -508.

**INPUTS**

- `gadget` - the gadget being drawn.
- `draw_info` - its screen's, for its style; null for the system's.
- `part` - the part of the style it is drawn as (`style.PART_`), whose
  transition time is the one that counts.
- `state` - the `style.STATE_` bits the gadget is in now: pressed,
  disabled, checked, and hovered and focused from its flags
  (`gadgetclass.styleStates`).

**RESULT**

The state to hand `DrawPart`, `GetStyleAttr` or a frame image's
`ImpDraw.style_state`: `state` itself, or while the gadget is changing
into it a mixed state (`style.mixState`) that is part of the way there.

**BEHAVIOR**

When `state` differs from the one the gadget was last drawn in and the
style gives the new one a time (`STYLE_Transition`), an animation on
motion.library's clock runs over that time. Each of its steps asks
intuition to draw the gadget again (`QueueGadgetRefresh`), and each
drawing asks this call again and is answered how far the change has
come. A state that changes again mid-way goes on from whichever of the
two it was nearer. With no time given - under the system's default
style every transition is 0 - on a gadget or screen that does not
move (`GA_Animate`, `SA_Animate`), or without motion.library, the
answer is `state` at once.

What intuition's own classes ask before they draw, so a class of a
program's own that draws through this fades as they do.

**CONTEXT**

- Waits: when a change starts, for motion.library's clock, to start its
  animation.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do; it is meant for a class's `GM_RENDER`.

**OWNERSHIP**

The first change the style gives a time allocates a block the gadget
keeps until it is disposed of.

**NOTES**

Ask once per drawing, for the state the gadget is drawn in as a whole:
the transition is the gadget's, one at a time.

**BUGS**

None known.

**SEE ALSO**

`DrawPart`, `GetStyleAttr`, `QueueGadgetRefresh`

**EXAMPLES**

```zig
const states = style.statesOfImage(state) | gc.styleStates(g.flags);
draw.style_state = ib.GadgetStyleState(o, info.draw_info, style.PART_MAIN, states);
```

## GetAttr

Reads one attribute of an object.

**SYNOPSIS**

```zig
fn GetAttr(ib: *IntuitionBase, attr_id: utility.Tag, object: ?*Object,
    storage: *usize) u32
```

**SINCE**

0.2. LVO -60.

**INPUTS**

- `attr_id` - the attribute's tag.
- `object` - the object. Null answers 0.
- `storage` - where the value goes: the same value `SetAttrsTagList`
  takes in a tag's data.

**RESULT**

Nonzero when its class knew the attribute; 0, with `storage` untouched,
when none did.

**BEHAVIOR**

`OM_GET` goes to the object's own class.

**CONTEXT**

- Waits: whatever its classes do.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

A pointer read back still belongs to the object.

**NOTES**

- A 32-bit attribute is written as 32 bits. Set `storage` to 0 first
  where `usize` is wider, as on the host the tests run on.

**BUGS**

None known.

**SEE ALSO**

`SetAttrsTagList`

**EXAMPLES**

```zig
var width: usize = 0;
_ = ib.GetAttr(IA_Width, image, &width);
```

## GetDefPrefs

The settings the system starts with.

**SYNOPSIS**

```zig
fn GetDefPrefs(ib: *IntuitionBase, tags: ?[*]const TagItem) u32
```

**SINCE**

1.0. LVO -468.

**INPUTS**

- `ib` - intuition.library's base.
- `tags` - the settings wanted, as `GetPrefs` takes them.

**RESULT**

How many were written.

**BEHAVIOR**

What the system is born with, whatever has been set since: a
double-click of 1500 milliseconds, a screen font 16 rows tall, the
keyboard on the screen on a board with none, every window kept wholly
on its screen, pospaz from the ROM for all three fonts, the built-in
pens. Written as `GetPrefs` writes them;
what a settings editor's "use the defaults" hands to `SetPrefs`. The
style is the default when none is set: `IPREFS_Style` with null.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The storage is the caller's; a font written is the caller's to close.

**BUGS**

None known.

**SEE ALSO**

`GetPrefs`, `SetPrefs`

**EXAMPLES**

```zig
var ms: u32 = 0;
_ = ib.GetDefPrefs(&[_]TagItem{ .{ .tag = intuition.IPREFS_DoubleClick, .data = @intFromPtr(&ms) }, .{} });
_ = ib.SetPrefs(&[_]TagItem{ .{ .tag = intuition.IPREFS_DoubleClick, .data = ms }, .{} });
```

## GetDefaultPubScreen

Names the default public screen.

**SYNOPSIS**

```zig
fn GetDefaultPubScreen(ib: *IntuitionBase, name_buffer: ?*[32]u8) ?*Screen
```

**SINCE**

0.14. LVO -376.

**INPUTS**

- `name_buffer` - where its name is written, NUL-terminated, or null.

**RESULT**

The screen `SetDefaultPubScreen` chose, or null when that is the
Workbench screen; `name_buffer` gets `WBENCHNAME` then.

**BEHAVIOR**

Only the name is safe to keep: the screen answered is not locked and
may close at any moment. It is for comparing with a screen the caller
holds, to tell whether that one is the default.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands. The name is a copy in the caller's buffer.

**NOTES**

To open a window on the default screen there is no need for its name:
`LockPubScreen(null)` does that.

**BUGS**

None known.

**SEE ALSO**

`SetDefaultPubScreen`, `LockPubScreen`

**EXAMPLES**

```zig
var name: [sc.MAXPUBSCREENNAME + 1]u8 = undefined;
const is_default = ib.GetDefaultPubScreen(&name) == my_screen;
```

## GetIMsg

Takes the next message off a window's port.

**SYNOPSIS**

```zig
fn GetIMsg(ib: *IntuitionBase, window: *Window) ?*IntuiMessage
```

**SINCE**

0.14. LVO -332.

**INPUTS**

- `window` - the window whose messages are wanted.

**RESULT**

The oldest message waiting, taken off the port, or null when there is
none or the window has no port.

**BEHAVIOR**

`GetMsg` on the window's port, handed back as the IntuiMessage it is.
A window gets a port when it is opened with an `IDCMP_` class, or given
one with `ModifyIDCMP`, and loses it with `ModifyIDCMP(window, 0)`.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed; only the window's own program changes its port,
  through `ModifyIDCMP` and `CloseWindow`.
- Process: a Task will do.

**OWNERSHIP**

The message is the program's until it hands it back with `ReplyIMsg`,
which it must do before the window closes or its port is taken away.

**NOTES**

Read what is needed and reply soon: moves and key repeats are held back
while earlier ones wait unreplied, and a verify message holds up the
screen until it is answered.

**BUGS**

None known.

**SEE ALSO**

`ReplyIMsg`, `WaitIMsg`, `ModifyIDCMP`

**EXAMPLES**

```zig
while (ib.GetIMsg(window)) |im| {
    const class = im.class;
    ib.ReplyIMsg(im);
    if (class == IDCMP_CLOSEWINDOW) done = true;
}
```

## GetPrefs

The system's settings as they are now.

**SYNOPSIS**

```zig
fn GetPrefs(ib: *IntuitionBase, tags: ?[*]const TagItem) u32
```

**SINCE**

1.0. LVO -464.

**INPUTS**

- `ib` - intuition.library's base.
- `tags` - the settings wanted, each an `IPREFS_` tag whose data is
  where its value is written: a `*u32` for `IPREFS_DoubleClick`
  (milliseconds), `IPREFS_ScreenFontHeight` (rows), `IPREFS_Keyboard`
  and `IPREFS_OffScreen`; a `*?*graphics.TextFont` for the three fonts; a
  `*[NUMDRIPENS]graphics.Pen` for `IPREFS_Pens`.

**RESULT**

How many were written.

**BEHAVIOR**

Each tag asked is written; a data of 0, a tag that is not a setting,
and `IPREFS_Style` - a style once read is intuition's own and has no
list to give back - are passed over. A font is opened for the caller,
as `OpenSystemFont` opens it.

**CONTEXT**

- Waits: for a font asked for, while another task sets the fonts.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The storage is the caller's. What is written is a copy: changing it
changes nothing until `SetPrefs`. A font written is the caller's to
close with `CloseFont`.

**BUGS**

None known.

**SEE ALSO**

`SetPrefs`, `GetDefPrefs`, `OpenSystemFont`

**EXAMPLES**

```zig
var ms: u32 = 0;
var pens: [sc.NUMDRIPENS]graphics.Pen = undefined;
_ = ib.GetPrefs(&[_]TagItem{
    .{ .tag = intuition.IPREFS_DoubleClick, .data = @intFromPtr(&ms) },
    .{ .tag = intuition.IPREFS_Pens, .data = @intFromPtr(&pens) },
    .{},
});
```

## GetScreenAttrs

Reads a screen.

**SYNOPSIS**

```zig
fn GetScreenAttrs(ib: *IntuitionBase, screen: *Screen,
    tags: ?[*]const TagItem) void
```

**SINCE**

0.4. LVO -104.

**INPUTS**

- `screen` - the screen.
- `tags` - which values, each tag's data a `*usize` the value goes to:
  `SA_Width`, `SA_Height`, `SA_Depth`, `SA_Title` (what the bar shows
  now), `SA_DefaultTitle`, `SA_Font`, `SA_PubName` (0 for a private
  screen), `SA_Type`, `SA_ShowTitle`, `SA_RastPort`, `SA_LayerInfo`,
  `SA_BarHeight`, `SA_BarVBorder`, `SA_BarHBorder`, `SA_MouseX`,
  `SA_MouseY` (the pointer in the screen's own coordinates, wherever
  on the display the screen is), `SA_WBorTop`, `SA_WBorLeft`,
  `SA_WBorRight`, `SA_WBorBottom`, `SA_Top` (how far down its display
  the screen is now), `SA_Left` (0), `SA_Draggable`, `SA_Exclusive`.
  A tag it does not know, or a null data, is passed over.

**RESULT**

Nothing; the values are where the tags point.

**BEHAVIOR**

The screen is opaque, and this is how a program learns how big it is
and where to draw.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Pointers read back are the screen's, good until it closes.

**NOTES**

- The RastPort covers the whole display under no layer: what is drawn
  through it lands beneath every window.

**BUGS**

None known.

**SEE ALSO**

`OpenScreenTagList`, `GetScreenDrawInfo`

**EXAMPLES**

```zig
var width: usize = 0;
const ask = [_]TagItem{ .{ .tag = SA_Width, .data = @intFromPtr(&width) }, .{} };
ib.GetScreenAttrs(screen, &ask);
```

## GetScreenDrawInfo

The pens and font a screen's parts are drawn in.

**SYNOPSIS**

```zig
fn GetScreenDrawInfo(_: *IntuitionBase, screen: *Screen) *sc.DrawInfo
```

**SINCE**

0.4. LVO -116.

**INPUTS**

- `screen` - the screen.

**RESULT**

The screen's DrawInfo: `pens` indexed by `DETAILPEN`...`BARTRIMPEN`,
each an ARGB pen; `font`; `depth` in bits per pixel.

**BEHAVIOR**

The screen's own, not a copy: every caller sees the same pens.

**CONTEXT**

- Waits: no. - Interrupts: no. - Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Read only, the screen's, and good until it closes. Hand it back with
`FreeScreenDrawInfo` when done.

**NOTES**

- Check `version` against `DRI_VERSION` before reading a field added
  after the first.

**BUGS**

None known.

**SEE ALSO**

`FreeScreenDrawInfo`, `DrawImageState`

**EXAMPLES**

```zig
const dri = ib.GetScreenDrawInfo(screen);
defer ib.FreeScreenDrawInfo(screen, dri);
const text = dri.pens[TEXTPEN];
```

## GetStyleAttr

One property of a part in a state, found as `DrawPart` finds it.

**SYNOPSIS**

```zig
fn GetStyleAttr(ib: *IntuitionBase, draw_info: ?*const DrawInfo,
    own: ?*const Style, part: u32, state: u32, attr: Tag) usize
```

**SINCE**

0.20. LVO -480.

**INPUTS**

- `draw_info` - the screen's, for its pens and its style; null for the
  default pens and the system's default style alone.
- `own` - a gadget's own style (`GA_Style`, read back), or null.
- `part` - a `style.PART_` number, or a class's own.
- `state` - `style.STATE_` bits, or a mixed state (`style.mixState`):
  the look part of the way from one state to another, every colour
  mixed channel by channel and every number rounded.
- `attr` - a `style.STYLE_` tag.

**RESULT**

A colour as 0xAARRGGBB, whichever of its two tags `attr` is - a pen
index in the style is looked up in the screen's pens, so the answer can
go straight into `RPTAG_APen`. `STYLE_BackgroundFill` answers a
`*const graphics.FillStyle`, the style's own copy - good until that
style is replaced (`SetStyle`) - or 0 when the background is a colour; asked for the background colour of one that is
a fill style, the colour of its first stop. Any other property as its number:
`STYLE_BorderWidth` answers `STYLE_BorderX` and `STYLE_Padding`
`STYLE_PaddingX`. 0 for a tag that is not a property.

**BEHAVIOR**

The property is found by the same order `DrawPart` uses: the most
particular state first, then the gadget's own style before the screen's
before the default, then the exact part before the one it falls back
to. A colour is answered as it is in the style; the part's opacity is
not laid on it.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

What a class asks when it draws something of its own in the style's
colours - its label, a mark - rather than having `DrawPart` draw it.

**BUGS**

None known.

**SEE ALSO**

`DrawPart`, `SA_Style`, `GA_Style`

**EXAMPLES**

```zig
// A button's label in the colour its style gives pressed text.
const ink = ib.GetStyleAttr(draw_info, own, style.PART_MAIN,
    style.STATE_PRESSED, style.STYLE_TextPen);
gb.SetRPAttrs(rp, &.{ .{ .tag = graphics.RPTAG_APen, .data = ink }, .{} });
```

## GetWindowAttrs

Reads a window.

**SYNOPSIS**

```zig
fn GetWindowAttrs(ib: *IntuitionBase, window: *Window,
    tags: ?[*]const TagItem) void
```

**SINCE**

0.5. LVO -140.

**INPUTS**

- `window` - the window.
- `tags` - which values, each tag's data a `*usize`: `WA_Left`,
  `WA_Top`, `WA_Width`, `WA_Height`, `WA_InnerWidth`, `WA_InnerHeight`,
  the limits, `WA_Title`, `WA_IDCMP`, `WA_RastPort`, `WA_UserPort`,
  `WA_Screen`, `WA_Layer`, `WA_BorderLeft`/`Top`/`Right`/`Bottom`,
  `WA_Active`, `WA_SimpleRefresh`, `WA_Backdrop`, `WA_Checkmark`,
  `WA_AmigaKey`, `WA_MenuHelp`. `WA_Left` and `WA_Top` are signed,
  written by their bits: a window past the screen's left edge
  (`IPREFS_OffScreen`) has a negative left.

**RESULT**

Nothing; the values are where the tags point.

**BEHAVIOR**

The window is opaque, and this is how a program learns where to draw:
inside the border widths of its RastPort.

**CONTEXT**

- Waits: no. - Interrupts: no. - Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Pointers read back are the window's, good until it closes.

**NOTES**

- A program drawing through the RastPort holds the layer's lock
  (layers.library's LockLayer on `WA_Layer`) while it does.

**BUGS**

None known.

**SEE ALSO**

`OpenWindowTagList`

**EXAMPLES**

```zig
var port: usize = 0;
const ask = [_]TagItem{ .{ .tag = WA_UserPort, .data = @intFromPtr(&port) }, .{} };
ib.GetWindowAttrs(window, &ask);
```

## HelpControl

Turns gadget help on or off for a window and its help group.

**SYNOPSIS**

```zig
fn HelpControl(ib: *IntuitionBase, window: *Window, flags: u32) void
```

**SINCE**

0.14. LVO -424.

**INPUTS**

- `window` - the window.
- `flags` - `HC_GADGETHELP` for on, 0 for off.

**RESULT**

Nothing.

**BEHAVIOR**

Every window of the window's help group (`WA_HelpGroup`) is changed
with it. With help on, while one of them is active, each time the
pointer comes to rest somewhere new the window under it is sent
IDCMP_GADGETHELP: the help-aware gadget there (`GA_GadgetHelp`), or the
window itself; and the active window is sent one with a null address
when the pointer is over no window of the group. Only a window whose
IDCMP asks for IDCMP_GADGETHELP hears it.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

"Rest" is the pointer having moved no more than six pixels across and
three down between two of intuition's timer events, which come ten
times a second.

**BUGS**

None known.

**SEE ALSO**

`OpenWindowTagList` (`WA_HelpGroup`), `ModifyIDCMP`

**EXAMPLES**

```zig
ib.HelpControl(window, wn.HC_GADGETHELP); // the Help key was pressed
```

## InitRequester

Clears a Requester to be filled in.

**SYNOPSIS**

```zig
fn InitRequester(ib: *IntuitionBase, requester: *Requester) void
```

**SINCE**

0.13. LVO -300.

**INPUTS**

- `requester` - the structure, the caller's.

**RESULT**

Nothing.

**BEHAVIOR**

Every field is set to its default: no gadgets, no image, no flags, the
box empty, filled in the screen's background pen, and none of the
fields intuition.library keeps in it set.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

It must not be called on a requester that is up.

**BUGS**

None known.

**SEE ALSO**

`Request`, `sdk.intuition.requesters.Requester`

**EXAMPLES**

```zig
var box: Requester = undefined;
ib.InitRequester(&box);
```

## IntuiTextLength

How wide one run of an IntuiText is, in pixels.

**SYNOPSIS**

```zig
fn IntuiTextLength(ib: *IntuitionBase, itext: ?[*]const TagItem) i32
```

**SINCE**

0.9. LVO -216.

**INPUTS**

- `itext` - the run, a tag list. Only its `IT_Text`, `IT_Font` and
  `IT_Style` are read.

**RESULT**

How far graphics' `Text` would move along drawing it, in the run's own
font and style or, when it names no font, in the system's default
font (`SYSFONT_DEFAULT`). 0 for null, no text, or when there is no
memory to measure in.

**BEHAVIOR**

The run is measured by itself: the runs linked after it are drawn
where each says, not after it, so adding them up would be a width of
nothing in particular.

**CONTEXT**

- Waits: no.
- Interrupts: no: it allocates.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands. The RastPort it measures in is its own and is
freed before it returns.

**NOTES**

- A run drawn with `PrintIText` in a RastPort whose font is not the
  default, and naming no font of its own, comes out in that font, so
  this measure is not its width. Name the font in the run to measure
  what will be drawn; `intuition.text.plainRun` makes a run of a word
  and a font to measure.

**BUGS**

None known.

**SEE ALSO**

`PrintIText`, graphics' `TextLength`

**EXAMPLES**

```zig
const word = intuition.text.plainRun("Cancel", font);
const width = ib.IntuiTextLength(&word);
```

## ItemAddress

The item a menu number names.

**SYNOPSIS**

```zig
fn ItemAddress(ib: *IntuitionBase, menu_strip: ?*Menu, menu_number: u32) ?*MenuItem
```

**SINCE**

0.12. LVO -276.

**INPUTS**

- `menu_strip` - the strip, or null.
- `menu_number` - a menu number: what IDCMP_MENUPICK carries in `code`,
  or an item's `next_select`.

**RESULT**

The subitem the number names, or the item when it names no subitem;
null when it names only a title, or none - `MENUNULL` - or one the
strip does not have.

**BEHAVIOR**

The number is taken apart with `MENUNUM`, `ITEMNUM` and `SUBNUM` and the
strip walked to that menu, item and subitem. Nothing is changed.

**CONTEXT**

- Waits: no.
- Interrupts: no: the strip is the caller's, and a task's.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The item is the strip's, which is the caller's.

**NOTES**

A program reads what was picked by following the chain:
`ItemAddress` of the message's code, then of that item's `next_select`,
until `MENUNULL`.

**BUGS**

None known.

**SEE ALSO**

`SetMenuStrip`, `sdk.intuition.menus.MENUNUM`

**EXAMPLES**

```zig
var number = message.code;
while (number != MENUNULL) {
    const item = ib.ItemAddress(&project_menu, number) orelse break;
    picked(number);
    number = item.next_select;
}
```

## LayoutMenuItemsA

Places the items of one panel, and their subitems, that CreateMenusA made from a table of items.

**SYNOPSIS**

```zig
fn LayoutMenuItemsA(ib: *IntuitionBase, first_item: *MenuItem, screen: *Screen, tags: ?[*]const TagItem) bool
```

**SINCE**

0.17. LVO -448.

**INPUTS**

- `first_item` - the first item, as CreateMenusA answered it.
- `screen` - the screen whose windows will show it.
- `tags` - `GTMN_Menu`, the title they are the panel of, which says
  where the panel starts and how wide it is at the least; and those of
  `LayoutMenusA`.

**RESULT**

True.

**BEHAVIOR**

As `LayoutMenusA` places a panel's items. Without `GTMN_Menu` the panel
is taken to start at the bar's left and may be as narrow as its items.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The items are still the caller's. Their places are written, and into
each text's runs their `IT_Left`, `IT_FrontPen` and `IT_Font`, as
`LayoutMenusA` does.

**BUGS**

None known.

**SEE ALSO**

`LayoutMenusA`, `CreateMenusA`

**EXAMPLES**

```zig
const items = ib.CreateMenusA(&more_items, null) orelse return;
const first: *intuition.MenuItem = @ptrCast(@alignCast(items));
menu.first_item = first;
_ = ib.LayoutMenuItemsA(first, screen, &.{ .{ .tag = mn.GTMN_Menu, .data = @intFromPtr(menu) }, .{} });
```

## LayoutMenusA

Places every title, item and subitem of a strip CreateMenusA made, for a screen.

**SYNOPSIS**

```zig
fn LayoutMenusA(ib: *IntuitionBase, menu: *Menu, screen: *Screen, tags: ?[*]const TagItem) bool
```

**SINCE**

0.17. LVO -444.

**INPUTS**

- `menu` - the first title of a strip from CreateMenusA.
- `screen` - the screen whose windows will show it.
- `tags` - `GTMN_Font`, the items' font, the screen's unless given;
  `GTMN_FrontPen`, their colour, the screen's `BARDETAILPEN` unless
  given; `GTMN_Checkmark` and `GTMN_AmigaKey`, a window's own images
  in place of the screen's, for their widths.

**RESULT**

True.

**BEHAVIOR**

The titles go along the bar from its left, each as wide as its words
in the screen's font and the bar's trim either side, a character apart.
Each panel's items go in a column from under the bar at its title, as
tall as a line of the font and a row (never less than nine), as wide as
the widest item's words - in from the left by the checkmark's width for
a `CHECKIT` item - and the widest shortcut, words at the right, or "»"
with the Amiga key and a character's gap; separators six rows. A panel
taller than the screen goes on in further columns, and one that would
run off the screen's right is moved left. Subitems go beside their
item, three quarters of the way across it and a row higher, higher
still to fit on the screen.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The strip is still the caller's. Its places are written, and into each
item text's runs their `IT_Left`, `IT_FrontPen` and `IT_Font`: the
runs CreateMenusA makes are writable and have all three, and a run
without one of them keeps what it says.

**NOTES**

Laid out again after a window's font or screen changes, before the
strip is set again.

**BUGS**

None known.

**SEE ALSO**

`CreateMenusA`, `LayoutMenuItemsA`, `SetMenuStrip`

**EXAMPLES**

```zig
const strip = ib.CreateMenusA(&table, null) orelse return;
_ = ib.LayoutMenusA(strip, screen, null);
_ = ib.SetMenuStrip(window, strip);
```

## LendMenus

Makes one window's menu button show another window's menus.

**SYNOPSIS**

```zig
fn LendMenus(ib: *IntuitionBase, from_window: *Window, to_window: ?*Window) void
```

**SINCE**

0.12. LVO -288.

**INPUTS**

- `from_window` - the window whose menu button is lent.
- `to_window` - the window whose menus it shows, or null for its own
  again.

**RESULT**

Nothing.

**BEHAVIOR**

While `from_window` is active, the menu button - and a right-Amiga
shortcut of `to_window`'s items - makes `to_window` active and uses its
menus on its screen, as though the pointer had been there. The picks go
to `to_window`, and `from_window` is made active again when the session
ends.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands. When `to_window` closes the loan ends by itself.

**NOTES**

It is meant for a window on a small screen of controls that belongs to
a program whose menus are in its main window.

**BUGS**

`to_window` really is made active for the length of the session, and
hears IDCMP_ACTIVEWINDOW and IDCMP_INACTIVEWINDOW about it.

**SEE ALSO**

`SetMenuStrip`, `ActivateWindow`

**EXAMPLES**

```zig
ib.LendMenus(panel_window, main_window);
```

## LockClassList

Holds the public class list.

**SYNOPSIS**

```zig
fn LockClassList(ib: *IntuitionBase) *exec.MinList
```

**SINCE**

0.2. LVO -40.

**INPUTS**

None.

**RESULT**

The list. Each node on it is a class: the dispatcher's node is the
class's first field.

**BEHAVIOR**

Nothing is added to it, taken off it or freed until `UnlockClassList`.
The same task may take it again inside; each take needs its release.

**CONTEXT**

- Waits: yes, for another task that holds it.
- Interrupts: no.
- Locks: no spinlock may be held - it may wait.
- Process: a Task will do.

**OWNERSHIP**

Read only. Nothing on it may be changed through it.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`UnlockClassList`, `FindClass`

**EXAMPLES**

```zig
const list = ib.LockClassList();
defer ib.UnlockClassList();
```

## LockIBase

Holds the screens and windows still.

**SYNOPSIS**

```zig
fn LockIBase(ib: *IntuitionBase, lock_number: u32) u32
```

**SINCE**

0.9. LVO -220.

**INPUTS**

- `lock_number` - which lock. There is one, so every number takes it;
  0 is the one to pass.

**RESULT**

What to hand to `UnlockIBase`: `lock_number`, back.

**BEHAVIOR**

Obtains the semaphore every screen and window call takes. Until
`UnlockIBase`, no screen or window opens, closes, moves, sizes or
changes places, and the active window stays the active one - which
includes everything the pointer would do, since intuition's input is
handled under the same semaphore.

**CONTEXT**

- Waits: yes, for whoever holds the screens - another program, or
  intuition's own input task.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The caller holds the lock and must give it back with `UnlockIBase`,
soon: all input waits while it is held.

**NOTES**

- The semaphore nests, so the holder may call intuition's calls that
  take it - `GetWindowAttrs`, `GetScreenAttrs` and the like - and read
  what they answer as one picture.

**BUGS**

- A caller holding a layer's lock must not take this one: intuition's
  input task takes the screens first and then a window's layer, and
  the two would wait for each other for good.

**SEE ALSO**

`UnlockIBase`, `LockPubScreen`, `LockClassList`

**EXAMPLES**

```zig
const held = ib.LockIBase(0);
ib.GetWindowAttrs(window, &tags);
ib.UnlockIBase(held);
```

## LockPubScreen

Locks a public screen, opening the default one if needed.

**SYNOPSIS**

```zig
fn LockPubScreen(ib: *IntuitionBase, name: ?[*:0]const u8) ?*Screen
```

**SINCE**

0.4. LVO -124.

**INPUTS**

- `name` - the public screen's name, in any case, or null for the
  default public screen: the one `SetDefaultPubScreen` chose, or else
  `WBENCHNAME`.

**RESULT**

The screen, locked, or null: no public screen of that name, or it is
private, or - for null - the Workbench screen could not be opened (no
display, or the display already shows another screen).

**BEHAVIOR**

The screen cannot close until each lock has its `UnlockPubScreen`. Null
opens the Workbench screen the first time, public at once; a name opens
nothing. A screen its owner has not yet opened to visitors with
`PubScreenStatus` is not found.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The screen stays its owner's. The Workbench screen opened here belongs
to nobody in particular and stays open when the last lock goes.

**NOTES**

- This is how a program finds a screen to open its window on.

**BUGS**

None known.

**SEE ALSO**

`UnlockPubScreen`, `OpenScreenTagList`

**EXAMPLES**

```zig
const screen = ib.LockPubScreen(null) orelse return;
defer ib.UnlockPubScreen(null, screen);
```

## LockPubScreenList

Holds the list of public screens, and answers it.

**SYNOPSIS**

```zig
fn LockPubScreenList(ib: *IntuitionBase) *exec.List
```

**SINCE**

0.14. LVO -360.

**INPUTS**

None.

**RESULT**

The list, whose nodes are `PubScreenNode`s, oldest first.

**BEHAVIOR**

Until `UnlockPubScreenList`, no screen opens, closes, or changes its
status or visitors. Each node names its screen, whether it is private,
and how many visitors it has.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do; while it holds the list it must not wait for
  anything that opens, closes or draws on a screen.

**OWNERSHIP**

The list stays intuition's; copy what is wanted out of it and let it go
soon.

**NOTES**

This is for a program that shows the screens and lets someone choose
one; a program that only wants to open a window uses `LockPubScreen`.

**BUGS**

None known.

**SEE ALSO**

`UnlockPubScreenList`, `NextPubScreen`, `LockPubScreen`

**EXAMPLES**

```zig
const list = ib.LockPubScreenList();
defer ib.UnlockPubScreenList();
var node = list.head;
while (node) |n| : (node = n.succ) {
    if (n.succ == null) break;
    const psn: *sc.PubScreenNode = @ptrCast(n);
    show(psn.node.name.?);
}
```

## MakeClass

Makes a class.

**SYNOPSIS**

```zig
fn MakeClass(ib: *IntuitionBase, class_id: ?[*:0]const u8,
    super_id: ?[*:0]const u8, super_class: ?*Class,
    inst_size: u32) ?*Class
```

**SINCE**

0.2. LVO -20.

**INPUTS**

- `class_id` - the name it will be found by once it is on the public
  list, or null for a private class, which is used by pointer only.
  Not copied: it must outlive the class.
- `super_id` - the public class to make it from, by name.
- `super_class` - the class to make it from, by pointer, when
  `super_id` is null; how a class is made from a private one.
- `inst_size` - how many bytes of data this class adds to an object.

**RESULT**

The class, or null: `class_id` names a public class already, `super_id`
names none, or there was no memory.

**BEHAVIOR**

The class comes back **off the public list**, with a dispatcher that
answers 0 to every message. Its owner sets `dispatcher.entry` (and
`user_data`, if the dispatcher needs anything found again), and then
calls `AddClass` if it is public - so no object can be made of it
before it can answer. Its data starts after its superclass's, rounded
up to 8. The superclass's subclass count goes up, so it cannot be freed
while this class exists.

**CONTEXT**

- Waits: for the class list's semaphore.
- Interrupts: no; it allocates.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's, until `FreeClass`.

**NOTES**

- Only rootclass has neither a `super_id` nor a `super_class`. A class
  made from nothing must allocate its own objects in `OM_NEW`.

**BUGS**

None known.

**SEE ALSO**

`AddClass`, `FreeClass`, `NewObjectTagList`

**EXAMPLES**

```zig
const cl = ib.MakeClass(null, intuition.classusr.IMAGECLASS, null, @sizeOf(MyData)) orelse return;
cl.dispatcher.entry = &myDispatch;
```

## ModifyIDCMP

Changes which messages a window gets.

**SYNOPSIS**

```zig
fn ModifyIDCMP(ib: *IntuitionBase, window: *Window, flags: u32) bool
```

**SINCE**

0.5. LVO -168.

**INPUTS**

- `window` - the window.
- `flags` - the `IDCMP_` classes to be told about from now on.

**RESULT**

True, or false when it needed a port and none could be made - the
flags are then as they were.

**BEHAVIOR**

0 takes the port away, with every message still waiting on it. From 0
to anything, the window gets a port, made for the calling task.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

A port taken away is gone, and so is any message still on it; every
message the program took off it must have been replied first.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`OpenWindowTagList` (`WA_IDCMP`)

**EXAMPLES**

```zig
if (!ib.ModifyIDCMP(window, IDCMP_REFRESHWINDOW | IDCMP_NEWSIZE)) return;
```

## MoveScreen

Moves a screen up or down its display by an amount.

**SYNOPSIS**

```zig
fn MoveScreen(ib: *IntuitionBase, screen: *Screen, dx: i32, dy: i32) void
```

**SINCE**

0.29. LVO -500.

**INPUTS**

- `screen` - the screen.
- `dx` - across: screens are as wide as their display, so it stays
  where it is.
- `dy` - down, in lines; up for less than 0.

**RESULT**

Nothing. GetScreenAttrs' `SA_Top` says where it went.

**BEHAVIOR**

The screen goes as far as it may: not above its display's top, and not
so far down that its bar leaves the glass, so it can be pulled back. The
screen behind shows above it, from its own top - and above that, the one
behind it - and the display's home where no screen reaches. Nothing is
drawn again: each screen keeps its picture, and the display shows the
new bands at its next frame. A screen opened with `{SA_Draggable,
false}` does not move, nor does an exclusive one.

**CONTEXT**

- Waits: for the screen list's semaphore, and for the display to take
  the new picture up at its next frame.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

What the pointer is over goes with the bands: a press above a screen
pulled down is a press on the screen behind it.

**BUGS**

None known.

**SEE ALSO**

`ScreenPositionTagList`, `ScreenDepth`, `GetScreenAttrs`

**EXAMPLES**

```zig
ib.MoveScreen(screen, 0, 200); // pulled down 200 lines
ib.MoveScreen(screen, 0, -200); // and back
```

## MoveWindow

Moves a window.

**SYNOPSIS**

```zig
fn MoveWindow(ib: *IntuitionBase, window: *Window, dx: i32,
    dy: i32) void
```

**SINCE**

0.5. LVO -144.

**INPUTS**

- `window` - the window.
- `dx`, `dy` - how far, right and down.

**RESULT**

Nothing.

**BEHAVIOR**

`ChangeWindowBox` at its size and a new place, kept on the screen - or,
while windows may hang past its edges (`IPREFS_OffScreen`), with
enough of it on the screen to take hold of again.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ChangeWindowBox`, `SizeWindow`

**EXAMPLES**

```zig
ib.MoveWindow(window, 10, 0);
```

## MoveWindowInFrontOf

Puts a window just in front of another.

**SYNOPSIS**

```zig
fn MoveWindowInFrontOf(ib: *IntuitionBase, window: *Window, behind: *Window) void
```

**SINCE**

0.14. LVO -344.

**INPUTS**

- `window` - the window to move.
- `behind` - the window it goes in front of.

**RESULT**

Nothing.

**BEHAVIOR**

The window goes in front of `behind` and of everything that belongs to
it - its interior and its requesters - and behind whatever was in front
of those. What that uncovers of other windows is repaired.

Nothing happens when the two are on different screens, are the same
window, or are of different kinds: a backdrop window stays behind every
other window, and an ordinary one in front of every backdrop window.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

A window asking for IDCMP_CHANGEWINDOW with `WA_NotifyDepth` is told
its depth changed.

**BUGS**

None known.

**SEE ALSO**

`WindowToFront`, `WindowToBack`

**EXAMPLES**

```zig
// The palette window stays just in front of the picture it belongs to.
ib.MoveWindowInFrontOf(palette, picture);
```

## NewObjectTagList

Makes an object.

**SYNOPSIS**

```zig
fn NewObjectTagList(ib: *IntuitionBase, cl: ?*Class,
    class_id: ?[*:0]const u8, tags: ?[*]const TagItem) ?*Object
```

**SINCE**

0.2. LVO -48.

**INPUTS**

- `cl` - the class, by pointer: how a private class is used.
- `class_id` - the public class, by name, when `cl` is null.
- `tags` - its first attributes, as its classes define them. May be
  null.

**RESULT**

The object, or null: no such class, or one of its classes would not
make it - no memory, or an attribute it will not take.

**BEHAVIOR**

`OM_NEW` is sent to the class with the class itself as the object,
since there is none yet. Each class passes it up first and then sets
up its own part: rootclass allocates the whole object, cleared, and
every class below it fills in its data from `tags`. The class is kept
from being freed while that runs.

**CONTEXT**

- Waits: for the class list's semaphore when finding by name; beyond
  that, whatever the classes do.
- Interrupts: no; it allocates.
- Locks: none needed.
- Process: a Task will do, unless a class says otherwise.

**OWNERSHIP**

The object is the caller's, until `DisposeObject`. `tags` is read
during the call and not kept.

**NOTES**

- An object's handle is not the start of its memory: a header sits in
  front of it. Free it only with `DisposeObject`.

**BUGS**

None known.

**SEE ALSO**

`DisposeObject`, `MakeClass`, `SetAttrsTagList`

**EXAMPLES**

```zig
const tags = [_]TagItem{ .{ .tag = IA_Width, .data = 16 }, .{} };
const image = ib.NewObjectTagList(null, IMAGECLASS, &tags) orelse return;
defer ib.DisposeObject(image);
```

## NextObject

Walks a list of objects.

**SYNOPSIS**

```zig
fn NextObject(_: *IntuitionBase, state: *?*exec.MinNode) ?*Object
```

**SINCE**

0.2. LVO -64.

**INPUTS**

- `state` - a node pointer the walk keeps its place in. Set it to the
  list's `head` before the first call.

**RESULT**

The next object on the list, or null at its end.

**BEHAVIOR**

The place moves on before the object is handed back, so the object may
be taken off the list (`OM_REMOVE`) and disposed of before the next
call. This is the only way to read a list objects were put on with
`OM_ADDTAIL`: the node is in the header, not at the handle.

**CONTEXT**

- Waits: no.
- Interrupts: no; the list is the caller's to guard.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The objects stay where they were.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`intuition.classusr.OM_ADDTAIL`, `intuition.classusr.OM_REMOVE`

**EXAMPLES**

```zig
var at = members.head;
while (ib.NextObject(&at)) |member| ib.DisposeObject(member);
```

## NextPubScreen

Names the public screen after a given one, going round.

**SYNOPSIS**

```zig
fn NextPubScreen(ib: *IntuitionBase, screen: ?*Screen, name_buffer: *[32]u8) ?[*:0]u8
```

**SINCE**

0.14. LVO -368.

**INPUTS**

- `screen` - the screen to go on from, or null to start at the first.
- `name_buffer` - where the name is written, NUL-terminated.

**RESULT**

`name_buffer`, or null when there is no public screen.

**BEHAVIOR**

The public screens are taken in the order they opened; after the last
comes the first again, and a screen that is not public starts at the
first. Private screens are named too.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The name is a copy in the caller's buffer.

**NOTES**

The screen named may have closed, or gone private, by the time it is
locked; `LockPubScreen` answers null then and the caller moves on.

**BUGS**

None known.

**SEE ALSO**

`LockPubScreen`, `LockPubScreenList`

**EXAMPLES**

```zig
var name: [sc.MAXPUBSCREENNAME + 1]u8 = undefined;
// A gadget that jumps the window to the next screen.
if (ib.NextPubScreen(current, &name)) |next| reopenOn(next);
```

## ObtainGIRPort

The RastPort a gadget draws into, for a moment.

**SYNOPSIS**

```zig
fn ObtainGIRPort(ib: *IntuitionBase,
    gadget_info: ?*classusr.GadgetInfo) ?*graphics.RastPort
```

**SINCE**

0.6. LVO -200.

**INPUTS**

- `gadget_info` - from the message the gadget was sent, or null.

**RESULT**

The window's RastPort, with the window's layer held; null for a null
GadgetInfo, which a gadget in no window is sent.

**BEHAVIOR**

The layer lock is what lets a gadget draw while the program draws in the
same window.
What is drawn through it stays inside the GadgetInfo's `clip`: a gadget
inside a scrolled group draws only on the part of it that shows, and
nothing at all while it is scrolled out of sight.
`EraseRect` through it paints the window's ground, as through the
window's own RastPort: its backfill hook comes with it.

**CONTEXT**

- Waits: for the window's layer.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Lent: every one obtained is given back with `ReleaseGIRPort`, soon, and
the pens and draw mode as they were.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ReleaseGIRPort`

**EXAMPLES**

```zig
if (ib.ObtainGIRPort(msg.gadget_info)) |rp| {
    defer ib.ReleaseGIRPort(rp);
    // draw
}
```

## OffGadget

Keeps a gadget from being pressed, and shows it so.

**SYNOPSIS**

```zig
fn OffGadget(ib: *IntuitionBase, gadget: *Object, window: *Window,
    requester: ?*Requester) void
```

**SINCE**

0.10. LVO -244.

**INPUTS**

- `gadget` - the gadget.
- `window` - the window it is in.
- `requester` - the requester it is in, or null for one of the window's
  own. A gadget knows which requester it is in, so this is not read.

**RESULT**

Nothing.

**BEHAVIOR**

`GA_Disabled` is set through `SetGadgetAttrsTagList`, and the gadget drawn
again - by its class, or with `RefreshGList` when the class leaves that
to the caller - ghosted: one pixel in four of its box in the window's
block pen. A press on it is swallowed: it goes neither to the gadget nor
to one behind it.

Only this gadget is drawn.

**CONTEXT**

- Waits: for the screen list's semaphore and the window's layer.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

Not while holding the window's layer lock.

**BUGS**

None known.

**SEE ALSO**

`OnGadget`, `SetGadgetAttrsTagList`

**EXAMPLES**

```zig
ib.OffGadget(save_button, window, null);
```

## OffMenu

Keeps a menu, an item or a subitem from being picked.

**SYNOPSIS**

```zig
fn OffMenu(ib: *IntuitionBase, window: *Window, menu_number: u32) void
```

**SINCE**

0.12. LVO -284.

**INPUTS**

- `window` - the window whose strip it is.
- `menu_number` - which: a number naming no item is the whole menu, one
  naming no subitem the item, and one naming a subitem that subitem.

**RESULT**

Nothing.

**BEHAVIOR**

What the number names is disabled: shown ghosted, and it cannot be picked - a disabled title's whole panel with it. A number the strip does not have, or a
window with no strip, changes nothing.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

It may be called whenever the strip is the window's. While the window's
menus are shown, the titles and the open panels are painted again at
once, so what looks pickable is what can be picked.

**BUGS**

None known.

**SEE ALSO**

`OnMenu`, `SetMenuStrip`, `sdk.intuition.menus.FULLMENUNUM`

**EXAMPLES**

```zig
ib.OffMenu(window, FULLMENUNUM(0, 2, NOSUB));
```

## OnGadget

Lets a gadget be pressed again, and shows it so.

**SYNOPSIS**

```zig
fn OnGadget(ib: *IntuitionBase, gadget: *Object, window: *Window,
    requester: ?*Requester) void
```

**SINCE**

0.10. LVO -240.

**INPUTS**

- `gadget` - the gadget.
- `window` - the window it is in.
- `requester` - the requester it is in, or null for one of the window's
  own. A gadget knows which requester it is in, so this is not read.

**RESULT**

Nothing.

**BEHAVIOR**

`GA_Disabled` is cleared through `SetGadgetAttrsTagList`, and the gadget
drawn again - by its class, or with `RefreshGList` when the class leaves
that to the caller - in its normal state again. From then on a press
reaches it.

Only this gadget is drawn.

**CONTEXT**

- Waits: for the screen list's semaphore and the window's layer.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

Not while holding the window's layer lock.

**BUGS**

None known.

**SEE ALSO**

`OffGadget`, `SetGadgetAttrsTagList`

**EXAMPLES**

```zig
ib.OnGadget(save_button, window, null);
```

## OnMenu

Lets a menu, an item or a subitem be picked again.

**SYNOPSIS**

```zig
fn OnMenu(ib: *IntuitionBase, window: *Window, menu_number: u32) void
```

**SINCE**

0.12. LVO -280.

**INPUTS**

- `window` - the window whose strip it is.
- `menu_number` - which: a number naming no item is the whole menu, one
  naming no subitem the item, and one naming a subitem that subitem.

**RESULT**

Nothing.

**BEHAVIOR**

What the number names is enabled again: its ghost goes and it can be picked. A number the strip does not have, or a
window with no strip, changes nothing.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

It may be called whenever the strip is the window's. While the window's
menus are shown, the titles and the open panels are painted again at
once, so what looks pickable is what can be picked.

**BUGS**

None known.

**SEE ALSO**

`OffMenu`, `SetMenuStrip`, `sdk.intuition.menus.FULLMENUNUM`

**EXAMPLES**

```zig
ib.OnMenu(window, FULLMENUNUM(0, 2, NOSUB));
```

## OpenScreenTagList

Opens a screen.

**SYNOPSIS**

```zig
fn OpenScreenTagList(ib: *IntuitionBase,
    tags: ?[*]const TagItem) ?*Screen
```

**SINCE**

0.4. LVO -96.

**INPUTS**

- `tags` - the `SA_` names: `SA_Title` (not copied), `SA_Font` (a
  TextFont the caller keeps open while the screen is), `SA_PubName`
  (copied; makes it public), `SA_ShowTitle` (true by default),
  `SA_Pens` (a `*const [NUMDRIPENS]Pen`, copied), and `SA_ErrorCode`, a
  `*u32` for the reason when it fails. May be null.

**RESULT**

The screen, or null: `OSERR_NOMONITOR` (no display), `OSERR_NOTAVAILABLE`
(the display's memory has no room for another screen), `OSERR_PUBNOTUNIQUE`,
`OSERR_BADNAME` (a public name too long), `OSERR_NOMEM`.

**BEHAVIOR**

It takes the display rtg shows first: the whole of it, in its own
buffer and format. The display is painted in `BACKGROUNDPEN`, and the
title bar - `BARBLOCKPEN`, the title in `BARDETAILPEN`, a `BARTRIMPEN`
line under it - is a layer at the back, so windows will cover it the
way they cover each other. Nothing else is drawn.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no; it allocates.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's until `CloseScreen`. A public one may also be locked by
others, and cannot close while it is.

**NOTES**

- A display holds as many screens as its memory has room for; the one
  in front is shown, and `ScreenToFront` and `ScreenToBack` change
  which.
- Without memory for its title bar it opens with none.

**BUGS**

None known.

**SEE ALSO**

`CloseScreen`, `GetScreenAttrs`, `LockPubScreen`

**EXAMPLES**

```zig
var why: u32 = 0;
const tags = [_]TagItem{
    .{ .tag = SA_Title, .data = @intFromPtr("My Screen") },
    .{ .tag = SA_ErrorCode, .data = @intFromPtr(&why) },
    .{},
};
const screen = ib.OpenScreenTagList(&tags) orelse return why;
```

## OpenSystemFont

One of the system's fonts, opened.

**SYNOPSIS**

```zig
fn OpenSystemFont(ib: *IntuitionBase, which: u32) ?*graphics.TextFont
```

**SINCE**

0.19. LVO -460.

**INPUTS**

- `which` - `SYSFONT_SCREEN`, `SYSFONT_DEFAULT` or `SYSFONT_FIXED`;
  anything else is `SYSFONT_DEFAULT`.

**RESULT**

The font, open, or null only when not even the ROM's can be opened.

**BEHAVIOR**

The font `SetSystemFonts` last set for `which`, or pospaz from the ROM
at the height intuition starts with when none was set - or when the one
set cannot be opened again. What screens, windows and consoles are
opened with when they name no font; a program laying out text to match
them asks for the same.

**CONTEXT**

- Waits: yes, while the fonts are being changed.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The caller holds it open: `CloseFont` it. A later `SetSystemFonts`
does not take it away.

**BUGS**

None known.

**SEE ALSO**

`SetSystemFonts`, `SA_SysFont`, `WA_SysFont`

**EXAMPLES**

```zig
const font = ib.OpenSystemFont(sdk.intuition.screens.SYSFONT_FIXED) orelse return;
defer gb.CloseFont(font);
```

## OpenWindowTagList

Opens a window.

**SYNOPSIS**

```zig
fn OpenWindowTagList(ib: *IntuitionBase,
    tags: ?[*]const TagItem) ?*Window
```

**SINCE**

0.5. LVO -132.

**INPUTS**

- `tags` - the `WA_` names. Where: `WA_Left`, `WA_Top` (or
  `WA_Position`, centred), `WA_Width`,
  `WA_Height` (or `WA_InnerWidth`/`WA_InnerHeight`), `WA_MinWidth` and
  the other limits. On what: `WA_CustomScreen`, `WA_PubScreen`,
  `WA_PubScreenName`, or by default the default public screen. How:
  `WA_Title` (not copied), `WA_CloseGadget`, `WA_DepthGadget`,
  `WA_SizeGadget`, `WA_DragBar`, `WA_Borderless`, `WA_Backdrop`,
  `WA_SimpleRefresh`/`WA_SmartRefresh`, `WA_NoCareRefresh`,
  `WA_Activate` - or `WA_NoActivate`, never active, its gadgets
  pressed beside whatever has the input - and `WA_IDCMP` for a message
  port. Its menus:
  `WA_Checkmark`, `WA_AmigaKey`, `WA_MenuHelp`, `WA_NewLookMenus`. Its
  pointer: `WA_Pointer`, `WA_BusyPointer`, `WA_HidePointer`,
  `WA_PointerDelay`, as
  `SetWindowPointerA` takes them. May be null.

**RESULT**

The window, or null: no screen to open it on (the default one could not
be opened, or a named one is not open), or no memory.

**BEHAVIOR**

It is a layer of its screen, made to fit: sized down to the screen and
moved onto it when asked for more. With `WA_Position` and no `WA_Left`
or `WA_Top` it goes in the middle of the screen, or with the pointer in
its middle, worked out from its size with the border counted. Its border is drawn - a frame, a
title bar the font's height and a little, and the images of the border
gadgets it asked for - and the part inside is the screen's background
pen. Its RastPort draws in `TEXTPEN` on `BACKGROUNDPEN` in the screen's
font. With `WA_IDCMP` it has a message port of its own, made for the
calling task. With `WA_Activate` it becomes the active window.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's until `CloseWindow`, which the same task must call: the
message port's signal is that task's.

**NOTES**

- A window on a public screen keeps it from closing, so no lock needs
  to be held for the window's life.
- The border gadgets are pictures until there is input.

**BUGS**

None known.

**SEE ALSO**

`CloseWindow`, `GetWindowAttrs`, `ModifyIDCMP`

**EXAMPLES**

```zig
const tags = [_]TagItem{
    .{ .tag = WA_Title, .data = @intFromPtr("Hello") },
    .{ .tag = WA_CloseGadget, .data = 1 },
    .{ .tag = WA_IDCMP, .data = IDCMP_REFRESHWINDOW },
    .{},
};
const window = ib.OpenWindowTagList(&tags) orelse return;
```

## PointInImage

Whether a point is inside an image.

**SYNOPSIS**

```zig
fn PointInImage(ib: *IntuitionBase, x: i32, y: i32,
    image: ?*Object) bool
```

**SINCE**

0.3. LVO -92.

**INPUTS**

- `x`, `y` - the point, in the coordinates the image's left and top are
  in.
- `image` - the image, or null, which contains every point.

**RESULT**

True when the image says the point is its own.

**BEHAVIOR**

`IM_HITTEST` sent to the image's own class. imageclass answers by its
box; a class with a shape that is not a box can answer by the shape.

**CONTEXT**

- Waits: whatever the image's class does.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

- A null image containing every point lets a gadget with no image of
  its own be hit anywhere in its box without a test of its own.

**BUGS**

None known.

**SEE ALSO**

`imageclass.IM_HITTEST`

**EXAMPLES**

```zig
if (ib.PointInImage(mouse_x, mouse_y, button_face)) press();
```

## PrintIText

Draws an IntuiText and the runs linked after it.

**SYNOPSIS**

```zig
fn PrintIText(ib: *IntuitionBase, rp: *graphics.RastPort,
    itext: ?[*]const TagItem, left: i32, top: i32) void
```

**SINCE**

0.9. LVO -208.

**INPUTS**

- `rp` - where to draw.
- `itext` - the first run, a tag list: `IT_Text`, the words;
  `IT_FrontPen`, `IT_BackPen` and `IT_DrawMode`, how they are drawn;
  `IT_Left` and `IT_Top`, where; `IT_Font` and `IT_Style`, in what;
  `IT_Next`, the next run. Null draws nothing.
- `left`, `top` - added to each run's own `IT_Left` and `IT_Top`.

**RESULT**

Nothing.

**BEHAVIOR**

Each run in turn starts from the RastPort as it was given and takes
what it names: its pens, its draw mode, its font, its style. What it
does not name is the RastPort's own, so a run without `IT_FrontPen` is
drawn in the caller's pen and one without `IT_Font` in the RastPort's
font; nothing one run names carries over to the next. The text's top
is at (`left` + `IT_Left`, `top` + `IT_Top`), so a run's place is its
top left corner, whatever its font's baseline. A run with no text, or
an empty one, is passed over and the runs after it are drawn.

**CONTEXT**

- Waits: no, beyond what the RastPort's layer asks of a caller - hold
  it, as for any drawing in a window.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands. The RastPort gets its pens, draw mode, font and
style back as they were; its current point is left at the end of the
last run drawn, as `Text` leaves it.

**NOTES**

- itexticlass draws its `IA_Data` with the same loop, in the image's
  one pen instead of each run's.

**BUGS**

None known.

**SEE ALSO**

`IntuiTextLength`, `DrawBorder`, `DrawImage`, graphics' `Text`

**EXAMPLES**

```zig
const label = [_]TagItem{
    .{ .tag = intuition.IT_Text, .data = @intFromPtr("Name:") },
    .{ .tag = intuition.IT_FrontPen, .data = graphics.penRGB(0, 0, 0) },
    .{ .tag = intuition.IT_Style, .data = graphics.FSF_BOLD },
    .{},
};
ib.PrintIText(rp, &label, 10, 20);
```

## PubScreenStatus

Opens a public screen to visitors, or closes it to them.

**SYNOPSIS**

```zig
fn PubScreenStatus(ib: *IntuitionBase, screen: *Screen, flags: u32) u32
```

**SINCE**

0.14. LVO -384.

**INPUTS**

- `screen` - a public screen the caller opened.
- `flags` - `PSNF_PRIVATE` to close it to visitors, 0 to open it.

**RESULT**

1 when it is done; 0 when the screen is not public, or cannot go
private because it still has visitors.

**BEHAVIOR**

A public screen opens private: nobody finds it until its owner has
set it up and calls this with 0. Going private, it also stops being
the default public screen.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

An owner that wants to close its screen makes it private first, so no
new visitor comes while it waits for the last to go.

**BUGS**

None known.

**SEE ALSO**

`OpenScreenTagList` (`SA_PubName`, `SA_PubSig`), `LockPubScreen`

**EXAMPLES**

```zig
const screen = ib.OpenScreenTagList(&tags) orelse return;
// Set up, now visitors are welcome.
_ = ib.PubScreenStatus(screen, 0);
```

## QueueGadgetRefresh

A gadget drawn again by intuition soon, with whatever it holds then.

**SYNOPSIS**

```zig
fn QueueGadgetRefresh(ib: *IntuitionBase, gadget: *Object) void
```

**SINCE**

0.24. LVO -492.

**INPUTS**

- `gadget` - any gadget, in a window, a requester or a group, or in
  none.

**RESULT**

Nothing.

**BEHAVIOR**

The gadget is marked and intuition's input task woken; that task,
which draws gadgets as they are pressed, draws every marked one again
(`GM_RENDER`, `GREDRAW_UPDATE`) with what it holds at that moment.
Asked several times before it gets round to it, it is drawn once, in
its newest state. A gadget that is in no window by then is not drawn,
and taken out of its window it is not drawn either.

It never waits: it neither takes intuition's lock nor locks a layer.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: takes intuition's mark lock, a spinlock, for a moment.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

What a class's animation calls at each step, on motion.library's task:
the step stores the gadget's new value - with `SetAttrsTagList`, no
GadgetInfo, so nothing is drawn there - and asks for the drawing here.
Drawing on the clock's own task would have it wait for a window whose
task may be waiting for the clock.

**BUGS**

- Without input.device - the host tests - there is no task to draw it,
  and nothing is drawn.

**SEE ALSO**

`RefreshGList`, `GA_Animate`, motion.library `CreateAnimationTagList`

**EXAMPLES**

```zig
fn step(hook: *Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const msg: *const motion.AnimationMsg = @ptrCast(@alignCast(message.?));
    const gauge: *Object = @ptrCast(hook.data.?);
    _ = ib.SetAttrsTagList(gauge, &[_]TagItem{
        .{ .tag = FUELGAUGE_Level, .data = @intCast(msg.value) },
        .{},
    });
    ib.QueueGadgetRefresh(gauge);
    return 0;
}
```

## RefreshGList

Draws gadgets of a window.

**SYNOPSIS**

```zig
fn RefreshGList(ib: *IntuitionBase, gadget: *Object, window: *Window,
    count: i32) void
```

**SINCE**

0.6. LVO -192.

**INPUTS**

- `gadget` - the first to draw, in the window's list.
- `window` - the window.
- `count` - how many from it on; -1 for the rest of the list.

**RESULT**

Nothing.

**BEHAVIOR**

Each is sent `GM_RENDER` with `GREDRAW_REDRAW` and the window's
RastPort, its layer held.

**CONTEXT**

- Waits: for the screen list's semaphore and the window's layer.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

A window draws its gadgets itself when it opens, when a simple window is
uncovered and when it is sized; this is for the program's own changes.

**BUGS**

None known.

**SEE ALSO**

`AddGList`

**EXAMPLES**

```zig
ib.RefreshGList(first, window, -1);
```

## RefreshWindowFrame

Draws a window's border again.

**SYNOPSIS**

```zig
fn RefreshWindowFrame(ib: *IntuitionBase, window: *Window) void
```

**SINCE**

0.5. LVO -180.

**INPUTS**

- `window` - the window.

**RESULT**

Nothing.

**BEHAVIOR**

The frame, the title bar and the gadget images, in the colours of
whether it is active - after a program has drawn over them.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`OpenWindowTagList`

**EXAMPLES**

```zig
ib.RefreshWindowFrame(window);
```

## ReleaseGIRPort

Gives back a RastPort from `ObtainGIRPort`.

**SYNOPSIS**

```zig
fn ReleaseGIRPort(ib: *IntuitionBase, rp: ?*graphics.RastPort) void
```

**SINCE**

0.6. LVO -204.

**INPUTS**

- `rp` - what ObtainGIRPort answered; null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The layer of the window whose RastPort it is is let go.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The RastPort is the window's again.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ObtainGIRPort`

**EXAMPLES**

See `ObtainGIRPort`.

## RemoveClass

Takes a class off the public list.

**SYNOPSIS**

```zig
fn RemoveClass(ib: *IntuitionBase, cl: *Class) void
```

**SINCE**

0.2. LVO -32.

**INPUTS**

- `cl` - the class. One not on the list is left alone.

**RESULT**

Nothing.

**BEHAVIOR**

Objects of it that exist are untouched and keep working; it simply can
no longer be found by name.

**CONTEXT**

- Waits: for the class list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's, as before.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`AddClass`, `FreeClass`

**EXAMPLES**

```zig
ib.RemoveClass(cl);
```

## RemoveGList

Takes gadgets out of a window.

**SYNOPSIS**

```zig
fn RemoveGList(ib: *IntuitionBase, window: *Window, gadget: *Object,
    count: i32) i32
```

**SINCE**

0.6. LVO -188.

**INPUTS**

- `window` - the window.
- `gadget` - the first of them.
- `count` - how many from it on; -1 for the rest of the list.

**RESULT**

The position the first one had, or -1 if it was not the window's.

**BEHAVIOR**

A gadget that has the input is told it has lost it (`GM_GOINACTIVE`,
`abort` 1) first. The gadgets taken out are linked to one another as
they were, and the last one to nothing. What they drew stays in the
window until the program draws over it.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The gadgets are wholly the program's again.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`AddGList`

**EXAMPLES**

```zig
_ = ib.RemoveGList(window, ok_button, 1);
ib.DisposeObject(ok_button);
```

## ReplyIMsg

Hands a message from `GetIMsg` back.

**SYNOPSIS**

```zig
fn ReplyIMsg(ib: *IntuitionBase, msg: *IntuiMessage) void
```

**SINCE**

0.14. LVO -336.

**INPUTS**

- `msg` - a message `GetIMsg` answered, not yet handed back.

**RESULT**

Nothing.

**BEHAVIOR**

`ReplyMsg` on the message. Intuition takes it back: a verify message
lets the screen go on, and a held-back move or key repeat can be sent
again.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The message is Intuition's again; it must not be read after this.

**NOTES**

Copy what is needed out of the message before replying.

**BUGS**

None known.

**SEE ALSO**

`GetIMsg`, `WaitIMsg`

**EXAMPLES**

```zig
const code = im.code;
ib.ReplyIMsg(im);
```

## ReportMouse

Turns the reports of the pointer's moves to a window on or off.

**SYNOPSIS**

```zig
fn ReportMouse(ib: *IntuitionBase, window: *Window, on: bool) void
```

**SINCE**

0.14. LVO -356.

**INPUTS**

- `window` - the window.
- `on` - true to be told of the pointer's moves with no button held
  while the window is active, false not to be.

**RESULT**

Nothing.

**BEHAVIOR**

It is what `WA_ReportMouse` sets when the window opens. The moves come
as IDCMP_MOUSEMOVE messages, so the window's IDCMP must ask for them
too; how many may wait is `SetMouseQueue`'s.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

A program that follows the pointer only in some mode - a tool that
shows where it would draw - turns the reports on for that mode, and is
not woken by every move otherwise.

**BUGS**

None known.

**SEE ALSO**

`SetMouseQueue`, `ModifyIDCMP`, `OpenWindowTagList` (`WA_ReportMouse`)

**EXAMPLES**

```zig
ib.ReportMouse(window, true); // the button went down: follow the drag
```

## Request

Puts a requester up in a window.

**SYNOPSIS**

```zig
fn Request(ib: *IntuitionBase, requester: *Requester, window: *Window) bool
```

**SINCE**

0.13. LVO -304.

**INPUTS**

- `requester` - what it is: its box, gadgets, image and flags.
- `window` - the window it goes up in.

**RESULT**

True when it is up; false when there was no memory for its layer, or
it is already up.

**BEHAVIOR**

The requester becomes a layer in front of the window and of every
requester already up in it, cut at the window's inner edges. With
`POINTREL` it is put at the middle of the window, moved by `rel_left`
and `rel_top`, and kept inside it; otherwise at `left` and `top`. Its
face is drawn: the box filled with `back_fill` unless `NOREQBACKFILL`,
its image over that, then its gadgets. The window gets `IDCMP_REQSET`
with the requester in `iaddress`, and `WFLG_INREQUEST` is set.

From then on a press on the window reaches only this requester's
gadgets. Its drag bar, depth, zoom and size gadgets still work; its
close gadget, its own gadgets, its menus and its keys do not - the keys
reach a gadget of the requester that has the input, and with
`NOISYREQ` whatever the requester does not use still reaches the window
as `IDCMP_MOUSEBUTTONS`, `IDCMP_RAWKEY` and the rest. The requester moves
with the window and stays in front of it.

**CONTEXT**

- Waits: for the screen list's semaphore and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The requester, its gadgets and its image stay the caller's and must
stay where they are, unchanged, until `EndRequest` or an end gadget
takes it down. A gadget of it must not be on any other list meanwhile.

**NOTES**

A gadget with `GA_EndGadget` takes the requester down when it is used,
after the window has had its `IDCMP_GADGETUP`; the window hears
`IDCMP_REQCLEAR` then as for `EndRequest`.

**BUGS**

None known.

**SEE ALSO**

`EndRequest`, `InitRequester`, `SetDMRequest`,
`sdk.intuition.requesters.Requester`

**EXAMPLES**

```zig
ib.InitRequester(&box);
box.width = 200;
box.height = 60;
box.flags = POINTREL;
box.gadgets = ok_button;
if (!ib.Request(&box, window)) return error.NoMemory;
```

## ResetMenuStrip

Gives a window back a strip it already had.

**SYNOPSIS**

```zig
fn ResetMenuStrip(ib: *IntuitionBase, window: *Window, menu_strip: *Menu) bool
```

**SINCE**

0.12. LVO -272.

**INPUTS**

- `window` - the window.
- `menu_strip` - a strip `SetMenuStrip` has laid out, for this window or
  another on a screen with the same font.

**RESULT**

Always true.

**BEHAVIOR**

As `SetMenuStrip`, without laying the panels out again: the strip keeps
the `jazz_x`..`beat_y` it has. It is the quick way back after
`ClearMenuStrip` when all that changed in the meantime is which items
are checked or enabled.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

As for `SetMenuStrip`: the strip stays the caller's until
`ClearMenuStrip`.

**NOTES**

None.

**BUGS**

A strip changed in any other way - an item added, a text made longer -
keeps panels of the old size. Use `SetMenuStrip` for that.

**SEE ALSO**

`SetMenuStrip`, `ClearMenuStrip`

**EXAMPLES**

```zig
ib.ClearMenuStrip(window);
save_item.flags &= ~ITEMENABLED;
_ = ib.ResetMenuStrip(window, &project_menu);
```

## ScreenDepth

Moves a screen to the front of its display or to the back.

**SYNOPSIS**

```zig
fn ScreenDepth(ib: *IntuitionBase, screen: *Screen, flags: u32) void
```

**SINCE**

0.14. LVO -388.

**INPUTS**

- `screen` - the screen.
- `flags` - `SDEPTH_TOFRONT` or `SDEPTH_TOBACK`.

**RESULT**

Nothing.

**BEHAVIOR**

`ScreenToFront` or `ScreenToBack`, chosen by a value - for a gadget or
a key that flips between the two.

**CONTEXT**

- Waits: for the screen list's semaphore, and for the display to take
  the new picture up at the next frame.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ScreenToFront`, `ScreenToBack`

**EXAMPLES**

```zig
ib.ScreenDepth(screen, sc.SDEPTH_TOBACK);
```

## ScreenPositionTagList

Puts a screen at a place on its display, or moves it by an amount.

**SYNOPSIS**

```zig
fn ScreenPositionTagList(ib: *IntuitionBase, screen: *Screen, tags: ?[*]const utility.TagItem) void
```

**SINCE**

0.29. LVO -504.

**INPUTS**

- `screen` - the screen.
- `tags`:
  - `SPOS_Top` (i32) - the display line its top edge goes to, or with
    `SPOS_Relative` how far down it moves (up for less than 0); left
    where it is without the tag.
  - `SPOS_Left` (i32) - the same across; screens are as wide as their
    display, so it stays at 0.
  - `SPOS_Relative` (bool) - the two are a move, not a place (false).
  - `SPOS_ForceDrag` (bool) - move a screen opened with
    `{SA_Draggable, false}` as well (false).

**RESULT**

Nothing. GetScreenAttrs' `SA_Top` says where it went.

**BEHAVIOR**

As `MoveScreen`: the screen goes as far as it may - not above the top,
its bar kept on the glass - and the screens behind show above it. A
screen that may not be dragged moves only with `SPOS_ForceDrag`; an
exclusive one stays at the top.

**CONTEXT**

- Waits: for the screen list's semaphore, and for the display to take
  the new picture up at its next frame.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands. The tags are read, not kept.

**NOTES**

Only the screen's owner should set `SPOS_ForceDrag`: a screen that may
not be dragged is that way for a reason of its own.

**BUGS**

None known.

**SEE ALSO**

`MoveScreen`, `ScreenDepth`, `GetScreenAttrs`

**EXAMPLES**

```zig
// Half way down the display.
ib.ScreenPositionTagList(screen, &[_]utility.TagItem{
    .{ .tag = sc.SPOS_Top, .data = 300 },
    .{},
});
```

## ScreenToBack

Puts a screen behind the others on its display.

**SYNOPSIS**

```zig
fn ScreenToBack(ib: *IntuitionBase, screen: *Screen) void
```

**SINCE**

0.4. LVO -112.

**INPUTS**

- `screen` - the screen.

**RESULT**

Nothing.

**BEHAVIOR**

It goes behind every other screen of its display, and the display shows
the one that is now in front from the start of the next frame. Nothing
is copied, and nothing of it is lost: it is shown as it was when it is
brought forward again.

**CONTEXT**

- Waits: for the screen list's semaphore, and for the display to take
  the new picture up at the next frame.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

The pointer and the menu button reach the screen in front.

**BUGS**

None known.

**SEE ALSO**

`ScreenToFront`, `ScreenDepth`, `OpenScreenTagList` (`SA_Behind`)

**EXAMPLES**

```zig
ib.ScreenToBack(screen);
```

## ScreenToFront

Brings a screen to the front of its display.

**SYNOPSIS**

```zig
fn ScreenToFront(ib: *IntuitionBase, screen: *Screen) void
```

**SINCE**

0.4. LVO -108.

**INPUTS**

- `screen` - the screen.

**RESULT**

Nothing.

**BEHAVIOR**

It goes in front of every other screen of its display, and the display
shows it from the start of the next frame: its buffer is shown in place
of the one that was, whole, and nothing is copied. Its windows keep
whatever they had; the active window stays the one it was.

**CONTEXT**

- Waits: for the screen list's semaphore, and for the display to take
  the new picture up at the next frame.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

The pointer and the menu button reach the screen in front.

**BUGS**

None known.

**SEE ALSO**

`ScreenToBack`, `ScreenDepth`, `OpenScreenTagList` (`SA_Behind`)

**EXAMPLES**

```zig
ib.ScreenToFront(screen);
```

## ScrollWindowRaster

Moves part of what a window shows, and clears what it leaves.

**SYNOPSIS**

```zig
fn ScrollWindowRaster(ib: *IntuitionBase, window: *Window, dx: i32, dy: i32, area: *const Rect) bool
```

**SINCE**

0.14. LVO -348.

**INPUTS**

- `window` - the window.
- `dx`, `dy` - how far the contents move left and up; negative moves
  them right and down.
- `area` - what moves, half-open, in the coordinates the program draws
  in: `WA_RastPort`'s, which for a GimmeZeroZero window start inside
  the border.

**RESULT**

True when the contents moved: only the strip they left is cleared, and
only that needs drawing. False when they could not be moved - part of
what was to be read is covered and kept nowhere, or the area is in too
many pieces - and then the whole area is cleared and wants drawing.

**BEHAVIOR**

`ScrollRaster` on the window's RastPort, then what is to be drawn again
is cleared the way the window paints its ground, its backfill hook or
the background pen.

**CONTEXT**

- Waits: for the window's layer.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

A scroll by the area's whole width or height or more moves nothing and
clears all of it, and answers true.

**BUGS**

None known.

**SEE ALSO**

`ScrollRaster`, `EraseRect`

**EXAMPLES**

```zig
// One line of text up; the line it leaves at the bottom is drawn.
if (ib.ScrollWindowRaster(window, 0, line_height, &text_area)) drawLastLine() else drawAll();
```

## SendMessage

Sends a message to an object.

**SYNOPSIS**

```zig
fn SendMessage(ib: *IntuitionBase, object: ?*Object, msg: *Msg) usize
```

**SINCE**

0.2. LVO -68.

**INPUTS**

- `object` - the object, or null, which answers 0.
- `msg` - the message: a method ID, then that method's fields.

**RESULT**

Whatever the object's class answers, as the method defines it.

**BEHAVIOR**

The message goes to the dispatcher of the class the object was made
of, which passes on to its superclass what it does not handle.

**CONTEXT**

- Waits: whatever the class does.
- Interrupts: no, unless a class says a method is safe there.
- Locks: none needed.
- Process: a Task will do, unless a class says otherwise.

**OWNERSHIP**

The message is the caller's; a class does not keep it.

**NOTES**

- This is how any method is invoked: `NewObjectTagList`,
  `DisposeObject`, `SetAttrsTagList` and `GetAttr` are this with their
  message made for the caller.

**BUGS**

None known.

**SEE ALSO**

`SendSuperMessage`, `CoerceMessage`

**EXAMPLES**

```zig
var draw = imageclass.ImpDraw{ .method_id = IM_DRAW, .rast_port = rp };
_ = ib.SendMessage(image, @ptrCast(&draw));
```

## SendSuperMessage

Sends a message on to a class's superclass.

**SYNOPSIS**

```zig
fn SendSuperMessage(ib: *IntuitionBase, cl: *Class, object: ?*Object,
    msg: *Msg) usize
```

**SINCE**

0.2. LVO -72.

**INPUTS**

- `cl` - the class whose dispatcher is running: the one passed to it.
- `object` - the object, as the dispatcher was given it.
- `msg` - the message.

**RESULT**

What the superclass answers; 0 when `cl` has none.

**BEHAVIOR**

The superclass handles it as if the object were one of its own. This is
how a dispatcher passes on a message it does not handle, and how it
lets the classes above it do their part first.

**CONTEXT**

- Waits: whatever the superclass does.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The message is the caller's.

**NOTES**

- Pass the class the dispatcher was given, never the object's own:
  that would send the message back down to where it started.

**BUGS**

None known.

**SEE ALSO**

`SendMessage`, `CoerceMessage`

**EXAMPLES**

```zig
else => return ib.SendSuperMessage(cl, object, msg),
```

## SetAttrsTagList

Changes an object's attributes.

**SYNOPSIS**

```zig
fn SetAttrsTagList(ib: *IntuitionBase, object: ?*Object,
    tags: ?[*]const TagItem) u32
```

**SINCE**

0.2. LVO -56.

**INPUTS**

- `object` - the object. Null does nothing and answers 0.
- `tags` - the attributes to change. One its classes do not know is
  passed over.

**RESULT**

Nonzero when something that shows changed and the object wants
drawing again, as its class decides.

**BEHAVIOR**

`OM_SET` goes to the object's own class.

**CONTEXT**

- Waits: whatever its classes do.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

`tags` is read during the call. What a tag points at may be kept - each
class says, as imageclass does for `IA_Data`.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`GetAttr`

**EXAMPLES**

```zig
const move = [_]TagItem{ .{ .tag = IA_Left, .data = 10 }, .{} };
_ = ib.SetAttrsTagList(image, &move);
```

## SetDMRequest

The requester a double-click of the menu button puts up.

**SYNOPSIS**

```zig
fn SetDMRequest(ib: *IntuitionBase, window: *Window, requester: *Requester) bool
```

**SINCE**

0.13. LVO -312.

**INPUTS**

- `window` - the window.
- `requester` - what a double-click of the menu button puts up.

**RESULT**

True; false, and nothing changed, while the double-click requester the
window has is up.

**BEHAVIOR**

The requester becomes the window's double-click requester, in place of
any it had. While the window is active and has no requester up, the
menu button pressed twice within the double-click time, the pointer
hardly moved, puts it up: the menu bar shows after the first press, the
window is sent `IDCMP_REQVERIFY` and its reply waited for, and then the
requester goes up as `Request` puts one - with `POINTREL` under the
pointer, moved by `rel_left` and `rel_top`. A first press held past
the double-click time, or moved away, is the menus as usual.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The requester stays the caller's, and must stay where it is until it is
cleared again - which must happen before the window closes.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ClearDMRequest`, `Request`, `sdk.intuition.windows.IDCMP_REQVERIFY`

**EXAMPLES**

```zig
_ = ib.SetDMRequest(window, &quick);
```

## SetDefaultPubScreen

Chooses the public screen windows open on by default.

**SYNOPSIS**

```zig
fn SetDefaultPubScreen(ib: *IntuitionBase, name: ?[*:0]const u8) void
```

**SINCE**

0.14. LVO -372.

**INPUTS**

- `name` - the public screen's name, in any case, or null for the
  Workbench screen.

**RESULT**

Nothing.

**BEHAVIOR**

From now on `LockPubScreen(null)`, and a window given no screen or
falling back from a name that is not there, get that screen. A name
that is not a public screen open to visitors changes nothing. It stops
being the default when it closes or goes private.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands; the screen is not locked by being the default.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`GetDefaultPubScreen`, `LockPubScreen`, `PubScreenStatus`

**EXAMPLES**

```zig
ib.SetDefaultPubScreen("PAINT");
```

## SetEditHook

Puts the global edit hook every string gadget's keys go through first.

**SYNOPSIS**

```zig
fn SetEditHook(ib: *IntuitionBase, hook: ?*Hook) *Hook
```

**SINCE**

0.14. LVO -428.

**INPUTS**

- `hook` - the new global hook, or null for intuition's own editing
  again.

**RESULT**

The hook it replaces - intuition's own the first time.

**BEHAVIOR**

For every key typed into a strgclass gadget, the global hook is called
with the `SGWork` and `SGH_KEY` (`sghooks.zig`) before the gadget's own
hook. It *is* the editing: a hook that calls none other decides alone
what every key does. A hook that means to add to intuition's editing
rather than replace it calls the hook this answered for the keys it
leaves alone, with the same object and message, through
`CallHookPkt`.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do. The hook is called on intuition's input
  task: it must not wait, nor draw.

**OWNERSHIP**

The hook stays the caller's, and must stay where it is until it is
replaced again.

**NOTES**

It changes every string gadget of every program. For one gadget, give
that gadget `STRINGA_EditHook` instead.

**BUGS**

None known.

**SEE ALSO**

strgclass (`STRINGA_EditHook`), utility.library's `CallHookPkt`

**EXAMPLES**

```zig
var upper = utility.Hook{ .entry = &upperCase };
previous = ib.SetEditHook(&upper); // upperCase calls `previous` for the rest
```

## SetGadgetAttrsTagList

Changes a gadget's attributes, and lets it show the change.

**SYNOPSIS**

```zig
fn SetGadgetAttrsTagList(ib: *IntuitionBase, gadget: *Object,
    window: ?*Window, tags: ?[*]const TagItem) usize
```

**SINCE**

0.6. LVO -196.

**INPUTS**

- `gadget` - the gadget.
- `window` - the window it is in, or null for one in no window.
- `tags` - the attributes.

**RESULT**

What `OM_SET` answered: nonzero when something that shows changed and
the class left drawing it to the caller.

**BEHAVIOR**

`OM_SET` with a GadgetInfo for the window, which is what lets a class
draw itself again. `SetAttrsTagList` on a gadget in a window changes it
without it showing.

**CONTEXT**

- Waits: for the screen list's semaphore and the window's layer.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The tags are read and not kept, except what an attribute says is kept -
`GA_Text` is.

**NOTES**

Not while holding the window's layer lock.

**BUGS**

None known.

**SEE ALSO**

`SetAttrsTagList`

**EXAMPLES**

```zig
const off = [_]TagItem{ .{ .tag = gc.GA_Disabled, .data = 1 }, .{} };
_ = ib.SetGadgetAttrsTagList(button, window, &off);
```

## SetMenuStrip

Gives a window its menus.

**SYNOPSIS**

```zig
fn SetMenuStrip(ib: *IntuitionBase, window: *Window, menu_strip: *Menu) bool
```

**SINCE**

0.12. LVO -264.

**INPUTS**

- `window` - the window.
- `menu_strip` - the first `Menu` of the strip, the others linked through
  `next_menu`, each with its items.

**RESULT**

Always true.

**BEHAVIOR**

Each menu's panel is laid out from its items - the smallest rectangle
that holds every item's box and what its text or image, its checkmark
and its shortcut take up, with a trim, and at least as wide as the
title - into the menu's `jazz_x`..`beat_y`, and the strip becomes the
window's. From then on the menu button over the window, while it is
active and does not trap the button, shows it, and a right-Amiga key
with an item's `command` picks that item.

A strip the window already had is simply replaced. When the window's
menus are being shown, that session ends first and the window is sent
IDCMP_MENUPICK `MENUNULL`.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The strip stays the caller's, and must stay where it is, unchanged but
for its checkmarks and enabling, until `ClearMenuStrip` takes it off
again - which must happen before the window closes.

**NOTES**

It is the call to make in reply to IDCMP_MENUVERIFY `MENUHOT`, when a
program wants to change its menus just before they are shown: the
session waiting for the reply shows the new strip.

**BUGS**

None known.

**SEE ALSO**

`ClearMenuStrip`, `ResetMenuStrip`, `ItemAddress`, `sdk.intuition.menus`

**EXAMPLES**

```zig
_ = ib.SetMenuStrip(window, &project_menu);
defer ib.ClearMenuStrip(window);
```

## SetMouseQueue

Sets how many pointer moves a window may have waiting.

**SYNOPSIS**

```zig
fn SetMouseQueue(ib: *IntuitionBase, window: *Window, length: u32) u32
```

**SINCE**

0.14. LVO -352.

**INPUTS**

- `window` - the window.
- `length` - how many IDCMP_MOUSEMOVE messages may be out unreplied; 0
  is taken as 1.

**RESULT**

The length it had before.

**BEHAVIOR**

Beyond that many, further moves are not sent until the program replies:
the next one says where the pointer is anyway. Moves already waiting
stay. It is what `WA_MouseQueue` sets when the window opens.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

A drawing program that wants every point of a stroke asks for more; a
program that only wants to know where the pointer is now needs one.

**BUGS**

None known.

**SEE ALSO**

`ReportMouse`, `OpenWindowTagList` (`WA_MouseQueue`)

**EXAMPLES**

```zig
_ = ib.SetMouseQueue(window, 16);
```

## SetPrefs

The system's settings changed.

**SYNOPSIS**

```zig
fn SetPrefs(ib: *IntuitionBase, tags: ?[*]const TagItem) bool
```

**SINCE**

1.0. LVO -472.

**INPUTS**

- `ib` - intuition.library's base.
- `tags` - the settings to change, each an `IPREFS_` tag with its
  value as the data. Null changes nothing.

**RESULT**

True when every setting given was taken; false when one was not - a
value that means nothing, a fixed font that is proportional, no memory
for a style - and then that one keeps its value and the rest are
taken all the same.

**BEHAVIOR**

Each setting takes effect at once and a setting left out keeps its
value:

- `IPREFS_DoubleClick`, milliseconds: the next press is measured by
  it. 0 is refused.
- `IPREFS_ScreenFontHeight`, rows: the next screen opened without a
  font of its own takes it. 0 is refused.
- `IPREFS_Keyboard`: when the keyboard on the screen comes up. A
  value past `KEYBOARD_NEVER` is refused.
- `IPREFS_OffScreen`: whether a window may be moved partly past its
  screen's edges, 0 or 1; anything else is refused. It holds from the
  next move or size on: a window already past an edge stays there until
  it is moved or sized.
- `IPREFS_ScreenFont`, `IPREFS_DefaultFont`, `IPREFS_FixedFont`: the
  fonts screens, windows and consoles opened from now on use, as
  `SetSystemFonts` sets them; one not given keeps the font it has.
- `IPREFS_Pens`: the system's pens, as `SetScreenPens` with no screen
  sets them - every screen without pens of its own is painted again.
- `IPREFS_Style`: the system's style, as `SetStyle` with no screen
  sets it - every window it reaches is drawn again.

Every window that asked for `IDCMP_NEWPREFS` is told, whichever
screen it is on: a window that draws something the settings decide
reads them again and draws it anew.

**CONTEXT**

- Waits: yes - for the fonts, the screen list and the layers it draws
  in.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The list and all it points to stay the caller's: intuition opens fonts
of its own and copies the pens and the style.

**NOTES**

- What `C:SetPrefs` calls at boot, from the files in `ENV:Sys`.

**BUGS**

None known.

**SEE ALSO**

`GetPrefs`, `GetDefPrefs`, `SetStyle`, `SetScreenPens`,
`SetSystemFonts`

**EXAMPLES**

```zig
// A quicker double-click, and no keyboard on the screen.
_ = ib.SetPrefs(&[_]TagItem{
    .{ .tag = intuition.IPREFS_DoubleClick, .data = 400 },
    .{ .tag = intuition.IPREFS_Keyboard, .data = intuition.KEYBOARD_NEVER },
    .{},
});
```

## SetPubScreenModes

Sets how public screens behave, for every program.

**SYNOPSIS**

```zig
fn SetPubScreenModes(ib: *IntuitionBase, modes: u32) u32
```

**SINCE**

0.14. LVO -380.

**INPUTS**

- `modes` - the new bits: `POPPUBSCREEN`, or 0.

**RESULT**

The bits there were before.

**BEHAVIOR**

With `POPPUBSCREEN` a window opened on a public screen by name, or on
the default one, brings that screen to the front.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

The modes are the whole system's, not the caller's: they are for the
program that manages the screens, which reads them first and keeps the
bits it does not mean to change.

**BUGS**

None known.

**SEE ALSO**

`LockPubScreen`, `ScreenToFront`

**EXAMPLES**

```zig
const old = ib.SetPubScreenModes(sc.POPPUBSCREEN);
_ = old;
```

## SetScreenPens

A screen's pens, or the system's, replaced - and every screen it reaches painted again in them.

**SYNOPSIS**

```zig
fn SetScreenPens(ib: *IntuitionBase, screen: ?*Screen,
    pens: ?[*]const Pen) void
```

**SINCE**

0.26. LVO -496.

**INPUTS**

- `screen` - the screen whose own pens they are, as `SA_Pens` gives
  them at open; null for the system's.
- `pens` - `NUMDRIPENS` colours, by the `DrawInfo` pens' indexes, read
  and copied; null for the system's pens (a screen) or the built-in
  ones (the system).

**RESULT**

Nothing.

**BEHAVIOR**

**The system's pens** are what a screen opened without `SA_Pens`,
`SA_DetailPen` or `SA_BlockPen` takes: every such screen, those already
open among them, and every one opened after. **A screen's own**
replaces its pens alone, and then it keeps them whatever the system's
become; given null, it follows the system's again.

Every screen it reaches is then painted again: its ground, its bar,
and every window on it - its inside in the new background, its border
and its gadgets. A console in a window draws its text again; each
window that listens for `IDCMP_NEWPREFS` hears it, for what its
program draws itself, which the paint has cleared.

**CONTEXT**

- Waits: yes - for intuition's lock, and for the layers it draws in.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The pens stay the caller's; the screen keeps a copy.

**NOTES**

- With no screen, what `SetPrefs` does with `IPREFS_Pens` - which
  `C:SetPrefs` gives from `ENV:Sys/palette.prefs`.
- A style that gives colours of its own (`STYLE_BackgroundRGB` and the
  rest) keeps them: only what is drawn in pens changes.

**BUGS**

- A program that draws in its window and does not listen for
  `IDCMP_NEWPREFS` shows the new background where it drew until it
  draws again.

**SEE ALSO**

`SA_Pens`, `GetScreenDrawInfo`, `SetStyle`, `SetPrefs`

**EXAMPLES**

```zig
// A darker ground for every screen, the rest as they are.
var pens: [sc.NUMDRIPENS]Pen = (ib.GetScreenDrawInfo(screen)).pens[0..sc.NUMDRIPENS].*;
pens[sc.BACKGROUNDPEN] = graphics.penRGB(0x80, 0x84, 0x88);
ib.SetScreenPens(null, &pens);
```

## SetStyle

A screen's style, or the system's, replaced - and every window it reaches drawn again in it.

**SYNOPSIS**

```zig
fn SetStyle(ib: *IntuitionBase, screen: ?*Screen,
    tags: ?[*]const TagItem) bool
```

**SINCE**

0.23. LVO -488.

**INPUTS**

- `screen` - the screen whose own style it is, as `SA_Style` gives one
  at open; null for the system's style.
- `tags` - the style, a tag list as `SA_Style` takes; null, or one
  with no property in it, for none.

**RESULT**

True when the style is in place; false when there was no memory for
it, and then the one before is kept.

**BEHAVIOR**

The list is read once, as `SA_Style`'s is, and may go once the call
returns. **The system's style** is asked after a screen's own and
before the system's default, so it changes the look of every screen
at once, those already open among them, and of every screen opened
after; a screen's own style still wins over it. **A screen's own**
replaces what `SA_Style`, or an earlier call, gave that screen.

Every window on the screens it reaches is then drawn again: its
gadgets laid out - a border or a padding may have changed what fits -
its frame and its gadgets drawn, and the screen's bar. Each such window
that listens for `IDCMP_NEWPREFS` hears it, for what it draws itself.

**CONTEXT**

- Waits: yes - for intuition's lock, and for the layers it draws in.
- Interrupts: no.
- Locks: no spinlock may be held. The style is put in place under
  intuition's look lock.
- Process: a Task will do.

**OWNERSHIP**

The list stays the caller's; intuition keeps its own copy, and frees
the one it replaces. A screen's style is freed when the screen
closes.

**NOTES**

- What a program read with `GetStyleAttr(STYLE_BackgroundFill)` points
  into the style it came from, and is good only until that style is
  replaced.
- With no screen, what `SetPrefs` does with `IPREFS_Style` - which
  `C:SetPrefs` gives from `ENV:Sys/style.prefs`.

**BUGS**

- A window keeps the border sizes it opened with: a style whose window
  border is wider or narrower than the one before shows it only in
  windows opened after.
- A gadget drawn smaller than before leaves what was outside it until
  the window is drawn again for some other reason.

**SEE ALSO**

`SA_Style`, `GA_Style`, `DrawPart`, `GetStyleAttr`, `SetPrefs`

**EXAMPLES**

```zig
// Every screen's buttons with a blue line round them.
const blue = [_]TagItem{
    .{ .tag = style.STYLE_Part, .data = style.PART_MAIN },
    .{ .tag = style.STYLE_Border, .data = style.BORDER_FLAT },
    .{ .tag = style.STYLE_BorderRGB, .data = 0xFF3A6EA5 },
    .{},
};
if (!ib.SetStyle(null, &blue)) return dos.RETURN_FAIL;

// And back to the default.
_ = ib.SetStyle(null, null);
```

## SetSystemFonts

The fonts screens, windows and consoles use from now on.

**SYNOPSIS**

```zig
fn SetSystemFonts(ib: *IntuitionBase, screen_font: ?*graphics.TextFont, default_font: ?*graphics.TextFont, fixed_font: ?*graphics.TextFont) bool
```

**SINCE**

0.19. LVO -456.

**INPUTS**

- `screen_font` - title bars and menus of screens opened from now on.
- `default_font` - text in windows and gadgets that name none.
- `fixed_font` - consoles; must be fixed-width.

Each may be null: pospaz from the ROM again.

**RESULT**

True when set. False when `fixed_font` is proportional, or a font
could not be opened, and then nothing changes.

**BEHAVIOR**

Intuition opens each font itself and keeps it open until the next
call, so the caller closes its own opens as soon as this returns.
Screens and windows already open keep the fonts they were made with:
their layout was worked out for those. The next screen, window and
console takes the new ones - and the default public screen when it is
next opened.

Every window that asked for `IDCMP_NEWPREFS` is told, since the fonts
are a setting like any other and a window that draws in one may want
to draw again. A screen already open keeps the font it opened with.

**CONTEXT**

- Waits: yes, while another task reads the fonts.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The fonts stay the caller's to close; intuition holds opens of its own.

**BUGS**

None known.

**SEE ALSO**

`OpenSystemFont`, `SetPrefs`, `diskfont.library/OpenDiskFont`

**EXAMPLES**

```zig
const font = dfb.OpenDiskFont(&.{ .name = "spleen.font", .y_size = 10, .flags = sdk.graphics.FPF_POINTS });
_ = ib.SetSystemFonts(font, font, font);
if (font) |f| gb.CloseFont(f);
```

## SetWindowPointerA

Gives a window its own mouse pointer, the busy pointer, the default, or none at all.

**SYNOPSIS**

```zig
fn SetWindowPointerA(ib: *IntuitionBase, window: *Window, tags: ?[*]const TagItem) void
```

**SINCE**

0.18. LVO -452.

**INPUTS**

- `window` - the window.
- `tags` - any of:
  - `WA_Pointer` - a `pointerclass` object, or null (the default) for
    the default pointer.
  - `WA_BusyPointer` - true for the standard busy pointer in place of
    `WA_Pointer`'s.
  - `WA_HidePointer` - true for no pointer at all, in place of either.
  - `WA_PointerDelay` - true to make the change three tenths of a
    second from now, unless another comes first.
  No tags at all is the default pointer again.

**RESULT**

Nothing.

**BEHAVIOR**

The window keeps the pointer, and the mouse pointer takes it whenever
the window is the active one - at once if it is now. With
`WA_PointerDelay` the change waits for three of input.device's ticks;
another call before then replaces it, so a program that puts up the
busy pointer with a delay and takes it down again as soon as a short
piece of work is done never shows it. `OpenWindowTagList` takes the
same three tags.

A hidden pointer is hidden only from sight: the mouse still moves it,
and the window still hears its moves and buttons - which is what a
program drawing a cursor of its own wants.

The pointer is seen once a mouse has been used: on a touch panel with
no mouse the call changes what a mouse would show, and nothing else.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The pointerclass object stays the caller's and must outlive its use by
the window - or be disposed of, which takes it off every window.

**NOTES**

A picture the board will not take - too large, or with no alpha - shows
the default pointer.

**BUGS**

None known.

**SEE ALSO**

`OpenWindowTagList`, `NewObjectTagList` (pointerclass)

**EXAMPLES**

```zig
ib.SetWindowPointerA(window, &.{
    .{ .tag = wn.WA_BusyPointer, .data = 1 },
    .{ .tag = wn.WA_PointerDelay, .data = 1 },
    .{},
});
work();
ib.SetWindowPointerA(window, null);
```

## SetWindowTitles

Changes a window's title and the screen title it shows while active.

**SYNOPSIS**

```zig
fn SetWindowTitles(ib: *IntuitionBase, window: *Window,
    window_title: ?[*:0]const u8, screen_title: ?[*:0]const u8) void
```

**SINCE**

0.10. LVO -232.

**INPUTS**

- `window` - the window.
- `window_title` - what its title bar says; null for nothing, or
  `TITLE_UNCHANGED` to leave it.
- `screen_title` - what the screen's bar says while this window is the
  active one; null for nothing, or `TITLE_UNCHANGED` to leave it.

**RESULT**

Nothing.

**BEHAVIOR**

A new window title is drawn at once, with the rest of the border. A new
screen title is drawn at once when the window is active, and otherwise
the next time it is activated.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The strings are not copied: each must stay as it is for as long as the
window shows it.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`OpenWindowTagList` (`WA_Title`, `WA_ScreenTitle`), `RefreshWindowFrame`

**EXAMPLES**

```zig
ib.SetWindowTitles(window, "Saved", wn.TITLE_UNCHANGED);
```

## ShowTitle

Puts a screen's title bar in front of its backdrop windows, or behind them.

**SYNOPSIS**

```zig
fn ShowTitle(ib: *IntuitionBase, screen: *Screen, show: bool) void
```

**SINCE**

0.14. LVO -392.

**INPUTS**

- `screen` - the screen.
- `show` - true for the bar in front of the backdrop windows, false for
  it behind them.

**RESULT**

Nothing.

**BEHAVIOR**

A backdrop window covering the whole screen hides the bar when it is
behind, and the bar shows over the window when it is in front. Ordinary
windows are always in front of the bar. A backdrop window opened later
goes where the bar leaves room for it: behind a bar that is shown, in
front of one that is not. A screen without a bar is left as it is.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

A program filling the screen with a backdrop window hides the bar this
way and shows it again when the menu button is held.

**BUGS**

None known.

**SEE ALSO**

`OpenScreenTagList` (`SA_ShowTitle`), `OpenWindowTagList` (`WA_Backdrop`)

**EXAMPLES**

```zig
ib.ShowTitle(screen, false);
```

## SizeWindow

Sizes a window.

**SYNOPSIS**

```zig
fn SizeWindow(ib: *IntuitionBase, window: *Window, dw: i32,
    dh: i32) void
```

**SINCE**

0.5. LVO -148.

**INPUTS**

- `window` - the window.
- `dw`, `dh` - how much wider and taller; negative is smaller.

**RESULT**

Nothing.

**BEHAVIOR**

`ChangeWindowBox` at its place and a new size, kept within its limits.
**The window stays where it is**: it grows no further than its
screen's right and bottom edges, measured from its own left and top -
or, while windows may hang past those edges (`IPREFS_OffScreen`), no
larger than the screen. `ChangeWindowBox` given a size that does not
fit at the place it is given moves the window to make room; a size is
not a move.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ChangeWindowBox`, `MoveWindow`

**EXAMPLES**

```zig
ib.SizeWindow(window, 20, 20);
```

## StylePens

The screen's pens, with the ones that stand for a gadget's look taken from a part of the style.

**SYNOPSIS**

```zig
fn StylePens(ib: *IntuitionBase, draw_info: ?*const DrawInfo,
    own: ?*const Style, part: u32, pens: [*]graphics.Pen) void
```

**SINCE**

0.22. LVO -484.

**INPUTS**

- `draw_info` - the screen's, for its pens and its style; null for the
  default pens and the system's default style alone.
- `own` - a gadget's own style (`GA_Style`, read back), or null.
- `part` - a `style.PART_` number, or a class's own.
- `pens` - room for `NUMDRIPENS` pens, written.

**RESULT**

Nothing; the pens are in `pens`, as 0xAARRGGBB.

**BEHAVIOR**

Every pen is the screen's, except six:

| pen | from the part |
|---|---|
| `BACKGROUNDPEN` | its background, at rest |
| `TEXTPEN` | its text, at rest |
| `FILLPEN` | its background, pressed |
| `FILLTEXTPEN` | its text, pressed |
| `SHINEPEN` | its bevel's light side |
| `SHADOWPEN` | its bevel's dark side |

Each is found as `DrawPart` finds a property. With the system's default
style and `style.PART_MAIN`, all six are the screen's own pens again,
so a class that draws with these instead of the screen's draws exactly
as it did - and follows whatever style its screen or the gadget has.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

`pens` is the caller's; nothing is kept.

**NOTES**

A class that also shows a selection or a level takes `FILLPEN` and
`FILLTEXTPEN` from `style.PART_SELECTION` or `style.PART_INDICATOR`
with `GetStyleAttr` afterwards.

**BUGS**

None known.

**SEE ALSO**

`GetStyleAttr`, `DrawPart`

**EXAMPLES**

```zig
var pens: [sc.NUMDRIPENS]graphics.Pen = undefined;
ib.StylePens(info.draw_info, gadget.style, style.PART_MAIN, &pens);
// ... draw as before, with `pens` for `info.draw_info.pens`.
```

## SysReqHandler

Reads what arrived at a requester.

**SYNOPSIS**

```zig
fn SysReqHandler(ib: *IntuitionBase, window: ?*Window, idcmp_ptr: ?*u32,
    wait_input: bool) i32
```

**SINCE**

0.11. LVO -256.

**INPUTS**

- `window` - what `BuildEasyRequestArgs` answered. Null, which is what it
  answers when it failed, is answered 0 at once.
- `idcmp_ptr` - where to write which of the caller's own IDCMP classes
  arrived, or null.
- `wait_input` - wait for a message when none is waiting.

**RESULT**

- 1, 2, ... for the buttons from the left and 0 for the rightmost.
- -1 (`SYSREQ_IDCMP`): one of the classes the caller gave
  `BuildEasyRequestArgs` arrived; it is written to `*idcmp_ptr`.
- -2 (`SYSREQ_PENDING`): nothing that arrived answered the requester -
  a key it does not know, or no message at all without `wait_input`.

**BEHAVIOR**

Every message waiting is read and replied to until one answers. A
button let go over itself answers with its number; the left Amiga key
with V answers as the leftmost button would, and with B as the
rightmost. Any other key is passed over.

**CONTEXT**

- Waits: with `wait_input`, until the window has a message.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands. The requester stays open until
`FreeSysRequest`, whatever the answer.

**NOTES**

- When more than one class of the caller's is asked for, `*idcmp_ptr`
  holds the one that arrived; set it again before the next time it is
  given to `EasyRequestArgs`.

**BUGS**

None known.

**SEE ALSO**

`BuildEasyRequestArgs`, `FreeSysRequest`, `EasyRequestArgs`

**EXAMPLES**

```zig
var answer = ib.SysReqHandler(req, null, true);
while (answer == requesters.SYSREQ_PENDING) : (answer = ib.SysReqHandler(req, null, true)) {}
```

## TimedDisplayAlert

Shows an alert and waits for an answer, or for the time to run out.

**SYNOPSIS**

```zig
fn TimedDisplayAlert(ib: *IntuitionBase, alert_number: u32, text: [*:0]const u8, height: u32, frames: u32) bool
```

**SINCE**

0.14. LVO -420.

**INPUTS**

- `alert_number` - what the alert is; only its type counts here:
  `AT_DeadEnd` set for one the system does not come back from.
- `text` - what it says, lines parted by `'\n'`, each centred.
- `height` - the least height of its box, in pixels; the box grows to
  hold the lines.
- `frames` - how long it waits for an answer, in frames of a 60 Hz
  display; 0 shows nothing and answers false.

**RESULT**

True when the left button - or a touch on the left half of the display -
answered it; false for the right button or the right half, when the
time ran out, when it could not be shown, and always for a dead-end
alert.

**BEHAVIOR**

The alert is shown alone, on a black picture of the display's own: a
box across its top, amber - red for a dead end - with the text in it,
its border flashing. Everything else is kept as it is and shown again
when the alert comes down. While it is up, the input is its own:
nothing reaches a window, and presses made before it came up are not
taken for an answer. A dead-end alert stays up: this returns at once
and nothing takes it down. One alert at a time; a second waits for the
first.

**CONTEXT**

- Waits: for the answer or the time, and for an alert already up.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do; not intuition's input task, whose events
  answer it.

**OWNERSHIP**

The text is read while the alert is up and not kept.

**NOTES**

The picture comes out of the display's memory: when that has no room
for another one, the alert cannot be shown.

**BUGS**

None known.

**SEE ALSO**

`DisplayAlert`, `EasyRequestArgs`, exec's `Alert`

**EXAMPLES**

```zig
// Six seconds to say whether to go on.
const go_on = ib.TimedDisplayAlert(exec.AT_Recovery, "The disk went away.\nLeft: retry   Right: cancel", 60, 360);
```

## UnlockClassList

Lets the public class list go.

**SYNOPSIS**

```zig
fn UnlockClassList(ib: *IntuitionBase) void
```

**SINCE**

0.2. LVO -44.

**INPUTS**

None.

**RESULT**

Nothing.

**BEHAVIOR**

One release for each `LockClassList`.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do; the task that took it.

**OWNERSHIP**

Nothing found through the list may be kept past this.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`LockClassList`

**EXAMPLES**

```zig
ib.UnlockClassList();
```

## UnlockIBase

Lets the screens and windows go again.

**SYNOPSIS**

```zig
fn UnlockIBase(ib: *IntuitionBase, lock_number: u32) void
```

**SINCE**

0.9. LVO -224.

**INPUTS**

- `lock_number` - what `LockIBase` answered. There is one lock, so it
  is not read.

**RESULT**

Nothing.

**BEHAVIOR**

Releases the semaphore `LockIBase` obtained, once. A caller that locked
twice unlocks twice.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: the task that called `LockIBase`.

**OWNERSHIP**

The lock goes back.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`LockIBase`

**EXAMPLES**

```zig
const held = ib.LockIBase(0);
defer ib.UnlockIBase(held);
```

## UnlockPubScreen

Unlocks a public screen.

**SYNOPSIS**

```zig
fn UnlockPubScreen(ib: *IntuitionBase, name: ?[*:0]const u8,
    screen: ?*Screen) void
```

**SINCE**

0.4. LVO -128.

**INPUTS**

- `name` - the screen's name, used when `screen` is null; null names
  the default public screen.
- `screen` - the screen LockPubScreen answered, or null.

**RESULT**

Nothing.

**BEHAVIOR**

One lock fewer. A screen with none can close, and its owner is sent
`SA_PubSig` if it asked for it.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The caller may not use the screen after this unless it holds another
lock or opened it.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`LockPubScreen`

**EXAMPLES**

```zig
ib.UnlockPubScreen(null, screen);
```

## UnlockPubScreenList

Lets the list of public screens go.

**SYNOPSIS**

```zig
fn UnlockPubScreenList(ib: *IntuitionBase) void
```

**SINCE**

0.14. LVO -364.

**INPUTS**

None.

**RESULT**

Nothing.

**BEHAVIOR**

Screens can open, close and change again. Each `LockPubScreenList` has
one of these.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do; the one that locked the list.

**OWNERSHIP**

Nothing changes hands. The list and its nodes must not be read after.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`LockPubScreenList`

**EXAMPLES**

```zig
ib.UnlockPubScreenList();
```

## WaitIMsg

Waits until a window has a message, or one of some other signals comes.

**SYNOPSIS**

```zig
fn WaitIMsg(ib: *IntuitionBase, window: *Window, others: u32) u32
```

**SINCE**

0.14. LVO -340.

**INPUTS**

- `window` - the window whose messages are waited for.
- `others` - more signals to wake up for, such as
  `SIGBREAKF_CTRL_C`; 0 for none.

**RESULT**

The signals received: the window port's signal when a message came, and
those of `others` that arrived. 0 when there is nothing to wait for:
no port and `others` 0.

**BEHAVIOR**

With a message already waiting it answers at once, the port's signal
and any of `others` already set, without clearing them. Otherwise it
is `Wait` on the port's signal and `others`, which clears the signals
it answers. A window without a port waits for `others` alone.

**CONTEXT**

- Waits: yes, unless a message is already there.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do; it must be the task the window's port
  signals, the one that opened the window or last gave it a port.

**OWNERSHIP**

Nothing is allocated and no message is taken: `GetIMsg` does that.

**NOTES**

One wake-up can mean several messages: take them with `GetIMsg` until
it answers null before waiting again.

**BUGS**

None known.

**SEE ALSO**

`GetIMsg`, `ReplyIMsg`, `ModifyIDCMP`

**EXAMPLES**

```zig
while (true) {
    const got = ib.WaitIMsg(window, SIGBREAKF_CTRL_C);
    if (got & SIGBREAKF_CTRL_C != 0) break;
    while (ib.GetIMsg(window)) |im| {
        const class = im.class;
        ib.ReplyIMsg(im);
        if (class == IDCMP_CLOSEWINDOW) return;
    }
}
```

## WindowLimits

Sets how small and how large a window may be sized.

**SYNOPSIS**

```zig
fn WindowLimits(ib: *IntuitionBase, window: *Window, min_width: i32,
    min_height: i32, max_width: i32, max_height: i32) bool
```

**SINCE**

0.10. LVO -236.

**INPUTS**

- `window` - the window.
- `min_width`, `min_height` - the smallest it may be, border included;
  0 leaves the limit as it is.
- `max_width`, `max_height` - the largest; 0 leaves it, and a negative
  one is as large as the screen.

**RESULT**

True when every limit asked for was taken. False when a minimum is
larger than the window is now or a maximum smaller: that limit is left
as it was, and the others are still taken.

**BEHAVIOR**

Only the limits change: the window keeps its size, which every limit
taken already allows. Sizing it afterwards - with its size gadget,
`SizeWindow`, `ChangeWindowBox` or `ZipWindow` - stays within them, and
within its screen whatever the maximum says.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`OpenWindowTagList` (`WA_MinWidth` ... `WA_MaxHeight`), `SizeWindow`

**EXAMPLES**

```zig
_ = ib.WindowLimits(window, 200, 80, -1, -1);
```

## WindowToBack

Puts a window at the back.

**SYNOPSIS**

```zig
fn WindowToBack(ib: *IntuitionBase, window: *Window) void
```

**SINCE**

0.5. LVO -160.

**INPUTS**

- `window` - the window.

**RESULT**

Nothing.

**BEHAVIOR**

Behind every other window of its kind on the screen. What that
uncovers of the others is repaired.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`WindowToFront`

**EXAMPLES**

```zig
ib.WindowToBack(window);
```

## WindowToFront

Brings a window to the front.

**SYNOPSIS**

```zig
fn WindowToFront(ib: *IntuitionBase, window: *Window) void
```

**SINCE**

0.5. LVO -156.

**INPUTS**

- `window` - the window.

**RESULT**

Nothing.

**BEHAVIOR**

In front of every other window of its kind on the screen: a backdrop
window stays behind the ordinary ones. What it uncovers of itself is
repaired if it is a simple-refresh window.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`WindowToBack`

**EXAMPLES**

```zig
ib.WindowToFront(window);
```

## ZipWindow

Flips a window to its other box and back.

**SYNOPSIS**

```zig
fn ZipWindow(ib: *IntuitionBase, window: *Window) void
```

**SINCE**

0.10. LVO -228.

**INPUTS**

- `window` - the window.

**RESULT**

Nothing.

**BEHAVIOR**

The window goes to the box it was told to flip to - `WA_Zoom`, or else
its largest size when it opened at its smallest and its smallest
otherwise - and remembers where it was, so the next call puts it back.
A box whose corner is -1, -1 changes the size and not the place, which
is what a window that only wants to grow and shrink asks for. It is
what the zoom gadget does, and works on a window without one.

The box is changed with `ChangeWindowBox`, so it is kept within the
window's limits and its screen, and the window is told
`IDCMP_NEWSIZE` and `IDCMP_CHANGEWINDOW` as it asked.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ChangeWindowBox`, `sdk.intuition.windows.WA_Zoom`

**EXAMPLES**

```zig
ib.ZipWindow(window);
```
