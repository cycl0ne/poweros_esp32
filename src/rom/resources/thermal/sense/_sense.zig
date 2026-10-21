// SPDX-License-Identifier: MPL-2.0
//! The board's sensors: found once, from its PARTKIND_THERMAL parts in the
//! order it lists them, each started by its chip's code; and one reading
//! of a sensor.
//!
//! A sensor whose chip the resource has no code for, or that would not
//! start, keeps its unit and gives no reading, so the units after it are
//! still the board's order. The chips there is code for: the JH7110's own
//! sensor (`../jh7110/sensor.zig`).

const sdk = @import("sdk");
const st = sdk.expansion.systemtags;
const ExecBase = sdk.interface.exec.ExecBase;
const BoardPart = sdk.expansion.BoardPart;
const _base = @import("../thermal_base.zig");
const ThermalBase = _base.ThermalBase;

const on_jh7110 = sdk.hardware.chip == .rv64sbi;
const jh7110 = @import("../jh7110/sensor.zig");

/// A sensor: its chip and where it is, as its part gives them, what it
/// measures, its chip's limits in thousandths of a degree (0: none), and
/// whether it started.
pub const Sensor = extern struct {
    chip: u32 = 0,
    base: usize = 0,
    name: ?[*:0]const u8 = null,
    hot: i32 = 0,
    critical: i32 = 0,
    started: bool = false,
};

/// The board's sensors into `tb`, each started; none without
/// expansion.library.
pub fn find(tb: *ThermalBase) void {
    const sys = tb.sys_base;
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return;
    defer sys.CloseLibrary(utility_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return;
    defer sys.CloseLibrary(expansion_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    var part: ?*const BoardPart = null;
    while (tb.units < _base.max_units) {
        part = eb.FindBoardPart(part, st.PARTKIND_THERMAL, st.CHIP_ANY) orelse break;
        const tags = part.?.tags;
        const label = ub.GetTagData(st.PART_Label, 0, tags);
        const chip_name = ub.GetTagData(st.PART_ChipName, 0, tags);
        const named = if (label != 0) label else chip_name;
        var sensor: Sensor = .{
            .chip = @truncate(ub.GetTagData(st.PART_Chip, 0, tags)),
            .base = ub.GetTagData(st.PART_Address, 0, tags),
            .name = if (named != 0) @ptrFromInt(named) else null,
        };
        start(sys, &sensor);
        tb.sensors[tb.units] = sensor;
        tb.units += 1;
    }
}

/// `sensor` started by its chip's code, its limits filled in.
fn start(sys: *ExecBase, sensor: *Sensor) void {
    if (comptime on_jh7110) {
        if (sensor.chip == st.CHIP_JH7110_TEMP and sensor.base != 0) {
            sensor.hot = jh7110.hot;
            sensor.critical = jh7110.critical;
            sensor.started = jh7110.start(sys, sensor.base);
        }
    }
}

/// `sensor`'s reading in thousandths of a degree, or null: it did not
/// start, or has not converted yet.
pub fn read(sensor: *const Sensor) ?i32 {
    if (!sensor.started) return null;
    if (comptime on_jh7110) {
        if (sensor.chip == st.CHIP_JH7110_TEMP) return jh7110.read(sensor.base);
    }
    return null;
}
