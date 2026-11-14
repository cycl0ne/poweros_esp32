// SPDX-License-Identifier: MPL-2.0
//! The emulators' command lines: Espressif's QEMU for the ESP32-S3, and
//! upstream QEMU's virt and q35 machines with their network, USB, sound,
//! monitor and disks.

const std = @import("std");
const build_boards = @import("boards.zig");
const build_disk = @import("disk.zig");
const build_kernel = @import("kernel.zig");
const build_release = @import("release.zig");

const Board = build_boards.Board;
const chipOf = build_boards.chipOf;
const disk_sector = build_boards.disk_sector;
const flash_boards = build_boards.flash_boards;
const virt_work_bytes = build_boards.virt_work_bytes;
const virt_work_dir = build_boards.virt_work_dir;
const flashDisk = build_disk.flashDisk;
const Image = build_kernel.Image;
const addA64Image = build_kernel.addA64Image;
const addImage = build_kernel.addImage;
const addKernel = build_kernel.addKernel;
const addP4Image = build_kernel.addP4Image;
const addX64Image = build_kernel.addX64Image;
const addReport = build_release.addReport;
const ramDiskName = build_release.ramDiskName;
const release_dir = build_release.release_dir;

/// The host ports qemu-display forwards to the machine's Telnet port, 23,
/// and its SSH port, 22.
pub const display_telnet_port: u16 = 2323;
pub const display_ssh_port: u16 = 2222;
/// The two NVMe SSDs of a virt machine: the system disk the build made,
/// whose writes QEMU keeps in a copy that ends with the run
/// (`snapshot=on`), and the work disk, which keeps them. QEMU passes the
/// work disk's flushes on to nobody (`cache=unsafe`): each would be a
/// sync of the image file on the host, milliseconds apiece, while what
/// was written is in the host's own cache already and stays there when
/// QEMU quits or is killed - only a crash of the host can lose it.
const VirtDisks = struct {
    system: std.Build.LazyPath,
    /// The work disk's path, and the step that puts it there.
    work: WorkDisk,

    fn addTo(disks: VirtDisks, run: *std.Build.Step.Run) void {
        const b = run.step.owner;
        run.addArg("-drive");
        run.addPrefixedFileArg("if=none,id=system,format=raw,snapshot=on,file=", disks.system);
        run.addArgs(&.{
            "-device", "nvme,serial=system,drive=system",
            "-drive",  b.fmt("if=none,id=work,format=raw,cache=unsafe,file={s}", .{disks.work.path}),
            "-device", "nvme,serial=work,drive=work",
        });
        run.step.dependOn(disks.work.step);
    }
};

/// A machine's firmware variable store, `name` in `virt_work_dir`: the
/// system's own copied there when there is none yet, so that what the
/// firmware remembers survives between runs and the file it was copied from
/// is never written.
fn keepFirmwareVars(b: *std.Build, blank: []const u8, name: []const u8) WorkDisk {
    const path = b.pathFromRoot(b.pathJoin(&.{ virt_work_dir, name }));
    const keep = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\[ -f "$0" ] || { mkdir -p "$(dirname "$0")" && cp "$1" "$0"; }
        ,
        path,
        blank,
    });
    keep.has_side_effects = true;
    return .{ .path = path, .step = &keep.step };
}

const WorkDisk = struct { path: []const u8, step: *std.Build.Step };

/// A machine's work disk, `name` in `virt_work_dir`: the blank one copied
/// there when there is none yet, which leaves one that is alone. A copy
/// keeps the blank's holes, so the disk takes on the host what has been
/// written to it.
fn keepWorkDisk(b: *std.Build, blank: std.Build.LazyPath, name: []const u8) WorkDisk {
    const path = b.pathFromRoot(b.pathJoin(&.{ virt_work_dir, name }));
    const keep = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\[ -f "$0" ] || { mkdir -p "$(dirname "$0")" && cp "$1" "$0"; }
        ,
        path,
    });
    keep.addFileArg(blank);
    keep.has_side_effects = true;
    return .{ .path = path, .step = &keep.step };
}

/// A QEMU run on a throw-away copy of the image: -snapshot keeps the
/// kernel's writes out of it.
fn qemuRun(b: *std.Build, qemu: []const u8, flash_image: std.Build.LazyPath, network: []const []const u8, usb: []const []const u8, extra: []const []const u8) *std.Build.Step.Run {
    return qemuRunPath(b, qemu, flash_image, true, network, usb, extra);
}

