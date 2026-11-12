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
/// the name its load file is known by, the inner modules it is built
/// with (`inner_modules`), and the catalog descriptor its strings are made
/// from - imported as `strings`, or as `strings_as` names it, its catalog
/// named after its place unless `catalog` names it (`sys/` for the
/// system's own modules). A module the disk's host tests take in beside
/// anvil.library, whose strings they import as `strings`, imports its
/// own under a name of its own.
pub const Program = struct { disk: []const u8, source: []const u8, name: []const u8, imports: []const []const u8 = &.{}, strings: ?[]const u8 = null, strings_as: []const u8 = "strings", catalog: ?[]const u8 = null };

/// A translation of a program's strings: its place on the disk, in
/// LOCALE:Catalogs/<language>/, the descriptor and the translation it is
/// made from, and the catalog's name. One that is `wide` goes on the
/// 64-bit machines' disks only: its language is written in a font only
/// they have.
pub const Catalog = struct { disk: []const u8, descriptor: []const u8, translation: []const u8, name: []const u8, wide: bool = false };

/// The programs' translations.
pub const catalogs = [_]Catalog{
    .{ .disk = "locale/Catalogs/deutsch/c/test/locale.catalog", .descriptor = "c/test/locale/locale.cd", .translation = "c/test/locale/catalogs/deutsch.ct", .name = "c/test/locale.catalog" },
    .{ .disk = "locale/Catalogs/deutsch/programs/Notepad.catalog", .descriptor = "programs/notepad/notepad.cd", .translation = "programs/notepad/catalogs/deutsch.ct", .name = "programs/Notepad.catalog" },
    .{ .disk = "locale/Catalogs/deutsch/programs/Sheet.catalog", .descriptor = "programs/sheet/sheet.cd", .translation = "programs/sheet/catalogs/deutsch.ct", .name = "programs/Sheet.catalog" },
    .{ .disk = "locale/Catalogs/deutsch/programs/Player.catalog", .descriptor = "programs/player/player.cd", .translation = "programs/player/catalogs/deutsch.ct", .name = "programs/Player.catalog" },
    .{ .disk = "locale/Catalogs/deutsch/programs/Movie.catalog", .descriptor = "programs/movie/movie.cd", .translation = "programs/movie/catalogs/deutsch.ct", .name = "programs/Movie.catalog" },
    .{ .disk = "locale/Catalogs/deutsch/System/Clock.catalog", .descriptor = "system/clock/clock.cd", .translation = "system/clock/catalogs/deutsch.ct", .name = "System/Clock.catalog" },
    .{ .disk = "locale/Catalogs/deutsch/sys/anvil.catalog", .descriptor = "libs/anvil/anvil.cd", .translation = "libs/anvil/catalogs/deutsch.ct", .name = "sys/anvil.catalog" },
    .{ .disk = "locale/Catalogs/deutsch/sys/http.catalog", .descriptor = "libs/http/http.cd", .translation = "libs/http/catalogs/deutsch.ct", .name = "sys/http.catalog" },
    .{ .disk = "locale/Catalogs/hindi/c/test/locale.catalog", .descriptor = "c/test/locale/locale.cd", .translation = "c/test/locale/catalogs/hindi.ct", .name = "c/test/locale.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/hindi/programs/Notepad.catalog", .descriptor = "programs/notepad/notepad.cd", .translation = "programs/notepad/catalogs/hindi.ct", .name = "programs/Notepad.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/hindi/programs/Sheet.catalog", .descriptor = "programs/sheet/sheet.cd", .translation = "programs/sheet/catalogs/hindi.ct", .name = "programs/Sheet.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/hindi/programs/Player.catalog", .descriptor = "programs/player/player.cd", .translation = "programs/player/catalogs/hindi.ct", .name = "programs/Player.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/hindi/programs/Movie.catalog", .descriptor = "programs/movie/movie.cd", .translation = "programs/movie/catalogs/hindi.ct", .name = "programs/Movie.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/hindi/System/Clock.catalog", .descriptor = "system/clock/clock.cd", .translation = "system/clock/catalogs/hindi.ct", .name = "System/Clock.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/hindi/sys/anvil.catalog", .descriptor = "libs/anvil/anvil.cd", .translation = "libs/anvil/catalogs/hindi.ct", .name = "sys/anvil.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/hindi/sys/http.catalog", .descriptor = "libs/http/http.cd", .translation = "libs/http/catalogs/hindi.ct", .name = "sys/http.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/nihongo/c/test/locale.catalog", .descriptor = "c/test/locale/locale.cd", .translation = "c/test/locale/catalogs/nihongo.ct", .name = "c/test/locale.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/nihongo/programs/Notepad.catalog", .descriptor = "programs/notepad/notepad.cd", .translation = "programs/notepad/catalogs/nihongo.ct", .name = "programs/Notepad.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/nihongo/programs/Sheet.catalog", .descriptor = "programs/sheet/sheet.cd", .translation = "programs/sheet/catalogs/nihongo.ct", .name = "programs/Sheet.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/nihongo/programs/Player.catalog", .descriptor = "programs/player/player.cd", .translation = "programs/player/catalogs/nihongo.ct", .name = "programs/Player.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/nihongo/programs/Movie.catalog", .descriptor = "programs/movie/movie.cd", .translation = "programs/movie/catalogs/nihongo.ct", .name = "programs/Movie.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/nihongo/System/Clock.catalog", .descriptor = "system/clock/clock.cd", .translation = "system/clock/catalogs/nihongo.ct", .name = "System/Clock.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/nihongo/sys/anvil.catalog", .descriptor = "libs/anvil/anvil.cd", .translation = "libs/anvil/catalogs/nihongo.ct", .name = "sys/anvil.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/nihongo/sys/http.catalog", .descriptor = "libs/http/http.cd", .translation = "libs/http/catalogs/nihongo.ct", .name = "sys/http.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/hangugeo/c/test/locale.catalog", .descriptor = "c/test/locale/locale.cd", .translation = "c/test/locale/catalogs/hangugeo.ct", .name = "c/test/locale.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/hangugeo/programs/Notepad.catalog", .descriptor = "programs/notepad/notepad.cd", .translation = "programs/notepad/catalogs/hangugeo.ct", .name = "programs/Notepad.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/hangugeo/programs/Sheet.catalog", .descriptor = "programs/sheet/sheet.cd", .translation = "programs/sheet/catalogs/hangugeo.ct", .name = "programs/Sheet.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/hangugeo/programs/Player.catalog", .descriptor = "programs/player/player.cd", .translation = "programs/player/catalogs/hangugeo.ct", .name = "programs/Player.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/hangugeo/programs/Movie.catalog", .descriptor = "programs/movie/movie.cd", .translation = "programs/movie/catalogs/hangugeo.ct", .name = "programs/Movie.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/hangugeo/System/Clock.catalog", .descriptor = "system/clock/clock.cd", .translation = "system/clock/catalogs/hangugeo.ct", .name = "System/Clock.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/hangugeo/sys/anvil.catalog", .descriptor = "libs/anvil/anvil.cd", .translation = "libs/anvil/catalogs/hangugeo.ct", .name = "sys/anvil.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/hangugeo/sys/http.catalog", .descriptor = "libs/http/http.cd", .translation = "libs/http/catalogs/hangugeo.ct", .name = "sys/http.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/zhongwen/c/test/locale.catalog", .descriptor = "c/test/locale/locale.cd", .translation = "c/test/locale/catalogs/zhongwen.ct", .name = "c/test/locale.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/zhongwen/programs/Notepad.catalog", .descriptor = "programs/notepad/notepad.cd", .translation = "programs/notepad/catalogs/zhongwen.ct", .name = "programs/Notepad.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/zhongwen/programs/Sheet.catalog", .descriptor = "programs/sheet/sheet.cd", .translation = "programs/sheet/catalogs/zhongwen.ct", .name = "programs/Sheet.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/zhongwen/programs/Player.catalog", .descriptor = "programs/player/player.cd", .translation = "programs/player/catalogs/zhongwen.ct", .name = "programs/Player.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/zhongwen/programs/Movie.catalog", .descriptor = "programs/movie/movie.cd", .translation = "programs/movie/catalogs/zhongwen.ct", .name = "programs/Movie.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/zhongwen/System/Clock.catalog", .descriptor = "system/clock/clock.cd", .translation = "system/clock/catalogs/zhongwen.ct", .name = "System/Clock.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/zhongwen/sys/anvil.catalog", .descriptor = "libs/anvil/anvil.cd", .translation = "libs/anvil/catalogs/zhongwen.ct", .name = "sys/anvil.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/zhongwen/sys/http.catalog", .descriptor = "libs/http/http.cd", .translation = "libs/http/catalogs/zhongwen.ct", .name = "sys/http.catalog", .wide = true },
};

