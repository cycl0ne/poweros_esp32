# Commodities

A commodity is a program that watches the input stream and acts on it:
a hotkey that brings a program up, a blanker that waits for the keys to
go quiet, a key turned into a string of others. `commodities.library`,
in `LIBS:`, puts itself on input.device's handler chain, at priority 53
- before the windowing system (50) and the console (45) - and sends
every event through a network of objects the commodities have built
before any window sees it.

This guide is the network first, then a commodity, the descriptions
filters are written in, the objects, messages inside the network,
events added to the stream, a controller, and how the library runs.
`sdk.commodities` holds the shapes and the helpers, the calls are in the
[autodocs](../autodocs/commodities.md).

## The network

The network is a list of **brokers**, one for each program taking part,
the highest priority first. Under each broker hangs the program's own
tree of objects, each with a list of its own:

| Object | Made with | What it does with an event |
|---|---|---|
| filter | `cx.CxFilter(cb, "ctrl alt h")` | sends it down its own list when it matches a description |
| sender | `cx.CxSender(cb, port, id)` | puts a copy on the program's port, with `id` |
| signal | `cx.CxSignal(cb, task, signal)` | signals the task |
| translator | `cx.CxTranslate(cb, events)` | puts its own events in place of it; null swallows it |
| custom | `cx.CxCustom(cb, function, id)` | calls a function of the program's |
| debug | `cx.CxDebug(cb, id)` | prints it on the serial console |
| broker | `cb.CxBroker(&new_broker, &err)` | sends it down its own list |

An event starts at the first broker. An object it is diverted into - a
broker, a filter that matched - sends it through its own list first,
then on to the object after it; when the list of the brokers is done,
the event has come out of the network and goes on down input.device's
chain. A disabled object lets everything pass as if it were not there,
and a new broker starts disabled.

The handler is on the chain only while a broker exists: a program that
only reads the list of brokers costs the input stream nothing.

## A commodity

A broker is made from a `NewBroker`: a name (up to 23 characters), a
title and a description for a controller to show (39 each), what to do
about a second broker of the name, the program's port for commands, and
its priority, -128 to 127.

```zig
const cx = sdk.commodities;

const port = sys.CreateMsgPort() orelse return;
defer sys.DeleteMsgPort(port);
var err: i32 = 0;
const broker = cb.CxBroker(&.{
    .name = "Clock",
    .title = "Clock",
    .descr = "Shows the time on a hotkey",
    .unique = cx.NBU_UNIQUE | cx.NBU_NOTIFY,
    .port = port,
}, &err) orelse return; // err: CBERR_DUP when a Clock runs already
defer {
    cb.DeleteCxObjAll(broker);
    while (sys.GetMsg(port)) |msg| sys.ReplyMsg(msg);
}
cb.AttachCxObj(broker, cx.HotKey(cb, "ctrl alt c", port, 1));
if (cb.CxObjError(broker) != 0) return; // no memory
_ = cb.ActivateCxObj(broker, true);
```

`unique` is `NBU_DUPLICATE` for any number of brokers of a name,
`NBU_UNIQUE` to refuse a second one (`CBERR_DUP`), and `NBU_NOTIFY` to
tell the first with a `CXCMD_UNIQUE` command when a second tries; with
both, a program started twice is refused and the running one hears of
it - and can come to the front, say. `CBERR_VERSION` is a NewBroker
whose `version` is not `NB_VERSION`, `CBERR_SYSERR` no memory.

`cx.HotKey` is three objects: a filter for the description, a sender
under it with the id, and a translator with no events after the sender,
so the key reaches the program and nothing else. A description that
makes no sense leaves the filter with `COERR_BADFILTER` and matching
nothing; `cb.ParseIX` says so before.

The program then waits on its port. Every message on it is replied to:

```zig
while (running) {
    const got = sys.Wait(port.sigMask() | exec.SIGBREAKF_CTRL_C);
    if (got & exec.SIGBREAKF_CTRL_C != 0) running = false;
    while (sys.GetMsg(port)) |msg| {
        const cxm = cx.CxMsg.from(msg);
        const kind = cb.CxMsgType(cxm);
        const id = cb.CxMsgID(cxm);
        sys.ReplyMsg(msg);
        if (kind == cx.CXM_IEVENT) {
            // id 1: the hotkey
        } else switch (id) {
            cx.CXCMD_DISABLE => _ = cb.ActivateCxObj(broker, false),
            cx.CXCMD_ENABLE => _ = cb.ActivateCxObj(broker, true),
            cx.CXCMD_APPEAR, cx.CXCMD_UNIQUE => {}, // show the window
            cx.CXCMD_DISAPPEAR => {}, // hide it
            cx.CXCMD_KILL => running = false,
            else => {},
        }
    }
}
```

A `CXM_IEVENT` message carries a copy of the event (`cb.CxMsgData`,
valid until the reply) and the sender's id. A `CXM_COMMAND` message is
an order from a controller: its id is the command. A program whose
broker has no port gets Ctrl-E for `CXCMD_KILL` instead and no other
command; a broker with a window to show and hide says so with
`COF_SHOW_HIDE` in the NewBroker's `flags`.

