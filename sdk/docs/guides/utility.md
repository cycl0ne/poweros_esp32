# utility.library

`utility.library`, in the ROM, holds the small, general calls the other
modules lean on: tag lists, the way options are handed to almost every
call in the system; hooks, the way a library calls a program back; dates;
32- and 64-bit multiplication and division; strings and Latin-1 case; the
patterns names are matched against; named objects; unique numbers; pack
tables; and comparing records. This guide goes through them by what a
program wants to do. Every call is in full in the
[autodocs](../autodocs/utility.md).

## Opening it

```zig
const sdk = @import("sdk");
const dos = sdk.dos;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const UtilityBase = sdk.interface.utility.UtilityBase;

const lib = sys.OpenLibrary(utility.UTILITYNAME, 1) orelse return dos.RETURN_FAIL;
defer sys.CloseLibrary(lib);
const ub: *UtilityBase = @ptrCast(lib);
```

Version 1 has every call here; `CompareMem` came with revision 1 (1.1),
which `ub.lib().revision` tells. The structures and constants are in
`sdk.utility`, a file per area (`tagitem`, `hooks`, `date`, `name`,
`pack`, `pattern`), most of them by name in `sdk.utility` itself; the
pack-table ones only in `sdk.utility.pack`. No call needs a process: a
task will do.

## Tag lists

A tag list is an array of `TagItem`s, each a tag that says what the item
is and a data word, ended by an item whose tag is `TAG_DONE`. A
`TagItem`'s defaults are `TAG_DONE` and 0, so `.{}` ends a list. The tags
below `TAG_USER` belong to the system; a library's tags, and a program's
own, start at a base above it:

```zig
const BOX_Dummy = utility.TAG_USER + 0x1000;
const BOX_Width = BOX_Dummy + 1; // u32, in pixels
const BOX_Title = BOX_Dummy + 2; // [*:0]const u8
const BOX_Framed = BOX_Dummy + 3; // 0 or 1
const BOX_Offset = BOX_Dummy + 4; // i32

const options = [_]TagItem{
    .{ .tag = BOX_Width, .data = 120 },
    .{ .tag = BOX_Title, .data = @intFromPtr("Volume") },
    .{ .tag = BOX_Offset, .data = @bitCast(@as(isize, -4)) },
    .{},
};
```

A call takes the list as `&options`. The data is a `usize`, as wide as a
pointer: a number, a pointer through `@intFromPtr`, a negative number by
its bits, a flag as 0 or 1. Four tags steer the walk and are never items
themselves:

| Tag | |
|---|---|
| `TAG_DONE` | the end of the list |
| `TAG_IGNORE` | this item is passed over |
| `TAG_SKIP` | this item and the next `data` items are passed over |
| `TAG_MORE` | the list goes on at the array `data` points to; null ends it |

### Reading a list

`NextTagItem` walks a list: it keeps the place in a variable of the
caller's, follows `TAG_MORE`, passes over the control items and answers
null at the end. A list is never walked by indexing the array, since what
lies behind a `TAG_MORE` is not the list's.

```zig
const Box = struct { width: u32 = 100, title: ?[*:0]const u8 = null, offset: i32 = 0 };

fn setAttrs(ub: *UtilityBase, box: *Box, tags: ?[*]const TagItem) void {
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        switch (item.tag) {
            BOX_Width => box.width = @truncate(item.data),
            BOX_Title => box.title = @ptrFromInt(item.data),
            BOX_Offset => box.offset = @truncate(@as(isize, @bitCast(item.data))),
            else => {}, // not ours
        }
    }
}
```

**A reader passes over every tag it does not know.** One list often
serves several readers - a gadget class reads its own tags and hands the
same list to the class it is built on - and a list written for a later
version of a library carries tags an earlier one has never heard of,
which then does what it can with the rest.

For an option or two, `GetTagData` answers a tag's data or a default,
and `FindTagItem` the item or null, which tells a missing tag from one
given with the default:

```zig
const stack_size = ub.GetTagData(dos.NP_StackSize, 4096, tags);
if (ub.FindTagItem(BOX_Title, tags)) |item| box.title = @ptrFromInt(item.data);
```

