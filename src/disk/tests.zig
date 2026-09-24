// SPDX-License-Identifier: MIT
//! Host tests of the modules on the disk: the parts of each that need no
//! hardware. Some of them bring up exec and utility.library the way the
//! ROM's own tests do, through the named import `host_rom`, which the
//! system's build hands this root when it runs them.

test {
    _ = @import("devs/sd/card.zig");
    _ = @import("handlers/fat/_fat.zig");
    _ = @import("handlers/fat/testmedia.zig");
    _ = @import("handlers/fat/cache.zig");
    _ = @import("handlers/fat/fat32/layout.zig");
    _ = @import("handlers/fat/fat32/table.zig");
    _ = @import("handlers/fat/fat32/names.zig");
    _ = @import("handlers/fat/fat32/dir.zig");
    _ = @import("handlers/fat/fat32/fs.zig");
    _ = @import("handlers/fat/fat.zig");
    _ = @import("handlers/fat/tests/_fat.zig");
    _ = @import("handlers/fat/tests/names.zig");
    _ = @import("handlers/fat/tests/dir.zig");
    _ = @import("handlers/fat/tests/fs.zig");
}
