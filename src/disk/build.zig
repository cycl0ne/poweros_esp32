// SPDX-License-Identifier: MIT
//! The disk's own programs as a Zig package: the commands in C:, the test
//! programs in C:test, the libraries, devices and handlers loaded from
//! LIBS:, DEVS: and HANDLERS:, the classes in SYS:classes, and the scripts
//! in S:. Every one of them is
//! built against the SDK package alone.
//!
//! What it builds is listed here (`programs`, `files`), and each is handed
//! out under its place on the disk - `c/list`, `devs/sdcard.device`,
//! `s/startup-sequence` - as a named lazy path, so the system's build can
//! put them on its disk image without knowing how they are made. Built on
//! its own, the load files land in `zig-out/bin`.

const std = @import("std");
const poweros_sdk = @import("poweros_sdk");

/// Something built for the disk: its place there, its root source file,
/// and the name its load file is known by.
pub const Program = struct { disk: []const u8, source: []const u8, name: []const u8 };

/// Something copied onto the disk as it is.
pub const File = struct { disk: []const u8, source: []const u8 };

/// What a command is for decides which directory it lives in, and the one
/// name serves for both the source tree and the disk: `c` is what the
/// system is used with, `c/test` the programs that exercise a device or a
/// library and print what happened, `c/net` the network's tools.
const commands = [_][]const u8{
    "type",         "dir",       "delete",   "makedir",       "rename",
    "avail",        "assign",    "version",  "addbuffers",    "which",
    "list",         "format",    "protect",  "changetaskpri", "wait",
    "info",         "platform",  "copy",     "rdb",           "i2c",
    "backlight",    "rtg",       "showinfo", "setmap",        "mount",
    "showconfig",   "date",      "setdate",  "setprefs",      "fixfonts",
    "adddatatypes", "listfonts", "log",      "requestfile",   "requestchoice",
    "diskchange",   "modbus",    "more",     "relabel",       "loadanvil",
    "iconx",
};
const tests = [_][]const u8{
    "hello",       "echoargs",   "testlib",     "gfx",     "anim",
    "intuition",   "console",    "keyboard",    "touch",   "input",
    "lines",       "nyan",       "plasma",      "audio",   "fonts",
    "screens",     "layout",     "classes",     "gadgets", "listview",
    "diskfont",    "colorwheel", "tapedeck",    "pointer", "crypto",
    "bsdsocktest", "asl",        "settings",    "iff",     "datatypes",
    "shapes",      "styles",     "motion",      "widgets", "modbusserver",
    "cores",       "scroll",     "listbrowser", "notify",  "icon",
    "launch",      "drag",       "tap",         "app",
};
const net_tools = [_][]const u8{ "net", "udp", "tcp", "addnetinterface", "remnetinterface", "resolve", "netstatus", "online", "offline", "ping", "timesync", "httpget", "packetcapture", "shellserver", "wireless", "hostname", "ssh", "scp", "filter" };

/// Programs with windows, in SYS:Programs: started by their full name or
/// from a shell there, not on the command path.
const window_programs = [_]Program{
    .{ .disk = "programs/FontView", .source = "programs/fontview/fontview.zig", .name = "fontview" },
    .{ .disk = "programs/MultiView", .source = "programs/multiview/multiview.zig", .name = "multiview" },
    .{ .disk = "programs/Battery", .source = "programs/battery/battery.zig", .name = "battery" },
    .{ .disk = "programs/Prefs", .source = "programs/prefs/prefs.zig", .name = "prefs" },
    .{ .disk = "programs/CPULoad", .source = "programs/cpuload/cpuload.zig", .name = "cpuload" },
    .{ .disk = "programs/Notepad", .source = "programs/notepad/notepad.zig", .name = "notepad" },
    .{ .disk = "System/Shell", .source = "system/shell/shell.zig", .name = "shell" },
};