/// Code compiled into each program that imports it, by name, rather than
/// loaded: a library's inner part that its test programs build in as well.
/// The rasterizer core is facet.library's, and is called per triangle and
/// per tile - too often to go through a jump table. vector.library's
/// drawing is the library itself, kept apart so that it is tested on the
/// host and used by host tools as it is. The SMB client is
/// the protocol and the share files, which smb-handler, C:net/MountShare
/// and SYS:System/Shares each need all or part of. The baseline JPEG
/// decoder is jpeg.datatype's, and mjpeg.vcodec's for Motion JPEG. The
/// film's sound is the process Movie and videocodec.datatype both play one
/// with. The
/// H.264 decoder is h264.vcodec's, the VP8 decoder vp8.vcodec's, the VP9
/// decoder vp9.vcodec's, the AV1 decoder av1.vcodec's and the H.265
/// decoder hevc.vcodec's, kept apart from the system so that they are
/// tested on the host as they are. The readers of H.264's and H.265's
/// parameter sets and of VP9's and AV1's headers are videoparse.library's,
/// and chip.vcodec's for the colours a stream says. The commodity frame is
/// where the
/// settings and the broker loop of every commodity in SYS:Commodities are
/// written once.
const inner_modules = [_]struct { name: []const u8, source: []const u8 }{
    .{ .name = "raster", .source = "libs/facet/driver/cpu/raster/raster.zig" },
    .{ .name = "vector", .source = "libs/vector/draw/draw.zig" },
    .{ .name = "v3d", .source = "libs/facet/driver/v3d/v3d.zig" },
    .{ .name = "jpegdecode", .source = "classes/datatypes/jpeg/decode.zig" },
    .{ .name = "filmsound", .source = "libs/videocodec/filmsound.zig" },
    .{ .name = "h264core", .source = "libs/codecs/h264/core.zig" },
    .{ .name = "vp8core", .source = "libs/codecs/vp8/core.zig" },
    .{ .name = "vp9core", .source = "libs/codecs/vp9/core.zig" },
    .{ .name = "av1core", .source = "libs/codecs/av1/core.zig" },
    .{ .name = "hevccore", .source = "libs/codecs/hevc/core.zig" },
    .{ .name = "h264sets", .source = "libs/videoparse/h264/sets.zig" },
    .{ .name = "hevcsets", .source = "libs/videoparse/hevc/sets.zig" },
    .{ .name = "vp9header", .source = "libs/videoparse/vp9/header.zig" },
    .{ .name = "av1header", .source = "libs/videoparse/av1/header.zig" },
    .{ .name = "smbclient", .source = "libs/smb/smbclient.zig" },
    .{ .name = "commodity", .source = "commodities/_frame/frame.zig" },
};

/// Something copied onto the disk as it is.
pub const File = struct { disk: []const u8, source: []const u8 };

/// What a command is for decides which directory it lives in, and the one
/// name serves for both the source tree and the disk: `c` is what the
/// system is used with, `c/test` the programs that exercise a device or a
/// library and print what happened, `c/net` the network's tools.
const commands = [_][]const u8{
    "type",          "dir",         "delete",      "makedir",       "rename",
    "avail",         "assign",      "version",     "addbuffers",    "which",
    "list",          "format",      "protect",     "changetaskpri", "wait",
    "info",          "platform",    "copy",        "rdb",           "i2c",
    "backlight",     "rtg",         "showinfo",    "setmap",        "mount",
    "showconfig",    "date",        "setdate",     "setprefs",      "fixfonts",
    "adddatatypes",  "listfonts",   "log",         "requestfile",   "requestchoice",
    "requestdevice", "diskchange",  "modbus",      "more",          "relabel",
    "loadanvil",     "iconx",       "usb",         "usbinfo",       "battery",
    "setclock",      "top",         "play",        "screendump",    "memdebug",
    "makelink",      "posfs",       "binddrivers", "pciinfo",       "record",
    "audio",         "temperature", "hash",        "break",         "status",
    "cpuclock",      "install",     "update",      "reboot",        "shutdown",
};
const tests = [_][]const u8{
    "hello",       "echoargs",    "testlib",     "gfx",       "anim",
    "intuition",   "console",     "keyboard",    "touch",     "input",
    "lines",       "nyan",        "plasma",      "audiotest", "fonts",
    "screens",     "layout",      "classes",     "gadgets",   "listview",
    "diskfont",    "colorwheel",  "tapedeck",    "pointer",   "crypto",
    "bsdsocktest", "asl",         "settings",    "iff",       "datatypes",
    "shapes",      "styles",      "motion",      "widgets",   "modbusserver",
    "cores",       "scroll",      "listbrowser", "notify",    "icon",
    "launch",      "drag",        "tap",         "app",       "open",
    "engine",      "jpeg",        "keysource",   "usbdevice", "scsi",
    "sound",       "memowner",    "records",     "exall",     "disktest",
    "filetest",    "speed2d",     "windraw",     "semtest",   "membench",
    "glyphs",      "ribbon",      "taskbench",   "videodec",  "audiodec",
    "film",        "commodities", "filmdt",      "watchdog",  "gpu",
    "dttime",      "names",       "axes",
};
const net_tools = [_][]const u8{ "net", "udp", "tcp", "addnetinterface", "remnetinterface", "resolve", "netstatus", "online", "offline", "ping", "timesync", "httpget", "packetcapture", "shellserver", "wireless", "hostname", "ssh", "scp", "filter", "git" };

