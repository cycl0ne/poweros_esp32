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
hanguk, india, italia, nederland, nihon, norge, osterreich, portugal,
schweiz, suisse, sverige, svizzera, taiwan, united_kingdom,
united_states and zhongguo. The languages: dansk, deutsch, espanol,
francais, hangugeo, hindi, italiano, nederlands, nihongo, norsk,
portugues, svenska, zhongwen and zhongwen-fanti, and english, which is
built in. A file is named by the language's own word for itself, in
ASCII, so that any keyboard types it. India and Hindi are on the
64-bit machines' disks only, where `FONTS:devanagari` is, the font
their words are drawn in: `COUNTRY=india` writes
`गुरुवार, 12 नवंबर 2026`, `2:05 अपराह्न` and `12,34,567`.

Japan (`nihon`, `nihongo`), Korea (`hanguk`, `hangugeo`), China
(`zhongguo`, `zhongwen`: the simplified characters) and Taiwan
(`taiwan`, `zhongwen-fanti`: the traditional ones) are on those disks
too. Their dates begin with the year, and the month's name holds its
sign, so a template writes it with `%B` or `%b` and no sign of its own:

| `COUNTRY=` | the date | the short date | the short time |
|---|---|---|---|
| nihon | `2026年11月12日木曜日` | `2026/11/12` | `14:05` |
| hanguk | `2026년 11월 12일 목요일` | `2026. 11. 12.` | `오후 2:05` |
| zhongguo | `2026年11月12日星期四` | `2026/11/12` | `14:05` |
| taiwan | `2026年11月12日 星期四` | `2026/11/12` | `下午2:05` |

Their words are drawn in a font that has them: the `cjk-` families of
`FONTS:` ([fonts guide](fonts.md)), where a disk has them.

## The files

A country's file, a language's and the settings file are UTF-8 text, a mark at
the start allowed, read as `KEY=value` pairs - a value with a blank in
double quotes, with no escapes - and a line starting with `#` or `;` is a
comment. A key the library does not know is passed over, and one left
out keeps the value of the system's own locale. A file that is not UTF-8
is one an editor wrote in code page 1252, the Western code page of
Windows, and is read as that.

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
after a `%` is written as it is. A `-` before a number's letter writes
the number with no zero and no blank before it (locale.library 1.5):
`%-d` is `5`, `%-m` is `1`, and `%Y年%-m月%-d日` is `2026年1月5日`.

`ParseDate(loc, &stamp, template, &hook)` reads a date by the same
templates, the names in either case and the longest that fits first, a
month by its name or its number, a number with or without a zero, and
the word of noon before the hour or after it (`오후 2:05`, `2:05 PM`);
`sdk.locale.StringHook` reads a string. What the template leaves out is
1 January 1978, 00:00.

### Numbers

`FormatString(loc, template, &stream, &hook)` writes values as
`RawDoFmt` does, with two more things: `%D` and `%U` group a number's
digits as the country does (`1.234.567`), and `%2$s` takes the second
value wherever it stands, so a translation can put a sentence's values
in its own order and still be handed the same stream. `sdk.exec.fmtStream`
packs the values.

### Characters and order

`IsAlpha`, `IsUpper` and the rest take a code point and answer by
Unicode's classes, the same in every language: `IsAlpha` is true for a
letter of any script, `IsDigit` for a decimal digit of any script,
`IsPunct` for what is printed and neither blank, a letter nor a digit -
`€` and the emoji among them. `ConvToLower` and `ConvToUpper` are
Unicode's simple case, a character to a character (`ÿ` to `Ÿ`; `ß`
stays). A character of a string is what `sdk.utility.utf8.next` reads.