Both answer the first item with the tag, where a loop that stores every
item ends with the last; and each walks the list from its start, so a
reader of many tags uses one loop.

### Handing a list on

The list is the caller's, often on its stack: a reader takes what it
needs during the call and keeps nothing that points into it. One that
must keep the options copies them with `CloneTagItems` - a flat copy, the
control items gone and a `TAG_MORE` chain joined - and gives the copy
back with `FreeTagItems`. A caller that adds its own options to a list it
was handed puts its own items first and ends them with
`.{ .tag = utility.TAG_MORE, .data = @intFromPtr(theirs) }`, copying
nothing.

An item is switched off in place by making its tag `TAG_IGNORE`; a
`TAG_SKIP` with data 1 in front of an item does the same for the item
behind it, and with 0 passes over only itself.

### Changing a list

These calls change a list in place, so they work on a copy:

| Call | |
|---|---|
| `FilterTagItems(list, tags, logic)` | keeps the items whose tags are in a `TAG_DONE`-ended array (`TAGFILTER_AND`), or those not in it (`TAGFILTER_NOT`) |
| `MapTags(list, map, map_type)` | renames tags through a map of old tag (`tag`) to new (`data`); `MAP_KEEP_NOT_FOUND` or `MAP_REMOVE_NOT_FOUND` for the rest |
| `ApplyTagChanges(list, changes)` | gives every item the data a change list has for its tag |
| `FilterTagChanges(changes, list, apply)` | drops the changes that change nothing; with `apply` non-zero, writes the rest into the list |
| `RefreshTagItemClones(clone, list)` | copies a list into its earlier clone again; the list may not have grown |

An item taken out becomes `TAG_IGNORE`, so every `TAG_MORE` stays where
it is. A class that hands some of its tags to another object, under that
object's names:

```zig
const gc = sdk.intuition.gadgetclass;
const handed_on = [_]utility.Tag{ BOX_Width, BOX_Title, utility.TAG_DONE };
const to_gadget = [_]TagItem{ .{ .tag = BOX_Width, .data = gc.GA_Width }, .{} };

const copy = ub.CloneTagItems(tags) orelse return dos.RETURN_FAIL;
defer ub.FreeTagItems(copy);
_ = ub.FilterTagItems(copy, &handed_on, utility.TAGFILTER_AND);
ub.MapTags(copy, &to_gadget, utility.MAP_KEEP_NOT_FOUND);
```

`FilterTagChanges` is how an object keeps quiet about what did not
change: it filters the changes against its attributes, applies the rest
and tells its listeners only what is left. `TagInArray` says whether a
tag is in an array of tags. `AllocateTagItems(n)` gives `n` items for a
list built at run time, every one `TAG_DONE` to begin with. **`FreeTagItems`
takes only an array from `AllocateTagItems` or `CloneTagItems`**: it
reads a size in front of the array that no other list has.

## Tags into a structure: pack tables

A pack table says which tag goes into which field of a structure.
`PackStructureTags` copies a list's data into the fields, and
`UnpackStructureTags` copies fields out to where a list's items point,
so setting and getting come from one table:

```zig
const pack = utility.pack;
const BOXF_FRAMED: u32 = 1 << 0;

const BoxFields = extern struct { width: u32 = 100, offset: i32 = 0, flags: u32 = 0 };

const box_table = [_]u32{
    BOX_Dummy,
    pack.packEntry(BOX_Dummy, BOX_Width, @offsetOf(BoxFields, "width"), pack.PKCTRL_ULONG),
    pack.packEntry(BOX_Dummy, BOX_Offset, @offsetOf(BoxFields, "offset"), pack.PKCTRL_LONG),
    pack.packBit(BOX_Dummy, BOX_Framed, @offsetOf(BoxFields, "flags"), pack.PKCTRL_BIT, BOXF_FRAMED),
    pack.PACK_ENDTABLE,
};

var box: BoxFields = .{};
_ = ub.PackStructureTags(&box, &box_table, tags); // set

var width: u32 = 0;
const query = [_]TagItem{ .{ .tag = BOX_Width, .data = @intFromPtr(&width) }, .{} };
_ = ub.UnpackStructureTags(&box, &box_table, &query); // get
```

