// SPDX-License-Identifier: MIT
//! The elements html.datatype knows by name, and what each one is: one
//! that starts a block, one that holds nothing (`<br>`, `<img>`), one
//! whose end closes an open paragraph.
//!
//! A name is looked up without regard to case. An element known by no
//! name here is `.other`: it is kept open as any other, so that its end
//! tag is matched, and changes nothing about how its text is drawn.

/// Every element told apart. The names are the elements' own.
pub const Tag = enum(u8) {
    other,
    a,
    abbr,
    address,
    applet,
    area,
    article,
    aside,
    audio,
    b,
    base,
    bdi,
    bdo,
    big,
    blockquote,
    body,
    br,
    button,
    canvas,
    caption,
    center,
    cite,
    code,
    col,
    colgroup,
    data,
    datalist,
    dd,
    del,
    details,
    dfn,
    dialog,
    dir,
    div,
    dl,
    dt,
    em,
    embed,
    fieldset,
    figcaption,
    figure,
    font,
    footer,
    form,
    frame,
    frameset,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    head,
    header,
    hgroup,
    hr,
    html,
    i,
    iframe,
    img,
    input,
    ins,
    kbd,
    keygen,
    label,
    legend,
    li,
    link,
    listing,
    main,
    map,
    mark,
    marquee,
    math,
    menu,
    meta,
    nav,
    nobr,
    noembed,
    noframes,
    noscript,
    object,
    ol,
    optgroup,
    option,
    p,
    param,
    picture,
    plaintext,
    pre,
    q,
    rp,
    rt,
    ruby,
    s,
    samp,
    script,
    search,
    section,
    select,
    small,
    source,
    span,
    strike,
    strong,
    style,
    sub,
    summary,
    sup,
    svg,
    table,
    tbody,
    td,
    template,
    textarea,
    tfoot,
    th,
    thead,
    time,
    title,
    tr,
    track,
    tt,
    u,
    ul,
    @"var",
    video,
    wbr,
    xmp,
};

const names = blk: {
    const fields = @typeInfo(Tag).@"enum".fields;
    var list: [fields.len][]const u8 = undefined;
    for (fields, 0..) |field, index| list[index] = field.name;
    break :blk list;
};

/// The element `name` stands for, its case aside.
pub fn tagOf(name: []const u8) Tag {
    if (name.len == 0 or name.len > 10) return .other;
    for (names[1..], 1..) |known, index| {
        if (known.len != name.len) continue;
        if (sameName(name, known)) return @enumFromInt(index);
    }
    return .other;
}

/// Whether `name` is `lower` (lower case), its own case aside.
pub fn sameName(name: []const u8, lower: []const u8) bool {
    if (name.len != lower.len) return false;
    for (name, lower) |char, want| {
        const folded = if (char >= 'A' and char <= 'Z') char + 32 else char;
        if (folded != want) return false;
    }
    return true;
}

/// An element with no content and no end tag.
pub fn isVoid(tag: Tag) bool {
    return switch (tag) {
        .area, .base, .br, .col, .embed, .frame, .hr, .img, .input, .keygen, .link, .meta, .param, .source, .track, .wbr => true,
        else => false,
    };
}

/// An element that stands as a block of its own: the text before it and
/// the text after it are not one paragraph.
pub fn isBlock(tag: Tag) bool {
    return switch (tag) {
        .address, .article, .aside, .blockquote, .caption, .center, .dd, .details, .dialog, .dir, .div, .dl, .dt, .fieldset, .figcaption, .figure, .footer, .form, .frameset, .h1, .h2, .h3, .h4, .h5, .h6, .header, .hgroup, .hr, .legend, .li, .listing, .main, .marquee, .menu, .nav, .noframes, .ol, .p, .plaintext, .pre, .search, .section, .summary, .table, .tbody, .td, .tfoot, .th, .thead, .tr, .ul, .xmp => true,
        else => false,
    };
}

/// An element whose start closes a paragraph that is open.
pub fn closesParagraph(tag: Tag) bool {
    return switch (tag) {
        .address, .article, .aside, .blockquote, .center, .dd, .details, .dialog, .dir, .div, .dl, .dt, .fieldset, .figcaption, .figure, .footer, .form, .h1, .h2, .h3, .h4, .h5, .h6, .header, .hgroup, .hr, .li, .listing, .main, .menu, .nav, .ol, .p, .plaintext, .pre, .search, .section, .summary, .table, .ul, .xmp => true,
        else => false,
    };
}

/// A heading's level, 1 to 6; 0 for any other element.
pub fn headingLevel(tag: Tag) u8 {
    return switch (tag) {
        .h1 => 1,
        .h2 => 2,
        .h3 => 3,
        .h4 => 4,
        .h5 => 5,
        .h6 => 6,
        else => 0,
    };
}

/// An element nothing of which is shown: a film or a sound, a picture
/// drawn from its markup, a list only a field offers, what a script makes
/// copies of. What stands in a plug-in, a `<canvas>` or a `<picture>` is
/// what shows where they cannot, and is shown.
pub fn isUnshown(tag: Tag) bool {
    return switch (tag) {
        .audio, .datalist, .frameset, .map, .math, .svg, .template, .video => true,
        else => false,
    };
}

/// An element an end tag of another does not reach past: the end of a
/// `<div>` inside a cell does not close one round the table.
pub fn isScopeEdge(tag: Tag) bool {
    return switch (tag) {
        .applet, .caption, .html, .marquee, .object, .table, .td, .template, .th => true,
        else => false,
    };
}

const std = @import("std");
const testing = std.testing;

test "names are found in any case, and others are .other" {
    try testing.expectEqual(Tag.div, tagOf("DIV"));
    try testing.expectEqual(Tag.blockquote, tagOf("BlockQuote"));
    try testing.expectEqual(Tag.@"var", tagOf("var"));
    try testing.expectEqual(Tag.h3, tagOf("h3"));
    try testing.expectEqual(Tag.other, tagOf("my-widget"));
    try testing.expectEqual(Tag.other, tagOf(""));
    try testing.expectEqual(Tag.other, tagOf("other"));
    try testing.expect(isVoid(.br) and !isVoid(.p));
    try testing.expect(isBlock(.li) and !isBlock(.span));
    try testing.expectEqual(@as(u8, 4), headingLevel(.h4));
}
