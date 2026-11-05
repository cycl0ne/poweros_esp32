// SPDX-License-Identifier: MIT
//! intelnet.device: Intel's gigabit Ethernet controllers on PCI as a
//! network device (sdk/devices/network.zig). A unit is a controller, in
//! the order pci.library found them, so unit 0 is the machine's first
//! Ethernet port. It is in DEVS:networks/, and a machine with no such
//! controller gets no device.
//!
//! What it answers is the network device API as that file describes it,
//! on an Ethernet link: 48-bit addresses, an MTU of 1500, and the speed
//! the link came up at.
//!
//! Two generations are driven. The 82576 and the parts built like it go
//! at a gigabit; the I225 and I226 go at 2.5. They differ in where one
//! register block sits and in the speed they report, and in nothing else
//! that this device touches - the descriptor rings, the receive filter
//! and the interrupt registers are at the same places with the same bits
//! - so one driver covers both and `family/` holds the difference.
//!
//! **The link.** The controller is told once to bring its link up and
//! reports what came of it; it raises a cause of its own when that
//! changes, so a cable going in or out takes the unit on and off line
//! without anything being polled.
//!
//! **Checksums.** The controller works them out both ways, so the sums
//! over a packet's every byte - the one costly thing about handling one
//! - fall to it rather than to the opener.
//!
//! On the way in it checks what a packet carries and says in the
//! descriptor what it found, so a read of a packet whose checksums were
//! all there and all right is answered as checked. It abstains where
//! there was nothing it could check: a frame that is not an IP packet,
//! and a packet whose transport part is neither TCP nor UDP.
//!
//! On the way out it finishes the transport checksum of a write that
//! asked for one, told by a context descriptor in front of the frame
//! where the headers end. What it works out is seeded from the field it
//! finds, so the pseudo-header's own sum goes in first, and the IP
//! header's checksum is worked out at the same time - a dozen bytes and
//! twenty against a payload of fifteen hundred (`checksum.zig`).
//!
//! **Two things are left out on purpose**, because what they need is in
//! the parts' own documents and not in the register map:
//!
//! - The semaphore a controller keeps so that a driver and the board's
//!   management firmware do not drive the PHY's management bus at once.
//!   This device makes one such access, at the start, to begin the
//!   negotiation. A card whose firmware drives that bus as well could
//!   collide with it.
//! - A least time between interrupts. The throttle register is written
//!   to 0, which is what the controller comes up with: every frame
//!   raises its interrupt. That is what is wanted at a gigabit, and at
//!   2.5 it is a great many interrupts a second.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const timer = sdk.devices.timer;
const pci = sdk.pci;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const PCIBase = sdk.interface.pci.PCIBase;
const _intelnet = @import("_intelnet.zig");
const IntelnetBase = _intelnet.IntelnetBase;
const Card = _intelnet.Card;
const Work = _intelnet.Work;
const pci_file = @import("pci.zig");
const sana = @import("sana.zig");

