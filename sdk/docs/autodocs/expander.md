# expander.resource

expander.resource's functions: the board's IO expander - the pins the
panel, the touch controller and the SD card are held by, the backlight
and an analogue input. A resource: no Open or Close, its first function
in the first slot. The base comes from OpenResource("expander.resource").

Generated from the source by `./zig build autodoc`.

## Index

- [Backlight](#backlight) - What SetBacklight was last given.
- [ClaimPin](#claimpin) - Take `pin` (0 to PIN_COUNT-1) for `name`, which is kept for the listing and must outlive the claim.
- [GetPin](#getpin) - What `pin` reads: 0 or 1, or -1 if the pin is out of range or the part does not answer.
- [PinOwner](#pinowner) - Who holds `pin`, or null if nobody does.
- [ReadADC](#readadc) - The analogue input, 0 to 65535, or -1 if the part does not answer.
- [ReleasePin](#releasepin) - Give `pin` back.
- [SetBacklight](#setbacklight) - The backlight, BACKLIGHT_OFF (0) to BACKLIGHT_FULL (100).
- [SetPin](#setpin) - Drive `pin` high or low.

## Backlight

What SetBacklight was last given.

**SYNOPSIS**

```zig
u32 Backlight()
```

## ClaimPin

Take `pin` (0 to PIN_COUNT-1) for `name`, which is kept for the listing and must outlive the claim.

**SYNOPSIS**

```zig
bool ClaimPin(u32 pin, [*:0]const u8 name)
```

**BEHAVIOR**

False if the pin is out of range or someone else already holds it. A
driver claims the pins it is going to drive so that two of them fighting
over one is an error at claim time rather than a light that goes out
when an unrelated card is initialised.

## GetPin

What `pin` reads: 0 or 1, or -1 if the pin is out of range or the part does not answer.

**SYNOPSIS**

```zig
i32 GetPin(u32 pin)
```

## PinOwner

Who holds `pin`, or null if nobody does.

**SYNOPSIS**

```zig
?[*:0]const u8 PinOwner(u32 pin)
```

## ReadADC

The analogue input, 0 to 65535, or -1 if the part does not answer.

**SYNOPSIS**

```zig
i32 ReadADC()
```

## ReleasePin

Give `pin` back.

**SYNOPSIS**

```zig
void ReleasePin(u32 pin)
```

**BEHAVIOR**

Its level is left as it is.

## SetBacklight

The backlight, BACKLIGHT_OFF (0) to BACKLIGHT_FULL (100).

**SYNOPSIS**

```zig
bool SetBacklight(u32 percent)
```

**BEHAVIOR**

The register behind it counts the other way, which this hides. False if
the part does not answer.

## SetPin

Drive `pin` high or low.

**SYNOPSIS**

```zig
bool SetPin(u32 pin, bool high)
```

**BEHAVIOR**

The pin becomes an output if it was not one, its value being written
before the direction changes so that it never drives the wrong level
first. False if the pin is out of range or the part does not answer.
