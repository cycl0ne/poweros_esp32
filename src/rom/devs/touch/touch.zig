// SPDX-License-Identifier: MPL-2.0
//! touch.device: the board's touch panel on I2C, as contacts.
//!
//! Which controller that is the board says, through expansion.library:
//! its touch part names the chip - a GT911 of its own, or the ST7123 built
//! into the panel - and says which I2C unit and address it answers at,
//! where its interrupt and reset lines are (a reset on the IO expander or
//! on a pad) and how the screen is turned from its glass. The chips differ
//! in their registers and in what they report; everything from the report
//! on is the same, and is `_touch.zig`.
//!
//! Nothing is touched until the first OpenDevice, so a board that never
//! uses the panel keeps its pins. The first open starts the device's task,
//! and the task brings the controller up:
//!
//!   1. i2c.device unit 0 and timer.device opened, and expander.resource
//!      for a board whose reset line is one of its pins;
//!   2. the controller reset - a GT911 with its interrupt line held low,
//!      which makes it answer at 0x5D;
//!   3. what it is and how large its panel is, read from it;
//!   4. the interrupt line's GPIO interrupt armed, with a server on
//!      INTB_GPIO.
//!
//! The open waits for that and fails if the controller did not answer.
//! From then on every report the controller makes raises the interrupt;
//! the server clears it and signals the task, and the task reads the
//! contacts over I2C - which an interrupt cannot do - turns the change
//! into events, and hands them to whatever reads are waiting.
//!
//! The device stays up once it is: the task, the interrupt server and the
//! claimed pin are the machine's for good, as i2c.device keeps its units.
//! A read waiting for an event is queued on the unit, so AbortIO and
//! CMD_FLUSH can take it back.
//!
//! The emulator has no panel, so there an open fails: its window's pointer
//! is a mouse, and mouse.device reports it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const touch = sdk.devices.touch;
const i2c = sdk.devices.i2c;
const timer = sdk.devices.timer;
const expander = sdk.resources.expander;
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;
const intbits = sdk.hardware.intbits;
const ExecBase = sdk.interface.exec.ExecBase;
const ExpanderBase = sdk.interface.expander.ExpanderBase;
const TimerBase = timer.TimerBase;
const _touch = @import("_touch.zig");
const gt911 = @import("gt911.zig");
const st7123 = @import("st7123.zig");
const gpio = @import("sdk").hardware.gpio;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const BoardPin = expansion.BoardPin;

pub const DEVICE_NAME = touch.TOUCHNAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "19.9.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// Above ordinary tasks, so a finger is followed while a program computes.
const task_pri = 10;
const stack_size = 4096;
/// Which controller the board has: its touch part's chip. A GT911 of its
/// own, or the ST7123 built into the panel.
const Controller = enum(u8) { none, gt911, panel };
/// A GT911 answers at one address when its interrupt line was low as it
/// came out of reset, and at another when it was high.
const address_high: u16 = 0x14;
/// Interrupts with no read of the controller in between, past which the
/// line is taken to be stuck and turned off.
const storm_limit = 1000;
/// How often the task looks at the panel's own controller of its own
/// accord, in microseconds: its interrupt line does not reach the chip
/// on the board that has it, and this is fast enough for a finger. A
/// GT911's line does, and it is left to the interrupt.
/// What a look costs while nobody is touching the panel: the report and
/// the first slot, in one read of eight bytes. The slots past the first
/// are read only while a finger is in the first, so an idle panel is two
/// transfers every `poll_ticks` and no more.
const panel_poll_us: u32 = 10_000;

const TouchBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    /// What the board's touch part says, read at init: which controller,
    /// on which I2C unit and at which address, its interrupt pad, its
    /// reset line, and how the screen is turned from its glass.
    controller: Controller = .none,
    int_pin: u8 = 0,
    part_address: u16 = 0,
    bus_unit: u32 = 0,
    reset: BoardPin = .{},
    turn: _touch.Turn = .none,
    pad5: [3]u8 = .{ 0, 0, 0 },
    /// `panel_poll_us`, or 0 to leave it to the interrupt.
    poll_ticks: u32 = 0,
    /// The pads taken from gpio.resource while the device runs: the
    /// interrupt line, and the reset when it is a pad of the chip.
    gpio_base: ?*GpioBase = null,
    held_pads: [2]u8 = .{ 0, 0 },
    held_count: u8 = 0,
    pad6: [1]u8 = .{0},
    /// Reads waiting for an event are on its port's list.
    unit: exec.Unit,
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    int: exec.Interrupt = .{},
    /// The task is running and the controller answered.
    ready: u8 = 0,
    /// The task has been started.
    started: u8 = 0,
    start_signal: i8 = -1,
    pad: u8 = 0,
    starter: ?*exec.Task = null,
    /// The task's signal the interrupt server raises, and the one the
    /// tick that looks anyway comes back on.
    int_mask: u32 = 0,
    tick_mask: u32 = 0,
    tick_port: ?*exec.MsgPort = null,
    tick_io: timer.TimeRequest = .{},
    ticking: u8 = 0,
    pad4: [3]u8 = .{ 0, 0, 0 },
    /// Interrupts since the task last read the controller. A line that
    /// keeps firing without the task ever getting to run would hold the
    /// machine; past `storm_limit` the server turns it off instead.
    unanswered: u32 = 0,
    storm: u32 = 0,
    /// Owned by the task.
    port: ?*exec.MsgPort = null,
    i2c_io: i2c.IOExtI2C = .{},
    timer_io: timer.TimeRequest = .{},
    exp: ?*ExpanderBase = null,
    address: u16 = 0,
    pad2: u16 = 0,
    /// Set when the controller would not answer a register read with a
    /// repeated start in it, and is read in two transfers instead.
    two_step: u8 = 0,
    pad3: [3]u8 = .{ 0, 0, 0 },
    /// How many fingers the controller follows, and how large its own
    /// glass is - which is the screen's size with the two exchanged when
    /// the screen is turned from it.
    max_touches: u32 = touch.TOUCH_MAX_CONTACTS,
    glass_width: u32 = 0,
    glass_height: u32 = 0,
    /// Events not yet read, and where every finger is.
    queue: _touch.Queue = .{},
    state: touch.TouchState = .{},
    info: touch.TouchInfo = .{},
};

fn touchBase(dev: *exec.Device) *TouchBase {
    return @alignCast(@fieldParentPtr("dev", dev));
}

fn baseOf(io: *exec.IORequest) *TouchBase {
    return touchBase(io.device.?);
}

fn stdReq(io: *exec.IORequest) *exec.IOStdReq {
    return @ptrCast(@alignCast(io));
}

// --- the controller ------------------------------------------------------------------

fn wait(tb: *TouchBase, us: u32) void {
    const sys = tb.sys_base;
    tb.timer_io.node.command = timer.TR_ADDREQUEST;
    tb.timer_io.time = timer.TimeVal.fromMicros(us);
    _ = sys.DoIO(&tb.timer_io.node);
}

/// `count` bytes of the register at `register` into `into`, in one
/// transfer: the register number and the read with a repeated start
/// between them, so nothing else on the bus can come in between.
///
/// A controller that will not have that is read in two transfers instead
/// (`tb.two_step`), which bring-up finds out once and remembers.
fn readReg(tb: *TouchBase, register: u16, into: [*]u8, count: u32) bool {
    var at = _touch.address(register);
    const io = &tb.i2c_io;
    const sys = tb.sys_base;
    if (tb.two_step != 0) {
        io.req.req.command = exec.CMD_WRITE;
        io.req.req.flags = exec.IOF_QUICK;
        io.address = tb.address;
        io.req.data = &at;
        io.req.length = at.len;
        _ = sys.DoIO(&io.req.req);
        if (io.req.req.err != 0) return false;
        io.req.req.command = exec.CMD_READ;
        io.req.req.flags = exec.IOF_QUICK;
        io.req.data = into;
        io.req.length = count;
        _ = sys.DoIO(&io.req.req);
        return io.req.req.err == 0 and io.req.actual == count;
    }
    io.req.req.command = i2c.I2CCMD_WRITEREAD;
    io.req.req.flags = exec.IOF_QUICK;
    io.address = tb.address;
    io.wr_data = &at;
    io.wr_length = at.len;
    io.req.data = into;
    io.req.length = count;
    _ = sys.DoIO(&io.req.req);
    return io.req.req.err == 0 and io.req.actual == count;
}

fn writeReg(tb: *TouchBase, register: u16, value: u8) bool {
    const at = _touch.address(register);
    var bytes = [3]u8{ at[0], at[1], value };
    const io = &tb.i2c_io;
    io.req.req.command = exec.CMD_WRITE;
    io.req.req.flags = exec.IOF_QUICK;
    io.address = tb.address;
    io.req.data = &bytes;
    io.req.length = bytes.len;
    _ = tb.sys_base.DoIO(&io.req.req);
    return io.req.req.err == 0;
}