/// Modules on the disk: built exactly as a command is. What makes one a
/// module is the ROM tag in it: ramlib finds a library's or a device's
/// after LoadSeg and hands it to InitResident, dos finds a handler's when
/// the device it serves is first used. Each goes where its kind is looked
/// for - LIBS:, DEVS:, HANDLERS: - and a class library in classes/, which
/// the startup-sequence adds to LIBS:.
const modules = [_]Program{
    .{ .disk = "libs/hello.library", .source = "libs/hello/hello.zig", .name = "hello.library" },
    .{ .disk = "libs/bsdsocket.library", .source = "libs/bsdsocket/bsdsocket.zig", .name = "bsdsocket.library" },
    .{ .disk = "libs/crypto.library", .source = "libs/crypto/crypto.zig", .name = "crypto.library" },
    .{ .disk = "libs/rdb.library", .source = "libs/rdb/rdb.zig", .name = "rdb.library" },
    .{ .disk = "libs/modbus.library", .source = "libs/modbus/modbus.zig", .name = "modbus.library" },
    .{ .disk = "libs/filter.library", .source = "libs/filter/filter.zig", .name = "filter.library" },
    .{ .disk = "libs/icon.library", .source = "libs/icon/icon.zig", .name = "icon.library" },
    .{ .disk = "libs/anvil.library", .source = "libs/anvil/anvil.zig", .name = "anvil.library" },
    .{ .disk = "libs/tls.library", .source = "libs/tls/tls.zig", .name = "tls.library" },
    .{ .disk = "libs/diskfont.library", .source = "libs/diskfont/diskfont.zig", .name = "diskfont.library" },
    .{ .disk = "libs/truetype.library", .source = "libs/truetype/truetype.zig", .name = "truetype.library" },
    .{ .disk = "libs/asl.library", .source = "libs/asl/asl.zig", .name = "asl.library" },
    .{ .disk = "libs/iffparse.library", .source = "libs/iffparse/iffparse.zig", .name = "iffparse.library" },
    .{ .disk = "libs/datatypes.library", .source = "libs/datatypes/datatypes.zig", .name = "datatypes.library" },
    .{ .disk = "classes/gadgets/hello.gadget", .source = "classes/gadgets/hello/hello.zig", .name = "hello.gadget" },
    .{ .disk = "classes/gadgets/checkbox.gadget", .source = "classes/gadgets/checkbox/checkbox.zig", .name = "checkbox.gadget" },
    .{ .disk = "classes/gadgets/cycle.gadget", .source = "classes/gadgets/cycle/cycle.zig", .name = "cycle.gadget" },
    .{ .disk = "classes/gadgets/radiobutton.gadget", .source = "classes/gadgets/radiobutton/radiobutton.zig", .name = "radiobutton.gadget" },
    .{ .disk = "classes/gadgets/string.gadget", .source = "classes/gadgets/string/string.zig", .name = "string.gadget" },
    .{ .disk = "classes/gadgets/text.gadget", .source = "classes/gadgets/text/text.zig", .name = "text.gadget" },
    .{ .disk = "classes/gadgets/slider.gadget", .source = "classes/gadgets/slider/slider.zig", .name = "slider.gadget" },
    .{ .disk = "classes/gadgets/scroller.gadget", .source = "classes/gadgets/scroller/scroller.zig", .name = "scroller.gadget" },
    .{ .disk = "classes/gadgets/listview.gadget", .source = "classes/gadgets/listview/listview.zig", .name = "listview.gadget" },
    .{ .disk = "classes/gadgets/palette.gadget", .source = "classes/gadgets/palette/palette.zig", .name = "palette.gadget" },
    .{ .disk = "classes/gadgets/colorwheel.gadget", .source = "classes/gadgets/colorwheel/colorwheel.zig", .name = "colorwheel.gadget" },
    .{ .disk = "classes/gadgets/gradientslider.gadget", .source = "classes/gadgets/gradientslider/gradientslider.zig", .name = "gradientslider.gadget" },
    .{ .disk = "classes/gadgets/tapedeck.gadget", .source = "classes/gadgets/tapedeck/tapedeck.zig", .name = "tapedeck.gadget" },
    .{ .disk = "classes/gadgets/fuelgauge.gadget", .source = "classes/gadgets/fuelgauge/fuelgauge.zig", .name = "fuelgauge.gadget" },
    .{ .disk = "classes/gadgets/integer.gadget", .source = "classes/gadgets/integer/integer.zig", .name = "integer.gadget" },
    .{ .disk = "classes/gadgets/chooser.gadget", .source = "classes/gadgets/chooser/chooser.zig", .name = "chooser.gadget" },
    .{ .disk = "classes/gadgets/page.gadget", .source = "classes/gadgets/page/page.zig", .name = "page.gadget" },
    .{ .disk = "classes/gadgets/clicktab.gadget", .source = "classes/gadgets/clicktab/clicktab.zig", .name = "clicktab.gadget" },
    .{ .disk = "classes/gadgets/getfile.gadget", .source = "classes/gadgets/getfile/getfile.zig", .name = "getfile.gadget" },
    .{ .disk = "classes/gadgets/getfont.gadget", .source = "classes/gadgets/getfont/getfont.zig", .name = "getfont.gadget" },
    .{ .disk = "classes/gadgets/spinner.gadget", .source = "classes/gadgets/spinner/spinner.zig", .name = "spinner.gadget" },
    .{ .disk = "classes/gadgets/meter.gadget", .source = "classes/gadgets/meter/meter.zig", .name = "meter.gadget" },
    .{ .disk = "classes/gadgets/arc.gadget", .source = "classes/gadgets/arc/arc.zig", .name = "arc.gadget" },
    .{ .disk = "classes/gadgets/roller.gadget", .source = "classes/gadgets/roller/roller.zig", .name = "roller.gadget" },
    .{ .disk = "classes/gadgets/calendar.gadget", .source = "classes/gadgets/calendar/calendar.zig", .name = "calendar.gadget" },
    .{ .disk = "classes/gadgets/canvas.gadget", .source = "classes/gadgets/canvas/canvas.zig", .name = "canvas.gadget" },
    .{ .disk = "classes/gadgets/qrcode.gadget", .source = "classes/gadgets/qrcode/qrcode.zig", .name = "qrcode.gadget" },
    .{ .disk = "classes/gadgets/barcode.gadget", .source = "classes/gadgets/barcode/barcode.zig", .name = "barcode.gadget" },
    .{ .disk = "classes/gadgets/chart.gadget", .source = "classes/gadgets/chart/chart.zig", .name = "chart.gadget" },
    .{ .disk = "classes/gadgets/keyboard.gadget", .source = "classes/gadgets/keyboard/keyboard.zig", .name = "keyboard.gadget" },
    .{ .disk = "classes/gadgets/textedit.gadget", .source = "classes/gadgets/textedit/textedit.zig", .name = "textedit.gadget" },
    .{ .disk = "classes/gadgets/scrollgroup.gadget", .source = "classes/gadgets/scrollgroup/scrollgroup.zig", .name = "scrollgroup.gadget" },
    .{ .disk = "classes/gadgets/listbrowser.gadget", .source = "classes/gadgets/listbrowser/listbrowser.zig", .name = "listbrowser.gadget" },
    .{ .disk = "classes/datatypes/picture.datatype", .source = "classes/datatypes/picture/picture.zig", .name = "picture.datatype" },
    .{ .disk = "classes/datatypes/animation.datatype", .source = "classes/datatypes/animation/animation.zig", .name = "animation.datatype" },
    .{ .disk = "classes/datatypes/bmp.datatype", .source = "classes/datatypes/bmp/bmp.zig", .name = "bmp.datatype" },
    .{ .disk = "classes/datatypes/ilbm.datatype", .source = "classes/datatypes/ilbm/ilbm.zig", .name = "ilbm.datatype" },
    .{ .disk = "classes/datatypes/png.datatype", .source = "classes/datatypes/png/png.zig", .name = "png.datatype" },
    .{ .disk = "classes/datatypes/gif.datatype", .source = "classes/datatypes/gif/gif.zig", .name = "gif.datatype" },
    .{ .disk = "classes/datatypes/gifanim.datatype", .source = "classes/datatypes/gif/gifanim.zig", .name = "gifanim.datatype" },
    .{ .disk = "classes/datatypes/lottie.datatype", .source = "classes/datatypes/lottie/lottie.zig", .name = "lottie.datatype" },
    .{ .disk = "classes/datatypes/jpeg.datatype", .source = "classes/datatypes/jpeg/jpeg.zig", .name = "jpeg.datatype" },
    .{ .disk = "classes/datatypes/text.datatype", .source = "classes/datatypes/text/text.zig", .name = "text.datatype" },
    .{ .disk = "classes/datatypes/ascii.datatype", .source = "classes/datatypes/ascii/ascii.zig", .name = "ascii.datatype" },
    .{ .disk = "classes/datatypes/markdown.datatype", .source = "classes/datatypes/markdown/markdown.zig", .name = "markdown.datatype" },
    .{ .disk = "devs/sdcard.device", .source = "devs/sdcard/sdcard.zig", .name = "sdcard.device" },
    .{ .disk = "devs/rs485.device", .source = "devs/rs485/rs485.zig", .name = "rs485.device" },
    .{ .disk = "devs/networks/openeth.device", .source = "devs/networks/openeth/openeth.zig", .name = "openeth.device" },
    .{ .disk = "devs/networks/slip.device", .source = "devs/networks/slip/slip.zig", .name = "slip.device" },
    .{ .disk = "devs/telnet.device", .source = "devs/telnet/telnet.zig", .name = "telnet.device" },
    .{ .disk = "devs/ssh.device", .source = "devs/ssh/ssh.zig", .name = "ssh.device" },
    .{ .disk = "devs/clipboard.device", .source = "devs/clipboard/clipboard.zig", .name = "clipboard.device" },
    .{ .disk = "devs/handlers/fat-handler", .source = "devs/handlers/fat/fat.zig", .name = "fat-handler" },
};

