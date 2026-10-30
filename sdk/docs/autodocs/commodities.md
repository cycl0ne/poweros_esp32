# commodities.library

commodities.library's functions: programs that watch the input stream
and act on it - a hotkey, a blanker, a key turned into a string -
through a network of objects every event passes before the windows
see it. Open it with OpenLibrary("commodities.library", 1).

The table is this library's own: it starts at the first slot after
the standard four and holds only what is here.

Generated from the source by `./zig build autodoc`.

## Index

- [ActivateCxObj](#activatecxobj) - Turns an object on or off.
- [AddIEvents](#addievents) - Puts copies of events into the network, as though a device had made them.
- [AttachCxObj](#attachcxobj) - Puts an object at the end of another object's list.
- [BrokerCommand](#brokercommand) - Sends a command to the program of the broker of a name.
- [ClearCxObjError](#clearcxobjerror) - Forgets the errors an object has recorded.
- [CopyBrokerList](#copybrokerlist) - Copies every broker onto a list of the caller's.
- [CreateCxObj](#createcxobj) - Makes a new object of the network.
- [CxBroker](#cxbroker) - Makes a broker and puts it on the network's list.
- [CxMsgData](#cxmsgdata) - Answers the input event a commodity message carries.
- [CxMsgID](#cxmsgid) - Answers the id a commodity message carries.
- [CxMsgType](#cxmsgtype) - Says what kind of message a commodity message is.
- [CxObjError](#cxobjerror) - Answers the errors an object has recorded.
- [CxObjType](#cxobjtype) - Says what kind of object an object is.
- [DeleteCxObj](#deletecxobj) - Takes an object off its list and frees it.
- [DeleteCxObjAll](#deletecxobjall) - Takes an object off its list and frees it with everything attached to it, and everything attached to those.
- [DisposeCxMsg](#disposecxmsg) - Takes a commodity message out of the network.
- [DivertCxMsg](#divertcxmsg) - Sends a commodity message down an object's list, and on from another object once the list is done.
- [EnqueueCxObj](#enqueuecxobj) - Puts an object into another object's list by its priority.
- [FreeBrokerList](#freebrokerlist) - Gives back the copies CopyBrokerList put on a list.
- [InsertCxObj](#insertcxobj) - Puts an object into another object's list after a given one.
- [InvertKeyMap](#invertkeymap) - Fills in the key event that types a character.
- [MatchIX](#matchix) - Says whether an event meets an input expression.
- [ParseIX](#parseix) - Reads a description - "ctrl alt f1", "rawmouse lbutton mouse_rightpress" - into an input expression.
- [RemoveCxObj](#removecxobj) - Takes an object off whatever list it is on.
- [RouteCxMsg](#routecxmsg) - Sets the object a commodity message goes to next.
- [SetCxObjPri](#setcxobjpri) - Sets an object's priority, which EnqueueCxObj places it by.
- [SetFilter](#setfilter) - Sets a filter's condition from a description.
- [SetFilterIX](#setfilterix) - Sets a filter's condition from an input expression.
- [SetTranslate](#settranslate) - Sets the events a translator puts in place of each message it gets.

## ActivateCxObj

Turns an object on or off.

**SYNOPSIS**

```zig
fn ActivateCxObj(base: *CxBase, co: ?*cx.CxObj, active: bool) bool
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `co` - the object; null does nothing.
- `active` - true to turn it on, false off.

**RESULT**

Whether it was on; false for null.

**BEHAVIOR**

An object that is off does nothing with what reaches it: the message
goes on to the object after it. Every object starts on, a broker off -
a program builds its tree under the broker and then turns the broker
on, so no event meets half a tree. A broker turned on or off is told
to the controller (CXCMD_LIST_CHG).

**CONTEXT**

- Waits: for the network's lock.
- Interrupts: no.
- Locks: takes the network's lock.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

It is what a program does for CXCMD_DISABLE and CXCMD_ENABLE.

**BUGS**

None known.

**SEE ALSO**

`CxBroker`, `BrokerCommand`

**EXAMPLES**

```zig
cx.CXCMD_DISABLE => _ = cb.ActivateCxObj(broker, false),
cx.CXCMD_ENABLE => _ = cb.ActivateCxObj(broker, true),
```

## AddIEvents

Puts copies of events into the network, as though a device had made them.

**SYNOPSIS**

```zig
fn AddIEvents(base: *CxBase, events: ?*const ie.InputEvent) void
```

**SINCE**

1.0. LVO -116.

**INPUTS**

- `events` - a list linked by `next`; null does nothing.

**RESULT**

None.

**BEHAVIOR**

Each event is copied into a message, in the list's order. The
messages go to the first broker in the handler's next round - the
next event from a device, or the tick, a tenth of a second at most -
ahead of that round's own events, and through the whole network as
those do. Called from a custom object's function they join the round
that is under way, behind the messages already in it. Memory running
out ends the copying where it is.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: takes the library's queue spinlock for a moment.
- Process: a Task will do; a custom object's function may call it.

**OWNERSHIP**

The events stay the caller's, and may go as soon as the call is back.

**NOTES**

With no broker the library has no handler on input.device's chain,
and the events wait for the first one: IND_WRITEEVENT to input.device
is the way in then.

**BUGS**

None known.

**SEE ALSO**

`InvertString`, `InvertKeyMap`

**EXAMPLES**

```zig
const typed = cx.InvertString(sys, cb, "hello\n", null) orelse return;
defer cx.FreeIEvents(sys, typed);
cb.AddIEvents(typed);
```

## AttachCxObj

Puts an object at the end of another object's list.

**SYNOPSIS**

```zig
fn AttachCxObj(base: *CxBase, head_obj: ?*cx.CxObj, co: ?*cx.CxObj) void
```

**SINCE**

1.0. LVO -56.

**INPUTS**

- `head_obj` - the object whose list it joins; null deletes `co` and
  everything attached to it.
- `co` - the object; null is recorded in `head_obj` as
  COERR_NULLATTACH.

**RESULT**

None.

**BEHAVIOR**

`co` goes last on `head_obj`'s list: a message diverted into
`head_obj` reaches it after everything attached before. Taking either
side as null lets a tree be built from calls that make objects
without checking each: an object that could not be made shows as an
error in the one it was to join, and one with nowhere to go is not
left behind.

**CONTEXT**

- Waits: for the network's lock.
- Interrupts: no.
- Locks: takes the network's lock.
- Process: a Task will do.

**OWNERSHIP**

`co` stays the caller's; DeleteCxObjAll of anything above it deletes
it too.

**NOTES**

An object is on one list at a time: take it off one (RemoveCxObj)
before attaching it to another.

**BUGS**

None known.

**SEE ALSO**

`EnqueueCxObj`, `InsertCxObj`, `RemoveCxObj`, `CxObjError`

**EXAMPLES**

```zig
cb.AttachCxObj(broker, filter);
cb.AttachCxObj(filter, cx.CxSender(cb, port, 1));
cb.AttachCxObj(filter, cx.CxTranslate(cb, null));
if (cb.CxObjError(filter) != 0) return error.NoMemory;
```

## BrokerCommand

Sends a command to the program of the broker of a name.

**SYNOPSIS**

```zig
fn BrokerCommand(base: *CxBase, name: ?[*:0]const u8, id: i32) i32
```

**SINCE**

1.0. LVO -128.

**INPUTS**

- `name` - the broker's name, as its NewBroker gave it; null is the
  controller's, "Exchange".
- `id` - the command: CXCMD_DISABLE, CXCMD_ENABLE, CXCMD_APPEAR,
  CXCMD_DISAPPEAR, CXCMD_KILL, CXCMD_UNIQUE or CXCMD_LIST_CHG.

**RESULT**

CMDE_OK when it was sent; CMDE_NOBROKER for no broker of the name,
CMDE_NOPORT for one without a port, CMDE_NOMEM without memory.

**BEHAVIOR**

A CXM_COMMAND message with `id` goes to the broker's port; the program
replies to it and does what it says - the library does nothing to the
broker itself. A broker without a port gets nothing, except that a
CXCMD_KILL is Ctrl-E to the task that made it. Of two brokers of one
name, the first on the list gets it.

**CONTEXT**

- Waits: for the network's lock.
- Interrupts: no.
- Locks: takes the network's lock.
- Process: a Task will do.

**OWNERSHIP**

The message is the program's until it replies.

**NOTES**

It is how a controller - a window, or a command in a shell - shows,
hides, turns off and ends the programs on the list. The library sends
the controller CXCMD_LIST_CHG itself whenever the list changes.

**BUGS**

None known.

**SEE ALSO**

`CopyBrokerList`, `CxBroker`, `ActivateCxObj`

**EXAMPLES**

```zig
if (cb.BrokerCommand("Blanker", cx.CXCMD_KILL) == cx.CMDE_NOBROKER) notRunning();
```

## ClearCxObjError

Forgets the errors an object has recorded.

**SYNOPSIS**

```zig
fn ClearCxObjError(base: *CxBase, co: ?*cx.CxObj) void
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `co` - the object; null does nothing.

**RESULT**

None.

**BEHAVIOR**

CxObjError answers 0 afterwards. Nothing about the object changes
otherwise: a filter whose condition made no sense still matches
nothing.

**CONTEXT**

- Waits: for the network's lock.
- Interrupts: no.
- Locks: takes the network's lock.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

A filter is put right with a new condition (SetFilter), which clears
COERR_BADFILTER itself.

**BUGS**

None known.

**SEE ALSO**

`CxObjError`

**EXAMPLES**

```zig
cb.ClearCxObjError(broker);
```

## CopyBrokerList

Copies every broker onto a list of the caller's.

**SYNOPSIS**

```zig
fn CopyBrokerList(base: *CxBase, list: *exec.List) i32
```

**SINCE**

1.0. LVO -120.

**INPUTS**

- `list` - an initialised list; what CopyBrokerList put on it before
  is freed first.

**RESULT**

How many brokers were copied.

**BEHAVIOR**

A `BrokerCopy` for each broker goes on the end of `list`, in the
network's order, highest priority first: its name (the node's name),
title, description, task, port, and in `flags` COF_ACTIVE and
COF_SHOW_HIDE. Memory running out ends the copy where it is.

**CONTEXT**

- Waits: for the network's lock.
- Interrupts: no.
- Locks: takes the network's lock.
- Process: a Task will do.

**OWNERSHIP**

The copies are the caller's, to give back with FreeBrokerList. They
are a moment's picture: a broker may go while the caller reads its
copy, so a copy's task and port are for reading, not for use.

**NOTES**

A controller copies the list again on each CXCMD_LIST_CHG.

**BUGS**

None known.

**SEE ALSO**

`FreeBrokerList`, `BrokerCommand`

**EXAMPLES**

```zig
var list: exec.List = .{};
list.init(.unknown);
_ = cb.CopyBrokerList(&list);
defer cb.FreeBrokerList(&list);
var it = list.iterator();
while (it.next()) |node| show(@as(*cx.BrokerCopy, @ptrCast(node)));
```

## CreateCxObj

Makes a new object of the network.

**SYNOPSIS**

```zig
fn CreateCxObj(base: *CxBase, kind: u32, arg1: usize, arg2: usize) ?*cx.CxObj
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `kind` - CX_FILTER, CX_SEND, CX_SIGNAL, CX_TRANSLATE, CX_BROKER,
  CX_DEBUG or CX_CUSTOM.
- `arg1`, `arg2` - what the kind needs: a filter's description (or
  0); a sender's port and id; a signal object's task and signal
  number; a translator's events (or 0); a broker's NewBroker; a debug
  object's id; a custom object's function and id.

**RESULT**

The object, active - a broker inactive - and on no list; null without
memory, for a kind there is none of, and for a broker without a
NewBroker.

**BEHAVIOR**

Programs call it through the SDK's CxFilter, CxSender, CxSignal,
CxTranslate, CxDebug and CxCustom, and CxBroker for a broker, which
also puts it on the network's list. A filter's description is parsed
at once (SetFilter): one that makes no sense still makes the filter,
with COERR_BADFILTER recorded in it, matching nothing.

**CONTEXT**

- Waits: for the network's lock, only for a filter.
- Interrupts: no.
- Locks: takes the network's lock for a filter's condition.
- Process: a Task will do.

**OWNERSHIP**

The object is the caller's, to attach to a broker's tree or delete
(DeleteCxObj, DeleteCxObjAll). A translator's events and a sender's
port stay the caller's and must outlast the object.

**NOTES**

An object attached under a broker is deleted with it by
DeleteCxObjAll, which is how a program usually ends.

**BUGS**

None known.

**SEE ALSO**

`CxBroker`, `AttachCxObj`, `DeleteCxObjAll`, `CxObjError`

**EXAMPLES**

```zig
const filter = cx.CxFilter(cb, "rawkey ctrl alt f1");
cb.AttachCxObj(broker, filter);
cb.AttachCxObj(filter, cx.CxSender(cb, port, 1));
```

## CxBroker

Makes a broker and puts it on the network's list.

**SYNOPSIS**

```zig
fn CxBroker(base: *CxBase, nb: *const cx.NewBroker, err: ?*i32) ?*cx.CxObj
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `nb` - what the broker is: its name, its title and description for
  the controller, what to do about a broker of the same name, its
  priority, its port for commands. Copied: it may go once the call is
  back.
- `err` - where to put why it failed, or null.

**RESULT**

The broker, inactive; null when it is not made. `err` gets CBERR_OK,
CBERR_SYSERR (no memory), CBERR_DUP (`nb.unique` has NBU_UNIQUE and a
broker of the name is there) or CBERR_VERSION (`nb.version` is not
NB_VERSION).

**BEHAVIOR**

A broker of the name already there is sent CXCMD_UNIQUE when
`nb.unique` has NBU_NOTIFY - the usual answer is for that program to
show its window - and with NBU_UNIQUE no second one is made. The new
broker goes on the network's list by its priority, highest first. The
first broker puts the library's handler on input.device's chain, at
priority 53, before the windowing system; any other is told to the
controller (CXCMD_LIST_CHG). The broker stays inactive until
ActivateCxObj, so a program builds its tree first.

**CONTEXT**

- Waits: for the network's lock, and for input.device for the first
  broker.
- Interrupts: no.
- Locks: takes the network's lock.
- Process: a Task will do; never a custom object's function. The
  calling task is the broker's: CXCMD_KILL is Ctrl-E to it when the
  broker has no port.

**OWNERSHIP**

The broker is the caller's, to delete with DeleteCxObjAll before it
ends; everything attached to it goes with it.

**NOTES**

The name is how BrokerCommand and the controller find the program:
one that should run once gives NBU_UNIQUE | NBU_NOTIFY and ends when
it gets CBERR_DUP.

**BUGS**

None known.

**SEE ALSO**

`ActivateCxObj`, `DeleteCxObjAll`, `BrokerCommand`, `CopyBrokerList`

**EXAMPLES**

```zig
var why: i32 = 0;
const broker = cb.CxBroker(&.{
    .name = "Clock", .title = "Clock", .descr = "The time on a key",
    .unique = cx.NBU_UNIQUE | cx.NBU_NOTIFY, .port = port,
}, &why) orelse return if (why == cx.CBERR_DUP) dos.RETURN_OK else dos.RETURN_FAIL;
```

## CxMsgData

Answers the input event a commodity message carries.

**SYNOPSIS**

```zig
fn CxMsgData(base: *CxBase, cxm: ?*cx.CxMsg) ?*ie.InputEvent
```

**SINCE**

1.0. LVO -92.

**INPUTS**

- `cxm` - a message, or null.

**RESULT**

The message's event; null for a command and for a null message.

**BEHAVIOR**

The event is inside the message. A custom object's function may change
it, and what it changes is what the rest of the network and the
windows see; a sender's copy is the program's to read, and changing it
changes nothing else. Its `next` is null: each message carries one
event.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do; a custom object's function may call it.

**OWNERSHIP**

The event goes with the message: a sender's is not to be read once the
message is replied to, a custom object's not after its function
returns.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`CxMsgType`, `DisposeCxMsg`

**EXAMPLES**

```zig
fn noCaps(cb: *cx.CxBase, cxm: *cx.CxMsg, _: *cx.CxObj) callconv(.c) void {
    const event = cb.CxMsgData(cxm) orelse return;
    event.qualifier &= ~ie.IEQUALIFIER_CAPSLOCK;
}
```

## CxMsgID

Answers the id a commodity message carries.

**SYNOPSIS**

```zig
fn CxMsgID(base: *CxBase, cxm: *const cx.CxMsg) i32
```

**SINCE**

1.0. LVO -96.

**INPUTS**

- `cxm` - a message from a sender, or the one a custom object's
  function was given; not null.

**RESULT**

For an event the id of the sender that sent it, or of the custom
object whose function has it; for a command the command, CXCMD_.

**BEHAVIOR**

The id is what the program gave the object when it made it, so one
port can take the messages of several senders - a hotkey each - and
tell them apart. An event no object gave an id has 0.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do; a custom object's function may call it.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

Ids other than 0 make a message nobody sent stand out.

**BUGS**

None known.

**SEE ALSO**

`CxMsgType`, `CreateCxObj`

**EXAMPLES**

```zig
if (cb.CxMsgType(cxm) == cx.CXM_IEVENT and cb.CxMsgID(cxm) == hotkey_id) showWindow();
```

## CxMsgType

Says what kind of message a commodity message is.

**SYNOPSIS**

```zig
fn CxMsgType(base: *CxBase, cxm: *const cx.CxMsg) u32
```

**SINCE**

1.0. LVO -88.

**INPUTS**

- `cxm` - a message from a sender, or the one a custom object's
  function was given; not null.

**RESULT**

CXM_IEVENT for an input event, CXM_COMMAND for an order from the
controller.

**BEHAVIOR**

A sender's messages and a custom object's are events; a broker's port
gets both kinds when the program gives its senders the same port, so
the kind is the first thing a program looks at.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do; a custom object's function may call it.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

Read it before replying: a replied message is the library's again.

**BUGS**

None known.

**SEE ALSO**

`CxMsgID`, `CxMsgData`

**EXAMPLES**

```zig
while (sys.GetMsg(port)) |msg| {
    const cxm = cx.CxMsg.from(msg);
    const kind = cb.CxMsgType(cxm);
    const id = cb.CxMsgID(cxm);
    sys.ReplyMsg(msg);
    if (kind == cx.CXM_COMMAND and id == cx.CXCMD_KILL) done = true;
}
```

## CxObjError

Answers the errors an object has recorded.

**SYNOPSIS**

```zig
fn CxObjError(base: *CxBase, co: ?*cx.CxObj) u32
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `co` - the object, or null.

**RESULT**

COERR_ bits, 0 for none; COERR_ISNULL for null - the object was never
made.

**BEHAVIOR**

A call that fails on an object records why in it rather than
answering: COERR_NULLATTACH when a null object was attached to it,
COERR_BADFILTER while its condition makes no sense, COERR_BADTYPE when
a call for another kind was made on it. The bits stay until
ClearCxObjError, except COERR_BADFILTER, which the next condition that
makes sense clears. So a tree is built without a check after every
call, and checked once at the end.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

A bad description in a filter attached to a broker is the filter's
error, not the broker's: look at the filter.

**BUGS**

None known.

**SEE ALSO**

`ClearCxObjError`, `AttachCxObj`, `SetFilter`

**EXAMPLES**

```zig
const filter = cx.HotKey(cb, description, port, 1) orelse return;
if (cb.CxObjError(filter) & cx.COERR_BADFILTER != 0) return badHotkey(description);
```

## CxObjType

Says what kind of object an object is.

**SYNOPSIS**

```zig
fn CxObjType(base: *CxBase, co: ?*cx.CxObj) u32
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `co` - the object, or null.

**RESULT**

CX_FILTER ... CX_CUSTOM; CX_INVALID for null.

**BEHAVIOR**

The kind it was made as; it never changes.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do; a custom object's function may call it.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

A program knows what it made; this is for code handed an object.

**BUGS**

None known.

**SEE ALSO**

`CreateCxObj`

**EXAMPLES**

```zig
if (cb.CxObjType(co) == cx.CX_FILTER) cb.SetFilter(co, "ctrl alt x");
```

## DeleteCxObj

Takes an object off its list and frees it.

**SYNOPSIS**

```zig
fn DeleteCxObj(base: *CxBase, co: ?*cx.CxObj) void
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `co` - the object; null does nothing.

**RESULT**

None.

**BEHAVIOR**

The object is taken off whatever list it is on (RemoveCxObj) and
freed. What is attached to it is not: those objects are on no list in
the network any more, and are the caller's to delete. A broker's going
is told to the controller, and the last broker's takes the library's
handler off input.device's chain.

**CONTEXT**

- Waits: for the network's lock, and for input.device when it was the
  last broker.
- Interrupts: no.
- Locks: takes the network's lock.
- Process: a Task will do; never a custom object's function.

**OWNERSHIP**

The object is gone.

**NOTES**

A whole tree goes with DeleteCxObjAll.

**BUGS**

None known.

**SEE ALSO**

`DeleteCxObjAll`, `RemoveCxObj`

**EXAMPLES**

```zig
cb.DeleteCxObj(old_filter);
```

## DeleteCxObjAll

Takes an object off its list and frees it with everything attached to it, and everything attached to those.

**SYNOPSIS**

```zig
fn DeleteCxObjAll(base: *CxBase, co: ?*cx.CxObj) void
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `co` - the top of the tree; null does nothing.

**RESULT**

None.

**BEHAVIOR**

The object is taken off its list (RemoveCxObj), which takes its whole
tree out of the network at once; then every object in it is freed. A
broker's going is told to the controller, and the last broker's takes
the library's handler off input.device's chain.

**CONTEXT**

- Waits: for the network's lock, and for input.device when it was the
  last broker.
- Interrupts: no.
- Locks: takes the network's lock.
- Process: a Task will do; never a custom object's function.

**OWNERSHIP**

Every object of the tree is gone. Translators' events and senders'
ports stay the caller's; messages a sender sent are still to be
replied to.

**NOTES**

A program's broker deleted this way is all a program has to undo in
the library before it ends, besides replying to its messages.

**BUGS**

None known.

**SEE ALSO**

`DeleteCxObj`, `CxBroker`

**EXAMPLES**

```zig
cb.DeleteCxObjAll(broker);
while (sys.GetMsg(port)) |msg| sys.ReplyMsg(msg);
```

## DisposeCxMsg

Takes a commodity message out of the network.

**SYNOPSIS**

```zig
fn DisposeCxMsg(base: *CxBase, cxm: *cx.CxMsg) void
```

**SINCE**

1.0. LVO -108.

**INPUTS**

- `cxm` - the message a custom object's function was given.

**RESULT**

None.

**BEHAVIOR**

The message is freed: its event goes to no further object and never
reaches the windows. It is how a custom object swallows an event.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: the network's, already held by the handler that called the
  custom object's function.
- Process: a custom object's function, on input.device's task.

**OWNERSHIP**

The message is gone; neither it nor its event may be touched after.

**NOTES**

A message from a sender is not disposed of: it is replied to
(ReplyMsg), and the library frees it.

**BUGS**

None known.

**SEE ALSO**

`CxCustom`, `CxTranslate`

**EXAMPLES**

```zig
fn eatF10(cb: *cx.CxBase, cxm: *cx.CxMsg, _: *cx.CxObj) callconv(.c) void {
    const event = cb.CxMsgData(cxm) orelse return;
    if (event.class == ie.IECLASS_RAWKEY and event.code == kbd.RAWKEY_F10) cb.DisposeCxMsg(cxm);
}
```

## DivertCxMsg

Sends a commodity message down an object's list, and on from another object once the list is done.

**SYNOPSIS**

```zig
fn DivertCxMsg(base: *CxBase, cxm: *cx.CxMsg, head_obj: *cx.CxObj, return_obj: *cx.CxObj) void
```

**SINCE**

1.0. LVO -100.

**INPUTS**

- `cxm` - the message a custom object's function was given.
- `head_obj` - the object whose list it goes down.
- `return_obj` - the object it goes on after when that list is done.

**RESULT**

None.

**BEHAVIOR**

The message's next object is the first on `head_obj`'s list, and
`return_obj` goes on the message's stack: at the end of the list the
message goes to the object after `return_obj`. It is what a filter
does with an event that matches - `DivertCxMsg(cxm, filter, filter)` -
and a broker with every event.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none taken; the network's lock is held by the handler that
  called the custom object's function.
- Process: a custom object's function, on input.device's task.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

The stack holds 32 objects; a message diverted deeper than that goes
on, at the end of the deepest lists, to where the 32nd would have
sent it.

**BUGS**

None known.

**SEE ALSO**

`RouteCxMsg`, `CxCustom`

**EXAMPLES**

```zig
// A custom filter: only events with the pointer on the left half.
if (event.x < half) cb.DivertCxMsg(cxm, co, co);
```

## EnqueueCxObj

Puts an object into another object's list by its priority.

**SYNOPSIS**

```zig
fn EnqueueCxObj(base: *CxBase, head_obj: ?*cx.CxObj, co: ?*cx.CxObj) void
```

**SINCE**

1.0. LVO -60.

**INPUTS**

- `head_obj` - the object whose list it joins; null deletes `co` and
  everything attached to it.
- `co` - the object; null is recorded in `head_obj` as
  COERR_NULLATTACH.

**RESULT**

None.

**BEHAVIOR**

The list is kept highest priority first; `co` goes before the first
object of a lower priority, so objects of one priority stay in the
order they came. The priority is SetCxObjPri's, 0 for an object never
given one. Otherwise as AttachCxObj.

**CONTEXT**

- Waits: for the network's lock.
- Interrupts: no.
- Locks: takes the network's lock.
- Process: a Task will do.

**OWNERSHIP**

`co` stays the caller's; DeleteCxObjAll of anything above it deletes
it too.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`SetCxObjPri`, `AttachCxObj`, `InsertCxObj`

**EXAMPLES**

```zig
_ = cb.SetCxObjPri(first_look, 10);
cb.EnqueueCxObj(broker, first_look);
```

## FreeBrokerList

Gives back the copies CopyBrokerList put on a list.

**SYNOPSIS**

```zig
fn FreeBrokerList(base: *CxBase, list: *exec.List) void
```

**SINCE**

1.0. LVO -124.

**INPUTS**

- `list` - a list CopyBrokerList filled.

**RESULT**

None; the list is empty.

**BEHAVIOR**

Every node is taken off and freed.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed: the list is the caller's.
- Process: a Task will do.

**OWNERSHIP**

The copies are gone.

**NOTES**

Only BrokerCopy nodes may be on the list.

**BUGS**

None known.

**SEE ALSO**

`CopyBrokerList`

**EXAMPLES**

```zig
cb.FreeBrokerList(&list);
```

## InsertCxObj

Puts an object into another object's list after a given one.

**SYNOPSIS**

```zig
fn InsertCxObj(base: *CxBase, head_obj: ?*cx.CxObj, co: ?*cx.CxObj, pred: ?*cx.CxObj) void
```

**SINCE**

1.0. LVO -64.

**INPUTS**

- `head_obj` - the object whose list it joins; null deletes `co` and
  everything attached to it.
- `co` - the object; null is recorded in `head_obj` as
  COERR_NULLATTACH.
- `pred` - the object on that list it goes after; null puts it first.

**RESULT**

None.

**BEHAVIOR**

As AttachCxObj, at the place given.

**CONTEXT**

- Waits: for the network's lock.
- Interrupts: no.
- Locks: takes the network's lock.
- Process: a Task will do.

**OWNERSHIP**

`co` stays the caller's; DeleteCxObjAll of anything above it deletes
it too.

**NOTES**

`pred` must be on `head_obj`'s list.

**BUGS**

None known.

**SEE ALSO**

`AttachCxObj`, `EnqueueCxObj`

**EXAMPLES**

```zig
cb.InsertCxObj(broker, debug, null); // sees every event first
```

## InvertKeyMap

Fills in the key event that types a character.

**SYNOPSIS**

```zig
fn InvertKeyMap(base: *CxBase, ansi_code: u32, event: *ie.InputEvent, key_map: ?*const keymap.KeyMap) bool
```

**SINCE**

1.0. LVO -112.

**INPUTS**

- `ansi_code` - the character, 0 to 255.
- `event` - where the event goes.
- `key_map` - the keymap, null for the default.

**RESULT**

True when a key makes the character; false otherwise, `event` as it
was.

**BEHAVIOR**

keymap.library's MapANSI says which key makes it, with which
qualifiers - the fewest. The event is an IECLASS_RAWKEY key going
down, subclass, time and address 0. A character made by a dead key and
the key after it is the second key, with the dead key in `x` as a key
event carries the key down before it, so MapRawKey makes the
character from it; otherwise `x` and `y` are 0. `next` is left alone.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do; a custom object's function may call it.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

It is how ParseIX understands a description that ends in a character
("ctrl alt a"), and InvertString a string.

**BUGS**

None known.

**SEE ALSO**

`ParseIX`, `InvertString`, `AddIEvents`

**EXAMPLES**

```zig
var key: ie.InputEvent = .{};
if (cb.InvertKeyMap('a', &key, null)) cb.AddIEvents(&key);
```

## MatchIX

Says whether an event meets an input expression.

**SYNOPSIS**

```zig
fn MatchIX(base: *CxBase, event: *const ie.InputEvent, ix: *const cx.InputXpression) bool
```

**SINCE**

1.0. LVO -132.

**INPUTS**

- `event` - the event.
- `ix` - the expression.

**RESULT**

Whether it matches.

**BEHAVIOR**

An expression of class IECLASS_NULL matches every event. Otherwise
the event's class is the expression's, its code has the expression's
bits wherever `code_mask` has a bit, and its qualifiers have the
expression's wherever `qual_mask` has one - the event's qualifiers
widened first by `qual_same`: with IXSYM_SHIFT either shift held is
both, with IXSYM_CAPS either shift or Caps Lock is all three, with
IXSYM_ALT either alt is both. It is the test every filter makes.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do; a custom object's function may call it.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

A custom object's function uses it to test an event against several
expressions without a filter for each.

**BUGS**

None known.

**SEE ALSO**

`ParseIX`, `SetFilterIX`

**EXAMPLES**

```zig
if (cb.MatchIX(event, &hotkey)) cb.DisposeCxMsg(cxm);
```

## ParseIX

Reads a description - "ctrl alt f1", "rawmouse lbutton mouse_rightpress" - into an input expression.

**SYNOPSIS**

```zig
fn ParseIX(base: *CxBase, description: ?[*:0]const u8, ix: *cx.InputXpression) i32
```

**SINCE**

1.0. LVO -84.

**INPUTS**

- `description` - the words, or null.
- `ix` - where the expression goes.

**RESULT**

0 when every word made sense; -1 when words were left that did not
(the expression is what came before them); -2 for a description that
is null or empty, whose expression matches nothing.

**BEHAVIOR**

The words come in this order, each part optional:

  [class] {[-]qualifier} [[-]upstroke] [key or button]

The class is one of ACTIVEWINDOW, DISKINSERTED, DISKREMOVED, EVENT,
INACTIVEWINDOW, NEWPOINTERPOS, NEWPREFS, RAWKEY, RAWMOUSE, TIMER,
TOUCH or USB; RAWKEY when none is given. Each qualifier named must be
held: LSHIFT, RSHIFT, CAPSLOCK, CONTROL (CTRL), LALT, RALT, LCOMMAND,
RCOMMAND, NUMERICPAD, REPEAT, LEFTBUTTON, MIDBUTTON, RBUTTON,
RELATIVEMOUSE, with LEFT_SHIFT, NUMPAD and the like for the same;
SHIFT, CAPS and ALT are either of a pair (CAPS: either shift or Caps
Lock). Every qualifier not named must not be held, but for
RELATIVEMOUSE; one named with `-` in front may be held or not.
UPSTROKE matches the key going up, -UPSTROKE either way. The key is a
name - F1 to F12, ESC, TAB, RETURN, ENTER, SPACE, BACKSPACE, DEL,
HELP, INSERT, HOME, END, PAGE_UP, PAGE_DOWN, UP, DOWN, LEFT, RIGHT,
COMMA, BREAK - or one character, the key that types it through the
default keymap (with the qualifiers that takes, so "ctrl A" is ctrl
and shift); with a keypad qualifier, the keypad's key of the
character. For RAWMOUSE the button: MOUSE_LEFTPRESS,
MOUSE_MIDDLEPRESS, MOUSE_RIGHTPRESS, MOUSE_WHEEL; the button's own
qualifier, held on its press and not on its release, does not count.
Case does not matter; spaces, tabs, commas and new lines separate
words. A description that names no key or button takes any code:
"ctrl" is any key with Control held, down or up, "rawmouse -lbutton
-mbutton -rbutton" every mouse event with no key held, "touch
-lbutton" every finger; "ctrl upstroke" is any key going up, the only
part of the code that counts then.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

With Caps Lock on, a description that does not name it does not
match: "-caps ctrl alt h" matches either way.

**BUGS**

None known.

**SEE ALSO**

`SetFilter`, `MatchIX`, `InvertKeyMap`

**EXAMPLES**

```zig
var ix: cx.InputXpression = .{};
if (cb.ParseIX("-caps ctrl alt f1", &ix) != 0) return error.BadHotkey;
```

## RemoveCxObj

Takes an object off whatever list it is on.

**SYNOPSIS**

```zig
fn RemoveCxObj(base: *CxBase, co: ?*cx.CxObj) void
```

**SINCE**

1.0. LVO -68.

**INPUTS**

- `co` - the object; null, or one on no list, does nothing.

**RESULT**

None.

**BEHAVIOR**

The object leaves its list with everything attached to it, which stays
attached: the tree is out of the network as a whole. A broker leaves
the network's list; the controller is told (CXCMD_LIST_CHG), and when
it was the last, the library's handler comes off input.device's chain
and events pass the library by.

**CONTEXT**

- Waits: for the network's lock, and for input.device when it was the
  last broker.
- Interrupts: no.
- Locks: takes the network's lock.
- Process: a Task will do; never a custom object's function.

**OWNERSHIP**

The object stays the caller's.

**NOTES**

A message on its way through the tree when it goes is not lost: the
network's lock keeps the handler out until the tree is off.

**BUGS**

None known.

**SEE ALSO**

`AttachCxObj`, `DeleteCxObj`

**EXAMPLES**

```zig
cb.RemoveCxObj(filter);
cb.SetFilter(filter, new_description);
cb.AttachCxObj(broker, filter);
```

## RouteCxMsg

Sets the object a commodity message goes to next.

**SYNOPSIS**

```zig
fn RouteCxMsg(base: *CxBase, cxm: *cx.CxMsg, co: *cx.CxObj) void
```

**SINCE**

1.0. LVO -104.

**INPUTS**

- `cxm` - the message a custom object's function was given.
- `co` - the object it goes to; it must be in the network.

**RESULT**

None.

**BEHAVIOR**

A jump: the message goes on from `co`, through the objects after it,
and its stack of objects to come back to stays as it was.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none taken; the network's lock is held by the handler that
  called the custom object's function.
- Process: a custom object's function, on input.device's task.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

A message routed round in a circle leaves the network after it has
been through 1024 objects.

**BUGS**

None known.

**SEE ALSO**

`DivertCxMsg`, `CxCustom`

**EXAMPLES**

```zig
cb.RouteCxMsg(cxm, other_filter);
```

## SetCxObjPri

Sets an object's priority, which EnqueueCxObj places it by.

**SYNOPSIS**

```zig
fn SetCxObjPri(base: *CxBase, co: ?*cx.CxObj, pri: i32) i32
```

**SINCE**

1.0. LVO -52.

**INPUTS**

- `co` - the object; null does nothing.
- `pri` - -128 to 127, higher first; 0 is the usual. Outside that it
  is the nearest end.

**RESULT**

The priority it had; 0 for null.

**BEHAVIOR**

Only the number changes: an object already on a list stays where it
is. To move it, take it off (RemoveCxObj), set the priority, and put
it back with EnqueueCxObj.

**CONTEXT**

- Waits: for the network's lock.
- Interrupts: no.
- Locks: takes the network's lock.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

A broker's priority comes from its NewBroker; the user is best given
a way to set it (a PRI argument).

**BUGS**

None known.

**SEE ALSO**

`EnqueueCxObj`, `RemoveCxObj`

**EXAMPLES**

```zig
cb.RemoveCxObj(filter);
_ = cb.SetCxObjPri(filter, 10);
cb.EnqueueCxObj(broker, filter);
```

## SetFilter

Sets a filter's condition from a description.

**SYNOPSIS**

```zig
fn SetFilter(base: *CxBase, filter: ?*cx.CxObj, text: ?[*:0]const u8) void
```

**SINCE**

1.0. LVO -76.

**INPUTS**

- `filter` - a filter; null does nothing.
- `text` - the description, as ParseIX reads it.

**RESULT**

None. COERR_BADFILTER is set in the filter when the description makes
no sense or is null, and cleared when it does; COERR_BADTYPE is
recorded in an object that is not a filter.

**BEHAVIOR**

From the next event on, the filter passes down its list the events
that meet the description. While COERR_BADFILTER is set it passes
none: every event goes on to the object after it.

**CONTEXT**

- Waits: for the network's lock.
- Interrupts: no.
- Locks: takes the network's lock.
- Process: a Task will do.

**OWNERSHIP**

The description is read during the call and not kept.

**NOTES**

It is how a program takes a new hotkey from its user while running.
To stop a filter for a while, turn it off (ActivateCxObj).

**BUGS**

None known.

**SEE ALSO**

`ParseIX`, `SetFilterIX`, `CxObjError`

**EXAMPLES**

```zig
cb.SetFilter(filter, new_key);
if (cb.CxObjError(filter) & cx.COERR_BADFILTER != 0) cb.SetFilter(filter, old_key);
```

## SetFilterIX

Sets a filter's condition from an input expression.

**SYNOPSIS**

```zig
fn SetFilterIX(base: *CxBase, filter: ?*cx.CxObj, ix: *const cx.InputXpression) void
```

**SINCE**

1.0. LVO -80.

**INPUTS**

- `filter` - a filter; null does nothing.
- `ix` - the expression; its `version` must be IX_VERSION.

**RESULT**

None. COERR_BADFILTER is set in the filter for an expression of
another version, and cleared otherwise; COERR_BADTYPE is recorded in
an object that is not a filter.

**BEHAVIOR**

The expression is copied into the filter, which from the next event
on passes down its list the events that meet it (MatchIX). An
expression of another version is not copied, and the filter passes
nothing until it gets one it can use.

**CONTEXT**

- Waits: for the network's lock.
- Interrupts: no.
- Locks: takes the network's lock.
- Process: a Task will do.

**OWNERSHIP**

The expression stays the caller's; the filter has its own copy.

**NOTES**

For conditions no description can say: a code mask over several
keys, an event class with a code.

**BUGS**

None known.

**SEE ALSO**

`SetFilter`, `ParseIX`, `MatchIX`

**EXAMPLES**

```zig
// F1 to F8 going down, nothing held: the codes 0x50 to 0x57.
cb.SetFilterIX(filter, &.{ .code = kbd.RAWKEY_F1, .code_mask = 0xF8 });
```

## SetTranslate

Sets the events a translator puts in place of each message it gets.

**SYNOPSIS**

```zig
fn SetTranslate(base: *CxBase, translator: ?*cx.CxObj, events: ?*const ie.InputEvent) void
```

**SINCE**

1.0. LVO -72.

**INPUTS**

- `translator` - a translator; null does nothing.
- `events` - a list of events linked by `next`; null swallows every
  message.

**RESULT**

None; COERR_BADTYPE is recorded in an object that is not a
translator.

**BEHAVIOR**

Each message that reaches the translator is replaced by a message for
each event of the list, in the list's order, each stamped with the
time of the one it replaces and going on from where it would have:
the next object after the translator. With no list, the message is
simply gone. The events are not copied: the library reads the list
every time a message passes.

**CONTEXT**

- Waits: for the network's lock.
- Interrupts: no.
- Locks: takes the network's lock.
- Process: a Task will do.

**OWNERSHIP**

The list stays the caller's, and must not change or go while the
translator has it: set another first.

**NOTES**

InvertString in the SDK makes the list for a string, which is how a
key comes to type a word.

**BUGS**

None known.

**SEE ALSO**

`CxTranslate`, `InvertString`

**EXAMPLES**

```zig
const typed = cx.InvertString(sys, cb, "dir\n", null) orelse return;
cb.SetTranslate(translator, typed);
```