fn now(tb: *TouchBase) timer.TimeVal {
    var t: timer.TimeVal = .{};
    const tmb: *TimerBase = @ptrCast(tb.timer_io.node.device.?);
    tmb.GetSysTime(&t);
    return t;
}

/// The interrupt: whether it is this pin's, and if so the task told.
fn intServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const tb: *TouchBase = @ptrCast(@alignCast(is_data.?));
    const pin = tb.int_pin;
    if (!gpio.interruptPending(pin)) return 0;
    gpio.interruptClear(pin);
    tb.unanswered += 1;
    if (tb.unanswered > storm_limit) {
        gpio.interruptOff(pin);
        tb.storm = 1;
    }
    tb.sys_base.Signal(&tb.task, tb.int_mask);
    return 1;
}

/// The controller out of reset at 0x5D, and what it is.
/// Where bring-up has got to, on UART0: a controller that does not come
/// up leaves its last step there.
fn step(tb: *TouchBase, what: [*:0]const u8) void {
    sdk.exec.kprintf(tb.sys_base, "%s: %s\n", .{ DEVICE_NAME, what });
}

fn bringUp(tb: *TouchBase) bool {
    const sys = tb.sys_base;
    const pin = tb.int_pin;
    if (tb.controller == .none) {
        sdk.exec.kprintf(sys, "%s: the board has no touch panel\n", .{DEVICE_NAME});
        return false;
    }
    step(tb, "starting");
    if (!takePads(tb)) return false;

    tb.port = sys.CreateMsgPort() orelse return false;
    tb.i2c_io = .{};
    tb.i2c_io.req.req.message.reply_port = tb.port;
    tb.i2c_io.req.req.message.length = @sizeOf(i2c.IOExtI2C);
    if (sys.OpenDevice(i2c.DEVICE_NAME, tb.bus_unit, &tb.i2c_io.req.req, 0) != 0) {
        sdk.exec.kprintf(sys, "%s: no %s unit %d\n", .{ DEVICE_NAME, i2c.DEVICE_NAME, tb.bus_unit });
        return false;
    }
    step(tb, "i2c.device open");
    tb.timer_io = .{};
    tb.timer_io.node.message.reply_port = tb.port;
    tb.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &tb.timer_io.node, 0) != 0) return false;
    step(tb, "timer.device open");
    const trigger = switch (tb.controller) {
        .gt911 => bringUpGt911(tb) orelse return false,
        .panel => bringUpPanel(tb) orelse return false,
        .none => return false,
    };

    sys.AddIntServer(intbits.INTB_GPIO, &tb.int);
    gpio.interruptClear(pin);
    gpio.interruptOn(pin, trigger);
    return true;
}

/// The part's pads taken from gpio.resource: its interrupt line, and its
/// reset when that is a pad of the chip. False if another driver holds
/// one; a machine without the resource takes nothing.
fn takePads(tb: *TouchBase) bool {
    const sys = tb.sys_base;
    const gb: *GpioBase = @ptrCast(@alignCast(sys.OpenResource(gpio_resource.GPIONAME) orelse return true));
    var wanted: [2]u8 = .{ tb.int_pin, 0 };
    var count: u8 = 1;
    if (tb.reset.kind == expansion.boardpin.BPIN_GPIO) {
        wanted[1] = tb.reset.number;
        count = 2;
    }
    if (gpio_resource.allocPads(gb, wanted[0..count], DEVICE_NAME)) |refused| {
        sdk.exec.kprintf(sys, "%s: GPIO%d is %s's\n", .{ DEVICE_NAME, refused.pad, refused.holder });
        return false;
    }
    tb.gpio_base = gb;
    tb.held_pads = wanted;
    tb.held_count = count;
    return true;
}

