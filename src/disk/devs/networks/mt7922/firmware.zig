// SPDX-License-Identifier: MIT
//! The chip given its firmware: the patch for its boot ROM, then the
//! code its processor runs, both from `DEVS:networks/firmware/mt7922/`,
//! which `scripts/fetch-mt7922.sh` fetches.
//!
//! **The patch file** starts with a 96-byte header (big-endian): its
//! build date, and how many sections follow; each section's 64 bytes say
//! where its data is in the file, where it goes in the chip, and how it
//! is sealed. The boot ROM is asked for its patch semaphore first: it
//! says whether a patch is there already (a chip that was not reset),
//! which is then left as it is.
//!
//! **The RAM file** says what it holds at its end (little-endian): a
//! 36-byte trailer - its version, its build date, how many regions - and
//! a 40-byte entry per region before it. The regions' data is packed
//! from the start of the file in their order. A region marked as not to
//! be downloaded - the country tables - is passed over; the one marked
//! to override the start address names where the processor starts.
//!
//! Every piece is announced to the boot ROM - where it goes, how long it
//! is, how it is sealed - and then sent as bare data on the firmware's
//! ring, 4 KiB at a time.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const _mt = @import("_mt7922.zig");
const regs_file = @import("regs.zig");
const mcu = @import("mcu.zig");
const Work = _mt.Work;
const say = _mt.say;

const dir = "DEVS:networks/firmware/mt7922/";
pub const name_patch = dir ++ "WIFI_MT7922_patch_mcu_1_1_hdr.bin";
pub const name_ram = dir ++ "WIFI_RAM_CODE_MT7922_1.bin";

/// How much the firmware's ring takes in one descriptor.
const piece = 4096;

/// What the patch semaphore answers.
const PATCH_SEM_RELEASE = 0;
const PATCH_SEM_GET = 1;
const PATCH_IS_DL = 1;
const PATCH_NOT_DL_SEM_SUCCESS = 2;
const PATCH_REL_SEM_SUCCESS = 3;

/// How a piece is sealed: an answer wanted, encrypted, its key, the
/// initial vector started again, the other encryption mode.
const DL_MODE_NEED_RSP: u32 = 1 << 31;
const DL_MODE_ENCRYPT: u32 = 1 << 0;
const DL_MODE_KEY_IDX_SHIFT: u5 = 1;
const DL_MODE_RESET_SEC_IV: u32 = 1 << 3;
const DL_CONFIG_ENCRY_MODE_SEL: u32 = 1 << 6;

/// A region's feature bits in the RAM file.
const FEATURE_ENCRYPT: u8 = 1 << 0;
const FEATURE_KEY_IDX: u8 = 0x6;
const FEATURE_ENCRY_MODE: u8 = 1 << 4;
const FEATURE_OVERRIDE_ADDR: u8 = 1 << 5;
const FEATURE_NON_DL: u8 = 1 << 6;

/// The patch's address, which takes PATCH_START_REQ rather than
/// TARGET_ADDRESS_LEN_REQ.
const patch_address = 0x900000;
const patch_address_old = 0x200000;

const patch_header = 96;
const patch_section = 64;
const ram_trailer = 36;
const ram_region = 40;

pub const Error = error{ NoFile, BadFile, Refused } || mcu.Error;

/// Both files read and given to the chip, and its processor started:
/// true once the firmware says it runs.
pub fn load(work: *Work) Error!void {
    const sys = work.sys;
    // The chip's processor started again from its boot ROM - a firmware
    // that runs goes back to it - which it says in its state bits.
    _ = try mcu.send(work, mcu.plain(mcu.NIC_POWER_CTRL), &[_]u8{ 1, 0, 0, 0 }, false);
    if (!work.poll(regs_file.CONN_ON_MISC, regs_file.MISC_FW_STATE, regs_file.MISC_FW_PWR_ON, 1000)) {
        say(sys, "the chip's processor does not say it is powered on: %x", .{work.regs.rd(regs_file.CONN_ON_MISC)});
    }
    {
        const patch = readFile(work, name_patch) orelse return error.NoFile;
        defer sys.FreeVec(patch.ptr);
        try loadPatch(work, patch);
    }
    {
        const ram = readFile(work, name_ram) orelse return error.NoFile;
        defer sys.FreeVec(ram.ptr);
        try loadRam(work, ram);
    }
    if (!work.poll(regs_file.CONN_ON_MISC, regs_file.MISC_FW_N9_RDY, regs_file.MISC_FW_N9_RDY, 1500)) {
        say(sys, "the firmware was given but does not run", .{});
        return error.Refused;
    }
}

/// A file read whole into memory the chip reaches: the caller frees it.
fn readFile(work: *Work, name: [*:0]const u8) ?[]u8 {
    const dl = work.dl;
    var length: usize = 0;
    const bytes = dl.ReadFile(name, ~@as(usize, 0), exec.MEMF_DMA, &length) orelse {
        say(work.sys, "%s cannot be read (scripts/fetch-mt7922.sh fetches it)", .{name});
        return null;
    };
    if (length == 0) {
        work.sys.FreeVec(bytes);
        return null;
    }
    return bytes[0..length];
}

