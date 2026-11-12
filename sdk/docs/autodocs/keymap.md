# keymap.library

keymap.library's functions: rawkeys into characters and back. Open it
with OpenLibrary("keymap.library", 0).

Generated from the source by `./zig build autodoc`.

## Index

- [AskKeyMapDefault](#askkeymapdefault) - The default keymap.
- [FindKeyMap](#findkeymap) - A keymap by name: one on the library's list, or one in a file.
- [KeyMapName](#keymapname) - What a keymap of the library's is called.
- [MapANSI](#mapansi) - The keys that make a string.
- [MapRawKey](#maprawkey) - The characters a key event makes.
- [SetKeyMapDefault](#setkeymapdefault) - Makes a keymap the default.

## AskKeyMapDefault

The default keymap.

**SYNOPSIS**

```zig
fn AskKeyMapDefault(kb: *KeymapBase) *keymap.KeyMap
```

**SINCE**

0.1. LVO -24.

**INPUTS**

None.

**RESULT**

The keymap every call given null uses.

**BEHAVIOR**

"deutsch" until SetKeyMapDefault changes it.

**CONTEXT**

- Waits: no. - Interrupts: no. - Locks: none needed. - Process: a Task
  will do.

**OWNERSHIP**

The library's, or whoever set it.

**BUGS**

None known.

**SEE ALSO**

`SetKeyMapDefault`

**EXAMPLES**

```zig
const now = kb.AskKeyMapDefault();
```

## FindKeyMap

A keymap by name: one on the library's list, or one in a file.

**SYNOPSIS**

```zig
fn FindKeyMap(kb: *KeymapBase, name: [*:0]const u8) ?*keymap.KeyMap
```

**SINCE**

0.1. LVO -36.

**INPUTS**

- `name` - "deutsch", "usa", or a file's in `DEVS:Keymaps`
  ("inscript"), at most KEYMAP_NAME_MAX bytes.

**RESULT**

The keymap, or null when there is none of that name.

**BEHAVIOR**

The names are compared exactly. A name the list has not is looked for
as the file `DEVS:Keymaps/<name>` (0.3): a load file
with a ROM tag of the type `NodeType.keymap` and that name, whose
rt_Init is a `KeyMapFile`. The file is loaded once and its keymap is
on the list from then on; the tables of the keys from 0x40 up that the
file leaves null are the ROM's keymaps' own. A file with no such tag
is unloaded again.

**CONTEXT**

- Waits: for the file system, when the name is not on the list.
- Interrupts: no. - Locks: the list's, taken and released here; it is
  not held while the file is read.
- Process: a file is read for a process only. A Task finds what is on
  the list.

**OWNERSHIP**

The library's; it stays.

**NOTES**

What SetKeyMapDefault is given. dos.library's error of a file not
found is left in the caller's IoErr.

**BUGS**

None known.

**SEE ALSO**

`SetKeyMapDefault`, `KeyMapName`

**EXAMPLES**

```zig
const german = kb.FindKeyMap("deutsch");
```

## KeyMapName

What a keymap of the library's is called.

**SYNOPSIS**

```zig
fn KeyMapName(kb: *KeymapBase, key_map: ?*const keymap.KeyMap) ?[*:0]const u8
```

**SINCE**

0.3. LVO -40.

**INPUTS**

- `key_map` - a keymap; null: the default.

**RESULT**

The name FindKeyMap finds it by, or null when the keymap is not on
the library's list - one a program made and set as the default.

**BEHAVIOR**

The list is walked for the node that holds `key_map`.

**CONTEXT**

- Waits: no. - Interrupts: no. - Locks: the list's, taken and released
  here. - Process: a Task will do.

**OWNERSHIP**

The library's; it stays, as the keymap does.

**NOTES**

How a program says which keymap is in use: `C:SetMap` without a name.

**BUGS**

None known.

**SEE ALSO**

`FindKeyMap`, `AskKeyMapDefault`

**EXAMPLES**

```zig
const name = kb.KeyMapName(null) orelse "(a program's own)";
```

## MapANSI

The keys that make a string.

**SYNOPSIS**

```zig
fn MapANSI(kb: *KeymapBase, string: [*]const u8, count: i32, buffer: [*]keymap.KeyPair, length: i32, key_map: ?*const keymap.KeyMap) i32
```

**SINCE**

0.1, UTF-8 since 0.2. LVO -32.

**INPUTS**

- `string`, `count` - the characters, in UTF-8, and how many bytes.
- `buffer` - where the rawkey/qualifier pairs go.
- `length` - how many pairs it has room for.
- `key_map` - the keymap, or null for the default.

**RESULT**

How many pairs, 0 when a character cannot be made with the keymap, -1
when they did not fit.

**BEHAVIOR**

Each character by one key if one makes it - with the fewest qualifiers -
and otherwise by a dead key and the key it changes, two pairs. A
qualifier is given as the left one of its pair (IEQUALIFIER_LSHIFT,
IEQUALIFIER_LALT) or IEQUALIFIER_CONTROL.

**CONTEXT**

- Waits: no. - Interrupts: no. - Locks: none needed. - Process: a Task
  will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

A search through the keymap per character: fine for a word, not for a
file.

**BUGS**

None known.

**SEE ALSO**

`MapRawKey`

**EXAMPLES**

```zig
var keys: [8]KeyPair = undefined;
const n = kb.MapANSI("Hi €", 6, &keys, keys.len, null);
```

## MapRawKey

The characters a key event makes.

**SYNOPSIS**

```zig
fn MapRawKey(kb: *KeymapBase, event: *const ie.InputEvent, buffer: [*]u8, length: i32, key_map: ?*const keymap.KeyMap) i32
```

**SINCE**

0.1, UTF-8 since 0.2. LVO -28.

**INPUTS**

- `event` - an IECLASS_RAWKEY event: its code, its qualifiers, and in `x`
  and `y` the keys down before it, as input.device records them.
- `buffer` - where the characters go, in UTF-8.
- `length` - how many bytes it has room for.
- `key_map` - the keymap, or null for the default.

**RESULT**

How many bytes, 0 for none, or -1 when they did not fit.

**BEHAVIOR**

None for an event of another class, a key going up (unless its keymap
entry says it sends something then), a key that sends nothing, a dead
key, and a repeat of a key that does not repeat. A key changed by dead
keys looks at the keys before it for them. A string key gives its whole
string, the cursor keys `ESC [` sequences. Control with a key from
0x40 to 0x7F gives its control character, with alt held as well too.

**CONTEXT**

- Waits: no. - Interrupts: no, but only because nothing has been checked
  for it. - Locks: none needed. - Process: a Task will do - it is called
  from input handlers.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

One character can be up to four bytes: `sdk.keymap.character` says
which one a key made, when it made exactly one.

**BUGS**

None known.

**SEE ALSO**

`MapANSI`, `sdk.keymap`

**EXAMPLES**

```zig
var text: [8]u8 = undefined;
const n = kb.MapRawKey(event, &text, text.len, null);
if (sdk.keymap.character(&text, n)) |char| typed(char);
```

## SetKeyMapDefault

Makes a keymap the default.

**SYNOPSIS**

```zig
fn SetKeyMapDefault(kb: *KeymapBase, key_map: *keymap.KeyMap) void
```

**SINCE**

0.1. LVO -20.

**INPUTS**

- `key_map` - the keymap every call given null uses from now on.

**RESULT**

Nothing.

**BEHAVIOR**

It is a pointer store: the keymap is not copied or checked.

**CONTEXT**

- Waits: no. - Interrupts: no. - Locks: none needed; a word is written
  whole. - Process: a Task will do.

**OWNERSHIP**

The keymap must stay for as long as it is the default - one of the
library's own (FindKeyMap), or one that is never freed.

**BUGS**

None known.

**SEE ALSO**

`AskKeyMapDefault`, `FindKeyMap`

**EXAMPLES**

```zig
if (kb.FindKeyMap("usa")) |m| kb.SetKeyMapDefault(m);
```
