// e2e/cases/shared.zig — small helpers used by more than one cases file.
//
// Test-local helpers that only one feature needs live in that feature's
// file. Anything used by 2+ files lives here so the same logic doesn't
// drift between files.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Case-insensitive substring check. Microsoft normalizes email casing
/// in search results so we can't do a byte-exact compare against an
/// .env value the user may have lowercased.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |n_ch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(n_ch)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// Extract a named field value (e.g. "mail: ") from formatter output.
/// Returns the substring between the marker and the next " | " or newline.
pub fn extractFormattedField(allocator: Allocator, text: []const u8, marker: []const u8) ?[]u8 {
    const start = std.mem.indexOf(u8, text, marker) orelse return null;
    const val_start = start + marker.len;
    var end = val_start;
    // Field ends at " | " separator, newline, or end of string.
    while (end < text.len and text[end] != '\n') : (end += 1) {
        if (end + 2 < text.len and text[end] == ' ' and text[end + 1] == '|' and text[end + 2] == ' ') break;
    }
    if (val_start == end) return null;
    return allocator.dupe(u8, text[val_start..end]) catch null;
}
