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

- **The line at the top** shows the current cell's name (`B7`) and the
  text typed into it. Typing goes there. On a board with a touch panel
  and no keyboard, the keyboard on the screen comes up for it.
- **The cells** fill the rest of the window: the columns' letters across
  the top, the rows' numbers down the left. The current cell has a frame;
  the cells picked with it are tinted, and so are their letters and
  numbers.
- **The status line** at the bottom gives the sum, the average and the
  count of the numbers among the cells picked, while there are several.
  It also says what is wrong with a formula that cannot be kept.
- **The scroll bars** are in the window's border.

While the window is the active one, the screen's title bar says
`Sheet 1.0`. The window's own title says the file's name, with a `*` in
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
cell. A cell holds up to 1024 characters; the sheet has rows 1 to 9999
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
| Home, End | the first cell of the row, the last one with anything in it |
| Return, Tab | move down, move right |
| Escape | picks only the current cell |
| Ctrl-X, -C, -V | cut, copy, paste |
| Ctrl-Z, -Y | undo, redo |
| Ctrl-A | picks every cell |

In the line at the top:

| Key | Does |
|---|---|
| Return | keeps the text, moves down |
| Tab, Shift-Tab | keeps the text, moves right or left |
| cursor up, down | keeps the text, moves up or down |
| Escape | puts back what the cell held |

Pressing a cell makes it current; pressing it again and letting go there
edits it. A drag over cells picks the rectangle it goes over. A press on a
column's letter or a row's number picks the whole column or row, a drag
along them several, and the corner between them every cell. A drag on the
line at the right of a column's letter makes the column wider or
narrower. The mouse wheel scrolls the rows. Pressing anywhere keeps what
was typed into the line at the top.

## Menus

| Menu | Items |
|---|---|
| Project | New (N), Open... (O), Save (S), Save As..., Quit (Q) |
| Edit | Undo (Z), Redo (Y), Cut (X), Copy (C), Paste (V), Clear, Fill Down (D), Fill Right (R), Select All (A) |
| Sheet | Insert Rows, Delete Rows, Insert Columns, Delete Columns, Wider Column, Narrower Column |

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

## Files

A sheet is saved as CSV: a line per row, each cell's text as it was typed
- a formula with its `=` - split by commas. A field that holds a comma, a
quote or a line break is put in quotes, a quote in it written twice.
Values are not saved; they are worked out again when the file is read.

Reading takes whichever of comma, semicolon or tab the first line is
split by. In a file split by semicolons, a number written with a decimal
comma (`1,5`) is read as that number, and saved back the same way. A file
in UTF-8 has its characters turned into the system's Latin-1 ones.

The columns' widths are not saved. New, Open, Quit, the close gadget and
Ctrl-C ask whether to save a sheet that has changed.

## The source

| File | Holds |
|---|---|
| `sheet.zig` | the program: the window, drawing the cells, the keys and the pointer, the menus, files and the clipboard |
| `cells.zig` | the cells, kept in a table by place; working them out; the steps that can be undone; rows and columns put in and taken out; fill, copy and paste |
| `formula.zig` | reading a formula into code; the names of cells; moving a formula's references |
| `eval.zig` | values, operators and functions: working a formula's code out |
| `number.zig` | numbers read from text and written as text |
| `csv.zig` | CSV read and written |
| `tests/sheet.zig` | host tests of all but the window |

A formula is read once, from left to right, into postfix code, and run
over a stack of values, so no formula nests deeper than the program's
stack. Working the sheet out uses a stack of its own as well: a formula
that names one not yet worked out puts it on that stack and is tried
again after it, so a column of a thousand formulas each naming the one
above costs memory, not stack. The grid is a `canvas.gadget` as big as
the screen, drawn into by the program and shown as far as the window has
room.

The host tests run with the system's:

```sh
./zig build test
```
