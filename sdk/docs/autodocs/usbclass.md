# usbclass

A USB class driver's two functions, after BeginIO and AbortIO: what
usb.library calls a driver in DEVS:usb/ with when it offers it an
interface, and when that interface goes. Every class driver has them
(sdk/devices/usbclass.zig); the base is the driver's, io_Device of an
open request.

Generated from the source by `./zig build autodoc`.

## Index

- [USBClassBind](#usbclassbind) - An interface offered: true if the driver takes it - it has opened its pipes and filled a unit, `binding.unit` saying which - false if it declines and the next driver is asked.
- [USBClassUnbind](#usbclassunbind) - The interface is gone - the device was pulled, or the bus stops: every request the driver has outstanding on it answered, its pipes closed, its unit left without what was in it.

## USBClassBind

An interface offered: true if the driver takes it - it has opened its pipes and filled a unit, `binding.unit` saying which - false if it declines and the next driver is asked.

**SYNOPSIS**

```zig
bool USBClassBind(*usb.USBBinding binding)
```

**BEHAVIOR**

Called on the bus's process, which nothing else on the bus moves while
it runs: decide quickly, and leave anything slow to the driver's own
task. It may make control transfers on the device (DoUSBControl) and
open pipes.

## USBClassUnbind

The interface is gone - the device was pulled, or the bus stops: every request the driver has outstanding on it answered, its pipes closed, its unit left without what was in it.

**SYNOPSIS**

```zig
void USBClassUnbind(*usb.USBBinding binding)
```

**BEHAVIOR**

Called on the bus's process.
