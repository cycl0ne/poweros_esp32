# intuition.library

intuition.library's functions. So far the object system: classes made
and freed, objects made from them, and messages sent to those objects.
Every object's class is a Hook that is handed each message; a class
passes what it does not handle on to the class it was made from, up to
rootclass. Open it with OpenLibrary("intuition.library", 0).

Generated from the source by `./zig build autodoc`.

## Index

- [ActivateGadget](#activategadget) - Gives a gadget the input without it being pressed.
- [ActivateWindow](#activatewindow) - Makes a window the active one.
- [AddClass](#addclass) - Makes a class public.
- [AddGList](#addglist) - Puts gadgets into a window.
- [AutoRequestTagList](#autorequesttaglist) - Asks with two buttons made from IntuiTexts and waits.
- [BeginRefresh](#beginrefresh) - Begins redrawing what a window lost.
- [BuildEasyRequestArgs](#buildeasyrequestargs) - Opens a requester and hands it back to be answered.
- [BuildSysRequestTagList](#buildsysrequesttaglist) - A two-button requester from IntuiTexts, handed back.
- [ChangeWindowBox](#changewindowbox) - Moves and sizes a window at once.
- [ClearDMRequest](#cleardmrequest) - No double-click requester any more.
- [ClearMenuStrip](#clearmenustrip) - Takes a window's menus away.
- [CloseScreen](#closescreen) - Closes a screen.
- [CloseWindow](#closewindow) - Closes a window.
- [CoerceMessage](#coercemessage) - Sends a message to an object as a given class would handle it.
- [DisposeObject](#disposeobject) - Frees an object.
- [DoGadgetMethodA](#dogadgetmethoda) - Sends a gadget a method with its window's GadgetInfo.
- [DoubleClick](#doubleclick) - Whether two moments are close enough to be a double-click.
- [DrawBorder](#drawborder) - Draws a Border and the Borders linked after it.
- [DrawImage](#drawimage) - Draws an image.
- [DrawImageState](#drawimagestate) - Draws an image in a state.
- [EasyRequestArgs](#easyrequestargs) - Asks something in a requester and waits for the answer.
- [EndRefresh](#endrefresh) - Ends a redraw begun with BeginRefresh.
- [EndRequest](#endrequest) - Takes a requester down.
- [EraseImage](#eraseimage) - Erases what an image covers.
- [FindClass](#findclass) - Finds a public class by name.
- [FreeClass](#freeclass) - Frees a class.
- [FreeScreenDrawInfo](#freescreendrawinfo) - Hands back a DrawInfo.
- [FreeSysRequest](#freesysrequest) - Closes a requester and gives back what was made for it.
- [GetAttr](#getattr) - Reads one attribute of an object.
- [GetScreenAttrs](#getscreenattrs) - Reads a screen.
- [GetScreenDrawInfo](#getscreendrawinfo) - The pens and font a screen's parts are drawn in.
- [GetWindowAttrs](#getwindowattrs) - Reads a window.
- [InitRequester](#initrequester) - Clears a Requester to be filled in.
- [IntuiTextLength](#intuitextlength) - How wide one run of text is, in pixels.
- [ItemAddress](#itemaddress) - The item a menu number names.
- [LendMenus](#lendmenus) - Makes one window's menu button show another window's menus.
- [LockClassList](#lockclasslist) - Holds the public class list.
- [LockIBase](#lockibase) - Holds the screens and windows still.
- [LockPubScreen](#lockpubscreen) - Locks a public screen, opening the default one if needed.
- [MakeClass](#makeclass) - Makes a class.
- [ModifyIDCMP](#modifyidcmp) - Changes which messages a window gets.
- [MoveWindow](#movewindow) - Moves a window.
- [NewObjectTagList](#newobjecttaglist) - Makes an object.
- [NextObject](#nextobject) - Walks a list of objects.
- [ObtainGIRPort](#obtaingirport) - The RastPort a gadget draws into, for a moment.
- [OffGadget](#offgadget) - Keeps a gadget from being pressed, and shows it so.
- [OffMenu](#offmenu) - Keeps a menu, an item or a subitem from being picked.
- [OnGadget](#ongadget) - Lets a gadget be pressed again, and shows it so.
- [OnMenu](#onmenu) - Lets a menu, an item or a subitem be picked again.
- [OpenScreenTagList](#openscreentaglist) - Opens a screen.
- [OpenWindowTagList](#openwindowtaglist) - Opens a window.
- [PointInImage](#pointinimage) - Whether a point is inside an image.
- [PrintIText](#printitext) - Draws a run of text and the runs linked after it.
- [RefreshGList](#refreshglist) - Draws gadgets of a window.
- [RefreshWindowFrame](#refreshwindowframe) - Draws a window's border again.
- [ReleaseGIRPort](#releasegirport) - Gives back a RastPort from `ObtainGIRPort`.
- [RemoveClass](#removeclass) - Takes a class off the public list.
- [RemoveGList](#removeglist) - Takes gadgets out of a window.
- [Request](#request) - Puts a requester up in a window.
- [ResetMenuStrip](#resetmenustrip) - Gives a window back a strip it already had.
- [ScreenToBack](#screentoback) - Puts a screen behind the others on its display.
- [ScreenToFront](#screentofront) - Brings a screen to the front of its display.
- [SendMessage](#sendmessage) - Sends a message to an object.
- [SendSuperMessage](#sendsupermessage) - Sends a message on to a class's superclass.
- [SetAttrsTagList](#setattrstaglist) - Changes an object's attributes.
- [SetDMRequest](#setdmrequest) - The requester a double-click of the menu button puts up.
- [SetGadgetAttrsTagList](#setgadgetattrstaglist) - Changes a gadget's attributes, and lets it show the change.
- [SetMenuStrip](#setmenustrip) - Gives a window its menus.
- [SetWindowTitles](#setwindowtitles) - Changes a window's title and the screen title it shows while active.
- [SizeWindow](#sizewindow) - Sizes a window.
- [SysReqHandler](#sysreqhandler) - Reads what arrived at a requester.
- [UnlockClassList](#unlockclasslist) - Lets the public class list go.
- [UnlockIBase](#unlockibase) - Lets the screens and windows go again.
- [UnlockPubScreen](#unlockpubscreen) - Unlocks a public screen.
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

- `gadget` - a gadget on the window's list, or of the requester in front
  in it.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: must not be held: it waits.
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
const save = ib.AutoRequestTagList(window, &[_]TagItem{
    .{ .tag = SYSREQ_Body, .data = @intFromPtr(&body) },
    .{ .tag = SYSREQ_Positive, .data = @intFromPtr(&yes) },
    .{ .tag = SYSREQ_Negative, .data = @intFromPtr(&no) },
    .{},
});
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- `tags` - `SYSREQ_Body`, what it says, each run of the chain a line;
  `SYSREQ_Positive`, the left button's text - yes, retry, go on - or
  none; `SYSREQ_Negative`, the right button's text - no, cancel;
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
answering for the left and the right one. The texts' words are taken as
they are - no format is read in them - and their pens, fonts and places
give way to the requester's own look.

**CONTEXT**

- Waits: for the screen list's semaphore and the layers' locks.
- Interrupts: no.
- Forbid: not held and not needed.
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
const req = ib.BuildSysRequestTagList(null, &[_]TagItem{
    .{ .tag = SYSREQ_Body, .data = @intFromPtr(&body) },
    .{ .tag = SYSREQ_Positive, .data = @intFromPtr(&retry) },
    .{ .tag = SYSREQ_Negative, .data = @intFromPtr(&cancel) },
    .{},
}) orelse return;
defer ib.FreeSysRequest(req);
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
and on the screen; the place keeps it on the screen. When the size
changed, what was the right and bottom border is cleared to the
background and the border drawn where it now is, and the program is
told `IDCMP_NEWSIZE`; either way it is told `IDCMP_CHANGEWINDOW`.
Whatever the change uncovered is repaired.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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

Its bar and LayerInfo go, the display is left black, and a font the
screen opened for itself is closed.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no; it frees memory.
- Forbid: not held and not needed.
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
freed with the port. If it was active, no window is.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Forbid: not held and not needed.
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
- Forbid: not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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

The difference is compared with the double-click time, a second and a
half. A second moment before the first is not a double-click.

**CONTEXT**

- Waits: no.
- Interrupts: yes: it reads two numbers of the base.
- Forbid: not held and not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

It is what tells a double-click of the menu button that puts up a
window's double-click requester.

**BUGS**

The time cannot be changed yet: there is no preference for it.

**SEE ALSO**

`SetDMRequest`, `sdk.intuition.windows.IntuiMessage`

**EXAMPLES**

```zig
if (ib.DoubleClick(last_secs, last_micros, msg.seconds, msg.micros)) open(item);
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
- Forbid: not needed.
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
- Forbid: not needed.
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
- Forbid: not needed.
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
- Forbid: must not be held.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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

- Waits: no. - Interrupts: no. - Forbid: not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not needed.
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
  `SA_Width`, `SA_Height`, `SA_Depth`, `SA_Title`, `SA_Font`,
  `SA_PubName` (0 for a private screen), `SA_ShowTitle`,
  `SA_RastPort`, `SA_LayerInfo`, `SA_BarHeight`. A tag it does not
  know, or a null data, is passed over.

**RESULT**

Nothing; the values are where the tags point.

**BEHAVIOR**

The screen is opaque, and this is how a program learns how big it is
and where to draw.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
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

- Waits: no. - Interrupts: no. - Forbid: not needed.
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
  `WA_AmigaKey`, `WA_MenuHelp`.

**RESULT**

Nothing; the values are where the tags point.

**BEHAVIOR**

The window is opaque, and this is how a program learns where to draw:
inside the border widths of its RastPort.

**CONTEXT**

- Waits: no. - Interrupts: no. - Forbid: not needed.
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
- Forbid: not held and not needed.
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

How wide one run of text is, in pixels.

**SYNOPSIS**

```zig
fn IntuiTextLength(ib: *IntuitionBase, itext: *const IntuiText) i32
```

**SINCE**

0.9. LVO -216.

**INPUTS**

- `itext` - the run. Only its `text` and `font` are read.

**RESULT**

How far graphics' `Text` would move along drawing it, in the run's own
font or, when it names none, in the ROM's font at the height a screen
opens with when it is given no font. 0 for no text, or when there is
no memory to measure in.

**BEHAVIOR**

The run is measured by itself: the runs linked after it are drawn
where each says, not after it, so adding them up would be a width of
nothing in particular.

**CONTEXT**

- Waits: no.
- Interrupts: no: it allocates.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands. The RastPort it measures in is its own and is
freed before it returns.

**NOTES**

- A run drawn with `PrintIText` in a RastPort whose font is not the
  default, and naming no font of its own, comes out in that font, so
  this measure is not its width. Name the font in the run to measure
  what will be drawn.

**BUGS**

None known.

**SEE ALSO**

`PrintIText`, graphics' `TextLength`

**EXAMPLES**

```zig
const width = ib.IntuiTextLength(&label);
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: must not be held - it may wait.
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
- Forbid: must not be held.
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

- `name` - the public screen's name, or null for the default public
  screen, `WBENCHNAME`.

**RESULT**

The screen, locked, or null: no public screen of that name, or - for
null - the default screen could not be opened (no display, or the
display already shows another screen).

**BEHAVIOR**

The screen cannot close until each lock has its `UnlockPubScreen`. Null
opens the Workbench screen the first time; a name opens nothing.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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

`ChangeWindowBox` at its size and a new place, kept on the screen.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not needed.
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

**CONTEXT**

- Waits: for the window's layer.
- Interrupts: no.
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
(the display already shows a screen), `OSERR_PUBNOTUNIQUE`,
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
- Forbid: not held and not needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's until `CloseScreen`. A public one may also be locked by
others, and cannot close while it is.

**NOTES**

- One screen to a display, for now. A second on the same display is
  refused rather than hidden, so a program knows.
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

- `tags` - the `WA_` names. Where: `WA_Left`, `WA_Top`, `WA_Width`,
  `WA_Height` (or `WA_InnerWidth`/`WA_InnerHeight`), `WA_MinWidth` and
  the other limits. On what: `WA_CustomScreen`, `WA_PubScreen`,
  `WA_PubScreenName`, or by default the default public screen. How:
  `WA_Title` (not copied), `WA_CloseGadget`, `WA_DepthGadget`,
  `WA_SizeGadget`, `WA_DragBar`, `WA_Borderless`, `WA_Backdrop`,
  `WA_SimpleRefresh`/`WA_SmartRefresh`, `WA_NoCareRefresh`,
  `WA_Activate`, and `WA_IDCMP` for a message port. Its menus:
  `WA_Checkmark`, `WA_AmigaKey`, `WA_MenuHelp`, `WA_NewLookMenus`. May
  be null.

**RESULT**

The window, or null: no screen to open it on (the default one could not
be opened, or a named one is not open), or no memory.

**BEHAVIOR**

It is a layer of its screen, made to fit: sized down to the screen and
moved onto it when asked for more. Its border is drawn - a frame, a
title bar the font's height and a little, and the images of the border
gadgets it asked for - and the part inside is the screen's background
pen. Its RastPort draws in `TEXTPEN` on `BACKGROUNDPEN` in the screen's
font. With `WA_IDCMP` it has a message port of its own, made for the
calling task. With `WA_Activate` it becomes the active window.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Forbid: not held and not needed.
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
- Forbid: not needed.
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

Draws a run of text and the runs linked after it.

**SYNOPSIS**

```zig
fn PrintIText(ib: *IntuitionBase, rp: *graphics.RastPort,
    itext: ?*const IntuiText, left: i32, top: i32) void
```

**SINCE**

0.9. LVO -208.

**INPUTS**

- `rp` - where to draw.
- `itext` - the first run, or null, which draws nothing.
- `left`, `top` - added to each run's own `left` and `top`.

**RESULT**

Nothing.

**BEHAVIOR**

Each run in turn: its front and back pen and its draw mode are set,
and its font when it names one - a run without one is drawn in the
RastPort's own. The text's top is at (`left + run.left`,
`top + run.top`), so a run's place is its top left corner, whatever its
font's baseline. A run with no text, or an empty one, is passed over.

**CONTEXT**

- Waits: no, beyond what the RastPort's layer asks of a caller - hold
  it, as for any drawing in a window.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands. The RastPort gets its pens, draw mode and font
back as they were; its current point is left at the end of the last
run drawn, as `Text` leaves it.

**NOTES**

- itexticlass draws its `IA_Data` with the same loop, in the image's
  one pen instead of each run's.

**BUGS**

None known.

**SEE ALSO**

`IntuiTextLength`, `DrawBorder`, `DrawImage`, graphics' `Text`

**EXAMPLES**

```zig
var label = intuition.IntuiText{
    .front_pen = graphics.penRGB(0, 0, 0),
    .text = "Name:",
};
ib.PrintIText(rp, &label, 10, 20);
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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

## ScreenToBack

Puts a screen behind the others on its display.

**SYNOPSIS**

```zig
fn ScreenToBack(_: *IntuitionBase, screen: *Screen) void
```

**SINCE**

0.4. LVO -112.

**INPUTS**

- `screen` - the screen.

**RESULT**

Nothing.

**BEHAVIOR**

As `ScreenToFront`: with one screen to a display there is no other to
put in front of it.

**CONTEXT**

- Waits: no. - Interrupts: no. - Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ScreenToFront`

**EXAMPLES**

```zig
ib.ScreenToBack(screen);
```

## ScreenToFront

Brings a screen to the front of its display.

**SYNOPSIS**

```zig
fn ScreenToFront(_: *IntuitionBase, screen: *Screen) void
```

**SINCE**

0.4. LVO -108.

**INPUTS**

- `screen` - the screen.

**RESULT**

Nothing.

**BEHAVIOR**

A display shows one screen, so it is always at the front and this
changes nothing. The slot is here so that a program written now keeps
working when a display can hold several.

**CONTEXT**

- Waits: no. - Interrupts: no. - Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ScreenToBack`

**EXAMPLES**

```zig
ib.ScreenToFront(screen);
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
- Forbid: not needed.
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
- Forbid: not needed.
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
- Forbid: not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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

`ChangeWindowBox` at its place and a new size, kept within its limits
and its screen.

**CONTEXT**

- Waits: for the screen list's semaphore, and the layers' locks.
- Interrupts: no.
- Forbid: not held and not needed.
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
- Forbid: must not be held.
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
- Forbid: not needed.
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
- Forbid: not needed.
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

One lock fewer. A screen with none can close.

**CONTEXT**

- Waits: for the screen list's semaphore.
- Interrupts: no.
- Forbid: not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
- Forbid: not held and not needed.
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
