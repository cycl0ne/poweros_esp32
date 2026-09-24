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
const interfaces = [_][]const u8{ "exec", "utility", "timer", "watchdog", "dma", "platform", "expander", "expansion", "gpio", "dos", "rtg", "graphics", "layers", "intuition", "input", "keymap", "console" };

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
    const test_step = b.step("test", "Check that every interface is up to date with its .fd file");
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
    const module = b.createModule(.{
        .root_source_file = program.root,
        .target = b.resolveTargetQuery(target_query),
        .optimize = program.optimize,
        .single_threaded = true,
        .unwind_tables = .none,
    });
    module.addImport("sdk", dep.module("sdk"));
    const artifact_name = b.dupe(program.name);
    for (artifact_name) |*char| if (char.* == '.' or char.* == '-') {
        char.* = '_';
    };
    const exe = b.addExecutable(.{ .name = artifact_name, .root_module = module });
    exe.setLinkerScript(dep.path("program.ld"));
    exe.entry = .{ .symbol_name = "_program_entry" };
    exe.link_emit_relocs = true;

    const convert = b.addRunArtifact(dep.artifact("elf2seg"));
    convert.addArtifactArg(exe);
    return convert.addOutputFileArg(b.fmt("{s}.seg", .{program.name}));
}