/// The reset line taken for this device: a pin of the expander is claimed
/// from expander.resource, a pad of the chip made an output. False if the
/// line is someone else's, or the board wired it where this cannot reach.
fn takeReset(tb: *TouchBase) bool {
    const sys = tb.sys_base;
    switch (tb.reset.kind) {
        expansion.boardpin.BPIN_EXPANDER => {
            const exp: *ExpanderBase = @ptrCast(@alignCast(sys.OpenResource(expander.EXPANDERNAME) orelse return false));
            if (!exp.ClaimPin(tb.reset.number, DEVICE_NAME)) {
                sdk.exec.kprintf(sys, "%s: the touch reset pin is taken\n", .{DEVICE_NAME});
                return false;
            }
            tb.exp = exp;
        },
        expansion.boardpin.BPIN_GPIO => {
            const reset = tb.reset.number;
            gpio.toMatrix(reset);
            gpio.connectOut(reset, gpio.out_of_gpio, true);
            gpio.setLevel(reset, true);
            gpio.outputEnable(reset, true);
        },
        else => return false,
    }
    return true;
}

/// The reset line driven high or low, wherever it is.
fn setReset(tb: *TouchBase, high: bool) void {
    switch (tb.reset.kind) {
        expansion.boardpin.BPIN_EXPANDER => if (tb.exp) |exp| {
            _ = exp.SetPin(tb.reset.number, high);
        },
        expansion.boardpin.BPIN_GPIO => gpio.setLevel(tb.reset.number, high),
        else => {},
    }
}

/// A GT911: reset with the interrupt line held low, then what it is and
/// how its line signals. Null if it never answered.
fn bringUpGt911(tb: *TouchBase) ?gpio.Trigger {
    const sys = tb.sys_base;
    const pin = tb.int_pin;
    if (!takeReset(tb)) return null;
    step(tb, "reset pin claimed");

    // Reset with the interrupt line low: the controller reads the line as
    // it comes out of reset and answers at 0x5D for low.
    gpio.toMatrix(pin);
    gpio.connectOut(pin, gpio.out_of_gpio, true);
    gpio.setLevel(pin, false);
    gpio.outputEnable(pin, true);
    step(tb, "reset low");
    setReset(tb, false);
    step(tb, "waiting 10 ms");
    wait(tb, 10_000);
    step(tb, "reset high");
    setReset(tb, true);
    wait(tb, 10_000);
    // Then the line is the controller's to drive.
    gpio.outputEnable(pin, false);
    gpio.inputEnable(pin, true);
    wait(tb, 60_000);
    step(tb, "reading the product id");

    var id: [10]u8 = undefined;
    tb.address = tb.part_address;
    if (!readReg(tb, gt911.reg_product_id, &id, id.len)) {
        // The line may not have been where the reset expected it.
        tb.address = address_high;
        if (!readReg(tb, gt911.reg_product_id, &id, id.len)) {
            sdk.exec.kprintf(sys, "%s: nothing answers at 0x%02x or 0x%02x\n", .{ DEVICE_NAME, @as(u32, tb.part_address), @as(u32, address_high) });
            return null;
        }
    }
    const who = gt911.identity(&id);
    tb.glass_width = who.width;
    tb.glass_height = who.height;
    tb.info = .{
        .size = @sizeOf(touch.TouchInfo),
        .max_contacts = touch.TOUCH_MAX_CONTACTS,
        .width = who.width,
        .height = who.height,
        .product = who.product,
        .firmware = who.firmware,
        .address = tb.address,
    };

    // How the line signals, from the controller's own configuration - but
    // always as an edge. A level stays until the controller's status is
    // cleared, which only the task can do, and the task cannot run while
    // the interrupt keeps coming back: a level trigger here stops the
    // machine. The edge that starts the level is the same event.
    var switch1: [1]u8 = .{0x01};
    _ = readReg(tb, gt911.reg_module_switch1, &switch1, 1);
    const falling = switch (switch1[0] & 0x03) {
        0, 3 => false, // rising, or a high level
        else => true, // falling, or a low level
    };
    const trigger: gpio.Trigger = if (falling) .falling else .rising;
    const product: [*:0]const u8 = @ptrCast(&tb.info.product);
    sdk.exec.kprintf(sys, "%s: GT%s at 0x%02x, %dx%d, firmware %04x, GPIO %d %s edge (config %02x)\n", .{
        DEVICE_NAME,          product,
        @as(u32, tb.address), tb.info.width,
        tb.info.height,       tb.info.firmware,
        @as(u32, pin),        if (falling) @as([*:0]const u8, "falling") else @as([*:0]const u8, "rising"),
        @as(u32, switch1[0]),
    });

    // Anything it had to say before now is dropped.
    _ = writeReg(tb, gt911.reg_status, 0);
    return trigger;
}