Before the program ends it deletes its broker with everything under it
and replies to whatever is still on its port - the `defer` above.

## Descriptions

A filter matches what a description says, read by `cb.ParseIX` into an
`InputXpression`:

    [class] {[-]qualifier} [[-]upstroke] [key or button]

Case does not matter, and spaces, tabs, commas and new lines separate
the words.

- **Class:** `RAWKEY` (when none is given), `RAWMOUSE`, `TOUCH`, `TIMER`,
  `NEWPOINTERPOS`, `ACTIVEWINDOW`, `INACTIVEWINDOW`, `DISKINSERTED`,
  `DISKREMOVED`, `NEWPREFS`, `EVENT`, `USB`.
- **Qualifiers** must be held: `LSHIFT`, `RSHIFT`, `CAPSLOCK`,
  `CONTROL` (`CTRL`), `LALT`, `RALT`, `LCOMMAND`, `RCOMMAND`,
  `NUMERICPAD` (`NUMPAD`), `REPEAT`, `LBUTTON`, `MBUTTON`, `RBUTTON`,
  `RELATIVEMOUSE`, and spelt out: `LEFT_SHIFT`, `LEFT_COMMAND`,
  `MIDDLE_BUTTON` and the like. `SHIFT`, `ALT` and `CAPS` are either of
  a pair (`CAPS`: either shift or Caps Lock). Every qualifier not named
  must not be held - but for `RELATIVEMOUSE` - and one named with `-` in
  front may be held or not.
- **`UPSTROKE`** matches the key going up, `-UPSTROKE` either way;
  without it, the key going down.
