// SPDX-License-Identifier: MIT
//! truetypeshaping.library's shaping, for a tool on the host: a text
//! shaped (`text`) with the font (`shape`'s `Font`) and the memory
//! (`buffer`'s `Memory`) the tool hands it - the same code the library's
//! calls are made of, without its jump table. tools/svgcompare lays text
//! out with it.

pub const text = @import("shape/_text.zig");
pub const shape = @import("shape/_shape.zig");
pub const buffer = @import("shape/_buffer.zig");
