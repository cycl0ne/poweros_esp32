// SPDX-License-Identifier: MIT
//! The sound modules for a host test: each made from its ROM tag, under
//! the name ramlib finds it by on a disk, as exec's own search looks for
//! it. Taken away with the library.

const sdk = @import("sdk");
const exec = sdk.exec;
const wav_init = @import("../wav/wav_init.zig");
const mp3_init = @import("../mp3/mp3_init.zig");
const flac_init = @import("../flac/flac_init.zig");
const vorbis_init = @import("../vorbis/vorbis_init.zig");
const aac_init = @import("../aac/aac_init.zig");
const ac3_init = @import("../ac3/ac3_init.zig");
const opus_init = @import("../opus/opus_init.zig");
const dts_init = @import("../dts/dts_init.zig");

const ExecBase = sdk.interface.exec.ExecBase;

const tags = [_]struct { tag: *const exec.Resident, name: [*:0]const u8 }{
    .{ .tag = &wav_init.wav_acodec_tag.resident, .name = "codecs/wav.acodec" },
    .{ .tag = &mp3_init.mp3_acodec_tag.resident, .name = "codecs/mp3.acodec" },
    .{ .tag = &flac_init.flac_acodec_tag.resident, .name = "codecs/flac.acodec" },
    .{ .tag = &vorbis_init.vorbis_acodec_tag.resident, .name = "codecs/vorbis.acodec" },
    .{ .tag = &aac_init.aac_acodec_tag.resident, .name = "codecs/aac.acodec" },
    .{ .tag = &ac3_init.ac3_acodec_tag.resident, .name = "codecs/ac3.acodec" },
    .{ .tag = &opus_init.opus_acodec_tag.resident, .name = "codecs/opus.acodec" },
    .{ .tag = &dts_init.dts_acodec_tag.resident, .name = "codecs/dts.acodec" },
};

pub const Made = [tags.len]*exec.Library;

/// MP3's module, among them.
pub const mp3 = 1;
/// Opus's: a test that takes its name away has a kind the library knows
/// and this disk cannot decode, as a board without the module has.
pub const opus = 6;

pub fn make(kexec: anytype, made: *Made) !void {
    for (tags, made) |entry, *lib| {
        const library = kexec.InitResident(kexec.SysBase, entry.tag, null) orelse return error.NoLibrary;
        lib.* = @ptrCast(@alignCast(library));
        lib.*.node.name = entry.name;
    }
}

pub fn take(sys: *ExecBase, made: *const Made) void {
    for (made) |lib| _ = sys.RemLibrary(lib);
}