A table is a base tag, an entry per field, and `PACK_ENDTABLE`.
`packEntry` takes the field's type: `PKCTRL_UBYTE`, `PKCTRL_UWORD`,
`PKCTRL_ULONG` or the signed `PKCTRL_BYTE`, `PKCTRL_WORD`,
`PKCTRL_LONG`, with `PKCTRL_PACKONLY` or `PKCTRL_UNPACKONLY` added for
one direction only. `packBit` makes one for a bit of a flags field;
`PKCTRL_FLIPBIT` sets it when the tag says false. Packing truncates the
data to the field; unpacking writes a whole `u32` - widened, with its
sign for a signed field, a bit as all ones or 0. A field whose tag is
missing is left alone, and both answer how many entries found their tag.
A field lies within the first 8 KiB, a tag within 1023 of its base;
`PACK_NEWOFFSET` and another base tag switch the base.

For flags alone, `PackBoolTags(flags, tags, map)` takes a map from each
boolean tag to its bits - `.{ .tag = BOX_Framed, .data = BOXF_FRAMED }` -
and sets them for non-zero data and clears them for zero.

## Hooks

A hook is how a library calls a program back. A `utility.Hook` holds a
function, `entry`, and a word for its owner, `data`; the library calls
it with `CallHookPkt(hook, object, message)`, which calls `entry` with
the hook itself, the object and the message, and answers what it
answers (0 for a hook without one). `entry` is a `utility.HookFn`, a
`callconv(.c)` function of those three that answers a `usize`.

What the object and the message are, and what the answer means, is the
caller's to say. dos.library's `ExAll` calls `ExAllControl.match_func`
for every entry it is about to list, with a pointer to the level as the
object and the entry's record as the message, and leaves the entry out
when the hook answers 0:

```zig
/// Lists only the files of at least the size the hook's data points to.
fn bigEnough(hook: *utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const least: *const u64 = @ptrCast(@alignCast(hook.data.?));
    const record: *const dos.ExAllData = @ptrCast(@alignCast(message.?));
    return @intFromBool(record.size >= least.*);
}

var least: u64 = 64 * 1024;
var hook: utility.Hook = .{ .entry = &bigEnough, .data = &least };
control.match_func = &hook; // the ExAllControl, at ED_SIZE or more
```

The hook is handed to its own function so the function can find its
context: through `data`, as here, or - for a hook that is a field of a
structure of the program's - through the structure around it, with
`@fieldParentPtr("hook", hook)`. `sub_entry` is a second word of the
owner's, for a second function or more context, and `node` keeps hooks
on a list.

**A hook runs on the task of whoever calls it.** A class's dispatcher
(`Class.dispatcher`, a hook) runs on the task that sent the method,
`ExAll`'s on the task listing the directory, motion.library's on its
clock's task. Each call that takes a hook says where it runs; one that
runs on another task stores and signals, and leaves the rest to its
program's loop. A hook stays valid as long as the library may call it.

## Dates

Two counts measure time from 1 January 1978:

- **Seconds** since 00:00:00 that day, in 32 bits: the system time, and
  what `Amiga2Date`, `Date2Amiga` and `CheckDate` take. They reach
  7 February 2114, 06:28:15.
- **Days**, day 0 being that day, a Sunday: a `dos.DateStamp`'s `days`,
  and what `DateSplit` and `DateJoin` take. They reach the end of 65535,
  the last year a `ClockData` holds.

A date is a `ClockData`: `sec`, `min`, `hour`, `mday` (1-31), `month`
(1-12), `year` (with its century) and `wday` (0 is Sunday). The calendar
is the Gregorian one - 2000 is a leap year, 2100 is not - with no time
zone and no leap seconds.