/// The panel's own controller: it answers at one address, and says how
/// many fingers it follows and how large its panel is; there is no product
/// id to ask for. Its interrupt line goes low while it has something to
/// report, so the edge is the falling one. Null if it never answered.
fn bringUpPanel(tb: *TouchBase) ?gpio.Trigger {
    const sys = tb.sys_base;
    const pin = tb.int_pin;

    if (!takeReset(tb)) return null;
    wait(tb, st7123.reset_ms * 1000);
    step(tb, "reset low");
    setReset(tb, false);
    wait(tb, st7123.reset_ms * 1000);
    step(tb, "reset high");
    setReset(tb, true);
    wait(tb, st7123.settle_ms * 1000);

    // The line is the controller's to pull down and nothing's to pull up,
    // so the pad's own resistor holds it high between reports; without it
    // the line floats and no edge is ever clean.
    gpio.toMatrix(pin);
    gpio.inputEnable(pin, true);
    gpio.pullUp(pin, true);
    step(tb, "reading the status");

    tb.address = tb.part_address;
    var status: [1]u8 = .{st7123.status_starting};
    var tries: u32 = 0;
    while (tries < 10) : (tries += 1) {
        if (readReg(tb, st7123.reg_status, &status, 1) and st7123.ready(status[0])) break;
        // Half of the tries with the repeated start, half without: a
        // controller that answers only one of the two is found either way.
        if (tries == 4) {
            tb.two_step = 1;
            step(tb, "reading in two transfers");
        }
        wait(tb, 10_000);
    } else {
        sdk.exec.kprintf(sys, "%s: nothing ready at 0x%02x (status %02x)\n", .{
            DEVICE_NAME,         @as(u32, tb.part_address),
            @as(u32, status[0]),
        });
        return null;
    }

    var most: [1]u8 = .{touch.TOUCH_MAX_CONTACTS};
    _ = readReg(tb, st7123.reg_max_touches, &most, 1);
    tb.max_touches = @min(@as(u32, most[0]), touch.TOUCH_MAX_CONTACTS);
    if (tb.max_touches == 0) tb.max_touches = 1;
    var size: [4]u8 = .{ 0, 0, 0, 0 };
    _ = readReg(tb, st7123.reg_range, &size, size.len);
    const panel = st7123.range(&size);
    tb.glass_width = panel.width;
    tb.glass_height = panel.height;
    tb.info = .{
        .size = @sizeOf(touch.TouchInfo),
        .max_contacts = tb.max_touches,
        // What a program is told is the screen's size, which is the
        // glass's the other way round when the screen is turned from it.
        .width = if (tb.turn == .none) panel.width else panel.height,
        .height = if (tb.turn == .none) panel.height else panel.width,
        .address = tb.address,
    };
    sdk.exec.kprintf(sys, "%s: the panel's own at 0x%02x, %dx%d, %d fingers, GPIO %d falling edge\n", .{
        DEVICE_NAME,    @as(u32, tb.address),
        tb.info.width,  tb.info.height,
        tb.max_touches, @as(u32, pin),
    });
    return .falling;
}

/// The port the tick comes back on, and the signal it raises. Its own
/// port, so a tick waiting does not sit among the replies the bring-up
/// waits for.
fn startTicks(tb: *TouchBase) bool {
    const sys = tb.sys_base;
    const port = sys.CreateMsgPort() orelse return false;
    tb.tick_port = port;
    tb.tick_mask = @as(u32, 1) << @intCast(port.sig_bit);
    return true;
}

fn giveBack(tb: *TouchBase) void {
    const sys = tb.sys_base;
    if (tb.ticking != 0) {
        _ = sys.AbortIO(&tb.tick_io.node);
        _ = sys.WaitIO(&tb.tick_io.node);
        tb.ticking = 0;
    }
    if (tb.tick_port) |port| sys.DeleteMsgPort(port);
    tb.tick_port = null;
    if (tb.exp) |exp| exp.ReleasePin(tb.reset.number);
    tb.exp = null;
    if (tb.gpio_base) |gb| gpio_resource.freePads(gb, tb.held_pads[0..tb.held_count]);
    tb.gpio_base = null;
    tb.held_count = 0;
    if (tb.timer_io.node.device != null) sys.CloseDevice(&tb.timer_io.node);
    if (tb.i2c_io.req.req.device != null) sys.CloseDevice(&tb.i2c_io.req.req);
    sys.DeleteMsgPort(tb.port);
    tb.port = null;
}

