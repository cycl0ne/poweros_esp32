// SPDX-License-Identifier: MPL-2.0
//! Talking to a handler: the packets every other call is built on, and
//! the dos objects - packets, file handles and the rest - that carry them.
//!
//! The packet level every other dos call is built on: a DosPacket goes to
//! a handler's port, and comes back to the port its sender named.
//!
//! The packet is its own message (`DosPacket.fromMessage`), so there is no
//! separate link to follow: `qpkt` swaps dp_Port for the sender's own port
//! on the way out, which is how a reply finds its way back, and `taskwait`
//! takes the next packet off a port - through the process's pr_PktWait
//! when it has one, so a handler that multiplexes its port can hand dos
//! the packets it is waiting for.
//!
//! `exchange` is the synchronous round trip DoPkt and dos's own calls
//! use. It keeps any packet that arrives at the reply port before its own
//! and puts those back, in order, once its own is home, so a caller with
//! packets of its own in flight loses none of them. A plain task has no
//! msg_port, so it gets one for the call.
//!
//! AllocDosObject and FreeDosObject: one allocator for the objects dos
//! hands out, so a caller never needs to know their size or how they
//! are laid out.
//!
//! - DOS_STDPKT: a cleared DosPacket with its message's length set.
//! - DOS_FILEHANDLE: a FileHandle with its defaults; the first buffered
//!   call allocates its buffer.
//! - DOS_FIB and DOS_EXALLCONTROL: cleared (ExAll's last_key starts at
//!   0).
//! - DOS_CLI: a CommandLineInterface with its four name buffers behind
//!   it in the same block, each CLI_MAX_* bytes, and the structure's
//!   defaults.
//! - DOS_RDARGS: a cleared RDArgs.
//!
//! Every object is one AllocVec block, so FreeDosObject frees each
//! known type the same way. The tags are not read yet; they are there
//! for the options of the types to come.

const sdk = @import("sdk");
const process = @import("../process/_process.zig");
const DosBase = @import("../dos_base.zig").DosBase;
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const MsgPort = sdk.exec.MsgPort;
const DosPacket = dos.DosPacket;
const Process = dos.Process;
const exec = sdk.exec;

/// Sends a packet to its dp_Port, leaving `own_port` in dp_Port for the
/// way back.
///
/// INPUTS:
/// - `sys` - exec, to put the message.
/// - `pkt` - the packet, dp_Port naming the handler's port.
/// - `own_port` - where the reply is to go; null leaves the packet with
///   no way back.
///
/// BEHAVIOR:
/// A packet without a dp_Port has nowhere to go and is dropped silently.
pub fn qpkt(sys: *ExecBase, pkt: *DosPacket, own_port: ?*MsgPort) void {
    const to = pkt.port orelse return;
    pkt.port = own_port;
    sys.PutMsg(to, &pkt.msg);
}

/// The running process's msg_port; null from a plain task.
///
/// INPUTS:
/// - `sys` - exec, to find the running task.
pub fn ownPort(sys: *ExecBase) ?*MsgPort {
    const proc = process.currentProcess(sys) orelse return null;
    return &proc.msg_port;
}

/// The next packet at `port`, waiting for it: through the process's
/// pr_PktWait when it has one, else from the port itself.
///
/// INPUTS:
/// - `sys` - exec, for GetMsg and Wait.
/// - `proc` - the running process, or null for a plain task.
/// - `port` - the port to wait at; pr_PktWait decides this for itself.
///
/// CONTEXT:
/// - Waits: yes.
pub fn taskwait(sys: *ExecBase, proc: ?*Process, port: *MsgPort) *DosPacket {
    if (proc) |p| {
        if (p.pkt_wait) |wait| return DosPacket.fromMessage(wait(p, sys));
    }
    while (true) {
        if (sys.GetMsg(port)) |msg| return DosPacket.fromMessage(msg);
        _ = sys.Wait(port.sigMask());
    }
}

/// What came back in `exchange`'s packet: dp_Res1, dp_Res2 and the arguments as the handler left them.
pub const Result = struct { res1: isize, res2: i32, args: [7]isize };

