// SPDX-License-Identifier: MPL-2.0
//! expander.resource: the board's IO expander, an I2C part at address 0x24.
//!
//! It carries the pins the panel, the touch controller and the SD card are
//! held by, the backlight, and an analogue input. One piece of hardware,
//! shared by drivers that know nothing of each other - so one owner keeps
//! the shadow of what has been written, and a pin change is a
//! read-modify-write of that shadow under a semaphore. Two drivers cannot
//! then undo each other's pins, which is what would happen if each did its
//! own I2C.
//!
//! The part is a register file:
//!
//!   02  pin mode, a bit per pin: 1 drives, 0 listens
//!   03  pin output, a bit per pin
//!   04  pin input, a bit per pin
//!   05  backlight, 0 to 255 - **inverted**, 0 is full brightness
//!   06  analogue input, two bytes, high byte first
//!
//! A write is the register number and the value in one transfer. A read
//! writes the register number and then reads without letting go of the bus,
//! which is one `I2CCMD_WRITEREAD` request.
//!
//! Every exchange is two or three bytes, so i2c.device serves them inside
//! BeginIO without queueing or scheduling anything: setting a pin costs a
//! semaphore, a byte of arithmetic and about seventy microseconds of bus.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const i2c = sdk.devices.i2c;
const types = sdk.resources.expander;
const ExecBase = sdk.interface.exec.ExecBase;

pub const RESOURCE_NAME = types.EXPANDERNAME;
const RESOURCE_VERSION = 1;
const RESOURCE_REVISION = 0;
const BUILD_DATE = "17.9.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const expansion = sdk.expansion;
const st = expansion.systemtags;

// The registers.
const reg_mode: u8 = 0x02;
const reg_output: u8 = 0x03;
const reg_input: u8 = 0x04;
const reg_backlight: u8 = 0x05;
const reg_adc: u8 = 0x06;

/// The backlight register counts downwards: 0 is full brightness and 255
/// is dark.
const backlight_dark: u32 = 255;

const vec = exec.libraries.vec;

const ExpanderBase = extern struct {
    lib: exec.Library,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// One transfer at a time, and one owner of the shadows.
    lock: exec.SignalSemaphore,
    /// The request every exchange goes through, and its reply port.
    port: exec.MsgPort,
    io: i2c.IOExtI2C,
    /// i2c.device is open and the part answered.
    ready: u8 = 0,
    /// What was last written to the mode and output registers. The part
    /// gives no way to read the mode back, and reading the output costs a
    /// bus exchange, so both are kept here.
    mode: u8 = 0,
    output: u8 = 0,
    /// What SetBacklight was last given, as a percentage.
    backlight: u8 = 0,
    /// A bit per claimed pin, and who holds it.
    claimed: u8 = 0,
    pad: u8 = 0,
    /// Where the part answers, and on which I2C unit: the board's
    /// expander part says.
    address: u16 = 0,
    unit: u32 = 0,
    owners: [types.PIN_COUNT]?[*:0]const u8,
};

fn expanderBase(lib: *exec.Library) *ExpanderBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

// --- the part -------------------------------------------------------------

/// The reply port belongs to whoever is calling: a resource is called from
/// any task, and a port signals the task that made it. Under the semaphore
/// this one is ours alone, so it is pointed at the caller for the length of
/// the exchange. Most exchanges are quick I/O and never reach it at all.
fn takePort(eb: *ExpanderBase) ?i8 {
    const sys = eb.sys_base;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return null;
    eb.port = .{
        .flags = exec.PA_SIGNAL,
        .sig_bit = @intCast(signal),
        .sig_task = sys.FindTask(null),
    };
    eb.port.msg_list.init(.message);
    return signal;
}

/// `value` into `reg`: the two bytes in one transfer.
fn writeReg(eb: *ExpanderBase, reg: u8, value: u8) bool {
    if (eb.ready == 0) return false;
    const sys = eb.sys_base;
    const bit = takePort(eb) orelse return false;
    defer sys.FreeSignal(bit);
    var bytes = [2]u8{ reg, value };
    eb.io.req.req.message.reply_port = &eb.port;
    eb.io.req.req.command = exec.CMD_WRITE;
    eb.io.req.req.flags = exec.IOF_QUICK;
    eb.io.req.req.err = 0;
    eb.io.address = eb.address;
    eb.io.req.data = &bytes;
    eb.io.req.length = bytes.len;
    _ = sys.DoIO(&eb.io.req.req);
    return eb.io.req.req.err == 0;
}