/// Reads that were waiting, given what is queued now. Under Forbid.
fn serveReads(tb: *TouchBase) void {
    const sys = tb.sys_base;
    const list = &tb.unit.msg_port.msg_list;
    while (tb.queue.count > 0) {
        const node = list.head orelse break;
        if (node.succ == null) break;
        const io: *exec.IORequest = @ptrCast(@alignCast(node));
        sys.Remove(node);
        io.flags &= ~exec.IOF_QUEUED;
        const std_io = stdReq(io);
        const room = std_io.length / @sizeOf(touch.TouchEvent);
        const into: [*]touch.TouchEvent = @ptrCast(@alignCast(std_io.data.?));
        const n = tb.queue.take(into[0..@intCast(room)]);
        std_io.actual = n * @sizeOf(touch.TouchEvent);
        sys.ReplyIO(io);
    }
}

/// One report from the controller, as events.
fn poll(tb: *TouchBase) void {
    const sys = tb.sys_base;
    // Whatever woke the task, the tick that was out is taken back so the
    // next one can be armed.
    if (tb.ticking != 0 and sys.CheckIO(&tb.tick_io.node) != null) {
        _ = sys.WaitIO(&tb.tick_io.node);
        tb.ticking = 0;
    }
    tb.unanswered = 0;
    if (tb.storm != 0) {
        tb.storm = 2;
        sdk.exec.kprintf(tb.sys_base, "%s: the interrupt would not stop; GPIO %d turned off\n", .{ DEVICE_NAME, @as(u32, tb.int_pin) });
    }
    if (tb.storm == 2) return;
    var contacts: [touch.TOUCH_MAX_CONTACTS]touch.TouchContact = undefined;
    const n = switch (tb.controller) {
        .gt911 => pollGt911(tb, &contacts),
        .panel => pollPanel(tb, &contacts),
        .none => null,
    } orelse return;
    // Where the fingers are on the screen, which is where a program draws.
    if (tb.turn != .none) {
        for (contacts[0..n]) |*c| c.* = _touch.turned(c.*, tb.turn, tb.glass_width, tb.glass_height);
    }
    report(tb, contacts[0..n]);
}

/// A GT911 says in its status that a report is ready and how many contacts
/// it holds; reading them is not enough, the status has to go back to 0 or
/// it stops reporting.
fn pollGt911(tb: *TouchBase, into: []touch.TouchContact) ?usize {
    var status: [1]u8 = .{0};
    if (!readReg(tb, gt911.reg_status, &status, 1)) return null;
    const count = gt911.reported(status[0]) orelse return null;
    var bytes: [touch.TOUCH_MAX_CONTACTS * gt911.point_size]u8 = undefined;
    const length: u32 = @intCast(count * gt911.point_size);
    if (count > 0 and !readReg(tb, gt911.reg_points, &bytes, length)) return null;
    _ = writeReg(tb, gt911.reg_status, 0);
    return gt911.decode(bytes[0..length], count, into);
}

/// The panel's own controller keeps a finger a slot and has nothing to
/// write back. The slots are read one at a time: all of them at once is a
/// transfer longer than i2c.device finishes while its caller spins, and
/// this way every read is a short one.
fn pollPanel(tb: *TouchBase, into: []touch.TouchContact) ?usize {
    // The whole report in one read, which is how the controller means it
    // to be read: it makes the report up as the read reaches its first
    // byte, so a read that starts at a slot sees what was there before.
    var bytes: [st7123.reportBytes(st7123.max_slots)]u8 = undefined;
    const length: u32 = @intCast(st7123.reportBytes(tb.max_touches));
    if (!readReg(tb, st7123.reg_touch_info, &bytes, length)) return null;
    return st7123.decode(bytes[0..length], into);
}

/// Where every finger is now, as events against where they were, handed to
/// any read that waits.
fn report(tb: *TouchBase, contacts: []const touch.TouchContact) void {
    const n = contacts.len;
    var events: [2 * touch.TOUCH_MAX_CONTACTS]touch.TouchEvent = undefined;
    const time = now(tb);

    const sys = tb.sys_base;
    sys.Forbid();
    defer sys.Permit();
    const old = tb.state.contacts[0..tb.state.count];
    const changed = _touch.diff(old, contacts, &events);
    for (events[0..changed]) |*e| {
        e.time = time;
        tb.queue.push(e.*);
    }
    tb.state.count = @intCast(n);
    for (0..n) |i| tb.state.contacts[i] = contacts[i];
    tb.state.time = time;
    serveReads(tb);
}

