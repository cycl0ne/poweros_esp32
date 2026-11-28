// SPDX-License-Identifier: MPL-2.0
//! The tools of the build that run on the host, and the steps that are
//! nothing but one of them.

const std = @import("std");
const build_fetched = @import("fetched.zig");

const fontsDir = build_fetched.fontsDir;
const hasFontSources = build_fetched.hasFontSources;
const liberation_dir = build_fetched.liberation_dir;

/// What `addHostTools` takes from the build so far.
pub const HostToolsWith = struct {
    disk_dep: *std.Build.Dependency,
    sdk: *std.Build.Module,
};

/// What `addHostTools` hands on to the rest of the build.
pub const MadeHostTools = struct {
    mkfs: *std.Build.Step.Compile,
    mkicon: *std.Build.Step.Compile,
    mkstick: *std.Build.Step.Compile,
    posfsck: *std.Build.Step.Compile,
    acpicheck: *std.Build.Step.Compile,
    svgcompare: *std.Build.Step.Compile,
};

/// The tools that run on the host and their steps: mkfs and posfsck, the
/// icon maker, the stick maker, acpicheck, the benches of audio.device
/// and graphics.library, and svgcompare.
/// Where scripts/fetch-svg-suite.sh puts resvg's test suite: `tests/`,
/// `resources/` and `fonts/` as the suite keeps them, and `commit`, the
/// one it is.
const svg_suite_dir = "toolchain/svg-suite";

/// The `svg-suite` step: a `svgcompare --suite` for each folder of the
/// suite's tests, two deep as the suite keeps them, so that they run side
/// by side - each a step that runs again when svgcompare or the suite
/// changes - and a `--summary` of their reports against the files that
/// are not close today. Without the suite the step says how to fetch it.
fn addSvgSuite(b: *std.Build, step: *std.Build.Step, svgcompare: *std.Build.Step.Compile) void {
    const io = b.graph.io;
    var tests = b.build_root.handle.openDir(io, svg_suite_dir ++ "/tests", .{ .iterate = true }) catch {
        step.dependOn(&b.addFail("svg-suite: there is no " ++ svg_suite_dir ++ "/tests - scripts/fetch-svg-suite.sh fetches it").step);
        return;
    };
    defer tests.close(io);
    var folders: std.ArrayList([]const u8) = .empty;
    var tops = tests.iterate();
    while (tops.next(io) catch null) |top| {
        if (top.kind != .directory) continue;
        var inner = tests.openDir(io, top.name, .{ .iterate = true }) catch continue;
        defer inner.close(io);
        var subs = inner.iterate();
        while (subs.next(io) catch null) |sub| {
            if (sub.kind == .directory) folders.append(b.allocator, b.fmt("{s}/{s}", .{ top.name, sub.name })) catch @panic("OOM");
        }
    }
    std.mem.sort([]const u8, folders.items, {}, earlierPath);

    const summary = b.addRunArtifact(svgcompare);
    summary.setName("svgcompare --summary");
    summary.addArg("--summary");
    summary.addFileArg(b.path("tools/svgcompare/suite-far.txt"));
    summary.has_side_effects = true;
    summary.stdio = .inherit;
    // The reports in one directory, a file a folder, which is what the
    // summary is handed.
    const reports = b.addWriteFiles();
    for (folders.items) |folder| {
        const run = b.addRunArtifact(svgcompare);
        run.setName(b.fmt("svgcompare --suite {s}", .{folder}));
        run.addArgs(&.{ "--fonts", b.pathFromRoot(svg_suite_dir ++ "/fonts"), "--suite", b.pathFromRoot(svg_suite_dir ++ "/tests"), "--report" });
        const report = run.addOutputFileArg("report");
        run.addArg(folder);
        // The suite's files are no inputs the build follows; the commit
        // they are of is.
        run.addFileInput(b.path(svg_suite_dir ++ "/commit"));
        _ = reports.addCopyFile(report, b.fmt("{s}.txt", .{folder}));
    }
    summary.addDirectoryArg(reports.getDirectory());
    step.dependOn(&summary.step);
}

fn earlierPath(_: void, one: []const u8, other: []const u8) bool {
    return std.mem.lessThan(u8, one, other);
}

