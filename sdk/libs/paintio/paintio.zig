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
//!   - `CYCL`: the palette's ranges that cycle, four bytes each - the
//!     first place, the last, the speed in steps a second, and the flags
//!     (`RANGEF_`). Only when one turns.
//!   - For each layer, from the bottom: `LHDR` - its opacity, its flags
//!     (`LAYERF_`) and its blend mode (`LAYERBLEND_`), a byte each, a byte
//!     of 0, and its name, UTF-8 - and then its `BODY`: the rows, alpha, red, green and blue a byte each a
//!     pixel, packed by Deflate in a zlib wrapping (compression.library).
//!     A layer with a mask has an `LMSK` after its `BODY`: the mask's
//!     rows, a byte a pixel, packed the same way.
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
/// A layer's mask. Since 1.2.
pub const ID_LMSK = iffparse.MakeID("LMSK");
/// The palette's ranges. Since 1.3.
pub const ID_CYCL = iffparse.MakeID("CYCL");

/// The largest side of a project.
pub const MAX_SIDE: u32 = 16384;
/// The most layers a project has.
pub const MAX_LAYERS: u32 = 64;
/// The most colours a palette has.
pub const MAX_PALETTE: u32 = 256;
/// The ranges a project keeps. Since 1.3.
pub const MAX_RANGES: u32 = 4;
/// The bytes a layer's name has room for, its NUL among them.
pub const NAME_SIZE = 32;

/// `Layer.flags`: the layer is not shown, nor counted in a picture made
/// of the project.
pub const LAYERF_HIDDEN: u8 = 1 << 0;

/// `Range.flags`: it turns the other way. Since 1.3.
pub const RANGEF_BACKWARDS: u8 = 1 << 0;

/// A run of the palette's colours that turns while they cycle: the
/// places `first` to `last`, `speed` steps a second, none for a range
/// that stands still. Since 1.3.
pub const Range = extern struct {
    first: u8 = 0,
    last: u8 = 0,
    speed: u8 = 0,
    flags: u8 = 0,
};

/// `Layer.blend`: how a layer's colours are put together with those of
/// what is under it, before its opacity and its alpha lay the result over
/// them. A blend mode past the last is read as normal.
/// Its own colours.
pub const LAYERBLEND_NORMAL: u8 = 0;
/// The two added.
pub const LAYERBLEND_ADD: u8 = 1;
/// Multiplied: never lighter than either.
pub const LAYERBLEND_MULTIPLY: u8 = 2;
/// The opposites multiplied: never darker than either.
pub const LAYERBLEND_SCREEN: u8 = 3;
/// Multiply where what is under is dark, screen where it is light.
pub const LAYERBLEND_OVERLAY: u8 = 4;
/// The darker of the two, each of red, green and blue.
pub const LAYERBLEND_DARKEN: u8 = 5;
/// The lighter of the two, each of red, green and blue.
pub const LAYERBLEND_LIGHTEN: u8 = 6;
/// What is under made lighter, the more the lighter the layer is.
pub const LAYERBLEND_COLOUR_DODGE: u8 = 7;
/// What is under made darker, the more the darker the layer is.
pub const LAYERBLEND_COLOUR_BURN: u8 = 8;
/// Multiply where the layer is dark, screen where it is light.
pub const LAYERBLEND_HARD_LIGHT: u8 = 9;
/// A gentler hard light.
pub const LAYERBLEND_SOFT_LIGHT: u8 = 10;
/// The layer's hue, with the saturation and the brightness of what is
/// under.
pub const LAYERBLEND_HUE: u8 = 11;
/// The layer's saturation, with the hue and the brightness of what is
/// under.
pub const LAYERBLEND_SATURATION: u8 = 12;
/// The layer's hue and saturation, with the brightness of what is under.
pub const LAYERBLEND_COLOUR: u8 = 13;
/// The layer's brightness, with the hue and the saturation of what is
/// under.
pub const LAYERBLEND_LUMINOSITY: u8 = 14;
pub const LAYERBLEND_LAST: u8 = LAYERBLEND_LUMINOSITY;

/// One layer of a project.
pub const Layer = extern struct {
    /// `width` times `height` pixels, `0xAARRGGBB`.
    pixels: ?[*]u32 = null,
    /// Its mask, `width` times `height` bytes: how much of each pixel
    /// shows, 0 none and 255 all. Null for a layer without one. Since
    /// 1.2.
    mask: ?[*]u8 = null,
    /// UTF-8, ended by a NUL.
    name: [NAME_SIZE]u8 = @splat(0),
    /// How much of it shows over what is under it, 255 all of it.
    opacity: u8 = 255,
    flags: u8 = 0,
    /// `LAYERBLEND_`. Since 1.1.
    blend: u8 = LAYERBLEND_NORMAL,
    pad: u8 = 0,
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
    /// The palette's ranges. Since 1.3.
    ranges: [MAX_RANGES]Range = @splat(.{}),
};