pub const DEVICE_NAME = _intelnet.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 1;
const BUILD_DATE = "05.11.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// exec has copied the tag's name, version and ID string into the base.
/// A machine with no controller this device drives gets no device at
/// all: null, with everything that was taken given back. Otherwise every
/// controller is claimed and reset, a card each, and the task is
/// started; this waits until the task takes requests.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _intelnet.intelnetBase(dev);
    base.sys_base = sys_base;
    base.seg_list = seg_list;

    const utility_lib = sys_base.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null;
    base.utility = @ptrCast(utility_lib);
    // pci.library is wanted from revision 1 on, which is where it says
    // whether a function sees the processors' caches; an older one just
    // means the caches are seen to by hand.
    const pci_lib = sys_base.OpenLibrary(pci.PCINAME, 2) orelse {
        sdk.exec.kprintf(sys_base, "%s: no pci.library on this machine\n", .{DEVICE_NAME});
        release(base);
        return null;
    };
    base.pci_base = @ptrCast(pci_lib);

    // PA_IGNORE until the task has a signal for it: a request that comes
    // in while the device starts is queued, and the task takes it then.
    base.port = .{ .flags = exec.PA_IGNORE };
    base.port.msg_list.init(.message);

    // The timer is open before the first controller is reset: a reset
    // asks for a wait that is not a register poll.
    base.timer_io = .{};
    base.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys_base.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &base.timer_io.node, 0) == 0) {
        base.timer_open = 1;
    }

    pci_file.findAll(base, &sana.intServer);
    if (base.card_count == 0) {
        sdk.exec.kprintf(sys_base, "%s: no Ethernet controller of its kind in this machine\n", .{DEVICE_NAME});
        release(base);
        return null;
    }
    for (base.cards[0..base.card_count]) |maybe| {
        if (maybe) |card| pci_file.describe(card);
    }

    const stack = sys_base.AllocMem(sana.stack_size, exec.MEMF_CLEAR) orelse {
        release(base);
        return null;
    };
    base.stack = stack;
    base.task = .{
        .node = .{ .type = .task, .pri = sana.task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + sana.stack_size,
    };

    const signal = sys_base.AllocSignal(-1);
    if (signal >= 0) {
        base.starter = sys_base.FindTask(null);
        base.start_signal = @intCast(signal);
    }
    _ = sys_base.AddTask(&base.task, &sana.netTask, null);
    if (signal >= 0) {
        _ = sys_base.Wait(@as(u32, 1) << @intCast(signal));
        sys_base.FreeSignal(@intCast(signal));
    }
    if (base.ready != 0) {
        // The task is there to take them, so the cards' causes go on
        // now rather than when a unit is told to run: a unit that is off
        // line for want of a carrier has to hear the carrier arrive.
        for (base.cards[0..base.card_count]) |maybe| {
            if (maybe) |card| card.startInterrupts();
        }
        return dev;
    }
    {
        sdk.exec.kprintf(sys_base, "%s: its task has no signal to work with\n", .{DEVICE_NAME});
        // The task has stopped by itself; what it never took is given
        // back here.
        sys_base.FreeMem(stack, sana.stack_size);
        base.stack = null;
        release(base);
        return null;
    }
}

/// Everything the init took, given back: each card's interrupt, its
/// memory and its PCI function, then the libraries. The device is about
/// to be refused, so nothing of it may be left behind.
fn release(base: *IntelnetBase) void {
    const sys = base.sys_base;
    if (base.pci_base) |pb| {
        for (base.cards[0..base.card_count]) |maybe| {
            const card = maybe orelse continue;
            switch (card.signalling) {
                .vector, .message => {
                    pb.RemPCIVectorServer(card.function, 0, &card.int);
                    pb.FreePCIVectors(card.function);
                },
                .line => pb.RemPCIIntServer(card.function, &card.int),
                .none => {},
            }
            if (card.work_memory != 0) sys.FreeMem(@ptrFromInt(card.work_memory), card.work_bytes);
            pb.ReleasePCIDevice(card.function);
            sys.FreeMem(card, @sizeOf(Card));
        }
        base.card_count = 0;
        sys.CloseLibrary(@ptrCast(@alignCast(pb)));
        base.pci_base = null;
    }
    if (base.timer_open != 0) {
        sys.CloseDevice(&base.timer_io.node);
        base.timer_open = 0;
    }
    if (base.utility) |utility| {
        sys.CloseLibrary(@ptrCast(@alignCast(utility)));
        base.utility = null;
    }
}

/// The jump table: the six standard vectors, nothing past AbortIO.
const vectors = [_]*const anyopaque{
    vec(sana.open),
    vec(sana.close),
    vec(sana.expunge),
    vec(exec.libExtFunc),
    vec(sana.beginIO),
    vec(sana.abortIO),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(IntelnetBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// What the device speaks, for ObtainDeviceUnits (expansion.library).
const device_speaks = [_]u32{ sdk.expansion.devices.DEVIF_SANA2, 0 };

/// No flags but AUTOINIT and DEVICEINFO: the device is on the disk, in
/// DEVS:networks/, and is made when something opens it - ramlib loads
/// the file and hands this tag to InitResident. `units` is as many
/// controllers as it takes, not as many as a machine has: the tag is
/// read without running anything, and what is really there is only known
/// once pci.library has been walked.
///
/// It is in `.resident`, which program.ld KEEPs: nothing in the file
/// refers to the tag, whoever loads the file looks for it.
export const intelnet_device_tag: exec.ResidentDevice linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&intelnet_device_tag),
        .flags = exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
        .version = DEVICE_VERSION,
        .pri = 0,
        .type = .device,
        .name = DEVICE_NAME,
        .id_string = DEVICE_VERSION_STRING[1..], // past the NUL: a C string
        .init = &init_table,
    },
    .speaks = &device_speaks,
    .units = _intelnet.max_cards,
};

/// A device is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a device, not a command\n", .{DEVICE_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for. Nothing refers
/// to it, so it needs an export and a section of its own that program.ld
/// KEEPs.
export const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;
