# Compression

`compression.library`, in `LIBS:`, packs bytes with DEFLATE (RFC 1951)
and unpacks them: bare, in a zlib wrapping (RFC 1950: two bytes in front,
an Adler-32 behind) or in a gzip one (RFC 1952: a header, a CRC-32 and
the length behind). It is what a PNG's picture, a `.gz` file, a git
object or an HTTP body sent `gzip` is packed with. icon.library and
png.datatype unpack their PNGs with it, and `C:ScreenDump` packs its
pictures.

This guide is the stream first, then unpacking, packing, the calls that
do either in one go, and the checksums.

## A stream

Everything goes through a `compression.Stream`, which is the caller's:

```zig
const compression = sdk.compression;
var stream: compression.Stream = .{};   // .{} fills in its size
stream.next_in = input.ptr;
stream.avail_in = @intCast(input.len);
stream.next_out = output.ptr;
stream.avail_out = @intCast(output.len);
```

Before each call the program says where the next input is and how much
of it there is, where the output goes and how much room there is; the
library moves the four on by what it took and wrote. `total_in` and
`total_out` count every byte since the Init call. What the library keeps
between calls - the window of what came last, the block's codes - hangs
off `state` from the Init call to the End call.

The library has one base for every opener. Any number of streams may be
under way at once, on any number of tasks, each in its own Stream.

| Result | What it means |
|---|---|
| `COMPRESS_OK` | work done, or nothing more until there is more input or more room |
| `COMPRESS_END` | the stream's end: Inflate has read it, Deflate has written all of it |
| `COMPRESSERR_DATA` | no stream of the format: a bad header, a code there is not, a repeat from before the start, a checksum that does not match |
| `COMPRESSERR_MEMORY` | the state's memory could not be had |
| `COMPRESSERR_BUFFER` | Uncompress, Compress: the output did not hold it all |
| `COMPRESSERR_STREAM` | a stream not set up for the call, an argument out of range |
| `COMPRESSERR_TRUNCATED` | the input ended before the stream did, with `FLUSH_FINISH` or in Uncompress |

## Unpacking

`InitInflate` takes the format: `FORMAT_RAW`, `FORMAT_ZLIB`,
`FORMAT_GZIP`, or `FORMAT_AUTO`, which tells zlib from gzip by the first
two bytes and puts what it found in `stream.format`. `Inflate` then
unpacks as much as the input and the room allow, and `EndInflate` frees
the state. A `.gz` file into another file, a buffer at a time:

```zig
const cb: *CompressionBase = @ptrCast(sys.OpenLibrary(compression.COMPRESSIONNAME, 1) orelse return);
defer sys.CloseLibrary(cb.lib());

var stream: compression.Stream = .{};
if (cb.InitInflate(&stream, compression.FORMAT_GZIP) != compression.COMPRESS_OK) return;
defer cb.EndInflate(&stream);
var in: [8192]u8 = undefined;
var out: [16384]u8 = undefined;
while (true) {
    if (stream.avail_in == 0) {
        const got = dl.Read(from, &in, @intCast(in.len));
        if (got < 0) return;
        stream.next_in = &in;
        stream.avail_in = @intCast(got);
    }
    stream.next_out = &out;
    stream.avail_out = out.len;
    const result = cb.Inflate(&stream, if (stream.avail_in == 0) compression.FLUSH_FINISH else compression.FLUSH_NONE);
    const made: isize = @intCast(out.len - stream.avail_out);
    if (made != 0 and dl.Write(to, &out, made) != made) return;
    if (result == compression.COMPRESS_END) break;
    if (result != compression.COMPRESS_OK) return; // broken, or cut short
}
```

Inflate writes straight into the caller's output and stops anywhere -
a bit into a code, in the middle of a repeat - to go on with the next
call. `FLUSH_FINISH` says no more input comes, so a stream that has not
ended once the input is used up is `COMPRESSERR_TRUNCATED`; with
`FLUSH_NONE` it is `COMPRESS_OK`, waiting for more.

Nothing past the stream's end is read: at `COMPRESS_END`, `next_in`
points at the first byte after it and `total_in` is the stream's length.
That is how a reader of streams one after another - the entries of a git
pack, a zip file - finds where the next one starts.

The state is about 10 KiB. The 32 KiB window, which a repeat in a later
call may reach back into, is allocated by the first call that ends with
the stream still open; a stream unpacked in one call never has one.

## Packing

`InitDeflate` takes the format - `FORMAT_RAW`, `FORMAT_ZLIB` or
`FORMAT_GZIP` - and the level: `LEVEL_STORE` (0) stores the bytes as
they are, `LEVEL_FAST` (1) is the quickest, `LEVEL_DEFAULT` (6) the usual
choice, `LEVEL_BEST` (9) the smallest. `Deflate` takes input and writes
output; the third argument says what to do with what it has:

- `FLUSH_NONE`: as much as suits it. Deflate may hold input back to make
  a better block.
- `FLUSH_SYNC`: everything given so far out, ending on a byte, so the
  other end can unpack all of it now; the stream goes on. For a
  connection that sends as it goes.
- `FLUSH_FINISH`: no more input. Deflate ends the stream and answers
  `COMPRESS_END` once all of it is written; until then `COMPRESS_OK`,
  for more room.

```zig
var stream: compression.Stream = .{ .next_in = data.ptr, .avail_in = @intCast(data.len) };
if (cb.InitDeflate(&stream, compression.FORMAT_ZLIB, compression.LEVEL_DEFAULT) != compression.COMPRESS_OK) return;
defer cb.EndDeflate(&stream);
var out: [32768]u8 = undefined;
while (true) {
    stream.next_out = &out;
    stream.avail_out = out.len;
    const result = cb.Deflate(&stream, compression.FLUSH_FINISH);
    const made: isize = @intCast(out.len - stream.avail_out);
    if (made != 0 and dl.Write(to, &out, made) != made) return;
    if (result == compression.COMPRESS_END) break;
    if (result != compression.COMPRESS_OK) return;
}
```

Each block is written stored, with the fixed codes or with its own,
whichever comes out smallest, so bytes that do not pack - a picture
already packed, noise - grow by five bytes in each 16 KiB. A packing
stream's state is about 320 KiB: its window, the chains of where each
three bytes were last seen, the symbols of the block being gathered, the
codes it is written with and the output not yet taken. A call itself
needs little of the caller's stack.

## In one go

When the whole input is at hand and the output's size is known, one
call does the lot:

```zig
var stream: compression.Stream = .{
    .next_in = packed_bytes.ptr, .avail_in = @intCast(packed_bytes.len),
    .next_out = into.ptr, .avail_out = @intCast(into.len),
};
switch (cb.Uncompress(&stream, compression.FORMAT_AUTO)) {
    compression.COMPRESS_OK => {}, // stream.total_out bytes in `into`
    compression.COMPRESSERR_BUFFER => {}, // `into` too small
    else => {}, // broken, or cut short
}
```

`Uncompress` answers `COMPRESS_OK` for a whole stream that fitted, and
leaves `next_in` past its end as Inflate does. `Compress` packs the same
way, given the format and level; room of `CompressBound(format, length)`
always holds what it makes.

## Checksums

`Crc32` (gzip's, PNG's and zip's) and `Adler32` (zlib's) carry a sum on
over another run of bytes. A sum starts from 0 for CRC-32 and from 1
for Adler-32:

```zig
var crc: u32 = 0;
crc = cb.Crc32(crc, first.ptr, @intCast(first.len));
crc = cb.Crc32(crc, rest.ptr, @intCast(rest.len)); // the same as over both at once
```
