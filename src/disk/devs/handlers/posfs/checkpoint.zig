// SPDX-License-Identifier: MPL-2.0
//! Checkpoints, formatting and mounting a posfs volume.
//!
//! **A checkpoint** makes the changes in memory durable, in this order:
//! the journal's position is fixed (replay starts there); the object
//! tree's changed nodes are written, children first, to new homes; the
//! volume table and the deadlists; the bitmaps and the space tree, every
//! home for them counted out first (space.zig); a barrier; the slot into
//! the ring whose turn it is; a barrier. Only then is anything the
//! checkpoint replaced let go - after the *next* one, so the checkpoint
//! before stays whole for a mount to fall back to.
//!
//! **The rings** take odd generations in ring A and even ones in ring B, a
//! slot after the one before in each, so the newest checkpoint and the one
//! before it are never in the same block. On flash a ring block is erased
//! when its first slot is reached; the slots in it are older than both.
//!
//! **Format** writes the first trees, the volume table and the first
//! journal block, then checkpoint 1, then the label's copy in the last
//! block, and the label in block 0 last of all: a format cut short leaves
//! no label, and what an earlier volume left fails its id and checksums.
//!
//! **Mount** reads the label (or its copy), finds the newest slot that
//! checks out in both rings, and checks its roots. If they fail it falls
//! back to the slot before, once. Then the space, the volume table, and -
//! when the slot is not marked clean or the journal goes on after it - the
//! replay (objects.zig), followed by a checkpoint of its own.

const sdk = @import("sdk");
const posfs = sdk.dos.posfs;
const layout = posfs.layout;
const media = @import("media.zig");
const volume = @import("volume.zig");
const btree = @import("btree.zig");
const space = @import("space.zig");
const journal = @import("journal.zig");
const objects = @import("objects.zig");
const recycled = @import("recycled.zig");
const snapshots = @import("snapshots.zig");
const Volume = volume.Volume;
const Error = volume.Error;

/// What a format is asked for.
pub const Options = struct {
    /// The block size, 0 for the default (`posfs.chooseBlockSize`).
    block_size: u32 = 0,
    /// The partition's own block, which the default is taken from.
    partition_block: u32 = 0,
    name: []const u8 = "Empty",
    /// The switches a new volume starts with.
    settings: u32 = layout.VT_CHECKSUMS,
};

/// The blocks of each ring, and the slots a ring holds.
fn slotsPerBlock(vol: *const Volume) u32 {
    return vol.block_size / vol.label.slot_size;
}

fn slotsPerRing(vol: *const Volume) u64 {
    return @as(u64, slotsPerBlock(vol)) * layout.ring_blocks;
}

/// Where the slot of generation `gen` goes: its block and offset.
fn slotPlace(vol: *const Volume, gen: u64) struct { block: u64, offset: u32 } {
    const ring = if (gen & 1 == 1) vol.label.ring_a else vol.label.ring_b;
    const index = ((gen - 1) / 2) % slotsPerRing(vol);
    const per_block = slotsPerBlock(vol);
    return .{
        .block = ring + index / per_block,
        .offset = @intCast((index % per_block) * vol.label.slot_size),
    };
}

// --- format ------------------------------------------------------------------------

