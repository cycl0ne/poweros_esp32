// SPDX-License-Identifier: MPL-2.0
//! What checks the tree: the host tests, the checks of generated and
//! listed files, and the builds of every board's kernel and disk.

const std = @import("std");
const poweros_sdk = @import("poweros_sdk");
const poweros_userland = @import("poweros_userland");
const build_boards = @import("boards.zig");
const build_disk = @import("disk.zig");
const build_fetched = @import("fetched.zig");
const build_kernel = @import("kernel.zig");
const build_release = @import("release.zig");

const Board = build_boards.Board;
const chipOf = build_boards.chipOf;
const DiskImages = build_disk.DiskImages;
const isModule = build_disk.isModule;
const fontsDir = build_fetched.fontsDir;
const unicodeDir = build_fetched.unicodeDir;
const Image = build_kernel.Image;
const addKernel = build_kernel.addKernel;
const addReport = build_release.addReport;

/// What `addCheckSteps` takes from the build so far.
pub const CheckStepsWith = struct {
    a64_target: std.Build.ResolvedTarget,
    board: Board,
    built: Image,
    cores: u32,
    disk_dep: *std.Build.Dependency,
    disk_offset: u32,
    disks: DiskImages,
    mkicon: *std.Build.Step.Compile,
    mkpackage: *std.Build.Step.Compile,
    optimize: std.builtin.OptimizeMode,
    p4_target: std.Build.ResolvedTarget,
    posfs_soak: u32,
    posfsck: *std.Build.Step.Compile,
    rv64_target: std.Build.ResolvedTarget,
    sdk: *std.Build.Module,
    sdk_dep: *std.Build.Dependency,
    serve: *std.Build.Step.Compile,
    svgcompare: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    wifi: ?[]const u8,
    x64_target: std.Build.ResolvedTarget,
};

