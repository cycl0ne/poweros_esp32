// SPDX-License-Identifier: MIT
//! Talking to a remote's upload-pack or receive-pack: its advertisement
//! read, its refs listed, a pack fetched - in protocol version 2 where
//! the server speaks it, in version 0 where it answers that way - or refs
//! set and a pack sent, over a link that carries the bytes (smart HTTP,
//! an SSH channel).
//!
//! **The advertisement.** A server that speaks version 2 answers with
//! `version 2` and its capabilities, a line each (`ls-refs`, `fetch=shallow
//! ...`, `object-format=sha1`); one that does not lists its refs at once,
//! the first line carrying its capabilities after a NUL. Over HTTP either
//! may come after a `# service=git-upload-pack` line and a flush.
//!
//! **Refs**: version 2 asks for them with `ls-refs`, naming the prefixes
//! wanted, and gets each with its symref target and its peeled object;
//! version 0 has them all in the advertisement, a tag's peeled object on
//! a line of its own after it (`refs/tags/v1^{}`), HEAD's target among
//! the capabilities (`symref=HEAD:refs/heads/main`).
//!
//! **A fetch** sends the wanted commits, the ones at hand, a depth, and
//! `done`: one exchange, the server's answer the shallow boundary and the
//! pack. The pack comes in side-band packets: band 1 the pack's bytes,
//! band 2 the server's progress, band 3 an error. The pack goes to a sink
//! as it comes, its SHA-1 checked against the trailer at its end.
//!
//! **A push** speaks version 0, receive-pack's only one: a line for each
//! ref set - its old id, its new one and its name, the first line
//! carrying the capabilities asked for (`report-status`, side-band) -
//! a flush, and the pack, sent a piece at a time as it is read from its
//! file. The answer is the report: `unpack ok`, then `ok <ref>` or `ng
//! <ref> <reason>` for each, in band 1 when side-band was asked for.
//!
//! Nothing here writes to the console: a failure is left in `failure`
//! (and the server's message in `message`), progress goes to a listener.

const _git = @import("_git.zig");
const pktline = @import("pktline.zig");
const receive = @import("receive.zig");
const Id = _git.Id;
const CryptoBase = @import("sdk").interface.crypto.CryptoBase;

pub const agent = "PowerOS-Git/1.0";

/// What carries the bytes between Git and the server.
pub const Link = struct {
    context: *anyopaque,
    /// The request `body` sent, in the protocol `version` the server
    /// answered the advertisement in; what `read` reads from then on is
    /// its answer. False when it could not be sent, or was not answered
    /// (the link has said why).
    exchange: *const fn (context: *anyopaque, body: []const u8, version: u8) bool,
    /// The answer's bytes into `into`: how many, 0 at its end, below 0
    /// when reading failed (the link has said why).
    read: *const fn (context: *anyopaque, into: []u8) i32,
    /// A request too long to hold, sent in pieces: `begin` with its
    /// whole length, `write` with each piece in turn, `end` once all are
    /// sent; what `read` reads then is its answer. False when it could
    /// not be done (the link has said why).
    begin: *const fn (context: *anyopaque, length: u64, version: u8) bool,
    write: *const fn (context: *anyopaque, bytes: []const u8) bool,
    end: *const fn (context: *anyopaque) bool,
};

/// One ref, as a remote lists it.
pub const Ref = struct {
    /// The object it names; zero for an unborn one.
    id: Id,
    name: []const u8,
    /// A tag's: the object it peels to, a commit mostly.
    peeled: ?Id = null,
    /// A symbolic ref's (HEAD): the ref it names.
    target: ?[]const u8 = null,
    /// A ref the repository names without a commit yet - an empty
    /// repository's HEAD.
    unborn: bool = false,
};

/// Handed each ref in turn: false stops the listing (`failure` is then
/// `.stopped`). The ref and the names it points at are the remote's
/// until the call returns.
pub const RefFn = *const fn (context: *anyopaque, ref: *const Ref) bool;