fn touchTask(sys: *ExecBase) callconv(.c) void {
    const tb: *TouchBase = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    const signal = sys.AllocSignal(-1);
    const ok = signal >= 0 and bringUp(tb) and (tb.poll_ticks == 0 or startTicks(tb));
    if (ok) {
        tb.int_mask = @as(u32, 1) << @intCast(signal);
        tb.ready = 1;
    } else {
        giveBack(tb);
    }
    if (tb.starter) |starter| {
        tb.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(tb.start_signal));
    }
    if (!ok) return;

    // The interrupt line says when there is something to read. A
    // controller whose line this board does not bring out - or does not
    // drive - would then never be read at all, so the task also wakes on
    // its own every `poll_ticks` and looks. A report that the interrupt
    // brought is read at once; one it did not is read within a tick.
    while (true) {
        if (tb.poll_ticks != 0) armTick(tb);
        _ = sys.Wait(tb.int_mask | tb.tick_mask);
        poll(tb);
    }
}

/// The next look at the controller, `poll_ticks` from now. A request
/// already out is left to finish.
fn armTick(tb: *TouchBase) void {
    if (tb.ticking != 0) return;
    const sys = tb.sys_base;
    tb.tick_io = tb.timer_io;
    tb.tick_io.node.message.reply_port = tb.tick_port;
    tb.tick_io.node.command = timer.TR_ADDREQUEST;
    tb.tick_io.time = timer.TimeVal.fromMicros(tb.poll_ticks);
    tb.ticking = 1;
    sys.SendIO(&tb.tick_io.node);
}

/// The task started and waited for; true if the controller answered.
fn start(tb: *TouchBase) bool {
    const sys = tb.sys_base;
    if (tb.started != 0) return tb.ready != 0;
    const stack = tb.stack orelse blk: {
        const s = sys.AllocMem(stack_size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
        tb.stack = s;
        break :blk s;
    };
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return false;
    defer sys.FreeSignal(signal);
    tb.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    tb.starter = sys.FindTask(null);
    tb.start_signal = signal;
    tb.ready = 0;
    _ = sys.AddTask(&tb.task, &touchTask, null);
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    // A task whose controller did not answer has ended; the next open tries
    // again.
    if (tb.ready != 0) tb.started = 1;
    return tb.ready != 0;
}

// --- the device --------------------------------------------------------------------

fn readEvent(tb: *TouchBase, io: *exec.IORequest) bool {
    const std_io = stdReq(io);
    const each = @sizeOf(touch.TouchEvent);
    if (std_io.length == 0 or std_io.length % each != 0) {
        io.err = exec.IOERR_BADLENGTH;
        return true;
    }
    if (std_io.data == null) {
        io.err = exec.IOERR_BADADDRESS;
        return true;
    }
    const sys = tb.sys_base;
    sys.Forbid();
    defer sys.Permit();
    if (tb.queue.count > 0) {
        const into: [*]touch.TouchEvent = @ptrCast(@alignCast(std_io.data.?));
        const n = tb.queue.take(into[0..@intCast(std_io.length / each)]);
        std_io.actual = n * each;
        return true;
    }
    // Nothing yet: it waits on the unit for the next report.
    io.flags &= ~exec.IOF_QUICK;
    io.flags |= exec.IOF_QUEUED;
    // A queued request is a message again, as PutMsg would make it:
    // WaitIO looks at the node's type, and the reply left there by its
    // last use would let a caller past before this one has run.
    io.message.node.type = .message;
    sys.AddTail(&tb.unit.msg_port.msg_list, &io.message.node);
    return false;
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const tb = touchBase(dev);
    const sys = tb.sys_base;
    const std_io = stdReq(io);
    io.err = 0;
    std_io.actual = 0;
    switch (io.command) {
        touch.TOUCH_READEVENT => if (!readEvent(tb, io)) return,
        touch.TOUCH_READSTATE => {
            if (std_io.data == null) {
                io.err = exec.IOERR_BADADDRESS;
            } else if (std_io.length < @sizeOf(touch.TouchState)) {
                io.err = exec.IOERR_BADLENGTH;
            } else {
                sys.Forbid();
                @as(*touch.TouchState, @ptrCast(@alignCast(std_io.data.?))).* = tb.state;
                sys.Permit();
                std_io.actual = @sizeOf(touch.TouchState);
            }
        },
        touch.TOUCH_GETINFO => {
            if (std_io.data == null) {
                io.err = exec.IOERR_BADADDRESS;
            } else {
                const n: usize = @min(@as(usize, @intCast(std_io.length)), @sizeOf(touch.TouchInfo));
                const from: [*]const u8 = @ptrCast(&tb.info);
                const to: [*]u8 = @ptrCast(std_io.data.?);
                for (0..n) |i| to[i] = from[i];
                std_io.actual = n;
            }
        },
        exec.CMD_CLEAR => {
            sys.Forbid();
            tb.queue.clear();
            sys.Permit();
        },
        exec.CMD_FLUSH => flush(tb),
        else => io.err = exec.IOERR_NOCMD,
    }
    sys.ReplyIO(io);
}

/// Every waiting read back, aborted.
fn flush(tb: *TouchBase) void {
    const sys = tb.sys_base;
    sys.Forbid();
    defer sys.Permit();
    const list = &tb.unit.msg_port.msg_list;
    while (list.head) |node| {
        if (node.succ == null) break;
        const io: *exec.IORequest = @ptrCast(@alignCast(node));
        sys.Remove(node);
        io.flags &= ~exec.IOF_QUEUED;
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
    }
}

fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const tb = touchBase(dev);
    const sys = tb.sys_base;
    sys.Forbid();
    defer sys.Permit();
    if (io.flags & exec.IOF_QUEUED == 0) return -1;
    sys.Remove(&io.message.node);
    io.flags &= ~exec.IOF_QUEUED;
    io.err = exec.IOERR_ABORTED;
    sys.ReplyIO(io);
    return 0;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const tb = touchBase(dev);
    if (unit_number != 0) return exec.IOERR_OPENFAIL;
    if (io.message.length < @sizeOf(exec.IOStdReq)) return exec.IOERR_OPENFAIL;
    if (!start(tb)) return exec.IOERR_OPENFAIL;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    tb.unit.open_cnt += 1;
    io.unit = &tb.unit;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const tb = touchBase(dev);
    _ = abortIO(dev, io);
    tb.unit.open_cnt -= 1;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: its task, its interrupt server and the reset pin are
/// the machine's once it has come up.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

/// The unit and the interrupt server, ready. Nothing on the board is
/// touched here: that waits for the first open.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    _ = seg_list;
    dev.revision = DEVICE_REVISION;
    const tb = touchBase(dev);
    tb.sys_base = sys_base;
    tb.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    tb.unit.msg_port.msg_list.init(.message);
    tb.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = DEVICE_NAME },
        .data = tb,
        .code = &intServer,
    };
    tb.queue = .{};
    tb.state = .{};
    tb.info = .{};
    findPanel(tb);
    return dev;
}

