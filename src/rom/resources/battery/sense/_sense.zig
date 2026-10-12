// SPDX-License-Identifier: MPL-2.0
//! How the board's battery is measured: its wiring, read once from the
//! board's PARTKIND_BATTERY part, and one measurement of it.
//!
//! **The cell's voltage** comes from PART_Pin: a pad of the SAR ADC's
//! first unit, which the kernel keeps sampling that pad from boot (its
//! entropy source), so a reading is the unit's last sample made into
//! millivolts by the chip's calibration (`sdk.hardware.saradc`); or the
//! IO expander's analogue input (expander.resource's ReadADC). A chip
//! without its ADC calibration in eFuse measures nothing. Several readings are averaged, and the
//! average multiplied by PART_SenseScale for what the divider on the
//! board took off. **External power and charging** are lines a pad or an
//! expander pin reads (PART_PinExternal, PART_PinCharging), asserted at
//! the level their BoardPin says.
//!
//! The expander's analogue input is a BoardPin of kind BPIN_EXPANDER and
//! number `expander.PIN_ANALOG`, past its eight digital pins. It reads
//! 0 to 1023 for 0 V to the expander's own supply, 3.3 V, which is
//! what its accuracy is.

const sdk = @import("sdk");
const exec = sdk.exec;
const battery = sdk.resources.battery;
const expander = sdk.resources.expander;
const st = sdk.expansion.systemtags;
const boardpin = sdk.expansion.boardpin;
const BoardPin = sdk.expansion.BoardPin;
const ExecBase = sdk.interface.exec.ExecBase;
const pads = sdk.hardware.gpio;
const saradc = sdk.hardware.saradc;
const BatteryBase = @import("../battery_base.zig").BatteryBase;

/// How the battery is wired: its lines as the board's part gives them
/// (BoardPin data, 0 for a line it does not have), and the sense
/// divider's scale in thousandths.
pub const Wiring = extern struct {
    sense: u32 = 0,
    scale: u32 = 1000,
    external: u32 = 0,
    charging: u32 = 0,

    /// Whether there is anything to measure at all.
    pub fn any(wiring: Wiring) bool {
        return wiring.sense != 0 or wiring.external != 0 or wiring.charging != 0;
    }
};

/// The expander's analogue input: its full scale in millivolts, and
/// the reading there.
const expander_full_mv: u32 = 3300;
const expander_full_count: u32 = 1023;
/// Readings averaged into one measurement. The ADC samples every few
/// microseconds, and a reading takes about that long - the calibration
/// is read out of eFuse each time - so each is another sample.
const samples = 8;

