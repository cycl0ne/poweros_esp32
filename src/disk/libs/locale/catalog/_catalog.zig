// SPDX-License-Identifier: MIT
//! Catalogs: a CTLG file read into one allocation, the list of those
//! loaded, and the flush that gives back the ones no one holds.
//!
//! A catalog file is an IFF FORM of type CTLG: FVER, its `$VER:` string
//! (the version a program may ask for); LANG, the language; CSET, the code
//! set the strings are in, a big-endian u32 (IANA's number, 106 for UTF-8)
//! and 28 reserved bytes; STRS, each string as a big-endian id and length -
//! its bytes and the NUL after them - then those bytes, padded to a
//! multiple of four. Any other chunk is passed over.
//!
//! A loaded catalog is an ExtCatalog, its entries sorted by id after it,
//! then their strings in the locale's code set, then its name: one
//! allocation, freed whole. It stays on the base's list when the last
//! holder gives it back, so the next program to ask has it at once, and
//! goes when the library is asked to expunge.
//!
//! The list is taken under the library's lock; the file is read without
//! it, and a catalog another task loaded meanwhile wins.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const locale = sdk.locale;
const prefs = sdk.prefs;
const style = prefs.style;
const _base = @import("../locale_base.zig");
const _locale = @import("../locale/_locale.zig");
const LocaleBase = _base.LocaleBase;
const ExtCatalog = _base.ExtCatalog;
const Entry = _base.Entry;

/// The loaded catalog `name` in `language`, of `version` (0: any), held
/// once more; null when none is loaded. The caller holds the lock.
pub fn findLoaded(lb: *LocaleBase, name: []const u8, language: []const u8, version: u32) ?*ExtCatalog {
    var nodes = lb.catalogs.iterator();
    while (nodes.next()) |at| {
        const ext = catalogAt(at);
        if (!sameName(ext.public.link.name.?, name)) continue;
        if (!sameName(@ptrCast(&ext.language), language)) continue;
        if (version != 0 and ext.public.version != version) continue;
        return ext;
    }
    return null;
}

/// The catalogs no one holds taken off the list and freed.
pub fn flush(lb: *LocaleBase) void {
    const sys = lb.sys_base;
    sys.ObtainSemaphore(&lb.lock);
    defer sys.ReleaseSemaphore(&lb.lock);
    var nodes = lb.catalogs.iterator();
    while (nodes.next()) |at| {
        const ext = catalogAt(at);
        if (ext.usage != 0) continue;
        sys.Remove(at);
        sys.FreeVec(ext);
    }
}

/// The catalog a node of the list is the head of.
fn catalogAt(node: *exec.Node) *ExtCatalog {
    return _base.catalogOf(@as(*locale.Catalog, @fieldParentPtr("link", node)));
}

/// The catalog file `path` read as `name` in `language`, held once by the
/// caller and not yet on the list; null when there is no such file, it is
/// not a catalog, or it is not of `version` (0: any).
pub fn load(lb: *LocaleBase, path: [*:0]const u8, name: []const u8, language: []const u8, version: u32) ?*ExtCatalog {
    const sys = lb.sys_base;
    const file = prefs.loadWhole(sys, lb.dos_base, path) orelse return null;
    defer sys.FreeVec(file.ptr);
    const parts = readForm(file) orelse return null;
    if (version != 0 and parts.version != version) return null;

    // The strings counted and sized; each kept with its NUL.
    var count: usize = 0;
    var text_bytes: usize = 0;
    var walk = Strings{ .bytes = parts.strings };
    while (walk.next()) |string| {
        count += 1;
        text_bytes += string.text.len + 1;
    }
    if (!walk.whole) return null;

    const size = @sizeOf(ExtCatalog) + count * @sizeOf(Entry) + text_bytes + name.len + 1;
    const memory = sys.AllocVec(size, exec.MEMF_ANY) orelse return null;
    const ext: *ExtCatalog = @ptrCast(@alignCast(memory));
    const bytes: [*]u8 = @ptrCast(memory);
    const entries: [*]Entry = @ptrCast(@alignCast(bytes + @sizeOf(ExtCatalog)));
    var text_at: usize = @sizeOf(ExtCatalog) + count * @sizeOf(Entry);
    const name_at = size - name.len - 1;
    @memcpy(bytes[name_at..][0..name.len], name);
    bytes[name_at + name.len] = 0;

    ext.* = .{ .usage = 1, .count = @intCast(count), .entries = entries, .size = size };
    ext.public = .{
        .link = .{ .name = @ptrCast(bytes + name_at) },
        .language = @ptrCast(&ext.language),
        .code_set = locale.CODESET_LATIN1,
        .version = parts.version,
        .revision = parts.revision,
    };
    const kept_language = language[0..@min(language.len, ext.language.len - 1)];
    @memcpy(ext.language[0..kept_language.len], kept_language);
    ext.language[kept_language.len] = 0;

    // A string that is not UTF-8 is taken as Latin-1, whatever the file
    // says.
    const utf8 = parts.code_set == locale.CODESET_UTF8;
    var index: usize = 0;
    walk = .{ .bytes = parts.strings };
    while (walk.next()) |string| : (index += 1) {
        const into = bytes[text_at..][0..string.text.len];
        @memcpy(into, string.text);
        const kept = if (utf8 and _locale.isUtf8(string.text)) _locale.toLatin1(into) else into.len;
        bytes[text_at + kept] = 0;
        entries[index] = .{ .id = string.id, .text = @ptrCast(bytes + text_at) };
        text_at += string.text.len + 1;
    }
    sortById(entries[0..count]);
    return ext;
}

