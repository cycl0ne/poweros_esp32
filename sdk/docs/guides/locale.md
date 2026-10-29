# Locale

A locale is the way a place writes things down: a country's dates,
times, numbers and money, and a language's words - the names of the
days and months, yes and no - and the order its letters sort in.
`locale.library`, in `LIBS:`, makes locales from the files in
`LOCALE:`, keeps one as the system's default, and gives a program its
texts in the language the user prefers, from a catalog.

From the moment a default locale is set, dos writes and reads dates in
it and answers its error texts in its language; so does the shell, whose
messages are dos's texts too.

This guide is the setting first, then the files, a locale in a program,
a program's catalogs, and what dos does with the default.

## Setting the default: `ENV:Sys/locale.prefs`

Prefs' Region page sets it: the country from those in
`LOCALE:Countries`, the languages from those in `LOCALE:Languages` and
English, each one picked going on the preferred list after the ones on
it, and the time zone; a date, a time, a number and an amount of money
show how the settings look before they are saved. Save and Use write the
file and hand it over as described below. By hand:

One line names the country and, when they are not the country's own,
the languages wanted, the preferred first:

```
COUNTRY=deutschland
COUNTRY=schweiz LANGUAGES="francais, deutsch, english"
```

`C:SetPrefs` reads it at boot, after `S:Startup-Sequence` has assigned
`LOCALE:` to `SYS:locale`, makes the locale it describes the default, and
leaves the preferred language in the global variable `Language`. Without
the file, or with no line in it, the system stays in its own locale:
English, with the United States' numbers and money and dos's own forms
of the date (`29-Oct-2026`, `14:05:09`). To change it while running,
write the file and run `SetPrefs`, as the Region page does; `SetPrefs SHOW` prints it as
`LOCALE deutschland, deutsch`. A program opened the default before the
change keeps the one it has until it closes it.

LANGUAGES holds ten languages at most, each in quotes with the rest when
there are several; a blank parts one setting from the next. The first of
them that has a file in `LOCALE:Languages` gives the locale its words;
English needs none. The whole list stays the order a catalog is looked
for in (below). `sdk.prefs.locale` reads the file and writes it, as the
Region page does.

The countries there are: australia, belgie, belgique, canada,
canada_francais, danmark, deutschland, espana, france, great_britain,
italia, nederland, norge, osterreich, portugal, schweiz, suisse, sverige,
svizzera, united_kingdom and united_states. The languages: dansk,
deutsch, espanol, francais, italiano, nederlands, norsk, portugues and
svenska, and english, which is built in.

## The files

Every file in `LOCALE:` and the settings file are UTF-8 text, a mark at
the start allowed, read as `KEY=value` pairs - a value with a blank in
double quotes, with no escapes - and a line starting with `#` or `;` is a
comment. A key the library does not know is passed over, and one left
out keeps the value of the system's own locale. A file that is not UTF-8
is read as Latin-1.

### A country: `LOCALE:Countries/<name>.country`

| Key | What | Example |
|---|---|---|
| `CODE` | the country's ISO 3166 code | `DE` |
| `TELEPHONE` | its telephone code | `49` |
| `MEASURE` | `METRIC`, `AMERICAN`, `IMPERIAL` or `BRITISH` | `METRIC` |
| `FIRSTDAY` | the first day of its week, `SUNDAY` to `SATURDAY` | `MONDAY` |
| `LANGUAGE` | the language spoken there, for settings without LANGUAGES | `deutsch` |
| `DATETIME`, `DATE`, `TIME` | the long forms, as FormatDate templates | `"%A, %e. %B %Y"` |
| `SHORTDATETIME`, `SHORTDATE`, `SHORTTIME` | the short forms | `%d.%m.%Y` |
| `DECIMAL`, `GROUP`, `FRACGROUP` | the decimal point and the separators between groups of digits, before and after it | `,` `.` |
| `GROUPING`, `FRACGROUPING` | the groups' sizes from the point: `3`, `3,2` for three and then twos, `NONE` | `3` |
| `MONDECIMAL`, `MONGROUP`, `MONFRACGROUP`, `MONGROUPING`, `MONFRACGROUPING` | the same for amounts of money | |
| `MONFRACDIGITS`, `MONINTFRACDIGITS` | digits after the point, with the currency's symbol and with its code | `2` |
| `CURRENCY`, `SMALLCURRENCY`, `INTCURRENCY` | the currency's symbol, its small unit's, its ISO 4217 code | `€` `ct` `EUR` |
| `POSITIVESIGN`, `NEGATIVESIGN` | the signs of an amount | `""` `-` |
| `POSITIVESPACE`, `NEGATIVESPACE` | `YES` for a blank between the amount and the symbol | `YES` |
| `POSITIVESIGNAT`, `NEGATIVESIGNAT` | `BEFORE`, `AFTER`, `BEFORECURRENCY`, `AFTERCURRENCY` or `PARENS` | `BEFORE` |
| `POSITIVECURRENCYAT`, `NEGATIVECURRENCYAT` | the symbol `BEFORE` or `AFTER` the amount | `AFTER` |

