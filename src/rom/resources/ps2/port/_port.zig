// SPDX-License-Identifier: MPL-2.0
//! The PC's keyboard controller: the part a PS/2 keyboard and a PS/2
//! pointing device are plugged into, at the two ports every machine of
//! this kind has it at.
//!
//! **Its two ports.** 0x60 is the data: a byte from a device read, a byte
//! to the keyboard written. 0x64 read is the status - bit 0 a byte waits
//! to be read, bit 1 the controller has not yet taken the last one
//! written, bit 5 the byte waiting is the pointing device's - and written
//! is a command to the controller itself. A byte for the pointing device
//! is sent by telling the controller so first (0xD4).
//!
//! **Setting it up** (`setUp`): both devices' lines are closed while the
//! controller's own byte is read and written back with both interrupts
//! on, both clocks running and the translation on - every keyboard's
//! codes then come as the first set's, which is what `key/scancode.zig`
//! reads - then opened again. The keyboard is told to send its keys. The
//! pointing device is set to its defaults, asked whether it has a wheel
//! the way a wheel mouse is asked - three sample rates in a row, after
//! which one that has a wheel says so in its identifier - and told to
//! send its packets. The controller is not reset and not asked to test
//! itself: on a laptop that is the firmware's part, and some take a reset
//! as the moment to forget what the firmware set.
//!
//! **A machine without one** reads all ones at both ports: its status
//! says a byte waits that never runs out. Such a machine has no
//! controller, and nothing is written to it. Every wait here is counted,
//! so a controller or a device that does not answer costs a moment and
//! no more.
//!
//! Before the interrupts are on, answers are read by asking the status
//! over and over (`answer`); once they are on, every byte is the
//! servers'.

const sdk = @import("sdk");

/// The ports, on the machines that have them; on any other, ports that
/// read as a machine without the controller does.
const io = if (sdk.hardware.chip == .x64uefi) sdk.hardware.mmio else struct {
    fn in8(_: u16) u8 {
        return 0xFF;
    }
    fn out8(_: u16, _: u8) void {}
};

const DATA: u16 = 0x60;
const STATUS: u16 = 0x64;
const COMMAND: u16 = 0x64;

/// The status's bits.
pub const STATUS_WAITING: u8 = 1 << 0;
const STATUS_BUSY: u8 = 1 << 1;
pub const STATUS_POINTER: u8 = 1 << 5;

/// The controller's commands.
const CMD_READ_CONFIG: u8 = 0x20;
const CMD_WRITE_CONFIG: u8 = 0x60;
const CMD_CLOSE_POINTER: u8 = 0xA7;
const CMD_OPEN_POINTER: u8 = 0xA8;
const CMD_CLOSE_KEYBOARD: u8 = 0xAD;
const CMD_OPEN_KEYBOARD: u8 = 0xAE;
const CMD_TO_POINTER: u8 = 0xD4;

/// The controller's own byte.
const CONFIG_KEYBOARD_INT: u8 = 1 << 0;
const CONFIG_POINTER_INT: u8 = 1 << 1;
const CONFIG_KEYBOARD_OFF: u8 = 1 << 4;
const CONFIG_POINTER_OFF: u8 = 1 << 5;
const CONFIG_TRANSLATE: u8 = 1 << 6;

/// What a device is told, and what it answers.
const DEV_IDENTIFY: u8 = 0xF2;
const DEV_SAMPLE_RATE: u8 = 0xF3;
const DEV_SEND: u8 = 0xF4;
const DEV_DEFAULTS: u8 = 0xF6;
const DEV_ACK: u8 = 0xFA;
/// The identifier of a pointing device with a wheel.
const ID_WHEEL: u8 = 0x03;

/// How often the status is asked before a wait gives up: a port read
/// takes about a microsecond, so this is a tenth of a second or so.
const patience = 100_000;
/// The most bytes thrown away in one go: more than a controller holds.
const flush_most = 64;

/// What `setUp` found.
pub const Found = struct {
    /// The machine has the controller.
    controller: bool = false,
    /// A pointing device answered.
    pointer: bool = false,
    /// It sends a fourth byte, its wheel's.
    wheel: bool = false,
};

/// The status.
pub fn status() u8 {
    return io.in8(STATUS);
}

/// The byte waiting, which reading takes.
pub fn data() u8 {
    return io.in8(DATA);
}

/// Whatever bytes wait, thrown away.
fn flush() void {
    var left: u32 = flush_most;
    while (left > 0 and io.in8(STATUS) & STATUS_WAITING != 0) : (left -= 1) _ = io.in8(DATA);
}

/// Waited until the controller has taken the last byte written; false
/// when it never did.
fn ready() bool {
    var left: u32 = patience;
    while (left > 0) : (left -= 1) {
        if (io.in8(STATUS) & STATUS_BUSY == 0) return true;
    }
    return false;
}

/// The next byte to come, waited for; null when none came.
fn answer() ?u8 {
    var left: u32 = patience;
    while (left > 0) : (left -= 1) {
        if (io.in8(STATUS) & STATUS_WAITING != 0) return io.in8(DATA);
    }
    return null;
}

/// A command to the controller itself.
fn command(byte: u8) bool {
    if (!ready()) return false;
    io.out8(COMMAND, byte);
    return true;
}

/// A byte to the keyboard, and whether it acknowledged it.
fn toKeyboard(byte: u8) bool {
    if (!ready()) return false;
    io.out8(DATA, byte);
    return acknowledged();
}

/// A byte to the pointing device, and whether it acknowledged it.
fn toPointer(byte: u8) bool {
    if (!command(CMD_TO_POINTER) or !ready()) return false;
    io.out8(DATA, byte);
    return acknowledged();
}

/// Whether the next bytes hold an acknowledge: a key pressed meanwhile
/// may come before it.
fn acknowledged() bool {
    var tries: u32 = 4;
    while (tries > 0) : (tries -= 1) {
        const byte = answer() orelse return false;
        if (byte == DEV_ACK) return true;
    }
    return false;
}

/// The controller and its two devices set up, with the interrupts still
/// to be hooked: what there is.
pub fn setUp() Found {
    var found = Found{};
    // All ones: nothing is there to answer.
    if (io.in8(STATUS) == 0xFF) return found;
    _ = command(CMD_CLOSE_KEYBOARD);
    _ = command(CMD_CLOSE_POINTER);
    flush();
    if (!command(CMD_READ_CONFIG)) return found;
    var config = answer() orelse return found;
    config |= CONFIG_KEYBOARD_INT | CONFIG_POINTER_INT | CONFIG_TRANSLATE;
    config &= ~(CONFIG_KEYBOARD_OFF | CONFIG_POINTER_OFF);
    if (!command(CMD_WRITE_CONFIG) or !ready()) return found;
    io.out8(DATA, config);
    found.controller = true;
    _ = command(CMD_OPEN_KEYBOARD);
    _ = command(CMD_OPEN_POINTER);
    flush();

    _ = toKeyboard(DEV_SEND);
    flush();

    if (toPointer(DEV_DEFAULTS)) {
        found.pointer = true;
        // The three rates that ask for a wheel, and what it then is.
        for ([_]u8{ 200, 100, 80 }) |rate| {
            _ = toPointer(DEV_SAMPLE_RATE);
            _ = toPointer(rate);
        }
        if (toPointer(DEV_IDENTIFY)) {
            if (answer()) |id| found.wheel = id == ID_WHEEL;
        }
        _ = toPointer(DEV_SEND);
    }
    flush();
    return found;
}
