// SPDX-License-Identifier: MPL-2.0
//! videodec.resource's base: the chip's decoder - where it is, whether it
//! runs, the firmware's code buffer - the lock its commands are given
//! under, and the decoders open on it, by their instance number.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

/// How many decoders may be open at once.
pub const max_decoders = 8;

/// Where the chip's decoder is: asleep until the first decoder is
/// opened, then running - or dead, when it would not wake or its firmware
/// would not start.
pub const STATE_ASLEEP: u32 = 0;
pub const STATE_RUNNING: u32 = 1;
pub const STATE_DEAD: u32 = 2;

pub const VideoDecBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// The decoder's commands, one caller at a time: held for each call
    /// that gives the chip one, and while it waits for the chip's answer.
    lock: exec.SignalSemaphore,
    /// The WAVE511: its registers (0: the board has none), its interrupt,
    /// its state (STATE_*) and the codecs it takes (VDCODEC_*).
    vpu: usize,
    vpu_irq: u32,
    state: u32,
    codecs: u32,
    /// The firmware's version, as it said once started.
    firmware: u32,
    /// The firmware's code and temp buffer, on a 1 MiB boundary in the
    /// block allocated for it; kept while the chip runs.
    code_block: ?*anyopaque,
    code_block_size: u32,
    code: u32,
    /// The open decoders by their instance number: what the interrupt
    /// server tells. Changed under Disable.
    decoders: [max_decoders]?*anyopaque,
    /// The server on the decoder's interrupt, and whether it is hooked up.
    server: exec.Interrupt,
    hooked: bool,
};