```zig
var now: dos.DateStamp = .{};
_ = dl.DateStamp(&now);

var today: utility.ClockData = .{};
ub.DateSplit(@intCast(now.days), &today); // the date and weekday, the time 0
today.hour = @intCast(@divTrunc(now.minute, 60));
today.min = @intCast(@mod(now.minute, 60));
_ = dos.stdio.Printf(dl, "%d.%d.%d %d:%02d\n", .{ today.mday, today.month, today.year, today.hour, today.min });

// Arithmetic by the day goes through the day number.
const day = ub.DateJoin(&.{ .year = 2026, .month = 10, .mday = 6 });
if (day < 0) return dos.RETURN_ERROR; // no such date, or before 1978
var week_on: utility.ClockData = .{};
ub.DateSplit(@intCast(day + 7), &week_on); // 13 October 2026, wday 2: a Tuesday
```

**Each call that turns a date into a count refuses a wrong one in its
own way.** `DateJoin` answers -1 for no date - a month outside 1-12, a
day the month does not have, a day before 1978 - and reads only the
year, month and day; day 0 is a date, so -1 is the only refusal.
`CheckDate` answers 0 for no date or one outside the seconds' range, so
the first second of 1978 cannot be told from a refusal. `Date2Amiga`
checks nothing: a field out of range carries into the next, so 31 April
is 1 May.

`DateSplit` and `DateJoin` undo each other for every day up to that
last one, as `Amiga2Date` and `Date2Amiga` do for every count of
seconds. A date's weekday is its day number modulo 7.

## Multiplying, dividing, aligning

| Call | |
|---|---|
| `SMult32`, `UMult32` | the low 32 bits of a product; an overflow wraps |
| `SMult64`, `UMult64` | the whole 64-bit product of two 32-bit numbers |
| `SDivMod32`, `UDivMod32` | `quotient` and `remainder` in one result |
| `AlignUp`, `AlignDown` | an offset rounded to a multiple of a power of two |

```zig
const r = ub.SDivMod32(-7, 2); // r.quotient -3, r.remainder -1
const next = ub.AlignUp(17, @alignOf(usize)); // 20
```

A signed quotient is rounded towards zero, so the remainder has the
dividend's sign; the smallest `i32` divided by -1 wraps to itself. A
divisor of 0 has no answer and ends in a dead-end alert. An alignment
that is not a power of two gives a number with no meaning, and nothing
checks it.

## Strings and case

Strings are NUL-terminated, `[*:0]const u8`, and Latin-1: a character is
a byte.

| Call | |
|---|---|
| `Strcmp(a, b)` | below 0, 0 or above 0 as `a` sorts before, with or after `b` |
| `Stricmp(a, b)`, `Strnicmp(a, b, n)` | the same without case; `Strnicmp` at most `n` characters |
| `Strlen(s)` | the bytes before the NUL |
| `Strlcpy(dest, size, s)` | `s` into `dest`, cut to `size - 1` bytes and always ended with a NUL; answers the length of `s` |
| `Strchr(s, c)`, `Strrchr(s, c)` | a pointer to the first or last `c` in `s`, or null |
| `ToUpper(c)`, `ToLower(c)` | one character in the other case |

Case is Latin-1's, with no locale: `ToUpper` turns `a`-`z` and the
letters 0xE0-0xFE but `÷` (0xF7) into capitals, and `ß` and `ÿ`, which
have none, stay as they are. The comparisons without case, the patterns
without case and the name spaces without `NSF_CASE` all go through this
one mapping, so they agree on what the same name is. Without case,
strings sort by their upper-case codes: `_` (0x5F) after `Z`.

`Strlcpy` reads all of its source, so a cut copy shows in its answer:

```zig
var name: [32]u8 = undefined;
if (ub.Strlcpy(&name, name.len, wanted) >= name.len) return dos.RETURN_ERROR; // too long
const dot = ub.Strrchr(@ptrCast(&name), '.') orelse return dos.RETURN_WARN; // no extension
const extension = dot + 1;
```

## Patterns

A pattern describes a set of names: `#?.info` is every name that ends in
`.info`. `ParsePattern` turns a pattern into tokens once, and
`MatchPattern` matches any number of strings against them:

```zig
var tokens: [utility.parsedSize(64)]u8 = undefined;
if (ub.ParsePatternNoCase(pattern, &tokens, tokens.len) < 0) {
    _ = dl.PrintFault(dl.IoErr(), pattern);
    return dos.RETURN_ERROR;
}
if (ub.MatchPatternNoCase(@ptrCast(&tokens), name)) {
    // name is one of them
}
```

The syntax:

- `?` - any one character.
- `#x` - any number of `x`, none included, where `x` is one character, a
  class or a group; `#?` is any string.
- `(a|b|c)` - one of the alternatives; one may be empty.
- `~x` - anything `x` does not match: `~(#?.info)` is every name but those.
- `[abc]`, `[a-z]`, `[~a-z]` - one character of a class, or not of it; a
  `-` first or last is itself.
- `%` - the empty string.
- `'x` - `x` itself, for `x` one of `* ~ [ ] # ? ( ) | % '`; before any
  other character `'` is itself. In a class, `'` makes any character
  itself.
- `*` - any string once `SetWildStar(true)` has made it a wildcard;
  otherwise itself.

The whole string must match, and `/` and `:` are characters like any
other: a pattern matches one name. Walking directories with one is
dos.library's `MatchFirst` and `MatchNext` (see the
[dos guide](dos.md#patterns)).

**`~` is a pattern character**, and so is `'`: a name with a `~` in it is
matched by writing `'~` (a `~` at the very end of a pattern is itself),
and `''` is one `'`. Bytes 0x80 to 0x8B are refused in a pattern; they
are the tokens.

`ParsePattern` answers 1 for a pattern with wildcards and 0 for a plain
name - whose tokens are the name, its escapes resolved, for a program to
use as it is. -1 is a failure with the reason in IoErr:
`ERROR_BAD_TEMPLATE` for a pattern that does not parse,
`ERROR_LINE_TOO_LONG` for a buffer too small; the tokens then hold an
empty pattern. `utility.parsedSize(len)` bytes are always enough for
`len` characters.

**Case belongs to the pair.** `ParsePatternNoCase` puts the pattern
through `ToUpper` and `MatchPatternNoCase` each character of the string;
tokens are matched by the partner of the call that made them. Names on
the disk compare without case, so a pattern for them is parsed with
`ParsePatternNoCase` - the form `ExAllControl.match_string` takes.

The tokens are only read, so any number of tasks match against one
parsed pattern at once. Matching backtracks on frames of its own, given
back before it answers, up to 1024: a name of 255 characters always
fits. A match that needs more answers false, with `ERROR_TOO_MANY_LEVELS`
in IoErr (`ERROR_NO_FREE_STORE` without memory).

`SetWildStar` changes `*` for every task's patterns parsed from then on,
and answers the setting before, which a program puts back with a
`defer`.

## Named objects

A named object is a name with, if asked for, a block of memory of its
own (user space) and a name space other objects can be put into. The
system has one root name space, given as null: a structure put there
under a name is found by any program that knows the name.

`AllocNamedObjectA` makes one in one allocation, the name copied in.
`ANO_UserSpace` gives it that many bytes, cleared and aligned for a
pointer, at its `object`; `ANO_NameSpace` gives it a name space,
`ANO_Flags` that space's flags (`NSF_NODUPS` refuses a second object of a
name, `NSF_CASE` compares with case), and `ANO_Priority` its place among
the others. `AddNamedObject` puts it into a name space:

```zig
const Mixer = extern struct { volume: u32 = 50, muted: u32 = 0 };

const made = ub.AllocNamedObjectA("mixer", &[_]TagItem{
    .{ .tag = utility.ANO_UserSpace, .data = @sizeOf(Mixer) },
    .{},
}) orelse return dos.RETURN_FAIL;
const mixer: *Mixer = @ptrCast(@alignCast(made.object.?));
mixer.* = .{};
if (!ub.AddNamedObject(null, made)) {
    ub.FreeNamedObject(made);
    return dos.RETURN_FAIL;
}
```