fn loadPatch(work: *Work, file: []const u8) Error!void {
    const sys = work.sys;
    if (file.len < patch_header) return error.BadFile;
    copyText(&work.patch_build, file[0..16]);
    const regions = mcu.getBe32(file, 44);
    if (patch_header + @as(usize, regions) * patch_section > file.len) return error.BadFile;

    const got = (try semaphore(work, PATCH_SEM_GET)).status();
    switch (got) {
        PATCH_IS_DL => {
            say(sys, "the patch is in the chip already", .{});
            return;
        },
        PATCH_NOT_DL_SEM_SUCCESS => {},
        else => {
            say(sys, "the boot ROM does not give its patch semaphore: %u", .{@as(u32, got)});
            return error.Refused;
        },
    }
    const loaded = sections(work, file, regions);
    const released = semaphore(work, PATCH_SEM_RELEASE) catch |failure| return failure;
    if (released.status() != PATCH_REL_SEM_SUCCESS) {
        say(sys, "the boot ROM does not take its patch semaphore back: %u", .{@as(u32, released.status())});
        return error.Refused;
    }
    try loaded;
}

fn sections(work: *Work, file: []const u8, regions: u32) Error!void {
    for (0..regions) |index| {
        const at = patch_header + index * patch_section;
        const kind = mcu.getBe32(file, at);
        if (kind & 0xffff != 2) return error.BadFile;
        const offset = mcu.getBe32(file, at + 4);
        const address = mcu.getBe32(file, at + 12);
        const length = mcu.getBe32(file, at + 16);
        const key = mcu.getBe32(file, at + 20);
        if (@as(usize, offset) + length > file.len) return error.BadFile;
        try announce(work, address, length, patchMode(key));
        try mcu.sendData(work, file[offset .. offset + length], piece);
    }
    if (!mcu.drain(work)) return error.NoAnswer;
    const finished = (try mcu.send(work, mcu.plain(mcu.PATCH_FINISH_REQ), &[_]u8{ 0, 0, 0, 0 }, true)).?;
    if (finished.status() != 0) {
        say(work.sys, "the boot ROM does not take the patch: %u", .{@as(u32, finished.status())});
        return error.Refused;
    }
}

/// How a patch section is sealed: its key word's top byte says whether
/// it is plain (0), encrypted (1) or scrambled (2).
fn patchMode(key: u32) u32 {
    var mode = DL_MODE_NEED_RSP;
    if (key == 0xffffffff) return mode;
    switch (key >> 24) {
        1 => mode |= DL_MODE_ENCRYPT | (key & 0x3) << DL_MODE_KEY_IDX_SHIFT | DL_MODE_RESET_SEC_IV,
        2 => mode |= DL_MODE_ENCRYPT | DL_CONFIG_ENCRY_MODE_SEL | DL_MODE_RESET_SEC_IV,
        else => {},
    }
    return mode;
}

fn semaphore(work: *Work, operation: u32) Error!mcu.Answer {
    var payload: [4]u8 = undefined;
    mcu.put32(&payload, 0, operation);
    return (try mcu.send(work, mcu.plain(mcu.PATCH_SEM_CONTROL), &payload, true)).?;
}

/// The boot ROM told where the next piece goes, how long it is and how it
/// is sealed.
fn announce(work: *Work, address: u32, length: u32, mode: u32) Error!void {
    var payload: [12]u8 = undefined;
    mcu.put32(&payload, 0, address);
    mcu.put32(&payload, 4, length);
    mcu.put32(&payload, 8, mode);
    const id: u8 = if (address == patch_address or address == patch_address_old) mcu.PATCH_START_REQ else mcu.TARGET_ADDRESS_LEN_REQ;
    _ = try mcu.send(work, mcu.plain(id), &payload, true);
}

fn loadRam(work: *Work, file: []const u8) Error!void {
    if (file.len < ram_trailer) return error.BadFile;
    const trailer = file.len - ram_trailer;
    const regions: usize = file[trailer + 2];
    copyText(&work.ram_build, file[trailer + 17 .. trailer + 17 + 15]);
    if (regions * ram_region > trailer) return error.BadFile;
    const table = trailer - regions * ram_region;
    var data: usize = 0;
    var start: u32 = 0;
    for (0..regions) |index| {
        const at = table + index * ram_region;
        const address = mcu.get32(file, at + 16);
        const length = mcu.get32(file, at + 20);
        const feature = file[at + 24];
        if (data + length > table) return error.BadFile;
        defer data += length;
        if (feature & FEATURE_NON_DL != 0) continue;
        if (feature & FEATURE_OVERRIDE_ADDR != 0) start = address;
        try announce(work, address, length, ramMode(feature));
        try mcu.sendData(work, file[data .. data + length], piece);
    }
    if (!mcu.drain(work)) return error.NoAnswer;
    var payload: [8]u8 = undefined;
    mcu.put32(&payload, 0, if (start != 0) 1 else 0);
    mcu.put32(&payload, 4, start);
    _ = try mcu.send(work, mcu.plain(mcu.FW_START_REQ), &payload, true);
}

fn ramMode(feature: u8) u32 {
    var mode = DL_MODE_NEED_RSP;
    if (feature & FEATURE_ENCRYPT != 0) {
        mode |= DL_MODE_ENCRYPT | DL_MODE_RESET_SEC_IV;
        if (feature & FEATURE_ENCRY_MODE != 0) mode |= DL_CONFIG_ENCRY_MODE_SEL;
    }
    mode |= @as(u32, (feature & FEATURE_KEY_IDX) >> 1) << DL_MODE_KEY_IDX_SHIFT;
    return mode;
}

/// A name from a file: its printable characters, up to the first that is
/// not.
fn copyText(into: *[16:0]u8, from: []const u8) void {
    @memset(into, 0);
    for (from, 0..) |char, index| {
        if (index >= into.len or char < 0x20 or char > 0x7e) break;
        into[index] = char;
    }
}
