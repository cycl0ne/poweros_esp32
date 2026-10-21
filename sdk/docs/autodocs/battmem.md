# battmem.resource

battmem.resource's functions: a few hundred bits of settings kept where
no file has to be read to get them - memory that a reset leaves alone,
where the chip has some, and plain memory where it has none. A
resource: no Open or Close, its first function in the first slot. The
base comes from OpenResource("battmem.resource").

Generated from the source by `./zig build autodoc`.

## Index

- [ObtainBattSemaphore](#obtainbattsemaphore) - The bits to the calling task alone, for a read and the write that depends on it.
- [ReadBattMem](#readbattmem) - `length` bits from bit `offset` on, into `buffer`.
- [ReleaseBattSemaphore](#releasebattsemaphore) - The bits given back, after ObtainBattSemaphore.
- [WriteBattMem](#writebattmem) - `length` bits from `buffer`, to bit `offset` on.

## ObtainBattSemaphore

The bits to the calling task alone, for a read and the write that depends on it.

**SYNOPSIS**

```zig
fn ObtainBattSemaphore(mb: *BattMemBase) void
```

**SINCE**

1.0. LVO -4.

**INPUTS**

None.

**RESULT**

None.

**BEHAVIOR**

Obtains the resource's semaphore, waiting while another task holds
it. The same task may obtain it again, and releases it as often.

**CONTEXT**

- Waits: yes, while another task holds the bits.
- Interrupts: no.
- Locks: takes the resource's semaphore.
- Process: a Task will do.

**OWNERSHIP**

The semaphore is the caller's until ReleaseBattSemaphore.

**NOTES**

ReadBattMem and WriteBattMem each hold it for their own call, so one
read or one write needs no more; this is for several that belong
together, so no other task's write comes between them.

**BUGS**

None known.

**SEE ALSO**

`ReleaseBattSemaphore`, `ReadBattMem`, `WriteBattMem`

**EXAMPLES**

```zig
mb.ObtainBattSemaphore();
defer mb.ReleaseBattSemaphore();
var bits: u64 = 0;
_ = mb.ReadBattMem(@ptrCast(&bits), offset, 64);
bits |= 1;
_ = mb.WriteBattMem(@ptrCast(&bits), offset, 64);
```

## ReadBattMem

`length` bits from bit `offset` on, into `buffer`.

**SYNOPSIS**

```zig
fn ReadBattMem(mb: *BattMemBase, buffer: [*]u8, offset: u32, length: u32) u32
```

**SINCE**

1.0. LVO -12.

**INPUTS**

- `buffer` - where the bits go: (length + 7) / 8 bytes.
- `offset` - the first bit, from 0 (sdk.resources.battmembits names
  which bits hold what).
- `length` - how many bits.

**RESULT**

0; BATTMEMERR_RANGE when the bits run past BATTMEM_BITS, and then
`buffer` is not touched.

**BEHAVIOR**

Bit `offset` goes to bit 0 of the buffer's first byte, the next to
bit 1, and so on into the next byte: a setting of 64 bits read into
a u64 is its number on every chip PowerOS runs on. The bits of the
last byte past `length` stay as they were. Bits nobody wrote are 0.

**CONTEXT**

- Waits: yes, while another task holds the bits.
- Interrupts: no.
- Locks: the resource's semaphore, for the call.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

It sends no packet and reads no file, so a file system handler may
ask it for a setting it cannot read from a file on its own volume.

**BUGS**

None known.

**SEE ALSO**

`WriteBattMem`, `ObtainBattSemaphore`, sdk.resources.battmembits

**EXAMPLES**

```zig
var bits: u64 = 0;
if (mb.ReadBattMem(@ptrCast(&bits), battmembits.BATTMEM_ZONE_ADDR, battmembits.BATTMEM_ZONE_LEN) == 0) {
    const zone = dos.timezone.unpack(bits) orelse .{};
}
```

## ReleaseBattSemaphore

The bits given back, after ObtainBattSemaphore.

**SYNOPSIS**

```zig
fn ReleaseBattSemaphore(mb: *BattMemBase) void
```

**SINCE**

1.0. LVO -8.

**INPUTS**

None.

**RESULT**

None.

**BEHAVIOR**

Releases the resource's semaphore once; when the task held it no more
often than that, the next task waiting for it gets it.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: gives the resource's semaphore back.
- Process: a Task will do; the task that obtained it.

**OWNERSHIP**

The semaphore goes back to the resource.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ObtainBattSemaphore`

**EXAMPLES**

```zig
mb.ObtainBattSemaphore();
defer mb.ReleaseBattSemaphore();
```

## WriteBattMem

`length` bits from `buffer`, to bit `offset` on.

**SYNOPSIS**

```zig
fn WriteBattMem(mb: *BattMemBase, buffer: [*]const u8, offset: u32, length: u32) u32
```

**SINCE**

1.0. LVO -16.

**INPUTS**

- `buffer` - the bits: (length + 7) / 8 bytes, from its first byte's
  bit 0 up, as ReadBattMem gives them.
- `offset` - the first bit they go to, from 0.
- `length` - how many bits.

**RESULT**

0; BATTMEMERR_RANGE when the bits run past BATTMEM_BITS, and then
nothing is written.

**BEHAVIOR**

The bits around them stay as they are. The memory is written whole,
with a check sum: when a reset comes in the middle of it, the next
start finds a sum that does not add up and makes every bit 0.

**CONTEXT**

- Waits: yes, while another task holds the bits.
- Interrupts: no.
- Locks: the resource's semaphore, for the call.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands: the bits are copied.

**NOTES**

The bits outlive a reset on the ESP32-S3 and the ESP32-P4, not a
power-on; on the rv64sbi machines they last until the next start.
What should outlive that is kept in a file too, and written here
again as the system starts.

**BUGS**

None known.

**SEE ALSO**

`ReadBattMem`, `ObtainBattSemaphore`, sdk.resources.battmembits,
C:SetClock

**EXAMPLES**

```zig
const bits = dos.timezone.pack(&zone) orelse return error.NotKept;
_ = mb.WriteBattMem(@ptrCast(&bits), battmembits.BATTMEM_ZONE_ADDR, battmembits.BATTMEM_ZONE_LEN);
```
