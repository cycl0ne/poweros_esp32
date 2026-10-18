// SPDX-License-Identifier: MIT
//! The SBI firmware's calls, as the RISC-V SBI specification 1.0 has them
//! and OpenSBI 1.2 answers them: an `ecall` from supervisor mode with the
//! extension's id in a7, the function's in a6 and the arguments in a0-a5,
//! answered with an error in a0 and a value in a1.
//!
//! Only supervisor-mode code calls them: from a task they would be the
//! same, since tasks run in supervisor mode too, but nothing outside the
//! kernel has a reason to.

pub const Ret = struct {
    /// SUCCESS, or one of the ERR_ codes.
    err: isize,
    value: usize,
};

pub const SUCCESS: isize = 0;
pub const ERR_FAILED: isize = -1;
pub const ERR_NOT_SUPPORTED: isize = -2;
pub const ERR_INVALID_PARAM: isize = -3;
pub const ERR_DENIED: isize = -4;
pub const ERR_INVALID_ADDRESS: isize = -5;
pub const ERR_ALREADY_AVAILABLE: isize = -6;

/// The extensions, by their ids.
pub const EXT_LEGACY_CONSOLE_PUTCHAR: usize = 0x01;
pub const EXT_BASE: usize = 0x10;
pub const EXT_TIME: usize = 0x5449_4D45; // "TIME"
pub const EXT_IPI: usize = 0x73_5049; // "sPI"
pub const EXT_RFENCE: usize = 0x5246_4E43; // "RFNC"
pub const EXT_HSM: usize = 0x48_534D; // "HSM"
pub const EXT_SRST: usize = 0x5352_5354; // "SRST"

/// The call itself.
pub inline fn call(ext: usize, fid: usize, arg0: usize, arg1: usize, arg2: usize) Ret {
    var err: isize = undefined;
    var value: usize = undefined;
    asm volatile ("ecall"
        : [err] "={x10}" (err),
          [value] "={x11}" (value),
        : [arg0] "{x10}" (arg0),
          [arg1] "{x11}" (arg1),
          [arg2] "{x12}" (arg2),
          [fid] "{x16}" (fid),
          [ext] "{x17}" (ext),
        : .{ .memory = true });
    return .{ .err = err, .value = value };
}

/// The specification's version the firmware implements: major in bits
/// 24-30, minor in 0-23.
pub fn specVersion() usize {
    return call(EXT_BASE, 0, 0, 0, 0).value;
}

/// The firmware: 1 is OpenSBI, and its version.
pub fn implementationId() usize {
    return call(EXT_BASE, 1, 0, 0, 0).value;
}

pub fn implementationVersion() usize {
    return call(EXT_BASE, 2, 0, 0, 0).value;
}

/// Whether the firmware has extension `ext`.
pub fn probe(ext: usize) bool {
    return call(EXT_BASE, 3, ext, 0, 0).value != 0;
}

/// The timer's next interrupt at `time` (in the `time` counter's units,
/// the platform's timebase); its pending interrupt is cleared meanwhile.
pub fn setTimer(time: u64) void {
    _ = call(EXT_TIME, 0, time, 0, 0);
}

/// The software interrupt raised on every hart whose bit is set in
/// `mask`, bit 0 being hart `base`.
pub fn sendIpi(mask: usize, base: usize) isize {
    return call(EXT_IPI, 0, mask, base, 0).err;
}

/// Hart `hartid` started at `address`, in supervisor mode with its
/// interrupts and its MMU off, a0 its id and a1 `opaque`.
pub fn hartStart(hartid: usize, address: usize, opaque_value: usize) isize {
    return call(EXT_HSM, 0, hartid, address, opaque_value).err;
}

/// Hart states, as `hartStatus` answers them.
pub const HART_STARTED: usize = 0;
pub const HART_STOPPED: usize = 1;
pub const HART_START_PENDING: usize = 2;
pub const HART_STOP_PENDING: usize = 3;

/// Where hart `hartid` is: one of HART_, or null if there is no such hart.
pub fn hartStatus(hartid: usize) ?usize {
    const ret = call(EXT_HSM, 2, hartid, 0, 0);
    return if (ret.err == SUCCESS) ret.value else null;
}

/// System reset types and reasons.
pub const RESET_SHUTDOWN: usize = 0;
pub const RESET_COLD_REBOOT: usize = 1;
pub const RESET_WARM_REBOOT: usize = 2;
pub const REASON_NONE: usize = 0;
pub const REASON_FAILURE: usize = 1;

/// The machine reset or off; answers only if the firmware refused.
pub fn systemReset(kind: usize, reason: usize) isize {
    return call(EXT_SRST, 0, kind, reason, 0).err;
}

/// One character out through the firmware's console: the legacy call,
/// for before the kernel knows where its UART is.
pub fn consolePutchar(character: u8) void {
    _ = call(EXT_LEGACY_CONSOLE_PUTCHAR, 0, character, 0, 0);
}