pub const programs: []const Program = blk: {
    var list: [commands.len + tests.len + net_tools.len + window_programs.len + modules.len]Program = undefined;
    var n: usize = 0;
    for (commands) |name| {
        list[n] = .{ .disk = "c/" ++ name, .source = "c/" ++ name ++ "/" ++ name ++ ".zig", .name = name };
        n += 1;
    }
    for (tests) |name| {
        list[n] = .{ .disk = "c/test/" ++ name, .source = "c/test/" ++ name ++ "/" ++ name ++ ".zig", .name = name };
        n += 1;
    }
    for (net_tools) |name| {
        list[n] = .{ .disk = "c/net/" ++ name, .source = "c/net/" ++ name ++ "/" ++ name ++ ".zig", .name = name };
        n += 1;
    }
    for (window_programs) |program| {
        list[n] = program;
        n += 1;
    }
    for (modules) |module| {
        list[n] = module;
        n += 1;
    }
    const done = list;
    break :blk &done;
};

/// The radio's device: built only when the vendor libraries it links are
/// at hand (scripts/fetch-wifi.sh), given to this package as `-Dwifi=`.
pub const wifi_device: Program = .{ .disk = "devs/networks/wifi.device", .source = "devs/networks/wifi/wifi.zig", .name = "wifi.device" };

