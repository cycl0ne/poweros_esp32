// SPDX-License-Identifier: MIT
//! What model.datatype's object and its process share: the model as it
//! was handed over, the camera, the room it is drawn in, and the three
//! pictures a frame is drawn into.
//!
//! **Three pictures** - one on show, one drawn and waiting to be, one
//! being drawn. The process takes a free one, draws the frame into it and
//! makes it ready, dropping one that was ready and not yet shown: the
//! last frame drawn is the one shown, and a frame that came between is
//! never seen. `GM_RENDER` makes the ready one the one on show, frees the
//! one before, and puts it in the window. A picture is only read by
//! `GM_RENDER` while it holds it (`Slot.readers`), and the process takes
//! none that is held, so it never draws into or gives back a picture
//! being put in a window.
//!
//! Everything here moves under `Data.lock`, a spinlock, held only while
//! numbers move.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const gadgets = sdk.gadgets;
const mdt = sdk.datatypes.modelclass;
const classes = sdk.intuition.classes;

pub const slot_count = 3;

pub const FREE: u8 = 0;
pub const DRAWING: u8 = 1;
pub const READY: u8 = 2;
pub const SHOWN: u8 = 3;

/// One of the pictures a frame is drawn into, as `GM_RENDER` sees it: its
/// pixels in the screen's format, mapped from facet.library's memory.
pub const Slot = extern struct {
    pixels: ?[*]const u8 = null,
    pitch: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// A `PixelFormat`.
    format: u32 = 0,
    state: u8 = FREE,
    /// How many `GM_RENDER`s are putting it in a window now.
    readers: u8 = 0,
    pad: [2]u8 = @splat(0),
};

/// A material as handed over: its colour, and its picture staged as a
/// texture's levels (levels.zig) until the process has copied them in.
pub const Material = extern struct {
    color: graphics.Pen = 0xFFFF_FFFF,
    texture: ?[*]u8 = null,
    texture_width: u32 = 0,
    texture_height: u32 = 0,
    texture_levels: u32 = 0,
};

pub const Part = extern struct {
    first: u32 = 0,
    count: u32 = 0,
    material: u32 = mdt.NO_MATERIAL,
};

/// A format intuition does not name: the room has not been laid out yet.
pub const unknown_format: u32 = 0xFF;

/// model.datatype's part of an object.
pub const Data = extern struct {
    lock: exec.Lock = .{},

    // The model, as the format class handed it over.
    header: mdt.ModelHeader = .{},
    /// The header was set, and its memory had.
    held: bool = false,
    /// It turns by itself (`STM_PLAY`).
    turning: bool = false,
    /// The pointer is turning it.
    dragging: bool = false,
    quitting: bool = false,
    started: bool = false,
    pad: [3]u8 = @splat(0),
    /// Given back by the process once copied in.
    vertices: ?[*]mdt.ModelVertex = null,
    indices: ?[*]u32 = null,
    materials: ?[*]Material = null,
    parts: ?[*]Part = null,

    // The camera (camera.Camera).
    yaw: f32 = 0,
    pitch: f32 = 0,
    zoom: f32 = 1,
    /// Where the pointer was when the camera was last turned by it.
    drag_x: i32 = 0,
    drag_y: i32 = 0,

    // The room: its size, the screen's pixels and the ground's colour.
    width: u32 = 0,
    height: u32 = 0,
    format: u32 = unknown_format,
    ground: graphics.Pen = 0xFF00_0000,
    /// Counted up by every change of the camera or the room: the process
    /// draws again while what it last drew is behind it.
    changes: u32 = 0,

    slots: [slot_count]Slot = @splat(.{}),
    /// The slot on show, or -1.
    shown: i32 = -1,
    /// Why nothing is drawn, shown in the room instead; null while all is
    /// well. The words are the class's own and last.
    trouble: ?[*:0]const u8 = null,

    object: ?*classes.Object = null,
    base: ?*gadgets.Base = null,
    /// The process, and what it holds for as long as it runs.
    renderer: ?*exec.Task = null,
    alive: exec.SignalSemaphore = .{},
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    pad2: [3]u8 = @splat(0),
};