/// A new, empty volume over the whole medium, mounted.
pub fn format(vol: *Volume, options: Options) Error!void {
    const dev = vol.dev;
    const sector = dev.sectorSize();
    const erase = dev.eraseSize();
    const block_size = posfs.chooseBlockSize(options.block_size, options.partition_block, sector, erase) orelse return error.InvalidArgument;
    const size = dev.size() - vol.first_byte;
    const count = size / block_size;
    if (count < layout.min_blocks or count >= layout.max_blocks) return error.InvalidArgument;
    if (!dev.writable()) return error.ReadOnly;
    if (options.name.len == 0 or options.name.len > posfs.max_volume_name) return error.BadName;

    vol.release();
    const unit = media.writeUnit(dev);
    var label: layout.Label = .{
        .block_size = block_size,
        .block_count = count,
        .write_unit = unit,
        .erase_size = erase,
        .slot_size = layout.slotSize(unit),
        .ring_a = 1,
        .ring_b = count - 1 - layout.ring_blocks,
        .inline_max = layout.inlineMax(block_size),
        .created = dev.now(),
        .compat = layout.COMPAT_RECYCLED,
    };
    if (label.slot_size > block_size) return error.InvalidArgument;
    dev.random(&label.uuid);
    try vol.takeLabel(&label);
    vol.unclean = true;
    vol.read_only = false;
    vol.failed = false;
    vol.gen = 1;
    vol.life = 1;
    vol.next_oid = posfs.first_user_oid;
    vol.durable = .{};
    vol.previous = .{};
    vol.have_previous = false;

    try space.format(vol);
    vol.journal.lsn = 1;
    try journal.begin(vol, 1);
    vol.voltab.* = .{};
    vol.voltab.flags = options.settings;
    vol.voltab.inline_max = label.inline_max;
    vol.voltab.name_len = @intCast(options.name.len);
    @memcpy(vol.voltab.name[0..options.name.len], options.name);
    vol.voltab_dirty = true;
    try btree.create(vol, &vol.obj);
    try objects.formatRoot(vol);
    if (options.settings & layout.VT_RECYCLED != 0) {
        try recycled.turnOn(vol);
        vol.voltab.compat |= layout.COMPAT_RECYCLED;
    }
    try write(vol, 0);

    label.copy = 1;
    label.checksum = layout.labelChecksum(&label);
    try writeLabel(vol, count - 1, &label);
    try vol.barrier();
    label.copy = 0;
    label.checksum = layout.labelChecksum(&label);
    try writeLabel(vol, 0, &label);
    try vol.barrier();
    vol.label = label;
    vol.mounted = true;
    vol.session_started = true;
}

fn writeLabel(vol: *Volume, addr: u64, label: *const layout.Label) Error!void {
    const block = vol.scratch;
    const fill: u8 = if (vol.erase_size != 0) 0xFF else 0;
    @memset(block, fill);
    @memcpy(block[0..@sizeOf(layout.Label)], layout.bytesOf(label));
    try vol.writeBlocks(addr, block);
}

// --- writing a checkpoint ---------------------------------------------------------------

/// A checkpoint of everything in memory, written and durable; `flags` is
/// CHECKPOINT_CLEAN for the one an unmount writes.
pub fn write(vol: *Volume, flags: u32) Error!void {
    if (vol.read_only or vol.failed) return error.ReadOnly;
    if (!vol.session_started) {
        // The mount's first checkpoint raises the life and starts a fresh
        // journal, so that what an earlier mount left in the journal can
        // never be taken for this one's.
        vol.life = vol.durable.life + 1;
        try journal.begin(vol, journal.nextJseq(vol));
        vol.session_started = true;
    }
    skipTornSlot(vol);
    try journal.flush(vol);
    const where = journal.position(vol);
    try btree.flush(vol, &vol.obj);
    try snapshots.flush(vol);
    try writeVoltab(vol);
    try space.writeSpace(vol);
    try vol.barrier();

    const previous_space = if (vol.durable.gen != 0) vol.durable.space_root else 0;
    const previous_space_gen = if (vol.durable.gen != 0) vol.durable.space_gen else 0;
    var slot: layout.CheckpointSlot = .{
        .gen = vol.gen,
        .life = vol.life,
        .next_lsn = vol.journal.lsn,
        .jblock = where.block,
        .jseq = where.jseq,
        .joffset = where.offset,
        .flags = flags,
        .obj_root = vol.obj.root,
        .obj_gen = vol.obj.root_gen,
        .obj_height = vol.obj.height,
        .space_height = vol.space_tree.height,
        .space_root = vol.space_tree.root,
        .space_gen = vol.space_tree.root_gen,
        .prev_space_root = previous_space,
        .prev_space_gen = previous_space_gen,
        .voltab = vol.durable.voltab,
        .voltab_gen = vol.durable.voltab_gen,
        .next_oid = vol.next_oid,
        .free_blocks = vol.space.free_total,
        .alloc_cursor = vol.space.cursor,
        .time = vol.now(),
        .uuid = vol.uuid,
    };
    if (vol.voltab_written != 0) {
        slot.voltab = vol.voltab_written;
        slot.voltab_gen = vol.gen;
    }
    slot.checksum = layout.checksumOf(&vol.uuid, &slot);
    try writeSlot(vol, &slot);
    try vol.barrier();

    vol.previous = vol.durable;
    vol.have_previous = vol.durable.gen != 0;
    vol.durable = slot;
    vol.voltab_written = 0;
    // The journal the checkpoint before needed is let go: replay now
    // starts at this one, or falls back to the one before.
    const keep_from = if (vol.have_previous) vol.previous.jseq else slot.jseq;
    try journal.afterCheckpoint(vol, keep_from);
    try space.afterCheckpoint(vol);
    try snapshots.afterCheckpoint(vol);
    vol.gen += 1;
}

