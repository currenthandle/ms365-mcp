// url.zig — URL percent-encoding for query parameters (RFC 3986).

const std = @import("std");

/// URL-encode a string for use in query parameters.
/// Replaces spaces with %20 and other unsafe characters with %XX.
/// Returns an allocated string — caller must free it.
pub fn encode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Count how many bytes we need — each unsafe char becomes 3 bytes (%XX).
    var len: usize = 0;
    for (input) |c| {
        len += if (needsEncoding(c)) @as(usize, 3) else @as(usize, 1);
    }

    const buf = try allocator.alloc(u8, len);
    var i: usize = 0;
    for (input) |c| {
        if (needsEncoding(c)) {
            // Write %XX where XX is the hex representation of the byte.
            buf[i] = '%';
            buf[i + 1] = hexDigit(c >> 4);
            buf[i + 2] = hexDigit(c & 0x0f);
            i += 3;
        } else {
            buf[i] = c;
            i += 1;
        }
    }
    return buf;
}

/// Check if a character needs URL-encoding.
/// Letters, digits, and a few safe punctuation marks can appear as-is.
fn needsEncoding(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => false,
        else => true,
    };
}

/// Convert a 4-bit value (0-15) to its hex character ('0'-'9', 'A'-'F').
fn hexDigit(val: u8) u8 {
    return if (val < 10) '0' + val else 'A' + (val - 10);
}

// --- Tests ---

const testing = std.testing;

test "encode empty string" {
    const result = try encode(testing.allocator, "");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "encode plain alphanumeric" {
    const result = try encode(testing.allocator, "hello123");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello123", result);
}

test "encode spaces" {
    const result = try encode(testing.allocator, "hello world");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello%20world", result);
}

test "encode special characters" {
    const result = try encode(testing.allocator, "a=b&c");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("a%3Db%26c", result);
}

test "encode high bytes (UTF-8)" {
    const result = try encode(testing.allocator, "\xC3\xA9");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("%C3%A9", result);
}

test "encode preserves unreserved chars" {
    const result = try encode(testing.allocator, "a-b_c.d~e");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("a-b_c.d~e", result);
}

test "encode slash and at-sign" {
    const result = try encode(testing.allocator, "/me@host");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("%2Fme%40host", result);
}

test "encode percent character" {
    const result = try encode(testing.allocator, "100%");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("100%25", result);
}