/// Sends a packet built on the stack to `port` and waits for it to come
/// back. Null when a plain task can't have a reply port.
///
/// INPUTS:
/// - `sys` - exec.
/// - `port` - the handler's port.
/// - `action` - the packet's dp_Type.
/// - `args` - dp_Arg1 to dp_Arg5; dp_Arg6 and dp_Arg7 are 0.
///
/// BEHAVIOR:
/// A process waits at its msg_port and gets dp_Res2 as its IoErr; a task
/// gets a port for the call. Packets that arrive first are kept and go
/// back on the port, in order, with its signal set again, once this one is
/// back.
///
/// CONTEXT:
/// - Waits: yes. Never under Forbid.
pub fn exchange(sys: *ExecBase, port: *MsgPort, action: i32, args: [5]isize) ?Result {
    const proc = process.currentProcess(sys);
    const reply_port = if (proc) |p| &p.msg_port else sys.CreateMsgPort() orelse return null;
    defer if (proc == null) sys.DeleteMsgPort(reply_port);
    return exchangeVia(sys, proc, reply_port, port, action, args);
}

/// `exchange` with the reply port already in hand, for a caller that must
/// know it can have one before it does something it cannot take back.
///
/// INPUTS:
/// - `sys` - exec.
/// - `proc` - the calling process, or null for a plain task.
/// - `reply_port` - the process's msg_port, or a port of the task's own.
/// - `port` - the handler's port.
/// - `action` - the packet's dp_Type.
/// - `args` - dp_Arg1 to dp_Arg5; dp_Arg6 and dp_Arg7 are 0.
pub fn exchangeVia(sys: *ExecBase, proc: ?*Process, reply_port: *MsgPort, port: *MsgPort, action: i32, args: [5]isize) Result {
    var pkt: DosPacket = .{
        .msg = .{ .length = @sizeOf(DosPacket), .reply_port = reply_port },
        .port = port,
        .action = action,
        .args = .{ .raw = args ++ [2]isize{ 0, 0 } },
    };
    qpkt(sys, &pkt, reply_port);
    var strays: sdk.exec.List = undefined;
    strays.init(.message);
    while (true) {
        const got = taskwait(sys, proc, reply_port);
        if (got == &pkt) break;
        sys.AddTail(&strays, &got.msg.node);
    }
    if (!strays.isEmpty()) {
        sys.Disable();
        while (sys.RemTail(&strays)) |node| sys.AddHead(&reply_port.msg_list, node);
        sys.Enable();
        _ = sys.SetSignal(reply_port.sigMask(), reply_port.sigMask());
    }
    if (proc) |p| p.result2 = pkt.res2;
    return .{ .res1 = pkt.res1, .res2 = pkt.res2, .args = pkt.args.raw };
}

/// A CLI's block: the structure, then its set name, command name,
/// prompt and command file buffers.
pub const cli_block_size = @sizeOf(dos.CommandLineInterface) + dos.CLI_MAX_SET_NAME + dos.CLI_MAX_COMMAND_NAME +
    dos.CLI_MAX_PROMPT + dos.CLI_MAX_COMMAND_FILE;

/// Lays a CLI out in a cleared block of cli_block_size bytes: the
/// structure's defaults, and its names pointing at the empty buffers
/// behind it.
///
/// INPUTS:
/// - `block` - the block.
///
/// RESULT:
/// The CLI, at the block's start.
pub fn initCli(block: [*]u8) *dos.CommandLineInterface {
    const c: *dos.CommandLineInterface = @ptrCast(@alignCast(block));
    c.* = .{};
    var text = block + @sizeOf(dos.CommandLineInterface);
    c.set_name = @ptrCast(text);
    text += dos.CLI_MAX_SET_NAME;
    c.command_name = @ptrCast(text);
    text += dos.CLI_MAX_COMMAND_NAME;
    c.prompt = @ptrCast(text);
    text += dos.CLI_MAX_PROMPT;
    c.command_file = @ptrCast(text);
    return c;
}

/// A cleared block of `size` bytes from AllocVec.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `size` - how many bytes.
///
/// RESULT:
/// The block, or null with ERROR_NO_FREE_STORE.
pub fn cleared(db: *DosBase, size: usize) ?*anyopaque {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    return sys.AllocVec(size, exec.MEMF_CLEAR) orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    };
}
