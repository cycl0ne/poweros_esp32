// SPDX-License-Identifier: MPL-2.0
//! Host test root for the ROM modules (./zig build test). The libraries
//! import exec from its sibling directory, and dos.library imports its
//! handlers from handler/, so the tests' module starts here, above libs/
//! and handler/ (Zig imports nothing outside a module's root directory).

test {
    _ = @import("libs/exec/exec.zig");
    _ = @import("libs/utility/utility.zig");
    _ = @import("libs/expansion/expansion.zig");
    _ = @import("resources/gpio/gpio.zig");
    _ = @import("libs/rtg/rtg.zig");
    _ = @import("libs/graphics/graphics.zig");
    _ = @import("libs/layers/layers.zig");
    _ = @import("libs/intuition/intuition.zig");
    _ = @import("libs/ramlib/loader.zig");
    _ = @import("devs/touch/_touch.zig");
    _ = @import("devs/touch/gt911.zig");
    _ = @import("devs/touch/st7123.zig");
    _ = @import("devs/audio/mixer.zig");
    _ = @import("devs/audio/es8311.zig");
    _ = @import("libs/utility/date/datesplit.zig");
    _ = @import("libs/utility/date/datejoin.zig");
    _ = @import("libs/rtg_driver/dcsboard/sequence.zig");
    _ = @import("devs/keyboard/rawkey.zig");
    _ = @import("devs/mouse/events.zig");
    _ = @import("devs/input/events.zig");
    _ = @import("libs/keymap/keymap.zig");
    _ = @import("devs/console/term.zig");
    _ = @import("devs/console/console.zig");
    _ = @import("libs/dos/dos.zig");
    _ = @import("handler/nil/nil.zig");
    _ = @import("handler/ram/ram.zig");
    _ = @import("handler/con/con.zig");
    _ = @import("handler/pipe/pipe.zig");
    _ = @import("handler/flashfs/volume.zig");
    _ = @import("handler/flashfs/disk.zig");
    _ = @import("handler/flashfs/flashfs.zig");
    _ = @import("shell/shell.zig");
}