/// Whether the journal or the nodes being changed have grown to where a
/// checkpoint is written: sooner on flash, where the journal and memory
/// are smaller.
pub fn due(vol: *const Volume) bool {
    const dirty_nodes: u32 = if (vol.erase_size != 0) 48 else 256;
    return vol.journal.since_checkpoint >= journalLimit(vol) or vol.dirty_count >= dirty_nodes;
}

/// The journal blocks written before a checkpoint is.
pub fn journalLimit(vol: *const Volume) u32 {
    return if (vol.erase_size != 0) 32 else 128;
}

/// On flash a slot is a page programmed once: one a cut left half
/// written is passed over, and the checkpoint takes the next place in its
/// ring - and the generation that goes with it.
fn skipTornSlot(vol: *Volume) void {
    if (vol.erase_size == 0 or vol.map == null) return;
    var tries: u32 = 0;
    while (tries < 4) : (tries += 1) {
        const place = slotPlace(vol, vol.gen);
        if (place.offset == 0) return;
        const at: usize = @intCast(vol.byteOf(place.block) + place.offset);
        if (volume.blank(vol.map.?[at..][0..vol.label.slot_size])) return;
        vol.gen += 2;
    }
}

fn writeSlot(vol: *Volume, slot: *const layout.CheckpointSlot) Error!void {
    const place = slotPlace(vol, slot.gen);
    const size = vol.label.slot_size;
    const block = vol.scratch[0..size];
    const fill: u8 = if (vol.erase_size != 0) 0xFF else 0;
    @memset(block, fill);
    @memcpy(block[0..@sizeOf(layout.CheckpointSlot)], layout.bytesOf(slot));
    if (place.offset == 0) {
        // The ring block's first slot: on flash, erased first.
        if (vol.erase_size != 0) {
            if (vol.failed or vol.read_only) return error.ReadOnly;
            if (!vol.dev.erase(vol.byteOf(place.block), vol.block_size)) {
                vol.failed = true;
                return error.Io;
            }
        }
    }
    try vol.writeAt(place.block, place.offset, block);
}

/// The volume table to a new home when it changed.
fn writeVoltab(vol: *Volume) Error!void {
    if (!vol.voltab_dirty) return;
    const blocks = layout.voltabBlocks(vol.block_size);
    const run = try space.alloc(vol, blocks, .used, true);
    if (run.count != blocks) {
        try space.freeNow(vol, run.start, run.count);
        return writeVoltabScattered(vol);
    }
    try putVoltab(vol, run.start);
}

/// A volume table that does not find its blocks in one run: a block's
/// worth at a time until a run turns up. Only small blocks need more than
/// one, and only a full volume has no two free together.
fn writeVoltabScattered(vol: *Volume) Error!void {
    const blocks = layout.voltabBlocks(vol.block_size);
    var tries: u32 = 0;
    while (tries < 64) : (tries += 1) {
        const run = try space.alloc(vol, blocks, .used, true);
        if (run.count == blocks) return putVoltab(vol, run.start);
        try space.freeNow(vol, run.start, run.count);
    }
    return error.DiskFull;
}

fn putVoltab(vol: *Volume, home: u64) Error!void {
    const blocks = layout.voltabBlocks(vol.block_size);
    const table = vol.voltab;
    table.header = .{
        .self = home,
        .gen = vol.gen,
        .tree = layout.tree_voltab,
        .uuid = vol.uuid,
    };
    table.header.checksum = voltabChecksum(vol, table);
    const bytes = try vol.alloc(@as(usize, blocks) * vol.block_size);
    defer vol.free(bytes);
    @memcpy(bytes[0..layout.voltab_size], voltabBytes(table));
    try vol.writeBlocks(home, bytes);
    if (vol.durable.voltab != 0) try space.freeNow(vol, vol.durable.voltab, blocks);
    vol.voltab_written = home;
    vol.voltab_dirty = false;
}

fn voltabBytes(table: *const layout.VolTab) []const u8 {
    const bytes: [*]const u8 = @ptrCast(table);
    return bytes[0..layout.voltab_size];
}

