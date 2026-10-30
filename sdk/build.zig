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

/// The ESP32-S3: what its programs are built for.
pub const target_query: std.Target.Query = .{
    .cpu_arch = .xtensa,
    .os_tag = .freestanding,
    .abi = .none,
    .cpu_model = .{ .explicit = &std.Target.xtensa.cpu.esp32s3 },
};

/// The chips code is built for.
pub const Chip = enum { esp32s3, esp32p4, rv64sbi, a64psci };

/// The ESP32-P4's HP cores: RV32IMAFC with the CSR and fence.i
/// instructions, and none of the chip's own extensions (PIE, hardware
/// loops), whose state no task carries yet.
pub const p4_target_query: std.Target.Query = .{
    .cpu_arch = .riscv32,
    .os_tag = .freestanding,
    .abi = .none,
    .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 },
    .cpu_features_add = std.Target.riscv.featureSet(&.{ .m, .a, .f, .c, .zicsr, .zifencei }),
};

/// A RISC-V 64 machine in supervisor mode under SBI firmware (OpenSBI):
/// QEMU's virt and the StarFive JH7110's U74 cores. RV64GC, so the LP64D
/// ABI: a task carries the D extension's FPU registers. Scheduled for the
/// U74: the instructions are RV64GC's alone, so QEMU runs the same code,
/// but LLVM knows the in-order core's latencies and fills them - without
/// it, a chain of FPU operations waits out every one.
pub const rv64_target_query: std.Target.Query = .{
    .cpu_arch = .riscv64,
    .os_tag = .freestanding,
    .abi = .none,
    .cpu_model = .{ .explicit = &std.Target.riscv.cpu.sifive_u74 },
    .cpu_features_add = std.Target.riscv.featureSet(&.{ .m, .a, .f, .d, .c, .zicsr, .zifencei }),
};

/// An AArch64 machine at EL1 under PSCI firmware: QEMU's virt with a
/// Cortex-A76, and the Raspberry Pi CM5's BCM2712, whose cores are A76s.
/// ARMv8.2-A with the LSE atomics, NEON and the AES and SHA instructions
/// (the BCM2712 has the crypto extension): a task carries the 32 vector
/// registers.
pub const a64_target_query: std.Target.Query = .{
    .cpu_arch = .aarch64,
    .os_tag = .freestanding,
    .abi = .none,
    .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a76 },
};

/// What a program for `chip` is built for. On the P4 without the linker's
/// relaxation: it may turn a PC-relative sequence into one that holds an
/// address, which would not survive the move to where the loader puts it.
pub fn programTargetQuery(chip: Chip) std.Target.Query {
    return switch (chip) {
        .esp32s3 => target_query,
        .esp32p4 => blk: {
            var query = p4_target_query;
            query.cpu_features_sub = std.Target.riscv.featureSet(&.{.relax});
            break :blk query;
        },
        .rv64sbi => blk: {
            var query = rv64_target_query;
            query.cpu_features_sub = std.Target.riscv.featureSet(&.{.relax});
            break :blk query;
        },
        .a64psci => a64_target_query,
    };
}

