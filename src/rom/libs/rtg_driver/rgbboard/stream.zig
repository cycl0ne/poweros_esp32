// SPDX-License-Identifier: MPL-2.0
//! The only code the panel's timing depends on.
//!
//! Putting the pixel stream back in step means starting the picture and
//! the frame together:
//!
//!   1. the timing generator stopped, so no frame is being emitted;
//!   2. the DMA stopped and reset - stopping it does not empty it, and the
//!      bytes it still holds would go out ahead of the chain;
//!   3. the pixel FIFO emptied;
//!   4. the chain started again from its head, and a moment given for the
//!      first bytes to reach the FIFO;
//!   5. the timing generator started, which begins a frame here and now.
//!
//! The last step is what makes it exact. Restarting the DMA under a
//! running generator only moves the picture to wherever that generator has
//! got to while this ran, which is a different place every frame: the
//! interrupt is taken when the CPU can be bothered, so the picture walks
//! sideways by however much the latency varied. Starting both from a stop
//! leaves no gap to vary.
//!
//! Every cycle here is a cycle the panel's sync signals stand still, so it
//! lives in internal memory and calls nothing that does not. Out of flash
//! it was measured standing still for 43 of a line's 46 microseconds -
//! not because anything is slow, but because an instruction the cache does
//! not hold costs a read of the flash chip, and there are a dozen chances
//! for that in these few calls. That is also why every entry point is
//! `noinline`: the caller is in flash, and a copy inlined into it would
//! run from there.
//!
//! It drives the DMA channel's registers rather than dma.resource's entry
//! points, which are in flash for the same reason. The channel is still
//! the driver's, taken and given back through the resource like any other
//! owner's.

const lcd = @import("lcd.zig");
const gdma = @import("sdk").hardware.gdma;
const cpu = @import("sdk").hardware.cpu;
const Panel = @import("panel.zig").Panel;

/// Stop the generator and the stream, and empty what they hold.
pub noinline fn stopStream(panel: *Panel) linksection(".iram.text") void {
    @setRuntimeSafety(false);
    lcd.stop();
    gdma.stop(panel.channel, .out);
    gdma.reset(panel.channel, .out);
    lcd.fifoReset();
}

/// Start them again, together. Returns how long the whole of it took, in
/// CPU cycles: the gap the panel saw.
pub noinline fn restart(panel: *Panel) linksection(".iram.text") u32 {
    @setRuntimeSafety(false);
    const began = cpu.ccount();
    // A timing change belongs here, with the generator stopped: the
    // peripheral takes one where `update` is set, and anywhere else that
    // is in the middle of a frame the DMA is feeding.
    if (panel.want_start) |start| {
        lcd.setActiveStart(start);
        panel.want_start = null;
    }
    gdma.start(panel.channel, .out, @truncate(@intFromPtr(panel.chain)));
    spin(panel.fill_cycles);
    lcd.start();
    return cpu.ccount() -% began;
}

noinline fn spin(cycles: u32) linksection(".iram.text") void {
    @setRuntimeSafety(false);
    const began = cpu.ccount();
    while (cpu.ccount() -% began < cycles) {}
}
