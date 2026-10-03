// SPDX-License-Identifier: MPL-2.0
//! LogControl: the system log's settings - the level it keeps, and the USB
//! console's copy.

const sdk = @import("sdk");
const _log = @import("_log.zig");
const _rawio = @import("../rawio/_rawio.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const lg = sdk.exec.log;

/// Changes one of the system log's settings, or asks what it is.
///
/// SYNOPSIS:
/// ```zig
/// fn LogControl(base: *ExecBase, what: u32, value: isize) isize
/// ```
///
/// SINCE: 1.2. LVO -488.
///
/// INPUTS:
/// - `what` - the setting:
///   - `LOGCTRL_LEVEL` - the level kept, `LOG_ERROR` to `LOG_DEBUG`. A
///     line below it is not written at all.
///   - `LOGCTRL_MIRROR` - 1 when the log is copied to the USB console, 0
///     when not.
///   - `LOGCTRL_USBPORT` - 1 when the USB port has a driver that copies
///     the log to it, which exec then no longer writes to: what
///     usbserial.device says as it starts.
/// - `value` - what it is set to; `LOGCTRL_ASK` changes nothing.
///
/// RESULT:
/// What the setting was before; -1, and nothing changed, for a setting
/// that does not exist or a value it cannot take.
///
/// BEHAVIOR:
/// A level takes effect with the next line. The mirror is written by the
/// raw port itself, character by character, until the USB port has a
/// driver; from then on usbserial.device copies the log, and turning the
/// mirror on there starts with the lines that come after it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// The startup script sets the level from `ENV:Sys/loglevel`, with
/// `C:Log LEVEL`. The mirror starts as the board says: on where the USB
/// port is the only way to the machine.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadLog`, `SetLogSignal`, `RawPutChar`, sdk.exec.klog
///
/// EXAMPLES:
/// ```zig
/// // Debug lines from now on, and the level before back afterwards.
/// const before = sys.LogControl(sdk.exec.LOGCTRL_LEVEL, sdk.exec.LOG_DEBUG);
/// defer _ = sys.LogControl(sdk.exec.LOGCTRL_LEVEL, before);
/// ```
pub fn LogControl(_: *ExecBase, what: u32, value: isize) isize {
    const ask = value == lg.LOGCTRL_ASK;
    switch (what) {
        lg.LOGCTRL_LEVEL => {
            const before: isize = @intCast(_log.level);
            if (ask) return before;
            if (value < lg.LOG_ERROR or value > lg.LOG_DEBUG) return -1;
            _log.level = @intCast(value);
            return before;
        },
        lg.LOGCTRL_MIRROR, lg.LOGCTRL_USBPORT => {
            const setting = if (what == lg.LOGCTRL_MIRROR) &_log.mirror_wanted else &_log.usb_taken;
            const before: isize = @intFromBool(setting.*);
            if (ask) return before;
            if (value != 0 and value != 1) return -1;
            setting.* = value == 1;
            _rawio.setMirror();
            return before;
        },
        else => return -1,
    }
}
