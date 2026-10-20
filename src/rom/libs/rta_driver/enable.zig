// SPDX-License-Identifier: MPL-2.0
//! An output's enable line: the pad that switches the amplifier in front
//! of a speaker on, as the board's part says (`PART_PinEnable`, low or
//! high for on). The sinks of the parts fed over I2S share it.
//!
//! The pad is taken from gpio.resource when the sink starts and given
//! back when it stops, and driven only in between: until then the board's
//! own pull holds the amplifier off, so the speaker is quiet through the
//! boot. A part with no enable line, or one on something other than a pad
//! of the chip, has nothing to switch.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const expansion = sdk.expansion;
const BoardPin = expansion.BoardPin;
const gpio = sdk.hardware.gpio;
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;

pub const Enable = struct {
    line: BoardPin = .{},
    /// The resource the pad was taken from, while it is this sink's.
    gpio_base: ?*GpioBase = null,
    /// The pad is this sink's: taken, or no resource to take it from.
    held: bool = false,

    /// The line of a part's `PART_PinEnable`.
    ///
    /// INPUTS:
    /// - `value` - the tag's data; 0 for a part without one.
    pub fn of(value: usize) Enable {
        return .{ .line = BoardPin.of(value) };
    }

    fn isPad(enable: *const Enable) bool {
        return enable.line.kind == expansion.boardpin.BPIN_GPIO;
    }

    /// The pad taken for `owner`. False if another driver holds it, said
    /// on the raw port; a machine without gpio.resource takes nothing.
    ///
    /// INPUTS:
    /// - `enable` - the line.
    /// - `sys` - exec.
    /// - `owner` - who takes it, as gpio.resource lists its holder.
    pub fn take(enable: *Enable, sys: *ExecBase, owner: [*:0]const u8) bool {
        if (!enable.isPad()) return true;
        const gb: *GpioBase = @ptrCast(@alignCast(sys.OpenResource(gpio_resource.GPIONAME) orelse {
            enable.held = true;
            return true;
        }));
        const pads = [_]u8{enable.line.number};
        if (gpio_resource.allocPads(gb, &pads, owner)) |refused| {
            exec.kprintf(sys, "%s: GPIO%d is %s's\n", .{ owner, @as(u32, refused.pad), refused.holder });
            return false;
        }
        enable.gpio_base = gb;
        enable.held = true;
        return true;
    }

    /// The amplifier on or off - only while the pad is this sink's.
    ///
    /// INPUTS:
    /// - `enable` - the line.
    /// - `on` - whether the amplifier is to play.
    pub fn set(enable: *const Enable, on: bool) void {
        if (!enable.isPad() or !enable.held) return;
        const pad = enable.line.number;
        gpio.toMatrix(pad);
        gpio.connectOut(pad, gpio.out_of_gpio, true);
        gpio.outputEnable(pad, true);
        gpio.setLevel(pad, if (enable.line.active_low != 0) !on else on);
    }

    /// The amplifier off and the pad given back.
    ///
    /// INPUTS:
    /// - `enable` - the line.
    pub fn giveBack(enable: *Enable) void {
        enable.set(false);
        if (enable.gpio_base) |gb| {
            const pads = [_]u8{enable.line.number};
            gpio_resource.freePads(gb, &pads);
        }
        enable.gpio_base = null;
        enable.held = false;
    }
};