/// `count` bytes of `reg` into `into`: the register number written, then
/// read back without letting go of the bus.
fn readReg(eb: *ExpanderBase, reg: u8, into: [*]u8, count: u32) bool {
    if (eb.ready == 0) return false;
    const sys = eb.sys_base;
    const bit = takePort(eb) orelse return false;
    defer sys.FreeSignal(bit);
    var which = [1]u8{reg};
    eb.io.req.req.message.reply_port = &eb.port;
    eb.io.req.req.command = i2c.I2CCMD_WRITEREAD;
    eb.io.req.req.flags = exec.IOF_QUICK;
    eb.io.req.req.err = 0;
    eb.io.address = eb.address;
    eb.io.wr_data = &which;
    eb.io.wr_length = which.len;
    eb.io.req.data = into;
    eb.io.req.length = count;
    _ = sys.DoIO(&eb.io.req.req);
    return eb.io.req.req.err == 0 and eb.io.req.actual == count;
}

// --- the functions --------------------------------------------------------

fn lvoClaimPin(lib: *ExpanderBase, pin: u32, name: [*:0]const u8) callconv(.c) bool {
    if (pin >= types.PIN_COUNT) return false;
    const sys = lib.sys_base;
    sys.ObtainSemaphore(&lib.lock);
    defer sys.ReleaseSemaphore(&lib.lock);
    const bit = @as(u8, 1) << @intCast(pin);
    if (lib.claimed & bit != 0) return false;
    lib.claimed |= bit;
    lib.owners[pin] = name;
    return true;
}

fn lvoReleasePin(lib: *ExpanderBase, pin: u32) callconv(.c) void {
    if (pin >= types.PIN_COUNT) return;
    const sys = lib.sys_base;
    sys.ObtainSemaphore(&lib.lock);
    defer sys.ReleaseSemaphore(&lib.lock);
    lib.claimed &= ~(@as(u8, 1) << @intCast(pin));
    lib.owners[pin] = null;
}

fn lvoPinOwner(lib: *ExpanderBase, pin: u32) callconv(.c) ?[*:0]const u8 {
    if (pin >= types.PIN_COUNT) return null;
    return lib.owners[pin];
}

fn lvoSetPin(lib: *ExpanderBase, pin: u32, high: bool) callconv(.c) bool {
    if (pin >= types.PIN_COUNT) return false;
    const sys = lib.sys_base;
    sys.ObtainSemaphore(&lib.lock);
    defer sys.ReleaseSemaphore(&lib.lock);

    const bit = @as(u8, 1) << @intCast(pin);
    const output = if (high) lib.output | bit else lib.output & ~bit;
    // The level goes out before the direction does, so a pin that is about
    // to start driving never drives the wrong way first.
    if (output != lib.output) {
        if (!writeReg(lib, reg_output, output)) return false;
        lib.output = output;
    }
    if (lib.mode & bit == 0) {
        const mode = lib.mode | bit;
        if (!writeReg(lib, reg_mode, mode)) return false;
        lib.mode = mode;
    }
    return true;
}

fn lvoGetPin(lib: *ExpanderBase, pin: u32) callconv(.c) i32 {
    if (pin >= types.PIN_COUNT) return -1;
    const sys = lib.sys_base;
    sys.ObtainSemaphore(&lib.lock);
    defer sys.ReleaseSemaphore(&lib.lock);
    var value: [1]u8 = .{0};
    if (!readReg(lib, reg_input, &value, 1)) return -1;
    return @intCast((value[0] >> @intCast(pin)) & 1);
}

fn lvoSetBacklight(lib: *ExpanderBase, percent: u32) callconv(.c) bool {
    const sys = lib.sys_base;
    sys.ObtainSemaphore(&lib.lock);
    defer sys.ReleaseSemaphore(&lib.lock);
    const want = @min(percent, types.BACKLIGHT_FULL);
    // The register counts the other way: 0 is full brightness.
    const level: u8 = @intCast(backlight_dark - (want * backlight_dark) / types.BACKLIGHT_FULL);
    if (!writeReg(lib, reg_backlight, level)) return false;
    lib.backlight = @intCast(want);
    return true;
}

