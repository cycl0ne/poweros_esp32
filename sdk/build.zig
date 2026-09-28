// SPDX-License-Identifier: MIT
//! The SDK as a Zig package: what a program, a library or a device for the
//! system builds against, and the tools that turn one into a load file.
//!
//! A package that depends on it (`zig fetch --save`, or a `.path` in its
//! build.zig.zon) takes the `sdk` module for its imports and builds each
//! program with `addProgram`, which knows the rest: the chip, the linker
//! script, the relocations kept and the load file made from them.
//!
//!   const poweros = @import("poweros_sdk");
//!   const dep = b.dependency("poweros_sdk", .{});
//!   const seg = poweros.addProgram(b, dep, .{ .name = "hello", .root = b.path("hello.zig") });
//!   b.getInstallStep().dependOn(&b.addInstallBinFile(seg, "hello.seg").step);
//!
//! Its own steps: `fd` writes the libraries' interfaces (`interface/`)
//! from their `.fd` files, and `test` fails when one of them is not up to
//! date.

const std = @import("std");

/// The chip every program runs on.
pub const target_query: std.Target.Query = .{
    .cpu_arch = .xtensa,
    .os_tag = .freestanding,
    .abi = .none,
    .cpu_model = .{ .explicit = &std.Target.xtensa.cpu.esp32s3 },
};

/// The libraries with an `.fd` file, each made into `interface/<name>.zig`.
const interfaces = [_][]const u8{ "exec", "utility", "timer", "watchdog", "dma", "platform", "expander", "expansion", "gpio", "dos", "rtg", "graphics", "layers", "intuition", "input", "keymap", "console", "colorwheel", "bsdsocket", "crypto", "diskfont", "truetype", "asl" };

pub fn build(b: *std.Build) void {
    const sdk = b.addModule("sdk", .{ .root_source_file = b.path("sdk.zig") });

    // A linked program into a load file for dos's LoadSeg.
    const elf2seg = b.addExecutable(.{
        .name = "elf2seg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/elf2seg/elf2seg.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    elf2seg.root_module.addImport("sdk", sdk);
    b.installArtifact(elf2seg);

    // A program's linker script with the chip ROM's addresses added, for
    // one that links a vendor archive.
    const romld = b.addExecutable(.{
        .name = "romld",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/romld/romld.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    b.installArtifact(romld);
    const romld_tests = b.addTest(.{ .root_module = romld.root_module });

    // A foreign archive's in-place addends folded into its relocations,
    // so that LLD links it as the GNU linker would.
    const addends = b.addExecutable(.{
        .name = "addends",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/addends/addends.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    b.installArtifact(addends);
    const addends_tests = b.addTest(.{ .root_module = addends.root_module });

    // A library's .fd file into its interface.
    const fd2zig = b.addExecutable(.{
        .name = "fd2zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fd2zig/fd2zig.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    b.installArtifact(fd2zig);

    const fd_step = b.step("fd", "Generate the interfaces (interface/) from fd/");
    const test_step = b.step("test", "Check that every interface is up to date with its .fd file, and test the tools");
    test_step.dependOn(&b.addRunArtifact(addends_tests).step);
    test_step.dependOn(&b.addRunArtifact(romld_tests).step);
    for (interfaces) |name| {
        const fd = b.path(b.fmt("fd/{s}_lib.fd", .{name}));
        const interface = b.fmt("interface/{s}.zig", .{name});
        const generate = b.addRunArtifact(fd2zig);
        generate.addFileArg(fd);
        generate.addArg(b.pathFromRoot(interface));
        generate.has_side_effects = true;
        fd_step.dependOn(&generate.step);

        const check = b.addRunArtifact(fd2zig);
        check.addArg("--check");
        check.addFileArg(fd);
        check.addFileArg(b.path(interface));
        test_step.dependOn(&check.step);
    }
}

/// What `addProgram` builds.
pub const Program = struct {
    /// The name of the compile artifact, and of the load file (`<name>.seg`).
    /// A name with a dot or a dash in it - `hello.library` - is kept for
    /// the load file; the artifact gets underscores instead.
    name: []const u8,
    /// Its root source file.
    root: std.Build.LazyPath,
    optimize: std.builtin.OptimizeMode = .ReleaseSafe,
    /// Foreign archives linked in (`.a`): code built by GCC for the same
    /// chip and the windowed ABI, such as the radio's vendor libraries.
    /// Each goes through tools/addends first; only what the program
    /// reaches is kept.
    archives: []const std.Build.LazyPath = &.{},
    /// Linker scripts that name the chip ROM's functions and data, for
    /// archives that call into mask ROM; their addresses are added to
    /// `program.ld` (tools/romld) and left alone by elf2seg.
    rom_scripts: []const std.Build.LazyPath = &.{},
};

/// A program, library, device or handler built for the chip and made into
/// a load file: the `.seg` dos's LoadSeg reads. What goes on the disk.
///
/// It is linked with the SDK's `program.ld` and with the linker's
/// relocations kept (`--emit-relocs`); `elf2seg` keeps the ones that hold
/// an address and makes the load file from them. The entry is
/// `_program_entry`, which a command exports; a module's ROM tag is what
/// ramlib or dos finds in it instead.
pub fn addProgram(b: *std.Build, dep: *std.Build.Dependency, program: Program) std.Build.LazyPath {
    const own = b.createModule(.{
        .root_source_file = program.root,
        .target = b.resolveTargetQuery(target_query),
        .optimize = program.optimize,
        .single_threaded = true,
        .unwind_tables = .none,
    });
    own.addImport("sdk", dep.module("sdk"));
    // The root is the SDK's program.zig, which takes the program's own
    // root in and gives it the SDK's panic handler.
    const module = b.createModule(.{
        .root_source_file = dep.path("program.zig"),
        .target = b.resolveTargetQuery(target_query),
        .optimize = program.optimize,
        .single_threaded = true,
        .unwind_tables = .none,
    });
    module.addImport("sdk", dep.module("sdk"));
    module.addImport("program", own);
    const artifact_name = b.dupe(program.name);
    for (artifact_name) |*char| if (char.* == '.' or char.* == '-') {
        char.* = '_';
    };
    const exe = b.addExecutable(.{ .name = artifact_name, .root_module = module });
    if (program.rom_scripts.len == 0) {
        exe.setLinkerScript(dep.path("program.ld"));
    } else {
        const merge = b.addRunArtifact(dep.artifact("romld"));
        merge.addFileArg(dep.path("program.ld"));
        const script = merge.addOutputFileArg(b.fmt("{s}.ld", .{program.name}));
        for (program.rom_scripts) |rom| merge.addFileArg(rom);
        exe.setLinkerScript(script);
    }
    for (program.archives, 0..) |archive, index| {
        const fold = b.addRunArtifact(dep.artifact("addends"));
        fold.addFileArg(archive);
        module.addObjectFile(fold.addOutputFileArg(b.fmt("{s}-{d}.a", .{ program.name, index })));
    }
    exe.entry = .{ .symbol_name = "_program_entry" };
    exe.link_emit_relocs = true;
    // A section per function, so each function's literal pool lies just
    // before its code (program.ld): an l32r reaches 256 KiB back, and a
    // program larger than that with one pool for all its code fails to
    // link.
    exe.link_function_sections = true;

    const convert = b.addRunArtifact(dep.artifact("elf2seg"));
    convert.addArtifactArg(exe);
    return convert.addOutputFileArg(b.fmt("{s}.seg", .{program.name}));
}
