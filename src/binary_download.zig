// binary_download.zig — Persist Graph binary payloads to disk safely.
//
// Why this exists: MCP tool results are UTF-8 text. Stuffing raw binary
// bytes (a PDF, a MOV, a PNG) into a text result corrupts JSON-RPC framing
// on any byte that isn't valid UTF-8, and blows out the LLM's context
// window on anything larger than a few KB. Instead we write the bytes to
// a fresh temp file and hand the path back to the LLM — its next tool
// call can read the file locally, stream it elsewhere, or display it.
//
// Reading guide for TS/Python-first readers:
//   - std.c.getpid is the POSIX getpid(2). Called once so each server
//     process gets a unique prefix (avoids colliding with a second server
//     instance running in the same /tmp).
//   - std.time.nanoTimestamp returns an i128 — nanoseconds since epoch.
//     We use it to make each call within this process get a unique dir.
//   - std.Io.Dir.cwd() is like Python's os.getcwd() wrapped as a Dir
//     handle. createDirPath on cwd with an absolute sub_path is the Zig
//     0.16 way to `mkdir -p /tmp/whatever`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Parent temp directory under which every download gets its own subdir.
/// macOS and Linux agree /tmp exists; Windows support is out of scope.
const temp_parent = "/tmp";

/// Write `bytes` to a fresh temp file and return its absolute path.
///
/// The returned path is an allocated []u8 — caller owns it and must free.
/// The file itself is NOT auto-deleted. The LLM's next tool call may be
/// "read this PDF", so the file must outlive this call. Cleanup is left
/// to the OS at reboot or to a future `cleanup-temp-files` tool.
///
/// Directory layout:
///   /tmp/ms-mcp-<pid>-<nanotime>/<sanitized-name>
///
/// `suggested_name` is sanitized (slashes, backslashes, and NULs stripped)
/// so a name like "../../etc/passwd" can't escape the fresh directory.
pub fn saveToTempFile(
    allocator: Allocator,
    io: Io,
    suggested_name: []const u8,
    bytes: []const u8,
) ![]u8 {
    const pid = std.c.getpid();
    const now: i128 = std.time.nanoTimestamp();

    // Build the per-call directory path, e.g. "/tmp/ms-mcp-12345-1729876543210000000".
    const dir_path = try std.fmt.allocPrint(
        allocator,
        "{s}/ms-mcp-{d}-{d}",
        .{ temp_parent, pid, now },
    );
    defer allocator.free(dir_path);

    // createDirPath is `mkdir -p` in shell, or os.makedirs(..., exist_ok=True)
    // in Python. It succeeds even if the directory already exists.
    try std.Io.Dir.cwd().createDirPath(io, dir_path);

    // Sanitize the file name into a stack buffer. 128 bytes is plenty for
    // any display name Graph hands us; longer names get silently trimmed.
    var name_buf: [128]u8 = undefined;
    const safe_name = sanitizeName(&name_buf, suggested_name);

    const full_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ dir_path, safe_name },
    );
    errdefer allocator.free(full_path);

    // writeFile is a one-shot open-write-close. Same as Node's
    // fs.writeFileSync or Python's open().write().
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = full_path,
        .data = bytes,
    });

    return full_path;
}

/// Strip any byte that could let a caller-supplied name escape the per-call
/// directory (slashes, backslashes, NULs) and cap the result at buf.len - 1.
///
/// If the input is empty (or consists entirely of stripped characters),
/// returns the literal "download.bin" written into `buf`.
fn sanitizeName(buf: []u8, name: []const u8) []const u8 {
    var out_i: usize = 0;
    for (name) |c| {
        if (out_i >= buf.len - 1) break;
        if (c == '/' or c == '\\' or c == 0) continue;
        buf[out_i] = c;
        out_i += 1;
    }
    if (out_i == 0) {
        const fallback = "download.bin";
        @memcpy(buf[0..fallback.len], fallback);
        return buf[0..fallback.len];
    }
    return buf[0..out_i];
}

// --- Tests ---

const testing = std.testing;

test "sanitizeName: plain name passes through" {
    var buf: [64]u8 = undefined;
    const out = sanitizeName(&buf, "report.pdf");
    try testing.expectEqualStrings("report.pdf", out);
}

test "sanitizeName: strips forward slashes" {
    var buf: [64]u8 = undefined;
    const out = sanitizeName(&buf, "../../etc/passwd");
    // '.', '.', '.', '.', 'e', 't', 'c', 'p', 'a', 's', 's', 'w', 'd'
    try testing.expectEqualStrings("....etcpasswd", out);
}

test "sanitizeName: strips backslashes" {
    var buf: [64]u8 = undefined;
    const out = sanitizeName(&buf, "a\\b\\c.txt");
    try testing.expectEqualStrings("abc.txt", out);
}

test "sanitizeName: strips null bytes" {
    var buf: [64]u8 = undefined;
    const out = sanitizeName(&buf, "ok\x00file.bin");
    try testing.expectEqualStrings("okfile.bin", out);
}

test "sanitizeName: empty input falls back to download.bin" {
    var buf: [64]u8 = undefined;
    const out = sanitizeName(&buf, "");
    try testing.expectEqualStrings("download.bin", out);
}

test "sanitizeName: all-slashes input falls back to download.bin" {
    var buf: [64]u8 = undefined;
    const out = sanitizeName(&buf, "////");
    try testing.expectEqualStrings("download.bin", out);
}

test "sanitizeName: long name truncates at buffer - 1" {
    var buf: [10]u8 = undefined;
    const out = sanitizeName(&buf, "abcdefghijklmnop");
    try testing.expectEqual(@as(usize, 9), out.len);
    try testing.expectEqualStrings("abcdefghi", out);
}