/// What is plugged into the emulator's USB port, as QEMU's arguments: a
/// `-device` per item of `devices` - an item with `=` in it is a property
/// of the device before it, so `usb-kbd,port=1,usb-mouse` is two devices
/// - and a USB stick over the raw image `disk`. The port is the DWC2's one
/// root port: QEMU puts a hub on it by itself when a device other than a
/// hub is plugged in without `port=1`, and the devices then sit behind
/// that hub. A `usb-serial` (an FTDI FT232) without a `chardev=` gets a
/// pty of its own, whose name QEMU prints as it starts; a `usb-net` (a
/// CDC Ethernet adapter) without a `netdev=` a user network of its own,
/// 10.0.3.0/24 for the first (DHCP hands out 10.0.3.15), 10.0.4.0/24 for
/// the next - beside the machine's own Ethernet on 10.0.2.0/24. A device plugged
/// in or out while the machine runs goes through the monitor (Ctrl-A C):
/// `device_add usb-kbd,id=kbd`, `device_del kbd` - the stick is
/// `usbstick`.
pub fn qemuUsb(b: *std.Build, devices: ?[]const u8, disk: ?[]const u8) []const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    if (devices) |list| {
        var specs: std.ArrayList([]const u8) = .empty;
        var items = std.mem.tokenizeScalar(u8, list, ',');
        while (items.next()) |item| {
            if (std.mem.indexOfScalar(u8, item, '=') == null) {
                specs.append(b.allocator, item) catch @panic("OOM");
                continue;
            }
            if (specs.items.len == 0) std.debug.panic("-Dusb={s}: {s} is a property of no device", .{ list, item });
            const last = &specs.items[specs.items.len - 1];
            last.* = b.fmt("{s},{s}", .{ last.*, item });
        }
        var nets: u32 = 0;
        for (specs.items, 0..) |spec, index| {
            const serial = std.mem.eql(u8, spec, "usb-serial") or std.mem.startsWith(u8, spec, "usb-serial,");
            if (serial and std.mem.indexOf(u8, spec, "chardev=") == null) {
                const id = b.fmt("usbserial{d}", .{index});
                args.appendSlice(b.allocator, &.{ "-chardev", b.fmt("pty,id={s}", .{id}), "-device", b.fmt("{s},chardev={s}", .{ spec, id }) }) catch @panic("OOM");
                continue;
            }
            const network = std.mem.eql(u8, spec, "usb-net") or std.mem.startsWith(u8, spec, "usb-net,");
            if (network and std.mem.indexOf(u8, spec, "netdev=") == null) {
                const id = b.fmt("usbnet{d}", .{index});
                nets += 1;
                args.appendSlice(b.allocator, &.{ "-netdev", b.fmt("user,id={s},net=10.0.{d}.0/24", .{ id, 2 + nets }), "-device", b.fmt("{s},netdev={s}", .{ spec, id }) }) catch @panic("OOM");
            } else {
                args.appendSlice(b.allocator, &.{ "-device", spec }) catch @panic("OOM");
            }
        }
    }
    if (disk) |file| {
        args.appendSlice(b.allocator, &.{
            "-drive",  b.fmt("if=none,id=usbdisk,format=raw,file={s}", .{file}),
            "-device", "usb-storage,drive=usbdisk,id=usbstick",
        }) catch @panic("OOM");
    }
    return args.items;
}

/// The emulator's network, as QEMU's arguments: the machine's Ethernet MAC
/// on QEMU's user network - NAT to the host's, with a gateway and DHCP
/// server at 10.0.2.2 and DNS at 10.0.2.3 - named here rather than left
/// to QEMU's default, which a USB adapter's network of its own (`qemuUsb`)
/// would take away. `net` names another
/// backend for the MAC (a tap device puts the machine on the real
/// network) or `none`; `dump` writes every frame to a pcap file, which
/// needs the backend to have a name, so it makes the user network explicit.
/// `telnet` forwards that host port to the machine's port 23, where
/// C:net/ShellServer listens, and `ssh_port` one to port 22, where
/// ShellServer SSH does; 0 is none. Only qemu-display has them unless
/// asked (2323, 2222): a fixed host port keeps a second QEMU from
/// starting, and the display is the run a person sits at.
pub fn qemuNetwork(b: *std.Build, net: ?[]const u8, dump: ?[]const u8, telnet: ?u16, ssh_port: ?u16) []const []const u8 {
    if (net) |backend| {
        if (std.mem.eql(u8, backend, "none")) return b.dupeStrings(&.{ "-nic", "none" });
    }
    const nic = b.fmt("{s},id=net0,model=open_eth{s}", .{ net orelse "user", if (net == null) hostForwards(b, telnet, ssh_port) else "" });
    const file = dump orelse return b.dupeStrings(&.{ "-nic", nic });
    return b.dupeStrings(&.{ "-nic", nic, "-object", b.fmt("filter-dump,id=dump0,netdev=net0,file={s}", .{file}) });
}

/// The virt machines' network, as QEMU's arguments: a USB Ethernet
/// adapter (`usb-net`, a CDC-ECM function usb/ecm.device drives) on the
/// machine's xHCI controller, on QEMU's user network as `qemuNetwork`
/// has it - 10.0.2.15 by DHCP, the gateway 10.0.2.2, DNS at 10.0.2.3.
/// It is the only network those two machines have a driver for; the
/// x86-64 machine has a card of its own (`q35Network`).
/// `net`, `dump`, `telnet` and `ssh_port` are `qemuNetwork`'s; nothing is
/// forwarded unless asked, so one of them starts beside a qemu-display,
/// which holds 2323 and 2222.
pub fn virtNetwork(b: *std.Build, net: ?[]const u8, dump: ?[]const u8, telnet: ?u16, ssh_port: ?u16) []const []const u8 {
    if (net) |backend| {
        if (std.mem.eql(u8, backend, "none")) return b.dupeStrings(&.{ "-nic", "none" });
    }
    const netdev = b.fmt("{s},id=net0{s}", .{ net orelse "user", if (net == null) hostForwards(b, telnet, ssh_port) else "" });
    const adapter = [_][]const u8{ "-netdev", netdev, "-device", "usb-net,netdev=net0" };
    const file = dump orelse return b.dupeStrings(&adapter);
    return b.dupeStrings(&(adapter ++ [_][]const u8{ "-object", b.fmt("filter-dump,id=dump0,netdev=net0,file={s}", .{file}) }));
}