/// The board's battery part, as wiring; none without one.
pub fn wiringOf(sys: *ExecBase) Wiring {
    const none: Wiring = .{};
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return none;
    defer sys.CloseLibrary(utility_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return none;
    defer sys.CloseLibrary(expansion_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_BATTERY, st.CHIP_ANY) orelse return none;
    const tags = part.tags;
    return .{
        .sense = @truncate(ub.GetTagData(st.PART_Pin, 0, tags)),
        .scale = @truncate(ub.GetTagData(st.PART_SenseScale, 1000, tags)),
        .external = @truncate(ub.GetTagData(st.PART_PinExternal, 0, tags)),
        .charging = @truncate(ub.GetTagData(st.PART_PinCharging, 0, tags)),
    };
}

/// What the board can tell, as BATTF_* flags: the ones a measurement
/// fills in later.
pub fn abilities(wiring: Wiring) u32 {
    var flags: u32 = 0;
    if (wiring.sense != 0) flags |= battery.BATTF_MEASURED;
    if (wiring.external != 0) flags |= battery.BATTF_KNOWS_EXTERNAL;
    if (wiring.charging != 0) flags |= battery.BATTF_KNOWS_CHARGING;
    return flags;
}

/// The lines set up: an ADC pad on the chip's ADC, a digital line as an
/// input. The pads are taken from gpio.resource first; a line on the
/// expander is the expander's to read. False if a pad is someone else's,
/// or the sense pad is not one the ADC reads.
pub fn setUp(bb: *BatteryBase) bool {
    const sys = bb.sys_base;
    const gb: ?*sdk.interface.gpio.GpioBase = @ptrCast(@alignCast(sys.OpenResource(sdk.resources.gpio.GPIONAME)));
    const lines = [_]u32{ bb.wiring.sense, bb.wiring.external, bb.wiring.charging };
    for (lines) |data| {
        const line = BoardPin.of(data);
        switch (line.kind) {
            boardpin.BPIN_GPIO => if (gb) |taken_from| {
                if (taken_from.AllocGPIO(line.number, battery.BATTERYNAME)) |holder| {
                    sdk.exec.kprintf(sys, "%s: GPIO%d is %s's\n", .{ battery.BATTERYNAME, @as(u32, line.number), holder });
                    return false;
                }
            },
            boardpin.BPIN_EXPANDER => if (bb.expander == null) {
                bb.expander = @ptrCast(@alignCast(sys.OpenResource(expander.EXPANDERNAME)));
            },
            else => {},
        }
    }
    const sense = BoardPin.of(bb.wiring.sense);
    if (sense.kind == boardpin.BPIN_GPIO) {
        const channel = saradc.channelOf(sense.number) orelse {
            sdk.exec.kprintf(sys, "%s: GPIO%d is not on the ADC's first unit\n", .{ battery.BATTERYNAME, @as(u32, sense.number) });
            return false;
        };
        if (saradc.calibration(channel) == null) {
            sdk.exec.kprintf(sys, "%s: no ADC calibration in this chip's eFuse\n", .{battery.BATTERYNAME});
            bb.wiring.sense = 0;
        }
    }
    for ([_]u32{ bb.wiring.external, bb.wiring.charging }) |data| {
        const line = BoardPin.of(data);
        if (line.kind != boardpin.BPIN_GPIO) continue;
        pads.toMatrix(line.number);
        pads.outputEnable(line.number, false);
        pads.pullUp(line.number, false);
        pads.inputEnable(line.number, true);
    }
    return true;
}

/// One measurement: the cell's voltage in millivolts (0 when the board
/// cannot measure it, or the reading failed), and the lines' states.
pub const Reading = struct { millivolts: u32 = 0, external: bool = false, charging: bool = false };

pub fn measure(bb: *BatteryBase) Reading {
    return .{
        .millivolts = senseMillivolts(bb),
        .external = asserted(bb, bb.wiring.external),
        .charging = asserted(bb, bb.wiring.charging),
    };
}

/// The cell's voltage: the average of `samples` readings at the sense
/// line, scaled back up past the divider.
fn senseMillivolts(bb: *BatteryBase) u32 {
    const line = BoardPin.of(bb.wiring.sense);
    var sum: u64 = 0;
    var taken: u32 = 0;
    var i: u32 = 0;
    while (i < samples) : (i += 1) {
        const mv: ?u32 = switch (line.kind) {
            boardpin.BPIN_GPIO => padMillivolts(line.number),
            boardpin.BPIN_EXPANDER => expanderMillivolts(bb),
            else => return 0,
        };
        if (mv) |one| {
            sum += one;
            taken += 1;
        }
    }
    if (taken == 0) return 0;
    const at_line: u64 = sum / taken;
    return @intCast(at_line * bb.wiring.scale / 1000);
}

/// The ADC's last sample of the pad, in millivolts.
fn padMillivolts(pad: u8) ?u32 {
    const channel = saradc.channelOf(pad) orelse return null;
    const cal = saradc.calibration(channel) orelse return null;
    return saradc.millivolts(saradc.latest(), cal);
}

fn expanderMillivolts(bb: *BatteryBase) ?u32 {
    const eb = bb.expander orelse return null;
    const raw = eb.ReadADC();
    if (raw < 0) return null;
    return @intCast(@as(u64, @intCast(raw)) * expander_full_mv / expander_full_count);
}

/// Whether a line is at its asserted level; false for a line the board
/// does not have.
fn asserted(bb: *BatteryBase, data: u32) bool {
    const line = BoardPin.of(data);
    const high = switch (line.kind) {
        boardpin.BPIN_GPIO => pads.level(line.number),
        boardpin.BPIN_EXPANDER => blk: {
            const eb = bb.expander orelse return false;
            const level = eb.GetPin(line.number);
            if (level < 0) return false;
            break :blk level != 0;
        },
        else => return false,
    };
    return high == (line.active_low == 0);
}
