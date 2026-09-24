# console.device

console.device's functions, after BeginIO and AbortIO. The base is the
device's: io_Device of a request opened on any unit, CONU_LIBRARY
included.

Generated from the source by `./zig build autodoc`.

## Index

- [AddSnipHook](#addsniphook) - Call `hook` whenever a console window's selection is finished, so that a program can carry the text away - to a clipboard, say.
- [CDInputHandler](#cdinputhandler) - Hand input events to the consoles: a key goes to the console of the window that is active, through that unit's keymap, and a window event (`IECLASS_EVENT`, `IECLASS_ACTIVEWINDOW`, `IECLASS_INACTIVEWINDOW`) to the console of the window it names.
- [GetConSnip](#getconsnip) - A copy of what was last selected in a console window, NUL terminated and allocated with AllocVec - the caller frees it - or null when nothing is selected and nothing was put there.
- [RawKeyConvert](#rawkeyconvert) - The characters a list of key events makes, into `buffer` (room for `length`): how many, or -1 when they did not fit.
- [RemSnipHook](#remsniphook) - Take a hook off again.
- [SetConSnip](#setconsnip) - What a paste is to give from now on; it is copied.

## AddSnipHook

Call `hook` whenever a console window's selection is finished, so that a program can carry the text away - to a clipboard, say.

**SYNOPSIS**

```zig
void AddSnipHook(*hooks.Hook hook)
```

**BEHAVIOR**

The hook is called on the console's own task, with the `ConUnit` the
text came from as its object and a `SnipHookMsg` as its message; neither
outlives the call, so a hook that wants the text copies it. The hook may
call nothing that waits. Its node belongs to the device until it is
removed.

## CDInputHandler

Hand input events to the consoles: a key goes to the console of the window that is active, through that unit's keymap, and a window event (`IECLASS_EVENT`, `IECLASS_ACTIVEWINDOW`, `IECLASS_INACTIVEWINDOW`) to the console of the window it names.

**SYNOPSIS**

```zig
?*ie.InputEvent CDInputHandler(?*ie.InputEvent events)
```

**BEHAVIOR**

Answers the events, so whoever is next on input.device's chain still
sees them. The device's own handler is this call.

## GetConSnip

A copy of what was last selected in a console window, NUL terminated and allocated with AllocVec - the caller frees it - or null when nothing is selected and nothing was put there.

**SYNOPSIS**

```zig
?[*:0]u8 GetConSnip()
```

## RawKeyConvert

The characters a list of key events makes, into `buffer` (room for `length`): how many, or -1 when they did not fit.

**SYNOPSIS**

```zig
i32 RawKeyConvert(?*const ie.InputEvent events, [*]u8 buffer, i32 length, ?*const keymap.KeyMap key_map)
```

**BEHAVIOR**

`key_map` null is keymap.library's default.

## RemSnipHook

Take a hook off again.

**SYNOPSIS**

```zig
void RemSnipHook(*hooks.Hook hook)
```

**BEHAVIOR**

It is not called after this returns.

## SetConSnip

What a paste is to give from now on; it is copied.

**SYNOPSIS**

```zig
bool SetConSnip(?[*:0]const u8 snip)
```

**BEHAVIOR**

Null empties it. False when there was no memory.