The short date and time are what dos writes with `FORMAT_DEF`, so each
must fit 15 characters.

### A language: `LOCALE:Languages/<name>.language`

Its words by their names in `sdk.locale` - `DAY_1` (Sunday) to `DAY_7`,
`ABDAY_1` to `ABDAY_7`, `MON_1` to `MON_12`, `ABMON_1` to `ABMON_12`,
`YESSTR`, `NOSTR`, `AM_STR`, `PM_STR`, `SOFTHYPHEN`, `HARDHYPHEN`,
`OPENQUOTE`, `CLOSEQUOTE`, `YESTERDAYSTR`, `TODAYSTR`, `TOMORROWSTR` and
`FUTURESTR`:

```
DAY_1=Sonntag DAY_2=Montag ...
YESTERDAYSTR=Gestern TODAYSTR=Heute TOMORROWSTR=Morgen FUTURESTR=Zukunft
```

and the letters the language sorts after one of the alphabet's rather
than with it, a comma between those that sort apart and none between
those that sort as one:

```
AFTER_Z=Å,ÄÆ,ÖØ
```

is Swedish: Å, then Ä and Æ, then Ö and Ø, all after Z. Every other
accented letter sorts with its own (`é` with `e`, `ß` with `s`).

## A locale in a program

```zig
const locale = sdk.locale;
const LocaleBase = sdk.interface.locale.LocaleBase;

const library = sys.OpenLibrary(locale.LOCALENAME, 1) orelse return error.NoLocale;
defer sys.CloseLibrary(library);
const lb: *LocaleBase = @ptrCast(library);
const loc = lb.OpenLocale(null) orelse return error.NoLocale; // the default
defer lb.CloseLocale(loc);
```

`OpenLocale` with a settings file's path makes a locale of that file
instead, held by the program alone; null with IoErr set says which file
could not be read. `loc`'s fields are the country's: `short_date_format`,
`decimal_point`, `mon_cs` and the rest; `GetLocaleStr(loc, locale.DAY_1)`
is one of the language's words.

### Dates

`FormatDate(loc, template, &stamp, &hook)` writes a DateStamp by a
template, a byte at a time to a hook: `sdk.locale.BufferHook` collects
them in a buffer.

```zig
var text: [64]u8 = undefined;
var out = locale.BufferHook.init(&text);
lb.FormatDate(loc, loc.date_format, &now, &out.hook);
// out.text() is "Donnerstag, 29. Oktober 2026"
```

The conversions: `%a %A` the weekday, `%b %h %B` the month, `%d %e` the
day of the month (`01`, ` 1`), `%m %y %Y`, `%H %q` the hour of 24
(`09`, `9`), `%I %Q` of 12 with `%p` the language's AM_STR or PM_STR,
`%M %S`, `%j` the day of the year, `%w` the weekday's number, `%U %W` the
week of the year from Sunday and from Monday, `%Z` the time zone's name
then (`CET`, `CEST`, from the rule in `ENV:Sys/timezone`), the
composites `%D %x %T %X %R %r %c %C`, and `%n %t`. Any other character
after a `%` is written as it is.

`ParseDate(loc, &stamp, template, &hook)` reads a date by the same
templates, the names in either case and the longest that fits first, a
month by its name or its number; `sdk.locale.StringHook` reads a string.
What the template leaves out is 1 January 1978, 00:00.

### Numbers

`FormatString(loc, template, &stream, &hook)` writes values as
`RawDoFmt` does, with two more things: `%D` and `%U` group a number's
digits as the country does (`1.234.567`), and `%2$s` takes the second
value wherever it stands, so a translation can put a sentence's values
in its own order and still be handed the same stream. `sdk.exec.fmtStream`
packs the values.

### Characters and order

`IsAlpha`, `IsUpper` and the rest, `ConvToLower` and `ConvToUpper` work
on the system's code set (below). `StrnCmp(loc, a, b, length, type)`
compares: `SC_ASCII` byte by byte, case aside; `SC_COLLATE1` by the
language's order, case and accents aside; `SC_COLLATE2` the same, then
accents and case deciding between words that are otherwise equal.
`StrConvert` makes the key that compares as `SC_COLLATE1` or
`SC_COLLATE2` does, byte by byte, for sorting many words fast.

## A program's texts: catalogs

A program's texts are written once, in its descriptor (`.cd`), and built
into it; a translation (`.ct`) of them is a catalog file on the disk,
which the program reads when the user prefers that language.

```
; C:Count's texts, in English.
#version 1
MSG_FILES (1//)
%ld files in %s\n
MSG_NONE (//)
No files\n
```

