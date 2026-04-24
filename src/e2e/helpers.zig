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

/// Find an email ID by matching a subject fragment in the formatted
/// list-emails output. Each email is one line of the form:
///   subject: ... | from: ... | received: ... | id: AAA... | webUrl: ...
/// The id value is terminated by the next " | " separator.
pub fn findEmailBySubject(allocator: Allocator, formatted_text: []const u8, subject_fragment: []const u8) ?[]u8 {
    var lines = std.mem.splitScalar(u8, formatted_text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, subject_fragment) == null) continue;
        if (extractIdFromFormattedLine(allocator, line)) |id| return id;
    }
    return null;
}

/// Find a message ID by matching content text in a list-chat-messages
/// response. The response is no longer raw JSON — chat.zig routes it
/// through formatter.summarizeArray, which produces multi-line text like:
///   sent: 2026-01-01T... | from: Alice | body: hello world
///    | id: 173...=
/// The body and id live on the same logical record separated by " | ".
/// A message line in the formatted output is actually two printed lines
/// (body ends with \n because of newline_after), so the id sits on the
/// line immediately after the body content.
pub fn findMessageByContent(allocator: Allocator, formatted_text: []const u8, content_fragment: []const u8) ?[]u8 {
    var lines = std.mem.splitScalar(u8, formatted_text, '\n');
    var body_matched = false;
    while (lines.next()) |line| {
        if (body_matched) {
            if (extractIdFromFormattedLine(allocator, line)) |id| return id;
            body_matched = false;
        }
        if (std.mem.indexOf(u8, line, content_fragment) != null) {
            if (extractIdFromFormattedLine(allocator, line)) |id| return id;
            body_matched = true;
        }
    }
    return null;
}

/// Extract the `id:` value from a formatter line, where the value is
/// terminated by the next " | " separator or end-of-line.
fn extractIdFromFormattedLine(allocator: Allocator, line: []const u8) ?[]u8 {
    const marker = "id: ";
    const start = std.mem.indexOf(u8, line, marker) orelse return null;
    const val_start = start + marker.len;
    const end_sep = std.mem.indexOfPos(u8, line, val_start, " | ") orelse line.len;
    if (val_start >= end_sep) return null;
    return allocator.dupe(u8, line[val_start..end_sep]) catch null;
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

        // Extract the chat ID after "— id: ". Em-dash is 3 UTF-8 bytes;
        // plus space(1) + "id:"(3) + space(1) = 8 total, not 6.
        const marker = "— id: ";
        if (std.mem.indexOf(u8, line, marker)) |id_start| {
            const id = line[id_start + marker.len ..];
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

/// Extract the first message ID from the formatted list-channel-messages
/// output. Skips rows that don't have a `from:` field (those correspond
/// to system/event messages that can't be replied to).
pub fn extractFirstMessageId(allocator: Allocator, formatted_text: []const u8) ?[]u8 {
    var lines = std.mem.splitScalar(u8, formatted_text, '\n');
    var prev_had_from = false;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "from: ") != null) prev_had_from = true;
        if (prev_had_from) {
            if (extractIdFromFormattedLine(allocator, line)) |id| return id;
        }
    }
    return null;
}

/// Read the file at the local_path reported by a binary-download tool
/// (download-sharepoint-file, download-onedrive-file, download-email-
/// attachment). Returns the bytes the tool wrote to disk, so tests can
/// verify the download matches what was uploaded.
pub fn readDownloadedFile(allocator: Allocator, io: std.Io, tool_result: []const u8) ?[]u8 {
    const local_path = extractAfterMarker(allocator, tool_result, "local_path: ") orelse return null;
    defer allocator.free(local_path);
    return std.Io.Dir.readFileAlloc(.cwd(), io, local_path, allocator, .unlimited) catch null;
}

/// Extract a named field from the first row of formatter output.
/// Formatter produces lines like:
///   displayName: ... | webUrl: ... | id: <value>
/// The value is terminated by the next " | " or end-of-line.
///
/// Still works for literal JSON too — falls through to a slow regex-ish
/// "key":"value" scan for callers that haven't migrated to formatter yet.
pub fn extractFirstValueField(allocator: Allocator, text: []const u8, key: []const u8) ?[]u8 {
    // Try formatter format first.
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var marker_buf: [64]u8 = undefined;
        if (key.len + 2 > marker_buf.len) break;
        const marker = std.fmt.bufPrint(&marker_buf, "{s}: ", .{key}) catch break;
        const start = std.mem.indexOf(u8, line, marker) orelse continue;
        const val_start = start + marker.len;
        const val_end = std.mem.indexOfPos(u8, line, val_start, " | ") orelse line.len;
        if (val_start >= val_end) continue;
        return allocator.dupe(u8, line[val_start..val_end]) catch null;
    }
    // Fallback: raw JSON "key":"value".
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, text, needle) orelse return null;
    const val_start = start + needle.len;
    const val_end = std.mem.indexOfPos(u8, text, val_start, "\"") orelse return null;
    if (val_start >= val_end) return null;
    return allocator.dupe(u8, text[val_start..val_end]) catch null;
}
