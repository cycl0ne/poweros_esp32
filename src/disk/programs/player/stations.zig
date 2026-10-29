// SPDX-License-Identifier: MIT
//! The Radio page's two lists, each the rows of a listbrowser.gadget: the
//! stations kept - their names and addresses - and the stations a search
//! found (finder.zig) - name, country, bit rate and genres - every row made
//! in one allocation with its station's address after it (`Station`).
//!
//! **The stations kept** are `ENV:Player/Stations.m3u`, an M3U of
//! addresses with `#EXTINF` names and pictures (`tvg-logo`), read as the
//! Player starts (`readKept`) and written to ENV: and ENVARC: as it ends
//! when Keep or Remove changed them (`keptText`). A fresh disk's ENVARC:
//! holds a few to start with.
//!
//! **The stations found** come from radio-browser.info's answers, CSV
//! (csv.zig): the columns are found by their names in the first record,
//! so a column more or one moved changes nothing, and each answer's rows
//! are put in among those already there by how often the service says
//! they were listened to (`readFound`) - the MP3 and the Ogg answers
//! become one list, the most heard first. A row without an address to
//! listen to is passed over. The texts are UTF-8 and become Latin-1, a
//! tab or another control character in them a space and the spaces at
//! their ends dropped (`tidy`); the addresses stay as they are.
//!
//! While a list changes the gadget showing it has let go of it
//! (`LISTBROWSER_DETACH`): that is the program's part.

const sdk = @import("sdk");
const exec = sdk.exec;
const lb = sdk.gadgets.listbrowser;
const ExecBase = sdk.interface.exec.ExecBase;
const m3u = @import("m3u.zig");
const csv = @import("csv.zig");
const icy = sdk.http.icy;

pub const KEPT_ENV_FILE = "ENV:Player/Stations.m3u";
pub const KEPT_ENVARC_FILE = "ENVARC:Player/Stations.m3u";
/// What the kept stations' file starts with: M3U's mark, and what the
/// file is in comments.
pub const kept_header =
    \\#EXTM3U
    \\# ENVARC:Player/Stations.m3u - the stations the Player keeps, shown on its
    \\# Radio page: an #EXTINF line with the station's name (and its picture,
    \\# tvg-logo="..."), then its address. Keep and Remove there write it.
    \\
;

/// The drawers the kept stations' files stand in, made when they are not
/// there.
pub const KEPT_ENV_DRAWER = "ENV:Player";
pub const KEPT_ENVARC_DRAWER = "ENVARC:Player";

/// The kept stations' columns: the name and the address.
pub const kept_columns = [_]lb.Column{
    .{ .title = "Station", .weight = 3 },
    .{ .title = "Address", .weight = 4 },
    .{},
};

/// The found stations' columns: the name, the country, the bit rate,
/// which sorts by its number, and the genres.
pub const found_columns = [_]lb.Column{
    .{ .title = "Station", .weight = 5 },
    .{ .title = "Country", .weight = 3 },
    .{ .title = "kbit/s", .weight = 1, .flags = lb.COLUMN_RIGHT | lb.COLUMN_NUMBER },
    .{ .title = "Genres", .weight = 4 },
    .{},
};
const cell_count = found_columns.len - 1;

/// The most of a name and a list of genres kept.
const name_room = 64;
const country_room = 32;
/// The service's word for a station: a UUID, 36 characters.
const uuid_room = 36;

/// What a station is made of; the texts Latin-1, the addresses as they
/// are. A station `found` shows its country, rate and genres, one kept
/// its address.
pub const Made = struct {
    found: bool = false,
    name: []const u8,
    url: []const u8,
    logo: []const u8 = "",
    country: []const u8 = "",
    kbps: u32 = 0,
    tags: []const u8 = "",
    clicks: u32 = 0,
    uuid: []const u8 = "",
};