/// Programs with windows, in SYS:Programs and - the system's own tools -
/// SYS:System, the commodities in SYS:Commodities, and the dock: started
/// by their full name or from a shell there, not on the command path.
const window_programs = [_]Program{
    .{ .disk = "programs/FontView", .source = "programs/fontview/fontview.zig", .name = "fontview" },
    .{ .disk = "programs/MultiView", .source = "programs/multiview/multiview.zig", .name = "multiview" },
    .{ .disk = "programs/Battery", .source = "programs/battery/battery.zig", .name = "battery" },
    .{ .disk = "programs/Prefs", .source = "programs/prefs/prefs.zig", .name = "prefs" },
    .{ .disk = "programs/Notepad", .source = "programs/notepad/notepad.zig", .name = "notepad", .strings = "programs/notepad/notepad.cd" },
    .{ .disk = "programs/Sheet", .source = "programs/sheet/sheet.zig", .name = "sheet", .strings = "programs/sheet/sheet.cd" },
    .{ .disk = "programs/Terminal", .source = "programs/terminal/terminal.zig", .name = "terminal" },
    .{ .disk = "programs/Player", .source = "programs/player/player.zig", .name = "player", .strings = "programs/player/player.cd" },
    .{ .disk = "programs/Movie", .source = "programs/movie/movie.zig", .name = "movie", .imports = &.{"filmsound"}, .strings = "programs/movie/movie.cd" },
    .{ .disk = "programs/Volume", .source = "programs/volume/volume.zig", .name = "volume" },
    .{ .disk = "programs/Boing", .source = "programs/boing/boing.zig", .name = "boing" },
    .{ .disk = "programs/Cobra", .source = "programs/cobra/cobra.zig", .name = "cobra" },
    // The dock, one program in either place (`builtFor`).
    .{ .disk = "programs/Dock", .source = "programs/dock/dock.zig", .name = "dock" },
    .{ .disk = "WBStartup/Dock", .source = "programs/dock/dock.zig", .name = "dock" },
    .{ .disk = "System/Shell", .source = "system/shell/shell.zig", .name = "shell" },
    .{ .disk = "System/HDToolBox", .source = "system/hdtoolbox/hdtoolbox.zig", .name = "hdtoolbox" },
    .{ .disk = "System/CPULoad", .source = "system/cpuload/cpuload.zig", .name = "cpuload" },
    .{ .disk = "System/NetLoad", .source = "system/netload/netload.zig", .name = "netload" },
    .{ .disk = "System/MemMap", .source = "system/memmap/memmap.zig", .name = "memmap" },
    .{ .disk = "System/Clock", .source = "system/clock/clock.zig", .name = "clock", .strings = "system/clock/clock.cd" },
    .{ .disk = "System/Shares", .source = "system/shares/shares.zig", .name = "shares", .imports = &.{"smbclient"} },
    .{ .disk = "System/Update", .source = "system/update/update.zig", .name = "sysupdate" },
    .{ .disk = "Commodities/Exchange", .source = "commodities/exchange/exchange.zig", .name = "exchange" },
    .{ .disk = "Commodities/NoCapsLock", .source = "commodities/nocapslock/nocapslock.zig", .name = "nocapslock", .imports = &.{"commodity"} },
    .{ .disk = "Commodities/NumericPad", .source = "commodities/numericpad/numericpad.zig", .name = "numericpad", .imports = &.{"commodity"} },
    .{ .disk = "Commodities/MouseBlanker", .source = "commodities/mouseblanker/mouseblanker.zig", .name = "mouseblanker", .imports = &.{"commodity"} },
    .{ .disk = "Commodities/AutoPoint", .source = "commodities/autopoint/autopoint.zig", .name = "autopoint", .imports = &.{"commodity"} },
    .{ .disk = "Commodities/ClickToFront", .source = "commodities/clicktofront/clicktofront.zig", .name = "clicktofront", .imports = &.{"commodity"} },
    .{ .disk = "Commodities/Blanker", .source = "commodities/blanker/blanker.zig", .name = "blanker", .imports = &.{"commodity"} },
    .{ .disk = "Commodities/FKey", .source = "commodities/fkey/fkey.zig", .name = "fkey", .imports = &.{"commodity"} },
};

/// Commands built with an inner module.
const inner_commands = [_]Program{
    .{ .disk = "c/net/mountshare", .source = "c/net/mountshare/mountshare.zig", .name = "mountshare", .imports = &.{"smbclient"} },
};

