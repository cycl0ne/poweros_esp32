// SPDX-License-Identifier: MPL-2.0
//! The ROM's modules, in groups a board's ROM is put together from. A
//! board's `romtags.zig` (src/boards/<board>/) names the groups it takes
//! and adds the drivers of its own parts; the kernel's root hands that
//! list to the linker, and every ROM tag in it goes into `.resident`,
//! where exec's boot scan finds it. exec starts them by their priority,
//! not by their place here.
//!
//! A module is in one group. One that a board leaves out of its ROM and
//! has on its disk instead - `pipe`, `motion` - is on the build's list of
//! those too (`rom_on_disk` in build.zig).

/// What every image has: the devices and libraries dos stands on, dos
/// and its handlers, the shell, and what tells a program which system
/// and which machine it runs on.
pub const core = .{
    @import("devs/timer/timer.zig"),
    @import("devs/flash/flash.zig"),
    @import("devs/serial/serial.zig"),
    @import("devs/input/input.zig"),
    @import("devs/keyboard/keyboard.zig"),
    @import("devs/mouse/mouse.zig"),
    @import("libs/keymap/keymap.zig"),
    @import("devs/console/console.zig"),
    @import("libs/utility/utility.zig"),
    @import("libs/expansion/expansion.zig"),
    @import("resources/battmem/battmem.zig"),
    @import("libs/dos/dos.zig"),
    @import("libs/ramlib/ramlib.zig"),
    @import("handler/nil/nil.zig"),
    @import("handler/ram/ram.zig"),
    @import("handler/con/con.zig"),
    @import("handler/flashfs/flashfs.zig"),
    @import("shell/shell.zig"),
    @import("resources/platform/platform.zig"),
    // The system's release, for a program to ask the running system.
    @import("release.zig"),
};

/// What draws: the display boards' library, the drawing, the layers and
/// the windows. The boot shell opens in a window, so a board with a
/// screen has these in its ROM.
pub const screen = .{
    @import("libs/rtg/rtg.zig"),
    @import("libs/graphics/graphics.zig"),
    @import("libs/layers/layers.zig"),
    @import("libs/intuition/intuition.zig"),
};

/// What both ESP32s have in the chip: the console on its USB
/// Serial/JTAG, the pads, the USB port's power, the RTC timer the clock
/// is kept on, the DMA engine and the watchdog.
pub const esp32 = .{
    @import("devs/usbserial/usbserial.zig"),
    @import("resources/gpio/gpio.zig"),
    @import("resources/usbport/usbport.zig"),
    @import("resources/battclock/battclock.zig"),
    @import("resources/dma/dma.zig"),
    @import("resources/watchdog/watchdog.zig"),
};

/// The pipe between two commands, `PIPE:`.
pub const pipe = .{
    @import("handler/pipe/pipe.zig"),
};

/// The clock of things that move.
pub const motion = .{
    @import("libs/motion/motion.zig"),
};

/// The battery's voltage and charge, for a board that measures them.
pub const battery = .{
    @import("resources/battery/battery.zig"),
};
