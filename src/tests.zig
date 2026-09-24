// SPDX-License-Identifier: MPL-2.0
//! Host test root (./zig build test) for the ROM's modules. The disk's
//! modules are tested from their own package's `tests.zig`, which reaches
//! the ROM's exec and utility.library through `host_rom.zig`.

test {
    _ = @import("rom/tests.zig");
}
