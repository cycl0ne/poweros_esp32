// SPDX-License-Identifier: MPL-2.0
//! The board this image is built for. `-Dboard` picks the directory, and
//! each board's directory holds what is true of that board: `system.zig`,
//! its system tag list (a ROM tag of its own, which expansion.library
//! reads), and `romtags.zig`, the drivers its parts want in the image. A
//! board that resets the machine itself, or whose firmware needs something
//! done before it does, has `reset.zig` too (`before_reset`), one that
//! sets its cores' supply itself `power.zig` (`cpu_supply`), one whose
//! firmware sets the cores' clock when asked `clock.zig` (`cpu_clock`),
//! one whose firmware powers its parts' blocks only when asked
//! `domains.zig` (`firmware_power`) - and one whose reset tells the
//! firmware first the memory for that in `reset.zig` (`reset_notice`) -
//! one whose console's pins the
//! firmware leaves to something else `pins.zig` (`console_pins`), and one
//! whose devices' interrupts come through a controller of its own the
//! code for that (`interrupt_bridge`).
//!
//! The kernel's own code reads the same list at compile time, through
//! `fact` and `partFact`, so a fact is written once whoever reads it.
//!
//! Only the kernel reads this - `main.zig`, `src/arch/`, the debug shell.
//! A module asks expansion.library.

const build_options = @import("build_options");
const sdk = @import("sdk");
const Tag = sdk.utility.Tag;
const FixedTagItem = sdk.utility.FixedTagItem;
const st = sdk.expansion.systemtags;

pub const system = switch (build_options.board) {
    .waveshare_7b => @import("waveshare_7b/system.zig"),
    .es3c35p => @import("es3c35p/system.zig"),
    .qemu => @import("qemu/system.zig"),
    .esp32p4_emu => @import("esp32p4_emu/system.zig"),
    .olimex_p4pc => @import("olimex_p4pc/system.zig"),
    .crowpanel_p4 => @import("crowpanel_p4/system.zig"),
    .qemu_virt => @import("qemu_virt/system.zig"),
    .visionfive2 => @import("visionfive2/system.zig"),
    .qemu_virt_a64 => @import("qemu_virt_a64/system.zig"),
    .rpi_cm5 => @import("rpi_cm5/system.zig"),
    .rpi_cm4 => @import("rpi_cm4/system.zig"),
    .qemu_q35 => @import("qemu_q35/system.zig"),
};

pub const romtags = switch (build_options.board) {
    .waveshare_7b => @import("waveshare_7b/romtags.zig"),
    .es3c35p => @import("es3c35p/romtags.zig"),
    .qemu => @import("qemu/romtags.zig"),
    .esp32p4_emu => @import("esp32p4_emu/romtags.zig"),
    .olimex_p4pc => @import("olimex_p4pc/romtags.zig"),
    .crowpanel_p4 => @import("crowpanel_p4/romtags.zig"),
    .qemu_virt => @import("qemu_virt/romtags.zig"),
    .visionfive2 => @import("visionfive2/romtags.zig"),
    .qemu_virt_a64 => @import("qemu_virt_a64/romtags.zig"),
    .rpi_cm5 => @import("rpi_cm5/romtags.zig"),
    .rpi_cm4 => @import("rpi_cm4/romtags.zig"),
    .qemu_q35 => @import("qemu_q35/romtags.zig"),
};

/// What the board does before the firmware resets the machine - its own
/// reset, perhaps, which then does not return - or null.
pub const before_reset: ?*const fn () void = switch (build_options.board) {
    .visionfive2 => @import("visionfive2/reset.zig").reset,
    .rpi_cm4 => @import("rpi_cm4/reset.zig").reset,
    else => null,
};

/// How the board sets its cores' supply, in microvolts, for the clock it
/// asks for (SYSTAG_CpuSpeed): true once the supply is there. Null where
/// the board has no say in it.
pub const cpu_supply: ?*const fn (microvolts: u32) bool = switch (build_options.board) {
    .visionfive2 => @import("visionfive2/power.zig").setCpuSupply,
    else => null,
};

/// How the board's firmware is asked for the cores' clock, in MHz
/// (SYSTAG_CpuSpeed), once exec is up and before the clock is measured:
/// the clock it set, 0 if it did not answer. Null where the kernel sets
/// the clock itself, or leaves it.
pub const cpu_clock: ?*const fn (sys: *sdk.interface.exec.ExecBase, mhz: u32) u32 = switch (build_options.board) {
    .rpi_cm5 => @import("rpi_cm5/clock.zig").setCpuClock,
    .rpi_cm4 => @import("rpi_cm4/clock.zig").setCpuClock,
    else => null,
};

