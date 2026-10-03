// SPDX-License-Identifier: MIT
//! Battery: a battery's state, read over Modbus TCP from a Victron GX
//! device (a Cerbo GX and its kind) and shown in a window. Built against
//! the SDK only.
//!
//!   Battery HOST/K,ID=UNIT/K/N,PORT/K/N,INTERVAL/K/N
//!
//! HOST is the GX device (192.168.1.13), PORT its Modbus TCP port (502),
//! UNIT the battery's unit ID (225) - the number the GX device lists for
//! the battery under Settings, Services, Modbus TCP, Available services,
//! which is not its VRM instance. INTERVAL is how often it is read, in
//! seconds (2).
//!
//! The window shows the state of charge on a ring, the state of health
//! on a bar under it, the power on a meter (discharging to the left of
//! 0, charging to the right), the readings and the charge limits as text,
//! and the power over the last four minutes as a chart. A line at the
//! bottom says when it was last read, or why it could not be.
//!
//! The battery's registers (com.victronenergy.battery), as a Cerbo GX
//! with a battery on VE.Can gives them - holding
//! registers read one at a time, so one the battery does not have
//! leaves only its own field empty:
//!
//!   258  power                    int16    1 W
//!   259  voltage                  uint16   0.01 V
//!   261  current                  int16    0.1 A
//!   262  temperature              int16    0.1 °C
//!   266  state of charge          uint16   0.1 %
//!   304  state of health          uint16   0.1 %
//!   305  charge voltage limit     uint16   0.1 V
//!   306  charge current limit     uint16   0.1 A
//!   307  discharge current limit  uint16   0.1 A
//!
//! A reading that fails for the connection - no answer, the connection
//! closed - ends the round; the connection is made again at the next.
//! The close gadget or Ctrl-C end it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const motion = sdk.motion;
const modbus = sdk.modbus;
const bsd = sdk.bsdsocket;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const MotionBase = sdk.interface.motion.MotionBase;
const ModbusBase = sdk.interface.modbus.ModbusBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const mt = sdk.gadgets.meter;
const ar = sdk.gadgets.arc;
const fg = sdk.gadgets.fuelgauge;
const tx = sdk.gadgets.text;
const cr = sdk.gadgets.chart;

pub const COMMAND_NAME = "Battery";
const VERSION_STRING = "\x00$VER: Battery 1.0 (03.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "HOST/K,ID=UNIT/K/N,PORT/K/N,INTERVAL/K/N";
const arg_host = 0;
const arg_unit = 1;
const arg_port = 2;
const arg_interval = 3;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOMEMORY = "%s: no memory for the gadgets\n";
const MSG_NOWINDOW = "%s: no window\n";

/// The power meter's scale, in watts either way.
const power_range = 10000;
/// How many readings the chart keeps: four minutes at two seconds.
const history = 120;

/// A register, how it is read, and where it is shown.
const Reading = struct {
    address: u32,
    signed: bool,
    /// How many decimals the register holds: 0 whole, 1 tenths, 2
    /// hundredths; shown with as many.
    decimals: u8,
    unit: []const u8,
    label: [*:0]const u8,
};

const voltage = 0;
const current = 1;
const power = 2;
const soc = 3;
const soh = 4;
const temperature = 5;
const charge_voltage = 6;
const charge_current = 7;
const discharge_current = 8;

const readings = [_]Reading{
    .{ .address = 259, .signed = false, .decimals = 2, .unit = " V", .label = "Voltage" },
    .{ .address = 261, .signed = true, .decimals = 1, .unit = " A", .label = "Current" },
    .{ .address = 258, .signed = true, .decimals = 0, .unit = " W", .label = "Power" },
    .{ .address = 266, .signed = false, .decimals = 1, .unit = " %", .label = "Charge" },
    .{ .address = 304, .signed = false, .decimals = 1, .unit = " %", .label = "Health" },
    .{ .address = 262, .signed = true, .decimals = 1, .unit = " \xB0C", .label = "Temperature" },
    .{ .address = 305, .signed = false, .decimals = 1, .unit = " V", .label = "Charge voltage" },
    .{ .address = 306, .signed = false, .decimals = 1, .unit = " A", .label = "Charge current" },
    .{ .address = 307, .signed = false, .decimals = 1, .unit = " A", .label = "Discharge current" },
};

/// The fields in the "Battery" group, and those in the "Limits" group.
const battery_fields = [_]usize{ voltage, current, power, temperature };
const limit_fields = [_]usize{ charge_voltage, charge_current, discharge_current };

fn pair(t: sdk.utility.Tag, data: usize) TagItem {
    return .{ .tag = t, .data = data };
}