`StrnCmp(loc, a, b, length, type)` compares two UTF-8 strings character
by character: `SC_ASCII` by the capitals' code points; `SC_COLLATE1` by
the language's order, case and marks aside - `ł` is an `l`, `č` a `c`,
`æ` an `a`, `ß` an `s`, a mark written on the letter before counts for
nothing, and in Swedish `Å`, `Ä` and `Ö` come after `Z`; `SC_COLLATE2`
the same, then the first byte that differs deciding between words that
are otherwise equal. What is no letter comes before every letter, the
Latin letters before those of other scripts, which follow in the order
of their code points. Devanagari has an order of its own inside its
block, the one a Hindi dictionary has: `ॐ`, then the signs written on a
syllable - anusvara and candrabindu as one, then visarga - the vowels,
the consonants, and the vowel signs with the virama last, so that
`कंगन` comes before `कई`, `कम` and `कल` before `का`, and `क्य` after
`की`; a consonant with a nukta is its consonant (`फ़िल्म` is `फिल्म`), and
the letters added to the block later stand with the ones they belong
to. The kana are in the order of their sounds, `あ` to `ん`: the
hiragana, the katakana and the halfwidth katakana of one sound are one
letter, and so are a small letter and a voiced one with theirs, so
`かさ`, `ガス` and `きあ` follow each other and `カタカナ` is `かたかな`;
the long vowel's mark `ー` and the iteration marks come before `あ`
(`キー` before `きあ`). Hangul and the Han characters are in the order
of their code points, which is a Korean dictionary's for the one and
radicals and strokes for the other (locale.library 1.6).
`tools/foldgen collate` and `tools/foldgen kana` make the two tables
from Unicode's collation element table. `length` counts bytes. `StrConvert` makes the key
that compares as `StrnCmp` does, byte by byte, for sorting many words
fast: at most twice the string's bytes for `SC_ASCII` and `SC_COLLATE1`,
three times and one more for `SC_COLLATE2`.

A language's `AFTER_<letter>=` line names the letters it sorts after one
of the alphabet's - `AFTER_Z=Å,ÄÆ,ÖØ`, a comma between those that sort
apart - any letter of any script, both cases at once, 64 at most.

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

The catalog is named after the program's place on the disk
(`c/count.catalog`) unless the program's `catalog` names it: the
system's own modules keep theirs under `sys/`, as the desktop's
`sys/anvil.catalog`.

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

