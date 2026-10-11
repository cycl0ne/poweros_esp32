// SPDX-License-Identifier: MPL-2.0
//! jpeg.resource's base: the lock one decode at a time holds, the 2D-DMA
//! channel the codec is fed through, its descriptors, and the decode
//! being waited for.

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
    /// The decode being waited for: its task and signal, what the codec
    /// raised, how the receive side ended.
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
