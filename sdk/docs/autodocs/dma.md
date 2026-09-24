# dma.resource

dma.resource's functions: the chip's general DMA engine (GDMA), its
channels handed out to one owner each. A
resource: no Open or Close, its first function in the first slot. The
base comes from OpenResource("dma.resource").

Generated from the source by `./zig build autodoc`.

## Index

- [AllocDMAChain](#allocdmachain) - A descriptor chain over `length` bytes at `buffer`, for a side: DMA_OUT sends them all (EOF on the last descriptor), DMA_IN fills them.
- [AllocDMAChannel](#allocdmachannel) - Claim a channel (0-4) for `name`: null if it is now yours, else its owner's name.
- [ClearDMAInts](#cleardmaints) - Clear a side's interrupts.
- [ConnectDMAChannel](#connectdmachannel) - Connect a channel to a peripheral (DMAPERI_*), or DMAPERI_MEMORY for memory to memory, with DMACF_* flags.
- [DMAChannelOwner](#dmachannelowner) - Who has a channel, or null.
- [DMAEOFDescriptor](#dmaeofdescriptor) - The descriptor that ended a side's last frame: IN's with SUC_EOF, OUT's last with EOF sent.
- [DMAIntStatus](#dmaintstatus) - A side's pending, enabled interrupts.
- [DMARawIntStatus](#dmarawintstatus) - A side's interrupt bits as the hardware sets them, enabled or not: what a driver polls when it wants to know that something happened without being interrupted by it.
- [EnableDMAInts](#enabledmaints) - Enable a side's interrupts (DMAINTF_*); 0: none.
- [FreeDMAChain](#freedmachain) - Free a chain from AllocDMAChain (null: nothing).
- [FreeDMAChannel](#freedmachannel) - Give a channel back: it stops, is disconnected, its interrupts off.
- [ResetDMA](#resetdma) - Reset a side: its FIFO and state machine, its connection and flags left as they are.
- [SetDMAPriority](#setdmapriority) - A side's priority on the bus, 0 (lowest) to DMA_MAXPRI.
- [StartDMA](#startdma) - Start a side (DMA_IN, DMA_OUT) on a descriptor chain.
- [StopDMA](#stopdma) - Stop a side.

## AllocDMAChain

A descriptor chain over `length` bytes at `buffer`, for a side: DMA_OUT sends them all (EOF on the last descriptor), DMA_IN fills them.

**SYNOPSIS**

```zig
?*dma.DMADescriptor AllocDMAChain(u32 side, ?*anyopaque buffer, u32 length, u32 flags)
```

**BEHAVIOR**

In internal memory, DMA_CHUNK (PSRAM: DMA_CHUNK_PSRAM) bytes per
descriptor; DMACHF_LOOP links the last back to the first. Null if the
buffer isn't in internal RAM or PSRAM, or without memory. Not from
interrupts.

## AllocDMAChannel

Claim a channel (0-4) for `name`: null if it is now yours, else its owner's name.

**SYNOPSIS**

```zig
?[*:0]const u8 AllocDMAChannel(u32 channel, [*:0]const u8 name)
```

**BEHAVIOR**

Not from interrupts.

## ClearDMAInts

Clear a side's interrupts.

**SYNOPSIS**

```zig
void ClearDMAInts(u32 channel, u32 side, u32 mask)
```

**BEHAVIOR**

From interrupts too.

## ConnectDMAChannel

Connect a channel to a peripheral (DMAPERI_*), or DMAPERI_MEMORY for memory to memory, with DMACF_* flags.

**SYNOPSIS**

```zig
bool ConnectDMAChannel(u32 channel, u32 peripheral, u32 flags)
```

**BEHAVIOR**

Resets the channel. False for a bad channel or peripheral, or a
peripheral another channel is connected to.

## DMAChannelOwner

Who has a channel, or null.

**SYNOPSIS**

```zig
?[*:0]const u8 DMAChannelOwner(u32 channel)
```

## DMAEOFDescriptor

The descriptor that ended a side's last frame: IN's with SUC_EOF, OUT's last with EOF sent.

**SYNOPSIS**

```zig
?*dma.DMADescriptor DMAEOFDescriptor(u32 channel, u32 side)
```

**BEHAVIOR**

Null if none yet.

## DMAIntStatus

A side's pending, enabled interrupts.

**SYNOPSIS**

```zig
u32 DMAIntStatus(u32 channel, u32 side)
```

**BEHAVIOR**

From interrupts too.

## DMARawIntStatus

A side's interrupt bits as the hardware sets them, enabled or not: what a driver polls when it wants to know that something happened without being interrupted by it.

**SYNOPSIS**

```zig
u32 DMARawIntStatus(u32 channel, u32 side)
```

**BEHAVIOR**

From interrupts too.

## EnableDMAInts

Enable a side's interrupts (DMAINTF_*); 0: none.

**SYNOPSIS**

```zig
void EnableDMAInts(u32 channel, u32 side, u32 mask)
```

## FreeDMAChain

Free a chain from AllocDMAChain (null: nothing).

**SYNOPSIS**

```zig
void FreeDMAChain(?*dma.DMADescriptor chain)
```

**BEHAVIOR**

Not from interrupts.

## FreeDMAChannel

Give a channel back: it stops, is disconnected, its interrupts off.

**SYNOPSIS**

```zig
void FreeDMAChannel(u32 channel)
```

**BEHAVIOR**

Remove your interrupt servers first. Not from interrupts.

## ResetDMA

Reset a side: its FIFO and state machine, its connection and flags left as they are.

**SYNOPSIS**

```zig
void ResetDMA(u32 channel, u32 side)
```

**BEHAVIOR**

Stopping a side does not empty it, and what it still holds goes out
ahead of the next chain it is started on. From interrupts too.

## SetDMAPriority

A side's priority on the bus, 0 (lowest) to DMA_MAXPRI.

**SYNOPSIS**

```zig
bool SetDMAPriority(u32 channel, u32 side, u32 priority)
```

**BEHAVIOR**

False for a bad channel, side or priority.

## StartDMA

Start a side (DMA_IN, DMA_OUT) on a descriptor chain.

**SYNOPSIS**

```zig
bool StartDMA(u32 channel, u32 side, *dma.DMADescriptor list)
```

**BEHAVIOR**

False unless the first descriptor is 4-byte aligned in internal RAM.
Memory to memory: IN first, then OUT.

## StopDMA

Stop a side.

**SYNOPSIS**

```zig
void StopDMA(u32 channel, u32 side)
```
