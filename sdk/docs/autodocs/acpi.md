# acpi.resource

acpi.resource's functions: the firmware's namespace - a name found by
its path, and the devices gone through. A resource: no Open or Close,
its first function in the first slot. The base comes from
OpenResource("acpi.resource").

Generated from the source by `./zig build autodoc`.

## Index

- [FindAcpiNode](#findacpinode) - The name at `path` from `scope`.
- [NextAcpiDevice](#nextacpidevice) - The device after `old` whose identity or compatible identity is `id`.

## FindAcpiNode

The name at `path` from `scope`.

**SYNOPSIS**

```zig
fn FindAcpiNode(ab: *AcpiBase, scope: ?*acpi.AcpiNode, path: [*:0]const u8) ?*acpi.AcpiNode
```

**SINCE**

1.0. LVO -4.

**INPUTS**

- `scope` - the name the path starts from; null for the root.
- `path` - names of up to four characters, separated by dots: from
  the root where it starts with `\` ("\\_SB.PCI0"), from as many
  scopes above `scope` as it has `^` in front ("^_PRT"), from `scope`
  itself otherwise ("PCI0._HID"). A name shorter than four characters
  is filled out with `_`, as the bytecode writes it: "_SB" is "_SB_".
  Lower-case letters are taken as upper-case.

**RESULT**

The node, or null where the path names nothing - one of its names is
not there, it goes above the root - or is not a path.

**BEHAVIOR**

Every name of the path must be there, each among the children of the
one before. A single name is looked for in `scope` alone, never in the
scopes above it as the bytecode's own references are: the device's
`_HID` is the device's, not its parent's. A name that is another name
for a node (an Alias) answers that node. "\\" alone is the root.

**CONTEXT**

- Waits: for the namespace, while a method changes it.
- Interrupts: no.
- Locks: takes the namespace, shared with other readers.
- Process: a Task will do.

**OWNERSHIP**

The node is the resource's and stays where it is for as long as the
system runs.

**NOTES**

On a machine whose firmware has no tables, or before any are loaded,
the namespace has only the names it starts with: `\_GPE`, `\_PR`,
`\_SB`, `\_SI`, `\_TZ`, `\_REV`, `\_OS`, `\_GL` and `\_OSI`.

**BUGS**

None known.

**SEE ALSO**

`NextAcpiDevice`

**EXAMPLES**

```zig
const pci = ab.FindAcpiNode(null, "\\_SB.PCI0") orelse return;
const routing = ab.FindAcpiNode(pci, "_PRT");
```

## NextAcpiDevice

The device after `old` whose identity or compatible identity is `id`.

**SYNOPSIS**

```zig
fn NextAcpiDevice(ab: *AcpiBase, old: ?*acpi.AcpiNode, id: ?[*:0]const u8) ?*acpi.AcpiNode
```

**SINCE**

1.0. LVO -8.

**INPUTS**

- `old` - the device the last call answered, or any other node; null
  to start at the beginning.
- `id` - the identity wanted, as the firmware writes it: a device's
  hardware identity ("PNP0C0C", "AMDI0030", "ACPI0007") or one it is
  compatible with; null for every device.

**RESULT**

The next device in the namespace's order, or null after the last.

**BEHAVIOR**

The namespace's order is the order the names were defined in, each
name followed by those inside it: `\_SB`, then its first device, the
devices inside that one, then its second device. A device is a name
that holds a Device; processors, thermal zones and power resources
are not.

Its identity is its `_HID`, and the identities it is compatible with
its `_CID`: a string, the integer the source's `EisaId ("PNP0C0C")`
makes, or a package of either. `id` is matched against each exactly,
as text, upper and lower case being different.

**CONTEXT**

- Waits: for the namespace, while a method changes it.
- Interrupts: no.
- Locks: takes the namespace, shared with other readers.
- Process: a Task will do.

**OWNERSHIP**

The node is the resource's and stays where it is for as long as the
system runs. `id` is the caller's, read during the call.

**NOTES**

Whether a device is there at all is its `_STA`'s to say, which this
call does not ask: it goes through what the firmware describes.

**BUGS**

An identity the firmware gives as a method, which answers it only when
run, is not read: the device is not found by it.

**SEE ALSO**

`FindAcpiNode`

**EXAMPLES**

```zig
var button: ?*acpi.AcpiNode = null;
while (ab.NextAcpiDevice(button, "PNP0C0C")) |found| : (button = found) {
    // a power button the firmware describes
}
```