/// One station: its row, the texts of its columns, and its address - and
/// after that its picture's - which follow it in the same allocation.
pub const Station = extern struct {
    row: lb.Row,
    cells: [cell_count]?[*:0]const u8,
    name: [name_room + 1]u8 = @splat(0),
    country: [country_room + 1]u8 = @splat(0),
    kbps: [12]u8 = @splat(0),
    tags: [name_room + 1]u8 = @splat(0),
    /// How often it was listened to, as the service counts.
    clicks: u32 = 0,
    /// The service's word for it, which a listen is told with; empty for
    /// one kept.
    uuid: [uuid_room + 1]u8 = @splat(0),
    /// How far past the start of its address its picture's address
    /// stands; 0 when it has none.
    logo_at: u32 = 0,

    /// The address it is listened to at.
    pub fn url(station: *const Station) [*:0]const u8 {
        return @ptrCast(@as([*]const u8, @ptrCast(station)) + @sizeOf(Station));
    }

    /// The address of a picture of it, if it has one.
    pub fn logo(station: *const Station) ?[*:0]const u8 {
        if (station.logo_at == 0) return null;
        return station.url() + station.logo_at;
    }

    /// What it is written as in the kept list.
    fn item(station: *const Station) m3u.Item {
        const address = station.url();
        return .{
            .location = address[0..lengthOf(address)],
            .title = station.name[0..lengthOf(@ptrCast(&station.name))],
            .logo = if (station.logo()) |picture| picture[0..lengthOf(picture)] else "",
        };
    }

    /// The station a row of a list is.
    pub fn of(row: *lb.Row) *Station {
        return @fieldParentPtr("row", row);
    }

    fn ofNode(node: *exec.Node) *Station {
        const row: *lb.Row = @fieldParentPtr("node", node);
        return of(row);
    }

    /// The station after it; null for the last.
    pub fn next(station: *Station) ?*Station {
        return ofNode(station.row.node.next() orelse return null);
    }
};

