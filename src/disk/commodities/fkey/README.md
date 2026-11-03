# FKey

FKey puts functions on freely chosen keys: a key held with its
qualifiers cycles the windows, types a piece of text, resizes the active
window or runs a program.

## Starting it

Double-click its icon in SYS:Commodities, or type in a shell:

```
FKey CX_PRIORITY/K/N,CX_POPKEY/K,CX_POPUP/K
```

- `CX_POPKEY` is the hotkey that brings the window up (`ctrl alt k`), in
  the form of commodities.library's descriptions: qualifiers, then a key
  - `lcommand f10`, `shift alt e`.
- `CX_POPUP=NO` starts it without the window: it runs on, and its hotkey
  shows it.
- `CX_PRIORITY` is its place among the commodities (0).

Started from its icon it reads the same three from the icon's tool
types, which the desktop's Information... changes.

## What a key can do

- **Cycle Windows**: the window at the back of the screen in front comes
  forward and takes the keyboard. The desktop's own window stays where it
  is, and a window put away is passed over: nothing of it is on the
  display, and what holds it - the dock's row - brings it back.
- **Cycle Screens**: the screen in front goes behind the others.
- **Enlarge Window**, **Shrink Window**: the active window grown to the
  room its screen leaves it, or back to the least it asked for.
- **Toggle Window**: the active window to its other size, as its zoom
  gadget does.
- **Insert Text**: the key types the text instead - `\n` a Return, `\t` a
  Tab, `<f1>` a key by its description - into whatever window is active.
- **Run Program**: a command line run in a shell of its own.

A key that is defined does not reach the windows: the function is what
it does now.

## Its window

- **Keys**: the keys defined, by their description. Pick one.
- **The key picked**: its **Key** - the description, the qualifiers held
  and the key itself, `ctrl alt f1`, `shift f5`, `help` - its
  **Command**, and the command's **Text**, which Insert Text types and
  Run Program runs. Each is in force as soon as it is changed.
- **New Key** adds one, **Delete Key** takes the one picked away. Up to
  32 keys.
- **Project:** Save (S), Hide (H), Quit (Q)

The close gadget and Hide only hide the window: FKey runs on, and its
hotkey or starting it again bring the window back. Quit, Remove in the
controller (SYS:Commodities/Exchange) or Ctrl-C in its shell end it.

## Where the keys are kept

Save writes them to `ENV:Sys/fkey.keys` and `ENVARC:Sys/fkey.keys`,
which is where they are read from when FKey starts - ENV: first. A line
for each key, in the order they are tried:

```
KEY="ctrl alt f1" COMMAND=CYCLEWINDOWS
KEY="f12" COMMAND=INSERT ARGS="Kind regards,\n"
KEY="ctrl alt n" COMMAND=PROGRAM ARGS="SYS:Programs/Notepad"
```

`COMMAND` is one of `CYCLEWINDOWS`, `CYCLESCREENS`, `ENLARGE`, `SHRINK`,
`TOGGLE`, `INSERT`, `PROGRAM`. `ARGS` is the text INSERT types or the
command PROGRAM runs; the other commands take none.

Running a script is not here: that needs a script language, which the
system has not got. A script file run by a shell is Run Program.
