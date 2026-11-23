# btprofile

A Bluetooth profile driver's two functions, after BeginIO and AbortIO:
what bluetooth.library calls a driver in DEVS:bluetooth/ with when it
offers it a service of a bonded device, and when it takes it back.
Every profile driver has them (sdk/devices/btprofile.zig); the base is
the driver's, io_Device of an open request.

Generated from the source by `./zig build autodoc`.

## Index

- [BTProfileBind](#btprofilebind) - A service offered: true if the driver takes it - it has filled a unit, `binding.unit` saying which, and keeps `binding` until BTProfileUnbind - false if it declines and the next driver is asked.
- [BTProfileUnbind](#btprofileunbind) - The service is taken back - its controller gone, or its bond ended (BTPU_FORGET in `flags`, for the driver to tell the device first, while the link is there): its channels closed, its unit left without it, `binding` no longer the driver's.

## BTProfileBind

A service offered: true if the driver takes it - it has filled a unit, `binding.unit` saying which, and keeps `binding` until BTProfileUnbind - false if it declines and the next driver is asked.

**SYNOPSIS**

```zig
bool BTProfileBind(*bluetooth.BTBinding binding)
```

**BEHAVIOR**

Called on the library's binder process, which serves nothing else
meanwhile: the driver may call the library - read the service's record,
add listeners, open channels - and wait for it.

## BTProfileUnbind

The service is taken back - its controller gone, or its bond ended (BTPU_FORGET in `flags`, for the driver to tell the device first, while the link is there): its channels closed, its unit left without it, `binding` no longer the driver's.

**SYNOPSIS**

```zig
void BTProfileUnbind(*bluetooth.BTBinding binding, u32 flags)
```

**BEHAVIOR**

Called on the binder process.