pub fn addHostTools(b: *std.Build, with: HostToolsWith) MadeHostTools {
    const disk_dep = with.disk_dep;
    const sdk = with.sdk;

    // The disk image: the same file system code the handler runs
    // (src/rom/handler/flashfs as a module of its own), driven on the host
    // over a block of memory. Its numbers must be the ones flash.device
    // reports: the disk area of src/layout.zig, 4 KiB sectors, 256-byte
    // pages.
    const fs_mod = b.createModule(.{
        .root_source_file = b.path("src/rom/handler/flashfs/disk.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    fs_mod.addImport("sdk", sdk);
    const mkfs = b.addExecutable(.{
        .name = "mkfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkfs/mkfs.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    mkfs.root_module.addImport("sdk", sdk);
    mkfs.root_module.addImport("fs", fs_mod);
    // tools/posfsck, the handler's check of a posfs volume run on an
    // image: `zig build posfsck -- [--data] <image>`, or without the
    // arguments installed as zig-out/bin/posfsck. The check is the
    // handler's own code (src/disk/devs/handlers/posfs as a module of its
    // own).
    const posfs_mod = b.createModule(.{
        .root_source_file = b.path("src/disk/devs/handlers/posfs/fs.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    posfs_mod.addImport("sdk", sdk);
    // mkfs writes posfs with the same code, on a disk with a GPT.
    mkfs.root_module.addImport("posfs", posfs_mod);
    const posfsck = b.addExecutable(.{
        .name = "posfsck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/posfsck/posfsck.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    posfsck.root_module.addImport("sdk", sdk);
    posfsck.root_module.addImport("posfs", posfs_mod);
    const posfsck_step = b.step("posfsck", "Check the posfs volumes of an image (zig build posfsck -- [--data] <image>)");
    if (b.args) |given| {
        const run_posfsck = b.addRunArtifact(posfsck);
        run_posfsck.addArgs(given);
        posfsck_step.dependOn(&run_posfsck.step);
    } else posfsck_step.dependOn(&b.addInstallArtifact(posfsck, .{}).step);

    // tools/acpicheck, acpi.resource's interpreter run on the host over a
    // folder of saved tables: `zig build acpicheck -- [--namespace]
    // [--acpiexec | --run] <folder>`, or without the arguments installed as
    // zig-out/bin/acpicheck. The interpreter is the resource's own code
    // (src/rom/resources/acpi as a module of its own).
    const acpi_mod = b.createModule(.{
        .root_source_file = b.path("src/rom/resources/acpi/acpi.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    acpi_mod.addImport("sdk", sdk);
    const acpicheck = b.addExecutable(.{
        .name = "acpicheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/acpicheck/acpicheck.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    acpicheck.root_module.addImport("sdk", sdk);
    acpicheck.root_module.addImport("acpi", acpi_mod);
    const acpicheck_step = b.step("acpicheck", "Load a folder of saved ACPI tables with acpi.resource's interpreter, and run their methods (zig build acpicheck -- [--namespace] [--acpiexec | --run] <folder>)");
    if (b.args) |given| {
        const run_acpicheck = b.addRunArtifact(acpicheck);
        run_acpicheck.addArgs(given);
        acpicheck_step.dependOn(&run_acpicheck.step);
    } else acpicheck_step.dependOn(&b.addInstallArtifact(acpicheck, .{}).step);

    // tools/mkstick makes the medium a machine whose firmware is UEFI
    // starts from. The FAT32 volume on it is laid down by the file
    // system's own format, through the door that handler keeps for a tool
    // on the host, so there is one implementation of the format and what
    // the tool writes is what the handler mounts.
    const fat32_mod = b.createModule(.{
        .root_source_file = b.path("src/disk/devs/handlers/fat/host.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    fat32_mod.addImport("sdk", sdk);
    const mkstick = b.addExecutable(.{
        .name = "mkstick",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkstick/mkstick.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    mkstick.root_module.addImport("sdk", sdk);
    mkstick.root_module.addImport("fat32", fat32_mod);

    // audio.device's mixer on the host: `audio-golden` writes the golden
    // mix's reference file again (src/rom/devs/audio/golden.zig, whose
    // test holds the mixer to it), and `audio-bench` says how fast the
    // mixer is - on stderr, which a test may not write to.
    const golden_mod = b.createModule(.{
        .root_source_file = b.path("src/rom/devs/audio/golden.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const audiogolden = b.addExecutable(.{
        .name = "audiogolden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/audio/audiogolden.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    audiogolden.root_module.addImport("golden", golden_mod);
    const write_golden = b.addRunArtifact(audiogolden);
    write_golden.addArg(b.pathFromRoot("src/rom/devs/audio/golden.pcm"));
    write_golden.has_side_effects = true;
    b.step("audio-golden", "Write audio.device's golden mix again (src/rom/devs/audio/golden.pcm)").dependOn(&write_golden.step);
    const audiobench = b.addExecutable(.{
        .name = "audiobench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/audio/audiobench.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    audiobench.root_module.addImport("golden", golden_mod);
    const run_bench = b.addRunArtifact(audiobench);
    run_bench.has_side_effects = true;
    b.step("audio-bench", "Time audio.device's mixer on the host for 1, 4, 8 and 16 voices").dependOn(&run_bench.step);

    // graphics.library's software drawing on the host, as the tests stand
    // it up: `gfx-bench` says what each kind of call costs, to compare one
    // change of the drawing loops with the one before. A test binary,
    // since exec stands on the host only in one, run as a program so that
    // it may print.
    const gfxbench_mod = b.createModule(.{
        .root_source_file = b.path("src/gfxbench.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    gfxbench_mod.addImport("sdk", sdk);
    const gfxbench = b.addTest(.{ .name = "gfxbench", .root_module = gfxbench_mod, .filters = &.{"gfx-bench"} });
    const run_gfxbench = std.Build.Step.Run.create(b, "run gfxbench");
    run_gfxbench.addArtifactArg(gfxbench);
    run_gfxbench.has_side_effects = true;
    b.step("gfx-bench", "Time graphics.library's software drawing on the host, in RGB565 and BGRA32").dependOn(&run_gfxbench.step);

    // tools/svgcompare: SVG files drawn on the host with svg.datatype's
    // code and vector.library's module, against another renderer's
    // pictures of them (scripts/svg-compare.sh, rsvg-convert's).
    const svgcompare_vector = b.createModule(.{ .root_source_file = disk_dep.path("libs/vector/draw/draw.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    svgcompare_vector.addImport("sdk", sdk);
    const svgcompare_svg = b.createModule(.{ .root_source_file = disk_dep.path("classes/datatypes/svg/draw.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    svgcompare_svg.addImport("sdk", sdk);
    const svgcompare_truetype = b.createModule(.{ .root_source_file = disk_dep.path("libs/truetype/outlines.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    svgcompare_truetype.addImport("sdk", sdk);
    const svgcompare_shaping = b.createModule(.{ .root_source_file = disk_dep.path("libs/truetypeshaping/shaping.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    svgcompare_shaping.addImport("sdk", sdk);
    // The disk's GIF, JPEG and WebP readers, for the pictures a file names.
    const svgcompare_gif = b.createModule(.{ .root_source_file = disk_dep.path("classes/datatypes/gif/decode.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    const svgcompare_lzw = b.createModule(.{ .root_source_file = disk_dep.path("classes/datatypes/gif/lzw.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    const svgcompare_jpeg = b.createModule(.{ .root_source_file = disk_dep.path("classes/datatypes/jpeg/decode.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    const svgcompare_vp8 = b.createModule(.{ .root_source_file = disk_dep.path("libs/codecs/vp8/core.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    const svgcompare_webp = b.createModule(.{ .root_source_file = disk_dep.path("classes/datatypes/webp/decode.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    svgcompare_webp.addImport("vp8core", svgcompare_vp8);
    const svgcompare = b.addExecutable(.{
        .name = "svgcompare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/svgcompare/svgcompare.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    svgcompare.root_module.addImport("sdk", sdk);
    svgcompare.root_module.addImport("vector", svgcompare_vector);
    svgcompare.root_module.addImport("svg", svgcompare_svg);
    svgcompare.root_module.addImport("truetype", svgcompare_truetype);
    svgcompare.root_module.addImport("shaping", svgcompare_shaping);
    svgcompare.root_module.addImport("gif", svgcompare_gif);
    svgcompare.root_module.addImport("lzw", svgcompare_lzw);
    svgcompare.root_module.addImport("jpeg", svgcompare_jpeg);
    svgcompare.root_module.addImport("webp", svgcompare_webp);
    const run_svgcompare = b.addRunArtifact(svgcompare);
    // Text in the disk's Liberation fonts, when scripts/fetch-fonts.sh
    // fetched them.
    if (fontsDir(b)) |dir| {
        if (hasFontSources(b, dir, liberation_dir)) run_svgcompare.addArgs(&.{ "--fonts", b.pathJoin(&.{ dir, liberation_dir }) });
    }
    if (b.args) |args| run_svgcompare.addArgs(args);
    b.step("svgcompare", "Draw SVG files as svg.datatype does and compare them with PNGs of them: svgcompare [--size N] [--out DIR] <file.svg> <drawn.png> ...").dependOn(&run_svgcompare.step);
    addSvgSuite(b, b.step("svg-suite", "Draw resvg's test suite (scripts/fetch-svg-suite.sh) as svg.datatype does; fails on a file further from resvg's picture than tools/svgcompare/suite-far.txt allows"), svgcompare);

    // tools/mkicon, which makes the disk's icons from pictures.
    const mkicon = b.addExecutable(.{
        .name = "mkicon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkicon/mkicon.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    mkicon.root_module.addImport("sdk", sdk);
    return .{
        .mkfs = mkfs,
        .mkicon = mkicon,
        .mkstick = mkstick,
        .posfsck = posfsck,
        .acpicheck = acpicheck,
        .svgcompare = svgcompare,
    };
}