/// The parts of a CTLG form that matter.
const Form = struct {
    version: u32 = 0,
    revision: u32 = 0,
    code_set: u32 = 0,
    strings: []const u8 = &.{},
};

fn readForm(file: []const u8) ?Form {
    if (file.len < 12) return null;
    if (be32(file[0..4]) != makeID("FORM") or be32(file[8..12]) != locale.ID_CTLG) return null;
    const end = @min(file.len, @as(usize, be32(file[4..8])) + 8);
    var form: Form = .{};
    var at: usize = 12;
    while (at + 8 <= end) {
        const id = be32(file[at..][0..4]);
        const length: usize = be32(file[at + 4 ..][0..4]);
        const start = at + 8;
        if (length > end - start) return null;
        const data = file[start..][0..length];
        if (id == locale.ID_FVER) versionOf(data, &form);
        if (id == locale.ID_CSET and length >= 4) form.code_set = be32(data[0..4]);
        if (id == locale.ID_STRS) form.strings = data;
        at = start + length + (length & 1);
    }
    return form;
}

/// The version and revision in a `$VER: name v.r (date)` string.
fn versionOf(data: []const u8, form: *Form) void {
    var at: usize = 0;
    while (at + 5 <= data.len and !(data[at] == '$' and data[at + 1] == 'V' and data[at + 2] == 'E' and data[at + 3] == 'R' and data[at + 4] == ':')) at += 1;
    at += 5;
    while (at < data.len and data[at] == ' ') at += 1;
    while (at < data.len and data[at] != ' ' and data[at] != 0) at += 1;
    while (at < data.len and data[at] == ' ') at += 1;
    form.version = digits(data, &at);
    if (at < data.len and data[at] == '.') {
        at += 1;
        form.revision = digits(data, &at);
    }
}

fn digits(data: []const u8, at: *usize) u32 {
    var value: u32 = 0;
    while (at.* < data.len and data[at.*] >= '0' and data[at.*] <= '9') : (at.* += 1) {
        value = value *| 10 +| (data[at.*] - '0');
    }
    return value;
}

/// The strings of a STRS chunk, one at a time; `whole` false when one
/// runs past the chunk.
const Strings = struct {
    bytes: []const u8,
    at: usize = 0,
    whole: bool = true,

    fn next(walk: *Strings) ?struct { id: i32, text: []const u8 } {
        if (walk.at + 8 > walk.bytes.len) return null;
        const id: i32 = @bitCast(be32(walk.bytes[walk.at..][0..4]));
        const length: usize = be32(walk.bytes[walk.at + 4 ..][0..4]);
        const start = walk.at + 8;
        if (length > walk.bytes.len - start) {
            walk.whole = false;
            return null;
        }
        var text = walk.bytes[start..][0..length];
        while (text.len > 0 and text[text.len - 1] == 0) text = text[0 .. text.len - 1];
        walk.at = start + ((length + 3) & ~@as(usize, 3));
        return .{ .id = id, .text = text };
    }
};

/// The entries in the order of their ids, as GetCatalogStr looks them up;
/// a catalog file has them sorted already, so this is one pass.
fn sortById(entries: []Entry) void {
    var at: usize = 1;
    while (at < entries.len) : (at += 1) {
        const entry = entries[at];
        var place = at;
        while (place > 0 and entries[place - 1].id > entry.id) : (place -= 1) entries[place] = entries[place - 1];
        entries[place] = entry;
    }
}

fn be32(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) << 24 | @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | bytes[3];
}

fn makeID(comptime four: *const [4]u8) u32 {
    return @as(u32, four[0]) << 24 | @as(u32, four[1]) << 16 | @as(u32, four[2]) << 8 | four[3];
}

/// Whether the NUL-ended `stored` is `name`, whatever the case of its
/// letters.
pub fn sameName(stored: [*:0]const u8, name: []const u8) bool {
    for (name, 0..) |c, at| {
        if (stored[at] == 0 or style.upper(stored[at]) != style.upper(c)) return false;
    }
    return stored[name.len] == 0;
}

/// No requester for the caller's process while catalogs are looked for -
/// PROGDIR: and LOCALE: may be missing - and what it had before.
pub fn quiet(lb: *LocaleBase) ?*anyopaque {
    const task = lb.sys_base.FindTask(null) orelse return null;
    if (task.node.type != .process) return null;
    const process: *dos.Process = @ptrCast(task);
    const old = process.window_ptr;
    process.window_ptr = @ptrFromInt(~@as(usize, 0));
    return old;
}

pub fn loud(lb: *LocaleBase, old: ?*anyopaque) void {
    const task = lb.sys_base.FindTask(null) orelse return;
    if (task.node.type != .process) return;
    const process: *dos.Process = @ptrCast(task);
    process.window_ptr = old;
}

/// `dir/language/name`, NUL-ended in `into`; null when it does not fit.
pub fn pathOf(into: []u8, dir: []const u8, language: []const u8, name: []const u8) ?[*:0]const u8 {
    const total = dir.len + 1 + language.len + 1 + name.len;
    if (total + 1 > into.len) return null;
    var at: usize = 0;
    for ([_][]const u8{ dir, "/", language, "/", name }) |part| {
        @memcpy(into[at..][0..part.len], part);
        at += part.len;
    }
    into[at] = 0;
    return @ptrCast(into.ptr);
}
