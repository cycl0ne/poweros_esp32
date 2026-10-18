// SPDX-License-Identifier: MPL-2.0
//! What posfs needs of a medium, and the one shape every medium takes for
//! it: the device behind the handler (posfs.zig), the image the host tool
//! builds (tools/mkfs), and the tests' media (testmedia.zig).
//!
//! A medium is an area of bytes, addressed from its first. It says how
//! large its blocks are (`sectorSize`), what one write programs at least
//! (`writeSize`: flash's page, 0 for a disk, which writes whole sectors),
//! whether it must be erased before it is written and in what units
//! (`eraseSize`, 0 for none), and whether it can be read as memory
//! (`mapped`: flash.device maps its unit into the data window). `update`
//! is the barrier: everything written before it is on the medium itself
//! when it returns - a USB stick's own cache included.
//!
//! The file system sees it as a `Device`: the medium's address and a table
//! of its calls, so that the file system is one piece of code whatever it
//! runs on rather than one copy per kind of medium.

pub const Ops = struct {
    size: *const fn (ctx: *anyopaque) u64,
    sectorSize: *const fn (ctx: *anyopaque) u32,
    writeSize: *const fn (ctx: *anyopaque) u32,
    eraseSize: *const fn (ctx: *anyopaque) u32,
    mapped: *const fn (ctx: *anyopaque) ?[*]const u8,
    read: *const fn (ctx: *anyopaque, at: u64, into: []u8) bool,
    write: *const fn (ctx: *anyopaque, at: u64, from: []const u8) bool,
    erase: *const fn (ctx: *anyopaque, at: u64, len: u64) bool,
    update: *const fn (ctx: *anyopaque) bool,
    writable: *const fn (ctx: *anyopaque) bool,
    alloc: *const fn (ctx: *anyopaque, len: usize) ?[]u8,
    allocRaw: *const fn (ctx: *anyopaque, len: usize) ?[]u8,
    free: *const fn (ctx: *anyopaque, memory: []u8) void,
    now: *const fn (ctx: *anyopaque) u64,
    random: *const fn (ctx: *anyopaque, into: *[16]u8) void,
};

/// A medium as the file system calls it.
pub const Device = struct {
    ctx: *anyopaque,
    ops: *const Ops,

    /// The device for a medium of type `T`, whose methods have the names
    /// and shapes of `Ops`'s fields.
    pub fn of(comptime T: type, media: *T) Device {
        return .{ .ctx = media, .ops = &OpsOf(T).ops };
    }

    pub fn size(dev: Device) u64 {
        return dev.ops.size(dev.ctx);
    }
    pub fn sectorSize(dev: Device) u32 {
        return dev.ops.sectorSize(dev.ctx);
    }
    pub fn writeSize(dev: Device) u32 {
        return dev.ops.writeSize(dev.ctx);
    }
    pub fn eraseSize(dev: Device) u32 {
        return dev.ops.eraseSize(dev.ctx);
    }
    pub fn mapped(dev: Device) ?[*]const u8 {
        return dev.ops.mapped(dev.ctx);
    }
    pub fn read(dev: Device, at: u64, into: []u8) bool {
        return dev.ops.read(dev.ctx, at, into);
    }
    pub fn write(dev: Device, at: u64, from: []const u8) bool {
        return dev.ops.write(dev.ctx, at, from);
    }
    pub fn erase(dev: Device, at: u64, len: u64) bool {
        return dev.ops.erase(dev.ctx, at, len);
    }
    pub fn update(dev: Device) bool {
        return dev.ops.update(dev.ctx);
    }
    pub fn writable(dev: Device) bool {
        return dev.ops.writable(dev.ctx);
    }
    /// Eight-byte aligned and cleared, as AllocVec's are.
    pub fn alloc(dev: Device, len: usize) ?[]u8 {
        return dev.ops.alloc(dev.ctx, len);
    }
    /// Eight-byte aligned and not cleared: for memory that is filled
    /// whole before it is read.
    pub fn allocRaw(dev: Device, len: usize) ?[]u8 {
        return dev.ops.allocRaw(dev.ctx, len);
    }
    pub fn free(dev: Device, memory: []u8) void {
        dev.ops.free(dev.ctx, memory);
    }
    /// Microseconds since 1 Jan 1978.
    pub fn now(dev: Device) u64 {
        return dev.ops.now(dev.ctx);
    }
    /// Sixteen bytes no other volume is likely to have.
    pub fn random(dev: Device, into: *[16]u8) void {
        dev.ops.random(dev.ctx, into);
    }
};

fn OpsOf(comptime T: type) type {
    return struct {
        fn self(ctx: *anyopaque) *T {
            return @ptrCast(@alignCast(ctx));
        }
        fn size(ctx: *anyopaque) u64 {
            return self(ctx).size();
        }
        fn sectorSize(ctx: *anyopaque) u32 {
            return self(ctx).sectorSize();
        }
        fn writeSize(ctx: *anyopaque) u32 {
            return self(ctx).writeSize();
        }
        fn eraseSize(ctx: *anyopaque) u32 {
            return self(ctx).eraseSize();
        }
        fn mapped(ctx: *anyopaque) ?[*]const u8 {
            return self(ctx).mapped();
        }
        fn read(ctx: *anyopaque, at: u64, into: []u8) bool {
            return self(ctx).read(at, into);
        }
        fn write(ctx: *anyopaque, at: u64, from: []const u8) bool {
            return self(ctx).write(at, from);
        }
        fn erase(ctx: *anyopaque, at: u64, len: u64) bool {
            return self(ctx).erase(at, len);
        }
        fn update(ctx: *anyopaque) bool {
            return self(ctx).update();
        }
        fn writable(ctx: *anyopaque) bool {
            return self(ctx).writable();
        }
        fn alloc(ctx: *anyopaque, len: usize) ?[]u8 {
            return self(ctx).alloc(len);
        }
        fn allocRaw(ctx: *anyopaque, len: usize) ?[]u8 {
            return self(ctx).allocRaw(len);
        }
        fn free(ctx: *anyopaque, memory: []u8) void {
            self(ctx).free(memory);
        }
        fn now(ctx: *anyopaque) u64 {
            return self(ctx).now();
        }
        fn random(ctx: *anyopaque, into: *[16]u8) void {
            self(ctx).random(into);
        }

        const ops: Ops = .{
            .size = size,
            .sectorSize = sectorSize,
            .writeSize = writeSize,
            .eraseSize = eraseSize,
            .mapped = mapped,
            .read = read,
            .write = write,
            .erase = erase,
            .update = update,
            .writable = writable,
            .alloc = alloc,
            .allocRaw = allocRaw,
            .free = free,
            .now = now,
            .random = random,
        };
    };
}

/// The write unit of a medium: what the journal and the checkpoint slots
/// are written in - its page, or its sector, at least 256 bytes.
pub fn writeUnit(dev: Device) u32 {
    var unit = dev.writeSize();
    if (unit == 0) unit = dev.sectorSize();
    return if (unit < 256) 256 else unit;
}
