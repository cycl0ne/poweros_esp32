// SPDX-License-Identifier: MIT
//! model.datatype: what every model in three dimensions is, whatever file
//! it came out of - the header a format's class sets, the methods it hands
//! the model over with, and what a program reads back.
//!
//! A format's class - OBJ - is a subclass, and reads its file and nothing
//! more, as a picture's class does. In `OM_NEW` it sets `MDTA_ModelHeader`
//! on itself, which says how much there is and gives the object its
//! memory, and then hands the vertices, the indices, the materials and
//! the parts over (`MDTM_WRITEVERTICES`, `MDTM_WRITEINDICES`,
//! `MDTM_WRITEMATERIAL`, `MDTM_WRITEPART`). A material's picture is
//! opened through the picture datatypes and handed over as the object it
//! is. Drawing, turning and looking are the superclass's, so a format
//! class has no `GM_RENDER`.
//!
//! **The model is drawn by facet.library** on a process of the object's
//! own, into pictures in the screen's pixels, and put in the window as
//! they are by `GM_RENDER`. Dragging the pointer over it turns it round
//! its middle and the wheel takes it nearer or further; those only move
//! the camera, and the process draws from wherever the camera is when it
//! begins a frame. Nothing is drawn while nothing changes. `DTM_TRIGGER`
//! with `STM_PLAY` turns it by itself until `STM_PAUSE`, which turns over,
//! or `STM_STOP`, which also takes it back to where it started. A machine
//! without facet.library, or a screen it cannot draw on, shows that in
//! the object's room instead.
//!
//! The model has no size of its own: it fills whatever room it is given,
//! and that room is all there is of it (`DTA_TotalVert` and
//! `DTA_VisibleVert` alike), so it has nothing to scroll.

const classusr = @import("../intuition/classusr.zig");
const graphics = @import("../graphics/graphics.zig");
const dtc = @import("datatypesclass.zig");

/// The class library, and the class it holds.
pub const MODEL_LIBRARY = "datatypes/model.datatype";
pub const MODELDTCLASS = "model.datatype";

pub const MDTA_Dummy = dtc.DTA_Dummy + 700;
/// The model's shape (`*ModelHeader`). Set once, by the format class in
/// `OM_NEW` before anything is written: setting it is what gives the
/// object its memory. Read by anyone.
pub const MDTA_ModelHeader = MDTA_Dummy + 1;
/// Bool (get only): whether it turns by itself.
pub const MDTA_Turning = MDTA_Dummy + 50;

/// The methods. Each answers 1 when it took what it was given, 0 when it
/// is past what the header said there is, or there is no header yet.
pub const MDTM_Dummy: classusr.MethodID = 0x730;
/// Vertices given to the object, which keeps them.
pub const MDTM_WRITEVERTICES: classusr.MethodID = 0x731;
/// Indices into them, three a triangle.
pub const MDTM_WRITEINDICES: classusr.MethodID = 0x732;
/// What a part is drawn with: a colour, and a picture over it.
pub const MDTM_WRITEMATERIAL: classusr.MethodID = 0x733;
/// A run of the triangles, drawn with one material.
pub const MDTM_WRITEPART: classusr.MethodID = 0x734;

/// A corner of a triangle: where it is, which way it faces, and where on
/// its material's picture it lies - 0 to 1 across and down from the top
/// left, repeated past that.
pub const ModelVertex = extern struct {
    position: [3]f32,
    /// One long; the light falls on either side alike.
    normal: [3]f32,
    uv: [2]f32,
};

/// How much there is of a model, and the box it fills.
pub const ModelHeader = extern struct {
    vertices: u32 = 0,
    /// Three a triangle.
    indices: u32 = 0,
    materials: u32 = 0,
    parts: u32 = 0,
    /// The least and the greatest x, y and z of the vertices: where the
    /// camera looks, and how far back it stands to see all of it.
    low: [3]f32 = .{ 0, 0, 0 },
    high: [3]f32 = .{ 0, 0, 0 },
};

/// `MDTM_WRITEVERTICES`: `count` vertices, from vertex `first` on.
pub const MdtWriteVertices = extern struct {
    method_id: classusr.MethodID = MDTM_WRITEVERTICES,
    vertices: [*]const ModelVertex,
    first: u32 = 0,
    count: u32 = 0,
};

/// `MDTM_WRITEINDICES`: `count` indices, from index `first` on, each a
/// vertex's number.
pub const MdtWriteIndices = extern struct {
    method_id: classusr.MethodID = MDTM_WRITEINDICES,
    indices: [*]const u32,
    first: u32 = 0,
    count: u32 = 0,
};

/// `MDTM_WRITEMATERIAL`: material `material`'s colour, 0xAARRGGBB, and
/// the picture over it, a picture.datatype object, or null. The picture
/// is the model's from the call on, whatever it answers, and is disposed
/// of by it: it is read at once into a texture - its sides made powers of
/// two, no more than 1024 - and not kept. A colour of a material with a
/// picture tints it, as an MTL's `Kd` does its `map_Kd`.
pub const MdtWriteMaterial = extern struct {
    method_id: classusr.MethodID = MDTM_WRITEMATERIAL,
    material: u32 = 0,
    color: graphics.Pen = 0xFFFF_FFFF,
    picture: ?*classusr.Object = null,
};

/// `MDTM_WRITEPART`: part `part` is `count` indices from index `first`
/// on - a multiple of three - drawn with material `material`, or
/// `NO_MATERIAL`.
pub const MdtWritePart = extern struct {
    method_id: classusr.MethodID = MDTM_WRITEPART,
    part: u32 = 0,
    first: u32 = 0,
    count: u32 = 0,
    material: u32 = NO_MATERIAL,
};

/// A part with no material of its own: drawn light grey.
pub const NO_MATERIAL: u32 = 0xFFFF_FFFF;
