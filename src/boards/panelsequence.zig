// SPDX-License-Identifier: MPL-2.0
//! A panel's bring-up sequence, as a board's list writes it down: the
//! bytes of `RTGA_InitSequence`, a step after another. A step is the
//! command, the number of its parameters, the milliseconds to wait after
//! it, then the parameters; rtg.library walks the bytes for the panel's
//! driver at bring-up (`RunPanelSequence`).

/// One step of a bring-up sequence: the command, the milliseconds to wait
/// after it, and its parameters. Steps join with `++`.
///
/// INPUTS:
/// - `cmd` - the command.
/// - `delay_ms` - how long to wait once it is sent, in milliseconds.
/// - `params` - its parameters, a tuple of bytes; `.{}` for none.
///
/// RESULT:
/// The step's bytes.
pub fn dcsStep(comptime cmd: u8, comptime delay_ms: u8, comptime params: anytype) [3 + params.len]u8 {
    var bytes: [3 + params.len]u8 = undefined;
    bytes[0] = cmd;
    bytes[1] = params.len;
    bytes[2] = delay_ms;
    inline for (params, 0..) |param, i| bytes[3 + i] = param;
    return bytes;
}