fn voltabChecksum(vol: *const Volume, table: *const layout.VolTab) u32 {
    const bytes = voltabBytes(table);
    var crc = layout.seeded(&vol.uuid);
    crc = layout.crcAdd(crc, bytes[0..@offsetOf(layout.NodeHeader, "checksum")]);
    crc = layout.crcAdd(crc, bytes[layout.node_header_size..]);
    return layout.crcEnd(crc);
}

// --- mounting ------------------------------------------------------------------------

/// The label at block 0 of the medium, or its copy in the last block.
fn readLabel(vol: *Volume) Error!layout.Label {
    const dev = vol.dev;
    var buffer = try vol.alloc(posfs.max_block_size);
    defer vol.free(buffer);
    const sector = dev.sectorSize();
    const first_len: usize = if (sector > @sizeOf(layout.Label)) sector else 512;
    if (dev.read(vol.first_byte, buffer[0..first_len])) {
        if (labelOk(vol, buffer[0..@sizeOf(layout.Label)], 0)) |label| return label;
    }
    // The copy: in the last block of whichever size the volume has.
    const area = dev.size() - vol.first_byte;
    var size: u32 = posfs.min_block_size;
    while (size <= posfs.max_block_size) : (size *= 2) {
        if (area < size or (sector != 0 and size % sector != 0)) continue;
        const last = area / size - 1;
        if (!dev.read(vol.first_byte + last * size, buffer[0..size])) continue;
        if (labelOk(vol, buffer[0..@sizeOf(layout.Label)], 1)) |label| {
            if (label.block_size == size and label.block_count == last + 1) return label;
        }
    }
    return error.NotPosfs;
}

fn labelOk(vol: *Volume, bytes: []const u8, copy: u32) ?layout.Label {
    var label: layout.Label = undefined;
    @memcpy(layout.bytesOfMut(&label), bytes);
    if (label.magic != layout.label_magic or label.copy != copy) return null;
    if (layout.labelChecksum(&label) != label.checksum) return null;
    if (label.version != layout.format_version) return null;
    const dev = vol.dev;
    if (!posfs.validBlockSize(label.block_size, 0, 0)) return null;
    if (label.block_count < layout.min_blocks or label.block_count >= layout.max_blocks) return null;
    if (label.block_count * label.block_size > dev.size() - vol.first_byte) return null;
    if (label.slot_size < @sizeOf(layout.CheckpointSlot) or label.slot_size > label.block_size) return null;
    if (label.write_unit == 0 or label.write_unit > label.block_size) return null;
    if (label.ring_blocks != layout.ring_blocks or label.ring_a != 1 or label.ring_b != label.block_count - 1 - layout.ring_blocks) return null;
    return label;
}

/// The newest slot that checks out, and the newest before it.
const Found = struct { best: ?layout.CheckpointSlot = null, second: ?layout.CheckpointSlot = null };

fn scanRings(vol: *Volume) Error!Found {
    var found: Found = .{};
    const buffer = try vol.alloc(vol.block_size);
    defer vol.free(buffer);
    for ([_]u64{ vol.label.ring_a, vol.label.ring_b }) |ring| {
        for (0..layout.ring_blocks) |index| {
            vol.readBlocks(ring + index, buffer) catch |err| switch (err) {
                error.Io => continue,
                else => return err,
            };
            var offset: usize = 0;
            while (offset + vol.label.slot_size <= vol.block_size) : (offset += vol.label.slot_size) {
                var slot: layout.CheckpointSlot = undefined;
                @memcpy(layout.bytesOfMut(&slot), buffer[offset..][0..@sizeOf(layout.CheckpointSlot)]);
                if (slot.magic != layout.checkpoint_magic or slot.gen == 0) continue;
                if (!volume.eqlBytes(&slot.uuid, &vol.uuid)) continue;
                if (layout.checksumOf(&vol.uuid, &slot) != slot.checksum) continue;
                // A slot must be where its generation puts it.
                const place = slotPlace(vol, slot.gen);
                if (place.block != ring + index or place.offset != offset) continue;
                consider(&found, slot);
            }
        }
    }
    return found;
}