fn signedData(value: i32) usize {
    return @bitCast(@as(isize, value));
}

/// A field's text: the value with its unit, or a dash.
const Field = struct {
    text: [24:0]u8 = @splat(0),

    fn set(field: *Field, value: ?i32, reading: Reading) void {
        var at: usize = 0;
        const out = &field.text;
        const number = value orelse {
            out[0] = '-';
            out[1] = 0;
            return;
        };
        var magnitude: u32 = @abs(number);
        if (number < 0) {
            out[at] = '-';
            at += 1;
        }
        var digits: [10]u8 = undefined;
        var count: usize = 0;
        var fraction: [2]u8 = undefined;
        var places: usize = 0;
        while (places < reading.decimals) : (places += 1) {
            fraction[reading.decimals - 1 - places] = @intCast('0' + magnitude % 10);
            magnitude /= 10;
        }
        while (true) {
            digits[count] = @intCast('0' + magnitude % 10);
            count += 1;
            magnitude /= 10;
            if (magnitude == 0) break;
        }
        while (count > 0) {
            count -= 1;
            out[at] = digits[count];
            at += 1;
        }
        if (places > 0) {
            out[at] = '.';
            @memcpy(out[at + 1 ..][0..places], fraction[0..places]);
            at += 1 + places;
        }
        @memcpy(out[at..][0..reading.unit.len], reading.unit);
        at += reading.unit.len;
        out[at] = 0;
    }
};

/// A text gadget a field is shown in, wide enough for any value.
fn valueGadget(ib: *IntuitionBase, field: *Field) ?*Object {
    return ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Text, @intFromPtr(&field.text)),
        pair(tx.TEXT_Justification, tx.TEXT_JUSTIFY_RIGHT),
        pair(gc.GA_Width, 110),
        .{},
    });
}

/// A framed column of labelled fields.
fn fieldGroup(ib: *IntuitionBase, title: [*:0]const u8, fields: []const usize, gadgets: []const ?*Object) ?*Object {
    var tags: [24]TagItem = undefined;
    var n: usize = 0;
    tags[n] = pair(lg.LAYOUTA_FrameTitle, @intFromPtr(title));
    n += 1;
    tags[n] = pair(lg.LAYOUTA_Margin, 6);
    n += 1;
    tags[n] = pair(lg.LAYOUTA_Spacing, 4);
    n += 1;
    for (fields) |index| {
        tags[n] = pair(lg.LAYOUTA_AddChild, @intFromPtr(gadgets[index]));
        tags[n + 1] = pair(lg.CHILDA_Label, @intFromPtr(readings[index].label));
        tags[n + 2] = pair(lg.CHILDA_WeightHeight, 0);
        n += 3;
    }
    tags[n] = .{};
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &tags);
}

/// A framed row of gadgets.
fn row(ib: *IntuitionBase, title: [*:0]const u8, children: []const ?*Object) ?*Object {
    var tags: [12]TagItem = undefined;
    var n: usize = 0;
    tags[n] = pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ);
    n += 1;
    tags[n] = pair(lg.LAYOUTA_FrameTitle, @intFromPtr(title));
    n += 1;
    tags[n] = pair(lg.LAYOUTA_Margin, 6);
    n += 1;
    tags[n] = pair(lg.LAYOUTA_Spacing, 10);
    n += 1;
    for (children) |child| {
        tags[n] = pair(lg.LAYOUTA_AddChild, @intFromPtr(child));
        n += 1;
    }
    tags[n] = .{};
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &tags);
}