/// The board's touch part, read into the base: which controller, where it
/// is and how its lines are wired. A board without one, or with a chip
/// this device does not drive, leaves `controller` at none, and every open
/// fails.
fn findPanel(tb: *TouchBase) void {
    const sys = tb.sys_base;
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_TOUCH, st.CHIP_ANY) orelse return;
    const tags = part.tags;
    const int_line = BoardPin.of(ub.GetTagData(st.PART_PinInt, 0, tags));
    if (int_line.kind != expansion.boardpin.BPIN_GPIO) return;
    tb.int_pin = int_line.number;
    tb.reset = BoardPin.of(ub.GetTagData(st.PART_PinReset, 0, tags));
    tb.part_address = @truncate(ub.GetTagData(st.PART_Address, 0, tags));
    tb.bus_unit = @truncate(ub.GetTagData(st.PART_BusUnit, 0, tags));
    tb.turn = _touch.turnOf(@truncate(ub.GetTagData(st.PART_Turn, 0, tags)));
    switch (part.chip) {
        st.CHIP_GT911 => tb.controller = .gt911,
        st.CHIP_ST7123 => {
            tb.controller = .panel;
            tb.poll_ticks = panel_poll_us;
        },
        else => {},
    }
}

const vectors = [_]*const anyopaque{
    vec(open),
    vec(close),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(TouchBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// Cold start after i2c.device (35) and expander.resource (30), which the
/// first open needs.
export const touch_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &touch_device_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = DEVICE_VERSION,
    .pri = 28,
    .type = .device,
    .name = DEVICE_NAME,
    .id_string = DEVICE_VERSION_STRING[1..],
    .init = &init_table,
};
