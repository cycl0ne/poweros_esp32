# json.library

json.library's functions: JSON text read into a tree of values, looked
through, built and changed, and written out again (sdk.json). Open it
with OpenLibrary("json.library", 1).

Generated from the source by `./zig build autodoc`.

## Index

- [CopyJSONValue](#copyjsonvalue) - Copies a value and everything in it.
- [CountJSONValues](#countjsonvalues) - Counts the values in an array or an object.
- [CreateJSONBool](#createjsonbool) - Makes a new boolean.
- [CreateJSONDocument](#createjsondocument) - Makes an empty document.
- [CreateJSONInteger](#createjsoninteger) - Makes a new whole number.
- [CreateJSONNumber](#createjsonnumber) - Makes a new number.
- [CreateJSONString](#createjsonstring) - Makes a new string.
- [CreateJSONValue](#createjsonvalue) - Makes a new value of a kind.
- [DisposeJSONDocument](#disposejsondocument) - Gives a document back, and every value made in it.
- [FindJSONMember](#findjsonmember) - Finds the member of an object called `name`.
- [FindJSONPointer](#findjsonpointer) - Finds the value a JSON Pointer names.
- [FormatJSON](#formatjson) - Writes a value as JSON text into memory.
- [GetJSONBool](#getjsonbool) - Reads a boolean's value.
- [GetJSONInteger](#getjsoninteger) - Reads a whole number's value.
- [GetJSONItem](#getjsonitem) - Finds the value at `index` in an array or an object.
- [GetJSONNumber](#getjsonnumber) - Reads a number's value.
- [GetJSONString](#getjsonstring) - Reads a string's text.
- [InsertJSONItem](#insertjsonitem) - Puts a value into an array.
- [ParseJSON](#parsejson) - Reads JSON text into a new document.
- [ReadJSONFile](#readjsonfile) - Reads a file of JSON text into a new document.
- [RemoveJSONValue](#removejsonvalue) - Takes a value out of its array or object, or off the root.
- [SetJSONMember](#setjsonmember) - Makes a value the member `name` of an object.
- [SetJSONRoot](#setjsonroot) - Makes a value the document's root.
- [WriteJSONFile](#writejsonfile) - Writes a value into a file as JSON text.

## CopyJSONValue

Copies a value and everything in it.

**SYNOPSIS**

```zig
fn CopyJSONValue(base: *JSONBase, document: *json.Document, value: *const json.Value) ?*json.Value
```

**SINCE**

1.0. LVO -88.

**INPUTS**

- `document`: the document to make the copy in: the value's own or
  another.
- `value`: what to copy.

**RESULT**

The copy, placed nowhere; null without the memory.

**BEHAVIOR**

Every value inside is copied too, in its order, with its name, text,
number and truth; the copy is the value's alone, so a change to one
leaves the other as it is. The value's own name is not copied: the
copy is placed nowhere. The tree is walked without recursion.

**CONTEXT**

- Waits: no.
- Interrupts: not from an interrupt.
- Locks: none taken; the caller keeps other tasks off both documents.
- Process: a Task will do.

**OWNERSHIP**

The copy is `document`'s, given back with it. When the memory runs out
halfway, what was copied stays in `document` until it goes.

**BUGS**

None known.

**SEE ALSO**

`SetJSONMember`, `InsertJSONItem`, `SetJSONRoot`

**EXAMPLES**

```zig
// A place of the answer kept in the settings, which outlive it.
const kept = jb.CopyJSONValue(settings, found) orelse return;
_ = jb.InsertJSONItem(places, kept, json.JSON_END);
```

## CountJSONValues

Counts the values in an array or an object.

**SYNOPSIS**

```zig
fn CountJSONValues(base: *JSONBase, container: ?*const json.Value) u32
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `container`: the array or object; null, or any other value, holds
  none.

**RESULT**

How many items or members it has; 0 for anything else.

**BEHAVIOR**

The count the array or object keeps, as `count` has it.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**BUGS**

None known.

**SEE ALSO**

`GetJSONItem`, `InsertJSONItem`

**EXAMPLES**

```zig
const hours = jb.CountJSONValues(jb.FindJSONPointer(document.root, "/hourly/time"));
```

## CreateJSONBool

Makes a new boolean.

**SYNOPSIS**

```zig
fn CreateJSONBool(base: *JSONBase, document: *json.Document, truth: bool) ?*json.Value
```

**SINCE**

1.0. LVO -84.

**INPUTS**

- `document`: the document to make it in.
- `truth`: its value.

**RESULT**

The boolean, placed nowhere; null without the memory.

**BEHAVIOR**

Written out as `true` or `false`.

**CONTEXT**

- Waits: no.
- Interrupts: not from an interrupt.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

The value is the document's, given back with it.

**BUGS**

None known.

**SEE ALSO**

`GetJSONBool`, `CreateJSONValue`

**EXAMPLES**

```zig
const fahrenheit = jb.CreateJSONBool(document, true) orelse return;
_ = jb.SetJSONMember(document.root.?, "fahrenheit", fahrenheit);
```

## CreateJSONDocument

Makes an empty document.

**SYNOPSIS**

```zig
fn CreateJSONDocument(base: *JSONBase) ?*json.Document
```

**SINCE**

1.0. LVO -64.

**INPUTS**

None.

**RESULT**

The document, with no root; null without the memory.

**BEHAVIOR**

The document is a memory pool of its own and the root that will be;
the `Create...` calls make values in it, `SetJSONRoot`,
`SetJSONMember` and `InsertJSONItem` put them together.

**CONTEXT**

- Waits: no.
- Interrupts: not from an interrupt.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The document is the caller's, given back with `DisposeJSONDocument`,
and every value made in it with it.

**BUGS**

None known.

**SEE ALSO**

`CreateJSONValue`, `SetJSONRoot`, `DisposeJSONDocument`, `ParseJSON`

**EXAMPLES**

```zig
const document = jb.CreateJSONDocument() orelse return;
defer jb.DisposeJSONDocument(document);
const places = jb.CreateJSONValue(document, json.JSON_ARRAY) orelse return;
_ = jb.SetJSONRoot(document, places);
```

## CreateJSONInteger

Makes a new whole number.

**SYNOPSIS**

```zig
fn CreateJSONInteger(base: *JSONBase, document: *json.Document, integer: i64) ?*json.Value
```

**SINCE**

1.0. LVO -76.

**INPUTS**

- `document`: the document to make it in.
- `integer`: its value.

**RESULT**

The number, placed nowhere; null without the memory.

**BEHAVIOR**

The number is kept exactly (`JSONVF_INTEGER`) and written digit for
digit, past 2^53 too; its `number` is the double nearest it.

**CONTEXT**

- Waits: no.
- Interrupts: not from an interrupt.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

The value is the document's, given back with it.

**BUGS**

None known.

**SEE ALSO**

`CreateJSONNumber`, `GetJSONInteger`

**EXAMPLES**

```zig
const shown = jb.CreateJSONInteger(document, 2) orelse return;
_ = jb.SetJSONMember(document.root.?, "shown", shown);
```

## CreateJSONNumber

Makes a new number.

**SYNOPSIS**

```zig
fn CreateJSONNumber(base: *JSONBase, document: *json.Document, number: f64) ?*json.Value
```

**SINCE**

1.0. LVO -72.

**INPUTS**

- `document`: the document to make it in.
- `number`: its value.

**RESULT**

The number, placed nowhere; null without the memory.

**BEHAVIOR**

Written out, the number takes the fewest digits that read back as the
same double: 3.6 as `3.6`, 2.0 as `2`.

**CONTEXT**

- Waits: no.
- Interrupts: not from an interrupt.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

The value is the document's, given back with it.

**NOTES**

JSON has no infinity and no NaN: either is written as `null`.

**BUGS**

None known.

**SEE ALSO**

`CreateJSONInteger`, `GetJSONNumber`, `FormatJSON`

**EXAMPLES**

```zig
const latitude = jb.CreateJSONNumber(document, 48.13743) orelse return;
_ = jb.SetJSONMember(place, "latitude", latitude);
```

## CreateJSONString

Makes a new string.

**SYNOPSIS**

```zig
fn CreateJSONString(base: *JSONBase, document: *json.Document, text: [*]const u8, length: u32) ?*json.Value
```

**SINCE**

1.0. LVO -80.

**INPUTS**

- `document`: the document to make it in.
- `text`: the text, UTF-8.
- `length`: how many bytes of it; `JSON_TERMINATED` for all of it up
  to its NUL.

**RESULT**

The string, placed nowhere; null without the memory.

**BEHAVIOR**

The text is copied, with a NUL after it, and needs no escapes: they
are made as it is written out, where bytes that are not UTF-8 are
written as U+FFFD.

**CONTEXT**

- Waits: no.
- Interrupts: not from an interrupt.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

The text stays the caller's; the value and its copy are the
document's.

**BUGS**

None known.

**SEE ALSO**

`GetJSONString`, `SetJSONMember`

**EXAMPLES**

```zig
const name = jb.CreateJSONString(document, "München", json.JSON_TERMINATED) orelse return;
_ = jb.SetJSONMember(place, "name", name);
```

## CreateJSONValue

Makes a new value of a kind.

**SYNOPSIS**

```zig
fn CreateJSONValue(base: *JSONBase, document: *json.Document, kind: u32) ?*json.Value
```

**SINCE**

1.0. LVO -68.

**INPUTS**

- `document`: the document to make it in.
- `kind`: `JSON_NULL`, `JSON_BOOLEAN`, `JSON_NUMBER`, `JSON_STRING`,
  `JSON_ARRAY` or `JSON_OBJECT`.

**RESULT**

The value - `null`, `false`, 0, an empty string, an empty array or
object - placed nowhere; null without the memory or for a kind that
is none of those.

**BEHAVIOR**

A value placed nowhere is in no array or object and is not the root:
`SetJSONMember`, `InsertJSONItem` or `SetJSONRoot` place it. The
other `Create...` calls make a value with its content.

**CONTEXT**

- Waits: no.
- Interrupts: not from an interrupt.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

The value is the document's, given back with it.

**BUGS**

None known.

**SEE ALSO**

`CreateJSONNumber`, `CreateJSONString`, `CreateJSONBool`, `SetJSONMember`

**EXAMPLES**

```zig
const place = jb.CreateJSONValue(document, json.JSON_OBJECT) orelse return;
_ = jb.InsertJSONItem(places, place, json.JSON_END);
```

## DisposeJSONDocument

Gives a document back, and every value made in it.

**SYNOPSIS**

```zig
fn DisposeJSONDocument(base: *JSONBase, document: ?*json.Document) void
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `document`: what `ParseJSON`, `ReadJSONFile` or
  `CreateJSONDocument` made; null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The document's pool is given back whole: its values - placed or not,
taken out or never put in - their names and their texts.

**CONTEXT**

- Waits: no.
- Interrupts: not from an interrupt.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing of the document may be used afterwards: not a value, not a
text `GetJSONString` gave.

**BUGS**

None known.

**SEE ALSO**

`ParseJSON`, `ReadJSONFile`, `CreateJSONDocument`

**EXAMPLES**

```zig
const document = jb.ParseJSON(text.ptr, text.len, 0, null) orelse return;
defer jb.DisposeJSONDocument(document);
```

## FindJSONMember

Finds the member of an object called `name`.

**SYNOPSIS**

```zig
fn FindJSONMember(base: *JSONBase, object: ?*const json.Value, name: [*:0]const u8) ?*json.Value
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `object`: the object; null, or a value that is not an object,
  finds nothing.
- `name`: the member's name, UTF-8, as the text has it with its
  escapes undone.

**RESULT**

The member; null for none.

**BEHAVIOR**

Names are compared byte for byte, capitals and all. When the object
names a member twice, the last of them is found, as a later member
stands for an earlier one of the same name. The members are gone
through from the last back.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself; nothing is allocated.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

The member is the document's.

**BUGS**

A name with a NUL in it - a `\u0000` - cannot be asked for here; go
through the members' `name` and `name_length` instead.

**SEE ALSO**

`FindJSONPointer`, `GetJSONItem`, `SetJSONMember`

**EXAMPLES**

```zig
const current = jb.FindJSONMember(document.root, "current");
var celsius: f64 = 0;
_ = jb.GetJSONNumber(jb.FindJSONMember(current, "temperature_2m"), &celsius);
```

## FindJSONPointer

Finds the value a JSON Pointer names.

**SYNOPSIS**

```zig
fn FindJSONPointer(base: *JSONBase, from: ?*const json.Value, pointer: [*:0]const u8) ?*json.Value
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `from`: where the pointer starts, a document's root or any value
  in it; null finds nothing.
- `pointer`: the pointer: empty for `from` itself, or a `/` before
  each step - an object's member by its name, `~1` for a `/` in it and
  `~0` for a `~`, or an array's item by its place, from 0.

**RESULT**

The value; null when a step finds nothing, or the pointer is not one.

**BEHAVIOR**

Each step goes one level down. A member is found as `FindJSONMember`
finds one, the last of a name; an item's place is written in digits
with no leading zero. `-`, the place after an array's last item,
names no value and finds nothing.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself; nothing is allocated.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

The value is the document's.

**BUGS**

None known.

**SEE ALSO**

`FindJSONMember`, `GetJSONItem`

**EXAMPLES**

```zig
var high: f64 = 0;
if (jb.GetJSONNumber(jb.FindJSONPointer(document.root, "/daily/temperature_2m_max/1"), &high)) {
    // tomorrow's highest
}
```

## FormatJSON

Writes a value as JSON text into memory.

**SYNOPSIS**

```zig
fn FormatJSON(base: *JSONBase, value: ?*const json.Value, buffer: ?[*]u8, size: usize, flags: u32) usize
```

**SINCE**

1.0. LVO -108.

**INPUTS**

- `value`: the value, with all it holds; null is written `null`.
- `buffer`: where the text goes; null to only measure it.
- `size`: the buffer's size in bytes, its NUL included.
- `flags`: `JSONF_PRETTY` for a value or member a line, indented;
  `JSONF_ASCII` for every character past ASCII as a `\u` escape; 0 for
  compact UTF-8.

**RESULT**

How long the whole text is in bytes, its NUL aside - more than fits
when the buffer was too small. 0, and an empty buffer, when there was
no memory to write a number in.

**BEHAVIOR**

What fits of the text is written, and a NUL after it whenever `size`
is not 0, so a buffer too small holds the text's start; a second call
with a buffer of the answer plus one holds all of it. A value's own
name is not written: the text is the value. Strings are escaped as
JSON wants, and bytes that are not UTF-8 written as U+FFFD. A number
takes the fewest digits that read back as the same double, a whole
number kept exactly its own digits; infinity and NaN are `null`.

**CONTEXT**

- Waits: no.
- Interrupts: not from an interrupt.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

The buffer is the caller's. The room a number is worked out in is
the call's own and freed before it answers.

**BUGS**

None known.

**SEE ALSO**

`WriteJSONFile`, `ParseJSON`

**EXAMPLES**

```zig
const length = jb.FormatJSON(document.root, null, 0, json.JSONF_PRETTY);
const text: [*]u8 = @ptrCast(sys.AllocVec(length + 1, exec.MEMF_ANY) orelse return);
_ = jb.FormatJSON(document.root, text, length + 1, json.JSONF_PRETTY);
```

## GetJSONBool

Reads a boolean's value.

**SYNOPSIS**

```zig
fn GetJSONBool(base: *JSONBase, value: ?*const json.Value, truth: *bool) bool
```

**SINCE**

1.0. LVO -60.

**INPUTS**

- `value`: the value; null is no boolean.
- `truth`: where its value goes.

**RESULT**

True with `true` or `false` in `truth`; false, `truth` as it was, for
anything but a boolean - `null`, 0 and an empty string among them.

**BEHAVIOR**

The boolean's own value; nothing else is made one.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**BUGS**

None known.

**SEE ALSO**

`CreateJSONBool`

**EXAMPLES**

```zig
var fahrenheit = false;
_ = jb.GetJSONBool(jb.FindJSONMember(kept.root, "fahrenheit"), &fahrenheit);
```

## GetJSONInteger

Reads a whole number's value.

**SYNOPSIS**

```zig
fn GetJSONInteger(base: *JSONBase, value: ?*const json.Value, integer: *i64) bool
```

**SINCE**

1.0. LVO -52.

**INPUTS**

- `value`: the value; null is no number.
- `integer`: where its value goes.

**RESULT**

True with the number in `integer`; false, `integer` as it was, for a
number with a fraction, one beyond 64 bits, or anything but a number.

**BEHAVIOR**

A number written, or made, as a whole number that fits 64 bits is
answered exactly, digit for digit (`JSONVF_INTEGER`). Any other
number is answered when its double is whole and fits: `2.0` and `1e3`
are 2 and 1000.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**BUGS**

None known.

**SEE ALSO**

`GetJSONNumber`, `CreateJSONInteger`

**EXAMPLES**

```zig
var code: i64 = 0;
if (jb.GetJSONInteger(jb.FindJSONPointer(document.root, "/current/weather_code"), &code)) {
    // the WMO code of the weather now
}
```

## GetJSONItem

Finds the value at `index` in an array or an object.

**SYNOPSIS**

```zig
fn GetJSONItem(base: *JSONBase, container: ?*const json.Value, index: u32) ?*json.Value
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `container`: the array or object; null, or any other value, finds
  nothing.
- `index`: the place, from 0.

**RESULT**

The value; null past the last.

**BEHAVIOR**

The values are counted from whichever end is nearer. An object's
members are in the order of its text, or as they were placed.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself; nothing is allocated.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

The value is the document's.

**NOTES**

Every value is a step from the next, so going through a long array
item by item is quicker along `first` and `next` than by index.

**BUGS**

None known.

**SEE ALSO**

`CountJSONValues`, `FindJSONMember`, `FindJSONPointer`, `InsertJSONItem`

**EXAMPLES**

```zig
const days = jb.FindJSONPointer(document.root, "/daily/time");
const tomorrow = jb.GetJSONString(jb.GetJSONItem(days, 1), null);
```

## GetJSONNumber

Reads a number's value.

**SYNOPSIS**

```zig
fn GetJSONNumber(base: *JSONBase, value: ?*const json.Value, number: *f64) bool
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `value`: the value; null is no number.
- `number`: where its value goes.

**RESULT**

True with the number in `number`; false, `number` as it was, for
anything but a number - a string of digits among them.

**BEHAVIOR**

The double the text was read to, or the value made. A whole number
beyond 2^53 is the double nearest it; `GetJSONInteger` has it
exactly.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**BUGS**

None known.

**SEE ALSO**

`GetJSONInteger`, `CreateJSONNumber`, `FindJSONPointer`

**EXAMPLES**

```zig
var wind: f64 = 0;
if (!jb.GetJSONNumber(jb.FindJSONPointer(document.root, "/current/wind_speed_10m"), &wind)) wind = 0;
```

## GetJSONString

Reads a string's text.

**SYNOPSIS**

```zig
fn GetJSONString(base: *JSONBase, value: ?*const json.Value, length: ?*u32) ?[*:0]const u8
```

**SINCE**

1.0. LVO -56.

**INPUTS**

- `value`: the value; null is no string.
- `length`: where the text's length in bytes goes; null when it is not
  wanted.

**RESULT**

The text, UTF-8 with a NUL after it; null, `length` as it was, for
anything but a string.

**BEHAVIOR**

The text with its escapes undone. A `\u0000` in it is a NUL byte
inside the text, which `length` counts: the text's end is its length,
the NUL after it only a convenience.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

The text is the document's, there until the document is disposed.

**BUGS**

None known.

**SEE ALSO**

`CreateJSONString`, `FindJSONMember`

**EXAMPLES**

```zig
const zone = jb.GetJSONString(jb.FindJSONMember(document.root, "timezone"), null) orelse "UTC";
```

## InsertJSONItem

Puts a value into an array.

**SYNOPSIS**

```zig
fn InsertJSONItem(base: *JSONBase, array: *json.Value, value: *json.Value, index: u32) bool
```

**SINCE**

1.0. LVO -96.

**INPUTS**

- `array`: the array.
- `value`: the value, made in the array's document.
- `index`: the item it goes before, from 0; `JSON_END`, or any place
  past the last, puts it after the last.

**RESULT**

True; false, and nothing changed, when `array` is no array, the value
is another document's, or the array is inside the value - which would
hold itself.

**BEHAVIOR**

A value placed elsewhere - in an array, an object, or as the root - is
taken out of there first, its name dropped; `index` counts the array
as it is after that, which matters when the value was in it already.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself; nothing is allocated.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

The values stay the document's.

**BUGS**

None known.

**SEE ALSO**

`GetJSONItem`, `RemoveJSONValue`, `SetJSONMember`

**EXAMPLES**

```zig
// The place shown last first in the list.
_ = jb.InsertJSONItem(places, place, 0);
```

## ParseJSON

Reads JSON text into a new document.

**SYNOPSIS**

```zig
fn ParseJSON(base: *JSONBase, text: [*]const u8, length: usize, flags: u32, report: ?*json.Error) ?*json.Document
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `text`: the text, UTF-8; it needs no NUL at its end.
- `length`: how many bytes of it to read.
- `flags`: `JSONF_COMMENTS` to read `//` and `/* */` comments as
  blanks and a comma before a closing `]` or `}` as nothing; 0 for
  JSON as RFC 8259 has it.
- `report`: filled in with why and where reading stopped, or with
  `JSONERR_OK`; null when that is not wanted.

**RESULT**

The document, its `root` the text's value; null when the text is not
JSON or there was no memory, `report` saying which (`JSONERR_*`) and
where: the byte, its line and its column.

**BEHAVIOR**

The text is one value with blanks - space, tab, line feed, carriage
return - around it; a UTF-8 byte order mark before it is passed over.
Arrays and objects may nest as deep as memory lets them. Every string
and name has its escapes undone and is copied into the document,
with a NUL after it; a `\u` escape of half a surrogate pair is read as
U+FFFD. Bytes that are not UTF-8 in a string stop the reading. An
object may name a member twice: both are kept, in order, and
`FindJSONMember` finds the last. A number is read to the double
nearest its text, and one written as a whole number that fits 64 bits
is kept exactly too (`JSONVF_INTEGER`); one too large for a double is
read as infinity.

**CONTEXT**

- Waits: no.
- Interrupts: not from an interrupt.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The text stays the caller's and may go once the call answers: the
document holds copies. The document is the caller's, given back with
`DisposeJSONDocument`.

**NOTES**

A number with more digits than its double holds, or an exponent
beyond 22, takes the slow way: a decimal of up to 800 digits, the
call's own while it reads.

**BUGS**

None known.

**SEE ALSO**

`ReadJSONFile`, `DisposeJSONDocument`, `FindJSONPointer`, `FormatJSON`

**EXAMPLES**

```zig
var report = json.Error{};
const document = jb.ParseJSON(answer.ptr, answer.len, 0, &report) orelse {
    // report.code, report.line, report.column say why and where
    return;
};
defer jb.DisposeJSONDocument(document);
```

## ReadJSONFile

Reads a file of JSON text into a new document.

**SYNOPSIS**

```zig
fn ReadJSONFile(base: *JSONBase, name: [*:0]const u8, flags: u32, report: ?*json.Error) ?*json.Document
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `name`: the file, as dos.library names one.
- `flags`: as `ParseJSON` takes them.
- `report`: filled in with why and where reading stopped, or with
  `JSONERR_OK`; null when that is not wanted.

**RESULT**

The document; null when the file could not be read - `report` then
says `JSONERR_FILE` and its `dos_error` what dos.library said - when
its text is not JSON, or when there was no memory.

**BEHAVIOR**

The file is read to its end into memory that grows as it fills, so a
stream with no size - a pipe, a console - is read as a file is, then
read as `ParseJSON` reads text.

**CONTEXT**

- Waits: yes: for the file's handler.
- Interrupts: no.
- Locks: none taken; none may be held around it, since it waits.
- Process: a Process: dos.library's calls need one.

**OWNERSHIP**

The document is the caller's, given back with `DisposeJSONDocument`.
The file is closed and its text given back before the call answers.

**BUGS**

None known.

**SEE ALSO**

`ParseJSON`, `WriteJSONFile`, `DisposeJSONDocument`

**EXAMPLES**

```zig
const kept = jb.ReadJSONFile("ENV:Weather.json", json.JSONF_COMMENTS, null);
defer jb.DisposeJSONDocument(kept);
```

## RemoveJSONValue

Takes a value out of its array or object, or off the root.

**SYNOPSIS**

```zig
fn RemoveJSONValue(base: *JSONBase, value: *json.Value) void
```

**SINCE**

1.0. LVO -100.

**INPUTS**

- `value`: the value.

**RESULT**

Nothing.

**BEHAVIOR**

The value leaves its array or object - the values beside it closing
up, the count one less - or stops being its document's root, and
loses its name. What it holds goes with it. A value placed nowhere
stays so.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself; nothing is allocated.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

The value stays the document's and can be placed again; its memory
goes with the document.

**BUGS**

None known.

**SEE ALSO**

`InsertJSONItem`, `SetJSONMember`, `SetJSONRoot`

**EXAMPLES**

```zig
if (jb.GetJSONItem(places, picked)) |place| jb.RemoveJSONValue(place);
```

## SetJSONMember

Makes a value the member `name` of an object.

**SYNOPSIS**

```zig
fn SetJSONMember(base: *JSONBase, object: *json.Value, name: [*:0]const u8, value: *json.Value) bool
```

**SINCE**

1.0. LVO -92.

**INPUTS**

- `object`: the object.
- `name`: the member's name, UTF-8; copied.
- `value`: the value, made in the object's document.

**RESULT**

True; false, and nothing changed, when `object` is no object, the
value is another document's, the object is inside the value - which
would hold itself - or there is no memory for the name.

**BEHAVIOR**

A value placed elsewhere - in an array, an object, or as the root - is
taken out of there first. When the object has a member of that name,
the value takes its place in the order and the old one is placed
nowhere, and so is any other member of the name; otherwise the value
goes after the last member.

**CONTEXT**

- Waits: no.
- Interrupts: not from an interrupt.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

The values stay the document's. One that was replaced can be placed
again; it is given back with the document.

**BUGS**

None known.

**SEE ALSO**

`FindJSONMember`, `RemoveJSONValue`, `InsertJSONItem`

**EXAMPLES**

```zig
const latitude = jb.CreateJSONNumber(document, 52.52) orelse return;
if (!jb.SetJSONMember(place, "latitude", latitude)) return;
```

## SetJSONRoot

Makes a value the document's root.

**SYNOPSIS**

```zig
fn SetJSONRoot(base: *JSONBase, document: *json.Document, value: ?*json.Value) bool
```

**SINCE**

1.0. LVO -104.

**INPUTS**

- `document`: the document.
- `value`: a value made in it, or null for no root.

**RESULT**

True; false, and nothing changed, when the value is another
document's.

**BEHAVIOR**

A value placed in an array or object is taken out of it first. The
root before it is placed nowhere, and can be put somewhere again.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself; nothing is allocated.
- Locks: none taken; the caller keeps other tasks off the document.
- Process: a Task will do.

**OWNERSHIP**

The values stay the document's.

**BUGS**

None known.

**SEE ALSO**

`CreateJSONDocument`, `RemoveJSONValue`, `WriteJSONFile`

**EXAMPLES**

```zig
const top = jb.CreateJSONValue(document, json.JSON_OBJECT) orelse return;
_ = jb.SetJSONRoot(document, top);
```

## WriteJSONFile

Writes a value into a file as JSON text.

**SYNOPSIS**

```zig
fn WriteJSONFile(base: *JSONBase, value: ?*const json.Value, name: [*:0]const u8, flags: u32) bool
```

**SINCE**

1.0. LVO -112.

**INPUTS**

- `value`: the value, with all it holds; null is written `null`.
- `name`: the file, as dos.library names one: made, or emptied when
  it is there.
- `flags`: as `FormatJSON` takes them.

**RESULT**

True; false when the file could not be made or written, `IoErr`
saying why, or there was no memory to write a number in
(`ERROR_NO_FREE_STORE`).

**BEHAVIOR**

The text `FormatJSON` would make, and a line end after it, written
through a buffer of the call's own. A file that could not be written
whole is closed as far as it got.

**CONTEXT**

- Waits: yes: for the file's handler.
- Interrupts: no.
- Locks: none taken; none may be held around it, since it waits.
- Process: a Process: dos.library's calls need one.

**OWNERSHIP**

The file is closed before the call answers.

**BUGS**

None known.

**SEE ALSO**

`FormatJSON`, `ReadJSONFile`

**EXAMPLES**

```zig
if (!jb.WriteJSONFile(settings.root, "ENVARC:Weather.json", json.JSONF_PRETTY)) {
    _ = dl.PrintFault(dl.IoErr(), "Weather");
}
```
