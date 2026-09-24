# gpio.resource

gpio.resource's functions: who holds which of the chip's pads. A driver
takes each pad it routes and gives it back when it is done, so two of
them wanting one pad is a refusal at the take rather than a line two
drivers fight over. A resource: no Open or Close, its first function in
the first slot. The base comes from OpenResource("gpio.resource").

Generated from the source by `./zig build autodoc`.

## Index

- [AllocGPIO](#allocgpio) - Take `pad` for `name`.
- [FreeGPIO](#freegpio) - Give `pad` back.
- [GPIOOwner](#gpioowner) - Who holds `pad`.

## AllocGPIO

Take `pad` for `name`.

**SYNOPSIS**

```zig
fn AllocGPIO(gb: *GpioBase, pad: u32, name: [*:0]const u8) ?[*:0]const u8
```

**SINCE**

1.0. LVO -4.

**INPUTS**

- `pad` - the pad, 0 to GPIO_PADS - 1.
- `name` - who takes it, as GPIOOwner will say: the driver's name.

**RESULT**

Null when the pad is now the caller's. Otherwise who has it - its
holder's name, or NO_SUCH_PAD for a pad the chip does not have - and
nothing has changed.

**BEHAVIOR**

The test and the take are one step under Forbid, so of two drivers
asking at once exactly one gets the pad. Taking a pad sets nothing up:
the caller routes it with `sdk.hardware.gpio` afterwards, as before.

**CONTEXT**

- Waits: no. - Interrupts: no.
- Forbid: taken here, around the test and the take.
- Process: a Task will do.

**OWNERSHIP**

`name` is kept, not copied: it must stay valid until FreeGPIO. A
string literal in the driver does.

**NOTES**

A driver takes every pad a part of the board gives it before it drives
any of them, and gives back the ones it did get when one is refused.

**BUGS**

None known.

**SEE ALSO**

`FreeGPIO`, `GPIOOwner`

**EXAMPLES**

```zig
if (gb.AllocGPIO(pad, "sd.device")) |holder| {
    sdk.exec.kprintf(sys, "sd.device: GPIO%d is %s's\n", .{ pad, holder });
    return false;
}
```

## FreeGPIO

Give `pad` back.

**SYNOPSIS**

```zig
fn FreeGPIO(gb: *GpioBase, pad: u32) void
```

**SINCE**

1.0. LVO -8.

**INPUTS**

- `pad` - a pad the caller took with AllocGPIO.

**RESULT**

None.

**BEHAVIOR**

The pad is free for the next AllocGPIO. How it is set up - its
function, its level, its pulls - is left as it is: a line let go of
mid-level stays there until its next holder sets it.

**CONTEXT**

- Waits: no. - Interrupts: no.
- Forbid: taken here.
- Process: a Task will do.

**OWNERSHIP**

The name given to AllocGPIO is no longer kept.

**NOTES**

Only the holder gives a pad back; nothing checks who calls.

**BUGS**

A pad the chip does not have is ignored.

**SEE ALSO**

`AllocGPIO`

**EXAMPLES**

```zig
gb.FreeGPIO(pad);
```

## GPIOOwner

Who holds `pad`.

**SYNOPSIS**

```zig
fn GPIOOwner(gb: *GpioBase, pad: u32) ?[*:0]const u8
```

**SINCE**

1.0. LVO -12.

**INPUTS**

- `pad` - the pad.

**RESULT**

The name it was taken for, or null when nobody holds it or the chip
does not have it.

**BEHAVIOR**

One read of the list, no lock: what it answers may have changed by the
time the caller looks at it, which is fine for a listing and nothing
else. To have a pad, take it.

**CONTEXT**

- Waits: no. - Interrupts: yes.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The name is its holder's; read it at once, do not keep it.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`AllocGPIO`

**EXAMPLES**

```zig
const holder = gb.GPIOOwner(9) orelse "-";
```
