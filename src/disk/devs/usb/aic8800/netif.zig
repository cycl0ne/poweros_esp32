// SPDX-License-Identifier: MIT
//! The device's DOS process: the unit's network interface brought up the
//! first time the Wi-Fi comes up.
//!
//! **The unit's interface** is the file `DEVS:NetInterfaces/WLAN1`,
//! brought up by `C:net/AddNetInterface WLAN1` as the boot brings up the
//! others. The file says `Start = DEVICE`, so the boot's `ALL` leaves it
//! to this, and nothing of the device is loaded before a stick is plugged
//! in. It is asked for once: the interface stays from then on, down while
//! no stick is plugged in. A `Network` line in it has that network joined
//! - and joined again by the next stick, which the device remembers. No
//! file, no interface; one already up - added by hand - is left as it is.
//!
//! **Why a process of its own.** AddNetInterface opens the unit and waits
//! for the device's worker to answer it: the worker cannot be the one
//! waiting.

const sdk = @import("sdk");
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const _aic = @import("_aic8800.zig");
const AicBase = _aic.AicBase;

const file = "DEVS:NetInterfaces/WLAN1";
/// Nothing said, and DHCP not waited for: the address comes when it
/// comes.
const command = "C:net/AddNetInterface WLAN1 QUIET NOWAIT";

pub fn netifProcess(sys: *ExecBase) callconv(.c) void {
    const process = sys.FindTask(null).?;
    const base: *AicBase = @ptrCast(@alignCast(process.user_data orelse return));
    const port = sys.CreateMsgPort();
    base.adder = port;
    if (base.starter) |starter| {
        base.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(base.start_signal));
    }
    const adder = port orelse return;
    while (true) {
        _ = sys.WaitPort(adder);
        while (sys.GetMsg(adder)) |_| bringUp(base);
    }
}

/// The interface brought up, if it has a file.
fn bringUp(base: *AicBase) void {
    const dl = base.dos_base orelse return;
    const lock = dl.Lock(file, dos.ACCESS_READ) orelse return;
    dl.UnLock(lock);
    _ = dl.SystemTagList(command, null);
}
