# hid.library

hid.library's functions: a keyboard's or a mouse's report descriptor
read, and each of its reports made into keys, moves and buttons for
keyboard.device and mouse.device (sdk.hid). Open it with
OpenLibrary("hid.library", 1).

Generated from the source by `./zig build autodoc`.

## Index

- [CloseHID](#closehid) - Gives a function back: its sources let go of whatever keys and buttons the device still held, and are closed.
- [HIDInput](#hidinput) - Hands one of a device's input reports to its function: its keys, media keys, moves, buttons and wheel go to keyboard.device and mouse.device as events.
- [OpenHID](#openhid) - Makes a function for a device by its report descriptor: the sources of what the descriptor describes opened, for its reports to be handed to with HIDInput.

## CloseHID

Gives a function back: its sources let go of whatever keys and buttons the device still held, and are closed.

**SYNOPSIS**

```zig
fn CloseHID(base: *HIDBase, function: ?*hid.HIDFunction) void
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `function` - OpenHID's, or null.

**RESULT**

None.

**BEHAVIOR**

keyboard.device and mouse.device are closed for the function, each
letting go of what its source held down, so no key stays pressed and
no button held for a device that has gone. A port the function made
for itself is deleted. Null does nothing.

**CONTEXT**

- Waits: yes, while the sources close.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do: the one the function's reply port belongs
  to.

**OWNERSHIP**

The function is gone once the call returns.

**BUGS**

None known.

**SEE ALSO**

`OpenHID`, `HIDInput`

**EXAMPLES**

```zig
hb.CloseHID(function);
```

## HIDInput

Hands one of a device's input reports to its function: its keys, media keys, moves, buttons and wheel go to keyboard.device and mouse.device as events.

**SYNOPSIS**

```zig
fn HIDInput(base: *HIDBase, function: *hid.HIDFunction, report: [*]const u8,
    length: u32) void
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `function` - OpenHID's.
- `report`, `length` - the report as the device's descriptor lays it
  out: its ID first where the descriptor gives its reports IDs - a
  transport that carries the ID beside the report puts it back in
  front - or the boot protocol's report for a function with HIDF_BOOT.

**RESULT**

None.

**BEHAVIOR**

A report the keyboard's layout reads becomes the key-ups and then the
key-downs from the keys the last one held to the keys this one holds,
each a RAWKEY event; a report of too many keys at once changes
nothing. When Caps Lock goes down, the keyboard's Caps Lock light
changes: its LEDs' output report goes to HIDA_OutputHook. A report the
consumer control's layout reads becomes the media keys that went up
and then down since its last report, each a RAWKEY event. A report the
mouse's layout reads becomes a move - or a tablet's place - each
button that changed, and the wheel's notches. The events go to their
source in one request. A report of an ID none reads is let go.

**CONTEXT**

- Waits: yes, while a source takes the events, and in the hook.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do: the one the function's reply port belongs
  to.

**OWNERSHIP**

The report stays the caller's: nothing of it is kept.

**NOTES**

The hook is called on this task, within the call, with an
HIDOutputMessage that is the library's until it returns.

**BUGS**

Only Caps Lock's light is kept; Num Lock's and Scroll Lock's stay dark.

**SEE ALSO**

`OpenHID`, `CloseHID`

**EXAMPLES**

```zig
// A report that came on the device's interrupt endpoint.
hb.HIDInput(function, &buffer, actual);
```

## OpenHID

Makes a function for a device by its report descriptor: the sources of what the descriptor describes opened, for its reports to be handed to with HIDInput.

**SYNOPSIS**

```zig
fn OpenHID(base: *HIDBase, descriptor: ?[*]const u8, length: u32,
    tags: ?[*]const utility.TagItem) ?*hid.HIDFunction
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `descriptor`, `length` - the device's report descriptor, as it gives
  it; null for a device that has none.
- `tags` - HIDA_Boot, a boot interface's kind (HIDBOOT_KEYBOARD,
  HIDBOOT_MOUSE); HIDA_OutputHook, the hook an output report goes to;
  HIDA_ReplyPort, the port the sources' requests reply to.

**RESULT**

The function; its `flags` say what it drives - HIDF_KEYBOARD,
HIDF_MOUSE, HIDF_TABLET, HIDF_CONSUMER - and HIDF_BOOT where it reads
the boot protocol's report. Null where the descriptor describes
nothing the library drives, a source does not open, or there is no
memory.

**BEHAVIOR**

The descriptor's first keyboard collection, its first mouse
collection and its first consumer control are read: where each
report keeps its keys - as bits, as slots of usages - its buttons, its
move or its place, and its wheel, a keyboard's LEDs' output report,
and where a consumer control's report keeps its media keys - play,
pause, stop, previous, next, rewind, fast forward, mute, the volume
down and up. A keyboard or a consumer control makes the function a
source of keyboard.device, a mouse or a tablet one of mouse.device,
and a descriptor with several all of them, its reports told apart by
their IDs; a consumer control whose reports cannot be told from the
keyboard's or the mouse's is passed over. With HIDA_Boot, where the
descriptor does not describe that kind, the function reads the boot
protocol's report of it and nothing else, and says so with HIDF_BOOT:
the driver then puts the device in the boot protocol. The sources' requests reply to HIDA_ReplyPort, or to a port
the function makes for the task that calls OpenHID.

**CONTEXT**

- Waits: yes, while the sources open.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The function is the library's until CloseHID; the descriptor stays the
caller's and is not kept. The hook and the port must outlast the
function.

**NOTES**

HIDInput and CloseHID are called on the task the reply port belongs to:
HIDA_ReplyPort's, or that of the task that called OpenHID. A driver
that opens its functions on one task and reads its devices on another
names a port of the second.

**BUGS**

A collection past the first keyboard, the first mouse and the first
consumer control - a second mouse, a system control's power and sleep
keys - is not read.

**SEE ALSO**

`HIDInput`, `CloseHID`

**EXAMPLES**

```zig
const tags = [_]utility.TagItem{
    .{ .tag = hid.HIDA_ReplyPort, .data = @intFromPtr(port) },
    .{ .tag = hid.HIDA_OutputHook, .data = @intFromPtr(&output_hook) },
    .{ .tag = utility.TAG_DONE, .data = 0 },
};
const function = hb.OpenHID(descriptor.ptr, @intCast(descriptor.len), &tags) orelse return false;
```