/// Test programs built with an inner module.
const inner_tests = [_]Program{
    .{ .disk = "c/test/raster", .source = "c/test/raster/raster.zig", .name = "raster", .imports = &.{"raster"} },
    .{ .disk = "c/test/cube", .source = "c/test/raster/cube.zig", .name = "cube", .imports = &.{"raster"} },
    .{ .disk = "c/test/facetcube", .source = "c/test/raster/facetcube.zig", .name = "facetcube", .imports = &.{"raster"} },
    .{ .disk = "c/test/facetwindow", .source = "c/test/raster/facetwindow.zig", .name = "facetwindow", .imports = &.{"raster"} },
    .{ .disk = "c/test/facetmany", .source = "c/test/raster/facetmany.zig", .name = "facetmany", .imports = &.{"raster"} },
    .{ .disk = "c/test/facetboth", .source = "c/test/raster/facetboth.zig", .name = "facetboth" },
    .{ .disk = "c/test/facetprobe", .source = "c/test/raster/facetprobe.zig", .name = "facetprobe" },
    .{ .disk = "c/test/v3dtest", .source = "c/test/v3d/v3dtest.zig", .name = "v3dtest", .imports = &.{"v3d"} },
    .{ .disk = "c/test/locale", .source = "c/test/locale/locale.zig", .name = "locale", .strings = "c/test/locale/locale.cd" },
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
    .{ .disk = "libs/compression.library", .source = "libs/compression/compression.zig", .name = "compression.library" },
    .{ .disk = "libs/http.library", .source = "libs/http/http.zig", .name = "http.library", .strings = "libs/http/http.cd", .strings_as = "http_strings", .catalog = "sys/http.catalog" },
    .{ .disk = "libs/rdb.library", .source = "libs/rdb/rdb.zig", .name = "rdb.library" },
    .{ .disk = "libs/usb.library", .source = "libs/usb/usb.zig", .name = "usb.library" },
    .{ .disk = "libs/pci.library", .source = "libs/pci/pci.zig", .name = "pci.library" },
    .{ .disk = "libs/facet.library", .source = "libs/facet/facet.zig", .name = "facet.library", .imports = &.{"raster"} },
    .{ .disk = "libs/facet/v3d.fdriver", .source = "libs/facet/v3d_fdriver.zig", .name = "v3d.fdriver", .imports = &.{ "v3d", "raster" } },
    .{ .disk = "libs/modbus.library", .source = "libs/modbus/modbus.zig", .name = "modbus.library" },
    .{ .disk = "libs/audiocodec.library", .source = "libs/audiocodec/audiocodec.zig", .name = "audiocodec.library" },
    .{ .disk = "libs/codecs/wav.acodec", .source = "libs/audiocodec/wav.zig", .name = "wav.acodec" },
    .{ .disk = "libs/codecs/mp3.acodec", .source = "libs/audiocodec/mp3.zig", .name = "mp3.acodec" },
    .{ .disk = "libs/codecs/flac.acodec", .source = "libs/audiocodec/flac.zig", .name = "flac.acodec" },
    .{ .disk = "libs/codecs/vorbis.acodec", .source = "libs/audiocodec/vorbis.zig", .name = "vorbis.acodec" },
    .{ .disk = "libs/codecs/aac.acodec", .source = "libs/audiocodec/aac.zig", .name = "aac.acodec" },
    .{ .disk = "libs/codecs/ac3.acodec", .source = "libs/audiocodec/ac3.zig", .name = "ac3.acodec" },
    .{ .disk = "libs/codecs/opus.acodec", .source = "libs/audiocodec/opus.zig", .name = "opus.acodec" },
    .{ .disk = "libs/codecs/dts.acodec", .source = "libs/audiocodec/dts.zig", .name = "dts.acodec" },
    .{ .disk = "libs/media.library", .source = "libs/media/media.zig", .name = "media.library" },
    .{ .disk = "libs/videoparse.library", .source = "libs/videoparse/videoparse.zig", .name = "videoparse.library", .imports = &.{ "h264sets", "hevcsets", "vp9header", "av1header" } },
    .{ .disk = "libs/codecs/mp4.container", .source = "libs/media/mp4.zig", .name = "mp4.container" },
    .{ .disk = "libs/codecs/mkv.container", .source = "libs/media/mkv.zig", .name = "mkv.container" },
    .{ .disk = "libs/videocodec.library", .source = "libs/videocodec/videocodec.zig", .name = "videocodec.library" },
    .{ .disk = "libs/codecs/chip.vcodec", .source = "libs/codecs/chip.zig", .name = "chip.vcodec", .imports = &.{ "h264sets", "hevcsets", "vp9header", "av1header" } },
    .{ .disk = "libs/codecs/mjpeg.vcodec", .source = "libs/codecs/mjpeg.zig", .name = "mjpeg.vcodec", .imports = &.{"jpegdecode"} },
    .{ .disk = "libs/codecs/h264.vcodec", .source = "libs/codecs/h264.zig", .name = "h264.vcodec", .imports = &.{"h264core"} },
    .{ .disk = "libs/codecs/vp8.vcodec", .source = "libs/codecs/vp8.zig", .name = "vp8.vcodec", .imports = &.{"vp8core"} },
    .{ .disk = "libs/codecs/vp9.vcodec", .source = "libs/codecs/vp9.zig", .name = "vp9.vcodec", .imports = &.{"vp9core"} },
    .{ .disk = "libs/codecs/av1.vcodec", .source = "libs/codecs/av1.zig", .name = "av1.vcodec", .imports = &.{"av1core"} },
    .{ .disk = "libs/codecs/hevc.vcodec", .source = "libs/codecs/hevc.zig", .name = "hevc.vcodec", .imports = &.{"hevccore"} },
    .{ .disk = "libs/filter.library", .source = "libs/filter/filter.zig", .name = "filter.library" },
    .{ .disk = "libs/update.library", .source = "libs/update/update.zig", .name = "update.library" },
    .{ .disk = "libs/icon.library", .source = "libs/icon/icon.zig", .name = "icon.library" },
    .{ .disk = "libs/anvil.library", .source = "libs/anvil/anvil.zig", .name = "anvil.library", .strings = "libs/anvil/anvil.cd", .catalog = "sys/anvil.catalog" },
    .{ .disk = "libs/tls.library", .source = "libs/tls/tls.zig", .name = "tls.library" },
    .{ .disk = "libs/wpa.library", .source = "libs/wpa/wpa.zig", .name = "wpa.library" },
    .{ .disk = "libs/diskfont.library", .source = "libs/diskfont/diskfont.zig", .name = "diskfont.library" },
    .{ .disk = "libs/truetype.library", .source = "libs/truetype/truetype.zig", .name = "truetype.library" },
    .{ .disk = "libs/truetypeshaping.library", .source = "libs/truetypeshaping/truetypeshaping.zig", .name = "truetypeshaping.library" },
    .{ .disk = "libs/vector.library", .source = "libs/vector/vector.zig", .name = "vector.library", .imports = &.{"vector"} },
    .{ .disk = "libs/asl.library", .source = "libs/asl/asl.zig", .name = "asl.library" },
    .{ .disk = "libs/iffparse.library", .source = "libs/iffparse/iffparse.zig", .name = "iffparse.library" },
    .{ .disk = "libs/commodities.library", .source = "libs/commodities/commodities.zig", .name = "commodities.library" },
    .{ .disk = "libs/locale.library", .source = "libs/locale/locale.zig", .name = "locale.library" },
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
    .{ .disk = "classes/gadgets/getdevice.gadget", .source = "classes/gadgets/getdevice/getdevice.zig", .name = "getdevice.gadget" },
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
    .{ .disk = "classes/gadgets/toolbutton.gadget", .source = "classes/gadgets/toolbutton/toolbutton.zig", .name = "toolbutton.gadget" },
    .{ .disk = "classes/gadgets/ribbon.gadget", .source = "classes/gadgets/ribbon/ribbon.zig", .name = "ribbon.gadget" },
    // The image classes: pictures drawn to any size.
    .{ .disk = "classes/images/command.image", .source = "classes/images/command/command.zig", .name = "command.image" },
    .{ .disk = "classes/images/media.image", .source = "classes/images/media/media.zig", .name = "media.image" },
    // The dock's docklets, in their own drawer: the dock lists it.
    .{ .disk = "classes/docklets/clock.docklet", .source = "classes/docklets/clock/clock.zig", .name = "clock.docklet" },
    .{ .disk = "classes/docklets/battery.docklet", .source = "classes/docklets/battery/battery.zig", .name = "battery.docklet" },
    .{ .disk = "classes/docklets/volume.docklet", .source = "classes/docklets/volume/volume.zig", .name = "volume.docklet" },
    .{ .disk = "classes/docklets/cpu.docklet", .source = "classes/docklets/cpu/cpu.zig", .name = "cpu.docklet" },
    .{ .disk = "classes/docklets/network.docklet", .source = "classes/docklets/network/network.zig", .name = "network.docklet" },
    .{ .disk = "classes/docklets/player.docklet", .source = "classes/docklets/player/player.zig", .name = "player.docklet" },
    .{ .disk = "classes/datatypes/picture.datatype", .source = "classes/datatypes/picture/picture.zig", .name = "picture.datatype" },
    .{ .disk = "classes/datatypes/animation.datatype", .source = "classes/datatypes/animation/animation.zig", .name = "animation.datatype" },
    .{ .disk = "classes/datatypes/model.datatype", .source = "classes/datatypes/model/model.zig", .name = "model.datatype" },
    .{ .disk = "classes/datatypes/obj.datatype", .source = "classes/datatypes/obj/obj.zig", .name = "obj.datatype" },
    .{ .disk = "classes/datatypes/sound.datatype", .source = "classes/datatypes/sound/sound.zig", .name = "sound.datatype" },
    .{ .disk = "classes/datatypes/audiocodec.datatype", .source = "classes/datatypes/audiocodec/audiocodec.zig", .name = "audiocodec.datatype" },
    .{ .disk = "classes/datatypes/videocodec.datatype", .source = "classes/datatypes/videocodec/videocodec.zig", .name = "videocodec.datatype", .imports = &.{"filmsound"} },
    .{ .disk = "classes/datatypes/8svx.datatype", .source = "classes/datatypes/8svx/8svx.zig", .name = "8svx.datatype" },
    .{ .disk = "classes/datatypes/bmp.datatype", .source = "classes/datatypes/bmp/bmp.zig", .name = "bmp.datatype" },
    .{ .disk = "classes/datatypes/ico.datatype", .source = "classes/datatypes/bmp/ico.zig", .name = "ico.datatype" },
    .{ .disk = "classes/datatypes/ilbm.datatype", .source = "classes/datatypes/ilbm/ilbm.zig", .name = "ilbm.datatype" },
    .{ .disk = "classes/datatypes/png.datatype", .source = "classes/datatypes/png/png.zig", .name = "png.datatype" },
    .{ .disk = "classes/datatypes/gif.datatype", .source = "classes/datatypes/gif/gif.zig", .name = "gif.datatype" },
    .{ .disk = "classes/datatypes/gifanim.datatype", .source = "classes/datatypes/gif/gifanim.zig", .name = "gifanim.datatype" },
    .{ .disk = "classes/datatypes/lottie.datatype", .source = "classes/datatypes/lottie/lottie.zig", .name = "lottie.datatype" },
    .{ .disk = "classes/datatypes/svg.datatype", .source = "classes/datatypes/svg/svg.zig", .name = "svg.datatype" },
    .{ .disk = "classes/datatypes/jpeg.datatype", .source = "classes/datatypes/jpeg/jpeg.zig", .name = "jpeg.datatype", .imports = &.{"jpegdecode"} },
    .{ .disk = "classes/datatypes/text.datatype", .source = "classes/datatypes/text/text.zig", .name = "text.datatype" },
    .{ .disk = "classes/datatypes/ascii.datatype", .source = "classes/datatypes/ascii/ascii.zig", .name = "ascii.datatype" },
    .{ .disk = "classes/datatypes/markdown.datatype", .source = "classes/datatypes/markdown/markdown.zig", .name = "markdown.datatype" },
    .{ .disk = "classes/datatypes/html.datatype", .source = "classes/datatypes/html/html.zig", .name = "html.datatype" },
    .{ .disk = "classes/datatypes/font.datatype", .source = "classes/datatypes/font/font.zig", .name = "font.datatype" },
    .{ .disk = "devs/sdcard.device", .source = "devs/sdcard/sdcard.zig", .name = "sdcard.device" },
    .{ .disk = "devs/rs485.device", .source = "devs/rs485/rs485.zig", .name = "rs485.device" },
    .{ .disk = "devs/networks/openeth.device", .source = "devs/networks/openeth/openeth.zig", .name = "openeth.device" },
    .{ .disk = "devs/networks/intelnet.device", .source = "devs/networks/intelnet/intelnet.zig", .name = "intelnet.device" },
    .{ .disk = "devs/networks/realnet.device", .source = "devs/networks/realnet/realnet.zig", .name = "realnet.device" },
    .{ .disk = "devs/networks/emac.device", .source = "devs/networks/emac/emac.zig", .name = "emac.device" },
    .{ .disk = "devs/networks/slip.device", .source = "devs/networks/slip/slip.zig", .name = "slip.device" },
    .{ .disk = "devs/networks/cyw43455.device", .source = "devs/networks/cyw43455/cyw43455.zig", .name = "cyw43455.device" },
    .{ .disk = "devs/telnet.device", .source = "devs/telnet/telnet.zig", .name = "telnet.device" },
    .{ .disk = "devs/ssh.device", .source = "devs/ssh/ssh.zig", .name = "ssh.device" },
    .{ .disk = "devs/clipboard.device", .source = "devs/clipboard/clipboard.zig", .name = "clipboard.device" },
    .{ .disk = "devs/usbotg.device", .source = "devs/usbotg/usbotg.zig", .name = "usbotg.device" },
    .{ .disk = "devs/xhci.device", .source = "devs/xhci/xhci.zig", .name = "xhci.device" },
    .{ .disk = "devs/nvme.device", .source = "devs/nvme/nvme.zig", .name = "nvme.device" },
    .{ .disk = "devs/usb/hid.device", .source = "devs/usb/hid/hid.zig", .name = "hid.device" },
    .{ .disk = "devs/usb/disk.device", .source = "devs/usb/disk/disk.zig", .name = "disk.device" },
    .{ .disk = "devs/usb/ftdi.device", .source = "devs/usb/serial/ftdi.zig", .name = "ftdi.device" },
    .{ .disk = "devs/usb/acm.device", .source = "devs/usb/serial/acm.zig", .name = "acm.device" },
    .{ .disk = "devs/usb/ecm.device", .source = "devs/usb/ecm/ecm.zig", .name = "ecm.device" },
    .{ .disk = "devs/usb/uac.device", .source = "devs/usb/audio/uac.zig", .name = "uac.device" },
    .{ .disk = "devs/usb/aic8800.device", .source = "devs/usb/aic8800/aic8800.zig", .name = "aic8800.device" },
    .{ .disk = "devs/handlers/fat-handler", .source = "devs/handlers/fat/fat.zig", .name = "fat-handler" },
    .{ .disk = "devs/handlers/posfs-handler", .source = "devs/handlers/posfs/posfs.zig", .name = "posfs-handler" },
    .{ .disk = "devs/handlers/smb-handler", .source = "devs/handlers/smb/smb.zig", .name = "smb-handler", .imports = &.{"smbclient"} },
};