Notepad, Sheet, the Player and Movie have their texts in catalogs,
German on the disk (`LOCALE:Catalogs/deutsch/programs/<Program>.catalog`),
and so have the Clock (`LOCALE:Catalogs/deutsch/System/Clock.catalog`)
and the desktop (`LOCALE:Catalogs/deutsch/sys/anvil.catalog`); their
descriptors and translations are beside their sources. The same
catalogs are there in Hindi (`LOCALE:Catalogs/hindi/`), Japanese
(`nihongo/`), Korean (`hangugeo/`) and Chinese in the simplified
characters (`zhongwen/`) on the 64-bit machines' disks - a `Catalog`
that is `.wide = true` in the build goes on those only. These
translations are drafts that no reader of the language has gone
through yet, as each one's first lines say. A gadget's shortcut in the
Hindi ones is a Devanagari letter, which a keyboard reaches with the
`inscript` keymap ([Keymaps](#keymaps)). In the Japanese, Korean and Chinese ones it is the
English text's letter in parentheses behind the label (`保存(_S)`,
`열기(_O)...`): a keymap types none of these scripts' characters, and
the key stays the one the English label has.

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
  `dos.FORMAT_DEF` is the country's short date and time. Each string
  has `dos.LEN_DATSTRING` bytes, 48, which hold a day's name in any
  of the languages (`गुरुवार` is 21 bytes); a longer text is cut after
  a whole character.
- `StrToDate` reads the language's words (`Gestern`, `Do`), and dates in
  the format's order with the month's name in the language or as a
  number, the year in four digits or two; what it does not read is
  handed to dos's own, so a script's `Today` and `29-Oct-2026` still mean
  what they meant. A language with one word for yesterday and tomorrow
  (Hindi's `कल`) has it read as yesterday.
- `Fault`, and with it PrintFault and the shell's messages, takes the
  text of a code from `LOCALE:Catalogs/<language>/sys/dos.catalog`, and
  dos's own text where that has none.

dos's texts are described in `src/rom/libs/dos/text/dos.cd`, each by its
code; a ROM test keeps the descriptor and dos's table the same. The
German translation beside it is built into the disk's
`LOCALE:Catalogs/deutsch/sys/dos.catalog`, the Hindi, Japanese, Korean
and Chinese ones into their languages' drawers
(`LOCALE:Catalogs/hindi/sys/dos.catalog`).

## The code set

The text is UTF-8, `Locale.code_set` and `Catalog.code_set` are
`CODESET_UTF8`, and the files are kept as they are read: `€` and the
German quotes `„“` are what a country or a language file writes. A
catalog's string that is not UTF-8 is read as code page 1252. A width or
a limit in FormatString and the catalogs' least and most count
characters; `%c` takes a code point and writes it in UTF-8.

## Keymaps

A keymap is the tables that make a key into characters:
keymap.library's `MapRawKey` reads them, and the one it reads when a
caller names none is the default, which `C:SetMap <name>` sets for the
whole machine: every window types by it from the next key on, and so
does every console, the shell the command was typed in among them (a
console a program gave a keymap of its own with `CD_SETKEYMAP` keeps
that one). `deutsch` and `usa` are in the ROM. Any other is a file
of `DEVS:Keymaps` with the keymap's name, which `FindKeyMap` loads the
first time a process asks for it and keeps; `KeyMapName` says what a
keymap is called. A name is taken as it is written: `SetMap USA` finds
no keymap.

`DEVS:Keymaps/inscript` types Devanagari by the InScript layout:

| Held | A key types | The digits |
|---|---|---|
| nothing | the vowel signs, the consonants said without breath (`k` is क) | the ASCII digit |
| shift | the vowels, the consonants said with breath (`K` is ख) | InScript's signs; on 3 to 8 a conjunct (`7` is क्ष) |
| alt | what the key types on the US layout (`k`) | the Devanagari digit (१) |
| shift and alt | the US layout with shift (`K`) | the US layout's sign (`!`) |

`d` is the virama, which joins two consonants: `k` `d` `m` is क्म.
Comma, full stop and hyphen are themselves, with shift ष, the danda `।`
and the visarga. The Latin letters are on alt because the keymap is
the whole machine's: a command's name, a path and the line that goes
back - `SetMap usa`, each key with alt - are typed while it is set.
Control with a letter key makes the Latin letter's control character,
and Caps Lock changes nothing. A menu's shortcut is the character its
key types with what else is held, so a Latin letter's shortcut - an
English text's, and the two keys that send a screen to the back and
bring the desktop's to the front - takes alt as well while the keymap
is set, and a Devanagari letter's is typed as it is.

### A keymap's file

The file is a program's load file that holds a ROM tag of the type
`.keymap`, named as the keymap and as the file, whose `init` points at
a `sdk.keymap.KeyMapFile`: the four tables of the character keys
(rawkeys 0x00 to 0x3F) and, if the keymap has its own, the four of the
keys from 0x40 up - space, return, the cursor and function keys. Left
null, those are the tables the ROM's keymaps share.

```zig
const km = sdk.keymap;

const lo_types = [64]u8{ km.KC_VANILLA, ... };
const lo_map = [64]km.KeyMapEntry{ .{ .chars = .{ 0x94A, 0x912, '`', '~' } }, ... };
const lo_capsable = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
const lo_repeatable = [8]u8{ 0xFF, 0xBF, 0xFF, 0xEF, 0xFF, 0xEF, 0xFF, 0xF7 };

pub const file: km.KeyMapFile = .{
    .lo_key_map_types = &lo_types,
    .lo_key_map = &lo_map,
    .lo_capsable = &lo_capsable,
    .lo_repeatable = &lo_repeatable,
};

export const tag: exec.Resident linksection(".resident") = .{
    .match_tag = &tag,
    .type = .keymap,
    .name = "inscript",
    .id_string = "inscript 1.0 (12.11.2026)\r\n",
    .init = &file,
};
```

A key's type byte says which of shift, alt and control choose among
its characters and whether its entry is four characters or points at
strings (`KCF_STRING`: for each choice a length and where the
characters begin, counted in words from the entry's data, then the
characters as code points) or at a dead key's table. The file exports
`_program_entry` as every load file does - run as a command it says
what it is and fails - and keeps its `$VER:` string in `.version`.
The entries are written with `sdk.keymap.tables`, which the ROM's
keymaps are written with too: `chars` for a key of four characters,
`one`, `none`, `strings` and `string1`/`string2` for string keys, and
the dead keys' forms.
`src/disk/devs/keymaps/inscript/inscript.zig` is the worked example;
`src/disk/build.zig` lists it among the modules, which puts it into
`DEVS:Keymaps`.

## Emoji: `LOCALE:Emoji`

What a program needs to offer the emoji to choose from: which there
are, in which groups and order, and what each is called in the
languages the disk has. Two kinds of file, UTF-8 text with a line feed
after each line and a tab between a line's fields.

`LOCALE:Emoji/emoji.list` is every emoji, 1906 in nine groups:

```
emoji-list 1 9 1906
@Smileys & Emotion
😀
...
@People & Body
👋	👋🏻	👋🏼	👋🏽	👋🏾	👋🏿
```

The first line is the file's kind, the form it is in, and how many
groups and emoji follow. A line starting with `@` opens a group. An
emoji that is drawn in the skin tones has the five of them after it,
the lightest first, each written out whole - a program picks the field
and needs no rule for where a tone goes in a sequence. Where an emoji
shows several people, the five are the ones with everyone in the same
tone; the pairs in two different tones are not in the list. The group
names are English.

`LOCALE:Emoji/<language>.names` is what the emoji are called in a
language, the file named as the locale names the language (`deutsch`,
`english`):

```
emoji-names 1 1905 deutsch
😀	grinsendes Gesicht	froh|fröhlich|Gesicht|grinsen|haha|lachen|lol|lustig|Smiley
...
🇩🇪	Flagge: Deutschland	Flagge
```

One line for each emoji of the list that has a name in the language,
in the list's order: the emoji, its name, and the further words it is
found by with `|` between them - a field that is missing where there
are none. An emoji in a skin tone goes by the name of the one without.

`sdk.emoji` (`sdk/libs/emoji/emoji.zig`) reads both from a file held in
memory, handing out slices of it and allocating nothing:

```zig
var list = sdk.emoji.List.open(bytes) orelse return; // not a list
// list.groups and list.emoji: what to make room for.
while (list.next()) |item| switch (item) {
    .group => |name| ...,
    .emoji => |one| ..., // one.text; one.toned(2): in the medium tone
};

var path: [64]u8 = undefined;
const file = sdk.emoji.namesPath(&path, "deutsch"); // LOCALE:Emoji/deutsch.names
var names = sdk.emoji.Names.open(names_bytes) orelse return;
while (names.next()) |name| {
    // name.emoji, name.name; name.words() walks the keywords.
}
```

A program takes the names of the first of the locale's languages
(`pref_languages`) that has a file, and `english` after them.

The files are made at build time by `tools/emojigen`, from Unicode's
`emoji-test.txt` (Emoji 16.0) and the CLDR's annotations (release 46),
which `scripts/fetch-emoji.sh` fetches; the licence of both is
`LOCALE:Emoji/unicode.licence`. They are where `FONTS:emoji` is: in the
64-bit machines' release packages, so on a machine installed or
brought up to date from one, and on the system disks of QEMU's virt
machines; the disk image a machine starts from out of RAM has not the
room. 1.8 MB in all: the list 37 KB, a language's names 76 to 247 KB.

`SYS:Commodities/Emoji` is the window to pick one from: the groups as
tabs, a search through the names and keywords, the ones used last, and
the skin tone. What is picked is typed into the window that was being
worked in ([commodities guide](commodities.md)).

## Commands

| Command | What it does |
|---|---|
| `C:SetMap [<keymap>]` | makes the keymap of that name the machine's - `deutsch`, `usa` or a file of `DEVS:Keymaps` such as `inscript` -, or says which it is |
| `C:SetPrefs` | makes the locale `ENV:Sys/locale.prefs` describes the default, with the rest of the system's settings; `SHOW` prints the country and language |
| `C:test/Locale [DATE <date>] [WORDS <words>...]` | prints the default locale - its country, languages, time zone and catalog, now in each of its formats, a number and its money - in the words of its own catalog; reads DATE by the short date and sorts WORDS in the language's order |

In `SYS:` itself, `Locale` names the `SYS:locale` directory first; call
the command as `C:test/Locale` there.
