# utility.library

`utility.library`, in the ROM, holds the small, general calls the other
modules lean on: tag lists, the way options are handed to almost every
call in the system; hooks, the way a library calls a program back; dates;
32- and 64-bit multiplication and division; strings, characters and
case; text between UTF-8 and Latin-1; URLs taken apart and their escapes; the
patterns names are matched against; named objects; unique numbers; pack
tables; comparing records and sorting arrays; and reading the lines of
settings files. This guide goes through them by what a program wants to
do. Every call is in full in the
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
`NextSetting` with revision 2 (1.2), `ZoneOffset`, `DateToUtc` and
`UtcToDate` with revision 3 (1.3), `Utf8ToLatin1`, `Latin1ToUtf8` and
`Utf8Kind` with revision 4 (1.4), `ParseUrl`, `DecodeUrl` and
`EncodeUrl` with revision 5 (1.5), and `SortArray` with revision 6
(1.6), which `ub.lib().revision` tells. The
structures and constants are in `sdk.utility`, a file per area
(`tagitem`, `hooks`, `date`, `name`, `pack`, `pattern`, `setting`,
`text`, `url`),
most of them by name in `sdk.utility` itself; the pack-table ones only
in `sdk.utility.pack`. No call needs a process: a
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

## The zone the clock keeps

The system clock keeps local time. A server, a certificate, a file on
another machine or in git counts in UTC: seconds since 1 January 1970.
Three calls go between the two, by the zone the system keeps - the POSIX
TZ rule of `ENV:Sys/timezone`, which the boot's `C:SetClock ZONE` hands
to battmem.resource and Prefs' Region page hands again when it changes:

| Call | |
|---|---|
| `ZoneOffset(utc)` | the seconds the zone is east of UTC at that moment: 3600 for Central European Time, 7200 in its summer |
| `DateToUtc(&date, &nanoseconds)` | a `dos.DateStamp` as seconds since 1970, UTC; the fraction of its second where the second argument points, unless it is null |
| `UtcToDate(utc, &date)` | back: seconds since 1970, UTC, as a `dos.DateStamp` |

```zig
var now: dos.DateStamp = .{};
_ = dl.DateStamp(&now);
const utc = ub.DateToUtc(&now, null); // what a server counts in
const offset = ub.ZoneOffset(utc); // +3600 in Berlin in winter

var date: dos.DateStamp = .{};
ub.UtcToDate(server_mtime, &date); // a file's date from a server
_ = dl.SetFileDate(name, &date);
```

**The offset is that of the moment**, not of now: a date in July comes
with summer time in December. A local time in the hour the clocks skip
in spring is taken as if they had not changed yet; one in the hour they
go through twice in autumn, as the second time.

**The zone is read for each call**, from battmem.resource, so a zone
changed while a program runs is the one its next call uses, and no
file is read: a file system handler may ask about the volume the zone
file is on. While nobody set a zone, the clock keeps UTC and the offset
is 0. A rule whose offsets are not whole quarter hours cannot be kept
there (`SetClock ZONE` says so), and then the clock keeps UTC too.
These calls wait for battmem.resource's semaphore, so they need a task,
not an interrupt.

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

Strings are NUL-terminated, `[*:0]const u8`, and UTF-8: a character is
one to four bytes, and every length is counted in bytes.

| Call | |
|---|---|
| `Strcmp(a, b)` | below 0, 0 or above 0 as `a` sorts before, with or after `b`, byte by byte |
| `Stricmp(a, b)`, `Strnicmp(a, b, n)` | the same without case, a character at a time; `Strnicmp` at most `n` bytes |
| `Strlen(s)` | the bytes before the NUL |
| `Strlcpy(dest, size, s)` | `s` into `dest`, cut to `size - 1` bytes and always ended with a NUL; answers the length of `s` |
| `Strchr(s, c)`, `Strrchr(s, c)` | a pointer to the first or last byte `c` in `s`, or null |
| `ToUpper(c)`, `ToLower(c)` | one character, a code point (`u32`), in the other case |

