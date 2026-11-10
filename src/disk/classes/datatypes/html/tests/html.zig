// SPDX-License-Identifier: MIT
//! Host tests of html.datatype's reading: a page read twice, as the class
//! reads it, and its text, runs and blocks looked at. utility.library is
//! the ROM's, made on the ROM's exec, for the characters past Latin-1.

const std = @import("std");
const sdk = @import("sdk");
const host = @import("host_rom");
const parse = @import("../parse.zig");
const tdc = sdk.datatypes.textclass;
const UtilityBase = sdk.interface.utility.UtilityBase;

const testing = std.testing;

const bold: u16 = 1;
const italic: u16 = 2;
const underlined: u16 = 4;

/// Where a page is read into.
const Store = struct {
    source: [4096]u8 = undefined,
    text: [4096]u8 = undefined,
    pieces: [256]tdc.Piece = undefined,
    blocks: [64]tdc.Block = undefined,
};

const Read = struct {
    text: []const u8,
    /// The text and the link targets after it.
    whole: []const u8,
    pieces: []const tdc.Piece,
    blocks: []const tdc.Block,
    title: []const u8,
};

/// The page made Latin-1 and read twice, as the class does; both passes
/// agree on how much there is.
fn readTwice(ub: *UtilityBase, page: []const u8, store: *Store) !Read {
    @memcpy(store.source[0..page.len], page);
    const from = store.source[0..parse.toLatin1(ub, store.source[0..page.len])];
    var counting = parse.Build{ .ub = ub };
    parse.build(from, &counting);
    var writing = parse.Build{
        .ub = ub,
        .text = &store.text,
        .pieces = &store.pieces,
        .blocks = &store.blocks,
        .link_base = counting.text_len,
    };
    parse.build(from, &writing);
    try testing.expectEqual(counting.text_len, writing.text_len);
    try testing.expectEqual(counting.link_len, writing.link_len);
    try testing.expectEqual(counting.piece_count, writing.piece_count);
    try testing.expectEqual(counting.block_count, writing.block_count);
    // Every run in its place, one after another, and every block's runs
    // ending with its terminator.
    var next: u32 = 0;
    for (store.pieces[0..writing.piece_count]) |piece| {
        try testing.expectEqual(next, piece.offset);
        try testing.expect(piece.length > 0);
        next += piece.length;
    }
    try testing.expectEqual(writing.text_len, next);
    var first: u32 = 0;
    for (store.blocks[0..writing.block_count]) |block| {
        try testing.expectEqual(first, block.first);
        try testing.expect(block.count > 0);
        first += block.count;
        const last = store.pieces[block.first + block.count - 1];
        const terminator = store.text[last.offset];
        try testing.expect(last.length == 1 and (terminator == '\n' or terminator == '\t'));
    }
    try testing.expectEqual(writing.piece_count, first);
    return .{
        .text = store.text[0..writing.text_len],
        .whole = store.text[0 .. writing.text_len + writing.link_len],
        .pieces = store.pieces[0..writing.piece_count],
        .blocks = store.blocks[0..writing.block_count],
        .title = writing.title[0..writing.title_len],
    };
}

/// The text of a block, without the character that ends it.
fn textOf(read: Read, block: tdc.Block) []const u8 {
    const first = read.pieces[block.first];
    const last = read.pieces[block.first + block.count - 1];
    return read.text[first.offset..last.offset];
}

/// The run that holds `words`, which is to be one of its own.
fn runOf(read: Read, words: []const u8) !tdc.Piece {
    for (read.pieces) |piece| {
        if (std.mem.eql(u8, read.text[piece.offset..][0..piece.length], words)) return piece;
    }
    std.debug.print("no run \"{s}\" in \"{s}\"\n", .{ words, read.text });
    return error.NoSuchRun;
}

fn targetOf(read: Read, piece: tdc.Piece) []const u8 {
    return read.whole[piece.link_offset..][0..piece.link_length];
}

