// SPDX-License-Identifier: MIT
//! paintio.library's types: Paint's projects and pictures, read from and
//! written to files.
//!
//! The library is Paint's own and lives in its drawer: Paint opens it by
//! its path, `PAINTIOPATH`, the first time it reads or writes a file, and
//! ramlib loads it in Paint's process, where `PROGDIR:` is that drawer.
//!
//! A project is a picture as Paint keeps it: its size, its layers from the
//! bottom up, the layer being painted and the palette. Every layer is the
//! project's size, a pixel `0xAARRGGBB` in a `u32`, a row after another
//! with nothing between the rows; its pixels are the caller's when it saves
//! and the library's, from `AllocVec`, when it loads, which `FreeProject`
//! gives back.
//!
//! **The file** is an IFF `FORM PNTG`, every number big-endian:
//!
//!   - `PHDR`: the width, the height, the number of layers and the layer
//!     being painted, a `u32` each.
//!   - `PALT`: the palette, a `u32` `0xAARRGGBB` a colour.
//!   - For each layer, from the bottom: `LHDR` - its opacity and its flags
//!     (`LAYERF_`), a byte each, two bytes of 0, and its name, UTF-8 - and
//!     then its `BODY`: the rows, alpha, red, green and blue a byte each a
//!     pixel, packed by Deflate in a zlib wrapping (compression.library).
//!
//! A chunk the reader does not know is passed over, so what a later Paint
//! adds does not keep an earlier one from reading the rest.

const iffparse = @import("../iffparse/iffparse.zig");

pub const PAINTIONAME = "paintio.library";
/// Where Paint opens it from: its own drawer.
pub const PAINTIOPATH = "PROGDIR:Libs/paintio.library";

pub const ID_PNTG = iffparse.MakeID("PNTG");
pub const ID_PHDR = iffparse.MakeID("PHDR");
pub const ID_PALT = iffparse.MakeID("PALT");
pub const ID_LHDR = iffparse.MakeID("LHDR");
pub const ID_BODY = iffparse.MakeID("BODY");

/// The largest side of a project.
pub const MAX_SIDE: u32 = 16384;
/// The most layers a project has.
pub const MAX_LAYERS: u32 = 64;
/// The most colours a palette has.
pub const MAX_PALETTE: u32 = 256;
/// The bytes a layer's name has room for, its NUL among them.
pub const NAME_SIZE = 32;

/// `Layer.flags`: the layer is not shown, nor counted in a picture made
/// of the project.
pub const LAYERF_HIDDEN: u8 = 1 << 0;

/// One layer of a project.
pub const Layer = extern struct {
    /// `width` times `height` pixels, `0xAARRGGBB`.
    pixels: ?[*]u32 = null,
    /// UTF-8, ended by a NUL.
    name: [NAME_SIZE]u8 = @splat(0),
    /// How much of it shows over what is under it, 255 all of it.
    opacity: u8 = 255,
    flags: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
};

/// `Project.kind`: what `LoadProject` read.
pub const PIOKIND_PROJECT: u32 = 0;
/// A picture, read through datatypes: one layer, no palette.
pub const PIOKIND_PICTURE: u32 = 1;

/// `SavePicture`'s formats.
pub const PIOFORMAT_PNG: u32 = 0;
pub const PIOFORMAT_ILBM: u32 = 1;

pub const Project = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    layer_count: u32 = 0,
    /// The layer being painted, from 0 at the bottom.
    current: u32 = 0,
    layers: ?[*]Layer = null,
    /// `PIOKIND_`: what was read; not written.
    kind: u32 = PIOKIND_PROJECT,
    palette_count: u32 = 0,
    palette: [MAX_PALETTE]u32 = @splat(0),
};