- **The key:** `F1` to `F12`, `ESC`, `TAB`, `RETURN`, `ENTER` (the
  keypad's), `SPACE`, `BACKSPACE`, `DEL`, `HELP`, `INSERT`, `HOME`,
  `END`, `PAGE_UP`, `PAGE_DOWN`, `UP`, `DOWN`, `LEFT`, `RIGHT`, `COMMA`,
  `BREAK` - or one character, the key that types it on the default
  keymap with the qualifiers that takes (`ctrl A` is Control and shift
  with A); with `NUMERICPAD`, a digit is the keypad's.
- **The button**, for `RAWMOUSE`: `MOUSE_LEFTPRESS`,
  `MOUSE_MIDDLEPRESS`, `MOUSE_RIGHTPRESS`, `MOUSE_WHEEL`. The button's
  own qualifier - held on its press, not on its release - does not
  count.

A description that names no key takes any code: `ctrl` is any key with
Control held, down or up; `rawmouse -lbutton -mbutton -rbutton` every
mouse event with no key held; `touch -lbutton` every finger - the first
finger down holds the left button.

| Description | Matches |
|---|---|
| `ctrl alt h` | H going down with Control and an Alt, nothing else held |
| `-capslock lcommand f1` | F1 with the left command key, Caps Lock on or not |
| `shift upstroke space` | the space bar let go with a shift held |
| `numericpad 5` | the keypad's 5 |
| `rawmouse mouse_rightpress` | the right button pressed, no other button or key held |
| `rawmouse lbutton mouse_rightpress` | the right button pressed while the left is held |
| `touch -lbutton` | a finger landing, moving or lifting, no key held |

ParseIX answers 0 when every word made sense, -1 when words were left
over that did not (a key it does not know, a second key), and -2 for a
null or empty description, whose expression matches nothing.
`cb.MatchIX(&event, &ix)` asks whether an event matches.

An expression can be written by hand and given to a filter with
`cb.SetFilterIX`: `code_mask` says which bits of the code count,
`qual_mask` which qualifiers, `qual_same` which synonyms widen them.

```zig
// F1 to F8, nothing held: the low three bits do not count.
cb.SetFilterIX(filter, &.{ .code = kbd.RAWKEY_F1, .code_mask = 0xF8 });
```

A class of `IECLASS_NULL` matches every event. Caps Lock is a qualifier
like the others: a hotkey that should work with it on says `-caps`.

## The objects

`cb.AttachCxObj(head, co)` puts an object at the end of another's
list, `cb.EnqueueCxObj` by its priority (`cb.SetCxObjPri`),
`cb.InsertCxObj(head, co, pred)` after `pred` (null: first).
`cb.RemoveCxObj` takes it off again, `cb.DeleteCxObj` frees one object,
`cb.DeleteCxObjAll` one with everything under it, a broker taking itself
off the list.

The calls take what an earlier call made, null included, so a tree can
be built without a check after each line; the errors collect in the
object they happened to (`cb.CxObjError`, `cb.ClearCxObjError`):

| Bit | Meaning |
|---|---|
| `COERR_ISNULL` | `CxObjError` of null |
| `COERR_NULLATTACH` | null was attached: an object could not be made |
| `COERR_BADFILTER` | the filter's description makes no sense; it matches nothing |
| `COERR_BADTYPE` | a call for one kind of object given another |

Attaching to a null head deletes the object attached, with all under it.

`cb.SetFilter` and `cb.SetFilterIX` change a filter, `cb.SetTranslate`
a translator's events, while the network runs. A translator's events
stay the program's, and must stay until it is deleted or given others;
they come out in their order, at the time of the event they replace.
`cx.InvertString` makes such a list.

A **custom** object's function runs on input.device's task, inside the
network, with the library's base, the message and the object:

```zig
/// Every key as if Caps Lock were off.
fn noCapsLock(cb: *CxBase, cxm: *cx.CxMsg, _: *cx.CxObj) callconv(.c) void {
    const event = cb.CxMsgData(cxm) orelse return;
    if (event.class == ie.IECLASS_RAWKEY) event.qualifier &= ~ie.IEQUALIFIER_CAPSLOCK;
}

cb.AttachCxObj(broker, cx.CxCustom(cb, &noCapsLock, 0));
```

Like an input handler it may not wait: it may look at and change the
event, route, divert and dispose of the message, add events and signal -
nothing that makes or deletes objects. `CxMsgID` is the object's id
while it runs.

## Messages inside the network

From a custom function, `cb.RouteCxMsg(cxm, co)` sends the message on
to `co` instead of the next object, `cb.DivertCxMsg(cxm, head, back)`
through `head`'s list and then on after `back`, and
`cb.DisposeCxMsg(cxm)` takes it out of the stream. A message that has
been through 1024 objects is in a loop, and leaves the network as it
is.

## Adding events

`cb.AddIEvents(events)` puts copies of a list of events into the
stream, in front of the first broker, so they pass every commodity - its
own filters too: a hotkey that types itself loops. From a program they
go at the handler's next round (the timer ticks ten times a second),
from a custom function in the same round, after the events already in
it.

`cb.InvertKeyMap(character, &event, keymap)` makes the key event that
types one character; a dead key and its key come as one event with the
dead key as the key before (`event.x`). `cx.InvertString` makes a list
from a string - each character by its key, `\n` and `\r` Return, `\t`
Tab, `\\` a backslash, and `<description>` the event a description
names, `<alt f>`:

```zig
const typed = cx.InvertString(sys, cb, "Kind regards,\\n", null) orelse return;
defer cx.FreeIEvents(sys, typed);
cb.AddIEvents(typed); // copied: freed after
```

The events go to whatever is active: the window with the keyboard.

## A controller

A program that lists the commodities and orders them about:

```zig
var brokers: exec.List = .{};
brokers.init(.unknown);
_ = cb.CopyBrokerList(&brokers);
defer cb.FreeBrokerList(&brokers);
var it = brokers.iterator();
while (it.next()) |node| {
    const copy: *cx.BrokerCopy = @ptrCast(@alignCast(node));
    // copy.node.name, copy.title, copy.descr, copy.flags & cx.COF_ACTIVE
}
_ = cb.BrokerCommand("Clock", cx.CXCMD_APPEAR);
```

`BrokerCommand` finds the broker by its exact name and answers
`CMDE_OK`, `CMDE_NOBROKER`, `CMDE_NOPORT` (a program that takes no
commands: KILL reaches it as Ctrl-E) or `CMDE_NOMEM`. When a broker is
made, deleted, enabled or disabled, the library sends
`CXCMD_LIST_CHG` to the broker called "Exchange" - the controller - so
it reads the list again; `BrokerCommand(null, id)` sends it there too.

## How it runs

Every call that changes the network takes the network's lock for that
change only. The handler, which may not wait, only tries for it: while a
program has it, the handler keeps the round's events and gives nothing
on, and passes them through at its next round, in order, so a hotkey is
never lost and nothing overtakes.

The events the network gives back are the library's, read by the
handlers after it, and freed at its next round; a message a program
replies to is freed then too. When the last broker goes, the handler
comes off the chain and frees what it kept. The library stays in memory
while a broker exists, opened or not: the handler is its code.

## C:test/Commodities

    Commodities LIST/S,BROKER/K,COMMAND/K,HOTKEY/K,TYPE/K,PRI/K/N

With nothing asked for it is a commodity, "CxTest": a hotkey (HOTKEY,
`ctrl alt c` when none is given) that it prints each press of, until
Ctrl-C or a KILL; with TYPE each press types the string as well, in
InvertString's form. A second CxTest is refused, and the first told.
`LIST` prints the commodities running; `BROKER` with `COMMAND` sends
one a command: DISABLE, ENABLE, APPEAR, DISAPPEAR, KILL or UNIQUE.

```
1.System:> Run C:test/Commodities HOTKEY=f2 TYPE="echo typed\n"
1.System:> C:test/Commodities LIST
CxTest                  active   Commodities test - Prints a hotkey, types a string
1.System:> C:test/Commodities BROKER=CxTest COMMAND=KILL
```

`C:test/Input KEY=81` presses F2 down input.device's chain from a shell,
where no keyboard is at hand.