test "a page: its title, headings, paragraphs and the runs of its words" {
    const rom_ub = try host.utility.setUp();
    defer host.exec.deinit();
    const ub: *UtilityBase = @ptrCast(rom_ub);
    var store: Store = .{};
    const got = try readTwice(ub,
        \\<html><head><title> A  &amp;
        \\ B </title><style>p { color: red }</style><script>x = "<p>no</p>";</script></head>
        \\<body><h1>Title</h1><p>Some <em>words</em>  here.<h3>Third</h3>Next</body></html>
    , &store);
    try testing.expectEqualStrings("A & B", got.title);
    try testing.expectEqualStrings("Title\nSome words here.\nThird\nNext\n", got.text);
    try testing.expectEqual(@as(usize, 4), got.blocks.len);
    try testing.expectEqual(tdc.TDBLOCK_HEADING, got.blocks[0].kind);
    try testing.expectEqual(@as(u8, 1), got.blocks[0].level);
    try testing.expectEqual(tdc.TDBLOCK_PARAGRAPH, got.blocks[1].kind);
    try testing.expectEqual(@as(u8, 3), got.blocks[2].level);
    const title = try runOf(got, "Title");
    try testing.expectEqual(tdc.TDFONT_LARGER, title.font);
    try testing.expectEqual(bold, title.style);
    try testing.expectEqual(tdc.TDFONT_BIG, (try runOf(got, "Third")).font);
    try testing.expectEqual(italic, (try runOf(got, "words")).style);
    try testing.expectEqual(@as(u16, 0), (try runOf(got, " here.")).style);
    try host.utility.tearDown(rom_ub);
}

test "what an element's start and end close, and an end with nothing to close" {
    const rom_ub = try host.utility.setUp();
    defer host.exec.deinit();
    const ub: *UtilityBase = @ptrCast(rom_ub);
    var store: Store = .{};
    const got = try readTwice(ub, "<p>one<p>two<div>three</div>four<ul><li>a<li>b</ul>five<my-box>six</my-box></div><p>se</span>ven", &store);
    try testing.expectEqualStrings("one\ntwo\nthree\nfour\na\nb\nfivesix\nseven\n", got.text);
    try testing.expectEqual(@as(usize, 8), got.blocks.len);
    try testing.expectEqual(tdc.TDMARK_DISC, got.blocks[4].mark);
    try testing.expect(got.blocks[4].flags & tdc.TDBF_START != 0);
    try testing.expect(got.blocks[5].flags & tdc.TDBF_START == 0);
    try testing.expectEqual(@as(u8, 1), got.blocks[5].depth);
    try testing.expectEqual(@as(u8, 0), got.blocks[6].depth);
    try host.utility.tearDown(rom_ub);
}

test "lists: their marks by depth, numbers, and an item with a list first" {
    const rom_ub = try host.utility.setUp();
    defer host.exec.deinit();
    const ub: *UtilityBase = @ptrCast(rom_ub);
    var store: Store = .{};
    const got = try readTwice(ub,
        \\<ul><li>one<ul><li>in</ul><li><ul><li>deep</ul></ul>
        \\<ol start="4"><li>four<li value="9">nine<li><p>ten</ol>
        \\<ol type="a"><li>letter</ol><dl><dt>term<dd>meaning</dl>
        \\<blockquote><p>said</blockquote>
    , &store);
    try testing.expectEqualStrings("one\nin\n\ndeep\nfour\nnine\nten\nletter\nterm\nmeaning\nsaid\n", got.text);
    const b = got.blocks;
    try testing.expectEqual(tdc.TDMARK_DISC, b[0].mark);
    try testing.expectEqual(tdc.TDMARK_CIRCLE, b[1].mark);
    try testing.expectEqual(@as(u8, 2), b[1].depth);
    try testing.expectEqual(tdc.TDMARK_DISC, b[2].mark);
    try testing.expect(b[2].flags & tdc.TDBF_START == 0);
    try testing.expectEqual(tdc.TDMARK_CIRCLE, b[3].mark);
    try testing.expectEqual(tdc.TDMARK_NUMBER, b[4].mark);
    try testing.expectEqual(@as(u32, 4), b[4].number);
    try testing.expect(b[4].flags & tdc.TDBF_START != 0);
    try testing.expectEqual(@as(u32, 9), b[5].number);
    try testing.expectEqual(@as(u32, 10), b[6].number);
    try testing.expect(b[6].flags & tdc.TDBF_LOOSE != 0);
    try testing.expectEqual(tdc.TDMARK_LETTER, b[7].mark);
    try testing.expectEqual(tdc.TDMARK_NONE, b[8].mark);
    try testing.expectEqual(@as(u8, 0), b[8].depth);
    try testing.expectEqual(@as(u8, 1), b[9].depth);
    try testing.expectEqual(@as(u8, 0), b[9].quotes);
    try testing.expectEqual(@as(u8, 1), b[10].quotes);
    try testing.expectEqual(tdc.TDPEN_MUTED, (try runOf(got, "said")).pen);
    try host.utility.tearDown(rom_ub);
}

