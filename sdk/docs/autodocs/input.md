# input.device

input.device's function, after BeginIO and AbortIO. The base is the
device's: io_Device of an open request.

Generated from the source by `./zig build autodoc`.

## Index

- [PeekQualifier](#peekqualifier) - The qualifiers as the device has them now: the shifts, Caps Lock, Control, the Alts and the Amiga keys, and the pointer's buttons.

## PeekQualifier

The qualifiers as the device has them now: the shifts, Caps Lock, Control, the Alts and the Amiga keys, and the pointer's buttons.

**SYNOPSIS**

```zig
u32 PeekQualifier()
```