/// How the board's firmware is asked to power the blocks the board's
/// parts are in, once exec is up and before any driver runs; a block it
/// did not power is in the log, and why. Null where the firmware leaves
/// them on, or there is no firmware to ask.
pub const firmware_power: ?*const fn (sys: *sdk.interface.exec.ExecBase) void = switch (build_options.board) {
    .rpi_cm4 => @import("rpi_cm4/domains.zig").powerUp,
    else => null,
};

/// How the board's reset gets the memory it tells the firmware of the
/// reset in, once exec is up: where the firmware has to be told (Linux's
/// NOTIFY_REBOOT) and the reset has no exec to ask. Null elsewhere.
pub const reset_notice: ?*const fn (sys: *sdk.interface.exec.ExecBase) void = switch (build_options.board) {
    .rpi_cm4 => @import("rpi_cm4/reset.zig").keepNotice,
    else => null,
};

/// How the console's pins are given to its UART (SYSTAG_ConsoleBase),
/// before the kernel's first line: where the firmware gives them to
/// another. Null where they are the console's already.
pub const console_pins: ?*const fn () void = switch (build_options.board) {
    .rpi_cm4 => @import("rpi_cm4/pins.zig").consolePins,
    else => null,
};

/// How the board's firmware is asked for the picture it lit, before any
/// driver runs: `ask` answers it (null where it lit none), `declare`
/// writes it into the board's description as a panel part. The kernel
/// writes its lines on it until the display driver has it - the one place
/// they can be read on a board with no serial port.
pub const FirmwareScreen = struct {
    ask: *const fn () ?sdk.hardware.videocore.Picture,
    declare: *const fn (sdk.hardware.videocore.Picture) bool,
};

/// The board's, or null where it has a display driver of its own, or no
/// display.
pub const firmware_screen: ?FirmwareScreen = switch (build_options.board) {
    .rpi_cm4 => .{ .ask = @import("rpi_cm4/screen.zig").ask, .declare = @import("rpi_cm4/screen.zig").declare },
    else => null,
};

/// A controller between some of the board's devices and the chip's own:
/// its sources reach it as interrupts `first` to `first + count - 1`,
/// each taken on its edge, and it has its say in each - set up once the
/// chip's controller is (`init`), switched on and off with it, and told
/// once a source's servers have run (`end`).
pub const InterruptBridge = struct {
    first: u32,
    count: u32,
    init: *const fn () void,
    enable: *const fn (source: u32) void,
    disable: *const fn (source: u32) void,
    end: *const fn (source: u32) void,
};

/// The board's, or null: the CM5's RP1, whose interrupts are messages.
pub const interrupt_bridge: ?*const InterruptBridge = switch (build_options.board) {
    .rpi_cm5 => &@import("rpi_cm5/rp1.zig").bridge,
    else => null,
};

/// The first item of `list` with `tag`, or null. A list's tags are plain
/// here: none of the kernel's facts are behind TAG_MORE. Run at compile
/// time only.
fn findIn(list: [*]const FixedTagItem, tag: Tag) ?FixedTagItem {
    var at: usize = 0;
    while (list[at].tag != sdk.utility.TAG_DONE) : (at += 1) {
        if (list[at].tag == tag) return list[at];
    }
    return null;
}

/// A number from the board's root list, `default` when it is absent.
pub fn fact(comptime tag: Tag, comptime default: usize) usize {
    const found = comptime findIn(&system.root, tag);
    return if (found) |item| comptime item.data.value else default;
}

/// How many cores the kernel runs tasks on: the build's `-Dcores`, or
/// else the board's SYSTAG_Cores (1 without it). 0 is the board saying
/// every core the machine has, which the kernel reads from the machine
/// itself.
pub const cores: u32 = if (build_options.cores != 0) build_options.cores else fact(st.SYSTAG_Cores, 1);

/// A string from the board's root list (SYSTAG_Name).
pub fn text(comptime tag: Tag) [*:0]const u8 {
    const found = comptime findIn(&system.root, tag).?;
    return comptime @ptrCast(found.data.pointer.?);
}

/// A number from the board's first part of `kind`, `default` when the
/// board has no such part or the part no such tag.
pub fn partFact(comptime kind: u32, comptime tag: Tag, comptime default: usize) usize {
    return comptime partFactOf(kind, tag, default);
}

fn partFactOf(kind: u32, tag: Tag, default: usize) usize {
    var at: usize = 0;
    while (system.root[at].tag != sdk.utility.TAG_DONE) : (at += 1) {
        if (system.root[at].tag != st.SYSTAG_Part) continue;
        const part: [*]const FixedTagItem = @ptrCast(@alignCast(system.root[at].data.pointer.?));
        const kind_item = findIn(part, st.PART_Kind) orelse continue;
        if (kind_item.data.value != kind) continue;
        return if (findIn(part, tag)) |item| item.data.value else default;
    }
    return default;
}
