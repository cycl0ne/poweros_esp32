# asl.library

asl.library's functions: the requesters a program asks a question
with. Open it with OpenLibrary("asl.library", 1).

The table is this library's own: it is not on any other system's, so
it starts at the first slot after the standard four and holds only
what is here.

Generated from the source by `./zig build autodoc`.

## Index

- [AllocAslRequest](#allocaslrequest) - A requester of `kind`, set up from `tags`.
- [AslRequest](#aslrequest) - A requester put up, and answered or given up.
- [FreeAslRequest](#freeaslrequest) - A requester given back, with everything it was answered with.

## AllocAslRequest

A requester of `kind`, set up from `tags`.

**SYNOPSIS**

```zig
fn AllocAslRequest(ab: *AslBase, kind: u32, tags: ?[*]const TagItem) ?*anyopaque
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `ab` - asl.library's base.
- `kind` - `ASL_FileRequest`, `ASL_FontRequest` or
  `ASL_ScreenModeRequest`.
- `tags` - what the requester starts as; null for none. `AslRequest`
  reads the same tags and may change any of them for one showing.

**RESULT**

The requester, which is the request structure of that kind, or null
for a kind it does not know or no memory.

**BEHAVIOR**

The structure is the library's: the program reads it and never writes
it or frees it. It holds what the requester was answered with until
the next `AslRequest` on it or until `FreeAslRequest`, so a requester
asked twice opens where it was left - same place, same size, same
drawer, file and pattern.

A file requester starts with its three fields empty unless
`ASLFR_InitialFile`, `ASLFR_InitialDrawer` or `ASLFR_InitialPattern`
says otherwise, and with no place of its own, so the first showing is
put in the middle of the screen it opens on.

**CONTEXT**

- Waits: for memory.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The requester is the caller's to free with `FreeAslRequest`. Every
pointer the tags give - the title, the patterns, the hooks - stays the
caller's and must outlive the requester; the three text fields are
copied into the requester's own buffers.

**NOTES**

The tags of the three kinds share their numbers where they mean the
same thing, and have their own meanings where they do not, so the kind
is what decides how a number is read.

**SEE ALSO**

`AslRequest`, `FreeAslRequest`

**EXAMPLES**

```zig
const req: *asl.FileRequester = @ptrCast(@alignCast(ab.AllocAslRequest(asl.ASL_FileRequest, &.{
    .{ .tag = asl.ASLFR_TitleText, .data = @intFromPtr("Open") },
    .{ .tag = asl.ASLFR_InitialDrawer, .data = @intFromPtr("SYS:") },
    .{},
}) orelse return));
defer ab.FreeAslRequest(req);
```

## AslRequest

A requester put up, and answered or given up.

**SYNOPSIS**

```zig
fn AslRequest(ab: *AslBase, requester: *anyopaque, tags: ?[*]const TagItem) bool
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `ab` - asl.library's base.
- `requester` - what `AllocAslRequest` made.
- `tags` - what to change about it for this showing; null to put it up
  as it stands. They are the tags `AllocAslRequest` takes, and what
  they set stays set for the requests after this one.

**RESULT**

True when the requester was answered, false when it was given up -
the Cancel button, the close gadget, Ctrl-C - or could not be shown.

**BEHAVIOR**

The requester opens on the screen of `ASLFR_Window`, or on
`ASLFR_Screen`, or on the public screen `ASLFR_PubScreenName` names,
or on the default public screen; with `ASLFR_SleepWindow` the parent
window shows the busy pointer and takes no input while it is up. It
opens where it was left the time before, at the size it was left, so
a program that asks twice asks in the same place.

The call runs the requester on the caller's process and returns when
the user has answered: it does not come back to the program in
between, which is why a program with a window of its own hands one in
(`ASLFR_Window`) rather than leaving it to look stopped.

A drawer is read while the requester is up rather than before it
shows, so a drawer of some thousands of entries can be answered as
soon as the wanted one is there.

What it was answered with is in the request structure and holds until
the next call on that requester or until `FreeAslRequest`.

**CONTEXT**

- Waits: for input, for the screen, and for the drawer to be read.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Process, not a bare Task: it opens a window and reads a
  drawer.

**OWNERSHIP**

Everything the requester makes is its own and goes at the next request
or at `FreeAslRequest`. The locks of a multi-select answer are the
library's: they are not to be unlocked by the program.

**NOTES**

The font and the screen mode requesters answer false for now: only the
file requester is built (`todo/asl` 6 and 7).

**SEE ALSO**

`AllocAslRequest`, `FreeAslRequest`

**EXAMPLES**

```zig
if (ab.AslRequest(req, &.{
    .{ .tag = asl.ASLFR_TitleText, .data = @intFromPtr("Save as") },
    .{ .tag = asl.ASLFR_DoSaveMode, .data = 1 },
    .{},
})) save(req.drawer, req.file);
```

## FreeAslRequest

A requester given back, with everything it was answered with.

**SYNOPSIS**

```zig
fn FreeAslRequest(ab: *AslBase, requester: ?*anyopaque) void
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `ab` - asl.library's base.
- `requester` - what `AllocAslRequest` made; null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The request structure goes with it: every pointer the program read out
of it - the file, the drawer, the pattern, the names of a multi-select
answer and the locks with them - is gone once this returns, so a
program that wants to keep an answer copies it first.

**CONTEXT**

- Waits: for memory to be given back.
- Interrupts: no.
- Locks: takes asl's requester lock, a spinlock, while the requester is
  taken off the list.
- Process: a Task will do.

**OWNERSHIP**

What the tags handed the requester stays the caller's and is not
touched.

**SEE ALSO**

`AllocAslRequest`, `AslRequest`

**EXAMPLES**

```zig
ab.FreeAslRequest(req);
```
