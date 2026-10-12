// SPDX-License-Identifier: MIT
//! The device's DOS process: a unit's network interface brought up the
//! first time an adapter comes into the unit.
//!
//! **A unit's interface** is the file `DEVS:NetInterfaces/USB<n>` - unit
//! n's - brought up by `C:net/AddNetInterface USB<n>` as the boot brings
//! up the others. The file says `Start = DEVICE`, so the boot's `ALL`
//! leaves it to this, and nothing of the device is loaded before an
//! adapter is plugged in. It is asked for once: the interface stays from
//! then on, down while the unit has no adapter and up with the next one,
//! which brings its own Ethernet address. A unit with no file has no
//! interface, and one already up - added by hand - is left as it is.
//!
//! **Why a process of its own.** AddNetInterface opens the unit and waits
//! for the device's task to answer it: the task cannot be the one
//! waiting. Running a command needs a process, too.

const sdk = @import("sdk");
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const _ecm = @import("_ecm.zig");
const EcmBase = _ecm.EcmBase;
const Link = _ecm.Link;

const directory = "DEVS:NetInterfaces/";
const command_head = "C:net/AddNetInterface ";
/// Nothing said, and DHCP not waited for: the address comes when it
/// comes.
const command_tail = " QUIET NOWAIT";

pub fn netifProcess(sys: *ExecBase) callconv(.c) void {
    const process = sys.FindTask(null).?;
    const base: *EcmBase = @ptrCast(@alignCast(process.user_data orelse return));
    const port = sys.CreateMsgPort();
    base.adder = port;
    if (base.starter) |starter| {
        base.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(base.start_signal));
    }
    const adder = port orelse return;
    while (true) {
        _ = sys.WaitPort(adder);
        while (sys.GetMsg(adder)) |msg| {
            const link: *Link = @alignCast(@fieldParentPtr("tell", msg));
            bringUp(base, base.unitNumber(link));
        }
    }
}

/// Unit `number`'s interface brought up, if it has a file.
fn bringUp(base: *EcmBase, number: u32) void {
    const dl = base.dos_base orelse return;
    const digit: u8 = '0' + @as(u8, @intCast(number));
    var path = (directory ++ "USB0").*;
    path[path.len - 1] = digit;
    const lock = dl.Lock(&path, dos.ACCESS_READ) orelse return;
    dl.UnLock(lock);
    var command = (command_head ++ "USB0" ++ command_tail).*;
    command[command_head.len + 3] = digit;
    _ = dl.SystemTagList(&command, null);
}