Case is Unicode's simple case mapping, one character to one, with no
locale: `ToUpper` turns `ä` into `Ä`, `ж` into `Ж` and `ÿ` into `Ÿ`
(U+0178); `ß`, whose capital is two letters, stays as it is. A character
with no other case, and a value past U+10FFFF, is itself.

Without case, strings are compared by Unicode's simple case folding:
`Ä` and `ä` are one, `Σ`, `σ` and `ς` are one, and `ß` and `ẞ` are one.
The comparisons without case, the patterns without case, the name spaces
without `NSF_CASE` and the file systems' names all go through this one
folding, so they agree on what the same name is. Strings sort by their
folded code points: `_` (0x5F) before the letters, and what lies past
ASCII after all of ASCII. Two strings of different lengths in bytes can
be the same.

A byte that is no UTF-8 is read as U+FFFD, so it is never the letter
its value is in another encoding: `Stricmp` finds `M\xFCll` and `Müll`
different. Text in another encoding is made UTF-8 as it comes in (the
next section, and `fromLatin1`, `fromCp1252`, `fromForeign`).

`Strlcpy` reads all of its source, so a cut copy shows in its answer:

```zig
var name: [32]u8 = undefined;
if (ub.Strlcpy(&name, name.len, wanted) >= name.len) return dos.RETURN_ERROR; // too long
const dot = ub.Strrchr(@ptrCast(&name), '.') orelse return dos.RETURN_WARN; // no extension
const extension = dot + 1;
```

## Characters in a program

The SDK reads and writes UTF-8 itself, with no library call, in
`sdk.utility.utf8`; a program walks a string a character at a time with
it:

| | |
|---|---|
| `utf8.read(bytes)` | the first character: `.char`, the bytes it took (`.length`), and whether they were broken (`.broken`) |
| `utf8.next(bytes, &at)` | the character at `at`, moving `at` past it |
| `utf8.readLast(bytes)` | the character the bytes end with, as `read` reads it from its start: how text is walked back |
| `utf8.cut(bytes, limit)` | how many of the bytes a cut to at most `limit` keeps without ending inside a character |
| `utf8.readZ(text)` | `read` on a NUL-terminated string |
| `utf8.encode(char, &four)` | a character into at most four bytes: the bytes written |
| `utf8.lengthOf(char)` | the bytes `encode` writes for it |
| `utf8.valid(bytes)` | whether the whole is UTF-8 |
| `utf8.copyCut(bytes, into)` | as many whole characters as `into` holds, copied: the length |
| `utf8.fromLatin1(bytes, into)` | Latin-1 as UTF-8, as many whole characters as fit: the length |
| `utf8.fromForeign(bytes, into)` | text that does not say what it is written in - an ID3v1 tag, an old list - as UTF-8: as it is when the whole is UTF-8, else read as Latin-1; the length |

```zig
var at: usize = 0;
var count: usize = 0;
while (at < name.len) : (count += 1) _ = utility.utf8.next(name, &at);
```

Bytes that are no UTF-8 read as U+FFFD (`utf8.replacement`) with
`.broken` set: a byte that starts no character alone, a sequence broken
off as one with its lead, after which the byte that broke it is read
again, so a control after it is never swallowed. An overlong form, a
surrogate and a value past U+10FFFF are no UTF-8. `encode`
writes U+FFFD (`utf8.replacement`) for a surrogate or a value past
`utf8.last`.

