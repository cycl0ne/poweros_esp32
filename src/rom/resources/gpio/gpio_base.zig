// SPDX-License-Identifier: MPL-2.0
//! gpio.resource's base: who holds each pad.

const sdk = @import("sdk");
const exec = sdk.exec;
const types = sdk.resources.gpio;
const ExecBase = sdk.interface.exec.ExecBase;

pub const GpioBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// Each pad's holder, the name it was taken for; null: free.
    owner: [types.GPIO_PADS]?[*:0]const u8,
};
