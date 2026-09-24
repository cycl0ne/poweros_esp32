// SPDX-License-Identifier: MPL-2.0
//! What the division calls share: the alert a zero divisor raises.

const sdk = @import("sdk");

/// The divide-by-zero exception (number 5), as the dead-end alert exec
/// shows for it.
pub const ACPU_DivZero: u32 = sdk.exec.ACPU_Base | 5;