Finding one gives the finder a use of it, which it gives back:

```zig
if (ub.FindNamedObject(null, "mixer", null)) |found| {
    defer ub.ReleaseNamedObject(found);
    const shared: *Mixer = @ptrCast(@alignCast(found.object.?));
    shared.muted = 1;
}
```

The root name space has neither flag: names compare without case, and of
two objects with one name a search finds the first by priority. Searching
on from the last object found, with a null name, walks a whole space.
Searches share the space's semaphore and run at once; adding and taking
out hold it alone.

**An object is freed only when nobody holds it.** `RemNamedObject` takes
it out of its space at once, gives back the owner's use, and replies to
the message when the last other use is released - at once if there is
none. Then `FreeNamedObject` frees it:

```zig
const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
defer sys.DeleteMsgPort(port);
var message: sdk.exec.Message = .{ .reply_port = port };
ub.RemNamedObject(made, &message);
_ = sys.WaitPort(port);
_ = sys.GetMsg(port);
ub.FreeNamedObject(made);
```

`AttemptRemNamedObject` takes an object out only when the caller's use is
the only one, without waiting, and answers 1 when it did.
`FreeNamedObject` leaves alone - and leaks - an object still in a space,
or one whose own space still holds objects. `C:AddDataTypes` publishes
its list of data types this way, under `sdk.datatypes.DATATYPESLIST_NAME`,
and datatypes.library finds it by that name.

## Unique numbers

`GetUniqueID` answers 1 the first time and one more on every call after,
from one counter for the whole system, raised under `Disable`: tasks and
interrupts take numbers from it at once and never get the same one. A
window opened with no help group given gets one from it; a program that
puts several windows in one group takes one number and gives it to each
as `WA_HelpGroup`. After 2^32 numbers it wraps to 0.

## Comparing records

`CompareMem(first, second, length)` compares two blocks byte by byte: 0
when they are the same, below or above 0 as the first byte that differs
is lower or higher at `first`.

**A record equals another only when every byte does, padding
included**, so a record to compare is an `extern struct` of whole words,
which has none, or one cleared before it is filled. "Has anything
changed" is then one call - a gadget that keeps what it told its target
last tells it again only when the new record differs:

```zig
const Told = extern struct { line: u32, column: u32 };
var told: Told = .{ .line = 0xFFFF_FFFF, .column = 0 }; // no real line: the first call differs

const now: Told = .{ .line = line, .column = column };
if (ub.CompareMem(&now, &told, @sizeOf(Told)) != 0) {
    told = now;
    // ... tell the target ...
}
```

## Where each call may run

| Calls | Waits | In an interrupt |
|---|---|---|
| tag lists read or changed in place, pack tables, dates, arithmetic, strings and case, `CompareMem`, `GetUniqueID`, `SetWildStar`, `NamedObjectName` | no | yes; a list is the caller's to keep others off |
| `AllocateTagItems`, `CloneTagItems`, `FreeTagItems`, `AllocNamedObjectA`, `ReleaseNamedObject` | no | no: they allocate, free or take a lock |
| `ParsePattern`, `MatchPattern` and their `NoCase` forms | no | no: they may allocate, and report through IoErr, which only a process has |
| `AddNamedObject`, `FindNamedObject`, `RemNamedObject`, `AttemptRemNamedObject`, `FreeNamedObject` | for a name space's semaphore | no |
| `CallHookPkt` | as the hook does | as the hook allows |

## See also

- [utility.library's autodocs](../autodocs/utility.md) - every call in full.
- `sdk/libs/utility/` - the structures and constants, a file per area.
- The [programs guide](programs.md) - tag lists at work: windows, gadgets, layouts.
- The [dos guide](dos.md) - `MatchFirst`, `MatchNext`, `ExAll`, and `DateStamp`s.
- The [motion guide](motion.md) - hooks called on another task.
- At `s3>`, `date` shows the system time as a date, and `date 1000000000`
  what that many seconds come to; in a shell, `List SYS: PAT ~(#?.info)`
  lists every name but the `.info` files.