fn lvoBacklight(lib: *ExpanderBase) callconv(.c) u32 {
    return lib.backlight;
}

fn lvoReadADC(lib: *ExpanderBase) callconv(.c) i32 {
    const sys = lib.sys_base;
    sys.ObtainSemaphore(&lib.lock);
    defer sys.ReleaseSemaphore(&lib.lock);
    var value: [2]u8 = .{ 0, 0 };
    if (!readReg(lib, reg_adc, &value, 2)) return -1;
    return @as(i32, value[0]) << 8 | value[1];
}

// --- the resource ---------------------------------------------------------

/// i2c.device opened, and the part asked whether it is there. The pins are
/// left exactly as they are: what they hold is the business of the drivers
/// that claim them, and a resource that set them on the way past would
/// reset a panel or deselect a card that something else was using.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const eb = expanderBase(lib);
    lib.revision = RESOURCE_REVISION;
    eb.sys_base = sys_base;
    eb.owners = @splat(null);
    sys_base.InitSemaphore(&eb.lock);
    eb.port = .{ .flags = exec.PA_IGNORE };
    eb.port.msg_list.init(.message);
    eb.io = .{};
    eb.io.req.req.message.length = @sizeOf(i2c.IOExtI2C);

    if (!findPart(eb)) {
        sdk.exec.kprintf(sys_base, "%s: the board has no CH422G\n", .{RESOURCE_NAME});
        return lib;
    }
    if (sys_base.OpenDevice(i2c.DEVICE_NAME, eb.unit, &eb.io.req.req, 0) != 0) {
        sdk.exec.kprintf(sys_base, "%s: no %s unit %d\n", .{ RESOURCE_NAME, i2c.DEVICE_NAME, eb.unit });
        return lib;
    }
    eb.ready = 1;

    // The shadows start at what the part already holds, not at zero. The
    // pins are not idle when this runs - the board brings most of them up
    // high - so a shadow that began empty would make the first SetPin
    // write its own idea of all eight and pull the rest of them down with
    // it, which on the reset lines and the card's chip select is exactly
    // the accident this resource is here to prevent.
    var have: [1]u8 = .{0};
    if (!readReg(eb, reg_mode, &have, 1)) {
        sdk.exec.kprintf(sys_base, "%s: nothing answers at 0x%02x\n", .{ RESOURCE_NAME, @as(u32, eb.address) });
        eb.ready = 0;
        return lib;
    }
    eb.mode = have[0];
    if (readReg(eb, reg_output, &have, 1)) eb.output = have[0];
    if (readReg(eb, reg_backlight, &have, 1)) {
        // The register counts backwards, as SetBacklight's comment says.
        eb.backlight = @intCast((backlight_dark - have[0]) * types.BACKLIGHT_FULL / backlight_dark);
    }
    return lib;
}

/// The board's CH422G: where it answers and on which bus, into the base.
/// False if the board has none.
fn findPart(eb: *ExpanderBase) bool {
    const sys = eb.sys_base;
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return false;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return false;
    defer sys.CloseLibrary(expansion_lib);
    const xb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const part = xb.FindBoardPart(null, st.PARTKIND_EXPANDER, st.CHIP_CH422G) orelse return false;
    eb.address = @truncate(ub.GetTagData(st.PART_Address, 0, part.tags));
    eb.unit = @truncate(ub.GetTagData(st.PART_BusUnit, 0, part.tags));
    return true;
}

const vectors = [_]*const anyopaque{
    vec(lvoClaimPin),
    vec(lvoReleasePin),
    vec(lvoPinOwner),
    vec(lvoSetPin),
    vec(lvoGetPin),
    vec(lvoSetBacklight),
    vec(lvoBacklight),
    vec(lvoReadADC),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(ExpanderBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// Cold start below i2c.device (35), which it opens, and above dos
/// (-128), so a handler or a driver that wants a pin finds it already
/// there.
export const expander_resource_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &expander_resource_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = 30,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