/// The connection to the GX device, made when it is needed.
const Link = struct {
    mb: *ModbusBase,
    sb: *SocketBase,
    host: [*:0]const u8,
    port: u32,
    unit: u32,
    context: ?*modbus.ModbusContext = null,

    fn drop(link: *Link) void {
        if (link.context) |context| link.mb.CloseModbus(context);
        link.context = null;
    }

    /// Every reading, into `values` (null for one the battery did not
    /// give): MBERR_OK, or what ended the round.
    fn read(link: *Link, values: *[readings.len]?i32) i32 {
        if (link.context == null) {
            var err: i32 = 0;
            link.context = link.mb.OpenModbusTCP(link.sb, &[_]TagItem{
                pair(modbus.MBA_Host, @intFromPtr(link.host)),
                pair(modbus.MBA_Port, link.port),
                pair(modbus.MBA_Timeout, 1000),
                .{},
            }, &err);
            if (link.context == null) return err;
        }
        for (readings, 0..) |reading, i| {
            var word: [1]u16 = undefined;
            const result = link.mb.ReadHoldingRegisters(link.context.?, link.unit, reading.address, 1, &word);
            if (result > 0) {
                // The battery has no such register.
                values[i] = null;
                continue;
            }
            if (result != modbus.MBERR_OK) {
                link.drop();
                return result;
            }
            values[i] = if (reading.signed) @as(i16, @bitCast(word[0])) else word[0];
        }
        return modbus.MBERR_OK;
    }
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const host: [*:0]const u8 = rdargs.string(argv[arg_host]) orelse "192.168.1.13";
    const unit: u32 = @intCast(rdargs.number(argv[arg_unit]) orelse 225);
    const port: u32 = @intCast(rdargs.number(argv[arg_port]) orelse 502);
    const interval: u32 = @intCast(@max(rdargs.number(argv[arg_interval]) orelse 2, 1));

    var libraries: [8]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_][*:0]const u8{
        intuition.INTUITIONNAME, motion.MOTIONNAME, modbus.MODBUSNAME, bsd.SOCKETNAME,
        ar.ARC_LIBRARY,          fg.GAUGE_LIBRARY,  mt.METER_LIBRARY,  tx.TEXT_LIBRARY,
    };
    for (wanted, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, name });
            return dos.RETURN_FAIL;
        };
    }
    const chart_lib = sys.OpenLibrary(cr.CHART_LIBRARY, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, @as([*:0]const u8, cr.CHART_LIBRARY) });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(chart_lib);
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);
    const motion_base: *MotionBase = @ptrCast(libraries[1].?);
    const modbus_base: *ModbusBase = @ptrCast(libraries[2].?);
    const socket_base: *SocketBase = @ptrCast(libraries[3].?);

    // The gadgets.
    var fields: [readings.len]Field = @splat(.{});
    for (&fields, readings) |*field, reading| field.set(null, reading);
    var status: [80:0]u8 = @splat(0);
    @memcpy(status[0..12], "Connecting..");

    const charge = ib.NewObjectTagList(null, ar.ARC_CLASS, &[_]TagItem{
        pair(ar.ARC_Max, 100),
        pair(ar.ARC_Format, @intFromPtr("%ld%%")),
        pair(gc.GA_Width, 140),
        pair(gc.GA_Height, 140),
        .{},
    });
    const health = ib.NewObjectTagList(null, fg.GAUGE_CLASS, &[_]TagItem{
        pair(fg.GAUGE_Format, @intFromPtr("Health %ld%%")),
        pair(gc.GA_Width, 140),
        .{},
    });
    const meter = ib.NewObjectTagList(null, mt.METER_CLASS, &[_]TagItem{
        pair(mt.METER_Min, signedData(-power_range)),
        pair(mt.METER_Max, power_range),
        pair(mt.METER_Start, 180),
        pair(mt.METER_Sweep, 180),
        pair(mt.METER_Ticks, 4),
        pair(mt.METER_Minor, 5),
        pair(mt.METER_Format, @intFromPtr("%ld W")),
        pair(gc.GA_Width, 240),
        pair(gc.GA_Height, 170),
        .{},
    });
    const plot = ib.NewObjectTagList(null, cr.CHART_CLASS, &[_]TagItem{
        pair(cr.CHART_Capacity, history),
        pair(cr.CHART_Auto, 1),
        pair(cr.CHART_ColourRGB, 0xFF3070C0),
        pair(gc.GA_Width, 360),
        pair(gc.GA_Height, 110),
        .{},
    });
    const status_line = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Text, @intFromPtr(&status)),
        pair(tx.TEXT_Clipped, 1),
        pair(gc.GA_Width, 300),
        .{},
    });
    // Text for the readings the groups list; charge and health are on
    // the ring and the bar.
    var values_shown: [readings.len]?*Object = @splat(null);
    const listed = battery_fields ++ limit_fields;
    for (listed) |index| values_shown[index] = valueGadget(ib, &fields[index]);

    var all: [listed.len + 5]?*Object = undefined;
    for (listed, 0..) |index, i| all[i] = values_shown[index];
    all[listed.len..][0..5].* = .{ charge, health, meter, plot, status_line };
    for (all) |part| if (part == null) {
        for (all) |made| ib.DisposeObject(made);
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };

    const top = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            pair(lg.LAYOUTA_FrameTitle, @intFromPtr("Charge and health")),
            pair(lg.LAYOUTA_Margin, 6),
            pair(lg.LAYOUTA_Spacing, 6),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(charge)),
            pair(lg.CHILDA_MinWidth, 140),
            pair(lg.CHILDA_MinHeight, 140),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(health)),
            pair(lg.CHILDA_WeightHeight, 0),
            .{},
        }))),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            pair(lg.LAYOUTA_FrameTitle, @intFromPtr("Power")),
            pair(lg.LAYOUTA_Margin, 6),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(meter)),
            pair(lg.CHILDA_MinWidth, 240),
            pair(lg.CHILDA_MinHeight, 170),
            .{},
        }))),
        .{},
    });
    const middle = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(fieldGroup(ib, "Battery", &battery_fields, &values_shown))),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(fieldGroup(ib, "Limits", &limit_fields, &values_shown))),
        .{},
    });
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(top)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(middle)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(row(ib, "Power, last four minutes", &.{plot}))),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(status_line)),
        pair(lg.CHILDA_WeightHeight, 0),
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    var title: [64:0]u8 = @splat(0);
    const title_head = "Battery - ";
    @memcpy(title[0..title_head.len], title_head);
    var host_length: usize = 0;
    while (host[host_length] != 0 and title_head.len + host_length < title.len) : (host_length += 1) title[title_head.len + host_length] = host[host_length];
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr(&title)),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_SizeGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer ib.DisposeObject(object);

    var open = wc.WmOpen{};
    if (ib.SendMessage(object, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOWINDOW, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }
    var window_pointer: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_pointer);
    const window: *intuition.Window = @ptrFromInt(window_pointer);

    // The reading's clock: the first at once, then every interval.
    const bit = sys.AllocSignal(-1);
    if (bit < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(bit);
    const tick = motion_base.CreateTimerTagList(&[_]TagItem{
        pair(motion.TIMER_Period, interval * 1000),
        pair(motion.TIMER_Repeat, motion.TIMER_FOREVER),
        pair(motion.TIMER_Signal, @intCast(bit)),
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer motion_base.DeleteTimer(tick);
    motion_base.StartTimer(tick);
    const tick_mask = @as(u32, 1) << @intCast(bit);

    var link = Link{ .mb = modbus_base, .sb = socket_base, .host = host, .port = port, .unit = unit };
    defer link.drop();
    var rounds: u32 = 0;
    var due = true;
    var code_word: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code_word };
    while (true) {
        if (due) {
            due = false;
            var values: [readings.len]?i32 = @splat(null);
            const result = link.read(&values);
            if (result == modbus.MBERR_OK) {
                rounds += 1;
                for (&fields, readings, values, values_shown) |*field, reading, value, shown| {
                    field.set(value, reading);
                    const gadget = shown orelse continue;
                    _ = ib.SetGadgetAttrsTagList(gadget, window, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&field.text)), .{} });
                }
                if (values[soc]) |level| _ = ib.SetGadgetAttrsTagList(charge.?, window, &[_]TagItem{ pair(ar.ARC_Level, signedData(@divTrunc(level + 5, 10))), .{} });
                if (values[soh]) |level| _ = ib.SetGadgetAttrsTagList(health.?, window, &[_]TagItem{ pair(fg.GAUGE_Level, signedData(@divTrunc(level + 5, 10))), .{} });
                if (values[power]) |watts| {
                    _ = ib.SetGadgetAttrsTagList(meter.?, window, &[_]TagItem{ pair(mt.METER_Level, signedData(watts)), .{} });
                    _ = ib.SetGadgetAttrsTagList(plot.?, window, &[_]TagItem{ pair(cr.CHART_Add, signedData(watts)), .{} });
                }
                setStatus(&status, "Read ", rounds, " times, unit ", unit);
            } else {
                setStatus(&status, "Not read: ", null, modbus_base.ModbusErrorText(result), null);
            }
            _ = ib.SetGadgetAttrsTagList(status_line.?, window, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&status)), .{} });
        }
        const got = ib.WaitIMsg(window, tick_mask | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_OK;
        if (got & tick_mask != 0) due = true;
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            if (word & wc.WMHI_CLASSMASK == wc.WMHI_CLOSEWINDOW) return dos.RETURN_OK;
        }
    }
}

/// The status line: words, a number, words, a number - each part there
/// or not.
fn setStatus(into: *[80:0]u8, first: []const u8, number: ?u32, second: [*:0]const u8, last: ?u32) void {
    var at: usize = 0;
    const room = into.len;
    for (first) |c| {
        if (at == room) break;
        into[at] = c;
        at += 1;
    }
    if (number) |value| at = putNumber(into, at, value);
    var i: usize = 0;
    while (second[i] != 0 and at < room) : (i += 1) {
        into[at] = second[i];
        at += 1;
    }
    if (last) |value| at = putNumber(into, at, value);
    into[at] = 0;
}

fn putNumber(into: *[80:0]u8, start: usize, value: u32) usize {
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var left = value;
    while (true) {
        digits[count] = @intCast('0' + left % 10);
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    var at = start;
    while (count > 0 and at < into.len) {
        count -= 1;
        into[at] = digits[count];
        at += 1;
    }
    return at;
}
