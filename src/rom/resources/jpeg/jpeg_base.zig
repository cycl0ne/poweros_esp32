// SPDX-License-Identifier: MPL-2.0
//! jpeg.resource's base: the lock one decode at a time holds, the codec -
//! the ESP32-P4's with the 2D-DMA channel it is fed through and its
//! descriptors, or the JH7110's - and the decode being waited for.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DmaBase = sdk.resources.dma.DmaBase;

pub const JpegBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// One decode at a time; its holder waits for the codec.
    lock: exec.SignalSemaphore,
    /// dma.resource, while the resource holds the codec's 2D-DMA channel
    /// there; null: the codec cannot be used.
    dma: ?*DmaBase,
    /// The two 2D-DMA descriptors, 24 bytes each: the scan's, the
    /// picture's.
    descriptors: [12]u32 align(8),
    /// The JH7110's codec: its registers (0: the board has none), its
    /// interrupt, and whether it is awake - woken by the first decode -
    /// or would not wake.
    jpu: usize,
    jpu_irq: u32,
    jpu_awake: bool,
    jpu_dead: bool,
    /// The decode being waited for: its task and signal, what the codec
    /// raised, how the receive side ended - on the JH7110, what the codec
    /// raised as it ended.
    waiter: ?*exec.Task,
    waiter_mask: u32,
    errors: u32,
    ended: u32,
    /// The servers on the codec's interrupt and the receive side's, and
    /// whether they are hooked up.
    codec_int: exec.Interrupt,
    dma_int: exec.Interrupt,
    hooked: bool,
};