pub const Failure = enum {
    none,
    /// The link failed and said why.
    link,
    /// The answer ended in the middle.
    ended,
    /// The answer is no protocol Git knows.
    malformed,
    /// The server said why, in `message`.
    remote,
    /// The repository's objects are not named by SHA-1.
    object_format,
    /// A depth asked of a server that cannot cut history.
    no_shallow,
    /// The request is longer than there is room for.
    too_long,
    /// The pack is not one, or its checksum is wrong.
    pack,
    /// The sink did not take the pack.
    sink,
    /// A listener stopped it.
    stopped,
    /// The pack to send could not be read.
    source,
    /// The server could not take the pack it was sent; its words are in
    /// `message`.
    unpack,
};

/// What the server says while it works, and how much of the pack has
/// come. Either may stop the fetch by answering false.
pub const Listener = struct {
    context: *anyopaque,
    /// Side-band 2: the server's progress, a piece of its text, lines
    /// ended by line feeds or carriage returns.
    text: *const fn (context: *anyopaque, text: []const u8) bool,
    /// So many bytes of the pack have come.
    received: *const fn (context: *anyopaque, bytes: u64) bool,
};

/// What a fetch asks for.
pub const Fetch = struct {
    wants: []const Id,
    /// Commits the repository has, so the server sends only what is new.
    haves: []const Id = &.{},
    /// The commits the repository's history is cut at (its `shallow`).
    shallow: []const Id = &.{},
    /// History this many commits deep; 0 for all of it.
    depth: u32 = 0,
    /// Tags pointing into what comes, sent along.
    include_tags: bool = true,
    /// The server's progress left out.
    quiet: bool = false,
    /// Told each commit the server cuts history at (true) or no longer
    /// cuts it at (false).
    boundary: ?*const fn (context: *anyopaque, id: *const Id, shallow: bool) bool = null,
    boundary_context: *anyopaque = undefined,
};

/// A ref a push sets on the remote: `name` from `old` (zero for one it
/// does not have) to `new`. The server's answer is put in `status`, and
/// for a refusal its reason in `reason`.
pub const Update = struct {
    name: []const u8,
    old: Id,
    new: Id,
    status: Status = .waiting,
    reason: [reason_most]u8 = undefined,
    reason_length: usize = 0,

    pub const Status = enum { waiting, done, refused };

    pub fn reasonText(update: *const Update) []const u8 {
        return update.reason[0..update.reason_length];
    }

    fn refuse(update: *Update, reason: []const u8) void {
        update.status = .refused;
        const length = @min(reason.len, update.reason.len);
        @memcpy(update.reason[0..length], reason[0..length]);
        update.reason_length = length;
    }
};

const reason_most = 80;

/// The pack a push sends, read a piece at a time.
pub const PackSource = struct {
    context: *anyopaque,
    /// Its length in bytes.
    length: u64,
    /// The next bytes into `into`: how many, 0 at its end, below 0 when
    /// it could not be read.
    read: *const fn (context: *anyopaque, into: []u8) i32,
};

/// What a push sends.
pub const Push = struct {
    updates: []Update,
    pack: PackSource,
    /// The server's progress left out.
    quiet: bool = false,
};

const capabilities_most = 4096;
const request_most = 64 * 1024;
const name_most = 1024;