`sdk.utility.unicode` holds the case tables the calls above use:
`unicode.fold(char)`, `unicode.upper(char)`, `unicode.lower(char)`, and
`unicode.compareFolded(a, b)` and `unicode.equalFolded(a, b)` over two
slices, what `Strnicmp` answers. `unicode.base(char)` is the letter a
letter with marks is written on (`A` for `Ā`), what a font that lacks
one draws instead. `unicode.width(char)` is the cells of a console a
character takes: 0 for a mark written on the character before it or a
format character, 2 for a wide one - CJK, kana, Hangul, emoji - and 1
for the rest; the console and its line editor place text by it, and a
program that lines text up in a console does too. `unicode.class(char)`
is what a character is, by its general category: `.upper`, `.lower`,
`.title` and `.letter` (no case) for the letters, `.digit` for a
decimal digit of any script, `.number`, `.mark`, `.punctuation`,
`.symbol`, `.space`, `.separator`, `.control`, `.format`, `.private`,
and `.unassigned` for what is no character; locale.library's `IsAlpha`
and the rest are made from it. `unicode.version` names the Unicode
version the tables are made from.

A text is made of clusters, each what a reader takes for one character:
a letter with the marks written on it, a carriage return with its line
feed, a Hangul syllable written as its parts, the consonants a virama
joins with their vowel sign (`क्षि` is one), the two regional indicators
of a flag, the pictographs a joiner makes one picture. They are
Unicode's extended grapheme clusters. `unicode.clusterEnd(text, start)`
is where the cluster that starts at `start` ends, and
`unicode.clusterStart(text, at)` where the one starts that the byte at
`at` is in:

```zig
// The clusters of a text, counted: what a cursor steps over.
var count: usize = 0;
var at: usize = 0;
while (at < text.len) : (at = utility.unicode.clusterEnd(text, at)) count += 1;

// The text without its last cluster: what Delete at the end leaves.
const shorter = text[0..utility.unicode.clusterStart(text, text.len - 1)];
```

A program that moves a cursor through a text, deletes before it, or
cuts a text to a length does it by these, never by characters or bytes:
graphics.library draws, measures and fits a text by the same clusters
(`TextFit`, `TextXToOffset`). `unicode.part(char)` is what a character
is in one (`.consonant`, `.linker`, `.regional`, ...), which the two
calls decide by.

An emoji is a cluster too - a face, a flag of two regional indicators,
a thumb with its skin tone, a family of three joined by U+200D, a
keycap of a digit, U+FE0F and U+20E3 - and is drawn either as text or
as a picture in its own colours. Each has one of the two by default: a
face is a picture, a heart, a digit and `©` are text. U+FE0F behind a
character asks for its picture (`❤️`), U+FE0E for its text, and a skin
tone behind a character that takes one makes a picture of it.
`unicode.pictured(cluster)` answers which it is for one cluster:

```zig
// Whether the cluster at `at` is drawn as a picture.
const end = utility.unicode.clusterEnd(text, at);
const picture = utility.unicode.pictured(text[at..end]);
```

`unicode.emoji(char)` is what one character is by itself - `.none`,
`.text`, `.picture`, `.toned_text` and `.toned_picture` for the ones a
skin tone may stand behind, `.tone` for the five skin tones - and
`unicode.selectable(char)` whether a selector behind it is heeded: a
watch has a text form and a picture, a grinning face only the picture,
so U+FE0E behind it changes nothing.

## Text between UTF-8 and Latin-1

The system's strings are UTF-8, and graphics.library draws them as such
(`Text` and the calls that measure it); so does the console, each
character in the cells `unicode.width` gives it. What comes from
elsewhere - a server's words, a file another system wrote, a name in a
repository - is mostly UTF-8 too; what is Latin-1 - an ID3v1 tag, an
older file or server - is made UTF-8 as it comes in, and made Latin-1
again only for what holds nothing else. Latin-1's 256 characters are
Unicode's first 256, so a character up to U+00FF is one byte in Latin-1
and two at most in UTF-8; one past it is a `?` in Latin-1.

A width or a `.limit` on a `%s` in `RawDoFmt` - and so in `Printf`,
`kprintf` and the rest that format through it - counts characters, not
bytes: `%-20s` lines a column of names up whatever their bytes, and a
`.limit` never ends inside a character. A wide character still takes
two cells of a console. `%c` takes a code point and writes it in UTF-8
- `Printf(dl, "%c", .{@as(u32, 0x20AC)})` writes `€`, three bytes.

