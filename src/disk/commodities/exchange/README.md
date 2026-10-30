# Exchange

Exchange lists the commodities running - the programs that see the
input before the windows do - and controls each of them: makes it
active or inactive, opens or closes its window, ends it.

## Starting it

Double-click its icon in SYS:Commodities, or type in a shell:

```
Exchange CX_PRIORITY/K/N,CX_POPKEY/K,CX_POPUP/K
```

- `CX_POPKEY` is the hotkey that brings the window up (`ctrl alt home`),
  in the form of commodities.library's descriptions: qualifiers, then a
  key - `lcommand f10`, `shift alt e`.
- `CX_POPUP=NO` starts it without the window: it runs on, and its hotkey
  shows it.
- `CX_PRIORITY` is its place among the commodities (0).

Started from its icon it reads the same three from the icon's tool
types, which the desktop's Information... changes.

Only one Exchange runs. Starting another brings the first one's window
up, and the second ends at once.

## What the window shows

- **Commodities**: every commodity running, by name, in alphabetical
  order. The list follows them: one started joins it, one ended leaves
  it, one made active or inactive by anyone shows it at once. Pick one.
- **Information**: the title and description of the one picked.
- **Show Interface** and **Hide Interface** open and close its window.
  They are off for a commodity without one.
- The chooser beside **Remove** says whether it is **Active** or
  **Inactive**; choosing the other makes it so. An inactive commodity
  stays in the list and sees no input until it is made active again.
- **Remove** ends it.

Each of these is a command to the commodity, which carries it out itself;
one that does not take commands shows them but does nothing.

## Hiding it and ending it

- **Project:** Hide (H), Quit (Q)

The close gadget and Hide only hide the window: Exchange runs on, and
its hotkey, Ctrl-F in the shell it was started from, or starting it
again bring the window back where it was, at the size it had. Quit,
Remove with Exchange itself picked, or Ctrl-C in its shell end it.
