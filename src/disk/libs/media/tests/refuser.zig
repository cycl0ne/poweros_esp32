// SPDX-License-Identifier: MIT
//! A container module for a host test that claims a kind and then refuses
//! every file of it: MP4, at a priority above mp4.container's, so the
//! library tries it first and must give the file to mp4.container after
//! it.

const sdk = @import("sdk");
const exec = sdk.exec;
const media = sdk.media;
const mcontainer = sdk.mcontainer;
const module = @import("../mcontainer_module.zig");

const File = mcontainer.MediaContainerFile;
const Track = mcontainer.MContainerTrack;

/// How often it was asked to open a file: a test sees it was tried first.
pub var asked: u32 = 0;

const Kind = struct {
    pub fn open(_: *File, _: bool) i32 {
        asked += 1;
        return media.MERR_UNSUPPORTED;
    }

    pub fn read(_: *File, _: *Track, _: *media.MediaPacket) i32 {
        return media.MERR_UNSUPPORTED;
    }

    pub fn seek(_: *File, _: *Track, _: i64) i32 {
        return media.MERR_UNSUPPORTED;
    }
};

pub const Module = module.Module(0, Kind);

pub export const refuse_container_tag: mcontainer.ResidentMContainer = .{
    .resident = .{
        .match_tag = @ptrCast(&refuse_container_tag),
        .flags = exec.RTF_AUTOINIT,
        .version = 1,
        .type = .library,
        .pri = 0,
        .name = "refuse.container",
        .id_string = "refuse.container 1.0 (a test's)",
        .init = &Module.init_table,
    },
    .kinds = mcontainer.kindBit(media.MEDIA_MP4),
    .priority = 10,
};