/// The libraries with an `.fd` file, each made into `interface/<name>.zig`.
const interfaces = [_][]const u8{ "exec", "utility", "timer", "watchdog", "dma", "platform", "expander", "expansion", "gpio", "jpeg", "videodec", "dos", "rtg", "rta", "graphics", "layers", "intuition", "input", "keymap", "console", "colorwheel", "bsdsocket", "crypto", "diskfont", "truetype", "asl", "iffparse", "commodities", "datatypes", "motion", "rdb", "tls", "modbus", "filter", "icon", "anvil", "usb", "usbclass", "battery", "usbport", "battclock", "battmem", "thermal", "audiocodec", "media", "videocodec", "wpa", "pci", "facet", "compression", "http", "locale" };

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

    // A program's strings into the module it is built with, and a
    // translation of them into a catalog file.
    const catcomp = b.addExecutable(.{
        .name = "catcomp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/catcomp/catcomp.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    b.installArtifact(catcomp);
    const catcomp_tests = b.addTest(.{ .root_module = catcomp.root_module });

    const fd_step = b.step("fd", "Generate the interfaces (interface/) from fd/");
    const test_step = b.step("test", "Check that every interface is up to date with its .fd file, and test the tools");
    test_step.dependOn(&b.addRunArtifact(addends_tests).step);
    test_step.dependOn(&b.addRunArtifact(romld_tests).step);
    test_step.dependOn(&b.addRunArtifact(catcomp_tests).step);

    // elf2seg refuses what a loaded RISC-V or AArch64 program could not
    // survive: absolute addresses in its code, and a direct call to a fixed
    // address.
    const refused = [_]struct { name: []const u8, root: []const u8, chip: Chip, code_model: std.builtin.CodeModel, says: []const u8 }{
        .{ .name = "absolute", .root = "tools/elf2seg/tests/absolute.zig", .chip = .esp32p4, .code_model = .medlow, .says = "an absolute address in the code" },
        .{ .name = "romcall", .root = "tools/elf2seg/tests/romcall.zig", .chip = .esp32p4, .code_model = .medany, .says = "a fixed address, PC-relatively" },
        .{ .name = "absolute_a64", .root = "tools/elf2seg/tests/absolute.zig", .chip = .a64psci, .code_model = .large, .says = "an absolute address in the code" },
        .{ .name = "romcall_a64", .root = "tools/elf2seg/tests/romcall.zig", .chip = .a64psci, .code_model = .small, .says = "a fixed address, PC-relatively" },
    };
    for (refused) |case| {
        const exe = b.addExecutable(.{ .name = case.name, .root_module = b.createModule(.{
            .root_source_file = b.path(case.root),
            .target = b.resolveTargetQuery(programTargetQuery(case.chip)),
            .optimize = .ReleaseSmall,
            .strip = false,
            .single_threaded = true,
            .unwind_tables = .none,
            .code_model = case.code_model,
        }) });
        exe.entry = .{ .symbol_name = "_program_entry" };
        exe.link_emit_relocs = true;
        exe.setLinkerScript(b.path(if (case.chip == .a64psci) "program_a64psci.ld" else "program_esp32p4.ld"));
        const convert = b.addRunArtifact(elf2seg);
        convert.addArtifactArg(exe);
        _ = convert.addOutputFileArg(b.fmt("{s}.seg", .{case.name}));
        convert.expectExitCode(1);
        convert.expectStdErrMatch(case.says);
        test_step.dependOn(&convert.step);
    }
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

/// A program's strings, from its catalog descriptor (`.cd`), as the module
/// it imports (tools/catcomp): their numbers, the strings built in, and the
/// catalog's name and version for sdk.locale's `Strings`. `catalog_name` is
/// the name locale.library looks the catalog up by - the program's place
/// on the disk and `.catalog` (`c/test/locale.catalog`).
pub fn addStrings(b: *std.Build, dep: *std.Build.Dependency, descriptor: std.Build.LazyPath, catalog_name: []const u8) *std.Build.Module {
    const run = b.addRunArtifact(dep.artifact("catcomp"));
    run.addArg("strings");
    run.addFileArg(descriptor);
    run.addArg(catalog_name);
    const module = run.addOutputFileArg("strings.zig");
    return b.createModule(.{ .root_source_file = module });
}

/// A translation (`.ct`) of a program's strings as the catalog file that
/// goes on the disk at `LOCALE:Catalogs/<language>/<catalog_name>`
/// (tools/catcomp), checked against the descriptor.
pub fn addCatalog(b: *std.Build, dep: *std.Build.Dependency, descriptor: std.Build.LazyPath, translation: std.Build.LazyPath, catalog_name: []const u8) std.Build.LazyPath {
    const run = b.addRunArtifact(dep.artifact("catcomp"));
    run.addArg("catalog");
    run.addFileArg(descriptor);
    run.addFileArg(translation);
    run.addArg(catalog_name);
    return run.addOutputFileArg(std.fs.path.basename(catalog_name));
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
    /// The chip it runs on.
    chip: Chip = .esp32s3,
    /// Foreign archives linked in (`.a`): code built by GCC for the same
    /// chip and the windowed ABI, such as the radio's vendor libraries.
    /// Each goes through tools/addends first; only what the program
    /// reaches is kept.
    archives: []const std.Build.LazyPath = &.{},
    /// Linker scripts that name the chip ROM's functions and data, for
    /// archives that call into mask ROM; their addresses are added to
    /// `program.ld` (tools/romld) and left alone by elf2seg.
    rom_scripts: []const std.Build.LazyPath = &.{},
    /// Modules compiled into it beside the SDK, by the names it imports
    /// them by: code of the disk's own that a program shares with another
    /// rather than loading it.
    imports: []const std.Build.Module.Import = &.{},
};

/// A program, library, device or handler built for the chip and made into
/// a load file: the `.seg` dos's LoadSeg reads. What goes on the disk.
///
/// It is linked with the SDK's `program.ld` (`program_esp32p4.ld` on the
/// P4 and `program_rv64sbi.ld` on RV64, where the code is PC-relative,
/// -mcmodel=medany; `program_a64psci.ld` on AArch64, where it is too, by
/// ADRP pairs - the small code model - and the loader keeps its 4 KiB
/// pages where they were) and with the
/// linker's relocations kept (`--emit-relocs`); `elf2seg` keeps the ones
/// that hold an address and makes the load file from them. The entry is
/// `_program_entry`, which a command exports; a module's ROM tag is what
/// ramlib or dos finds in it instead.
pub fn addProgram(b: *std.Build, dep: *std.Build.Dependency, program: Program) std.Build.LazyPath {
    const target = b.resolveTargetQuery(programTargetQuery(program.chip));
    const code_model: std.builtin.CodeModel = switch (program.chip) {
        .esp32s3 => .default,
        .esp32p4, .rv64sbi => .medany,
        .a64psci => .small,
    };
    const own = b.createModule(.{
        .root_source_file = program.root,
        .target = target,
        .optimize = program.optimize,
        .single_threaded = true,
        .unwind_tables = .none,
        .code_model = code_model,
    });
    own.addImport("sdk", dep.module("sdk"));
    for (program.imports) |import| own.addImport(import.name, import.module);
    // The root is the SDK's program.zig, which takes the program's own
    // root in and gives it the SDK's panic handler.
    const module = b.createModule(.{
        .root_source_file = dep.path("program.zig"),
        .target = target,
        .optimize = program.optimize,
        .single_threaded = true,
        .unwind_tables = .none,
        .code_model = code_model,
    });
    module.addImport("sdk", dep.module("sdk"));
    module.addImport("program", own);
    const artifact_name = b.dupe(program.name);
    for (artifact_name) |*char| if (char.* == '.' or char.* == '-') {
        char.* = '_';
    };
    const exe = b.addExecutable(.{ .name = artifact_name, .root_module = module });
    const script_name = switch (program.chip) {
        .esp32s3 => "program.ld",
        .esp32p4 => "program_esp32p4.ld",
        .rv64sbi => "program_rv64sbi.ld",
        .a64psci => "program_a64psci.ld",
    };
    if (program.rom_scripts.len == 0) {
        exe.setLinkerScript(dep.path(script_name));
    } else {
        const merge = b.addRunArtifact(dep.artifact("romld"));
        merge.addFileArg(dep.path(script_name));
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