/// Drivers of the ESP32-S3's own hardware, built for it alone: RS-485 on
/// its UART, Ethernet in Espressif QEMU's S3 machine. The ESP32-P4's come
/// as drivers of their own.
const s3_only = [_][]const u8{ "rs485.device", "openeth.device" };
/// Drivers of hardware the ESP32-P4, the JH7110 and the RP1 have and
/// neither the ESP32-S3 nor an x86-64 machine does: an Ethernet MAC of
/// the chip's own. An x86-64 machine's Ethernet is a card on PCI.
const mac_only = [_][]const u8{"emac.device"};
/// Drivers of hardware both ESP32s have and a RISC-V 64 machine under SBI
/// does not: the DWC2 USB controller, the SD host. And the dock in
/// SYS:Programs, started by hand: on their small screens it is not
/// wanted from the start.
const esp_only = [_][]const u8{ "usbotg.device", "sdcard.device", "programs/Dock" };
/// What the 64-bit machines - RISC-V 64 under SBI, AArch64 under PSCI,
/// x86-64 under UEFI - have and the ESP32s do not: PCI, the command that
/// lists it, and the USB controllers and SSDs on it. The install, which
/// puts a system onto a card or an SSD for a machine whose firmware loads
/// a kernel from a partition - an ESP32's kernel is in its flash - and
/// update.library, C:Update and SYS:System/Update, which bring such a
/// system up to date from a package. And the
/// dock in SYS:WBStartup, started with the desktop, the test of a chip's
/// video decoder, DTS's module with its large tables, and the video codecs
/// in software: the ESP32s have neither the room for them on their flash
/// disks nor the speed, and the 64-bit machines' disks are RAM.
/// chip.vcodec goes with them: it drives videodec.resource, which no
/// ESP32 has, and carries the parameter-set readers it reads a stream's
/// colours with - 60 KB for a chip that is not there. svg.datatype as
/// well: what goes on an ESP32's flash disk is what that board is meant
/// to do, and showing SVG files is not among it.
const rv64_only = [_][]const u8{ "pci.library", "pciinfo", "xhci.device", "nvme.device", "intelnet.device", "realnet.device", "install", "update", "update.library", "System/Update", "WBStartup/Dock", "videodec", "dts.acodec", "chip.vcodec", "h264.vcodec", "hevc.vcodec", "vp8.vcodec", "vp9.vcodec", "av1.vcodec", "svg.datatype", "dttime" };
/// Drivers of what only the Raspberry Pi CM5 has among the AArch64
/// machines and no other chip does: its radio, a CYW43455 on the
/// BCM2712's SD host.
const a64_only = [_][]const u8{ "cyw43455.device", "v3dtest", "facetboth", "v3d.fdriver" };

/// What draws in three dimensions, left off the ESP32-S3's disk:
/// facet.library, the programs that drive its rasterizer, the two that
/// fly a scene past the eye, and the classes that read a model out of a
/// file. Together they are 2 MB of load files on a flash disk that has
/// 14 MB for everything, and that board's own room goes to the rest of
/// the system.
const no_3d = [_][]const u8{ "facet.library", "raster", "cube", "facetcube", "facetwindow", "facetmany", "facetprobe", "model.datatype", "obj.datatype", "boing", "cobra" };

/// The files that go with them: the models in SYS:Tests/datatypes, the
/// datatype descriptor that names obj.datatype, and what the two
/// programs are in SYS:Programs/Docs.
const no_3d_files = [_][]const u8{
    "devs/datatypes/OBJ",
    "tests/datatypes/Crate.obj",
    "tests/datatypes/Crate.mtl",
    "tests/datatypes/Crate.png",
    "tests/datatypes/Torus.obj",
    "tests/datatypes/Torus.mtl",
    "tests/datatypes/Icosahedron.obj",
    "programs/Docs/Boing.md",
    "programs/Docs/Cobra.md",
};

/// What goes with the programs only the 64-bit machines have
/// (`rv64_only`) - what they are, in SYS:System/Docs, the descriptors
/// and the test pictures of svg.datatype, plain, packed and of text, and
/// Lottie's paints: left off the ESP32s' disks with them.
const rv64_only_files = [_][]const u8{
    "System/Docs/Update.md",
    "devs/datatypes/SVG",
    "devs/datatypes/SVGZ",
    "tests/datatypes/Drawing.svg",
    "tests/datatypes/Drawing.svgz",
    "tests/datatypes/Text.svg",
    "tests/datatypes/Paints.json",
};

