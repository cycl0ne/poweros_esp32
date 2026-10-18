// SPDX-License-Identifier: MIT
//! timer.device's micro timer, waited on from the task that asks the
//! library for something that takes its time: the opener while the host
//! bridges come up, the caller of ResetPCIDevice while its function does.

const sdk = @import("sdk");
const exec = sdk.exec;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;

pub const Delay = struct {
    sys: *ExecBase,
    port: *exec.MsgPort,
    io: timer.TimeRequest = .{},

    /// A timer for the calling task; null if it cannot have one.
    pub fn open(sys: *ExecBase) ?Delay {
        const port = sys.CreateMsgPort() orelse return null;
        var delay = Delay{ .sys = sys, .port = port };
        delay.io.node.message.reply_port = port;
        delay.io.node.message.length = @sizeOf(timer.TimeRequest);
        if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &delay.io.node, 0) != 0) {
            sys.DeleteMsgPort(port);
            return null;
        }
        return delay;
    }

    /// `us` microseconds waited out.
    pub fn wait(delay: *Delay, us: u32) void {
        delay.io.node.message.reply_port = delay.port;
        delay.io.node.command = timer.TR_ADDREQUEST;
        delay.io.time = timer.TimeVal.fromMicros(us);
        _ = delay.sys.DoIO(&delay.io.node);
    }

    pub fn close(delay: *Delay) void {
        delay.sys.CloseDevice(&delay.io.node);
        delay.sys.DeleteMsgPort(delay.port);
    }
};