pub const Stations = struct {
    rows: exec.List = .{},
    count: usize = 0,
    /// Changed since it was read: written as the Player ends.
    changed: bool = false,

    /// Made empty where it is to stay: the list points at itself.
    pub fn init(list: *Stations) void {
        list.* = .{};
        list.rows.init(.unknown);
    }

    pub fn first(list: *Stations) ?*Station {
        return Station.ofNode(list.rows.first() orelse return null);
    }

    /// A station made of `made` put at the list's end - or, `by_clicks`,
    /// before the first listened to less often. Null without the memory.
    pub fn add(list: *Stations, sys: *ExecBase, made: Made, by_clicks: bool) ?*Station {
        const station = make(sys, made) orelse return null;
        if (by_clicks) {
            var at_station = list.first();
            while (at_station) |each| : (at_station = each.next()) {
                if (each.clicks >= station.clicks) continue;
                // Behind the node in front of it, or at the head when that
                // is the list's own.
                const in_front = each.row.node.pred.?;
                sys.Insert(&list.rows, &station.row.node, if (in_front.pred == null) null else in_front);
                list.count += 1;
                return station;
            }
        }
        sys.AddTail(&list.rows, &station.row.node);
        list.count += 1;
        return station;
    }

    /// The station listened to at `url`, if the list has it.
    pub fn find(list: *Stations, url: [*:0]const u8) ?*Station {
        var at_station = list.first();
        while (at_station) |each| : (at_station = each.next()) {
            if (sameText(each.url(), url)) return each;
        }
        return null;
    }

    /// Where `station` stands, counted from 0.
    pub fn placeOf(list: *Stations, station: *const Station) usize {
        var place: usize = 0;
        var at_station = list.first();
        while (at_station) |each| : (at_station = each.next()) {
            if (each == station) return place;
            place += 1;
        }
        return place;
    }

    /// `station` taken off the list and given back.
    pub fn remove(list: *Stations, sys: *ExecBase, station: *Station) void {
        sys.Remove(&station.row.node);
        list.count -= 1;
        sys.FreeVec(@ptrCast(station));
    }

    /// Every station taken off and given back.
    pub fn clear(list: *Stations, sys: *ExecBase) void {
        while (list.first()) |station| list.remove(sys, station);
    }

    /// The stations an M3U names added, a station for each address: its
    /// name from `#EXTINF` - the end of its address without one - and its
    /// picture. A file's name in it is passed over.
    pub fn readKept(list: *Stations, sys: *ExecBase, text: []const u8) void {
        var reader = m3u.Reader.init(text);
        var name: [name_room + 1]u8 = undefined;
        while (reader.next()) |item| {
            if (!isUrl(item.location)) continue;
            icy.latin1As(item.title, reader.utf8, &name);
            const shown = tidy(&name);
            _ = list.add(sys, .{
                .name = if (shown.len > 0) shown else lastPart(item.location),
                .url = item.location,
                .logo = item.logo,
            }, false);
        }
    }

    /// The list as M3U after `kept_header`, in memory of its own the
    /// caller gives back with `FreeVec`; null without the memory.
    pub fn keptText(list: *Stations, sys: *ExecBase) ?[]u8 {
        var length: usize = kept_header.len;
        var at_station = list.first();
        while (at_station) |each| : (at_station = each.next()) length += m3u.itemLength(each.item());
        const memory = sys.AllocVec(length, exec.MEMF_ANY) orelse return null;
        const text: [*]u8 = @ptrCast(memory);
        @memcpy(text[0..kept_header.len], kept_header);
        var written: usize = kept_header.len;
        at_station = list.first();
        while (at_station) |each| : (at_station = each.next()) written += m3u.itemLines(each.item(), text[written..length]);
        return text[0..written];
    }

    /// The stations a search's CSV answer names, put in by how often they
    /// were listened to: how many. The text is changed - its quotes taken
    /// off - as it is read.
    pub fn readFound(list: *Stations, sys: *ExecBase, text: []u8) usize {
        var reader = csv.Reader.init(text);
        var names: [field_most][]const u8 = undefined;
        const named = @min(reader.next(&names) orelse return 0, field_most);
        var places: [found_fields.len]?usize = undefined;
        for (found_fields, 0..) |field, at| places[at] = csv.column(names[0..named], field);
        if (places[field_url] == null) return 0;
        var fields: [field_most][]const u8 = undefined;
        var name: [name_room + 1]u8 = undefined;
        var country: [country_room + 1]u8 = undefined;
        var tags: [name_room + 1]u8 = undefined;
        var added: usize = 0;
        while (reader.next(&fields)) |count| {
            const seen = @min(count, field_most);
            const url = fieldOf(fields[0..seen], places[field_url]);
            if (!isUrl(url)) continue;
            icy.latin1As(fieldOf(fields[0..seen], places[field_name]), true, &name);
            icy.latin1As(fieldOf(fields[0..seen], places[field_country]), true, &country);
            icy.latin1As(fieldOf(fields[0..seen], places[field_tags]), true, &tags);
            const shown = tidy(&name);
            _ = tidy(&tags);
            const made = Made{
                .found = true,
                .name = if (shown.len > 0) shown else lastPart(url),
                .url = url,
                .logo = fieldOf(fields[0..seen], places[field_logo]),
                .country = tidy(&country),
                .kbps = number(fieldOf(fields[0..seen], places[field_kbps])),
                .tags = withSpaces(&tags),
                .clicks = number(fieldOf(fields[0..seen], places[field_clicks])),
                .uuid = fieldOf(fields[0..seen], places[field_uuid]),
            };
            if (list.add(sys, made, true) != null) added += 1;
        }
        return added;
    }
};

/// The columns of a search's answer read, by their names.
const found_fields = [_][]const u8{ "name", "url_resolved", "favicon", "country", "bitrate", "tags", "clickcount", "stationuuid" };
const field_name = 0;
const field_url = 1;
const field_logo = 2;
const field_country = 3;
const field_kbps = 4;
const field_tags = 5;
const field_clicks = 6;
const field_uuid = 7;
/// The most fields of a record looked at: the answer has 37.
const field_most = 48;

fn fieldOf(fields: []const []const u8, place: ?usize) []const u8 {
    const at = place orelse return "";
    return if (at < fields.len) fields[at] else "";
}