/// The x86-64 machine's network, as QEMU's arguments: an Intel 82576
/// (`igb`), which intelnet.device drives as the machine's Ethernet port,
/// on QEMU's user network as `qemuNetwork` has it. A PC's Ethernet is a
/// card on PCI, not a USB adapter, so this machine is given the card;
/// `-Dusb=usb-net` still plugs an adapter in beside it, on a user
/// network of its own. `net`, `dump`, `telnet` and `ssh_port` are
/// `qemuNetwork`'s.
pub fn q35Network(b: *std.Build, net: ?[]const u8, dump: ?[]const u8, telnet: ?u16, ssh_port: ?u16) []const []const u8 {
    if (net) |backend| {
        if (std.mem.eql(u8, backend, "none")) return b.dupeStrings(&.{ "-nic", "none" });
    }
    const netdev = b.fmt("{s},id=net0{s}", .{ net orelse "user", if (net == null) hostForwards(b, telnet, ssh_port) else "" });
    const card = [_][]const u8{ "-netdev", netdev, "-device", "igb,netdev=net0" };
    const file = dump orelse return b.dupeStrings(&card);
    return b.dupeStrings(&(card ++ [_][]const u8{ "-object", b.fmt("filter-dump,id=dump0,netdev=net0,file={s}", .{file}) }));
}

/// The virt machines' USB speaker, as QEMU's arguments: QEMU's
/// `usb-audio`, which usb/uac.device plays through as one of the
/// machine's outputs, `speaker` in the monitor - `device_del speaker`
/// pulls it out while it plays, `device_add usb-audio,id=speaker` puts it
/// back. `backend` is an `-audiodev`'s driver and its options - `pa`,
/// `pipewire`, `wav,path=out.wav` for a file; with none named QEMU takes
/// the first of the audio backends it has, and plays into nothing when it
/// has none but `none`.
pub fn virtSpeaker(b: *std.Build, backend: ?[]const u8) []const []const u8 {
    const named = backend orelse return b.dupeStrings(&.{ "-device", "usb-audio,id=speaker" });
    return b.dupeStrings(&.{ "-audiodev", b.fmt("{s},id=sound", .{named}), "-device", "usb-audio,id=speaker,audiodev=sound" });
}

/// The q35 machine's own sound, as QEMU's arguments: its ICH9 high
/// definition audio controller with an output codec behind it, which
/// rta-hda finds on PCI by its class and plays through - the same part a
/// machine of this kind really has, rather than something plugged into
/// it. `backend` is an `-audiodev`'s driver and its options, as the virt
/// machines' speaker takes it.
pub fn q35Speaker(b: *std.Build, backend: ?[]const u8) []const []const u8 {
    const card = [_][]const u8{ "-device", "ich9-intel-hda,id=sound" };
    const named = backend orelse return b.dupeStrings(&(card ++ [_][]const u8{ "-device", "hda-output,bus=sound.0,id=speaker" }));
    return b.dupeStrings(&(card ++ [_][]const u8{
        "-audiodev", b.fmt("{s},id=played", .{named}),
        "-device",   "hda-output,bus=sound.0,id=speaker,audiodev=played",
    }));
}

/// QEMU's QMP monitor on a Unix socket, which a program connects to while
/// the machine runs - to take its picture (`screendump`) or to move its
/// pointer and press its buttons (`input-send-event`), as
/// `scripts/qemu-shot.py` does. QEMU makes the socket itself and does not
/// wait for anyone (`server,nowait`); without the option there is none.
pub fn virtMonitor(b: *std.Build, socket: ?[]const u8) []const []const u8 {
    const path = socket orelse return &.{};
    return b.dupeStrings(&.{ "-qmp", b.fmt("unix:{s},server,nowait", .{path}) });
}

/// The user network's port forwards, as a backend's options: `telnet` to
/// the machine's port 23, `ssh_port` to its port 22; null or 0 is none.
fn hostForwards(b: *std.Build, telnet: ?u16, ssh_port: ?u16) []const u8 {
    const telnet_forwarded: ?u16 = if (telnet) |port| (if (port == 0) null else port) else null;
    const ssh_forwarded: ?u16 = if (ssh_port) |port| (if (port == 0) null else port) else null;
    const telnet_forward = if (telnet_forwarded) |port| b.fmt(",hostfwd=tcp::{d}-:23", .{port}) else "";
    const ssh_forward = if (ssh_forwarded) |port| b.fmt(",hostfwd=tcp::{d}-:22", .{port}) else "";
    return b.fmt("{s}{s}", .{ telnet_forward, ssh_forward });
}

/// The display arguments, then the serial ports: UART0, the console, on
/// the terminal QEMU runs in, and UART1 - the RS-485 port, or a SLIP
/// line - on `uart1`'s backend when one is given. `-nographic` alone puts
/// UART0 on the terminal; naming a second port means naming the first as
/// well.
fn qemuConsole(b: *std.Build, display: []const []const u8, uart1: ?[]const u8) []const []const u8 {
    const graphic = !(display.len == 1 and std.mem.eql(u8, display[0], "-nographic"));
    if (uart1 == null and !graphic) return display;
    var args: std.ArrayList([]const u8) = .empty;
    args.appendSlice(b.allocator, display) catch @panic("OOM");
    args.appendSlice(b.allocator, &.{ "-serial", "mon:stdio" }) catch @panic("OOM");
    if (uart1) |backend| args.appendSlice(b.allocator, &.{ "-serial", backend }) catch @panic("OOM");
    return args.items;
}

