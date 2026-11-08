// SPDX-License-Identifier: MIT
//! The parameter sets as the decoder takes them - videoparse.library's,
//! read there, their scaling lists resolved.

const hevc = @import("sdk").videoparse.hevc;

pub const ScalingList = hevc.HevcScaling;
pub const Sps = hevc.HevcSps;
pub const Pps = hevc.HevcPps;
pub const max_tile_columns = hevc.max_tile_columns;
pub const max_tile_rows = hevc.max_tile_rows;
