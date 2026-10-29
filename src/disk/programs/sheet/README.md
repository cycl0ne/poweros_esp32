# Sheet

`SYS:Programs/Sheet` is a spreadsheet: a window of cells in rows and
columns, each holding a number, a text or a formula, worked out again
whenever a cell changes. It reads and writes CSV files, so a sheet goes
to and comes from any other spreadsheet program.

```
Sheet [FILE]
```

`FILE` is opened at the start. A name that is not there yet is where the
sheet will be saved. Sheet also starts from its icon in `SYS:Programs`,
and a file dragged from the desktop and let go on its window is opened.

## The window

- **The ribbon** across the top has Sheet's commands in groups - see
  [The ribbon](#the-ribbon). View → Ribbon hides it and shows it again.
- **The line at the top** shows the current cell's name (`B7`) and the
  text typed into it. Typing goes there. On a board with a touch panel
  and no keyboard, the keyboard on the screen comes up for it.
- **The cells** fill the rest of the window: the columns' letters across
  the top, the rows' numbers down the left. The current cell has a frame;
  the cells picked with it are tinted, and so are their letters and
  numbers.
- **The find line** comes under it with Find: see [Finding](#finding).
- **The status line**, the sunk field at the bottom, gives the sum, the
  average and the count of the numbers among the cells picked, while
  there are several. It also says what is wrong with a formula that
  cannot be kept.
- **The scroll bars** are in the window's border.

While the window is the active one, the screen's title bar says
`Sheet 1.4`. The window's own title says the file's name, with a `*` in
front while the sheet has changed since it was read or saved.

## Cells

What is typed into a cell decides what it is:

| Typed | It is | Shown |
|---|---|---|
| `12`, `-1.5`, `2E3`, `15%` | a number | against the right, in as many digits as fit, `###` when none do |
| `=A1*2` | a formula | what it works out to |
| `'12` | a text, the `'` not shown | against the left |
| anything else | a text | against the left, running on over empty cells to its right |

A truth value (`TRUE`, `FALSE`) and an error sit in the middle of their
cell. A number can be given a format - see [Formats](#formats). A cell holds up to 1024 characters; the sheet has rows 1 to 9999
and columns A to IV.

## Formulas

A formula starts with `=`. It may hold:

| | |
|---|---|
| numbers | `12`, `1.5`, `2E3`, `15%` |
| text | `"in quotes"`, a quote inside it written twice: `"say ""hi"""` |
| truth values | `TRUE`, `FALSE` |
| references | `B7`, `$B$7`, `$B7`, `B$7` - a `$` keeps that part when the formula is copied |
| ranges | `A1:C4`, in a function's arguments |
| functions | below, with their arguments in parentheses, split by commas |

The operators, from the one that binds most to the one that binds least,
each worked from left to right:

| Operator | Does |
|---|---|
| `-` (in front) | negates: `-2^2` is 4 |
| `%` (after) | a hundredth: `15%` is 0.15 |
| `^` | power: `2^3^2` is 64 |
| `*` `/` | multiply, divide |
| `+` `-` | add, subtract |
| `&` | joins two texts: `A1&" kg"` |
| `=` `<>` `<` `>` `<=` `>=` | compare, giving TRUE or FALSE; texts without regard to case |

Arithmetic takes an empty cell as 0, TRUE as 1 and FALSE as 0, and a text
that reads as a number as that number; any other text is `#VALUE!`. An
error in an operand is the answer, whatever the operator.

### Functions

| Function | Answers |
|---|---|
| `SUM(...)` | the sum |
| `AVERAGE(...)` | the average |
| `MIN(...)`, `MAX(...)` | the least, the greatest (0 for none) |
| `COUNT(...)` | how many numbers |
| `COUNTA(...)` | how many cells hold anything |
| `PRODUCT(...)` | the product |
| `AND(...)`, `OR(...)` | whether all, whether any, are true |
| `ABS(x)` | the value without its sign |
| `SQRT(x)` | the square root |
| `ROUND(x, places)` | rounded to `places` decimals (0 if left out), halves away from zero; a negative count rounds to tens, hundreds, ... |
| `INT(x)` | the whole number at or below |
| `MOD(x, y)` | the remainder, with the sign of `y` |
| `POWER(x, y)` | `x` to the power `y` |
| `EXP(x)`, `LN(x)`, `LOG10(x)` | e to the `x`, the natural and the common logarithm |
| `SIN(x)`, `COS(x)`, `TAN(x)` | in radians |
| `PI()` | π |
| `IF(test, then, else)` | `then` when `test` is true, else `else` (FALSE if left out) |
| `NOT(x)` | the opposite truth |
| `LEN(text)` | how many characters |
| `UPPER(text)`, `LOWER(text)` | in capitals, in small letters |

The functions marked `...` take any number of arguments, each a value or
a range. Of a range, and of a single reference, they take the numbers and
pass over texts, truth values and empty cells; a value written into the
formula itself counts as it is, a text that reads as a number as that
number. Function names may be written in any case.

### Errors

| Shown | Because |
|---|---|
| `#DIV/0!` | a division by zero, or the average of no numbers |
| `#VALUE!` | a text where a number was wanted, or a range where one value was |
| `#REF!` | a reference to a cell that was deleted, or that a copy pushed off the sheet |
| `#NAME?` | a name that is no function |
| `#NUM!` | a number with no answer: the root of a negative, the logarithm of 0 |
| `#CIRC!` | a formula that comes round to itself, through others or directly |
| `#SYNTAX!` | a formula read from a file that cannot be read |

A formula typed with a mistake in it is not kept: the status line says
what is wrong and at which character, and the line at the top keeps the
text to be put right.

## Keys and the pointer

On the cells:

| Key | Does |
|---|---|
| a character | begins the current cell's text again with it |
| F2 | edits the current cell's text, the cursor at its end |
| Backspace | begins the current cell's text again, from nothing |
| Del | empties the cells picked |
| cursor keys | move the current cell |
| Page Up, Page Down | move a window's height of rows |
| Shift with a cursor key, Page Up or Page Down | picks the cells from the current one to where the key goes, the current cell staying |
| Home, End | the first cell of the row, the last one with anything in it |
| Return, Tab | move down, move right |
| Escape | picks only the current cell |
| Ctrl-X, -C, -V | cut, copy, paste |
| Ctrl-Z, -Y | undo, redo |
| Ctrl-A | picks every cell |
| Ctrl-F | shows the find line |

In the line at the top:

| Key | Does |
|---|---|
| Return | keeps the text, moves down |
| Tab, Shift-Tab | keeps the text, moves right or left |
| cursor up, down | keeps the text, moves up or down |
| Escape | puts back what the cell held |

Pressing a cell makes it current; pressing it again and letting go there
edits it. A drag over cells picks the rectangle it goes over, and a press
with Shift the cells from the current one to the one pressed. A press on a
column's letter or a row's number picks the whole column or row, a drag
along them several, and the corner between them every cell. A drag on the
line at the right of a column's letter makes the column wider or
narrower. The mouse wheel scrolls the rows. Pressing anywhere keeps what
was typed into the line at the top.

## Menus

| Menu | Items |
|---|---|
| Project | New (N), Open... (O), Save (S), Save As..., Quit (Q) |
| Edit | Undo (Z), Redo (Y), Cut (X), Copy (C), Paste (V), Clear, Fill Down (D), Fill Right (R), Select All (A), Find... (F), Find Next (G) |
| Sheet | Insert Rows, Delete Rows, Insert Columns, Delete Columns, Wider Column, Narrower Column, AutoSum, Sort Ascending, Sort Descending |
| Format | General, Number, Percent, Currency, More Decimals, Fewer Decimals |
| View | Ribbon |

The letters are the items' right-Amiga keys.

- **Copy** keeps the cells picked for Sheet and puts their shown values on
  the clipboard as text, a line per row split by tabs, for any program to
  paste. **Paste** in Sheet puts the cells back at the current cell, a
  formula's references moved as far as it moved and a part with a `$`
  staying; text from another program is put in a line per row, split at
  its tabs. **Cut** copies, then empties the cells picked.
- **Fill Down** and **Fill Right** copy the first row or column of the
  cells picked over the rest of them the same way.
- **Insert Rows** puts in as many empty rows above the cells picked as
  they have rows; **Delete Rows** takes those rows out. The columns'
  items do the same to the left. Every formula's references follow their
  cells: a range grows with what is put into it and shrinks with what is
  taken out, and a reference to a deleted cell becomes `#REF!`. Nothing is
  pushed off the end of the sheet: an insert that would is refused.
- **Undo** takes back the last change, up to a hundred of them; **Redo**
  does it again.
- **AutoSum** puts `=SUM(...)` of the numbers right above the current
  cell into it - or of those right left of it when there are none above.
  With several cells picked, a sum goes under each column of them that
  has numbers: into the last row picked when that row is empty, else
  into the row under it; for a single row, to its right the same way.
  The ribbon's AutoSum drops down Average, Count, Min and Max as well.
- **Sort Ascending** and **Sort Descending** put the rows picked in
  order by the current cell's column: numbers from the smallest, then
  texts from A to Z with no regard to case, then FALSE and TRUE, then
  errors - or all of it the other way round. Empty cells go last either
  way, and rows that sort the same keep their order. With only one cell
  picked, the rows of the cells round it are sorted, out to the empty
  rows and columns all round; when the first of them holds only texts and
  the second a number, the first is a heading and stays on top. A
  formula moves with its row as a copy of it would.

## The ribbon

The ribbon has one tab, Home, with the menus' commands in groups:

| Group | Buttons |
|---|---|
| Clipboard | Paste, Cut, Copy - Paste grey while there is nothing to paste: no text on the clipboard, no cells copied |
| Undo | Undo, Redo - grey while there is nothing to undo or redo |
| Number | Number, Percent, Currency - lit for the current cell's format; pressed again, back to General - and a decimal more or fewer |
| Cells | Insert, Delete - each drops down Rows and Columns |
| Editing | AutoSum - its arrow drops down Sum, Average, Count, Min, Max - Sort (Ascending, Descending), Find, Fill (Down, Right), Clear |

A button and the menu item of the same name are one command. No label
has a key: a key typed goes to the cells. A narrow window makes the
groups smaller, down to a button that drops the group down. A
double-click on the tab, or the mark at the row's right end, leaves the
row of tabs alone, a tab then dropping its page down over the cells; in
a window less than 400 pixels high inside - a small board's - the ribbon
is that way by itself.

**View → Ribbon** hides the ribbon and shows it again. Sheet keeps that
in `ENV:Sheet.prefs` and `ENVARC:Sheet.prefs` - a line `RIBBON=NO` or
`RIBBON=YES` - so it starts the same way next time. Without
toolbutton.gadget, command.image or ribbon.gadget there is no ribbon,
and the item is grey.

## Formats

A cell's number is shown in its format:

| Format | Shows 1234.5 as | Decimals to begin with |
|---|---|---|
| General | as many digits as the column has room for | - |
| Number | `1,234.50` - grouped in thousands | 2 |
| Percent | `123450%` - a hundred times it | 0 |
| Currency | `$1,234.50` | 2 |

More Decimals and Fewer Decimals change the count, from 0 to 10; on a
General cell they start from the decimals it shows and make it a Number.
A number with more digits than the format can write is shown as General
would, and one that does not fit its column as `###`.

A format is the cell's: it stays while the cell's text changes and goes
when the cell is emptied. Copy and Paste, Fill and Sort take it along,
and Undo puts it back. Copy puts the values on the clipboard as they are
shown. An empty cell has no format to take. **CSV keeps no formats**: a
sheet saved and read again shows its numbers in General.

## Finding

Find (Ctrl-F) shows a line under the line at the top. What is typed
there is looked for in every cell - in what was typed into it and in
what it shows - with no regard to case, from the cell after the current
one on along the rows, round the end to the first. Return or **Next**
makes the next cell that holds it current, and the line keeps the
keyboard for the one after; **Previous** goes the other way. A beep and
the status line say when no cell holds it. Escape or **Close** hides the
line. Find Next (G) goes on with what was last looked for.

## Files

A sheet is saved as CSV: a line per row, each cell's text as it was typed
- a formula with its `=` - split by commas. A field that holds a comma, a
quote or a line break is put in quotes, a quote in it written twice.
Values are not saved; they are worked out again when the file is read.

Reading takes whichever of comma, semicolon or tab the first line is
split by. In a file split by semicolons, a number written with a decimal
comma (`1,5`) is read as that number, and saved back the same way. A file
in UTF-8 has its characters turned into the system's Latin-1 ones.

The columns' widths and the cells' formats are not saved. New, Open, Quit, the close gadget and
Ctrl-C ask whether to save a sheet that has changed.

## The source

| File | Holds |
|---|---|
| `sheet.zig` | the program: the window, drawing the cells, the keys and the pointer, the menus and the ribbon, finding, files and the clipboard |
| `cells.zig` | the cells, kept in a table by place; working them out; the steps that can be undone; rows and columns put in and taken out; fill, copy and paste; formats, sorting, finding and AutoSum's ranges |
| `formula.zig` | reading a formula into code; the names of cells; moving a formula's references |
| `eval.zig` | values, operators and functions: working a formula's code out |
| `number.zig` | numbers read from text and written as text, in a format too |
| `csv.zig` | CSV read and written |
| `tests/sheet.zig` | host tests of all but the window |

A formula is read once, from left to right, into postfix code, and run
over a stack of values, so no formula nests deeper than the program's
stack. Working the sheet out uses a stack of its own as well: a formula
that names one not yet worked out puts it on that stack and is tried
again after it, so a column of a thousand formulas each naming the one
above costs memory, not stack. The grid is a `canvas.gadget` whose
picture is made as big as its box whenever the window is sized, and the
scroll bars are the window object's. The ribbon is made from a table
(`rb.build`), and it and the find line are children of the window's
layout that are hidden and shown again (`CHILDA_Hidden`), so they come
and go where they belong.

The host tests run with the system's:

```sh
./zig build test
```