/// The vendor archives wifi.device links, and the chip ROM's scripts.
pub const wifi_archives = [_][]const u8{ "libcore.a", "libnet80211.a", "libpp.a", "libphy.a" };
pub const wifi_rom_scripts = [_][]const u8{ "esp32s3.rom.ld", "esp32s3.rom.libc.ld", "esp32s3.rom.libgcc.ld", "esp32s3.rom.api.ld" };

/// The scripts in S:, DEVS:MountList for Mount to read, the interface
/// files and the settings in ENVARC:.
pub const files = [_]File{
    .{ .disk = "s/startup-sequence", .source = "s/startup-sequence" },
    .{ .disk = "s/shell-startup", .source = "s/shell-startup" },
    .{ .disk = "s/network-startup", .source = "s/network-startup" },
    .{ .disk = "devs/mountlist", .source = "devs/mountlist" },
    .{ .disk = "devs/datatypes/Directory", .source = "devs/datatypes/Directory" },
    .{ .disk = "devs/datatypes/ILBM", .source = "devs/datatypes/ILBM" },
    .{ .disk = "devs/datatypes/BMP", .source = "devs/datatypes/BMP" },
    .{ .disk = "devs/datatypes/PNG", .source = "devs/datatypes/PNG" },
    .{ .disk = "devs/datatypes/GIF", .source = "devs/datatypes/GIF" },
    .{ .disk = "devs/datatypes/GIFAnim", .source = "devs/datatypes/GIFAnim" },
    .{ .disk = "devs/datatypes/Lottie", .source = "devs/datatypes/Lottie" },
    .{ .disk = "devs/datatypes/JPEG", .source = "devs/datatypes/JPEG" },
    .{ .disk = "devs/datatypes/Markdown", .source = "devs/datatypes/Markdown" },
    .{ .disk = "devs/datatypes/FTXT", .source = "devs/datatypes/FTXT" },
    .{ .disk = "devs/datatypes/8SVX", .source = "devs/datatypes/8SVX" },
    .{ .disk = "devs/datatypes/ANIM", .source = "devs/datatypes/ANIM" },
    .{ .disk = "devs/datatypes/ASCII", .source = "devs/datatypes/ASCII" },
    .{ .disk = "devs/datatypes/Binary", .source = "devs/datatypes/Binary" },
    .{ .disk = "devs/NetInterfaces/ETH0", .source = "devs/NetInterfaces/ETH0" },
    .{ .disk = "devs/NetInterfaces/WLAN0", .source = "devs/NetInterfaces/WLAN0" },
    // ENVARC: as a fresh disk has it: what each settings file says, and
    // its value to start with.
    .{ .disk = "prefs/env-archive/Sys/timezone", .source = "prefs/env-archive/Sys/timezone" },
    .{ .disk = "prefs/env-archive/Sys/font.prefs", .source = "prefs/env-archive/Sys/font.prefs" },
    .{ .disk = "prefs/env-archive/Sys/style.prefs", .source = "prefs/env-archive/Sys/style.prefs" },
    .{ .disk = "prefs/env-archive/Sys/intuition.prefs", .source = "prefs/env-archive/Sys/intuition.prefs" },
    .{ .disk = "prefs/env-archive/Sys/palette.prefs", .source = "prefs/env-archive/Sys/palette.prefs" },
    .{ .disk = "prefs/env-archive/Sys/anvil.prefs", .source = "prefs/env-archive/Sys/anvil.prefs" },
    // The looks the preferences editor offers, a style file each.
    .{ .disk = "prefs/presets/styles/Classic.prefs", .source = "prefs/presets/styles/Classic.prefs" },
    .{ .disk = "prefs/presets/styles/Rounded.prefs", .source = "prefs/presets/styles/Rounded.prefs" },
    .{ .disk = "prefs/presets/styles/Flat.prefs", .source = "prefs/presets/styles/Flat.prefs" },
    .{ .disk = "prefs/presets/styles/Soft.prefs", .source = "prefs/presets/styles/Soft.prefs" },
    .{ .disk = "prefs/presets/styles/Contrast.prefs", .source = "prefs/presets/styles/Contrast.prefs" },
    .{ .disk = "prefs/env-archive/Sys/net/timeserver", .source = "prefs/env-archive/Sys/net/timeserver" },
    .{ .disk = "prefs/env-archive/Sys/net/hosts", .source = "prefs/env-archive/Sys/net/hosts" },
    .{ .disk = "prefs/env-archive/Sys/net/hostname", .source = "prefs/env-archive/Sys/net/hostname" },
    .{ .disk = "prefs/env-archive/Sys/net/nameservers", .source = "prefs/env-archive/Sys/net/nameservers" },
    // SYS:Tests/datatypes - a small file of every format the datatype
    // classes read, so that each can be opened on the machine itself.
    .{ .disk = "tests/datatypes/Colours.png", .source = "tests/datatypes/Colours.png" },
    .{ .disk = "tests/datatypes/Disc.png", .source = "tests/datatypes/Disc.png" },
    .{ .disk = "tests/datatypes/Palette.png", .source = "tests/datatypes/Palette.png" },
    .{ .disk = "tests/datatypes/Grey.png", .source = "tests/datatypes/Grey.png" },
    .{ .disk = "tests/datatypes/Mono.png", .source = "tests/datatypes/Mono.png" },
    .{ .disk = "tests/datatypes/Interlaced.png", .source = "tests/datatypes/Interlaced.png" },
    .{ .disk = "tests/datatypes/Shapes.gif", .source = "tests/datatypes/Shapes.gif" },
    .{ .disk = "tests/datatypes/Weave.gif", .source = "tests/datatypes/Weave.gif" },
    .{ .disk = "tests/datatypes/Bounce.gif", .source = "tests/datatypes/Bounce.gif" },
    .{ .disk = "tests/datatypes/Spinner.json", .source = "tests/datatypes/Spinner.json" },
    .{ .disk = "tests/datatypes/Garden.jpg", .source = "tests/datatypes/Garden.jpg" },
    .{ .disk = "tests/datatypes/Grey.jpg", .source = "tests/datatypes/Grey.jpg" },
    .{ .disk = "tests/datatypes/Tiles.bmp", .source = "tests/datatypes/Tiles.bmp" },
    .{ .disk = "tests/datatypes/Runs.bmp", .source = "tests/datatypes/Runs.bmp" },
    .{ .disk = "tests/datatypes/Nibbles.bmp", .source = "tests/datatypes/Nibbles.bmp" },
    .{ .disk = "tests/datatypes/Deep.bmp", .source = "tests/datatypes/Deep.bmp" },
    .{ .disk = "tests/datatypes/Bars.ilbm", .source = "tests/datatypes/Bars.ilbm" },
    .{ .disk = "tests/datatypes/Deep.ilbm", .source = "tests/datatypes/Deep.ilbm" },
    .{ .disk = "tests/datatypes/Ham.ilbm", .source = "tests/datatypes/Ham.ilbm" },
    .{ .disk = "tests/datatypes/Reading.md", .source = "tests/datatypes/Reading.md" },
};

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseSafe)") orelse .ReleaseSafe;
    const wifi = b.option([]const u8, "wifi", "The directory with the radio's vendor libraries (scripts/fetch-wifi.sh); without it there is no wifi.device");
    const sdk = b.dependency("poweros_sdk", .{});
    if (wifi) |dir| {
        var archives: [wifi_archives.len]std.Build.LazyPath = undefined;
        for (wifi_archives, 0..) |name, i| archives[i] = .{ .cwd_relative = b.pathJoin(&.{ dir, name }) };
        var scripts: [wifi_rom_scripts.len]std.Build.LazyPath = undefined;
        for (wifi_rom_scripts, 0..) |name, i| scripts[i] = .{ .cwd_relative = b.pathJoin(&.{ dir, name }) };
        const seg = poweros_sdk.addProgram(b, sdk, .{
            .name = wifi_device.name,
            .root = b.path(wifi_device.source),
            .optimize = optimize,
            .archives = b.allocator.dupe(std.Build.LazyPath, &archives) catch @panic("OOM"),
            .rom_scripts = b.allocator.dupe(std.Build.LazyPath, &scripts) catch @panic("OOM"),
        });
        b.addNamedLazyPath(wifi_device.disk, seg);
        b.getInstallStep().dependOn(&b.addInstallBinFile(seg, "wifi.device.seg").step);
    }
    for (programs) |program| {
        const seg = poweros_sdk.addProgram(b, sdk, .{ .name = program.name, .root = b.path(program.source), .optimize = optimize });
        b.addNamedLazyPath(program.disk, seg);
        b.getInstallStep().dependOn(&b.addInstallBinFile(seg, b.fmt("{s}.seg", .{program.name})).step);
    }
    for (files) |file| b.addNamedLazyPath(file.disk, b.path(file.source));
}