pub const Remote = struct {
    link: Link,
    cb: *CryptoBase,
    reader: pktline.Reader,
    listener: ?Listener = null,
    version: u8 = 0,
    failure: Failure = .none,
    /// The server's own words for `.remote`, NUL-terminated.
    message: [256]u8 = @splat(0),
    /// Version 2: the capability lines, each ended by a line feed.
    /// Version 0: the first ref line's, a space before each.
    capabilities: [capabilities_most]u8 = undefined,
    capabilities_length: usize = 0,
    /// Version 0: the advertisement's refs are still to be read, the
    /// first one - which came with the capabilities - waiting in `held`.
    advertising: bool = false,
    held: Ref = undefined,
    held_name: [name_most]u8 = undefined,
    have_held: bool = false,
    request: [request_most]u8 = undefined,
    buffer: [pktline.buffer_bytes]u8 = undefined,

    /// A remote over `link`, ready for `start`.
    pub fn init(remote: *Remote, link: Link, cb: *CryptoBase) void {
        // Field by field: the buffers are too big for a copy on a stack.
        remote.link = link;
        remote.cb = cb;
        remote.reader = .{ .source = .{ .context = remote, .read = readLink }, .buffer = &remote.buffer };
        remote.listener = null;
        remote.version = 0;
        remote.failure = .none;
        remote.message[0] = 0;
        remote.capabilities_length = 0;
        remote.advertising = false;
        remote.have_held = false;
    }

    fn readLink(context: *anyopaque, into: []u8) i32 {
        const remote: *Remote = @ptrCast(@alignCast(context));
        return remote.link.read(remote.link.context, into);
    }

    /// The advertisement read: which version the server speaks, its
    /// capabilities, and for version 0 the first ref.
    pub fn start(remote: *Remote) bool {
        var packet = remote.next() orelse return false;
        if (packet.kind == .data and _git.startsWith(packet.data, "# service=")) {
            const flush = remote.next() orelse return false;
            if (flush.kind != .flush) return remote.fail(.malformed);
            packet = remote.next() orelse return false;
        }
        if (packet.kind == .flush) {
            // Version 0 with no refs and nothing to say.
            return true;
        }
        if (packet.kind != .data) return remote.fail(.malformed);
        if (_git.same(pktline.line(packet.data), "version 2")) {
            remote.version = 2;
            while (true) {
                const line_packet = remote.next() orelse return false;
                if (line_packet.kind == .flush) break;
                if (line_packet.kind != .data) return remote.fail(.malformed);
                const text = pktline.line(line_packet.data);
                if (remote.capabilities_length + text.len + 1 > remote.capabilities.len) return remote.fail(.malformed);
                @memcpy(remote.capabilities[remote.capabilities_length..][0..text.len], text);
                remote.capabilities[remote.capabilities_length + text.len] = '\n';
                remote.capabilities_length += text.len + 1;
            }
            if (remote.capability("ls-refs") == null or remote.capability("fetch") == null) return remote.fail(.malformed);
        } else {
            if (_git.same(pktline.line(packet.data), "version 1")) {
                packet = remote.next() orelse return false;
                if (packet.kind == .flush) return true;
                if (packet.kind != .data) return remote.fail(.malformed);
            }
            remote.version = 0;
            const text = pktline.line(packet.data);
            var nul: usize = 0;
            while (nul < text.len and text[nul] != 0) nul += 1;
            if (nul == text.len) return remote.fail(.malformed);
            const words = text[nul + 1 ..];
            if (words.len + 2 > remote.capabilities.len) return remote.fail(.malformed);
            remote.capabilities[0] = ' ';
            @memcpy(remote.capabilities[1..][0..words.len], words);
            remote.capabilities[1 + words.len] = ' ';
            remote.capabilities_length = words.len + 2;
            remote.advertising = true;
            const ref = parseAdvertised(text[0..nul]) orelse return remote.fail(.malformed);
            // An empty repository advertises its capabilities on a ref
            // that is none.
            if (!_git.same(ref.name, "capabilities^{}")) remote.hold(ref.id, ref.name) orelse return false;
        }
        if (remote.capability("object-format")) |format| {
            if (!_git.same(format, "sha1")) return remote.fail(.object_format);
        }
        return true;
    }

    /// The value of a capability (`fetch=shallow filter` gives `shallow
    /// filter`, a capability without one an empty value); null when the
    /// server does not have it.
    pub fn capability(remote: *const Remote, name: []const u8) ?[]const u8 {
        const all = remote.capabilities[0..remote.capabilities_length];
        const separator: u8 = if (remote.version == 2) '\n' else ' ';
        var at: usize = 0;
        while (at < all.len) {
            var end = at;
            while (end < all.len and all[end] != separator) end += 1;
            const word = all[at..end];
            if (_git.startsWith(word, name)) {
                if (word.len == name.len) return word[name.len..];
                if (word[name.len] == '=') return word[name.len + 1 ..];
            }
            at = end + 1;
        }
        return null;
    }

    /// Whether a version 2 command's value names `feature`.
    pub fn feature(remote: *const Remote, command: []const u8, name: []const u8) bool {
        const value = remote.capability(command) orelse return false;
        var at: usize = 0;
        while (at < value.len) {
            var end = at;
            while (end < value.len and value[end] != ' ') end += 1;
            if (_git.same(value[at..end], name)) return true;
            at = end + 1;
        }
        return false;
    }

    /// HEAD's target, as version 0's capabilities name it.
    fn symrefOfHead(remote: *const Remote) ?[]const u8 {
        const all = remote.capabilities[0..remote.capabilities_length];
        const key = " symref=HEAD:";
        var at: usize = 0;
        while (at + key.len <= all.len) : (at += 1) {
            if (!_git.same(all[at..][0..key.len], key)) continue;
            var end = at + key.len;
            while (end < all.len and all[end] != ' ') end += 1;
            return all[at + key.len .. end];
        }
        return null;
    }

    /// Every ref whose name starts with one of `prefixes` (all of them
    /// for none) handed to `each`, HEAD with its target and a tag with
    /// its peeled object.
    pub fn listRefs(remote: *Remote, prefixes: []const []const u8, each: RefFn, context: *anyopaque) bool {
        return switch (remote.version) {
            2 => remote.listRefs2(prefixes, each, context),
            else => remote.listRefs0(prefixes, each, context),
        };
    }

    fn listRefs2(remote: *Remote, prefixes: []const []const u8, each: RefFn, context: *anyopaque) bool {
        var out: _git.Out = .{ .into = &remote.request };
        remote.commandHead(&out, "ls-refs");
        pktline.put(&out, "peel\n");
        pktline.put(&out, "symrefs\n");
        if (remote.feature("ls-refs", "unborn")) pktline.put(&out, "unborn\n");
        for (prefixes) |prefix| pktline.putParts(&out, &.{ "ref-prefix ", prefix, "\n" });
        out.put(pktline.flush);
        if (!remote.send(&out)) return false;
        while (true) {
            const packet = remote.next() orelse return false;
            if (packet.kind == .flush) return true;
            if (packet.kind != .data) return remote.fail(.malformed);
            const ref = parseListed(pktline.line(packet.data)) orelse return remote.fail(.malformed);
            if (!each(context, &ref)) return remote.fail(.stopped);
        }
    }

    fn listRefs0(remote: *Remote, prefixes: []const []const u8, each: RefFn, context: *anyopaque) bool {
        const head_target = remote.symrefOfHead();
        while (remote.advertising) {
            const packet = remote.next() orelse return false;
            var next_ref: ?Ref = null;
            if (packet.kind == .flush) {
                remote.advertising = false;
            } else {
                if (packet.kind != .data) return remote.fail(.malformed);
                const ref = parseAdvertised(pktline.line(packet.data)) orelse return remote.fail(.malformed);
                if (_git.startsWith(ref.name, "refs/") and endsWith(ref.name, "^{}")) {
                    // The tag held before it, peeled.
                    if (remote.have_held and _git.same(remote.held.name, ref.name[0 .. ref.name.len - 3])) remote.held.peeled = ref.id;
                    continue;
                }
                next_ref = ref;
            }
            if (remote.have_held) {
                remote.have_held = false;
                var ref = remote.held;
                if (_git.same(ref.name, "HEAD")) ref.target = head_target;
                if (prefixed(ref.name, prefixes) and !each(context, &ref)) return remote.fail(.stopped);
            }
            if (next_ref) |ref| remote.hold(ref.id, ref.name) orelse return false;
        }
        return true;
    }

    /// A version 0 ref kept until the line after it, which may peel it.
    fn hold(remote: *Remote, id: Id, name: []const u8) ?void {
        if (name.len > remote.held_name.len) {
            _ = remote.fail(.malformed);
            return null;
        }
        @memcpy(remote.held_name[0..name.len], name);
        remote.held = .{ .id = id, .name = remote.held_name[0..name.len] };
        remote.have_held = true;
    }

    /// `want` fetched, its pack into `sink`.
    pub fn fetch(remote: *Remote, want: *const Fetch, sink: _git.Sink) ?receive.Received {
        // The rest of a version 0 advertisement is not needed.
        if (remote.version == 0) {
            while (remote.advertising) {
                const packet = remote.next() orelse return null;
                if (packet.kind == .flush) remote.advertising = false;
            }
        }
        var out: _git.Out = .{ .into = &remote.request };
        const band = if (remote.version == 2) true else remote.fetchRequest0(&out, want) orelse return null;
        if (remote.version == 2) {
            if (want.depth != 0 and !remote.feature("fetch", "shallow")) {
                _ = remote.fail(.no_shallow);
                return null;
            }
            remote.commandHead(&out, "fetch");
            if (want.quiet) pktline.put(&out, "no-progress\n");
            pktline.put(&out, "ofs-delta\n");
            if (want.include_tags) pktline.put(&out, "include-tag\n");
            remote.fetchLines(&out, want);
            pktline.put(&out, "done\n");
            out.put(pktline.flush);
        }
        if (!remote.send(&out)) return null;

        if (remote.version == 2) {
            // Sections, each ended by a delimiter, the pack the last.
            while (true) {
                const packet = remote.next() orelse return null;
                if (packet.kind != .data) {
                    _ = remote.fail(.malformed);
                    return null;
                }
                const name = pktline.line(packet.data);
                if (_git.same(name, "packfile")) break;
                if (_git.same(name, "shallow-info")) {
                    if (!remote.readBoundary(want, .delim)) return null;
                } else if (!remote.skipSection()) return null;
            }
        } else {
            // The cut is told, ended by a flush, only when the request
            // deepens; the commits named as cut already get no answer.
            if (want.depth != 0) {
                if (!remote.readBoundary(want, .flush)) return null;
            }
            // ACKs for the commits in common, ended by the last ACK or a
            // NAK.
            while (true) {
                const packet = remote.next() orelse return null;
                if (packet.kind != .data) {
                    _ = remote.fail(.malformed);
                    return null;
                }
                const text = pktline.line(packet.data);
                if (_git.same(text, "NAK")) break;
                if (!_git.startsWith(text, "ACK ")) {
                    _ = remote.fail(.malformed);
                    return null;
                }
                if (text.len == 4 + 40) break;
            }
        }
        return remote.receivePack(sink, band);
    }

    /// Version 0's request: the first want carrying the capabilities
    /// asked for. Whether the pack comes in side-band packets.
    fn fetchRequest0(remote: *Remote, out: *_git.Out, want: *const Fetch) ?bool {
        if (want.wants.len == 0) {
            _ = remote.fail(.malformed);
            return null;
        }
        if ((want.depth != 0 or want.shallow.len != 0) and remote.capability("shallow") == null) {
            _ = remote.fail(.no_shallow);
            return null;
        }
        var words: [256]u8 = undefined;
        var line: _git.Out = .{ .into = &words };
        line.put("want ");
        line.hex(&want.wants[0]);
        const chosen = [_][]const u8{ "multi_ack_detailed", "side-band-64k", "ofs-delta" };
        for (chosen) |word| {
            if (remote.capability(word) != null) {
                line.byte(' ');
                line.put(word);
            }
        }
        const band = remote.capability("side-band-64k") != null or remote.capability("side-band") != null;
        if (band and remote.capability("side-band-64k") == null) line.put(" side-band");
        if ((want.depth != 0 or want.shallow.len != 0)) line.put(" shallow");
        if (want.quiet and remote.capability("no-progress") != null) line.put(" no-progress");
        if (want.include_tags and remote.capability("include-tag") != null) line.put(" include-tag");
        if (remote.capability("agent") != null) line.put(" agent=" ++ agent);
        if (remote.capability("object-format") != null) line.put(" object-format=sha1");
        line.byte('\n');
        pktline.put(out, line.written());
        for (want.wants[1..]) |*id| pktline.putParts(out, &.{ "want ", &hexText(id), "\n" });
        for (want.shallow) |*id| pktline.putParts(out, &.{ "shallow ", &hexText(id), "\n" });
        if (want.depth != 0) {
            var digits: [12]u8 = undefined;
            var number: _git.Out = .{ .into = &digits };
            number.decimal(want.depth);
            pktline.putParts(out, &.{ "deepen ", number.written(), "\n" });
        }
        out.put(pktline.flush);
        for (want.haves) |*id| pktline.putParts(out, &.{ "have ", &hexText(id), "\n" });
        pktline.put(out, "done\n");
        return band;
    }

    /// Version 2's shallow, deepen, want and have lines.
    fn fetchLines(remote: *Remote, out: *_git.Out, want: *const Fetch) void {
        _ = remote;
        for (want.shallow) |*id| pktline.putParts(out, &.{ "shallow ", &hexText(id), "\n" });
        if (want.depth != 0) {
            var digits: [12]u8 = undefined;
            var number: _git.Out = .{ .into = &digits };
            number.decimal(want.depth);
            pktline.putParts(out, &.{ "deepen ", number.written(), "\n" });
        }
        for (want.wants) |*id| pktline.putParts(out, &.{ "want ", &hexText(id), "\n" });
        for (want.haves) |*id| pktline.putParts(out, &.{ "have ", &hexText(id), "\n" });
    }

    /// A version 2 command's first lines, up to its delimiter.
    fn commandHead(remote: *Remote, out: *_git.Out, command: []const u8) void {
        pktline.putParts(out, &.{ "command=", command, "\n" });
        if (remote.capability("agent") != null) pktline.put(out, "agent=" ++ agent ++ "\n");
        if (remote.capability("object-format") != null) pktline.put(out, "object-format=sha1\n");
        out.put(pktline.delim);
    }

    /// `shallow <id>` and `unshallow <id>` lines up to `end`.
    fn readBoundary(remote: *Remote, want: *const Fetch, end: pktline.Kind) bool {
        while (true) {
            const packet = remote.next() orelse return false;
            if (packet.kind == end) return true;
            if (packet.kind != .data) return remote.fail(.malformed);
            const text = pktline.line(packet.data);
            const shallow = _git.startsWith(text, "shallow ");
            if (!shallow and !_git.startsWith(text, "unshallow ")) return remote.fail(.malformed);
            const id = _git.idOf(text[if (shallow) 8 else 10..]) orelse return remote.fail(.malformed);
            if (want.boundary) |told| {
                if (!told(want.boundary_context, &id, shallow)) return remote.fail(.stopped);
            }
        }
    }

    /// A section not needed, up to its delimiter.
    fn skipSection(remote: *Remote) bool {
        while (true) {
            const packet = remote.next() orelse return false;
            if (packet.kind == .delim) return true;
            if (packet.kind != .data) return remote.fail(.malformed);
        }
    }

    /// `request.updates` sent to receive-pack, with the pack: false,
    /// `failure` set, when the conversation failed, or the server could
    /// not take the pack; otherwise each update has the server's answer.
    pub fn push(remote: *Remote, request: *Push) bool {
        // The rest of the advertisement is not needed.
        while (remote.advertising) {
            const packet = remote.next() orelse return false;
            if (packet.kind == .flush) remote.advertising = false;
        }
        if (request.updates.len == 0) return true;
        if (remote.capability("report-status") == null) return remote.fail(.malformed);
        const band = remote.capability("side-band-64k") != null;
        var words: [128]u8 = undefined;
        var asked: _git.Out = .{ .into = &words };
        asked.put("report-status");
        if (band) asked.put(" side-band-64k");
        if (request.quiet and remote.capability("quiet") != null) asked.put(" quiet");
        if (remote.capability("agent") != null) asked.put(" agent=" ++ agent);
        if (remote.capability("object-format") != null) asked.put(" object-format=sha1");
        var out: _git.Out = .{ .into = &remote.request };
        for (request.updates, 0..) |*update, number| {
            const nul: []const u8 = if (number == 0) "\x00" else "";
            const capabilities: []const u8 = if (number == 0) asked.written() else "";
            pktline.putParts(&out, &.{ &hexText(&update.old), " ", &hexText(&update.new), " ", update.name, nul, capabilities, "\n" });
        }
        out.put(pktline.flush);
        if (out.overflow) return remote.fail(.too_long);

        // The commands and the pack, as one request.
        const link = remote.link;
        remote.reader.dropLeftOver();
        if (!link.begin(link.context, out.at + request.pack.length, remote.version)) return remote.fail(.link);
        if (!link.write(link.context, out.written())) return remote.fail(.link);
        var sent: u64 = 0;
        while (sent < request.pack.length) {
            const got = request.pack.read(request.pack.context, &remote.buffer);
            if (got <= 0) return remote.fail(.source);
            if (!link.write(link.context, remote.buffer[0..@intCast(got)])) return remote.fail(.link);
            sent += @intCast(got);
        }
        if (!link.end(link.context)) return remote.fail(.link);

        // The report: in band 1 gathered, as packets of its own, or the
        // packets themselves.
        var unpacked = false;
        if (band) {
            var length: usize = 0;
            while (true) {
                const packet = remote.next() orelse return false;
                if (packet.kind == .flush) break;
                if (packet.kind != .data or packet.data.len == 0) return remote.fail(.malformed);
                switch (packet.data[0]) {
                    1 => {
                        const data = packet.data[1..];
                        if (length + data.len > remote.request.len) return remote.fail(.malformed);
                        @memcpy(remote.request[length..][0..data.len], data);
                        length += data.len;
                    },
                    2 => {
                        if (remote.listener) |listener| {
                            if (!listener.text(listener.context, packet.data[1..])) return remote.fail(.stopped);
                        }
                    },
                    3 => {
                        remote.setMessage(packet.data[1..]);
                        return remote.fail(.remote);
                    },
                    else => return remote.fail(.malformed),
                }
            }
            var at: usize = 0;
            while (true) {
                if (at + 4 > length) return remote.fail(.malformed);
                const head = pktline.lengthOf(remote.request[at..][0..4]) orelse return remote.fail(.malformed);
                at += 4;
                if (head.kind == .flush) break;
                if (head.kind != .data or at + head.length > length) return remote.fail(.malformed);
                if (!remote.reportLine(request, pktline.line(remote.request[at..][0..head.length]), &unpacked)) return false;
                at += head.length;
            }
        } else {
            while (true) {
                const packet = remote.next() orelse return false;
                if (packet.kind == .flush) break;
                if (packet.kind != .data) return remote.fail(.malformed);
                if (!remote.reportLine(request, pktline.line(packet.data), &unpacked)) return false;
            }
        }
        if (!unpacked) return remote.fail(.unpack);
        for (request.updates) |*update| {
            if (update.status == .waiting) update.refuse("the server did not answer for it");
        }
        return true;
    }

    /// One line of the report taken: `unpack`'s outcome, or a ref's.
    fn reportLine(remote: *Remote, request: *Push, text: []const u8, unpacked: *bool) bool {
        if (_git.startsWith(text, "unpack ")) {
            const outcome = text[7..];
            if (_git.same(outcome, "ok")) {
                unpacked.* = true;
            } else {
                remote.setMessage(outcome);
            }
            return true;
        }
        const done = _git.startsWith(text, "ok ");
        if (!done and !_git.startsWith(text, "ng ")) return remote.fail(.malformed);
        const rest = text[3..];
        var end: usize = 0;
        while (end < rest.len and rest[end] != ' ') end += 1;
        const name = rest[0..end];
        for (request.updates) |*update| {
            if (!_git.same(update.name, name)) continue;
            if (done) {
                update.status = .done;
            } else {
                update.refuse(if (end < rest.len) rest[end + 1 ..] else "");
            }
        }
        return true;
    }

    /// The pack's bytes to `sink`, from side-band packets up to their
    /// flush, or as they come when `band` is false, checked as they go.
    fn receivePack(remote: *Remote, sink: _git.Sink, band: bool) ?receive.Received {
        var receiver = receive.Receiver.start(remote.cb, sink);
        var reported: u64 = 0;
        if (!band) {
            const waiting = remote.reader.leftOver();
            if (!receiver.take(waiting)) return remote.sinkFailed(&receiver);
            remote.reader.dropLeftOver();
        }
        while (true) {
            var data: []const u8 = undefined;
            if (band) {
                const packet = remote.next() orelse return null;
                if (packet.kind == .flush) break;
                if (packet.kind != .data or packet.data.len == 0) {
                    _ = remote.fail(.malformed);
                    return null;
                }
                switch (packet.data[0]) {
                    1 => data = packet.data[1..],
                    2 => {
                        if (remote.listener) |listener| {
                            if (!listener.text(listener.context, packet.data[1..])) {
                                _ = remote.fail(.stopped);
                                return null;
                            }
                        }
                        continue;
                    },
                    3 => {
                        remote.setMessage(packet.data[1..]);
                        _ = remote.fail(.remote);
                        return null;
                    },
                    else => {
                        _ = remote.fail(.malformed);
                        return null;
                    },
                }
            } else {
                const got = remote.link.read(remote.link.context, &remote.buffer);
                if (got < 0) {
                    _ = remote.fail(.link);
                    return null;
                }
                if (got == 0) break;
                data = remote.buffer[0..@intCast(got)];
            }
            if (!receiver.take(data)) return remote.sinkFailed(&receiver);
            if (remote.listener) |listener| {
                if (receiver.total - reported >= 64 * 1024) {
                    reported = receiver.total;
                    if (!listener.received(listener.context, receiver.total)) {
                        _ = remote.fail(.stopped);
                        return null;
                    }
                }
            }
        }
        const received = receiver.finish() orelse {
            _ = remote.fail(if (receiver.sink_failed) .sink else .pack);
            return null;
        };
        if (remote.listener) |listener| _ = listener.received(listener.context, received.bytes);
        return received;
    }

    fn sinkFailed(remote: *Remote, receiver: *const receive.Receiver) ?receive.Received {
        _ = remote.fail(if (receiver.sink_failed) .sink else .pack);
        return null;
    }

    /// The request sent, and the answer's first bytes waited for.
    fn send(remote: *Remote, out: *const _git.Out) bool {
        if (out.overflow) return remote.fail(.too_long);
        remote.reader.dropLeftOver();
        if (!remote.link.exchange(remote.link.context, out.written(), remote.version)) return remote.fail(.link);
        return true;
    }

    /// The next packet; null with `failure` set at the answer's end, a
    /// failure, or an `ERR` line from the server.
    fn next(remote: *Remote) ?pktline.Packet {
        const packet = remote.reader.next() orelse {
            _ = remote.fail(switch (remote.reader.failure) {
                .failed => .link,
                .malformed => .malformed,
                .ended, .none => .ended,
            });
            return null;
        };
        if (packet.kind == .data and _git.startsWith(packet.data, "ERR ")) {
            remote.setMessage(pktline.line(packet.data[4..]));
            _ = remote.fail(.remote);
            return null;
        }
        return packet;
    }

    fn setMessage(remote: *Remote, text: []const u8) void {
        var length: usize = 0;
        for (text) |char| {
            if (length == remote.message.len - 1) break;
            if (char == '\n' or char == '\r') continue;
            remote.message[length] = if (char < ' ' or char == 0x7F) '?' else char;
            length += 1;
        }
        remote.message[length] = 0;
    }

    fn fail(remote: *Remote, failure: Failure) bool {
        if (remote.failure == .none) remote.failure = failure;
        return false;
    }
};