test "a table drawn as one: its caption, head, cells, columns and row ends" {
    const rom_ub = try host.utility.setUp();
    defer host.exec.deinit();
    const ub: *UtilityBase = @ptrCast(rom_ub);
    var store: Store = .{};
    const got = try readTwice(ub,
        \\<table><caption>Cap</caption><tr><th>A</th><th>B</th></tr>
        \\<tr><td>1</td><td align=right>2</td></tr> lost
        \\<tr><td colspan=2 rowspan=2>wide</td><td>x</td></tr><tr><td>y<br>z</td></table><p>after
    , &store);
    try testing.expectEqualStrings("Cap\nA\tB\n1\t2\nwide\tx\ny\nz\nafter\n", got.text);
    const b = got.blocks;
    try testing.expectEqual(@as(usize, 9), b.len);
    try testing.expectEqual(tdc.TDBLOCK_PARAGRAPH, b[0].kind);
    for (b[1..8]) |cell| try testing.expectEqual(tdc.TDBLOCK_CELL, cell.kind);
    try testing.expectEqual(tdc.TDBF_ROW | tdc.TDBF_TABLE | tdc.TDBF_HEAD, b[1].flags);
    try testing.expectEqual(tdc.TDBF_HEAD, b[2].flags);
    try testing.expectEqual(@as(u32, 1), b[2].number);
    try testing.expectEqual(tdc.TDBF_ROW, b[3].flags);
    try testing.expectEqual(tdc.TDALIGN_RIGHT, b[4].alignment);
    try testing.expectEqual(@as(u32, 0), b[5].number);
    // A cell two columns wide is drawn across both, and the next is in
    // the third.
    try testing.expectEqual(@as(u8, 2), b[5].span);
    try testing.expectEqual(@as(u8, 1), b[4].span);
    try testing.expectEqual(@as(u32, 2), b[6].number);
    // The wide cell takes its columns in the row below too.
    try testing.expectEqual(tdc.TDBF_ROW, b[7].flags);
    try testing.expectEqual(@as(u32, 2), b[7].number);
    try testing.expectEqual(bold, (try runOf(got, "A")).style);
    try testing.expectEqual(tdc.TDBLOCK_PARAGRAPH, b[8].kind);
    try host.utility.tearDown(rom_ub);
}

test "a table that lays a page out is read as blocks" {
    const rom_ub = try host.utility.setUp();
    defer host.exec.deinit();
    const ub: *UtilityBase = @ptrCast(rom_ub);
    var store: Store = .{};
    const got = try readTwice(ub, "<table><tr><td>one</td><td>two</td></tr><tr><td><table><tr><td>in</td></tr></table></td></tr></table><table><tr><td>a</td></tr><tr><td>b</td></tr></table>", &store);
    try testing.expectEqualStrings("one\ntwo\nin\na\nb\n", got.text);
    for (got.blocks) |block| try testing.expectEqual(tdc.TDBLOCK_PARAGRAPH, block.kind);
    try host.utility.tearDown(rom_ub);
}

test "what is not shown, and fields and pictures as their text" {
    const rom_ub = try host.utility.setUp();
    defer host.exec.deinit();
    const ub: *UtilityBase = @ptrCast(rom_ub);
    var store: Store = .{};
    const got = try readTwice(ub,
        \\<p>a<span hidden>x</span> b<script>c</script><style>d</style><svg><text>e</text></svg> f<select><option>r<option selected>g</select>
        \\<input type=checkbox checked><input value="v"><button> go </button><img alt="pic"><input type=hidden value=h>
        \\<span style="color: red; DISPLAY : none">no</span><span aria-hidden="true">no</span><q>said</q></p>
        \\<ul><li hidden>gone<li>kept</ul><template><p>copy</p></template><dialog><p>closed</p></dialog>
    , &store);
    try testing.expectEqualStrings("a b f[g] [x][v][go]pic \"said\"\nkept\n", got.text);
    const pic = try runOf(got, "pic");
    try testing.expectEqual(italic, pic.style);
    try testing.expectEqual(tdc.TDPEN_MUTED, pic.pen);
    try testing.expect(got.blocks[1].flags & tdc.TDBF_START != 0);
    try host.utility.tearDown(rom_ub);
}