/// `snapshot` false lets the kernel write the image, so a disk on it keeps
/// what is written from one boot to the next.
///
/// Both cores run on one host thread (`-accel tcg,thread=single`). With a
/// thread each, the Espressif QEMU damages its own heap about a second
/// into a boot, while the desktop loads its code - a double free in its
/// flash requests, or a crash in its translated code - in up to half of
/// all boots; on one thread none.
fn qemuRunPath(b: *std.Build, qemu: []const u8, flash_image: std.Build.LazyPath, snapshot: bool, network: []const []const u8, usb: []const []const u8, extra: []const []const u8) *std.Build.Step.Run {
    // Like the board's N16R8 module: 8 MB octal PSRAM (-m is the PSRAM size).
    const run = b.addSystemCommand(&.{
        qemu,                                            "-machine", "esp32s3",
        "-m",                                            "8M",       "-global",
        "driver=ssi_psram,property=is_octal,value=true", "-accel",   "tcg,thread=single",
    });
    if (snapshot) run.addArg("-snapshot");
    run.addArgs(network);
    run.addArgs(usb);
    run.addArgs(extra);
    run.addArg("-drive");
    run.addPrefixedFileArg("if=mtd,format=raw,file=", flash_image);
    run.stdio = .inherit;
    run.has_side_effects = true;
    return run;
}

/// The 240 MHz build from scripts/build-qemu.sh if present, else
/// qemu-system-xtensa from PATH, else the newest one installed by ESP-IDF's
/// tools under ~/.espressif/tools/qemu-xtensa/<version>/qemu/bin.
pub fn findQemu(b: *std.Build) []const u8 {
    const name = "qemu-system-xtensa";
    const io = b.graph.io;

    const local = b.pathFromRoot("toolchain/qemu/bin/" ++ name);
    if (std.Io.Dir.cwd().access(io, local, .{})) |_| return local else |_| {}

    if (b.findProgram(&.{name}, &.{})) |path| return path else |_| {}

    const home = b.graph.environ_map.get("HOME") orelse return name;
    const tools = b.pathJoin(&.{ home, ".espressif", "tools", "qemu-xtensa" });
    var dir = std.Io.Dir.openDirAbsolute(io, tools, .{ .iterate = true }) catch return name;
    defer dir.close(io);

    var newest: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (newest == null or std.mem.order(u8, entry.name, newest.?) == .gt) newest = b.dupe(entry.name);
    }
    const version = newest orelse return name;
    return b.pathJoin(&.{ tools, version, "qemu", "bin", name });
}

/// What `addRunSteps` takes from the build so far.
pub const RunStepsWith = struct {
    a64_system_disk: std.Build.LazyPath,
    a64_target: std.Build.ResolvedTarget,
    board: Board,
    built: Image,
    cores: u32,
    disk_offset: u32,
    display_network: []const []const u8,
    esptool: []const u8,
    flash_disks: [flash_boards.len]std.Build.LazyPath,
    kernel: *std.Build.Step.Compile,
    logdebug: bool,
    memdebug: bool,
    mkfs: *std.Build.Step.Compile,
    mkstick: *std.Build.Step.Compile,
    network: []const []const u8,
    optimize: std.builtin.OptimizeMode,
    ovmf_code: []const u8,
    ovmf_vars: []const u8,
    p4_target: std.Build.ResolvedTarget,
    q35_network: []const []const u8,
    q35_speaker: []const []const u8,
    qemu: []const u8,
    ramimage: *std.Build.Step.Compile,
    ressize: *std.Build.Step.Compile,
    rv64_system_disk: std.Build.LazyPath,
    rv64_target: std.Build.ResolvedTarget,
    sdk: *std.Build.Module,
    selftest: bool,
    target: std.Build.ResolvedTarget,
    uart1: ?[]const u8,
    uefi_stub: *std.Build.Step.Compile,
    usb: []const []const u8,
    virt_monitor: []const []const u8,
    virt_network: []const []const u8,
    virt_speaker: []const []const u8,
    virt_ui: []const u8,
    x64_medium_bin: std.Build.LazyPath,
    x64_system_disk: std.Build.LazyPath,
    x64_target: std.Build.ResolvedTarget,
};

/// What `addRunSteps` hands on to the rest of the build.
pub const MadeRunSteps = struct {
    blank_work_disk: std.Build.LazyPath,
};