fn prefixed(name: []const u8, prefixes: []const []const u8) bool {
    if (prefixes.len == 0) return true;
    for (prefixes) |prefix| {
        if (_git.startsWith(name, prefix)) return true;
    }
    return false;
}

fn endsWith(text: []const u8, suffix: []const u8) bool {
    return text.len >= suffix.len and _git.same(text[text.len - suffix.len ..], suffix);
}

fn hexText(id: *const Id) [40]u8 {
    var text: [40]u8 = undefined;
    _git.hexOf(id, &text);
    return text;
}

/// `<id> <name>`, a line of version 0's advertisement.
fn parseAdvertised(text: []const u8) ?Ref {
    if (text.len < 42 or text[40] != ' ') return null;
    const id = _git.idOf(text) orelse return null;
    return .{ .id = id, .name = text[41..] };
}

/// `<id> <name>` and its attributes, or `unborn <name>` and its: a line
/// of version 2's `ls-refs` answer.
fn parseListed(text: []const u8) ?Ref {
    var ref: Ref = undefined;
    var at: usize = 0;
    if (_git.startsWith(text, "unborn ")) {
        ref = .{ .id = _git.zero_id, .name = undefined, .unborn = true };
        at = 7;
    } else {
        if (text.len < 42 or text[40] != ' ') return null;
        ref = .{ .id = _git.idOf(text) orelse return null, .name = undefined };
        at = 41;
    }
    var end = at;
    while (end < text.len and text[end] != ' ') end += 1;
    if (end == at) return null;
    ref.name = text[at..end];
    while (end < text.len) {
        at = end + 1;
        end = at;
        while (end < text.len and text[end] != ' ') end += 1;
        const word = text[at..end];
        if (_git.startsWith(word, "symref-target:")) {
            ref.target = word[14..];
        } else if (_git.startsWith(word, "peeled:")) {
            ref.peeled = _git.idOf(word[7..]) orelse return null;
        }
    }
    return ref;
}