test "characters: references, code page 1252, UTF-8 and what Latin-1 has not" {
    const rom_ub = try host.utility.setUp();
    defer host.exec.deinit();
    const ub: *UtilityBase = @ptrCast(rom_ub);
    var store: Store = .{};
    const got = try readTwice(ub, "<title>T&ndash;x</title><p>caf&eacute; &#150; &#x263A; “q” Grüße&hellip;&nbsp;€ &amp; &lt;b&gt; &copy &notit;</p>", &store);
    try testing.expectEqualStrings("T-x", got.title);
    try testing.expectEqualStrings("caf\xE9 - ? \"q\" Gr\xFC\xDFe...\xA0? & <b> \xA9 \xACit;\n", got.text);

    // A page that says it is Latin-1 is read byte for byte, and 1252's
    // quotes are quotes.
    const latin = try readTwice(ub, "<meta charset=\"ISO-8859-1\"><p>\xE9 \x93q\x94</p>", &store);
    try testing.expectEqualStrings("\xE9 \"q\"\n", latin.text);
    // A page in UTF-8 with a Latin-1 byte in it keeps the byte.
    const mixed = try readTwice(ub, "<p>\xE9t\xC3\xA9</p>", &store);
    try testing.expectEqualStrings("\xE9t\xE9\n", mixed.text);
    try host.utility.tearDown(rom_ub);
}

test "links: their runs, and their targets after the text" {
    const rom_ub = try host.utility.setUp();
    defer host.exec.deinit();
    const ub: *UtilityBase = @ptrCast(rom_ub);
    var store: Store = .{};
    const got = try readTwice(ub, "<p><a href=\" a b&amp;c \">one</a> <a href='/wiki/Stra%C3%9Fe'>two</a> <A HREF=ü>three <b>bold</b></a><a name=x>none</a></p>", &store);
    try testing.expectEqualStrings("one two three boldnone\n", got.text);
    const one = try runOf(got, "one");
    try testing.expectEqual(tdc.TDPEN_LINK, one.pen);
    try testing.expectEqual(underlined, one.style);
    try testing.expectEqualStrings("a%20b&c", targetOf(got, one));
    try testing.expectEqual(@as(u32, 0), (try runOf(got, " ")).link_length);
    try testing.expectEqualStrings("/wiki/Stra%C3%9Fe", targetOf(got, try runOf(got, "two")));
    const three = try runOf(got, "three ");
    try testing.expectEqualStrings("%C3%BC", targetOf(got, three));
    const in_bold = try runOf(got, "bold");
    try testing.expectEqual(underlined | bold, in_bold.style);
    try testing.expectEqualStrings("%C3%BC", targetOf(got, in_bold));
    try testing.expectEqual(@as(u32, 0), (try runOf(got, "none")).link_length);
    try host.utility.tearDown(rom_ub);
}

test "a listing as it stands, and line ends in a paragraph" {
    const rom_ub = try host.utility.setUp();
    defer host.exec.deinit();
    const ub: *UtilityBase = @ptrCast(rom_ub);
    var store: Store = .{};
    const got = try readTwice(ub, "<pre>\n  a\tb &lt;\n\n</pre><p>  one <br> two<br></p><xmp><b>&amp;</b></xmp>", &store);
    try testing.expectEqualStrings("  a     b <\none\ntwo\n<b>&amp;</b>\n", got.text);
    try testing.expectEqual(@as(usize, 3), got.blocks.len);
    try testing.expectEqual(tdc.TDBLOCK_LISTING, got.blocks[0].kind);
    try testing.expectEqual(tdc.TDFONT_FIXED, got.pieces[0].font);
    try testing.expectEqualStrings("one\ntwo", textOf(got, got.blocks[1]));
    try testing.expectEqual(tdc.TDBLOCK_LISTING, got.blocks[2].kind);
    try host.utility.tearDown(rom_ub);
}

test "a page with nothing to show has no text" {
    const rom_ub = try host.utility.setUp();
    defer host.exec.deinit();
    const ub: *UtilityBase = @ptrCast(rom_ub);
    var store: Store = .{};
    const got = try readTwice(ub, "<!DOCTYPE html><html><head><title>Empty</title></head><body>\n  <p> </p><div></div>\n</body></html>", &store);
    try testing.expectEqual(@as(usize, 0), got.text.len);
    try testing.expectEqual(@as(usize, 0), got.blocks.len);
    try testing.expectEqualStrings("Empty", got.title);
    try host.utility.tearDown(rom_ub);
}

test "the sample page on the disk reads" {
    const rom_ub = try host.utility.setUp();
    defer host.exec.deinit();
    const ub: *UtilityBase = @ptrCast(rom_ub);
    const page = @embedFile("../../../../tests/datatypes/Page.html");
    var source: [page.len]u8 = page.*;
    const from = source[0..parse.toLatin1(ub, &source)];
    var counting = parse.Build{ .ub = ub };
    parse.build(from, &counting);
    try testing.expectEqualStrings("A page to read - html.datatype", counting.title[0..counting.title_len]);
    try testing.expect(counting.block_count > 40);
    try host.utility.tearDown(rom_ub);
}
