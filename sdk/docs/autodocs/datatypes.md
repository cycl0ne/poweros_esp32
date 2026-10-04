# datatypes.library

datatypes.library's functions: a file opened by what is in it. Open
it with OpenLibrary("datatypes.library", 1).

The table is this library's own: it is not on any other system's, so
it starts at the first slot after the standard four and holds only
what is here.

Generated from the source by `./zig build autodoc`.

## Index

- [AddDTObject](#adddtobject) - Puts an object into a window.
- [DisposeDTObject](#disposedtobject) - Gives an object back.
- [DoAsyncLayout](#doasynclayout) - Lays an object out on a process of its own.
- [DoDTMethodA](#dodtmethoda) - Sends a method to an object.
- [DrawDTObjectA](#drawdtobjecta) - Draws an object into a RastPort of the caller's.
- [GetDTAttrsA](#getdtattrsa) - Reads attributes from an object.
- [GetDTMethods](#getdtmethods) - Answers the methods an object knows.
- [GetDTString](#getdtstring) - Answers the text of one of the library's messages.
- [GetDTTriggerMethods](#getdttriggermethods) - Answers what an object can be told to do, with a name for each.
- [NewDTObjectA](#newdtobjecta) - Makes an object for what a file holds.
- [ObtainDTDrawInfoA](#obtaindtdrawinfoa) - Makes an object ready to draw somewhere that is not its window.
- [ObtainDataTypeA](#obtaindatatypea) - Says what kind of file something is.
- [RefreshDTObjectA](#refreshdtobjecta) - Draws an object again.
- [ReleaseDTDrawInfo](#releasedtdrawinfo) - Gives back what `ObtainDTDrawInfoA` answered.
- [ReleaseDataType](#releasedatatype) - Lets go of a data type.
- [RemoveDTObject](#removedtobject) - Takes an object out of its window.
- [SetDTAttrsA](#setdtattrsa) - Sets attributes on an object.

## AddDTObject

Puts an object into a window.

**SYNOPSIS**

```zig
fn AddDTObject(db: *DataTypesBase, window: ?*intuition.Window, requester: ?*intuition.Requester, object: ?*classusr.Object, position: i32) i32
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `window` - the window it goes in.
- `requester` - the requester in that window, or null.
- `object` - a data type object.
- `position` - where in the window's gadget list, as `AddGList`
  takes it; -1 for the end.

**RESULT**

Where it went in the list, or -1 when there was nothing to add.

**BEHAVIOR**

The object becomes a gadget of the window and is laid out and drawn
from then on like any other. A program that puts the object in a
layout instead does not call this: the layout adds it.

**CONTEXT**

- Waits: for the window's layer.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The object stays the caller's; it must be taken out again with
`RemoveDTObject` before it is disposed of.

**SEE ALSO**

`RemoveDTObject`, `RefreshDTObjectA`, `NewDTObjectA`

**EXAMPLES**

```zig
_ = dt.AddDTObject(window, null, picture, -1);
dt.RefreshDTObjectA(picture, window, null, null);
```

## DisposeDTObject

Gives an object back.

**SYNOPSIS**

```zig
fn DisposeDTObject(db: *DataTypesBase, object: ?*classusr.Object) void
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `object` - what `NewDTObjectA` answered; null does nothing.

**RESULT**

None.

**BEHAVIOR**

The object is disposed of, which closes the source it was reading
from and lets go of its data type. It must have been taken out of
its window first (`RemoveDTObject`), and anything laying it out is
waited for.

The class library the object belongs to has nothing holding it once
its last object is gone, so it is unloaded when memory runs short.

**CONTEXT**

- Waits: for the object's layout to finish.
- Interrupts: no.
- Locks: none needed.
- Process: needed - closing a file is dos's.

**OWNERSHIP**

Everything the object held goes with it.

**SEE ALSO**

`NewDTObjectA`, `RemoveDTObject`

**EXAMPLES**

```zig
_ = dt.RemoveDTObject(window, picture);
dt.DisposeDTObject(picture);
```

## DoAsyncLayout

Lays an object out on a process of its own.

**SYNOPSIS**

```zig
fn DoAsyncLayout(db: *DataTypesBase, object: *classusr.Object, layout: *gc.GpLayout) u32
```

**SINCE**

1.0. LVO -56.

**INPUTS**

- `object` - a data type object.
- `layout` - the `GM_LAYOUT` message that asked for it. Its
  `gadget_info` is copied, so it need not outlive the call.

**RESULT**

1 when a process is doing it, 0 when none could be started - and
then nothing has been laid out, so the caller does it itself.

**BEHAVIOR**

The object is sent `DTM_ASYNCLAYOUT` on the new process. A second
call while one is already running does not start another: the
running one is told the size changed and lays the object out again
when it is done, which is what keeps a window being dragged to a new
size from starting a process for every pixel.

`DTSIF_LAYOUT` is set while the work is going on and the object's
lock is held over it, so nothing disposes of an object mid-layout.

**CONTEXT**

- Waits: for memory and for the object's lock, briefly.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do; the work itself needs a Process, which is
  why there is one.

**OWNERSHIP**

The job block is the new process's and goes with it.

**NOTES**

datatypesclass answers `GM_LAYOUT` with this call, so a format's
class does its laying out in `DTM_ASYNCLAYOUT` and never in
`GM_LAYOUT`.

**SEE ALSO**

`AddDTObject`, `RefreshDTObjectA`

**EXAMPLES**

```zig
gc.GM_LAYOUT => return db.DoAsyncLayout(object, @ptrCast(@alignCast(msg))),
```

## DoDTMethodA

Sends a method to an object.

**SYNOPSIS**

```zig
fn DoDTMethodA(db: *DataTypesBase, object: *classusr.Object, window: ?*intuition.Window, requester: ?*intuition.Requester, msg: *classusr.Msg) u32
```

**SINCE**

1.0. LVO -60.

**INPUTS**

- `object` - a data type object.
- `window`, `requester` - where it is; null when it is in neither.
- `msg` - the method and whatever goes with it.

**RESULT**

What the object answered.

**BEHAVIOR**

The window and requester are put into the message's `GadgetInfo`
where it has one, so that a method that draws or scrolls knows where
the object is. That is the difference between this and sending the
message by hand.

**CONTEXT**

- Waits: whatever the method waits for.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do, unless the method needs more.

**OWNERSHIP**

The message stays the caller's.

**SEE ALSO**

`GetDTMethods`, `GetDTTriggerMethods`

**EXAMPLES**

```zig
var copy = dtc.DtGeneral{ .method_id = dtc.DTM_COPY };
_ = dt.DoDTMethodA(text_object, window, null, @ptrCast(&copy));
```

## DrawDTObjectA

Draws an object into a RastPort of the caller's.

**SYNOPSIS**

```zig
fn DrawDTObjectA(db: *DataTypesBase, rast_port: *graphics.RastPort, object: *classusr.Object, left: i32, top: i32, width: i32, height: i32, top_horiz: i32, top_vert: i32, attrs: ?[*]const utility.TagItem) bool
```

**SINCE**

1.0. LVO -76.

**INPUTS**

- `rast_port` - where to draw.
- `object` - a data type object, made ready with
  `ObtainDTDrawInfoA`.
- `left`, `top`, `width`, `height` - the box to draw into.
- `top_horiz`, `top_vert` - where in the object to start, in its own
  units.
- `attrs` - anything more the class understands; null for none.

**RESULT**

True when it drew.

**BEHAVIOR**

It is `DTM_DRAW` sent to the object. This is how an object is drawn
somewhere other than its own window - into a bitmap, into another
window, into a part of one - and it does not need the object to be a
gadget of anything.

**CONTEXT**

- Waits: whatever the class waits for.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

`ObtainDTDrawInfoA` first, or a class that has work to do before it
can draw will refuse.

**SEE ALSO**

`ObtainDTDrawInfoA`, `ReleaseDTDrawInfo`

**EXAMPLES**

```zig
_ = dt.DrawDTObjectA(rp, picture, 0, 0, 320, 200, 0, 0, null);
```

## GetDTAttrsA

Reads attributes from an object.

**SYNOPSIS**

```zig
fn GetDTAttrsA(db: *DataTypesBase, object: ?*classusr.Object, attrs: ?[*]const utility.TagItem) u32
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `object` - a data type object; null answers 0.
- `attrs` - each tag's data is a pointer to where the value goes.

**RESULT**

How many were answered.

**BEHAVIOR**

A tag the object does not know is left alone and not counted, so a
program can ask for more than a class may have.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

What is answered - a name, a font - belongs to the object and lasts
as long as it does.

**SEE ALSO**

`SetDTAttrsA`

**EXAMPLES**

```zig
var total: usize = 0;
var visible: usize = 0;
_ = dt.GetDTAttrsA(picture, &.{
    .{ .tag = dtc.DTA_TotalVert, .data = @intFromPtr(&total) },
    .{ .tag = dtc.DTA_VisibleVert, .data = @intFromPtr(&visible) },
    .{},
});
```

## GetDTMethods

Answers the methods an object knows.

**SYNOPSIS**

```zig
fn GetDTMethods(db: *DataTypesBase, object: *classusr.Object) ?[*]const u32
```

**SINCE**

1.0. LVO -64.

**INPUTS**

- `object` - a data type object.

**RESULT**

An array of method numbers ending in `~0`, or null when the object
does not say.

**BEHAVIOR**

It is `DTA_Methods` read. A program uses it to grey out what an
object cannot do - no Copy for an object that does not answer
`DTM_COPY`.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The array belongs to the object.

**SEE ALSO**

`GetDTTriggerMethods`, `DoDTMethodA`

**EXAMPLES**

```zig
var at = dt.GetDTMethods(object);
while (at) |list| : (at = list + 1) { if (list[0] == ~@as(u32, 0)) break; }
```

## GetDTString

Answers the text of one of the library's messages.

**SYNOPSIS**

```zig
fn GetDTString(db: *DataTypesBase, id: u32) [*:0]const u8
```

**SINCE**

1.0. LVO -84.

**INPUTS**

- `id` - a `DTERROR_` number, or a `GID_` group.

**RESULT**

The text, which is never null: a number nothing is written for
answers an empty string.

**BEHAVIOR**

The words are the library's own and are the same for everyone.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The text belongs to the library and lasts as long as it is open.

**NOTES**

A group's name is here as well as an error's, so that a program
listing what it can open says "picture" rather than four characters.

**SEE ALSO**

`NewDTObjectA`, `ObtainDataTypeA`

**EXAMPLES**

```zig
_ = Printf(dl, "%s: %s\n", .{ name, dt.GetDTString(@intCast(dl.IoErr())) });
```

## GetDTTriggerMethods

Answers what an object can be told to do, with a name for each.

**SYNOPSIS**

```zig
fn GetDTTriggerMethods(db: *DataTypesBase, object: *classusr.Object) ?[*]const dtc.DTMethod
```

**SINCE**

1.0. LVO -68.

**INPUTS**

- `object` - a data type object.

**RESULT**

An array of `DTMethod` ending in one with a null label, or null when
the object says nothing.

**BEHAVIOR**

It is `DTA_TriggerMethods` read. Each entry carries a name to put in
a menu and the `STM_` number to send with `DTM_TRIGGER`, so a
program shows what an object offers - Play, Pause, Rewind - without
knowing what kind of object it is.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The array belongs to the object.

**SEE ALSO**

`GetDTMethods`, `DoDTMethodA`

**EXAMPLES**

```zig
var at = dt.GetDTTriggerMethods(object);
while (at) |list| : (at = list + 1) { const label = list[0].label orelse break; }
```

## NewDTObjectA

Makes an object for what a file holds.

**SYNOPSIS**

```zig
fn NewDTObjectA(db: *DataTypesBase, name: ?[*:0]const u8, attrs: ?[*]const utility.TagItem) ?*classusr.Object
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `name` - the file's name, or null when `DTA_Handle` says where the
  contents are.
- `attrs` - `DTA_SourceType` (`DTST_FILE` unless given),
  `DTA_GroupID` to refuse anything of another group, `DTA_Handle`,
  and any attribute of the object's own class. `GA_Left` and its
  like place the object in the window it will be added to.

**RESULT**

The object, or null with `IoErr` saying why:
`DTERROR_UNKNOWN_DATATYPE` when nothing recognises the file or its
class cannot be loaded, `DTERROR_COULDNT_OPEN` when the file cannot
be opened, `ERROR_OBJECT_WRONG_TYPE` when it is not of the group
that was asked for.

**BEHAVIOR**

The file is recognised (`ObtainDataTypeA`), its class library is
opened and the object is made of that class. From then on the object
owns the source: the lock for a file, the open handle for the
clipboard, and it closes them when it is disposed of.

`DTST_CLIPBOARD` takes the clipboard's unit number in place of a
name, and the object reads the IFF that is on it.

The class library is closed again straight away. It stays loaded
because it has an object, and goes when the last one is disposed of.

**CONTEXT**

- Waits: on the file, for memory, and for the class library to load.
- Interrupts: no.
- Locks: none needed.
- Process: needed - the file is reached through dos.

**OWNERSHIP**

The object is the caller's, to give back with `DisposeDTObject`.
`name` is copied.

**NOTES**

The object is a gadget: it is not shown until `AddDTObject` puts it
in a window, or until a layout it was put in is laid out.

**SEE ALSO**

`DisposeDTObject`, `AddDTObject`, `ObtainDataTypeA`

**EXAMPLES**

```zig
const picture = dt.NewDTObjectA("SYS:Tests/a.iff", &.{
    .{ .tag = gc.GA_Left, .data = 4 },
    .{ .tag = gc.GA_Top, .data = 4 },
    .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_PICTURE },
    .{},
}) orelse return;
defer dt.DisposeDTObject(picture);
```

## ObtainDTDrawInfoA

Makes an object ready to draw somewhere that is not its window.

**SYNOPSIS**

```zig
fn ObtainDTDrawInfoA(db: *DataTypesBase, object: *classusr.Object, attrs: ?[*]const utility.TagItem) ?*anyopaque
```

**SINCE**

1.0. LVO -72.

**INPUTS**

- `object` - a data type object.
- `attrs` - what the drawing will need; null for the object's own
  idea.

**RESULT**

A handle to give to `DrawDTObjectA` and back to
`ReleaseDTDrawInfo`, or null when the object cannot be drawn that
way.

**BEHAVIOR**

It is `DTM_OBTAINDRAWINFO` sent to the object. A class that has to
get ready - a picture that must be turned into the screen's pixels -
does it here, once, so that drawing the object many times costs that
work once.

**CONTEXT**

- Waits: whatever the class waits for; a picture waits for memory.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

What is answered is the object's and is given back with
`ReleaseDTDrawInfo`.

**SEE ALSO**

`DrawDTObjectA`, `ReleaseDTDrawInfo`

**EXAMPLES**

```zig
const handle = dt.ObtainDTDrawInfoA(picture, null) orelse return;
defer dt.ReleaseDTDrawInfo(picture, handle);
```

## ObtainDataTypeA

Says what kind of file something is.

**SYNOPSIS**

```zig
fn ObtainDataTypeA(db: *DataTypesBase, source_type: u32, handle: ?*anyopaque, attrs: ?[*]const utility.TagItem) ?*datatypes.DataType
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `source_type` - `DTST_FILE` with a `*dos.FileLock` as the handle,
  or `DTST_CLIPBOARD` with an `*IFFHandle` already opened for
  reading and walked as far as its first form.
- `handle` - the lock or the handle.
- `attrs` - `DTA_GroupID` refuses anything not of that group; null
  for no conditions.

**RESULT**

The data type, or null when nothing recognises it - `IoErr` is then
`DTERROR_UNKNOWN_DATATYPE` - or when `C:AddDataTypes` has not run.

**BEHAVIOR**

The descriptors are tried in the order they were sorted into, highest
priority first, and the first that matches wins. A descriptor
matches on the type of the file's outermost IFF form, on the bytes
it starts with, on its name, or on all of those; one that says none
of them catches whatever is left of its kind, which is how plain
text and plain bytes are named at the end.

A descriptor whose class knows how to tell (`RECOGNISE`) has its
class library opened and asked, but only after everything else it
says has already matched.

The file is opened and read once and every descriptor is tried
against that one reading.

**CONTEXT**

- Waits: on the file, and on the list's lock.
- Interrupts: no.
- Locks: none needed.
- Process: needed - the file is reached through dos.

**OWNERSHIP**

The lock or handle stays the caller's. What is answered is the
system's and is held until `ReleaseDataType`; a descriptor being
held cannot be taken off the list.

**NOTES**

`NewDTObjectA` does this itself, so a program that only wants to open
a file never calls it. It is for a program that wants to know what a
file is without reading it - a file requester showing only pictures.

**SEE ALSO**

`ReleaseDataType`, `NewDTObjectA`

**EXAMPLES**

```zig
const lock = dl.Lock("SYS:Tests/a.iff", dos.SHARED_LOCK) orelse return;
defer dl.UnLock(lock);
if (dt.ObtainDataTypeA(dtc.DTST_FILE, lock, null)) |kind| {
    defer dt.ReleaseDataType(kind);
    // kind.header.name says what it is
}
```

## RefreshDTObjectA

Draws an object again.

**SYNOPSIS**

```zig
fn RefreshDTObjectA(db: *DataTypesBase, object: ?*classusr.Object, window: ?*intuition.Window, requester: ?*intuition.Requester, attrs: ?[*]const utility.TagItem) void
```

**SINCE**

1.0. LVO -52.

**INPUTS**

- `object` - a data type object, in a window.
- `window`, `requester` - where it is.
- `attrs` - set on the object first; null for none.

**RESULT**

None.

**BEHAVIOR**

The attributes are set and the object is drawn whole. It is what a
program calls after adding an object to a window, and after anything
it did to the window that the object would not have heard about.

**CONTEXT**

- Waits: for the window's layer.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**SEE ALSO**

`AddDTObject`, `SetDTAttrsA`

**EXAMPLES**

```zig
dt.RefreshDTObjectA(picture, window, null, null);
```

## ReleaseDTDrawInfo

Gives back what `ObtainDTDrawInfoA` answered.

**SYNOPSIS**

```zig
fn ReleaseDTDrawInfo(db: *DataTypesBase, object: *classusr.Object, handle: ?*anyopaque) void
```

**SINCE**

1.0. LVO -80.

**INPUTS**

- `object` - the object it came from.
- `handle` - what `ObtainDTDrawInfoA` answered; null does nothing.

**RESULT**

None.

**BEHAVIOR**

It is `DTM_RELEASEDRAWINFO` sent to the object, which frees whatever
it got ready.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The handle must not be used afterwards.

**SEE ALSO**

`ObtainDTDrawInfoA`, `DrawDTObjectA`

**EXAMPLES**

```zig
dt.ReleaseDTDrawInfo(picture, handle);
```

## ReleaseDataType

Lets go of a data type.

**SYNOPSIS**

```zig
fn ReleaseDataType(db: *DataTypesBase, dt: ?*datatypes.DataType) void
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `dt` - what `ObtainDataTypeA` answered; null does nothing.

**RESULT**

None.

**BEHAVIOR**

The descriptor is not freed - it belongs to the list `C:AddDataTypes`
published - but it is no longer counted as held, and once nothing
holds it it may be taken off the list again.

**CONTEXT**

- Waits: on the list's lock, briefly.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands. The pointer must not be used afterwards.

**NOTES**

An object made by `NewDTObjectA` holds its data type for as long as
it lives and lets go of it when it is disposed of, so a program that
only makes objects never calls this.

**SEE ALSO**

`ObtainDataTypeA`, `DisposeDTObject`

**EXAMPLES**

```zig
dt.ReleaseDataType(kind);
```

## RemoveDTObject

Takes an object out of its window.

**SYNOPSIS**

```zig
fn RemoveDTObject(db: *DataTypesBase, window: ?*intuition.Window, object: ?*classusr.Object) i32
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `window` - the window it is in.
- `object` - a data type object.

**RESULT**

How many gadgets are left in the window, or -1 when there was
nothing to take out.

**BEHAVIOR**

The object is told first (`DTM_REMOVEDTOBJECT`), which is where a
class stops whatever it had running - a sound playing, an animation
- and then it is taken off the window's gadget list. It is not
disposed of: it can be put into another window.

**CONTEXT**

- Waits: for the window's layer, and for whatever the object stops.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The object stays the caller's.

**SEE ALSO**

`AddDTObject`, `DisposeDTObject`

**EXAMPLES**

```zig
_ = dt.RemoveDTObject(window, picture);
```

## SetDTAttrsA

Sets attributes on an object.

**SYNOPSIS**

```zig
fn SetDTAttrsA(db: *DataTypesBase, object: ?*classusr.Object, window: ?*intuition.Window, requester: ?*intuition.Requester, attrs: ?[*]const utility.TagItem) u32
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `object` - a data type object; null does nothing.
- `window`, `requester` - where it is, so that it can draw itself
  again; null when it is in neither.
- `attrs` - what to set.

**RESULT**

Nonzero when something changed that shows.

**BEHAVIOR**

It is `SetGadgetAttrsTagList` with the object's own attributes: a
scroller's new `DTA_TopVert` set here moves the view and draws it.
Without a window the attributes are set and nothing is drawn.

**CONTEXT**

- Waits: whatever the object waits for.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands; what the tags point at stays the caller's.

**SEE ALSO**

`GetDTAttrsA`, `RefreshDTObjectA`

**EXAMPLES**

```zig
_ = dt.SetDTAttrsA(picture, window, null, &.{
    .{ .tag = dtc.DTA_TopVert, .data = @bitCast(@as(isize, top)) },
    .{},
});
```
