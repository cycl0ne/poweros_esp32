# iffparse.library

iffparse.library's functions: reading and writing IFF - chunks inside
chunks, each named by four characters. Open it with
OpenLibrary("iffparse.library", 1).

The table is this library's own: it is not on any other system's, so
it starts at the first slot after the standard four and holds only
what is here.

Generated from the source by `./zig build autodoc`.

## Index

- [AllocIFF](#allociff) - Makes a handle for one IFF file.
- [AllocLocalItem](#alloclocalitem) - Makes a local item with room for its own bytes.
- [CloseClipboard](#closeclipboard) - Gives a clipboard handle back.
- [CloseIFF](#closeiff) - Finishes with the file.
- [CollectionChunk](#collectionchunk) - Keeps every such chunk, newest first, to be read back with `FindCollection`.
- [CollectionChunks](#collectionchunks) - Does what `CollectionChunk` does for each of a list of pairs.
- [CurrentChunk](#currentchunk) - Answers the chunk the walk is in.
- [EntryHandler](#entryhandler) - Sets a hook to run when the walk enters a chunk.
- [ExitHandler](#exithandler) - Sets a hook to run when the walk leaves a chunk.
- [FindCollection](#findcollection) - Answers the chunks a collection gathered.
- [FindLocalItem](#findlocalitem) - Finds the nearest stored item of a kind.
- [FindProp](#findprop) - Answers a property chunk that was kept.
- [FindPropContext](#findpropcontext) - Answers the FORM or LIST the walk is inside.
- [FreeIFF](#freeiff) - Gives a handle back.
- [FreeLocalItem](#freelocalitem) - Gives a local item back.
- [GoodID](#goodid) - Says whether four characters may name a chunk.
- [GoodType](#goodtype) - Says whether four characters may name a kind of form.
- [IDtoStr](#idtostr) - Writes an id out as text.
- [InitIFF](#initiff) - Says where a handle's bytes come from.
- [InitIFFasClip](#initiffasclip) - Says a handle's stream is the clipboard.
- [InitIFFasDOS](#initiffasdos) - Says a handle's stream is a file.
- [LocalItemData](#localitemdata) - Answers a local item's own bytes.
- [OpenClipboard](#openclipboard) - Opens clipboard.device, ready to be a handle's stream.
- [OpenIFF](#openiff) - Opens the file for reading or for writing.
- [ParentChunk](#parentchunk) - Answers the chunk a chunk is in.
- [ParseIFF](#parseiff) - Walks on through the file.
- [PopChunk](#popchunk) - Ends the chunk being written.
- [PropChunk](#propchunk) - Keeps the contents of every such chunk, to be read back with `FindProp`.
- [PropChunks](#propchunks) - Does what `PropChunk` does for each of a list of pairs.
- [PushChunk](#pushchunk) - Starts a chunk, for writing.
- [ReadChunkBytes](#readchunkbytes) - Reads bytes of the chunk the walk is in.
- [ReadChunkRecords](#readchunkrecords) - Reads whole records of the chunk the walk is in.
- [SetLocalItemPurge](#setlocalitempurge) - Sets the hook that frees an item instead of the library.
- [StopChunk](#stopchunk) - Stops the walk when it reaches such a chunk.
- [StopChunks](#stopchunks) - Does what `StopChunk` does for each of a list of pairs.
- [StopOnExit](#stoponexit) - Stops the walk when it reaches the end of such a chunk.
- [StoreItemInContext](#storeitemincontext) - Stores an item with a chunk named outright.
- [StoreLocalItem](#storelocalitem) - Stores an item with a chunk.
- [WriteChunkBytes](#writechunkbytes) - Writes bytes into the chunk being written.
- [WriteChunkRecords](#writechunkrecords) - Writes whole records into the chunk being written.

## AllocIFF

Makes a handle for one IFF file.

**SYNOPSIS**

```zig
fn AllocIFF(ib: *IFFParseBase) ?*iffparse.IFFHandle
```

**SINCE**

1.0. LVO -20.

**INPUTS**

None.

**RESULT**

The handle, or null for no memory.

**BEHAVIOR**

The handle comes back empty: it has no stream and is not open. Put
the stream in `iff.stream`, say what kind it is (`InitIFFasDOS`,
`InitIFFasClip` or `InitIFF`), and then open it with `OpenIFF`.

Only this call makes a handle, because the library keeps more behind
it than the three fields a program sees.

**CONTEXT**

- Waits: for memory.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The handle is the caller's to give back with `FreeIFF`, after
`CloseIFF`. The stream behind it is the caller's throughout: the
library never opens or closes a file.

**NOTES**

One handle reads or writes one file at a time. A program reading two
files at once needs two.

**SEE ALSO**

`FreeIFF`, `InitIFFasDOS`, `OpenIFF`

**EXAMPLES**

```zig
const iff = ip.AllocIFF() orelse return;
defer ip.FreeIFF(iff);
```

## AllocLocalItem

Makes a local item with room for its own bytes.

**SYNOPSIS**

```zig
fn AllocLocalItem(ib: *IFFParseBase, form_type: u32, id: u32, ident: u32, data_size: i32) ?*iffparse.LocalContextItem
```

**SINCE**

1.0. LVO -132.

**INPUTS**

- `form_type`, `id` - the chunk the item is about.
- `ident` - what kind of item it is. The library's own are
  `IFFLCI_PROP`, `IFFLCI_COLLECTION`, `IFFLCI_ENTRYHANDLER` and
  `IFFLCI_EXITHANDLER`; a program uses any other four characters.
- `data_size` - bytes of its own, which `LocalItemData` answers with.

**RESULT**

The item, or null for no memory.

**BEHAVIOR**

The item is not stored anywhere yet: `StoreLocalItem` puts it with a
chunk, and until then it is the caller's to free.

Its bytes come back cleared.

**CONTEXT**

- Waits: for memory.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's until it is stored, and the library's after: a stored
item goes when the walk leaves the chunk it was stored with.

**NOTES**

This is how a program keeps something of its own alongside a chunk -
what it has read so far of a form, say - without a list of its own to
walk and clean up.

**SEE ALSO**

`StoreLocalItem`, `FreeLocalItem`, `LocalItemData`, `FindLocalItem`

**EXAMPLES**

```zig
const item = ip.AllocLocalItem(ip.MakeID("ILBM"), ip.MakeID("BMHD"), MY_IDENT, @sizeOf(MyState)) orelse return;
const mine: *MyState = @ptrCast(@alignCast(ip.LocalItemData(item).?));
```

## CloseClipboard

Gives a clipboard handle back.

**SYNOPSIS**

```zig
fn CloseClipboard(ib: *IFFParseBase, clip: ?*iffparse.ClipboardHandle) void
```

**SINCE**

1.0. LVO -164.

**INPUTS**

- `clip` - a handle from `OpenClipboard`; null does nothing.

**RESULT**

None.

**BEHAVIOR**

The device is closed and the two signals go back to the task. Any IFF
handle using it must have been closed first (`CloseIFF`), since that
is what finishes the writing.

**CONTEXT**

- Waits: for clipboard.device to close.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do - the one that opened it.

**OWNERSHIP**

The handle goes.

**NOTES**

The signals belong to the task that opened the handle, so it is that
task that closes it.

**SEE ALSO**

`OpenClipboard`, `CloseIFF`

**EXAMPLES**

```zig
ip.CloseIFF(iff);
ip.CloseClipboard(clip);
```

## CloseIFF

Finishes with the file.

**SYNOPSIS**

```zig
fn CloseIFF(ib: *IFFParseBase, iff: *iffparse.IFFHandle) void
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `iff` - an open handle.

**RESULT**

None.

**BEHAVIOR**

Every chunk still open is popped, which for a file being written
finishes it off - the sizes written back, the held writes sent out.
Everything stored with those chunks goes with them. The stream is
then told `IFFCMD_CLEANUP`.

A pop that fails - a stream that will not seek - stops the popping;
the chunks are then thrown away without being finished, so that the
handle is left clean even when the file is not.

**CONTEXT**

- Waits: whatever the stream hook waits for.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do unless the stream needs a Process.

**OWNERSHIP**

The handle stays the caller's, to open again or to free. The stream
is the caller's to close, after this.

**NOTES**

A program that wants to know whether a file was written whole pops
its own chunks and looks at what `PopChunk` answered: this call
cannot say.

**SEE ALSO**

`OpenIFF`, `FreeIFF`, `PopChunk`

**EXAMPLES**

```zig
ip.CloseIFF(iff);
_ = dl.Close(file);
```

## CollectionChunk

Keeps every such chunk, newest first, to be read back with `FindCollection`.

**SYNOPSIS**

```zig
fn CollectionChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) i32
```

**SINCE**

1.0. LVO -100.

**INPUTS**

- `iff` - an open handle.
- `form_type` - the kind of the chunk's surroundings (`ILBM`), or 0
  to match whatever they are.
- `id` - the chunk's four characters.

**RESULT**

0, or `IFFERR_NOMEM`.

**BEHAVIOR**

Where `PropChunk` keeps the last one it saw, this keeps them all: the
list runs from the newest of this context back through the ones a
context further out gathered. The ones this context gathered go when
the walk leaves it; the rest stay with the context they belong to.

It is set on the chunk the walk is in, so it is asked for before the
walk starts - when the walk is inside nothing, which is the whole
file - or inside a chunk it is to apply to and no further.

**CONTEXT**

- Waits: for memory.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

What is kept belongs to the chunk it was found in and goes when the
walk leaves it.

**NOTES**

It is `EntryHandler` with a handler of the library's own.

**SEE ALSO**

`FindCollection`, `PropChunk`

**EXAMPLES**

```zig
_ = ip.CollectionChunk(iff, ip.MakeID("ILBM"), ip.MakeID("CRNG"));
```

## CollectionChunks

Does what `CollectionChunk` does for each of a list of pairs.

**SYNOPSIS**

```zig
fn CollectionChunks(ib: *IFFParseBase, iff: *iffparse.IFFHandle, list: [*]const u32, pairs: i32) i32
```

**SINCE**

1.0. LVO -104.

**INPUTS**

- `iff` - an open handle.
- `list` - `pairs` * 2 numbers: a type and an id, then the next type
  and id, and so on.
- `pairs` - how many pairs there are.

**RESULT**

0, or what the first pair that failed answered.

**BEHAVIOR**

The pairs are taken in order and the first failure stops the rest, so
a failure leaves some of them set. The handle is closed or the walk
given up either way, so nothing has to be taken back.

**CONTEXT**

- Waits: for memory.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

`list` is only read, and is the caller's.

**NOTES**

It is `CollectionChunk` in a loop, and is here because a class that reads
a format names most of its chunks at once.

**SEE ALSO**

`CollectionChunk`

**EXAMPLES**

```zig
const wanted = [_]u32{
    ip.MakeID("ILBM"), ip.MakeID("BMHD"),
    ip.MakeID("ILBM"), ip.MakeID("CMAP"),
};
_ = ip.CollectionChunks(iff, &wanted, wanted.len / 2);
```

## CurrentChunk

Answers the chunk the walk is in.

**SYNOPSIS**

```zig
fn CurrentChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle) ?*iffparse.ContextNode
```

**SINCE**

1.0. LVO -124.

**INPUTS**

- `iff` - an open handle.

**RESULT**

The chunk, or null before the walk has entered one and after it has
left the outermost.

**BEHAVIOR**

The node says the chunk's `id`, the `type` of the generic chunk it is
in, its `size` and how much of it has been read or written (`scan`).
Where `ParseIFF` has stopped at a chunk, `scan` is 0 and the whole of
it is still to read.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The node is the library's and is gone once the walk leaves the chunk.

**NOTES**

The bottom of the stack is a node of the library's own with no id,
and is never answered: "in no chunk" and "in a chunk with no name"
would otherwise look the same.

**SEE ALSO**

`ParentChunk`, `ParseIFF`, `ReadChunkBytes`

**EXAMPLES**

```zig
const chunk = ip.CurrentChunk(iff) orelse return;
if (chunk.id == ip.MakeID("BODY")) { ... }
```

## EntryHandler

Sets a hook to run when the walk enters a chunk.

**SYNOPSIS**

```zig
fn EntryHandler(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32, position: i32, hook: *utility.Hook, object: ?*anyopaque) i32
```

**SINCE**

1.0. LVO -76.

**INPUTS**

- `iff` - an open handle.
- `form_type` - the kind of the chunk's surroundings (`ILBM`), or 0
  to match whatever they are.
- `id` - the chunk's four characters.
- `position` - where the handler is kept: `IFFSLI_TOP` with the chunk
  the walk is in, `IFFSLI_PROP` with the FORM or LIST it is inside,
  `IFFSLI_ROOT` with the handle, which lasts for the whole file.
- `hook` - called with `object` and an `i32` holding `IFFCMD_ENTRY`.
- `object` - what the hook is called with; null is allowed.

**RESULT**

0, or `IFFERR_NOMEM`, or `IFFERR_NOSCOPE` when `IFFSLI_PROP` is asked
for and the walk is inside no FORM or LIST.

**BEHAVIOR**

The handler runs when `ParseIFF` enters a chunk of that type and id,
before any of it is read. What it answers decides what `ParseIFF`
does: 0 to walk on, `IFF_RETURN2CLIENT` to stop the walk there and
answer the program 0, anything else to stop it with that value.

A handler set at `IFFSLI_TOP` goes when the walk leaves the chunk it
was set in, which is what makes a handler set inside one FORM not
apply to the next.

**CONTEXT**

- Waits: for memory.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The hook and the object stay the caller's and must outlive the chunk
the handler is stored with.

**NOTES**

`PropChunk`, `StopChunk` and `CollectionChunk` are this call with a
handler of the library's own.

**SEE ALSO**

`ExitHandler`, `StopChunk`, `ParseIFF`

**EXAMPLES**

```zig
var hook = utility.Hook{ .entry = &onBody };
_ = ip.EntryHandler(iff, ip.MakeID("ILBM"), ip.MakeID("BODY"), ip.IFFSLI_ROOT, &hook, self);
```

## ExitHandler

Sets a hook to run when the walk leaves a chunk.

**SYNOPSIS**

```zig
fn ExitHandler(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32, position: i32, hook: *utility.Hook, object: ?*anyopaque) i32
```

**SINCE**

1.0. LVO -80.

**INPUTS**

- `iff` - an open handle.
- `form_type` - the kind of the chunk's surroundings, or 0 for any.
- `id` - the chunk's four characters.
- `position` - `IFFSLI_TOP`, `IFFSLI_PROP` or `IFFSLI_ROOT`.
- `hook` - called with `object` and an `i32` holding `IFFCMD_EXIT`.
- `object` - what the hook is called with; null is allowed.

**RESULT**

0, or `IFFERR_NOMEM`, or `IFFERR_NOSCOPE` for `IFFSLI_PROP` with no
FORM or LIST round the walk.

**BEHAVIOR**

The handler runs when the walk reaches the end of such a chunk, while
it is still the current one, which is the last moment at which
anything stored inside it can be read. What it answers decides what
`ParseIFF` does, as an entry handler's does.

**CONTEXT**

- Waits: for memory.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The hook and the object stay the caller's.

**NOTES**

`StopOnExit` is this call with a handler of the library's own.

**SEE ALSO**

`EntryHandler`, `StopOnExit`, `ParseIFF`

**EXAMPLES**

```zig
var hook = utility.Hook{ .entry = &formDone };
_ = ip.ExitHandler(iff, ip.MakeID("ILBM"), ip.ID_FORM, ip.IFFSLI_ROOT, &hook, self);
```

## FindCollection

Answers the chunks a collection gathered.

**SYNOPSIS**

```zig
fn FindCollection(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) ?*iffparse.CollectionItem
```

**SINCE**

1.0. LVO -116.

**INPUTS**

- `iff` - an open handle.
- `form_type`, `id` - the chunk, as they were given to
  `CollectionChunk`.

**RESULT**

The newest such chunk, each linked to the one before it through
`next`; null when none were gathered.

**BEHAVIOR**

The list runs newest first and crosses out of the chunk the walk is
in: after the ones this `FORM` gathered come the ones the `LIST`
outside it gathered. A program that wants them in the order they
stood in the file walks the list and turns it round.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The items are the library's; each goes when the walk leaves the chunk
that gathered it.

**NOTES**

Each item's bytes are the chunk's as they lie in the file.

**SEE ALSO**

`CollectionChunk`, `FindProp`

**EXAMPLES**

```zig
var at = ip.FindCollection(iff, ip.MakeID("ILBM"), ip.MakeID("CRNG"));
while (at) |item| : (at = item.next) { ... }
```

## FindLocalItem

Finds the nearest stored item of a kind.

**SYNOPSIS**

```zig
fn FindLocalItem(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32, ident: u32) ?*iffparse.LocalContextItem
```

**SINCE**

1.0. LVO -148.

**INPUTS**

- `iff` - an open handle.
- `form_type`, `id` - the chunk the item is about.
- `ident` - what kind of item it is.

**RESULT**

The item, or null when no such item is stored where the walk now is.

**BEHAVIOR**

The search runs from the chunk the walk is in outwards, so an item
stored on a chunk hides one of the same kind stored further out. That
is what makes a `PROP` in a `LIST` a default that a `FORM` inside it
may override.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The item belongs to the chunk it was stored with and is gone once the
walk leaves that chunk.

**NOTES**

`FindProp` and `FindCollection` are this call with the library's own
idents.

**SEE ALSO**

`StoreLocalItem`, `LocalItemData`, `FindProp`

**EXAMPLES**

```zig
const item = ip.FindLocalItem(iff, ip.MakeID("ILBM"), ip.MakeID("BMHD"), MY_IDENT);
```

## FindProp

Answers a property chunk that was kept.

**SYNOPSIS**

```zig
fn FindProp(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) ?*iffparse.StoredProperty
```

**SINCE**

1.0. LVO -112.

**INPUTS**

- `iff` - an open handle.
- `form_type`, `id` - the chunk, as they were given to `PropChunk`.

**RESULT**

Its contents - `size` bytes at `data` - or null when no such chunk
was kept where the walk now is.

**BEHAVIOR**

The nearest one counts: a property kept on the `FORM` the walk is in
hides one of the same name kept on the `PROP` of the `LIST` outside
it, which is how a list gives its forms defaults they may override.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The bytes are the library's and go when the walk leaves the chunk
they were kept on. What is wanted after that is copied out.

**NOTES**

The bytes are the chunk's as they lie in the file, so numbers wider
than a byte are big-endian and the caller turns them round.

**SEE ALSO**

`PropChunk`, `FindCollection`, `FindLocalItem`

**EXAMPLES**

```zig
const header = ip.FindProp(iff, ip.MakeID("ILBM"), ip.MakeID("BMHD")) orelse return;
const bytes = header.data.?;
const width = @as(u16, bytes[0]) << 8 | bytes[1];
```

## FindPropContext

Answers the FORM or LIST the walk is inside.

**SYNOPSIS**

```zig
fn FindPropContext(ib: *IFFParseBase, iff: *iffparse.IFFHandle) ?*iffparse.ContextNode
```

**SINCE**

1.0. LVO -120.

**INPUTS**

- `iff` - an open handle.

**RESULT**

The nearest `FORM` or `LIST` outside the chunk the walk is in, or
null when there is none.

**BEHAVIOR**

It starts at the chunk outside the current one, so a walk stopped at
a `BMHD` inside a `FORM ILBM` is answered that form. That is where
properties are stored, which is what makes a property found inside a
form the one that form set.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The node is the library's.

**NOTES**

A `CAT ` is not a property context: it groups forms and carries
nothing that applies to them.

**SEE ALSO**

`StoreLocalItem`, `PropChunk`, `CurrentChunk`

**EXAMPLES**

```zig
const form = ip.FindPropContext(iff) orelse return;
```

## FreeIFF

Gives a handle back.

**SYNOPSIS**

```zig
fn FreeIFF(ib: *IFFParseBase, iff: ?*iffparse.IFFHandle) void
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `iff` - a handle from `AllocIFF`; null does nothing.

**RESULT**

None.

**BEHAVIOR**

The handle and the bottom of its stack go. It must have been closed
first: `CloseIFF` is what pops the chunks still open and tells the
stream the file is done, and it cannot be done afterwards because the
handle is gone.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Everything the library kept with the handle goes with it. The stream
is still the caller's to close.

**NOTES**

Anything found through the handle - a `StoredProperty`, a
`CollectionItem`, a `ContextNode` - is gone once the walk has left
the chunk it belonged to, and certainly once the handle is freed.
What is wanted after that is copied out before.

**SEE ALSO**

`AllocIFF`, `CloseIFF`

**EXAMPLES**

```zig
ip.CloseIFF(iff);
dl.Close(file);
ip.FreeIFF(iff);
```

## FreeLocalItem

Gives a local item back.

**SYNOPSIS**

```zig
fn FreeLocalItem(ib: *IFFParseBase, item: ?*iffparse.LocalContextItem) void
```

**SINCE**

1.0. LVO -136.

**INPUTS**

- `item` - an item from `AllocLocalItem` that is not stored; null
  does nothing.

**RESULT**

None.

**BEHAVIOR**

The item and its bytes go. Its purge hook is not called: this is the
plain free, and the purge hook is what the library calls instead of
it when a stored item's chunk is left.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Only an item that was never stored, or whose purge hook is freeing
it, may be freed here. A stored item is the library's.

**NOTES**

A purge hook ends by calling this on the item it was given, which is
what makes a hook that frees more than the item itself possible.

**SEE ALSO**

`AllocLocalItem`, `StoreLocalItem`, `SetLocalItemPurge`

**EXAMPLES**

```zig
if (ip.StoreLocalItem(iff, item, ip.IFFSLI_TOP) != 0) ip.FreeLocalItem(item);
```

## GoodID

Says whether four characters may name a chunk.

**SYNOPSIS**

```zig
fn GoodID(ib: *IFFParseBase, id: u32) bool
```

**SINCE**

1.0. LVO -168.

**INPUTS**

- `id` - four characters as a number, the first in the highest byte.

**RESULT**

True when every character is printable - space to `~` - and the
first is not a space, unless the id is `ID_NULL`, which is four
spaces and is allowed.

**BEHAVIOR**

The library checks every id it reads and every id it is given to
write, so a program rarely needs this call; it is here for one that
builds an id from text and wants to know before it tries.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

Leading spaces are refused because an id is read as text: `" CAT"`
and `"CAT "` would otherwise both look like a group of forms.

**SEE ALSO**

`GoodType`, `IDtoStr`

**EXAMPLES**

```zig
if (!ip.GoodID(id)) return error.NotAChunkName;
```

## GoodType

Says whether four characters may name a kind of form.

**SYNOPSIS**

```zig
fn GoodType(ib: *IFFParseBase, form_type: u32) bool
```

**SINCE**

1.0. LVO -172.

**INPUTS**

- `form_type` - four characters as a number.

**RESULT**

True when it is a good id and holds only upper case letters, digits
and spaces.

**BEHAVIOR**

The type of a `FORM`, a `LIST` or a `CAT ` names a kind of thing -
`ILBM`, `FTXT`, `8SVX` - and the rule is tighter than for a chunk id
so that a type and a chunk name are told apart on sight.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

Lower case is what marks a chunk that a program made up for itself,
which is why a type may not have any.

**SEE ALSO**

`GoodID`, `PushChunk`

**EXAMPLES**

```zig
if (!ip.GoodType(kind)) return error.NotAFormKind;
```

## IDtoStr

Writes an id out as text.

**SYNOPSIS**

```zig
fn IDtoStr(ib: *IFFParseBase, id: u32, buf: *[5]u8) [*:0]u8
```

**SINCE**

1.0. LVO -176.

**INPUTS**

- `id` - four characters as a number.
- `buf` - five bytes to write them and a NUL into.

**RESULT**

`buf` again, as a C string.

**BEHAVIOR**

The four characters go in as they are, whatever they are: an id that
is not printable comes out as it stands, which is what a program
printing an error about a file wants to see.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

`buf` stays the caller's.

**NOTES**

Five bytes, not four: the NUL is what makes it a string.

**SEE ALSO**

`GoodID`, `CurrentChunk`

**EXAMPLES**

```zig
var name: [5]u8 = undefined;
_ = Printf(dl, "chunk %s\n", .{ip.IDtoStr(chunk.id, &name)});
```

## InitIFF

Says where a handle's bytes come from.

**SYNOPSIS**

```zig
fn InitIFF(ib: *IFFParseBase, iff: *iffparse.IFFHandle, flags: u32, hook: *utility.Hook) void
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `iff` - a handle from `AllocIFF`, not open.
- `flags` - what the stream can do: `IFFF_FSEEK` for seeking
  forwards, `IFFF_RSEEK` for seeking both ways, 0 for neither.
- `hook` - called with the handle and an `IFFStreamCmd`.

**RESULT**

None.

**BEHAVIOR**

The hook is called for every read, write and seek, and once at
`OpenIFF` (`IFFCMD_INIT`) and once at `CloseIFF` (`IFFCMD_CLEANUP`).
It answers 0 for done and anything else for a failure, which the
library turns into the `IFFERR_` that fits what was asked.

A stream that cannot seek forwards is seeked by reading and throwing
the bytes away, so reading needs no seek at all. A stream that cannot
seek back can still be written, but nothing reaches it until the
file is finished, because a chunk's size may have to be written back
over its header.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The hook stays the caller's and must outlive the handle's use of it.

**NOTES**

`iff.stream` is the caller's to set, and the library never looks at
it: the hook is what knows what it means.

**SEE ALSO**

`InitIFFasDOS`, `InitIFFasClip`, `OpenIFF`

**EXAMPLES**

```zig
var hook = utility.Hook{ .entry = &myStream };
iff.stream = @intFromPtr(&my_memory_block);
ip.InitIFF(iff, ip.IFFF_FSEEK | ip.IFFF_RSEEK, &hook);
```

## InitIFFasClip

Says a handle's stream is the clipboard.

**SYNOPSIS**

```zig
fn InitIFFasClip(ib: *IFFParseBase, iff: *iffparse.IFFHandle) void
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `iff` - a handle from `AllocIFF`, not open, whose `stream` holds a
  `*ClipboardHandle` from `OpenClipboard`.

**RESULT**

None.

**BEHAVIOR**

The clipboard seeks both ways, since a seek is only a change of
offset in the unit. Writing ends with `CMD_UPDATE`, which is what
makes the data the current clip; reading ends by asking past the end,
which tells the device nobody wants more.

**CONTEXT**

- Waits: no, but everything done through the stream afterwards waits
  on clipboard.device.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The clipboard handle stays the caller's, to close with
`CloseClipboard` after `CloseIFF`.

**NOTES**

Between `OpenIFF` and `CloseIFF` the clipboard handle is the
library's to drive: a program that sends its own requests on it
meanwhile will lose its place.

**SEE ALSO**

`OpenClipboard`, `CloseClipboard`, `OpenIFF`

**EXAMPLES**

```zig
const clip = ip.OpenClipboard(clipboard.PRIMARY_CLIP) orelse return;
defer ip.CloseClipboard(clip);
iff.stream = @intFromPtr(clip);
ip.InitIFFasClip(iff);
```

## InitIFFasDOS

Says a handle's stream is a file.

**SYNOPSIS**

```zig
fn InitIFFasDOS(ib: *IFFParseBase, iff: *iffparse.IFFHandle) void
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `iff` - a handle from `AllocIFF`, not open, whose `stream` holds a
  `*dos.FileHandle` from `Open`.

**RESULT**

None.

**BEHAVIOR**

The file is taken to seek both ways, which every file on a file
system here does. `Read`, `Write` and `Seek` are what the stream then
uses, and a short read or write is a failure.

**CONTEXT**

- Waits: no, but everything done through the stream afterwards waits
  on the file system.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do here; reading or writing the file needs a
  Process, because dos does.

**OWNERSHIP**

The file stays the caller's: it is opened before and closed after,
and the library never touches it except through `Read`, `Write` and
`Seek`.

**NOTES**

A stream that is not a file on a file system - a pipe, a socket -
does not seek, and is better given to `InitIFF` with the flags that
say so.

**SEE ALSO**

`InitIFF`, `InitIFFasClip`, `OpenIFF`

**EXAMPLES**

```zig
const file = dl.Open("SYS:Tests/picture.iff", dos.MODE_OLDFILE) orelse return;
defer _ = dl.Close(file);
iff.stream = @intFromPtr(file);
ip.InitIFFasDOS(iff);
```

## LocalItemData

Answers a local item's own bytes.

**SYNOPSIS**

```zig
fn LocalItemData(ib: *IFFParseBase, item: ?*iffparse.LocalContextItem) ?*anyopaque
```

**SINCE**

1.0. LVO -140.

**INPUTS**

- `item` - an item, or null.

**RESULT**

The `data_size` bytes it was made with, or null for a null item.

**BEHAVIOR**

The bytes are the item's own and last as long as it does. A null item
answers null, so the answer of `FindLocalItem` can be handed straight
in.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The bytes belong to the item and go with it.

**NOTES**

`FindProp` and `FindCollection` are this call on what `FindLocalItem`
found, with the ident the library uses for each.

**SEE ALSO**

`AllocLocalItem`, `FindLocalItem`

**EXAMPLES**

```zig
const mine: ?*MyState = @ptrCast(@alignCast(ip.LocalItemData(ip.FindLocalItem(iff, kind, id, MY_IDENT))));
```

## OpenClipboard

Opens clipboard.device, ready to be a handle's stream.

**SYNOPSIS**

```zig
fn OpenClipboard(ib: *IFFParseBase, unit: u32) ?*iffparse.ClipboardHandle
```

**SINCE**

1.0. LVO -160.

**INPUTS**

- `unit` - which clipboard: `PRIMARY_CLIP` is the one programs share.

**RESULT**

The handle, or null when there is no memory, no signal to spare or no
clipboard.device.

**BEHAVIOR**

The handle carries a request and two ports: one for the request to
come back on, one for a `CBD_POST` to be answered on. It is a
clipboard request like any other until it is given to `InitIFFasClip`
and the handle is opened, after which it is the library's until
`CloseIFF`.

The ports are the calling task's: the handle is used by the task that
opened it and no other.

**CONTEXT**

- Waits: for memory, and for clipboard.device to open.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's, to give back with `CloseClipboard`.

**NOTES**

The clipboard holds IFF, which is why this call is here rather than
in a program: what is cut from one program and pasted into another
has to be read by both, and an `FTXT` form is what both understand.

**SEE ALSO**

`CloseClipboard`, `InitIFFasClip`

**EXAMPLES**

```zig
const clip = ip.OpenClipboard(clipboard.PRIMARY_CLIP) orelse return;
defer ip.CloseClipboard(clip);
```

## OpenIFF

Opens the file for reading or for writing.

**SYNOPSIS**

```zig
fn OpenIFF(ib: *IFFParseBase, iff: *iffparse.IFFHandle, rw_mode: i32) i32
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `iff` - a handle with a stream (`InitIFF` and its like).
- `rw_mode` - `IFFF_READ` or `IFFF_WRITE`.

**RESULT**

0, or `IFFERR_NOHOOK` when the handle has no stream, or whatever the
stream's hook answered to `IFFCMD_INIT`.

**BEHAVIOR**

The walk starts at the top of the file: the depth goes to 0 and the
next `ParseIFF`, or the first `PushChunk`, is the outermost chunk.
The stream is told `IFFCMD_INIT` so that it can get ready.

A handle can be opened again after it is closed, which is how the
same handle reads one file after another.

**CONTEXT**

- Waits: whatever the stream hook waits for.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do unless the stream needs a Process.

**OWNERSHIP**

Nothing changes hands: the stream is the caller's throughout.

**NOTES**

The flags the stream was given - `IFFF_FSEEK`, `IFFF_RSEEK` - are
kept; only the read-or-write bit is set here.

**SEE ALSO**

`CloseIFF`, `ParseIFF`, `PushChunk`

**EXAMPLES**

```zig
if (ip.OpenIFF(iff, ip.IFFF_READ) != 0) return;
defer ip.CloseIFF(iff);
```

## ParentChunk

Answers the chunk a chunk is in.

**SYNOPSIS**

```zig
fn ParentChunk(ib: *IFFParseBase, context: *iffparse.ContextNode) ?*iffparse.ContextNode
```

**SINCE**

1.0. LVO -128.

**INPUTS**

- `context` - a chunk of a handle's stack.

**RESULT**

The chunk it sits in, or null when it is the outermost.

**BEHAVIOR**

Walking outwards from `CurrentChunk` with this call is how a program
sees where in the file it is - which `FORM` a chunk belongs to, and
which `LIST` that form is in.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The node is the library's.

**NOTES**

It takes no handle: a context node knows which stack it is on.

**SEE ALSO**

`CurrentChunk`, `FindPropContext`

**EXAMPLES**

```zig
var at = ip.CurrentChunk(iff);
while (at) |chunk| : (at = ip.ParentChunk(chunk)) { ... }
```

## ParseIFF

Walks on through the file.

**SYNOPSIS**

```zig
fn ParseIFF(ib: *IFFParseBase, iff: *iffparse.IFFHandle, control: i32) i32
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `iff` - a handle opened `IFFF_READ`.
- `control` - `IFFPARSE_SCAN` to walk on until a chunk the program
  asked to stop at, `IFFPARSE_STEP` to walk one chunk with the
  handlers run, `IFFPARSE_RAWSTEP` to walk one chunk with none run.

**RESULT**

0 when the walk stopped where it was asked to - at a `StopChunk`, at
one step of `STEP` or `RAWSTEP` - and the chunk it stopped at is
`CurrentChunk`. Otherwise a negative `IFFERR_`: `IFFERR_EOF` at the
end of the file, `IFFERR_EOC` when a step ended at the end of a
chunk, `IFFERR_NOTIFF` for a file that does not begin `FORM`, `LIST`
or `CAT `, `IFFERR_MANGLED` or `IFFERR_SYNTAX` for a file whose
chunks do not add up, `IFFERR_READ`, `IFFERR_NOMEM`, or whatever a
handler of the program's own answered.

**BEHAVIOR**

Each step enters the next chunk or reaches the end of the one it is
in, and runs the handler for that - the entry handler on the way in,
the exit handler on the way out. `PropChunk`, `StopChunk`,
`CollectionChunk` and `StopOnExit` are handlers of the library's own,
so a `SCAN` walks the file keeping what was asked for and stops where
it was asked to.

Where it stops, the chunk is entered and nothing of it has been read:
`CurrentChunk` says which it is and `ReadChunkBytes` reads it.

**CONTEXT**

- Waits: whatever the stream hook waits for, and for memory.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do unless the stream needs a Process, which a
  file does.

**OWNERSHIP**

What the walk keeps - stored properties, collections - belongs to the
chunk it was found in and goes when the walk leaves that chunk.

**NOTES**

A file is read by asking for what is wanted before the first call:
the properties to keep, the chunks to stop at. Walking with `STEP`
and looking at every chunk works too, and is what a program does when
it does not know what it will find.

**SEE ALSO**

`StopChunk`, `PropChunk`, `CollectionChunk`, `CurrentChunk`

**EXAMPLES**

```zig
_ = ip.PropChunk(iff, ip.MakeID("ILBM"), ip.MakeID("BMHD"));
_ = ip.StopChunk(iff, ip.MakeID("ILBM"), ip.MakeID("BODY"));
while (true) {
    const answer = ip.ParseIFF(iff, ip.IFFPARSE_SCAN);
    if (answer == ip.IFFERR_EOF) break;
    if (answer != 0) return;
    // at a BODY, with the BMHD already kept
}
```

## PopChunk

Ends the chunk being written.

**SYNOPSIS**

```zig
fn PopChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle) i32
```

**SINCE**

1.0. LVO -72.

**INPUTS**

- `iff` - a handle opened `IFFF_WRITE` with a chunk pushed.

**RESULT**

0, or a negative `IFFERR_`: `IFFERR_EOF` when no chunk is pushed,
`IFFERR_MANGLED` when the chunk was pushed with a size and a
different number of bytes was written, `IFFERR_WRITE`, `IFFERR_SEEK`
when the size could not be written back.

**BEHAVIOR**

A chunk of an odd number of bytes gets its pad byte here, so that the
next chunk starts on an even offset. A chunk pushed
`IFFSIZE_UNKNOWN` has its size written back over its header.

Popping the outermost chunk finishes the file: a stream that cannot
seek back is given everything that was held for it, in one go.

**CONTEXT**

- Waits: for whatever the stream hook waits for.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do unless the stream needs a Process.

**OWNERSHIP**

The chunk's context node and everything stored with it go here.

**NOTES**

`CloseIFF` pops whatever is still pushed, so a file written to the
end needs no pop of its own - but an error is then not seen.

**SEE ALSO**

`PushChunk`, `CloseIFF`

**EXAMPLES**

```zig
if (ip.PopChunk(iff) != 0) return error.WriteFailed;
```

## PropChunk

Keeps the contents of every such chunk, to be read back with `FindProp`.

**SYNOPSIS**

```zig
fn PropChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) i32
```

**SINCE**

1.0. LVO -84.

**INPUTS**

- `iff` - an open handle.
- `form_type` - the kind of the chunk's surroundings (`ILBM`), or 0
  to match whatever they are.
- `id` - the chunk's four characters.

**RESULT**

0, or `IFFERR_NOMEM`.

**BEHAVIOR**

The chunk is read whole as the walk goes past it and stored with the
FORM or LIST it was found in, so a property read inside one FORM is
that FORM's and not one left over from another. A second such chunk
in the same FORM replaces the first.

It is set on the chunk the walk is in, so it is asked for before the
walk starts - when the walk is inside nothing, which is the whole
file - or inside a chunk it is to apply to and no further.

**CONTEXT**

- Waits: for memory.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

What is kept belongs to the chunk it was found in and goes when the
walk leaves it.

**NOTES**

It is `EntryHandler` with a handler of the library's own.

**SEE ALSO**

`FindProp`, `CollectionChunk`, `StopChunk`

**EXAMPLES**

```zig
_ = ip.PropChunk(iff, ip.MakeID("ILBM"), ip.MakeID("BMHD"));
```

## PropChunks

Does what `PropChunk` does for each of a list of pairs.

**SYNOPSIS**

```zig
fn PropChunks(ib: *IFFParseBase, iff: *iffparse.IFFHandle, list: [*]const u32, pairs: i32) i32
```

**SINCE**

1.0. LVO -88.

**INPUTS**

- `iff` - an open handle.
- `list` - `pairs` * 2 numbers: a type and an id, then the next type
  and id, and so on.
- `pairs` - how many pairs there are.

**RESULT**

0, or what the first pair that failed answered.

**BEHAVIOR**

The pairs are taken in order and the first failure stops the rest, so
a failure leaves some of them set. The handle is closed or the walk
given up either way, so nothing has to be taken back.

**CONTEXT**

- Waits: for memory.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

`list` is only read, and is the caller's.

**NOTES**

It is `PropChunk` in a loop, and is here because a class that reads
a format names most of its chunks at once.

**SEE ALSO**

`PropChunk`

**EXAMPLES**

```zig
const wanted = [_]u32{
    ip.MakeID("ILBM"), ip.MakeID("BMHD"),
    ip.MakeID("ILBM"), ip.MakeID("CMAP"),
};
_ = ip.PropChunks(iff, &wanted, wanted.len / 2);
```

## PushChunk

Starts a chunk, for writing.

**SYNOPSIS**

```zig
fn PushChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32, size: i32) i32
```

**SINCE**

1.0. LVO -68.

**INPUTS**

- `iff` - a handle opened `IFFF_WRITE`.
- `form_type` - for a generic chunk (`FORM`, `LIST`, `CAT `, `PROP`),
  the kind of thing it holds: `ILBM`, `FTXT`. Ignored otherwise.
- `id` - the chunk's four characters.
- `size` - how many bytes it will hold, or `IFFSIZE_UNKNOWN` to have
  the count written back when the chunk is popped.

**RESULT**

0, or a negative `IFFERR_`: `IFFERR_SYNTAX` for an id that is not
four printable characters or a chunk where the IFF rules allow none,
`IFFERR_NOTIFF` when the outermost chunk is not `FORM`, `LIST` or
`CAT ` or a generic chunk's type is not upper case, `IFFERR_EOF`
after the outermost chunk has been popped, `IFFERR_WRITE`,
`IFFERR_NOMEM`.

**BEHAVIOR**

Nothing is written until every check has passed, so a chunk refused
leaves the file as it was. The rules checked are IFF's own: the file
starts with a `FORM`, a `LIST` or a `CAT `; a `PROP` sits only in a
`LIST`; a plain chunk sits only in a `FORM` or a `PROP`.

**CONTEXT**

- Waits: for memory, and for whatever the stream hook waits for.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do unless the stream needs a Process.

**OWNERSHIP**

The context node is the library's and goes at `PopChunk`.

**NOTES**

A size given here is kept to: `WriteChunkBytes` will not write past
it, and popping the chunk with less written is `IFFERR_MANGLED`.
`IFFSIZE_UNKNOWN` costs a seek back over the file, which a stream
that cannot seek back pays for by holding the whole file in memory
until it is done.

**SEE ALSO**

`PopChunk`, `WriteChunkBytes`, `OpenIFF`

**EXAMPLES**

```zig
_ = ip.PushChunk(iff, ip.MakeID("FTXT"), ip.ID_FORM, ip.IFFSIZE_UNKNOWN);
_ = ip.PushChunk(iff, 0, ip.MakeID("CHRS"), ip.IFFSIZE_UNKNOWN);
_ = ip.WriteChunkBytes(iff, text.ptr, @intCast(text.len));
_ = ip.PopChunk(iff);
_ = ip.PopChunk(iff);
```

## ReadChunkBytes

Reads bytes of the chunk the walk is in.

**SYNOPSIS**

```zig
fn ReadChunkBytes(ib: *IFFParseBase, iff: *iffparse.IFFHandle, buf: *anyopaque, bytes: i32) i32
```

**SINCE**

1.0. LVO -52.

**INPUTS**

- `iff` - an open handle whose walk is inside a chunk.
- `buf` - room for `bytes` bytes.
- `bytes` - how many to read at the most.

**RESULT**

How many bytes were read, which may be fewer than asked for and may
be 0 at the end of the chunk; or a negative `IFFERR_`: `IFFERR_EOF`
when the walk is in no chunk, `IFFERR_READ` when the stream could not
read.

**BEHAVIOR**

Never reads past the end of the chunk. The bytes are handed over as
they lie in the file and count towards the chunk's `scan`.

**CONTEXT**

- Waits: whatever the stream hook waits for - a file read does.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do unless the stream needs a Process, which a
  file does.

**OWNERSHIP**

`buf` stays the caller's.

**NOTES**

A chunk is read where the walk has stopped in it - at a `StopChunk`,
or at any chunk with `IFFPARSE_STEP`. A chunk named to `PropChunk` is
read by the library itself and found again with `FindProp`.

**SEE ALSO**

`ReadChunkRecords`, `StopChunk`, `FindProp`

**EXAMPLES**

```zig
const chunk = ip.CurrentChunk(iff).?;
const body = sys.AllocVec(@intCast(chunk.size), exec.MEMF_ANY).?;
_ = ip.ReadChunkBytes(iff, body, chunk.size);
```

## ReadChunkRecords

Reads whole records of the chunk the walk is in.

**SYNOPSIS**

```zig
fn ReadChunkRecords(ib: *IFFParseBase, iff: *iffparse.IFFHandle, buf: *anyopaque, record_size: i32, records: i32) i32
```

**SINCE**

1.0. LVO -56.

**INPUTS**

- `iff` - an open handle whose walk is inside a chunk.
- `buf` - room for `record_size` * `records` bytes.
- `record_size` - bytes per record, one or more.
- `records` - how many to read at the most.

**RESULT**

How many whole records were read, which may be fewer than asked for
and may be 0 at the end of the chunk; or a negative `IFFERR_`:
`IFFERR_EOF` when the walk is in no chunk, `IFFERR_READ` when the
stream could not read.

**BEHAVIOR**

Never reads past the end of the chunk: what is left of it is divided
by `record_size` and a part record at the end is left unread. The
bytes are handed over as they lie in the file, so a record of numbers
wider than a byte is the caller's to turn round.

The bytes count towards the chunk's `scan`, which is what tells the
walk when the chunk is used up.

**CONTEXT**

- Waits: whatever the stream hook waits for - a file read does.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do unless the stream needs a Process, which a
  file does.

**OWNERSHIP**

`buf` stays the caller's.

**NOTES**

`ReadChunkBytes` is this call with a record size of one.

**SEE ALSO**

`ReadChunkBytes`, `CurrentChunk`, `ParseIFF`

**EXAMPLES**

```zig
var colours: [32][3]u8 = undefined;
const got = ip.ReadChunkRecords(iff, &colours, 3, colours.len);
```

## SetLocalItemPurge

Sets the hook that frees an item instead of the library.

**SYNOPSIS**

```zig
fn SetLocalItemPurge(ib: *IFFParseBase, item: *iffparse.LocalContextItem, hook: *utility.Hook) void
```

**SINCE**

1.0. LVO -144.

**INPUTS**

- `item` - an item, stored or not.
- `hook` - called with the item and an `i32` holding
  `IFFCMD_PURGELCI`.

**RESULT**

None.

**BEHAVIOR**

When the walk leaves the chunk the item is stored with, the hook is
called instead of the item being freed, and the hook frees the item
itself with `FreeLocalItem`. That is how an item that owns more than
its own bytes - a list of chunks it gathered - gives all of it back.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The hook stays the caller's and must outlive the item.

**NOTES**

The hook is called while the chunk is being left, so what it does is
freeing and nothing else: the file is mid-walk and the stream is not
where the hook might think.

**SEE ALSO**

`AllocLocalItem`, `FreeLocalItem`, `StoreLocalItem`

**EXAMPLES**

```zig
mine.purge = utility.Hook{ .entry = &freeMine };
ip.SetLocalItemPurge(item, &mine.purge);
```

## StopChunk

Stops the walk when it reaches such a chunk.

**SYNOPSIS**

```zig
fn StopChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) i32
```

**SINCE**

1.0. LVO -92.

**INPUTS**

- `iff` - an open handle.
- `form_type` - the kind of the chunk's surroundings (`ILBM`), or 0
  to match whatever they are.
- `id` - the chunk's four characters.

**RESULT**

0, or `IFFERR_NOMEM`.

**BEHAVIOR**

`ParseIFF` answers 0 with that chunk the current one and nothing of
it read, so the program reads it and walks on.

It is set on the chunk the walk is in, so it is asked for before the
walk starts - when the walk is inside nothing, which is the whole
file - or inside a chunk it is to apply to and no further.

**CONTEXT**

- Waits: for memory.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

What is kept belongs to the chunk it was found in and goes when the
walk leaves it.

**NOTES**

It is `EntryHandler` with a handler of the library's own.

**SEE ALSO**

`ParseIFF`, `StopOnExit`, `PropChunk`

**EXAMPLES**

```zig
_ = ip.StopChunk(iff, ip.MakeID("ILBM"), ip.MakeID("BODY"));
```

## StopChunks

Does what `StopChunk` does for each of a list of pairs.

**SYNOPSIS**

```zig
fn StopChunks(ib: *IFFParseBase, iff: *iffparse.IFFHandle, list: [*]const u32, pairs: i32) i32
```

**SINCE**

1.0. LVO -96.

**INPUTS**

- `iff` - an open handle.
- `list` - `pairs` * 2 numbers: a type and an id, then the next type
  and id, and so on.
- `pairs` - how many pairs there are.

**RESULT**

0, or what the first pair that failed answered.

**BEHAVIOR**

The pairs are taken in order and the first failure stops the rest, so
a failure leaves some of them set. The handle is closed or the walk
given up either way, so nothing has to be taken back.

**CONTEXT**

- Waits: for memory.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

`list` is only read, and is the caller's.

**NOTES**

It is `StopChunk` in a loop, and is here because a class that reads
a format names most of its chunks at once.

**SEE ALSO**

`StopChunk`

**EXAMPLES**

```zig
const wanted = [_]u32{
    ip.MakeID("ILBM"), ip.MakeID("BMHD"),
    ip.MakeID("ILBM"), ip.MakeID("CMAP"),
};
_ = ip.StopChunks(iff, &wanted, wanted.len / 2);
```

## StopOnExit

Stops the walk when it reaches the end of such a chunk.

**SYNOPSIS**

```zig
fn StopOnExit(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) i32
```

**SINCE**

1.0. LVO -108.

**INPUTS**

- `iff` - an open handle.
- `form_type` - the kind of the chunk's surroundings (`ILBM`), or 0
  to match whatever they are.
- `id` - the chunk's four characters.

**RESULT**

0, or `IFFERR_NOMEM`.

The walk it stops answers `IFFERR_EOC`, not 0: that is what tells a
program which of the two kinds of stop it is looking at.

**BEHAVIOR**

`ParseIFF` answers `IFFERR_EOC` with that chunk still the current
one, which is the last moment at which what was stored inside it can
be read - the properties of a FORM, say, once every chunk of it has
been seen.

It is set on the chunk the walk is in, so it is asked for before the
walk starts - when the walk is inside nothing, which is the whole
file - or inside a chunk it is to apply to and no further.

**CONTEXT**

- Waits: for memory.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

What is kept belongs to the chunk it was found in and goes when the
walk leaves it.

**NOTES**

It is `EntryHandler` with a handler of the library's own.

**SEE ALSO**

`StopChunk`, `ExitHandler`, `FindProp`

**EXAMPLES**

```zig
_ = ip.StopOnExit(iff, ip.MakeID("ILBM"), ip.ID_FORM);
```

## StoreItemInContext

Stores an item with a chunk named outright.

**SYNOPSIS**

```zig
fn StoreItemInContext(ib: *IFFParseBase, iff: *iffparse.IFFHandle, item: *iffparse.LocalContextItem, context: *iffparse.ContextNode) void
```

**SINCE**

1.0. LVO -156.

**INPUTS**

- `iff` - an open handle.
- `item` - an item that is not stored.
- `context` - a chunk of this handle's stack, from `CurrentChunk`,
  `ParentChunk` or `FindPropContext`.

**RESULT**

None.

**BEHAVIOR**

The item goes at the front of that chunk's items, and any item
already there with the same type, id and ident is taken out and let
go of - so storing is replacing, and a second `BMHD` in one `FORM`
leaves one stored property and not two.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The item becomes the library's and goes when the walk leaves that
chunk.

**NOTES**

`StoreLocalItem` is this call with the chunk worked out from
`IFFSLI_ROOT`, `IFFSLI_TOP` or `IFFSLI_PROP`, and is what a program
normally wants.

**SEE ALSO**

`StoreLocalItem`, `AllocLocalItem`, `FindPropContext`

**EXAMPLES**

```zig
ip.StoreItemInContext(iff, item, ip.CurrentChunk(iff).?);
```

## StoreLocalItem

Stores an item with a chunk.

**SYNOPSIS**

```zig
fn StoreLocalItem(ib: *IFFParseBase, iff: *iffparse.IFFHandle, item: *iffparse.LocalContextItem, position: i32) i32
```

**SINCE**

1.0. LVO -152.

**INPUTS**

- `iff` - an open handle.
- `item` - an item that is not stored.
- `position` - `IFFSLI_ROOT` to keep it for the whole file,
  `IFFSLI_TOP` to keep it with the chunk the walk is in,
  `IFFSLI_PROP` to keep it with the FORM or LIST the walk is inside.

**RESULT**

0, or `IFFERR_NOSCOPE` when `IFFSLI_PROP` is asked for and the walk
is inside no FORM or LIST.

**BEHAVIOR**

The item lasts as long as the chunk it is stored with. `IFFSLI_ROOT`
stores it on the bottom of the stack, which is nobody's chunk and
lasts until the file is closed; that is where a handler meant for the
whole file goes.

An item already stored there saying the same thing is replaced.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

A stored item becomes the library's. One that could not be stored is
still the caller's, to free.

**NOTES**

`IFFSLI_TOP` before the walk has entered anything is the same as
`IFFSLI_ROOT`, which is why the chunk handlers are asked for then.

**SEE ALSO**

`StoreItemInContext`, `AllocLocalItem`, `FindLocalItem`

**EXAMPLES**

```zig
if (ip.StoreLocalItem(iff, item, ip.IFFSLI_TOP) != 0) ip.FreeLocalItem(item);
```

## WriteChunkBytes

Writes bytes into the chunk being written.

**SYNOPSIS**

```zig
fn WriteChunkBytes(ib: *IFFParseBase, iff: *iffparse.IFFHandle, buf: *const anyopaque, bytes: i32) i32
```

**SINCE**

1.0. LVO -60.

**INPUTS**

- `iff` - a handle opened `IFFF_WRITE` with a chunk pushed.
- `buf` - `bytes` bytes to write.
- `bytes` - how many to write.

**RESULT**

How many bytes were written, which is fewer than asked for when the
chunk was pushed with a size and has no room for them all; or a
negative `IFFERR_`: `IFFERR_EOF` when no chunk is pushed,
`IFFERR_WRITE` when the stream could not write, `IFFERR_NOMEM` when a
stream that cannot seek back had no room to hold the bytes.

**BEHAVIOR**

As `WriteChunkRecords` with a record size of one.

**CONTEXT**

- Waits: whatever the stream hook waits for - a file write does - and
  for memory on a stream that cannot seek back.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do unless the stream needs a Process, which a
  file does.

**OWNERSHIP**

`buf` stays the caller's.

**NOTES**

The library writes the eight header bytes of an inner chunk through
this call, so those bytes count towards the parent chunk's size as
they should.

**SEE ALSO**

`WriteChunkRecords`, `PushChunk`, `PopChunk`

**EXAMPLES**

```zig
_ = ip.PushChunk(iff, 0, ip.MakeID("CHRS"), ip.IFFSIZE_UNKNOWN);
_ = ip.WriteChunkBytes(iff, text.ptr, @intCast(text.len));
_ = ip.PopChunk(iff);
```

## WriteChunkRecords

Writes whole records into the chunk being written.

**SYNOPSIS**

```zig
fn WriteChunkRecords(ib: *IFFParseBase, iff: *iffparse.IFFHandle, buf: *const anyopaque, record_size: i32, records: i32) i32
```

**SINCE**

1.0. LVO -64.

**INPUTS**

- `iff` - a handle opened `IFFF_WRITE` with a chunk pushed.
- `buf` - `record_size` * `records` bytes to write.
- `record_size` - bytes per record, one or more.
- `records` - how many to write.

**RESULT**

How many whole records were written, which is fewer than asked for
when the chunk was pushed with a size and has no room for them all;
or a negative `IFFERR_`: `IFFERR_EOF` when no chunk is pushed,
`IFFERR_WRITE` when the stream could not write, `IFFERR_NOMEM` when a
stream that cannot seek back had no room to hold the bytes.

**BEHAVIOR**

A chunk pushed with a size takes no more than that size; one pushed
`IFFSIZE_UNKNOWN` takes whatever it is given and is told how much
when it is popped. The bytes go out as they are, so a record of
numbers wider than a byte is the caller's to turn round first.

**CONTEXT**

- Waits: whatever the stream hook waits for - a file write does - and
  for memory on a stream that cannot seek back.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do unless the stream needs a Process, which a
  file does.

**OWNERSHIP**

`buf` stays the caller's; what is written is copied out of it.

**NOTES**

On a stream that cannot seek back nothing reaches the stream until
the outermost chunk is popped, because a size may still have to be
written back into what has already been given.

**SEE ALSO**

`WriteChunkBytes`, `PushChunk`, `PopChunk`

**EXAMPLES**

```zig
_ = ip.PushChunk(iff, 0, ip.MakeID("CMAP"), @intCast(colours.len * 3));
_ = ip.WriteChunkRecords(iff, &colours, 3, colours.len);
_ = ip.PopChunk(iff);
```
