// SPDX-License-Identifier: MIT
//! The slice segment header as the decoder takes it: videoparse.library's,
//! read there.

const hevc = @import("sdk").videoparse.hevc;

pub const SliceType = hevc.HevcSliceType;
pub const Weights = hevc.HevcWeights;
pub const Header = hevc.HevcSliceHeader;
pub const max_refs = hevc.max_refs;