/// A station's entry, on no list yet; null without the memory.
fn make(sys: *ExecBase, made: Made) ?*Station {
    const logo_at: usize = if (made.logo.len > 0) made.url.len + 1 else 0;
    const size = @sizeOf(Station) + made.url.len + 1 + (if (logo_at != 0) made.logo.len + 1 else 0);
    const memory: [*]u8 = @ptrCast(sys.AllocVec(@intCast(size), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null);
    const station: *Station = @ptrCast(@alignCast(memory));
    station.* = .{ .row = .{ .cells = &station.cells }, .cells = @splat(null), .clicks = made.clicks, .logo_at = @intCast(logo_at) };
    const kept = memory + @sizeOf(Station);
    @memcpy(kept[0..made.url.len], made.url);
    kept[made.url.len] = 0;
    if (logo_at != 0) {
        @memcpy(kept[logo_at..][0..made.logo.len], made.logo);
        kept[logo_at + made.logo.len] = 0;
    }
    copyText(&station.name, made.name);
    copyText(&station.country, made.country);
    copyText(&station.tags, made.tags);
    copyText(&station.uuid, made.uuid);
    if (made.kbps != 0) writeNumber(&station.kbps, made.kbps);
    station.row.node.name = @ptrCast(&station.name);
    station.cells[0] = @ptrCast(&station.name);
    if (made.found) {
        station.cells[1] = @ptrCast(&station.country);
        station.cells[2] = @ptrCast(&station.kbps);
        station.cells[3] = @ptrCast(&station.tags);
    } else {
        station.cells[1] = station.url();
    }
    return station;
}

/// The genres as the service writes them, `a,b,c`, with a space after
/// each comma, in place where there is room.
/// A text ended in its buffer made fit to show, where it is: every
/// control character - a tab among them - a space, and the spaces at its
/// ends taken off. What is left.
fn tidy(text: []u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    for (text[0..length]) |*char| {
        if (char.* < ' ' or (char.* >= 0x7F and char.* < 0xA0)) char.* = ' ';
    }
    var start: usize = 0;
    while (start < length and text[start] == ' ') start += 1;
    while (length > start and text[length - 1] == ' ') length -= 1;
    for (start..length) |at| text[at - start] = text[at];
    length -= start;
    text[length] = 0;
    return text[0..length];
}

fn withSpaces(tags: *[name_room + 1]u8) []const u8 {
    var spaced: [name_room + 1]u8 = undefined;
    var out: usize = 0;
    var at: usize = 0;
    while (tags[at] != 0 and out < name_room) : (at += 1) {
        spaced[out] = tags[at];
        out += 1;
        if (tags[at] == ',' and out < name_room and tags[at + 1] != 0) {
            spaced[out] = ' ';
            out += 1;
        }
    }
    @memcpy(tags[0..out], spaced[0..out]);
    tags[out] = 0;
    return tags[0..out];
}

fn isUrl(text: []const u8) bool {
    return startsWith(text, "http://") or startsWith(text, "https://");
}

/// The last part of an address, after its last `/`; the whole of it when
/// that is empty.
fn lastPart(url: []const u8) []const u8 {
    var end = url.len;
    while (end > 0 and url[end - 1] == '/') end -= 1;
    var start = end;
    while (start > 0 and url[start - 1] != '/') start -= 1;
    return if (end > start) url[start..end] else url;
}

/// The number a text starts with; 0 when it starts with none.
fn number(text: []const u8) u32 {
    var result: u32 = 0;
    for (text) |char| {
        if (char < '0' or char > '9') break;
        result = result *| 10 +| (char - '0');
    }
    return result;
}

fn writeNumber(into: *[12]u8, value: u32) void {
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var left = value;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    for (0..count) |i| into[i] = digits[count - 1 - i];
    into[count] = 0;
}

/// `from` into `into`, cut to its room less one, ended.
fn copyText(into: []u8, from: []const u8) void {
    const length = @min(from.len, into.len - 1);
    @memcpy(into[0..length], from[0..length]);
    into[length] = 0;
}

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 32 else char;
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    for (text[0..prefix.len], prefix) |got, want| {
        if (lower(got) != want) return false;
    }
    return true;
}

fn sameText(a: [*:0]const u8, b: [*:0]const u8) bool {
    var at: usize = 0;
    while (a[at] == b[at]) : (at += 1) {
        if (a[at] == 0) return true;
    }
    return false;
}

fn lengthOf(text: [*:0]const u8) usize {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return n;
}