/// The steps that boot an emulated board - `qemu`, `emu`, `virt`,
/// `virt64`, `q35` and their display steps - and `stick`, the medium a
/// UEFI machine starts from.
pub fn addRunSteps(b: *std.Build, with: RunStepsWith) MadeRunSteps {
    const a64_system_disk = with.a64_system_disk;
    const a64_target = with.a64_target;
    const board = with.board;
    const built = with.built;
    const cores = with.cores;
    const disk_offset = with.disk_offset;
    const display_network = with.display_network;
    const esptool = with.esptool;
    const flash_disks = with.flash_disks;
    const kernel = with.kernel;
    const logdebug = with.logdebug;
    const memdebug = with.memdebug;
    const mkfs = with.mkfs;
    const mkstick = with.mkstick;
    const network = with.network;
    const optimize = with.optimize;
    const ovmf_code = with.ovmf_code;
    const ovmf_vars = with.ovmf_vars;
    const p4_target = with.p4_target;
    const q35_network = with.q35_network;
    const q35_speaker = with.q35_speaker;
    const qemu = with.qemu;
    const ramimage = with.ramimage;
    const ressize = with.ressize;
    const rv64_system_disk = with.rv64_system_disk;
    const rv64_target = with.rv64_target;
    const sdk = with.sdk;
    const selftest = with.selftest;
    const target = with.target;
    const uart1 = with.uart1;
    const uefi_stub = with.uefi_stub;
    const usb = with.usb;
    const virt_monitor = with.virt_monitor;
    const virt_network = with.virt_network;
    const virt_speaker = with.virt_speaker;
    const virt_ui = with.virt_ui;
    const x64_medium_bin = with.x64_medium_bin;
    const x64_system_disk = with.x64_system_disk;
    const x64_target = with.x64_target;

    // The emulator is a board of its own: the `qemu*` steps run its image,
    // with the same disk.
    const emulated = if (board == .qemu) built else addImage(b, esptool, ressize, addKernel(b, target, optimize, sdk, .qemu, disk_offset, cores, false, memdebug, logdebug), flashDisk(flash_disks, .qemu).?, disk_offset);
    const flash_image = emulated.flash_image;

    const run_qemu = qemuRun(b, qemu, flash_image, network, usb, qemuConsole(b, &.{"-nographic"}, uart1));
    b.step("qemu", "Boot the kernel in Espressif QEMU (quit with Ctrl-A X)").dependOn(&run_qemu.step);

    const run_display = qemuRun(b, qemu, flash_image, display_network, usb, qemuConsole(b, &.{ "-display", "sdl,show-cursor=off" }, uart1));
    b.step("qemu-display", "Boot in QEMU with its virtual display in an SDL window").dependOn(&run_display.step);

    // The same, but on a flash image that keeps what the kernel writes:
    // `qemu` runs with -snapshot and flash.bin is built afresh every time,
    // so neither survives a run. This one puts the current kernel at offset
    // 0 of a copy that stays, exactly as `zig build flash` does to the
    // board, and leaves the disk area (-Ddisk-offset on) alone.
    const disk_image = "zig-out/bin/qemu-flash.bin";
    const keep_disk = b.fmt(
        \\if [ ! -f "$0" ]; then
        \\  head -c 16777216 /dev/zero | tr '\000' '\377' > "$0"
        \\  dd if="$2" of="$0" bs={d} seek={d} conv=notrunc status=none
        \\fi
        \\dd if="$1" of="$0" conv=notrunc status=none
    , .{ disk_sector, disk_offset / disk_sector });
    const keep = b.addSystemCommand(&.{ "sh", "-c", keep_disk, disk_image });
    keep.addFileArg(emulated.image);
    keep.addFileArg(flashDisk(flash_disks, .qemu).?);
    keep.has_side_effects = true;
    const run_disk = qemuRunPath(b, qemu, .{ .cwd_relative = disk_image }, false, network, usb, qemuConsole(b, &.{"-nographic"}, uart1));
    run_disk.step.dependOn(&keep.step);
    b.step("qemu-disk", "Boot in QEMU on a flash image that keeps what is written to the disk").dependOn(&run_disk.step);

    // The ESP32-P4 in esp-emulator (scripts/fetch-esp-emu.sh), a board of
    // its own: the `emu` step runs its image on the boards' v1.x ROM.
    const p4_emulated = if (board == .esp32p4_emu) built else addP4Image(b, esptool, ramimage, addKernel(b, p4_target, optimize, sdk, .esp32p4_emu, disk_offset, cores, selftest, memdebug, logdebug), flashDisk(flash_disks, .esp32p4_emu).?, disk_offset);
    const run_emu = b.addSystemCommand(&.{
        b.pathFromRoot("toolchain/esp-emu/esp-emu"), "--chip",                                                 "esp32p4",
        "--rom",                                     b.pathFromRoot("toolchain/esp-emu/esp32p4_rev0_rom.elf"), "--psram-size",
        "32M",                                       "--net",                                                  "user",
        "--firmware",
    });
    run_emu.addFileArg(p4_emulated.flash_image);
    run_emu.stdio = .inherit;
    run_emu.has_side_effects = true;
    b.step("emu", "Boot the ESP32-P4 kernel in esp-emulator (quit with Ctrl-C)").dependOn(&run_emu.step);

    // The virt machines' work disk, blank: copied to work/ for each
    // machine the first time it runs (`keepWorkDisk`).
    const make_work_disk = b.addRunArtifact(mkfs);
    make_work_disk.addArg("--blank");
    const blank_work_disk = make_work_disk.addPrefixedOutputFileArg("--gpt=", "work.bin");
    make_work_disk.addArgs(&.{ b.fmt("--gpt-bytes={d}", .{virt_work_bytes}), "Work", "DH1" });

    // QEMU's RISC-V 64 virt machine, a board of its own: the `virt` step
    // boots its kernel under the OpenSBI QEMU brings (-bios default),
    // which enters it in supervisor mode at 0x80200000, and it starts
    // from its system disk, an NVMe SSD (`virtDisks`). A USB speaker
    // (`virtSpeaker`) is on its xHCI controller, as on every virt step.
    const virt_kernel = if (board == .qemu_virt) kernel else addKernel(b, rv64_target, optimize, sdk, .qemu_virt, disk_offset, cores, selftest, memdebug, logdebug);
    const virt_disks: VirtDisks = .{ .system = rv64_system_disk, .work = keepWorkDisk(b, blank_work_disk, "virt.bin") };
    const run_virt = b.addSystemCommand(&.{
        "qemu-system-riscv64", "-M", "virt",       "-m",    "512M",
        "-smp",                "4",  "-nographic", "-bios", "default",
    });
    run_virt.addArgs(&.{ "-device", "qemu-xhci" });
    run_virt.addArgs(virt_speaker);
    virt_disks.addTo(run_virt);
    run_virt.addArg("-kernel");
    run_virt.addArtifactArg(virt_kernel);
    run_virt.stdio = .inherit;
    run_virt.has_side_effects = true;
    b.step("virt", "Boot the RISC-V 64 kernel in QEMU's virt machine (quit with Ctrl-A X)").dependOn(&run_virt.step);

    // The same with what the board has around it: the virtio GPU, 1920x1080
    // as the VisionFive 2's HDMI, and USB with a keyboard, a tablet, whose
    // pointer stays where the host's is, and an Ethernet adapter on the
    // user network (`virtNetwork`). The window is QEMU's own
    // choice - GTK or SDL, VNC on :5900 where it has neither - and the
    // GPU's cursor is the host's pointer over it; the console stays on the
    // terminal. `virt-ramfb` has the ramfb instead, the machine's pointer
    // composed into the picture and the host's hidden over it.
    for ([_][3][]const u8{
        .{ "virtio-gpu-device,xres=1920,yres=1080", "virt-display", "virtio GPU" },
        .{ "ramfb", "virt-ramfb", "ramfb" },
    }) |display| {
        const run_virt_display = b.addSystemCommand(&.{
            "qemu-system-riscv64", "-M",        "virt",      "-m",      "512M",
            "-smp",                "4",         "-bios",     "default", "-display",
            virt_ui,               "-serial",   "mon:stdio", "-device", display[0],
            "-device",             "qemu-xhci", "-device",   "usb-kbd", "-device",
            "usb-tablet",
        });
        run_virt_display.addArgs(virt_network);
        run_virt_display.addArgs(virt_speaker);
        run_virt_display.addArgs(virt_monitor);
        virt_disks.addTo(run_virt_display);
        run_virt_display.addArg("-kernel");
        run_virt_display.addArtifactArg(virt_kernel);
        run_virt_display.stdio = .inherit;
        run_virt_display.has_side_effects = true;
        b.step(display[1], b.fmt("Boot QEMU's virt machine with its display ({s}), keyboard, tablet and network", .{display[2]})).dependOn(&run_virt_display.step);
    }

    // QEMU's AArch64 virt machine, a board of its own: the `virt64` step
    // boots its kernel as QEMU boots an arm64 Linux Image - at EL1, the
    // device tree in x0, PSCI by HVC - with Cortex-A76 cores and a GICv2
    // as the Pi's BCM2712 has them, everything below 4 GiB, and the same
    // two NVMe SSDs, its own system disk and work disk.
    const virt64_kernel = if (board == .qemu_virt_a64) built else addA64Image(b, addKernel(b, a64_target, optimize, sdk, .qemu_virt_a64, disk_offset, cores, selftest, memdebug, logdebug));
    const virt64_machine = [_][]const u8{
        "qemu-system-aarch64", "-M",         "virt,gic-version=2,highmem=off",
        "-cpu",                "cortex-a76", "-m",
        "512M",                "-smp",       "4",
    };
    const virt64_disks: VirtDisks = .{ .system = a64_system_disk, .work = keepWorkDisk(b, blank_work_disk, "virt64.bin") };
    const run_virt64 = b.addSystemCommand(&virt64_machine);
    run_virt64.addArgs(&.{ "-nographic", "-device", "qemu-xhci" });
    run_virt64.addArgs(virt_speaker);
    virt64_disks.addTo(run_virt64);
    run_virt64.addArg("-kernel");
    run_virt64.addFileArg(virt64_kernel.image);
    run_virt64.stdio = .inherit;
    run_virt64.has_side_effects = true;
    b.step("virt64", "Boot the AArch64 kernel in QEMU's virt machine (quit with Ctrl-A X)").dependOn(&run_virt64.step);

    // The same with what the board has around it, as `virt-display`: the
    // virtio GPU - or the ramfb, `virt64-ramfb` - USB with a keyboard, a
    // tablet and an Ethernet adapter, the console on the terminal.
    for ([_][3][]const u8{
        .{ "virtio-gpu-device,xres=1920,yres=1080", "virt64-display", "virtio GPU" },
        .{ "ramfb", "virt64-ramfb", "ramfb" },
    }) |display| {
        const run_virt64_display = b.addSystemCommand(&virt64_machine);
        run_virt64_display.addArgs(&.{
            "-display", virt_ui,    "-serial", "mon:stdio",
            "-device",  display[0], "-device", "qemu-xhci",
            "-device",  "usb-kbd",  "-device", "usb-tablet",
        });
        run_virt64_display.addArgs(virt_network);
        run_virt64_display.addArgs(virt_speaker);
        run_virt64_display.addArgs(virt_monitor);
        virt64_disks.addTo(run_virt64_display);
        run_virt64_display.addArg("-kernel");
        run_virt64_display.addFileArg(virt64_kernel.image);
        run_virt64_display.stdio = .inherit;
        run_virt64_display.has_side_effects = true;
        b.step(display[1], b.fmt("Boot QEMU's AArch64 virt machine with its display ({s}), keyboard, tablet and network", .{display[2]})).dependOn(&run_virt64_display.step);
    }

    // The machine with EL2 and EL3 (virtualization=on): the firmware is
    // QEMU's PSCI at EL3, reached by SMC, and every core comes in at EL2,
    // as on the CM5 - so the kernel's way down to EL1 runs.
    const run_virt64_el2 = b.addSystemCommand(&.{
        "qemu-system-aarch64", "-M",         "virt,gic-version=2,highmem=off,virtualization=on",
        "-cpu",                "cortex-a76", "-m",
        "512M",                "-smp",       "4",
        "-nographic",          "-device",    "qemu-xhci",
    });
    run_virt64_el2.addArgs(virt_speaker);
    virt64_disks.addTo(run_virt64_el2);
    run_virt64_el2.addArg("-kernel");
    run_virt64_el2.addFileArg(virt64_kernel.image);
    run_virt64_el2.stdio = .inherit;
    run_virt64_el2.has_side_effects = true;
    b.step("virt64-el2", "Boot the AArch64 kernel in QEMU's virt machine entered at EL2, PSCI by SMC").dependOn(&run_virt64_el2.step);

    // QEMU's q35 machine, the x86-64 board: its UEFI firmware starts
    // src/boot/uefi/stub.zig as BOOTX64.EFI off a boot partition the
    // emulator makes out of a directory, and the stub reads the kernel
    // from beside itself there. Only the kernel: the machine's system is
    // on its NVMe disk, and a disk image on the boot partition would be a
    // second system beside it - the stub reads one where there is one, for
    // a machine that has no disk of its own. The console is the machine's
    // first serial port, which the stub writes by hand and exec's raw port
    // drives afterwards, so the stub's lines and the kernel's first lines
    // come out of the same place.
    const q35_kernel = if (board == .qemu_q35) built else addX64Image(b, addKernel(b, x64_target, optimize, sdk, .qemu_q35, disk_offset, cores, selftest, memdebug, logdebug));
    const q35_boot = b.addWriteFiles();
    _ = q35_boot.addCopyFile(uefi_stub.getEmittedBin(), "EFI/BOOT/BOOTX64.EFI");
    _ = q35_boot.addCopyFile(q35_kernel.image, "kernel.bin");
    const q35_vars = keepFirmwareVars(b, ovmf_vars, "q35-vars.fd");
    // `-cpu max` is everything the emulator can do, which is what the
    // kernel is built against: the emulator's default core is older than
    // the architecture's second generation and has neither the instructions
    // the compiler emits for it nor 1 GiB pages.
    const q35_machine = [_][]const u8{ "qemu-system-x86_64", "-machine", "q35", "-cpu", "max", "-m", "512", "-smp", "8" };
    // The system disk and a work disk beside it, as the other two
    // emulated 64-bit machines have them: the firmware starts the kernel
    // off the boot partition, and dos starts from the system disk's DH0:.
    const q35_disks: VirtDisks = .{ .system = x64_system_disk, .work = keepWorkDisk(b, blank_work_disk, "q35.bin") };
    const run_q35 = b.addSystemCommand(&q35_machine);
    run_q35.addArgs(&.{ "-nographic", "-device", "qemu-xhci" });
    run_q35.addArgs(q35_network);
    run_q35.addArgs(q35_speaker);
    q35_disks.addTo(run_q35);
    run_q35.addArgs(&.{ "-drive", b.fmt("if=pflash,format=raw,readonly=on,file={s}", .{ovmf_code}) });
    run_q35.addArgs(&.{ "-drive", b.fmt("if=pflash,format=raw,file={s}", .{q35_vars.path}) });
    // The boot partition last, and `file=` after `format=raw` so that the
    // directory's path is the end of the argument.
    run_q35.addArg("-drive");
    run_q35.addPrefixedDirectoryArg("format=raw,file=fat:rw:", q35_boot.getDirectory());
    run_q35.step.dependOn(q35_vars.step);
    run_q35.stdio = .inherit;
    run_q35.has_side_effects = true;
    b.step("q35", "Boot the x86-64 kernel in QEMU's q35 machine under UEFI firmware (quit with Ctrl-A X)").dependOn(&run_q35.step);

    // `stick` - the medium a machine whose firmware is UEFI starts from,
    // into release/stick-<board>.img, to be written to a USB stick with
    // one `dd`. Two partitions: the EFI System partition with what the
    // firmware and the loader read - the loader under the one name a
    // firmware looks for, and the kernel beside it - and a PowerOS
    // container with the system on a posfs partition. The kernel starts
    // the system on the disk its loader was read from, so a machine
    // started from the stick runs the stick's system, whatever a disk of
    // its own holds: one stick carries a whole machine, what is written
    // on it stays, and `C:Install` puts a system on a disk of the
    // machine's own from it.
    const stick_step = b.step("stick", "Make the boot medium for -Dboard= (UEFI machines): release/stick-<board>.img");
    const stick_size = b.option(u64, "stick-size", "How many mebibytes the `stick` step's medium is (default: 320, the least a FAT32 volume of 4 KiB clusters can be with room over)");
    const stick_ram = b.option(bool, "stick-ram", "The `stick` step's medium carries the system as a disk image beside the kernel too, which the loader reads into RAM: for a machine whose USB controller the system does not drive (default: false)") orelse false;
    if (chipOf(board) != .x64uefi) {
        stick_step.dependOn(&b.addFail(
            "stick: this board's firmware does not read a partition. It is for a machine started by UEFI: -Dboard=qemu_q35.",
        ).step);
    } else {
        const make_stick = b.addRunArtifact(mkstick);
        const stick_name = b.fmt("stick-{s}.img", .{@tagName(board)});
        const stick_image = make_stick.addPrefixedOutputFileArg("--into=", stick_name);
        // The medium is written into the build's cache and put in
        // release/ afterwards, so the report is told where it will be
        // found: a line that writes a stick is one that can be run.
        make_stick.addArg(b.fmt("--as=release/{s}", .{stick_name}));
        if (stick_size) |mib| make_stick.addArg(b.fmt("--size={d}", .{mib}));
        // The one name a UEFI firmware reads off a boot partition, and
        // the two the loader then reads from beside itself.
        make_stick.addPrefixedFileArg("EFI/BOOT/BOOTX64.EFI=", uefi_stub.getEmittedBin());
        make_stick.addPrefixedFileArg("kernel.bin=", built.image);
        // The system, as the second partition: the container of the
        // disk the virt machine runs on, with every file a 64-bit
        // machine's system has.
        make_stick.addPrefixedFileArg("--system=", x64_system_disk);
        // With -Dstick-ram the system's disk image goes beside the
        // kernel as well: the loader reads it into RAM and the machine
        // runs on that, without a USB driver of this system's having to
        // find the stick - for a machine whose USB controller it does
        // not drive. Nothing written to that system stays.
        if (stick_ram) make_stick.addPrefixedFileArg(b.fmt("{s}=", .{ramDiskName(.x64uefi)}), x64_medium_bin);
        // What the tool says of the medium it made. A run the build
        // caches has its standard output sent nowhere, so the report is
        // captured and read back out by a step of its own, after the
        // medium is in release/ - whether the run happened this time or
        // the cache answered for it.
        const stick_report = make_stick.captureStdOut(.{ .basename = "report.txt" });
        const stick_put = b.addInstallFileWithDir(stick_image, release_dir, stick_name);
        // Which kernel is on it, which the image itself cannot be looked
        // at for: a medium written from a quiet build says nothing on a
        // machine whose boot stops, and looks like a machine that stops
        // earlier than it does.
        const stick_tail = if (logdebug)
            "\nThe kernel on it names every module as the cold start starts it, and\nsays so on the screen: `(-Dlogdebug)` in the lines before the cores.\n"
        else
            "\nThe kernel on it is a quiet one. Build it with -Dlogdebug to have it\nname every module as the cold start starts it, which is how a boot that\nstops somewhere is read.\n";
        stick_step.dependOn(&addReport(b, stick_report, stick_tail, &stick_put.step).step);
    }

    // The same with the machine's window and what the board has around
    // it, as `virt-display` and `virt64-display`: USB with a keyboard, a
    // tablet, whose pointer stays where the host's is; the console stays
    // on the terminal. Its Ethernet is the card both q35 steps have
    // (`q35Network`), and its sound the controller they both have
    // (`q35Speaker`).
    //
    // `q35-display` draws on the framebuffer the firmware lights, which
    // on this machine is its emulated VGA; `q35-virtio` gives it QEMU's
    // virtio GPU on PCI instead, which the board lists before the
    // firmware's framebuffer, and the same driver draws on that over
    // virtio's PCI transport. Both at 1920x1080, as the other emulated
    // machines' windows are. Both have the machine's own audio controller,
    // which rta-hda drives (`q35Speaker`).
    for ([_][3][]const u8{
        .{ "VGA,xres=1920,yres=1080", "q35-display", "the firmware's framebuffer" },
        .{ "virtio-gpu-pci,xres=1920,yres=1080", "q35-virtio", "virtio GPU" },
    }) |display| {
        const run_q35_display = b.addSystemCommand(&q35_machine);
        run_q35_display.addArgs(&.{
            "-display", virt_ui,      "-serial", "mon:stdio",
            "-device",  "qemu-xhci",  "-device", "usb-kbd",
            "-device",  "usb-tablet",
        });
        // The machine's own display goes and the one named here takes its
        // place. Even for the VGA that is what gives it a size: the
        // display a machine brings with it takes none, and `-global
        // VGA.xres=` does not reach it ("not used"), so the firmware
        // would light the 1280x800 its EDID offers by default - smaller
        // than every other machine's window here. Named as a device it
        // takes the size, and the firmware lights that.
        run_q35_display.addArgs(&.{ "-vga", "none", "-device", display[0] });
        run_q35_display.addArgs(q35_network);
        run_q35_display.addArgs(q35_speaker);
        run_q35_display.addArgs(virt_monitor);
        q35_disks.addTo(run_q35_display);
        run_q35_display.addArgs(&.{ "-drive", b.fmt("if=pflash,format=raw,readonly=on,file={s}", .{ovmf_code}) });
        run_q35_display.addArgs(&.{ "-drive", b.fmt("if=pflash,format=raw,file={s}", .{q35_vars.path}) });
        run_q35_display.addArg("-drive");
        run_q35_display.addPrefixedDirectoryArg("format=raw,file=fat:rw:", q35_boot.getDirectory());
        run_q35_display.step.dependOn(q35_vars.step);
        run_q35_display.stdio = .inherit;
        run_q35_display.has_side_effects = true;
        b.step(display[1], b.fmt("Boot QEMU's q35 machine with its display ({s}), keyboard, tablet and network", .{display[2]})).dependOn(&run_q35_display.step);
    }
    return .{
        .blank_work_disk = blank_work_disk,
    };
}
