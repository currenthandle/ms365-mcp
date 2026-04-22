// e2e/helpers.zig — Response-parsing helpers shared across test cases.
//
// Each function reads either a tool-call response body or a Graph API JSON
// blob and extracts a specific field (an id, a message body, etc.).

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Extract a value that appears after a text marker, ending at newline or end of string.
/// e.g. extractAfterMarker("Draft ID: ABC123\n", "Draft ID: ") => "ABC123"
pub fn extractAfterMarker(allocator: Allocator, text: []const u8, marker: []const u8) ?[]u8 {
    const start_idx = std.mem.indexOf(u8, text, marker) orelse return null;
    const val_start = start_idx + marker.len;
    const val_end = std.mem.indexOfPos(u8, text, val_start, "\n") orelse text.len;
    if (val_start >= val_end) return null;
    return allocator.dupe(u8, text[val_start..val_end]) catch return null;
}

/// Find an email ID by matching subject text in a list-emails JSON response.
pub fn findEmailBySubject(allocator: Allocator, json_text: []const u8, subject_fragment: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const values = switch (obj.get("value") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    for (values.items) |item| {
        const email = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const subject = switch (email.get("subject") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.indexOf(u8, subject, subject_fragment) != null) {
            const id = switch (email.get("id") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            return allocator.dupe(u8, id) catch return null;
        }
    }
    return null;
}

/// Find a message ID by matching content text in a list-chat-messages JSON response.
pub fn findMessageByContent(allocator: Allocator, json_text: []const u8, content_fragment: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const values = switch (obj.get("value") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    for (values.items) |item| {
        const msg = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const body = switch (msg.get("body") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const content = switch (body.get("content") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.indexOf(u8, content, content_fragment) != null) {
            const id = switch (msg.get("id") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            return allocator.dupe(u8, id) catch return null;
        }
    }
    return null;
}

/// Find a chat ID by scanning the condensed chat summary for a member name.
/// The summary format is: "[type] topic — Member1, Member2 — id: <chatId>\n"
/// Uses case-insensitive matching. Prefers oneOnOne chats but falls back to any type.
pub fn findChatByMember(allocator: Allocator, summary: []const u8, member_name: []const u8) ?[]u8 {
    // Case-insensitive search: lowercase both the summary and the name.
    var lower_name_buf: [128]u8 = undefined;
    const name_len = @min(member_name.len, lower_name_buf.len);
    for (member_name[0..name_len], 0..) |ch, i| {
        lower_name_buf[i] = std.ascii.toLower(ch);
    }
    const lower_name = lower_name_buf[0..name_len];

    // First pass: look for oneOnOne chats.
    var fallback_id: ?[]u8 = null;
    var lines = std.mem.splitScalar(u8, summary, '\n');
    while (lines.next()) |line| {
        // Case-insensitive line search.
        var lower_line_buf: [2048]u8 = undefined;
        const line_len = @min(line.len, lower_line_buf.len);
        for (line[0..line_len], 0..) |ch, i| {
            lower_line_buf[i] = std.ascii.toLower(ch);
        }
        const lower_line = lower_line_buf[0..line_len];

        if (std.mem.indexOf(u8, lower_line, lower_name) == null) continue;

        // Extract the chat ID after "— id: ".
        if (std.mem.indexOf(u8, line, "— id: ")) |id_start| {
            const id = line[id_start + 6 ..];
            if (id.len == 0) continue;

            if (std.mem.startsWith(u8, line, "[oneOnOne]")) {
                // Preferred: 1:1 chat. Drop any earlier fallback we held.
                if (fallback_id) |f| allocator.free(f);
                return allocator.dupe(u8, id) catch null;
            } else if (fallback_id == null) {
                // Save first non-oneOnOne match as fallback.
                fallback_id = allocator.dupe(u8, id) catch null;
            }
        }
    }
    return fallback_id;
}

/// Extract a top-level string field from a JSON response body string.
pub fn extractJsonString(allocator: Allocator, json_text: []const u8, key: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const val = obj.get(key) orelse return null;
    const str = switch (val) {
        .string => |s| s,
        else => return null,
    };
    return allocator.dupe(u8, str) catch return null;
}

/// Extract the top-level "id" field from a JSON response body string.
/// Parses the JSON properly to avoid matching "parentFolderId" etc.
pub fn extractId(allocator: Allocator, json_text: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const id_val = obj.get("id") orelse return null;
    const id_str = switch (id_val) {
        .string => |s| s,
        else => return null,
    };
    return allocator.dupe(u8, id_str) catch return null;
}

/// Extract the first message ID from a list-channel-messages JSON response.
/// Skips system messages (those without a "from" field).
pub fn extractFirstMessageId(allocator: Allocator, json_text: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const values = switch (obj.get("value") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    // Skip system messages — find first message with a "from" field.
    for (values.items) |item| {
        const msg = switch (item) {
            .object => |o| o,
            else => continue,
        };
        // Skip if no "from" (system event messages).
        const from = msg.get("from") orelse continue;
        if (from == .null) continue;
        const id = switch (msg.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        return allocator.dupe(u8, id) catch return null;
    }
    return null;
}

/// Extract a named string field from the first element of a Graph `value`
/// array. Handy for "give me the id of the first search hit" patterns where
/// the full response is {"value": [{..., "id": "..."}, ...]}.
pub fn extractFirstValueField(allocator: Allocator, json_text: []const u8, key: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const values = switch (obj.get("value") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    if (values.items.len == 0) return null;
    const first = switch (values.items[0]) {
        .object => |o| o,
        else => return null,
    };
    const val = first.get(key) orelse return null;
    const s = switch (val) {
        .string => |str| str,
        else => return null,
    };
    return allocator.dupe(u8, s) catch null;
}