fn consider(found: *Found, slot: layout.CheckpointSlot) void {
    if (found.best) |best| {
        if (slot.gen > best.gen) {
            found.second = best;
            found.best = slot;
        } else if (slot.gen < best.gen) {
            if (found.second == null or slot.gen > found.second.?.gen) found.second = slot;
        }
    } else found.best = slot;
}

/// Whether a slot's roots read and check out.
fn rootsOk(vol: *Volume, slot: *const layout.CheckpointSlot) bool {
    if (slot.obj_height == 0 or slot.obj_height > volume.max_height) return false;
    if (slot.space_height == 0 or slot.space_height > volume.max_height) return false;
    _ = vol.nodeView(slot.obj_root, slot.obj_gen, layout.tree_object) catch return false;
    _ = vol.nodeView(slot.space_root, slot.space_gen, layout.tree_space) catch return false;
    readVoltab(vol, slot) catch return false;
    return true;
}

fn readVoltab(vol: *Volume, slot: *const layout.CheckpointSlot) Error!void {
    try loadVoltab(vol, slot, vol.voltab);
}

/// The volume table a slot names, read into `into` (`voltab_size` bytes)
/// and checked.
pub fn loadVoltab(vol: *Volume, slot: *const layout.CheckpointSlot, into: *layout.VolTab) Error!void {
    const blocks = layout.voltabBlocks(vol.block_size);
    const bytes = try vol.alloc(@as(usize, blocks) * vol.block_size);
    defer vol.free(bytes);
    try vol.readBlocks(slot.voltab, bytes);
    const table: *const layout.VolTab = @ptrCast(@alignCast(bytes.ptr));
    const header = &table.header;
    if (header.magic != layout.node_magic or header.tree != layout.tree_voltab) return error.Corrupt;
    if (header.self != slot.voltab or header.gen != slot.voltab_gen) return error.Corrupt;
    if (!volume.eqlBytes(&header.uuid, &vol.uuid)) return error.Corrupt;
    if (voltabChecksum(vol, table) != header.checksum) return error.Corrupt;
    if (table.snapshot_count > posfs.max_snapshots or table.name_len > posfs.max_volume_name) return error.Corrupt;
    @memcpy(@as([*]u8, @ptrCast(into))[0..layout.voltab_size], bytes[0..layout.voltab_size]);
}

/// The volume on the medium, mounted: read-only when the medium or the
/// volume says so.
pub fn mount(vol: *Volume) Error!void {
    vol.release();
    const label = try readLabel(vol);
    if (label.incompat & ~layout.known_incompat != 0) return error.NotPosfs;
    try vol.takeLabel(&label);
    vol.read_only = !vol.dev.writable() or label.ro_compat & ~layout.known_ro_compat != 0;
    vol.failed = false;
    if (label.fold_default != layout.fold_1 or label.name_hash != layout.name_hash_1) vol.read_only = true;

    const found = try scanRings(vol);
    var base = found.best orelse return error.Corrupt;
    if (!rootsOk(vol, &base)) {
        base = found.second orelse return error.Corrupt;
        if (!rootsOk(vol, &base)) return error.Corrupt;
    }
    vol.durable = base;
    vol.previous = base;
    vol.have_previous = false;
    // Past every slot seen, the one not taken too.
    vol.gen = found.best.?.gen + 1;
    vol.life = base.life;
    vol.next_oid = base.next_oid;
    btree.reset(&vol.obj, base.obj_root, base.obj_gen, base.obj_height);
    btree.reset(&vol.space_tree, base.space_root, base.space_gen, base.space_height);
    try readVoltab(vol, &base);
    vol.voltab_dirty = false;
    vol.voltab_written = 0;
    try space.load(vol, &base);
    try snapshots.load(vol);
    vol.journal.lsn = base.next_lsn;
    vol.unclean = base.flags & layout.CHECKPOINT_CLEAN == 0;
    vol.mounted = true;
    vol.session_started = false;
    vol.replayed = try objects.replay(vol);
}

/// The first change of a mount: the checkpoint that starts its session
/// (`write`), before anything goes into the journal.
pub fn startSession(vol: *Volume) Error!void {
    if (vol.session_started) return;
    try write(vol, 0);
}

/// What is in memory made durable, the slot marked clean: the volume put
/// away.
pub fn unmount(vol: *Volume) Error!void {
    if (!vol.mounted) return;
    if (!vol.read_only and !vol.failed and vol.session_started) try write(vol, layout.CHECKPOINT_CLEAN);
    vol.release();
}