| Call | |
|---|---|
| `Utf8ToLatin1(conversion, from, from_length, into, into_length)` | UTF-8 as Latin-1: the bytes written |
| `Latin1ToUtf8(from, from_length, into, into_length)` | Latin-1 as UTF-8: the bytes the whole takes, written or not |
| `Utf8Kind(bytes, length)` | `UTF8KIND_ASCII`, `UTF8KIND_LATIN1` (UTF-8 whose characters Latin-1 all has), `UTF8KIND_WIDE` (one it has not), or `UTF8KIND_NONE` (no UTF-8 at all) |

`Utf8ToLatin1` writes a `?` for each character Latin-1 has not, and for
each byte that is no UTF-8. Its `utility.Utf8Conversion` is null for a
whole text; with `UTF8F_PIECES` the text comes a piece at a time, a
character cut between two pieces is held for the next, and a call with
no bytes ends the text.

```zig
// A song's title for an ID3v1 tag, which holds Latin-1.
const written = ub.Utf8ToLatin1(null, title.ptr, title.len, &tag.title, tag.title.len);
@memset(tag.title[written..], 0);

// A file from another system: UTF-8 when the whole of it is.
const utf8 = ub.Utf8Kind(text.ptr, text.len) != utility.UTF8KIND_NONE;

// A name an older file holds in Latin-1, as UTF-8; twice its length
// always holds it.
const length = ub.Latin1ToUtf8(name.ptr, name.len, &out, out.len);
if (length > out.len) return null; // did not fit
```

**UTF-8 is read strictly**: an overlong form, a surrogate, a character
past U+10FFFF, a byte that starts no character and a sequence broken
off are no UTF-8, both for `Utf8Kind` and for the conversion. A byte
order mark at the start of a text is passed over.

**In place.** Latin-1 is never longer than the UTF-8 it comes from, so
`into` may be `from` - but for a piece after one that ended inside a
character, whose held bytes come first. `Latin1ToUtf8` never works in
place: the text grows.

**A piece at a time**, a server's stream as it comes, keeps one
conversion with `UTF8F_PIECES` for the whole text, `into` two bytes
longer than the piece, and ends with a call of no bytes, which gives a
character the last piece cut as the broken bytes it is. Writing stops
where `into` is full.

## URLs

A URL is `scheme://[user[:password]@]host[:port][/path][?query][#fragment]`.
`ParseUrl` takes one apart where it lies: each part is an offset and a
length in the text (`UrlPart.of(text)` is its slice), nothing copied
and nothing decoded, so a part is still written as the URL writes it.

| Call | |
|---|---|
| `ParseUrl(text, length, parts, flags)` | the URL's parts into a `utility.UrlParts`: true when it is one |
| `DecodeUrl(from, from_length, into, into_length)` | a part's `%XX` undone: the bytes the whole comes to, or `URL_BROKEN` for a `%` that is no escape |
| `EncodeUrl(from, from_length, into, into_length, flags)` | bytes as a part can hold them, `%XX` for the rest: the bytes the whole takes |

`ParseUrl` sets flags in `parts.flags` for what the text had: a user
(`URLF_USER`) and a password (`URLF_PASSWORD`), either of which may be
empty, and an IPv6 address in brackets (`URLF_BRACKETS`; the host is
the address without them). The port is 0 when the URL names none, the
scheme's own being the caller's to know. The path runs from the
authority's end to the `#`, its query with it: what a request sends.
Its offset is where the authority ends even when the path is empty, so
the text from the host - with its bracket - to `parts.path.offset` is
the `host:port` a request names. A control character or a space
anywhere makes a text no URL.

With `URLF_SCP` given, a text without a scheme may be the form a copy
names its remote end in, `[user@]host:path`: the first colon outside
brackets ends the host, with no `/` before it and no `//` after it.
`URLF_SCP` comes back set in `parts.flags` when that form was read. A
local name such as `RAM:file` reads as that form too - only the caller
knows its own volumes.