/// The `test`, `check` and `check-all` steps, and the steps that write
/// what `test` checks: `autodoc`, `modchart` and `fd`.
pub fn addCheckSteps(b: *std.Build, with: CheckStepsWith) void {
    const a64_target = with.a64_target;
    const board = with.board;
    const built = with.built;
    const cores = with.cores;
    const disk_dep = with.disk_dep;
    const disk_offset = with.disk_offset;
    const disks = with.disks;
    const mkicon = with.mkicon;
    const mkpackage = with.mkpackage;
    const optimize = with.optimize;
    const p4_target = with.p4_target;
    const posfs_soak = with.posfs_soak;
    const posfsck = with.posfsck;
    const rv64_target = with.rv64_target;
    const sdk = with.sdk;
    const sdk_dep = with.sdk_dep;
    const serve = with.serve;
    const svgcompare = with.svgcompare;
    const target = with.target;
    const wifi = with.wifi;
    const x64_target = with.x64_target;

    // Three steps, by what they cost. `test` is the code that runs on
    // the host and the checks of what is generated or listed: nothing is
    // built for a board. `check` builds what -Dboard= is made of - its
    // kernel, its image and its chip's disk - and installs nothing.
    // `check-all` is `test` and that for every board and every chip.
    const test_step = b.step("test", "Run the unit tests on the host and the checks of generated files");
    const check_step = b.step("check", "Build the kernel and the disk of -Dboard= without installing them");
    const check_all_step = b.step("check-all", "`test`, and every board's kernel and every chip's disk");
    check_all_step.dependOn(test_step);
    check_all_step.dependOn(check_step);
    // Nothing is handed out unchecked: `release` builds every board's
    // artifact, and this is what says every board still builds and the
    // tests pass.
    b.top_level_steps.get("release").?.step.dependOn(check_all_step);
    built.image.addStepDependencies(check_step);
    built.flash_image.addStepDependencies(check_step);
    if (built.flash_part) |part| part.addStepDependencies(check_step);
    check_step.dependOn(&disks.runOf(board).step);
    const test_options = b.addOptions();
    test_options.addOption(u32, "posfs_soak", posfs_soak);
    // Where the fetched fonts are, for the tests that read one; empty
    // when scripts/fetch-fonts.sh has not run, and those tests skip.
    test_options.addOption([]const u8, "fonts_dir", fontsDir(b) orelse "");
    // And the fetched files of the Unicode Character Database; empty
    // when scripts/fetch-unicode.sh has not run.
    test_options.addOption([]const u8, "unicode_dir", unicodeDir(b) orelse "");
    for ([_][]const u8{ "src/tests.zig", "src/rom/devs/timer/timeval.zig" }) |path| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = b.graph.host,
        });
        test_mod.addImport("sdk", sdk);
        test_mod.addOptions("test_options", test_options);
        const unit_tests = b.addTest(.{ .root_module = test_mod });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
    // The disk's own tests, some of which bring up the ROM's exec and
    // utility.library: those they reach through `host_rom`.
    const host_rom = b.createModule(.{ .root_source_file = b.path("src/host_rom.zig"), .target = b.graph.host });
    host_rom.addImport("sdk", sdk);
    const disk_test_mod = b.createModule(.{
        .root_source_file = disk_dep.path("tests.zig"),
        .target = b.graph.host,
    });
    disk_test_mod.addImport("sdk", sdk);
    disk_test_mod.addImport("host_rom", host_rom);
    // anvil.library's strings, which its files import as `strings`, and
    // http.library's, which its own import as `http_strings`: the modules
    // of the disk's tests that have a catalog.
    disk_test_mod.addImport("strings", poweros_sdk.addStrings(b, sdk_dep, disk_dep.path("libs/anvil/anvil.cd"), "sys/anvil.catalog"));
    disk_test_mod.addImport("http_strings", poweros_sdk.addStrings(b, sdk_dep, disk_dep.path("libs/http/http.cd"), "sys/http.catalog"));
    // The rasterizer core: its own tests, and the module its test programs
    // import, for the scenes they draw (c/test/raster/reference.zig). A
    // file belongs to one module, so the core is tested on its own.
    const raster_mod = b.createModule(.{ .root_source_file = disk_dep.path("libs/facet/driver/cpu/raster/raster.zig"), .target = b.graph.host });
    raster_mod.addImport("sdk", sdk);
    disk_test_mod.addImport("raster", raster_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = raster_mod })).step);
    // vector.library's drawing, likewise: tested on its own, and the
    // module the library's own tests build it with.
    const vector_mod = b.createModule(.{ .root_source_file = disk_dep.path("libs/vector/draw/draw.zig"), .target = b.graph.host });
    vector_mod.addImport("sdk", sdk);
    disk_test_mod.addImport("vector", vector_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = vector_mod })).step);
    // The V3D's control list packets and QPU instructions, on their own: the
    // rest of the driver is only of use on the board.
    const v3d_mod = b.createModule(.{ .root_source_file = disk_dep.path("libs/facet/driver/v3d/v3d.zig"), .target = b.graph.host });
    v3d_mod.addImport("sdk", sdk);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = v3d_mod })).step);
    // The baseline JPEG decoder, jpeg.datatype's and videocodec.library's,
    // tested on its own as well.
    const jpegdecode_mod = b.createModule(.{ .root_source_file = disk_dep.path("classes/datatypes/jpeg/decode.zig"), .target = b.graph.host });
    disk_test_mod.addImport("jpegdecode", jpegdecode_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = jpegdecode_mod })).step);
    // The H.264 decoder, h264.vcodec's, likewise.
    const h264core_mod = b.createModule(.{ .root_source_file = disk_dep.path("libs/codecs/h264/core.zig"), .target = b.graph.host });
    h264core_mod.addImport("sdk", sdk);
    disk_test_mod.addImport("h264core", h264core_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = h264core_mod })).step);
    // The VP8 decoder, vp8.vcodec's, likewise.
    const vp8core_mod = b.createModule(.{ .root_source_file = disk_dep.path("libs/codecs/vp8/core.zig"), .target = b.graph.host });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = vp8core_mod })).step);
    // The VP9 decoder, vp9.vcodec's, likewise.
    const vp9core_mod = b.createModule(.{ .root_source_file = disk_dep.path("libs/codecs/vp9/core.zig"), .target = b.graph.host });
    vp9core_mod.addImport("sdk", sdk);
    disk_test_mod.addImport("vp9core", vp9core_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = vp9core_mod })).step);
    // The AV1 decoder, av1.vcodec's, likewise.
    const av1core_mod = b.createModule(.{ .root_source_file = disk_dep.path("libs/codecs/av1/core.zig"), .target = b.graph.host });
    av1core_mod.addImport("sdk", sdk);
    disk_test_mod.addImport("av1core", av1core_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = av1core_mod })).step);
    // The H.265 decoder, hevc.vcodec's, likewise.
    const hevccore_mod = b.createModule(.{ .root_source_file = disk_dep.path("libs/codecs/hevc/core.zig"), .target = b.graph.host });
    hevccore_mod.addImport("sdk", sdk);
    disk_test_mod.addImport("hevccore", hevccore_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = hevccore_mod })).step);
    // The readers of H.264's and H.265's parameter sets and of VP9's and
    // AV1's headers, which videoparse.library and chip.vcodec build in.
    const h264sets_mod = b.createModule(.{ .root_source_file = disk_dep.path("libs/videoparse/h264/sets.zig"), .target = b.graph.host });
    h264sets_mod.addImport("sdk", sdk);
    disk_test_mod.addImport("h264sets", h264sets_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = h264sets_mod })).step);
    const hevcsets_mod = b.createModule(.{ .root_source_file = disk_dep.path("libs/videoparse/hevc/sets.zig"), .target = b.graph.host });
    hevcsets_mod.addImport("sdk", sdk);
    disk_test_mod.addImport("hevcsets", hevcsets_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = hevcsets_mod })).step);
    const vp9header_mod = b.createModule(.{ .root_source_file = disk_dep.path("libs/videoparse/vp9/header.zig"), .target = b.graph.host });
    vp9header_mod.addImport("sdk", sdk);
    disk_test_mod.addImport("vp9header", vp9header_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = vp9header_mod })).step);
    const av1header_mod = b.createModule(.{ .root_source_file = disk_dep.path("libs/videoparse/av1/header.zig"), .target = b.graph.host });
    av1header_mod.addImport("sdk", sdk);
    disk_test_mod.addImport("av1header", av1header_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = av1header_mod })).step);
    // The SMB client - the protocol and the share files - which the
    // handler, MountShare and the Shares tool are each built with.
    const smbclient_mod = b.createModule(.{ .root_source_file = disk_dep.path("libs/smb/smbclient.zig"), .target = b.graph.host });
    smbclient_mod.addImport("sdk", sdk);
    disk_test_mod.addImport("smbclient", smbclient_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = smbclient_mod })).step);
    disk_test_mod.addOptions("test_options", test_options);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = disk_test_mod })).step);
    test_step.dependOn(&posfsck.step);
    // esp32s3wifi.device's own code compiles for the chip even where the vendor
    // libraries it links are missing: as an object, which needs no link.
    const wifi_check = b.addObject(.{
        .name = "wifi_check",
        .root_module = b.createModule(.{
            .root_source_file = disk_dep.path(poweros_userland.wifi_device.source),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .unwind_tables = .none,
        }),
    });
    wifi_check.root_module.addImport("sdk", sdk);
    test_step.dependOn(&wifi_check.step);
    // fontconv's own tests: its readers and the images it writes.
    const fontconv_tests = b.createModule(.{
        .root_source_file = b.path("tools/fontconv/fontconv.zig"),
        .target = b.graph.host,
    });
    fontconv_tests.addImport("sdk", sdk);
    const fontconv_tests_truetype = b.createModule(.{ .root_source_file = disk_dep.path("libs/truetype/outlines.zig"), .target = b.graph.host });
    fontconv_tests_truetype.addImport("sdk", sdk);
    fontconv_tests.addImport("truetype", fontconv_tests_truetype);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = fontconv_tests })).step);
    // emojigen's own tests: the list and the names it makes, read back
    // with the SDK's reader.
    const emojigen_tests = b.createModule(.{
        .root_source_file = b.path("tools/emojigen/emojigen.zig"),
        .target = b.graph.host,
    });
    emojigen_tests.addImport("sdk", sdk);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = emojigen_tests })).step);
    // svgcompare reads the modules' own code, not their calls: it is
    // compiled here so that a change to that code is seen in it.
    test_step.dependOn(&svgcompare.step);
    // Board facts are src/boards/'s and nothing a module imports: a
    // module asks expansion.library for its part (tools/boardcheck.zig).
    const boardcheck = b.addExecutable(.{
        .name = "boardcheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/boardcheck.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const check_boards = b.addRunArtifact(boardcheck);
    check_boards.addArg(b.pathFromRoot("src"));
    check_boards.has_side_effects = true;
    test_step.dependOn(&check_boards.step);
    // Every file in the kernel shell's cmds/ is in its command list: the
    // table and `help` are made from that list (tools/shellcheck.zig).
    const shellcheck = b.addExecutable(.{
        .name = "shellcheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/shellcheck.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const check_shell = b.addRunArtifact(shellcheck);
    check_shell.addArg(b.pathFromRoot("src/rom/libs/exec/_shell"));
    check_shell.has_side_effects = true;
    test_step.dependOn(&check_shell.step);
    // The SDK's autodocs (sdk/docs/autodocs) come from the doc comments of
    // every call in sdk/fd: `autodoc` writes them, and `test` fails if one
    // isn't up to date (tools/autodoc.zig).
    const autodoc = b.addExecutable(.{
        .name = "autodoc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/autodoc.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const autodoc_args = [_][]const u8{ b.pathFromRoot("sdk/fd"), b.pathFromRoot("src"), b.pathFromRoot("sdk/docs/autodocs") };
    const write_autodocs = b.addRunArtifact(autodoc);
    write_autodocs.addArgs(&autodoc_args);
    write_autodocs.has_side_effects = true;
    b.step("autodoc", "Generate the SDK's autodocs (sdk/docs/autodocs) from the source").dependOn(&write_autodocs.step);
    const check_autodocs = b.addRunArtifact(autodoc);
    check_autodocs.addArg("--check");
    check_autodocs.addArgs(&autodoc_args);
    check_autodocs.has_side_effects = true;
    test_step.dependOn(&check_autodocs.step);
    // The charts of which module opens which (sdk/docs/modules.md) come
    // from the source: `modchart` writes them, and `test` fails if one
    // isn't up to date (tools/modchart.zig). The ROM's modules it finds by
    // their place; the disk's are the disk package's list, handed over as a
    // file of `<name>=<root file>` lines.
    const modchart = b.addExecutable(.{
        .name = "modchart",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/modchart.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    var disk_modules: std.ArrayList(u8) = .empty;
    for (poweros_userland.programs ++ [_]poweros_userland.Program{poweros_userland.wifi_device}) |program| {
        if (!isModule(program.disk)) continue;
        const root = b.pathFromRoot(b.fmt("src/disk/{s}", .{program.source}));
        disk_modules.appendSlice(b.allocator, b.fmt("{s}={s}\n", .{ program.name, root })) catch @panic("OOM");
    }
    const disk_module_list = b.addWriteFiles().add("disk-modules", disk_modules.items);
    const modchart_args = [_][]const u8{ b.pathFromRoot("sdk/docs/modules.md"), b.pathFromRoot("src"), b.pathFromRoot("sdk") };
    const write_modchart = b.addRunArtifact(modchart);
    write_modchart.addArgs(&modchart_args);
    write_modchart.addFileArg(disk_module_list);
    write_modchart.has_side_effects = true;
    b.step("modchart", "Generate the module charts (sdk/docs/modules.md) from the source").dependOn(&write_modchart.step);
    // What the board's disk leaves without: a module its sets leave off
    // that something on the disk opens, said after the disk is made. It
    // is said and nothing more - what a disk holds is its board's choice.
    {
        const sets = disks.sets[DiskImages.indexOf(board)];
        var listed: std.ArrayList(u8) = .empty;
        // The radio's device is the ESP32-S3's, and there only with its
        // vendor libraries.
        const wifi_devices: []const poweros_userland.Program = if (wifi != null and chipOf(board) == .esp32s3) &.{poweros_userland.wifi_device} else &.{};
        for ([_][]const poweros_userland.Program{ poweros_userland.programs, wifi_devices }) |some| {
            for (some) |program| {
                if (!poweros_userland.builtFor(program, chipOf(board))) continue;
                const on = poweros_userland.onDisk(sets, program.disk);
                listed.appendSlice(b.allocator, b.fmt("{s}={s}={s}={s}\n", .{
                    if (isModule(program.disk)) program.name else program.disk,
                    b.pathFromRoot(b.fmt("src/disk/{s}", .{program.source})),
                    @tagName(program.set),
                    if (on) "on" else "off",
                })) catch @panic("OOM");
            }
        }
        const find_needs = b.addRunArtifact(modchart);
        find_needs.addArgs(&.{ "--needs", b.pathFromRoot("src"), b.pathFromRoot("sdk") });
        find_needs.addFileArg(b.addWriteFiles().add("disk-programs", listed.items));
        // The sources it reads are not its arguments: it runs each time.
        find_needs.has_side_effects = true;
        const say_needs = addReport(b, find_needs.captureStdOut(.{}), "", &disks.runOf(board).step);
        check_step.dependOn(&say_needs.step);
        b.getInstallStep().dependOn(&say_needs.step);
    }
    const check_modchart = b.addRunArtifact(modchart);
    check_modchart.addArg("--check");
    check_modchart.addArgs(&modchart_args);
    check_modchart.addFileArg(disk_module_list);
    check_modchart.has_side_effects = true;
    test_step.dependOn(&check_modchart.step);
    // tools/mkicon runs once on a default icon's picture with every
    // field, reads back what it wrote, and fails if any of it does not
    // read.
    const try_mkicon = b.addRunArtifact(mkicon);
    try_mkicon.addFileArg(b.path("src/disk/libs/icon/images/drawer.png"));
    _ = try_mkicon.addOutputFileArg("Work.info");
    try_mkicon.addArgs(&.{ "KIND=DRAWER", "AT=20,10", "TOOL=SYS:Programs/MultiView", "TYPE=FILETYPE=text|ascii", "TYPE=DONOTWAIT", "STACK=16384", "WINDOW=40,30,400,200", "SCROLL=0,8", "VIEW=NAME", "SHOW=ALL" });
    test_step.dependOn(&try_mkicon.step);
    // The scripts an archive carries are read by `sh` and by nothing else
    // here, so the test step at least asks the shell whether they parse.
    for ([_][]const u8{
        "tools/qemupackage/run.sh",
        "tools/espackage/flash.sh",
        "tools/bootpackage/write.sh",
    }) |script| {
        const check_script = b.addSystemCommand(&.{ "sh", "-n" });
        check_script.addFileArg(b.path(script));
        test_step.dependOn(&check_script.step);
    }
    // tools/mkpackage and tools/serve compile, whichever board is being
    // built: the `package` and `serve` steps are the only other things
    // that build them, and a tool nothing compiles is a tool that stops
    // compiling.
    test_step.dependOn(&mkpackage.step);
    test_step.dependOn(&serve.step);
    // Every program and module on a disk compiles: every board's flash
    // disk and every 64-bit chip's disk is made.
    for (disks.runs) |run| check_all_step.dependOn(&run.step);
    // Every board's kernel compiles, not only the one being flashed.
    for (std.enums.values(Board)) |other| {
        const other_target = switch (chipOf(other)) {
            .esp32s3 => target,
            .esp32p4 => p4_target,
            .rv64sbi => rv64_target,
            .a64psci => a64_target,
            .x64uefi => x64_target,
        };
        if (other != board) check_all_step.dependOn(&addKernel(b, other_target, optimize, sdk, other, disk_offset, cores, false, false, false).step);
    }

    // The SDK's interfaces (sdk/interface) come from its .fd files
    // (sdk/fd): the SDK package's `fd` step writes them, and its `test`
    // step - part of this one - fails if one isn't up to date.
    const fd_step = b.step("fd", "Generate the SDK's interfaces (sdk/interface) from sdk/fd");
    fd_step.dependOn(&sdk_dep.builder.top_level_steps.get("fd").?.step);
    test_step.dependOn(&sdk_dep.builder.top_level_steps.get("test").?.step);
}
