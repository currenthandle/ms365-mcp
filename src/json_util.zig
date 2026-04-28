// json_util.zig — Tiny helpers for pulling fields out of Graph JSON responses.
//
// Three separate tool modules (drafts.zig, sharepoint.zig, ...) had drifted
// into their own copy-pasted variants of "parse this JSON, dig out one
// string field, dupe it into a fresh slice, free the parser arena". This
// module consolidates them.
//
// Reading guide for TS/Python-first readers:
//   - parseFromSlice is like JSON.parse. Its Parsed(T) owns an arena; the
//     arena (and every string slice inside it) dies on parsed.deinit().
//   - We always dupe the string we want to return into the caller's
//     allocator *before* deinit runs, so the caller gets a stable pointer.
//   - Functions return ?[]u8 (owned) so the caller is responsible for
//     freeing the returned slice when done.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Extract the top-level "id" string from a Graph response body.
///
/// Convenience wrapper around `extractString(alloc, json, "id")`. Used
/// after POST create-* calls that return the freshly-created item's JSON.
///
/// Returns an allocated string the caller must free, or null on any parse
/// / shape / missing-field failure.
pub fn extractId(allocator: Allocator, json_text: []const u8) ?[]u8 {
    return extractString(allocator, json_text, "id");
}

/// Extract a top-level string field from a Graph response body.
///
/// Returns an allocated copy the caller owns, or null if the JSON failed
/// to parse, wasn't an object, the key was absent, or the value wasn't a
/// string.
pub fn extractString(allocator: Allocator, json_text: []const u8, key: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const val = obj.get(key) orelse return null;
    const s = switch (val) {
        .string => |str| str,
        else => return null,
    };
    // dupe copies the slice into the caller's allocator. Without this, the
    // returned slice would point into the arena we're about to deinit.
    return allocator.dupe(u8, s) catch null;
}

// --- Tests ---

const testing = std.testing;

test "extractId: happy path" {
    const out = extractId(testing.allocator, "{\"id\":\"abc123\",\"name\":\"x\"}").?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("abc123", out);
}

test "extractId: missing key returns null" {
    try testing.expect(extractId(testing.allocator, "{\"name\":\"x\"}") == null);
}

test "extractId: non-string id returns null" {
    try testing.expect(extractId(testing.allocator, "{\"id\":42}") == null);
}

test "extractId: malformed JSON returns null" {
    try testing.expect(extractId(testing.allocator, "not json") == null);
}

test "extractId: non-object top-level returns null" {
    try testing.expect(extractId(testing.allocator, "[1,2,3]") == null);
}

test "extractString: arbitrary key" {
    const out = extractString(testing.allocator, "{\"name\":\"Hello\"}", "name").?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Hello", out);
}

test "extractString: empty value is allowed" {
    const out = extractString(testing.allocator, "{\"key\":\"\"}", "key").?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}
