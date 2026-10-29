# locale.library

locale.library's functions: a country's formats for dates, times and
numbers, a language's words and order of letters, and a program's
strings in the languages the user prefers. Open it with
OpenLibrary("locale.library", 1).

The table is this library's own: it starts at the first slot after
the standard four and holds only what is here.

Generated from the source by `./zig build autodoc`.

## Index

- [CloseCatalog](#closecatalog) - Gives a catalog back.
- [CloseLocale](#closelocale) - Gives a locale back.
- [ConvToLower](#convtolower) - Answers a character as a small letter.
- [ConvToUpper](#convtoupper) - Answers a character as a capital letter.
- [FormatDate](#formatdate) - Writes a date out by a template, in the locale's words.
- [FormatString](#formatstring) - Writes values out by a template, as RawDoFmt does, a value picked by its place and the digits of a number grouped as the locale groups them.
- [GetCatalogStr](#getcatalogstr) - Answers one of a catalog's strings, or the one built in.
- [GetLocaleStr](#getlocalestr) - Answers one of the words of the locale's language.
- [IsAlNum](#isalnum) - Says whether a character is a letter or a digit.
- [IsAlpha](#isalpha) - Says whether a character is a letter.
- [IsCntrl](#iscntrl) - Says whether a character is a control character.
- [IsDigit](#isdigit) - Says whether a character is a decimal digit.
- [IsGraph](#isgraph) - Says whether a character is printed and not blank.
- [IsLower](#islower) - Says whether a character is a small letter.
- [IsPrint](#isprint) - Says whether a character is printed, blanks included.
- [IsPunct](#ispunct) - Says whether a character is punctuation.
- [IsSpace](#isspace) - Says whether a character is blank.
- [IsUpper](#isupper) - Says whether a character is a capital letter.
- [IsXDigit](#isxdigit) - Says whether a character is a hexadecimal digit.
- [OpenCatalogA](#opencataloga) - Opens a program's catalog in the first of the locale's languages that has one.
- [OpenLocale](#openlocale) - Makes a locale from a settings file, or answers the default one.
- [ParseDate](#parsedate) - Reads a date by a template, in the locale's words.
- [SetDefaultLocale](#setdefaultlocale) - Makes a locale the default, which `OpenLocale(null)` answers and dos writes and reads dates and its texts in.
- [StrConvert](#strconvert) - Writes a string as a key whose plain byte order is the string's order in the locale.
- [StrnCmp](#strncmp) - Compares two strings in the order of the locale's language.

## CloseCatalog

Gives a catalog back.

**SYNOPSIS**

```zig
fn CloseCatalog(lb: *LocaleBase, catalog: ?*locale.Catalog) void
```

**SINCE**

1.0. LVO -112.

**INPUTS**

- `catalog` - a catalog from OpenCatalogA; null does nothing, so the
  answer of an OpenCatalogA that found none may be handed over as it
  is.

**RESULT**

None.

**BEHAVIOR**

The catalog is held once by each OpenCatalogA that answered it. One no
one holds stays loaded, for the next program that asks, until the
library is asked to give memory back.

**CONTEXT**

- Waits: for the library's lock, for a moment.
- Interrupts: no.
- Locks: takes the library's lock.
- Process: a Task will do.

**OWNERSHIP**

The caller's hold ends: the catalog's strings may be gone once this
returns.

**NOTES**

A string from GetCatalogStr is the catalog's: copy what is needed
after the catalog is closed.

**BUGS**

None known.

**SEE ALSO**

`OpenCatalogA`, `GetCatalogStr`

**EXAMPLES**

```zig
const catalog = lb.OpenCatalogA(null, "c/test/locale.catalog", null);
defer lb.CloseCatalog(catalog);
```

## CloseLocale

Gives a locale back.

**SYNOPSIS**

```zig
fn CloseLocale(lb: *LocaleBase, loc: ?*locale.Locale) void
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `loc` - a locale from OpenLocale, or one SetDefaultLocale answered;
  null does nothing.

**RESULT**

None.

**BEHAVIOR**

A locale is held once by each OpenLocale that answered it and by the
library while it is the default. The last to give it back frees it;
the library's own is never freed.

**CONTEXT**

- Waits: for the library's lock, for a moment.
- Interrupts: no.
- Locks: takes the library's lock.
- Process: a Task will do.

**OWNERSHIP**

The caller's hold ends: the locale and its strings may be gone once
this returns.

**NOTES**

Each OpenLocale is matched by one CloseLocale, also for the default.

**BUGS**

None known.

**SEE ALSO**

`OpenLocale`, `SetDefaultLocale`

**EXAMPLES**

```zig
const loc = lb.OpenLocale(null) orelse return;
defer lb.CloseLocale(loc);
```

## ConvToLower

Answers a character as a small letter.

**SYNOPSIS**

```zig
fn ConvToLower(_: *LocaleBase, loc: *const locale.Locale, character: u32) u32
```

**SINCE**

1.0. LVO -80.

**INPUTS**

- `loc` - a locale, from OpenLocale.
- `character` - a character of the locale's code set, by its number.

**RESULT**

The small letter for a capital one; anything else as it is. A to Z and À to Þ but × are
answered as a to z and à to þ.
A character past 255 is answered as it is.

**BEHAVIOR**

The cases are the code set's: Latin-1's, the same in every language.

**CONTEXT**

- Waits: no.
- Interrupts: safe; it reads no memory but its argument.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

The answer fits a byte whenever the character does, so a string can be
changed in place.

**BUGS**

None known.

**SEE ALSO**

`ConvToUpper`, `IsUpper`

**EXAMPLES**

```zig
const small: u8 = @intCast(lb.ConvToLower(loc, key));
```

## ConvToUpper

Answers a character as a capital letter.

**SYNOPSIS**

```zig
fn ConvToUpper(_: *LocaleBase, loc: *const locale.Locale, character: u32) u32
```

**SINCE**

1.0. LVO -84.

**INPUTS**

- `loc` - a locale, from OpenLocale.
- `character` - a character of the locale's code set, by its number.

**RESULT**

The capital letter for a small one; anything else as it is. a to z and à to þ but ÷ are
answered as A to Z and À to Þ; ß, ÿ and µ have no capital in the
code set and stay as they are.
A character past 255 is answered as it is.

**BEHAVIOR**

The cases are the code set's: Latin-1's, the same in every language.

**CONTEXT**

- Waits: no.
- Interrupts: safe; it reads no memory but its argument.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

The answer fits a byte whenever the character does, so a string can be
changed in place.

**BUGS**

None known.

**SEE ALSO**

`ConvToLower`, `IsLower`

**EXAMPLES**

```zig
for (word) |*c| c.* = @intCast(lb.ConvToUpper(loc, c.*));
```

## FormatDate

Writes a date out by a template, in the locale's words.

**SYNOPSIS**

```zig
fn FormatDate(lb: *LocaleBase, loc: *const locale.Locale, template: [*:0]const u8, date: *const dos.DateStamp, put_char_func: *utility.Hook) void
```

**SINCE**

1.0. LVO -96.

**INPUTS**

- `loc` - a locale, from OpenLocale: its words for the days, the
  months, before and after noon, and its time zone.
- `template` - the text to write, with a conversion after each `%`
  (below); a locale's formats (`loc.date_format`, ...) are templates.
- `date` - the moment, in local time.
- `put_char_func` - called through utility's CallHookPkt with the
  locale as the object and each byte as the message, then with 0.

**RESULT**

None: the text went to the hook.

**BEHAVIOR**

The conversions:

- `%a` `%A` - the weekday, short and long (ABDAY_*, DAY_*).
- `%b` `%h` `%B` - the month, short, short and long.
- `%d` `%e` - the day of the month, `01` to `31`, and ` 1` to `31`.
- `%m` `%y` `%Y` - the month `01` to `12`, the year's last two digits,
  the year.
- `%H` `%q` - the hour of 24, `00` to `23` and `0` to `23`.
- `%I` `%Q` - the hour of 12, `01` to `12` and `1` to `12`; `%p` the
  locale's AM_STR or PM_STR.
- `%M` `%S` - the minute and the second, `00` to `59`.
- `%j` - the day of the year, `001` to `366`; `%w` the weekday, `0`
  (Sunday) to `6`; `%U` `%W` the week of the year, `00` to `53`, a week
  from Sunday and from Monday, the days before the first such day in
  week 0.
- `%Z` - the time zone's name then (`CET`, `CEST`), from the locale's
  rule; nothing when it has none.
- `%D` `%x` - `%m/%d/%y`; `%T` `%X` - `%H:%M:%S`; `%R` - `%H:%M`;
  `%r` - `%I:%M:%S %p`; `%c` - `%a %b %d %H:%M:%S %Y`; `%C` -
  `%a %b %e %T %Z %Y`.
- `%n` `%t` - a line feed and a tab. Any other character after a `%`
  is written as it is, so `%%` is one `%`.

**CONTEXT**

- Waits: no, but the hook may.
- Interrupts: no; the hook is called through utility.library.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated; what the hook does with the bytes is its own.

**NOTES**

The forms `%x`, `%c` and the rest are fixed; a program that wants the
country's way passes the country's format - `loc.short_date_format`.
sdk.locale's `BufferHook` writes into a buffer.

**BUGS**

None known.

**SEE ALSO**

`ParseDate`, `FormatString`, dos.library `DateToStr`

**EXAMPLES**

```zig
var text: [64]u8 = undefined;
var out = locale.BufferHook.init(&text);
var now: dos.DateStamp = undefined;
_ = dl.DateStamp(&now);
lb.FormatDate(loc, loc.date_format, &now, &out.hook);
```

## FormatString

Writes values out by a template, as RawDoFmt does, a value picked by its place and the digits of a number grouped as the locale groups them.

**SYNOPSIS**

```zig
fn FormatString(lb: *LocaleBase, loc: *const locale.Locale, template: [*:0]const u8, data_stream: ?*const anyopaque, put_char_func: *utility.Hook) ?*const anyopaque
```

**SINCE**

1.0. LVO -104.

**INPUTS**

- `loc` - a locale, from OpenLocale: its group separator and grouping.
- `template` - `%[n$][-][0][width][.limit][l|z]{d,D,u,U,x,X,s,c}`, as
  RawDoFmt takes it, and `n$` to take the n-th value, from 1.
- `data_stream` - the values, packed and read with unaligned loads, as
  RawDoFmt reads them: 32 bits for `d u x c`, 64 with `l`, a usize
  with `z`, a pointer for `s`. Null reads 0 and null for each.
- `put_char_func` - called through utility's CallHookPkt with the
  locale as the object and each byte as the message, then with 0.

**RESULT**

The data stream past the last value the template uses; null when it
was null.

**BEHAVIOR**

Each conversion takes the next value unless it names one by its place
(`%2$s`): a translation can put the values of a sentence in another
order and still be handed the same stream. The values are where their
sizes put them, so a template that names its values by place must use
each value up to the last it names, and each with one size.

`%D` and `%U` write a signed and an unsigned number with the locale's
group separator between groups of digits (`1.234.567`); `%d` and `%u`
do not group. `%x` and `%X` write capitals. A width and a limit count
characters. With zero fill the sign comes before the zeros; a null
`%s` writes nothing, padding included. Any other character after a
`%` is written as it is, so `%%` is one `%`.

**CONTEXT**

- Waits: no, but the hook may.
- Interrupts: no; the hook is called through utility.library.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

A template uses 32 values at most; a conversion that names one past
them is written as its text. sdk.exec's `fmtStream` packs the values,
and sdk.locale's `BufferHook` takes the text.

**BUGS**

None known.

**SEE ALSO**

`FormatDate`, exec.library `RawDoFmt`, `GetCatalogStr`

**EXAMPLES**

```zig
var text: [80]u8 = undefined;
var out = locale.BufferHook.init(&text);
const stream = exec.fmtStream(.{ name, size });
_ = lb.FormatString(loc, "%2$D bytes in %1$s", &stream, &out.hook);
```

## GetCatalogStr

Answers one of a catalog's strings, or the one built in.

**SYNOPSIS**

```zig
fn GetCatalogStr(_: *LocaleBase, catalog: ?*const locale.Catalog, string_num: i32, default_string: [*:0]const u8) [*:0]const u8
```

**SINCE**

1.0. LVO -116.

**INPUTS**

- `catalog` - a catalog from OpenCatalogA, or null.
- `string_num` - the string's number, as the program's `.cd` file
  gives it.
- `default_string` - the string built into the program.

**RESULT**

The catalog's string of that number, in the locale's code set;
`default_string` when `catalog` is null or has none of that number.

**BEHAVIOR**

The strings are sorted by number when the catalog is read, so this is
a binary search.

**CONTEXT**

- Waits: no.
- Interrupts: safe; a catalog does not change while it is held.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The string is the catalog's, good until it is closed, or the caller's
own `default_string`.

**NOTES**

A translation may leave strings out: each is the one built in.

**BUGS**

None known.

**SEE ALSO**

`OpenCatalogA`, `CloseCatalog`, sdk.locale `Strings`

**EXAMPLES**

```zig
_ = dl.PutStr(lb.GetCatalogStr(catalog, MSG_HELLO, "Hello\n"));
```

## GetLocaleStr

Answers one of the words of the locale's language.

**SYNOPSIS**

```zig
fn GetLocaleStr(_: *LocaleBase, loc: *const locale.Locale, string_num: u32) ?[*:0]const u8
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `loc` - a locale, from OpenLocale.
- `string_num` - which word: DAY_1 (Sunday) to DAY_7, ABDAY_1 to
  ABDAY_7, MON_1 (January) to MON_12, ABMON_1 to ABMON_12, YESSTR,
  NOSTR, AM_STR, PM_STR, SOFTHYPHEN, HARDHYPHEN, OPENQUOTE, CLOSEQUOTE,
  YESTERDAYSTR, TODAYSTR, TOMORROWSTR, FUTURESTR.

**RESULT**

The word, in the locale's code set; null for 0 or a number past
FUTURESTR.

**BEHAVIOR**

The words are the language file's; one it leaves out is English.

**CONTEXT**

- Waits: no.
- Interrupts: safe; it reads the locale, which does not change.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The word is the locale's, good until it is closed.

**NOTES**

FormatDate writes the day and month names with these; a program that
writes its own dates asks here for the same words.

**BUGS**

None known.

**SEE ALSO**

`OpenLocale`, `FormatDate`

**EXAMPLES**

```zig
const yes = lb.GetLocaleStr(loc, locale.YESSTR) orelse "Yes";
```

## IsAlNum

Says whether a character is a letter or a digit.

**SYNOPSIS**

```zig
fn IsAlNum(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `loc` - a locale, from OpenLocale.
- `character` - a character of the locale's code set, by its number.

**RESULT**

True for a letter - A to Z, a to z, À to ÿ but × and ÷, and ª, µ, º -
or a digit, 0 to 9. False for anything past 255.

**BEHAVIOR**

The classes are the code set's: Latin-1's, the same in every
language. A language decides the order its letters sort in
(`StrnCmp`), not which characters are letters.

**CONTEXT**

- Waits: no.
- Interrupts: safe; it reads a table.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

A byte from a string is handed over as it is: the code set's
characters are its bytes.

**BUGS**

None known.

**SEE ALSO**

`IsAlpha`, `IsDigit`, `IsPunct`

**EXAMPLES**

```zig
while (at < name.len and lb.IsAlNum(loc, name[at])) at += 1;
```

## IsAlpha

Says whether a character is a letter.

**SYNOPSIS**

```zig
fn IsAlpha(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `loc` - a locale, from OpenLocale.
- `character` - a character of the locale's code set, by its number.

**RESULT**

True for A to Z, a to z, À to ÿ but × and ÷, and ª, µ and º. False for anything past 255.

**BEHAVIOR**

The classes are the code set's: Latin-1's, the same in every
language. A language decides the order its letters sort in
(`StrnCmp`), not which characters are letters.

**CONTEXT**

- Waits: no.
- Interrupts: safe; it reads a table.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

A byte from a string is handed over as it is: the code set's
characters are its bytes.

**BUGS**

None known.

**SEE ALSO**

`IsAlNum`, `IsUpper`, `IsLower`

**EXAMPLES**

```zig
if (lb.IsAlpha(loc, text[0])) return .word;
```

## IsCntrl

Says whether a character is a control character.

**SYNOPSIS**

```zig
fn IsCntrl(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `loc` - a locale, from OpenLocale.
- `character` - a character of the locale's code set, by its number.

**RESULT**

True for 0 to 31, 127, and 128 to 159. False for anything past 255.

**BEHAVIOR**

The classes are the code set's: Latin-1's, the same in every
language. A language decides the order its letters sort in
(`StrnCmp`), not which characters are letters.

**CONTEXT**

- Waits: no.
- Interrupts: safe; it reads a table.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

A byte from a string is handed over as it is: the code set's
characters are its bytes.

**BUGS**

None known.

**SEE ALSO**

`IsPrint`, `IsSpace`

**EXAMPLES**

```zig
const shown: u8 = if (lb.IsCntrl(loc, byte)) '.' else byte;
```

## IsDigit

Says whether a character is a decimal digit.

**SYNOPSIS**

```zig
fn IsDigit(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `loc` - a locale, from OpenLocale.
- `character` - a character of the locale's code set, by its number.

**RESULT**

True for 0 to 9. False for anything past 255.

**BEHAVIOR**

The classes are the code set's: Latin-1's, the same in every
language. A language decides the order its letters sort in
(`StrnCmp`), not which characters are letters.

**CONTEXT**

- Waits: no.
- Interrupts: safe; it reads a table.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

A byte from a string is handed over as it is: the code set's
characters are its bytes.

**BUGS**

None known.

**SEE ALSO**

`IsXDigit`, `IsAlNum`

**EXAMPLES**

```zig
while (at < text.len and lb.IsDigit(loc, text[at])) at += 1;
```

## IsGraph

Says whether a character is printed and not blank.

**SYNOPSIS**

```zig
fn IsGraph(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool
```

**SINCE**

1.0. LVO -52.

**INPUTS**

- `loc` - a locale, from OpenLocale.
- `character` - a character of the locale's code set, by its number.

**RESULT**

True for 33 to 126 and 161 to 255: a letter, a digit or punctuation. False for anything past 255.

**BEHAVIOR**

The classes are the code set's: Latin-1's, the same in every
language. A language decides the order its letters sort in
(`StrnCmp`), not which characters are letters.

**CONTEXT**

- Waits: no.
- Interrupts: safe; it reads a table.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

A byte from a string is handed over as it is: the code set's
characters are its bytes.

**BUGS**

None known.

**SEE ALSO**

`IsPrint`, `IsSpace`, `IsPunct`

**EXAMPLES**

```zig
if (!lb.IsGraph(loc, key)) return; // a blank or a control character
```

## IsLower

Says whether a character is a small letter.

**SYNOPSIS**

```zig
fn IsLower(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool
```

**SINCE**

1.0. LVO -56.

**INPUTS**

- `loc` - a locale, from OpenLocale.
- `character` - a character of the locale's code set, by its number.

**RESULT**

True for a to z, ß to ÿ but ÷, and µ. False for anything past 255.

**BEHAVIOR**

The classes are the code set's: Latin-1's, the same in every
language. A language decides the order its letters sort in
(`StrnCmp`), not which characters are letters.

**CONTEXT**

- Waits: no.
- Interrupts: safe; it reads a table.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

A byte from a string is handed over as it is: the code set's
characters are its bytes.

**BUGS**

None known.

**SEE ALSO**

`IsUpper`, `ConvToUpper`

**EXAMPLES**

```zig
if (lb.IsLower(loc, first)) first = @intCast(lb.ConvToUpper(loc, first));
```

## IsPrint

Says whether a character is printed, blanks included.

**SYNOPSIS**

```zig
fn IsPrint(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool
```

**SINCE**

1.0. LVO -60.

**INPUTS**

- `loc` - a locale, from OpenLocale.
- `character` - a character of the locale's code set, by its number.

**RESULT**

True for what IsGraph is true for, and for the space (32) and the
space that does not break (160). False for anything past 255.

**BEHAVIOR**

The classes are the code set's: Latin-1's, the same in every
language. A language decides the order its letters sort in
(`StrnCmp`), not which characters are letters.

**CONTEXT**

- Waits: no.
- Interrupts: safe; it reads a table.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

A byte from a string is handed over as it is: the code set's
characters are its bytes.

**BUGS**

None known.

**SEE ALSO**

`IsGraph`, `IsCntrl`

**EXAMPLES**

```zig
const shown: u8 = if (lb.IsPrint(loc, byte)) byte else '.';
```

## IsPunct

Says whether a character is punctuation.

**SYNOPSIS**

```zig
fn IsPunct(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool
```

**SINCE**

1.0. LVO -64.

**INPUTS**

- `loc` - a locale, from OpenLocale.
- `character` - a character of the locale's code set, by its number.

**RESULT**

True for a character that is printed and neither blank, a letter nor
a digit: `!` to `/`, `:` to `@`, `[` to `` ` ``, `{` to `~`, ¡ to ¿ but
ª, µ and º, and × and ÷. False for anything past 255.

**BEHAVIOR**

The classes are the code set's: Latin-1's, the same in every
language. A language decides the order its letters sort in
(`StrnCmp`), not which characters are letters.

**CONTEXT**

- Waits: no.
- Interrupts: safe; it reads a table.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

A byte from a string is handed over as it is: the code set's
characters are its bytes.

**BUGS**

None known.

**SEE ALSO**

`IsGraph`, `IsAlNum`

**EXAMPLES**

```zig
while (at < text.len and lb.IsPunct(loc, text[at])) at += 1;
```

## IsSpace

Says whether a character is blank.

**SYNOPSIS**

```zig
fn IsSpace(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool
```

**SINCE**

1.0. LVO -68.

**INPUTS**

- `loc` - a locale, from OpenLocale.
- `character` - a character of the locale's code set, by its number.

**RESULT**

True for the space, for tab, line feed, vertical tab, form feed and
carriage return (9 to 13), and for the space that does not break
(160). False for anything past 255.

**BEHAVIOR**

The classes are the code set's: Latin-1's, the same in every
language. A language decides the order its letters sort in
(`StrnCmp`), not which characters are letters.

**CONTEXT**

- Waits: no.
- Interrupts: safe; it reads a table.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

A byte from a string is handed over as it is: the code set's
characters are its bytes.

**BUGS**

None known.

**SEE ALSO**

`IsPrint`, `IsGraph`

**EXAMPLES**

```zig
while (at < text.len and lb.IsSpace(loc, text[at])) at += 1;
```

## IsUpper

Says whether a character is a capital letter.

**SYNOPSIS**

```zig
fn IsUpper(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool
```

**SINCE**

1.0. LVO -72.

**INPUTS**

- `loc` - a locale, from OpenLocale.
- `character` - a character of the locale's code set, by its number.

**RESULT**

True for A to Z, and À to Þ but ×. False for anything past 255.

**BEHAVIOR**

The classes are the code set's: Latin-1's, the same in every
language. A language decides the order its letters sort in
(`StrnCmp`), not which characters are letters.

**CONTEXT**

- Waits: no.
- Interrupts: safe; it reads a table.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

A byte from a string is handed over as it is: the code set's
characters are its bytes.

**BUGS**

None known.

**SEE ALSO**

`IsLower`, `ConvToLower`

**EXAMPLES**

```zig
if (lb.IsUpper(loc, key)) shifted = true;
```

## IsXDigit

Says whether a character is a hexadecimal digit.

**SYNOPSIS**

```zig
fn IsXDigit(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool
```

**SINCE**

1.0. LVO -76.

**INPUTS**

- `loc` - a locale, from OpenLocale.
- `character` - a character of the locale's code set, by its number.

**RESULT**

True for 0 to 9, A to F and a to f. False for anything past 255.

**BEHAVIOR**

The classes are the code set's: Latin-1's, the same in every
language. A language decides the order its letters sort in
(`StrnCmp`), not which characters are letters.

**CONTEXT**

- Waits: no.
- Interrupts: safe; it reads a table.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

A byte from a string is handed over as it is: the code set's
characters are its bytes.

**BUGS**

None known.

**SEE ALSO**

`IsDigit`

**EXAMPLES**

```zig
while (at < text.len and lb.IsXDigit(loc, text[at])) at += 1;
```

## OpenCatalogA

Opens a program's catalog in the first of the locale's languages that has one.

**SYNOPSIS**

```zig
fn OpenCatalogA(lb: *LocaleBase, loc: ?*const locale.Locale, name: [*:0]const u8, tag_list: ?[*]const utility.TagItem) ?*locale.Catalog
```

**SINCE**

1.0. LVO -108.

**INPUTS**

- `loc` - the locale whose languages are tried; null for the default.
- `name` - the catalog's name: a program's place on the disk and
  `.catalog` (`c/test/locale.catalog`), `sys/<module>.catalog` for the
  system's own.
- `tag_list` - OC_BuiltInLanguage, the language of the strings built
  into the program (`english` if not given); OC_Version, the version
  the catalog must have (any if 0 or not given); OC_Language, a
  language to try before the locale's; OC_BuiltInCodeSet, taken and
  not used. Null for none.

**RESULT**

The catalog, or null when the strings built in are the ones to use:
the language they are in comes before any with a catalog, or none of
the languages has one of that version.

**BEHAVIOR**

OC_Language and then each of the locale's preferred languages is
tried in turn. The language built in ends the search - its strings
need no catalog. For any other, a catalog already loaded is taken;
else `PROGDIR:Catalogs/<language>/<name>` is read, when the caller has
a program directory, and then `LOCALE:Catalogs/<language>/<name>`.
The strings are converted to the locale's code set as they are read.

No requester asks for PROGDIR: or LOCALE: when either is missing.

**CONTEXT**

- Waits: yes, to read a file; not for a catalog already loaded.
- Interrupts: no.
- Locks: takes the library's lock, never across a read. None may be
  held that a handler needs.
- Process: yes, for the files; a Task gets only catalogs already
  loaded.

**OWNERSHIP**

The catalog is the caller's to give back with CloseCatalog. It stays
loaded after that until the library is asked to give memory back, so
the next program to open it has it at once.

**NOTES**

sdk.locale's `Strings` opens a program's catalog with the name and the
version tools/catcomp put into its strings.

**BUGS**

None known.

**SEE ALSO**

`CloseCatalog`, `GetCatalogStr`, `OpenLocale`

**EXAMPLES**

```zig
const tags = [_]utility.TagItem{ .{ .tag = locale.OC_Version, .data = 1 }, .{} };
const catalog = lb.OpenCatalogA(null, "c/test/locale.catalog", &tags);
defer lb.CloseCatalog(catalog);
const hello = lb.GetCatalogStr(catalog, 1, "Hello");
```

## OpenLocale

Makes a locale from a settings file, or answers the default one.

**SYNOPSIS**

```zig
fn OpenLocale(lb: *LocaleBase, name: ?[*:0]const u8) ?*locale.Locale
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `name` - the path of a settings file, as `ENV:Sys/locale.prefs` is
  written; null for the default locale.

**RESULT**

The locale, or null when the settings file cannot be read, the country
it names has no file, none of the languages it names has one, or a
file holds a value its key does not take. IoErr says which:
ERROR_OBJECT_NOT_FOUND and the rest of dos's for a file that cannot be
read, ERROR_OBJECT_WRONG_TYPE for a value, ERROR_UNMATCHED_QUOTES for
a quote not closed, ERROR_OBJECT_TOO_LARGE for more text than a locale
holds (4 KiB), ERROR_INVALID_COMPONENT_NAME for a name too long for a
path, ERROR_NO_FREE_STORE.

**BEHAVIOR**

With null, the default locale is answered, held once more: the one
SetDefaultLocale last made the default, or the library's own - English,
and the dates dos writes - before it has.

With a name, a locale is made from the file: its COUNTRY's file in
LOCALE:Countries, the first of its LANGUAGES that has a file in
LOCALE:Languages (English needs none), and the time zone's rule from
ENV:Sys/timezone. A field no file sets keeps the library's own
value. A name may be given with its `.country` or `.language` or
without. Every file is UTF-8 text, converted to the locale's code set.

A settings file:

  # The country, and the languages in the order they are wanted.
  COUNTRY=deutschland
  LANGUAGES=deutsch,english

**CONTEXT**

- Waits: yes, to read the files; not with null.
- Interrupts: no.
- Locks: takes the library's lock, for a moment, with null. None may
  be held that a handler needs.
- Process: yes, with a name: the files are read through dos. A Task
  will do with null.

**OWNERSHIP**

The locale is the caller's to give back with CloseLocale. It does not
change while it is held, and every string it points at is good until
then.

**NOTES**

A key a file has and the library does not know is passed over, so a
file written for a later library still reads.

**BUGS**

None known.

**SEE ALSO**

`CloseLocale`, `SetDefaultLocale`, `GetLocaleStr`

**EXAMPLES**

```zig
const loc = lb.OpenLocale(null) orelse return;
defer lb.CloseLocale(loc);
lb.FormatDate(loc, loc.date_format, &stamp, &out.hook);
```

## ParseDate

Reads a date by a template, in the locale's words.

**SYNOPSIS**

```zig
fn ParseDate(lb: *LocaleBase, loc: *const locale.Locale, date: *dos.DateStamp, template: [*:0]const u8, get_char_func: *utility.Hook) bool
```

**SINCE**

1.0. LVO -100.

**INPUTS**

- `loc` - a locale, from OpenLocale: its words for the days, the
  months, and before and after noon.
- `date` - where the moment goes.
- `template` - what the text holds, with a conversion after each `%`
  (below); a locale's formats (`loc.short_date_format`, ...) are
  templates.
- `get_char_func` - called through utility's CallHookPkt with the
  locale as the object, for the text's next byte each time; 0 ends the
  text.

**RESULT**

True with `date` set when the whole text is a date by the template;
false, and `date` as it was, when it is not, names a day the month
does not have, or is longer than 127 bytes.

**BEHAVIOR**

The conversions, each reading what FormatDate writes for it:

- `%a` `%A` - a weekday's name, long or short; it is read and not
  used.
- `%b` `%B` `%h` `%m` - a month, by its name, long or short, or its
  number.
- `%d` `%e` - the day of the month, 1 to 31.
- `%H` `%I` `%q` `%Q` - the hour, 0 to 23; `%p` after it the locale's
  AM_STR or PM_STR, which makes it an hour of twelve.
- `%M` `%S` - the minute and the second, 0 to 59.
- `%y` - the year's last two digits, 78 to 99 for 1978 to 1999 and
  below 78 for 2000 to 2077; `%Y` the year, 1978 to 9999.
- `%D` `%x`, `%T` `%X`, `%R`, `%r`, `%c` - their forms in FormatDate.
- `%Z` - a time zone's name, read and not used.
- `%n` `%t` and a blank - any blanks, or none; `%%` a `%`.

Any other character must be in the text where the template has it.
Names and letters are matched whatever their case, the longest name
that fits first; a number may have blanks before it. What the template
leaves out is 1 January 1978, 00:00:00: a template of a time alone
reads a moment on that day.

**CONTEXT**

- Waits: no, but the hook may.
- Interrupts: no; the hook is called through utility.library.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

sdk.locale's `StringHook` reads a string. Any other conversion in the
template makes the text no date.

**BUGS**

None known.

**SEE ALSO**

`FormatDate`, dos.library `StrToDate`

**EXAMPLES**

```zig
var in = locale.StringHook.init("29.10.2026");
var date: dos.DateStamp = undefined;
if (!lb.ParseDate(loc, &date, loc.short_date_format, &in.hook)) return error.NoDate;
```

## SetDefaultLocale

Makes a locale the default, which `OpenLocale(null)` answers and dos writes and reads dates and its texts in.

**SYNOPSIS**

```zig
fn SetDefaultLocale(lb: *LocaleBase, loc: *locale.Locale) ?*locale.Locale
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `loc` - a locale from OpenLocale; it must not be null.

**RESULT**

The default before, with the library's hold on it handed to the
caller.

**BEHAVIOR**

The library holds `loc` once more for as long as it is the default, so
the caller may give its own hold back at once. A program that opens the
default locale after this gets `loc`; one that opened it before keeps
the one it has.

From the first call on, dos.library's DateToStr, StrToDate and Fault
are the library's, and the library stays in memory. DateToStr writes
the default locale's words - the months' short names, the weekdays,
"today" and the rest - and dos.FORMAT_DEF is the locale's short date
and time. StrToDate reads them, and what it does not read it hands to
dos's own, so English words and dos's forms still work. Fault answers
a code's text from the catalog `sys/dos.catalog` in the locale's
languages, opened here each time; dos's own text where that has none.

**CONTEXT**

- Waits: for the library's lock, for a moment, and for the catalog's
  file.
- Interrupts: no.
- Locks: takes the library's lock, never across the file read.
- Process: a process, for dos's catalog to be read; a Task gets the
  catalog only when it is loaded already.

**OWNERSHIP**

The locale answered is the caller's to give back with CloseLocale; the
caller's hold on `loc` stays the caller's.

**NOTES**

C:SetPrefs calls this at boot with the locale ENV:Sys/locale.prefs
describes; few programs have reason to.

**BUGS**

None known.

**SEE ALSO**

`OpenLocale`, `CloseLocale`, `OpenCatalogA`, dos.library `DateToStr`,
`StrToDate`, `Fault`

**EXAMPLES**

```zig
const loc = lb.OpenLocale(locale.prefs_file) orelse return error.NoLocale;
lb.CloseLocale(lb.SetDefaultLocale(loc));
lb.CloseLocale(loc);
```

## StrConvert

Writes a string as a key whose plain byte order is the string's order in the locale.

**SYNOPSIS**

```zig
fn StrConvert(_: *LocaleBase, loc: *const locale.Locale, string: [*:0]const u8, buffer: [*]u8, buffer_size: u32, compare_type: u32) u32
```

**SINCE**

1.0. LVO -92.

**INPUTS**

- `loc` - a locale, from OpenLocale.
- `string` - the string, in the locale's code set.
- `buffer` - where the key goes.
- `buffer_size` - its size in bytes, the NUL that ends the key
  counted.
- `compare_type` - SC_ASCII, SC_COLLATE1 or SC_COLLATE2; any other
  number is taken as SC_ASCII.

**RESULT**

The bytes of the key written, the NUL left out; 0 when `buffer_size`
is 0, and nothing is written then.

**BEHAVIOR**

Two keys compared byte by byte, as unsigned bytes, up to the NUL that
ends the first, come out as StrnCmp compares their strings with the
same type. A key is one byte
per character for SC_ASCII and SC_COLLATE1, two and one more for
SC_COLLATE2.

A key cut short by the buffer still orders by what it holds.

**CONTEXT**

- Waits: no.
- Interrupts: safe; it reads the locale and the string.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The key is the caller's, in the caller's buffer.

**NOTES**

A key is only good with the locale it was made with: another language
orders differently.

**BUGS**

None known.

**SEE ALSO**

`StrnCmp`

**EXAMPLES**

```zig
var key: [2 * 108 + 2]u8 = undefined;
_ = lb.StrConvert(loc, name, &key, key.len, locale.SC_COLLATE2);
```

## StrnCmp

Compares two strings in the order of the locale's language.

**SYNOPSIS**

```zig
fn StrnCmp(_: *LocaleBase, loc: *const locale.Locale, string1: [*:0]const u8, string2: [*:0]const u8, length: i32, compare_type: u32) i32
```

**SINCE**

1.0. LVO -88.

**INPUTS**

- `loc` - a locale, from OpenLocale.
- `string1`, `string2` - the strings, in the locale's code set.
- `length` - the most bytes of each to compare; below 0 for all.
- `compare_type` - SC_ASCII, SC_COLLATE1 or SC_COLLATE2; any other
  number is taken as SC_ASCII.

**RESULT**

-1 when `string1` comes first, 0 when the two are the same in that
order, 1 when `string2` comes first. 0 when `length` is 0.

**BEHAVIOR**

SC_ASCII leaves the case of letters out and compares their capitals
by their codes, as a file name is compared. SC_COLLATE1 leaves case
and accent out and orders the letters as the language does: in
Swedish Å, Ä and Ö come after Z, in Spanish Ñ after N, and anything
that is not a letter comes before every letter. SC_COLLATE2 orders as
SC_COLLATE1 and, where that finds the two the same, by the first byte
they differ in: the order a sorted list is shown in, where `apple`,
`Apple` and `äpple` stand together and always in the same order.

A string that ends where the other goes on comes first.

**CONTEXT**

- Waits: no.
- Interrupts: safe; it reads the locale and the strings.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

To sort many strings, StrConvert each once and compare the keys
byte by byte: the order is the same.

**BUGS**

A letter is weighed alone: `ß` is an `s` and `æ` an `a`, not two
letters each.

**SEE ALSO**

`StrConvert`, utility.library `Stricmp`

**EXAMPLES**

```zig
if (lb.StrnCmp(loc, left.name, right.name, -1, locale.SC_COLLATE2) > 0) swap(left, right);
```