/// What is written in Devanagari, kana, Hangul or Han characters, which
/// only the 64-bit machines' disks have fonts for (FONTS:devanagari,
/// FONTS:cjk-jp): left off the ESP32s' disks.
const wide_only_files = [_][]const u8{
    "locale/Countries/hanguk.country",
    "locale/Countries/india.country",
    "locale/Countries/nihon.country",
    "locale/Countries/taiwan.country",
    "locale/Countries/zhongguo.country",
    "locale/Languages/hangugeo.language",
    "locale/Languages/hindi.language",
    "locale/Languages/nihongo.language",
    "locale/Languages/zhongwen.language",
    "locale/Languages/zhongwen-fanti.language",
};

/// Whether `program` is built for `chip`. The lists name a program by its
/// name, or by its place on the disk where one program has two.
pub fn builtFor(program: Program, chip: poweros_sdk.Chip) bool {
    const others = switch (chip) {
        .esp32s3 => &(mac_only ++ rv64_only ++ a64_only ++ no_3d),
        .esp32p4 => &(s3_only ++ rv64_only ++ a64_only),
        .rv64sbi => &(s3_only ++ esp_only ++ a64_only),
        .x64uefi => &(s3_only ++ esp_only ++ a64_only ++ mac_only),
        .a64psci => &(s3_only ++ esp_only),
    };
    for (others) |name| {
        if (std.mem.eql(u8, program.name, name) or std.mem.eql(u8, program.disk, name)) return false;
    }
    return true;
}

/// Whether `file` goes on `chip`'s disk. The 64-bit machines' have all
/// of them; the ESP32s' leave out what goes with a program or a font
/// they do not have, and the ESP32-S3's also what reads a model
/// (`no_3d`).
pub fn fileFor(file: File, chip: poweros_sdk.Chip) bool {
    const others: []const []const u8 = switch (chip) {
        .esp32s3 => &(no_3d_files ++ rv64_only_files ++ wide_only_files),
        .esp32p4 => &(rv64_only_files ++ wide_only_files),
        .rv64sbi, .x64uefi, .a64psci => &.{},
    };
    for (others) |path| {
        if (std.mem.eql(u8, file.disk, path)) return false;
    }
    return true;
}