```zig
var parts: utility.UrlParts = .{};
if (!ub.ParseUrl(text.ptr, text.len, &parts, 0)) return null;
const scheme = parts.scheme.of(text);      // "https", in the case it is written
const host = parts.host.of(text);
const port: u32 = if (parts.port != 0) parts.port else 443;
const path = parts.path.of(text);           // "" for none: send "/"

// The user, for a login: decoded, its bytes UTF-8 as a rule.
if (parts.flags & utility.URLF_USER != 0) {
    const user = parts.user.of(text);
    const length = ub.DecodeUrl(user.ptr, user.len, &name, name.len - 1);
    if (length == utility.URL_BROKEN or length > name.len - 1) return null;
    name[length] = 0;
}
```

`EncodeUrl` leaves the letters, the digits and `-`, `.`, `_`, `~` as
they are - what no part of a URL needs escaped - and writes every other
byte as `%` and two upper-case hex digits, which is right for a user, a
password, a query's value and a path's segment alike:

| Flag | |
|---|---|
| `URLF_SLASH` | `/` stays as it is: for a whole path |

Both `DecodeUrl` and `EncodeUrl` answer the whole length and write as
much as `into` holds, no NUL after it: the whole is there when the
answer is no more than `into_length`, and an `into_length` of 0 only
counts. `EncodeUrl` never writes part of an escape. A part never grows as it is decoded, so `DecodeUrl` works in
place; `EncodeUrl` never does.

```zig
// Words typed for a search, as a query's value.
const room = address.len - at;
const length = ub.EncodeUrl(words.ptr, words.len, address[at..].ptr, room, 0);
if (length > room) return null; // too long
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
and `''` is one `'`.

**Both sides are characters.** A pattern and the strings it matches are
UTF-8: `?` takes one character, however many bytes it is, and a class's
range is a range of code points, so `[α-ω]` takes the Greek small
letters. The tokens are the bytes 0xF5 to 0xFF, which UTF-8 never holds
(`utility.isToken(byte)`), so a parsed pattern can be scanned byte by
byte. A pattern that is no UTF-8 does not parse (`ERROR_BAD_TEMPLATE`);
a byte of a string that is no UTF-8 is U+FFFD, which `?` takes.

`ParsePattern` answers 1 for a pattern with wildcards and 0 for a plain
name - whose tokens are the name, its escapes resolved, for a program to
use as it is. -1 is a failure with the reason in IoErr:
`ERROR_BAD_TEMPLATE` for a pattern that does not parse,
`ERROR_LINE_TOO_LONG` for a buffer too small; the tokens then hold an
empty pattern. `utility.parsedSize(len)` bytes are always enough for a
pattern of `len` bytes.

**Without case**, a character matches when it folds to what the
pattern's does, by the folding `Stricmp` uses. `ParsePatternNoCase`
writes the pattern's characters folded and `MatchPatternNoCase` folds
both sides, so it also matches tokens `ParsePattern` made; `MatchPattern`
on the tokens of `ParsePatternNoCase` matches only names already folded.
Names on the disk compare without case, so a pattern for them is parsed
with `ParsePatternNoCase` - the form `ExAllControl.match_string` takes.

The tokens are only read, so any number of tasks match against one
parsed pattern at once. Matching backtracks on frames of its own, given
back before it answers, up to 1024: a name of 255 bytes always fits. A match that needs more answers false, with `ERROR_TOO_MANY_LEVELS`
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

## Sorting an array

`SortArray(array, count, size, hook)` puts `count` elements of `size`
bytes in order where they are. The hook compares two: it is called with
one element as the object and another as the message, and answers -
read as an `isize` - below 0 when the object goes before the message, 0
or above when not. An answer of `Stricmp` or `CompareMem` can be handed
back as it is, and the hook's `data` carries whatever else the
comparison needs:

```zig
const Entry = struct { name: [*:0]const u8, size: u64 };

fn byName(hook: *utility.Hook, first: ?*anyopaque, second: ?*anyopaque) callconv(.c) usize {
    const ub: *UtilityBase = @ptrCast(@alignCast(hook.data.?));
    const a: *const Entry = @ptrCast(@alignCast(first.?));
    const b: *const Entry = @ptrCast(@alignCast(second.?));
    return @bitCast(@as(isize, ub.Stricmp(a.name, b.name)));
}

var by_name: utility.Hook = .{ .entry = byName, .data = ub };
ub.SortArray(entries.ptr, entries.len, @sizeOf(Entry), &by_name);
```

It is a heap sort: no memory taken, so it cannot fail, and about
2 n log2 n comparisons at most whatever order the elements come in -
an array already sorted costs as much as a shuffled one. It is not
stable: elements that compare alike end up in no order of their own,
so a list that must keep its ties in order compares by a second key
too. Elements whose size is a word's multiple, in an array on a word's
boundary, are swapped a word at a time.

## Lines of settings

`NextSetting(scan)` reads a line of `KEY=value` pairs a pair at a time -
the form every settings file in ENV:Sys is written in:

```
ICONSIZE=48 PICTURE="SYS:Prefs/Sea Side.png" VIEW NAME
```

Blanks - spaces, tabs, carriage returns, line feeds - part the pairs. A
pair is `KEY=value`, or `KEY value`. A value in double quotes runs to
the next quote, blanks and `=` in it, with no escapes; any other value to
the next blank. The call answers 1 with the pair in the `SettingScan`,
0 at the end, -1 for a quote that is not closed. Nothing is copied:
`key` and `value` point into the caller's text, so the call needs no
buffer and can run anywhere.

```zig
var scan: utility.SettingScan = .{ .text = line.ptr, .length = line.len };
while (ub.NextSetting(&scan) > 0) {
    if (std.ascii.eqlIgnoreCase(scan.keyText(), "ICONSIZE")) size = scan.valueText();
}
```

It knows no keys: which there are, and what their values may be, is the
caller's. The forms in `sdk.prefs` read their lines through it
(`sdk.prefs.Pairs`, which hands out slices), so every settings file
takes the same words the same way. A command line is another matter:
dos.library's `ReadArgs` and `ReadItem` read the shell's form, with its
`*` escapes in quotes and `;` comments.

## Where each call may run

| Calls | Waits | In an interrupt |
|---|---|---|
| tag lists read or changed in place, pack tables, dates, arithmetic, strings and case, text between UTF-8 and Latin-1, URLs, `CompareMem`, `NextSetting`, `GetUniqueID`, `SetWildStar`, `NamedObjectName` | no | yes; a list is the caller's to keep others off |
| `AllocateTagItems`, `CloneTagItems`, `FreeTagItems`, `AllocNamedObjectA`, `ReleaseNamedObject` | no | no: they allocate, free or take a lock |
| `ParsePattern`, `MatchPattern` and their `NoCase` forms | no | no: they may allocate, and report through IoErr, which only a process has |
| `AddNamedObject`, `FindNamedObject`, `RemNamedObject`, `AttemptRemNamedObject`, `FreeNamedObject` | for a name space's semaphore | no |
| `CallHookPkt`, `SortArray` | as the hook does | as the hook allows |

## See also

- [utility.library's autodocs](../autodocs/utility.md) - every call in full.
- `sdk/libs/utility/` - the structures and constants, a file per area.
- The [programs guide](programs.md) - tag lists at work: windows, gadgets, layouts.
- The [dos guide](dos.md) - `MatchFirst`, `MatchNext`, `ExAll`, and `DateStamp`s.
- The [motion guide](motion.md) - hooks called on another task.
- At `s3>`, `date` shows the system time as a date, and `date 1000000000`
  what that many seconds come to; in a shell, `List SYS: PAT ~(#?.info)`
  lists every name but the `.info` files.