A string is its name, then its number and the least and most characters
its translations may have, `(number/least/most)` - a number left out is
one past the one before - and its text on the next line, with C's
escapes; `\x20` keeps a blank at the end. A translation:

```
## version $VER: c/count.catalog 1.0 (29.10.2026)
## language deutsch
## codeset 106
MSG_FILES
%2$s hat %1$ld Dateien\n
```

A string it leaves out is the one built in. `sdk/tools/catcomp` checks
every translation against the descriptor - names, lengths, and that it
takes the same values of the same sizes, by place or in order - and
fails the build when one is wrong.

In `src/disk/build.zig` a program names its descriptor, and its
translations go in `catalogs`:

```zig
.{ .disk = "c/count", .source = "c/count/count.zig", .name = "count", .strings = "c/count/count.cd" },

pub const catalogs = [_]Catalog{
    .{ .disk = "locale/Catalogs/deutsch/c/count.catalog", .descriptor = "c/count/count.cd", .translation = "c/count/catalogs/deutsch.ct", .name = "c/count.catalog" },
};
```

The program then imports its strings as the module `strings` and reads
them through `sdk.locale.Strings`:

```zig
const strings = @import("strings");
const Text = sdk.locale.Strings(strings);

var text = Text.open(sys);
defer text.close();
_ = text.printf(dl, .MSG_FILES, .{ @as(i64, count), name });
_ = dl.PutStr(text.get(.MSG_NONE));
```

`printf` checks the values against the string built in when the program
is compiled, and writes by FormatString, so a translation's `%2$s` and
`%D` work; `format` does the same into a buffer, cut to it. Without
locale.library, or without a catalog in any of the languages the default
locale prefers, every string is the one built in.

A table made when the program is compiled - menus, a ribbon, a chooser's
labels - holds each label's string name rather than its text, and the
program makes the table it hands over from it when it runs, each label
`text.get`'s; the table it made stays as long as what shows it. A
requester's text goes through RawDoFmt, which takes its values in
order, so a translation of one keeps them so. Another process of the
program's may be handed the strings and read them while the program
keeps them open.

Notepad, Sheet and the Player have their texts in catalogs, German on
the disk (`LOCALE:Catalogs/deutsch/programs/<Program>.catalog`); their
descriptors and translations are beside their sources.

`OpenCatalogA(loc, name, tags)` looks for `name` in `OC_Language`'s
language, if given, then in each of the locale's languages in turn, and
stops at the language the strings built in are in (`OC_BuiltInLanguage`,
English unless said): then there is no catalog to read. In each language
it tries `PROGDIR:Catalogs/<language>/<name>`, then
`LOCALE:Catalogs/<language>/<name>`; `OC_Version` asks for one version
only. A catalog loaded once is kept, and the next program to ask has it
at once. Only a process reads catalog files; a Task gets the ones loaded
already.

## dos in the default locale

The first `SetDefaultLocale` puts the library in front of three of
dos.library's calls, and keeps the library in memory from then on:

- `DateToStr` writes its strings in the locale's words
  (`Donnerstag 29-Okt-2026`, and `Heute` with `DTF_SUBST`);
  `dos.FORMAT_DEF` is the country's short date and time.
- `StrToDate` reads the language's words (`Gestern`, `Do`), and dates in
  the format's order with the month's name in the language or as a
  number, the year in four digits or two; what it does not read is
  handed to dos's own, so a script's `Today` and `29-Oct-2026` still mean
  what they meant.
- `Fault`, and with it PrintFault and the shell's messages, takes the
  text of a code from `LOCALE:Catalogs/<language>/sys/dos.catalog`, and
  dos's own text where that has none.

dos's texts are described in `src/rom/libs/dos/text/dos.cd`, each by its
code; a ROM test keeps the descriptor and dos's table the same. The
German translation beside it is built into the disk's
`LOCALE:Catalogs/deutsch/sys/dos.catalog`.

## The code set

The system's text is Latin-1, one byte a character. The files are
UTF-8 and are converted as they are read; a character Latin-1 does not
have becomes `?` - the euro sign `€` and the German quotes `„“` among
them, until the system's text is UTF-8. A width or a length in
FormatDate, FormatString and the catalogs' least and most counts
characters.

## Commands

| Command | What it does |
|---|---|
| `C:SetPrefs` | makes the locale `ENV:Sys/locale.prefs` describes the default, with the rest of the system's settings; `SHOW` prints the country and language |
| `C:test/Locale [DATE <date>] [WORDS <words>...]` | prints the default locale - its country, languages, time zone and catalog, now in each of its formats, a number and its money - in the words of its own catalog; reads DATE by the short date and sorts WORDS in the language's order |

In `SYS:` itself, `Locale` names the `SYS:locale` directory first; call
the command as `C:test/Locale` there.