pub const programs: []const Program = blk: {
    var list: [commands.len + tests.len + inner_tests.len + inner_commands.len + net_tools.len + window_programs.len + modules.len]Program = undefined;
    var n: usize = 0;
    for (commands) |name| {
        list[n] = .{ .disk = "c/" ++ name, .source = "c/" ++ name ++ "/" ++ name ++ ".zig", .name = name };
        n += 1;
    }
    for (tests) |name| {
        list[n] = .{ .disk = "c/test/" ++ name, .source = "c/test/" ++ name ++ "/" ++ name ++ ".zig", .name = name };
        n += 1;
    }
    for (inner_tests) |program| {
        list[n] = program;
        n += 1;
    }
    for (inner_commands) |program| {
        list[n] = program;
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

/// The disks of the chips with an Ethernet MAC of their own (the
/// ESP32-P4, the JH7110) have these in place of the shared files of the
/// same name: the Ethernet interface names emac.device.
pub const mac_files = [_]File{
    .{ .disk = "devs/NetInterfaces/ETH0", .source = "devs/NetInterfaces/emac/ETH0" },
};

/// The ESP32-P4's disk has these as well.
pub const p4_files = [_]File{
    // A USB Wi-Fi stick: only the P4's port is fast enough for one.
    .{ .disk = "devs/NetInterfaces/WLAN1", .source = "devs/NetInterfaces/esp32p4/WLAN1" },
    // A photograph the size of the CrowPanel's screen, for C:test/Jpeg to
    // time the codec on.
    .{ .disk = "tests/datatypes/Desktop.jpg", .source = "tests/datatypes/esp32p4/Desktop.jpg" },
};

/// The x86-64 machines' disk has this in place of the shared file of the
/// same name, and two more beside it: their Ethernet is a card on PCI,
/// and the interfaces name the two kinds of card this system drives
/// there, with a second port for the kind that often has two. A machine
/// has what it has, and an interface whose port is not there is not
/// added. And the large photograph, for C:test/Jpeg to time an AMD
/// graphics device's decoder on.
pub const x64_files = [_]File{
    .{ .disk = "devs/NetInterfaces/ETH0", .source = "devs/NetInterfaces/x64/ETH0" },
    .{ .disk = "devs/NetInterfaces/ETH1", .source = "devs/NetInterfaces/x64/ETH1" },
    .{ .disk = "devs/NetInterfaces/ETH2", .source = "devs/NetInterfaces/x64/ETH2" },
    .{ .disk = "tests/datatypes/Desktop.jpg", .source = "tests/datatypes/esp32p4/Desktop.jpg" },
};

/// The AArch64 machines' disk has these in place of the shared files of
/// the same name: the Wi-Fi interface names the CM5's radio, the Ethernet
/// one its RP1's MAC.
pub const a64_files = [_]File{
    .{ .disk = "devs/NetInterfaces/WLAN0", .source = "devs/NetInterfaces/a64/WLAN0" },
    .{ .disk = "devs/NetInterfaces/ETH0", .source = "devs/NetInterfaces/emac/ETH0" },
};

/// The radio's device: built only when the vendor libraries it links are
/// at hand (scripts/fetch-wifi.sh), given to this package as `-Dwifi=`.
pub const wifi_device: Program = .{ .disk = "devs/networks/esp32s3wifi.device", .source = "devs/networks/esp32s3wifi/esp32s3wifi.zig", .name = "esp32s3wifi.device" };

/// The vendor archives esp32s3wifi.device links, and the chip ROM's scripts.
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
    .{ .disk = "devs/datatypes/ICO", .source = "devs/datatypes/ICO" },
    .{ .disk = "devs/datatypes/PNG", .source = "devs/datatypes/PNG" },
    .{ .disk = "devs/datatypes/GIF", .source = "devs/datatypes/GIF" },
    .{ .disk = "devs/datatypes/GIFAnim", .source = "devs/datatypes/GIFAnim" },
    .{ .disk = "devs/datatypes/Lottie", .source = "devs/datatypes/Lottie" },
    .{ .disk = "devs/datatypes/SVG", .source = "devs/datatypes/SVG" },
    .{ .disk = "devs/datatypes/SVGZ", .source = "devs/datatypes/SVGZ" },
    .{ .disk = "devs/datatypes/JPEG", .source = "devs/datatypes/JPEG" },
    .{ .disk = "devs/datatypes/Markdown", .source = "devs/datatypes/Markdown" },
    .{ .disk = "devs/datatypes/HTML", .source = "devs/datatypes/HTML" },
    .{ .disk = "devs/datatypes/OBJ", .source = "devs/datatypes/OBJ" },
    .{ .disk = "devs/datatypes/Font", .source = "devs/datatypes/Font" },
    .{ .disk = "devs/datatypes/FTXT", .source = "devs/datatypes/FTXT" },
    .{ .disk = "devs/datatypes/8SVX", .source = "devs/datatypes/8SVX" },
    .{ .disk = "devs/datatypes/MP3", .source = "devs/datatypes/MP3" },
    .{ .disk = "devs/datatypes/WAV", .source = "devs/datatypes/WAV" },
    .{ .disk = "devs/datatypes/FLAC", .source = "devs/datatypes/FLAC" },
    .{ .disk = "devs/datatypes/Ogg", .source = "devs/datatypes/Ogg" },
    .{ .disk = "devs/datatypes/AAC", .source = "devs/datatypes/AAC" },
    .{ .disk = "devs/datatypes/M4A", .source = "devs/datatypes/M4A" },
    .{ .disk = "devs/datatypes/AC3", .source = "devs/datatypes/AC3" },
    .{ .disk = "devs/datatypes/DTS", .source = "devs/datatypes/DTS" },
    .{ .disk = "devs/datatypes/MP4", .source = "devs/datatypes/MP4" },
    .{ .disk = "devs/datatypes/MOV", .source = "devs/datatypes/MOV" },
    .{ .disk = "devs/datatypes/MKV", .source = "devs/datatypes/MKV" },
    .{ .disk = "devs/datatypes/WebM", .source = "devs/datatypes/WebM" },
    .{ .disk = "devs/datatypes/MKA", .source = "devs/datatypes/MKA" },
    .{ .disk = "devs/datatypes/M3U", .source = "devs/datatypes/M3U" },
    .{ .disk = "devs/datatypes/PLS", .source = "devs/datatypes/PLS" },
    .{ .disk = "devs/datatypes/ANIM", .source = "devs/datatypes/ANIM" },
    .{ .disk = "devs/datatypes/ASCII", .source = "devs/datatypes/ASCII" },
    .{ .disk = "devs/datatypes/Binary", .source = "devs/datatypes/Binary" },
    .{ .disk = "devs/NetInterfaces/ETH0", .source = "devs/NetInterfaces/ETH0" },
    .{ .disk = "devs/NetInterfaces/WLAN0", .source = "devs/NetInterfaces/WLAN0" },
    .{ .disk = "devs/NetInterfaces/USB0", .source = "devs/NetInterfaces/USB0" },
    // ENVARC: as a fresh disk has it: what each settings file says, and
    // its value to start with.
    .{ .disk = "prefs/env-archive/Sys/timezone", .source = "prefs/env-archive/Sys/timezone" },
    .{ .disk = "prefs/env-archive/Sys/locale.prefs", .source = "prefs/env-archive/Sys/locale.prefs" },
    .{ .disk = "prefs/env-archive/Sys/font.prefs", .source = "prefs/env-archive/Sys/font.prefs" },
    .{ .disk = "prefs/env-archive/Sys/style.prefs", .source = "prefs/env-archive/Sys/style.prefs" },
    .{ .disk = "prefs/env-archive/Sys/intuition.prefs", .source = "prefs/env-archive/Sys/intuition.prefs" },
    .{ .disk = "prefs/env-archive/Sys/palette.prefs", .source = "prefs/env-archive/Sys/palette.prefs" },
    .{ .disk = "prefs/env-archive/Sys/anvil.prefs", .source = "prefs/env-archive/Sys/anvil.prefs" },
    .{ .disk = "prefs/env-archive/Sys/sound.prefs", .source = "prefs/env-archive/Sys/sound.prefs" },
    .{ .disk = "prefs/env-archive/Sys/audio.prefs", .source = "prefs/env-archive/Sys/audio.prefs" },
    .{ .disk = "prefs/env-archive/Sys/dock.prefs", .source = "prefs/env-archive/Sys/dock.prefs" },
    .{ .disk = "prefs/env-archive/Sys/dock.items", .source = "prefs/env-archive/Sys/dock.items" },
    .{ .disk = "prefs/env-archive/Player/Stations.m3u", .source = "prefs/env-archive/Player/Stations.m3u" },
    // LOCALE: - each country's formats and each language's words, which
    // locale.library makes a locale of.
    .{ .disk = "locale/Countries/australia.country", .source = "locale/countries/australia.country" },
    .{ .disk = "locale/Countries/belgie.country", .source = "locale/countries/belgie.country" },
    .{ .disk = "locale/Countries/belgique.country", .source = "locale/countries/belgique.country" },
    .{ .disk = "locale/Countries/canada.country", .source = "locale/countries/canada.country" },
    .{ .disk = "locale/Countries/canada_francais.country", .source = "locale/countries/canada_francais.country" },
    .{ .disk = "locale/Countries/danmark.country", .source = "locale/countries/danmark.country" },
    .{ .disk = "locale/Countries/deutschland.country", .source = "locale/countries/deutschland.country" },
    .{ .disk = "locale/Countries/espana.country", .source = "locale/countries/espana.country" },
    .{ .disk = "locale/Countries/france.country", .source = "locale/countries/france.country" },
    .{ .disk = "locale/Countries/great_britain.country", .source = "locale/countries/great_britain.country" },
    .{ .disk = "locale/Countries/hanguk.country", .source = "locale/countries/hanguk.country" },
    .{ .disk = "locale/Countries/india.country", .source = "locale/countries/india.country" },
    .{ .disk = "locale/Countries/italia.country", .source = "locale/countries/italia.country" },
    .{ .disk = "locale/Countries/nederland.country", .source = "locale/countries/nederland.country" },
    .{ .disk = "locale/Countries/nihon.country", .source = "locale/countries/nihon.country" },
    .{ .disk = "locale/Countries/norge.country", .source = "locale/countries/norge.country" },
    .{ .disk = "locale/Countries/osterreich.country", .source = "locale/countries/osterreich.country" },
    .{ .disk = "locale/Countries/portugal.country", .source = "locale/countries/portugal.country" },
    .{ .disk = "locale/Countries/schweiz.country", .source = "locale/countries/schweiz.country" },
    .{ .disk = "locale/Countries/suisse.country", .source = "locale/countries/suisse.country" },
    .{ .disk = "locale/Countries/sverige.country", .source = "locale/countries/sverige.country" },
    .{ .disk = "locale/Countries/svizzera.country", .source = "locale/countries/svizzera.country" },
    .{ .disk = "locale/Countries/taiwan.country", .source = "locale/countries/taiwan.country" },
    .{ .disk = "locale/Countries/united_kingdom.country", .source = "locale/countries/united_kingdom.country" },
    .{ .disk = "locale/Countries/united_states.country", .source = "locale/countries/united_states.country" },
    .{ .disk = "locale/Countries/zhongguo.country", .source = "locale/countries/zhongguo.country" },
    .{ .disk = "locale/Languages/dansk.language", .source = "locale/languages/dansk.language" },
    .{ .disk = "locale/Languages/deutsch.language", .source = "locale/languages/deutsch.language" },
    .{ .disk = "locale/Languages/espanol.language", .source = "locale/languages/espanol.language" },
    .{ .disk = "locale/Languages/francais.language", .source = "locale/languages/francais.language" },
    .{ .disk = "locale/Languages/hangugeo.language", .source = "locale/languages/hangugeo.language" },
    .{ .disk = "locale/Languages/hindi.language", .source = "locale/languages/hindi.language" },
    .{ .disk = "locale/Languages/italiano.language", .source = "locale/languages/italiano.language" },
    .{ .disk = "locale/Languages/nederlands.language", .source = "locale/languages/nederlands.language" },
    .{ .disk = "locale/Languages/nihongo.language", .source = "locale/languages/nihongo.language" },
    .{ .disk = "locale/Languages/norsk.language", .source = "locale/languages/norsk.language" },
    .{ .disk = "locale/Languages/portugues.language", .source = "locale/languages/portugues.language" },
    .{ .disk = "locale/Languages/svenska.language", .source = "locale/languages/svenska.language" },
    .{ .disk = "locale/Languages/zhongwen.language", .source = "locale/languages/zhongwen.language" },
    .{ .disk = "locale/Languages/zhongwen-fanti.language", .source = "locale/languages/zhongwen-fanti.language" },
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
    .{ .disk = "tests/datatypes/Paints.json", .source = "tests/datatypes/Paints.json" },
    .{ .disk = "tests/datatypes/Drawing.svg", .source = "tests/datatypes/Drawing.svg" },
    .{ .disk = "tests/datatypes/Drawing.svgz", .source = "tests/datatypes/Drawing.svgz" },
    .{ .disk = "tests/datatypes/Text.svg", .source = "tests/datatypes/Text.svg" },
    .{ .disk = "tests/datatypes/Crate.obj", .source = "tests/datatypes/Crate.obj" },
    .{ .disk = "tests/datatypes/Crate.mtl", .source = "tests/datatypes/Crate.mtl" },
    .{ .disk = "tests/datatypes/Crate.png", .source = "tests/datatypes/Crate.png" },
    .{ .disk = "tests/datatypes/Torus.obj", .source = "tests/datatypes/Torus.obj" },
    .{ .disk = "tests/datatypes/Torus.mtl", .source = "tests/datatypes/Torus.mtl" },
    .{ .disk = "tests/datatypes/Icosahedron.obj", .source = "tests/datatypes/Icosahedron.obj" },
    .{ .disk = "tests/datatypes/Garden.jpg", .source = "tests/datatypes/Garden.jpg" },
    .{ .disk = "tests/datatypes/Grey.jpg", .source = "tests/datatypes/Grey.jpg" },
    .{ .disk = "tests/datatypes/Tiles.bmp", .source = "tests/datatypes/Tiles.bmp" },
    .{ .disk = "tests/datatypes/Runs.bmp", .source = "tests/datatypes/Runs.bmp" },
    .{ .disk = "tests/datatypes/Nibbles.bmp", .source = "tests/datatypes/Nibbles.bmp" },
    .{ .disk = "tests/datatypes/Deep.bmp", .source = "tests/datatypes/Deep.bmp" },
    .{ .disk = "tests/datatypes/Badge.ico", .source = "tests/datatypes/Badge.ico" },
    .{ .disk = "tests/datatypes/Glow.ico", .source = "tests/datatypes/Glow.ico" },
    .{ .disk = "tests/datatypes/Bars.ilbm", .source = "tests/datatypes/Bars.ilbm" },
    .{ .disk = "tests/datatypes/Deep.ilbm", .source = "tests/datatypes/Deep.ilbm" },
    .{ .disk = "tests/datatypes/Ham.ilbm", .source = "tests/datatypes/Ham.ilbm" },
    .{ .disk = "tests/datatypes/Reading.md", .source = "tests/datatypes/Reading.md" },
    .{ .disk = "tests/datatypes/Page.html", .source = "tests/datatypes/Page.html" },
    // SYS:Programs/Docs - what each program is and how it is used.
    .{ .disk = "programs/Docs/Battery.md", .source = "programs/battery/README.md" },
    .{ .disk = "programs/Docs/Dock.md", .source = "programs/dock/README.md" },
    .{ .disk = "programs/Docs/FontView.md", .source = "programs/fontview/README.md" },
    .{ .disk = "programs/Docs/Movie.md", .source = "programs/movie/README.md" },
    .{ .disk = "programs/Docs/MultiView.md", .source = "programs/multiview/README.md" },
    .{ .disk = "programs/Docs/Notepad.md", .source = "programs/notepad/README.md" },
    .{ .disk = "programs/Docs/Player.md", .source = "programs/player/README.md" },
    .{ .disk = "programs/Docs/Prefs.md", .source = "programs/prefs/README.md" },
    .{ .disk = "programs/Docs/Sheet.md", .source = "programs/sheet/README.md" },
    .{ .disk = "programs/Docs/Terminal.md", .source = "programs/terminal/README.md" },
    .{ .disk = "programs/Docs/Volume.md", .source = "programs/volume/README.md" },
    .{ .disk = "programs/Docs/Boing.md", .source = "programs/boing/README.md" },
    .{ .disk = "programs/Docs/Cobra.md", .source = "programs/cobra/README.md" },
    // SYS:System/Docs - the same for the system's tools.
    .{ .disk = "System/Docs/HDToolBox.md", .source = "system/hdtoolbox/README.md" },
    .{ .disk = "System/Docs/CPULoad.md", .source = "system/cpuload/README.md" },
    .{ .disk = "System/Docs/NetLoad.md", .source = "system/netload/README.md" },
    .{ .disk = "System/Docs/MemMap.md", .source = "system/memmap/README.md" },
    .{ .disk = "System/Docs/Clock.md", .source = "system/clock/README.md" },
    .{ .disk = "System/Docs/Shares.md", .source = "system/shares/README.md" },
    .{ .disk = "System/Docs/Update.md", .source = "system/update/README.md" },
    // SYS:Commodities/Docs - the same for the commodities.
    .{ .disk = "Commodities/Docs/Exchange.md", .source = "commodities/exchange/README.md" },
    .{ .disk = "Commodities/Docs/NoCapsLock.md", .source = "commodities/nocapslock/README.md" },
    .{ .disk = "Commodities/Docs/NumericPad.md", .source = "commodities/numericpad/README.md" },
    .{ .disk = "Commodities/Docs/MouseBlanker.md", .source = "commodities/mouseblanker/README.md" },
    .{ .disk = "Commodities/Docs/AutoPoint.md", .source = "commodities/autopoint/README.md" },
    .{ .disk = "Commodities/Docs/ClickToFront.md", .source = "commodities/clicktofront/README.md" },
    .{ .disk = "Commodities/Docs/Blanker.md", .source = "commodities/blanker/README.md" },
    .{ .disk = "Commodities/Docs/FKey.md", .source = "commodities/fkey/README.md" },
};

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseSafe)") orelse .ReleaseSafe;
    const wifi = b.option([]const u8, "wifi", "The directory with the radio's vendor libraries (scripts/fetch-wifi.sh); without it there is no esp32s3wifi.device");
    const chip = b.option(poweros_sdk.Chip, "chip", "The chip the programs are built for (default: esp32s3)") orelse .esp32s3;
    const sdk = b.dependency("poweros_sdk", .{});
    // The radio's vendor libraries are the S3's.
    if (wifi != null and chip == .esp32s3) {
        const dir = wifi.?;
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
        b.getInstallStep().dependOn(&b.addInstallBinFile(seg, "esp32s3wifi.device.seg").step);
    }
    var inner: [inner_modules.len]std.Build.Module.Import = undefined;
    for (inner_modules, &inner) |module, *import| {
        const made = b.createModule(.{ .root_source_file = b.path(module.source) });
        made.addImport("sdk", sdk.module("sdk"));
        import.* = .{ .name = module.name, .module = made };
    }
    for (programs) |program| {
        if (!builtFor(program, chip)) continue;
        var imports: [inner_modules.len + 1]std.Build.Module.Import = undefined;
        var count: usize = 0;
        for (program.imports) |name| {
            for (inner) |import| {
                if (!std.mem.eql(u8, import.name, name)) continue;
                imports[count] = import;
                count += 1;
            }
        }
        if (program.strings) |descriptor| {
            const catalog_name = program.catalog orelse b.fmt("{s}.catalog", .{program.disk});
            imports[count] = .{ .name = program.strings_as, .module = poweros_sdk.addStrings(b, sdk, b.path(descriptor), catalog_name) };
            count += 1;
        }
        const seg = poweros_sdk.addProgram(b, sdk, .{
            .name = program.name,
            .root = b.path(program.source),
            .optimize = optimize,
            .chip = chip,
            .imports = b.allocator.dupe(std.Build.Module.Import, imports[0..count]) catch @panic("OOM"),
        });
        b.addNamedLazyPath(program.disk, seg);
        b.getInstallStep().dependOn(&b.addInstallBinFile(seg, b.fmt("{s}.seg", .{program.name})).step);
    }
    for (files) |file| b.addNamedLazyPath(file.disk, b.path(file.source));
    for (catalogs) |catalog| {
        b.addNamedLazyPath(catalog.disk, poweros_sdk.addCatalog(b, sdk, b.path(catalog.descriptor), b.path(catalog.translation), catalog.name));
    }
    for (mac_files ++ p4_files ++ a64_files ++ x64_files) |file| b.addNamedLazyPath(file.source, b.path(file.source));
}
