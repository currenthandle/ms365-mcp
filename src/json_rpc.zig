// json_rpc.zig — Helpers for working with JSON-RPC 2.0 messages.

const std = @import("std");
const types = @import("types.zig");

// Re-export I/O types so other modules can reference them without
// importing std directly for these specific aliases.
pub const Writer = std.Io.Writer;

/// Extract the integer "id" field from a JSON-RPC message object.
/// JSON-RPC clients assign an id to each request so they can match our response.
/// Returns 0 if missing or not an integer.
pub fn getRequestId(value: std.json.Value) i64 {
    // We can only look up "id" if the value is a JSON object.
    const obj = switch (value) {
        .object => |o| o,
        else => return 0,
    };

    const id = obj.get("id") orelse return 0;

    return switch (id) {
        .integer => |n| n,
        else => 0,
    };
}

/// Extract the tool name from a "tools/call" request.
/// In JSON-RPC, tool calls look like: {"params": {"name": "login", ...}}
/// Returns null if missing or malformed.
pub fn getToolName(value: std.json.Value) ?[]const u8 {
    // Same pattern as getRequestId — unwrap one layer at a time.
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    // "params" contains the tool call details.
    const params = switch (obj.get("params") orelse return null) {
        .object => |o| o,
        else => return null,
    };

    // "name" is which tool the client wants to invoke.
    return switch (params.get("name") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Extract the "arguments" object from a "tools/call" request.
/// Tool calls with parameters look like:
///   {"params": {"name": "send-email", "arguments": {"to": "...", "subject": "..."}}}
/// Returns the arguments as a JSON ObjectMap, or null if missing.
pub fn getToolArgs(value: std.json.Value) ?std.json.ObjectMap {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    const params = switch (obj.get("params") orelse return null) {
        .object => |o| o,
        else => return null,
    };

    // "arguments" contains the tool-specific parameters.
    return switch (params.get("arguments") orelse return null) {
        .object => |o| o,
        else => null,
    };
}

/// Helper to extract a string value from a JSON ObjectMap.
/// Returns null if the key is missing or the value isn't a string.
pub fn getStringArg(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = args.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Extract and validate a numeric "top" parameter for pagination.
/// Returns a valid numeric string between 1 and 50, or the default "50".
/// Rejects non-numeric values that could inject OData query parameters.
pub fn getTopArg(args: std.json.ObjectMap) []const u8 {
    const val = getStringArg(args, "top") orelse return "50";
    // Validate it's a pure numeric string.
    for (val) |c| {
        if (c < '0' or c > '9') return "50";
    }
    if (val.len == 0 or val.len > 2) return "50";
    // Parse and clamp to 1-50.
    const n = std.fmt.parseInt(u32, val, 10) catch return "50";
    if (n < 1 or n > 50) return "50";
    return val;
}

/// Extract a string argument that will be used in a Graph API URL path segment.
/// Rejects values containing '/', '?', '&', '#' to prevent path traversal
/// and OData query injection attacks.
pub fn getPathArg(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = getStringArg(args, key) orelse return null;
    for (val) |c| {
        switch (c) {
            '/', '?', '&', '#' => return null,
            else => {},
        }
    }
    return val;
}

/// Serialize any Zig struct as JSON, write it to the writer, then flush.
///
/// This is how we send every response back to the MCP client. Zig's
/// std.json.Stringify can automatically convert any struct to JSON —
/// field names become JSON keys, nested structs become nested objects.
/// No manual format strings or escaped braces needed.
///
/// The writer is buffered, so we must call flush() to actually send
/// the bytes to stdout. The "\n" delimiter tells the client where
/// one message ends and the next begins (newline-delimited JSON).
pub fn sendJsonResponse(writer: *Writer, response: anytype) void {
    std.json.Stringify.value(response, .{}, writer) catch return;
    writer.writeAll("\n") catch return;
    writer.flush() catch return;
}

// --- Tests ---

const testing = std.testing;

/// Parse a JSON string into a Value for testing.
fn parseTestJson(json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
}

test "getRequestId extracts integer id" {
    var parsed = try parseTestJson("{\"id\": 42, \"method\": \"test\"}");
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 42), getRequestId(parsed.value));
}

test "getRequestId missing id returns 0" {
    var parsed = try parseTestJson("{\"method\": \"test\"}");
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 0), getRequestId(parsed.value));
}

test "getRequestId non-object returns 0" {
    try testing.expectEqual(@as(i64, 0), getRequestId(.null));
}

test "getToolName extracts name from params" {
    var parsed = try parseTestJson("{\"params\":{\"name\":\"login\"}}");
    defer parsed.deinit();
    try testing.expectEqualStrings("login", getToolName(parsed.value).?);
}

test "getToolName missing params returns null" {
    var parsed = try parseTestJson("{\"id\":1}");
    defer parsed.deinit();
    try testing.expect(getToolName(parsed.value) == null);
}

test "getToolArgs extracts arguments object" {
    var parsed = try parseTestJson("{\"params\":{\"name\":\"x\",\"arguments\":{\"to\":\"a@b.com\"}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expectEqualStrings("a@b.com", getStringArg(args, "to").?);
}

test "getToolArgs missing arguments returns null" {
    var parsed = try parseTestJson("{\"params\":{\"name\":\"x\"}}");
    defer parsed.deinit();
    try testing.expect(getToolArgs(parsed.value) == null);
}

test "getStringArg extracts string value" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{\"key\":\"val\"}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expectEqualStrings("val", getStringArg(args, "key").?);
}

test "getStringArg non-string returns null" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{\"key\":5}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expect(getStringArg(args, "key") == null);
}

test "getStringArg missing key returns null" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expect(getStringArg(args, "missing") == null);
}

// --- Security: getPathArg tests ---

test "getPathArg accepts valid ID" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{\"id\":\"AAMkAGNjY2ZhNjQ3\"}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expectEqualStrings("AAMkAGNjY2ZhNjQ3", getPathArg(args, "id").?);
}

test "getPathArg accepts GUID" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{\"id\":\"550e8400-e29b-41d4-a716-446655440000\"}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", getPathArg(args, "id").?);
}

test "getPathArg rejects slash (path traversal)" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{\"id\":\"../../admin/users\"}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expect(getPathArg(args, "id") == null);
}

test "getPathArg rejects question mark (query injection)" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{\"id\":\"abc?$select=body\"}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expect(getPathArg(args, "id") == null);
}

test "getPathArg rejects ampersand (query injection)" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{\"id\":\"abc&$top=1000\"}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expect(getPathArg(args, "id") == null);
}

test "getPathArg rejects hash" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{\"id\":\"abc#fragment\"}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expect(getPathArg(args, "id") == null);
}

test "getPathArg missing key returns null" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expect(getPathArg(args, "id") == null);
}

// --- Security: getTopArg tests ---

test "getTopArg valid number" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{\"top\":\"25\"}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expectEqualStrings("25", getTopArg(args));
}

test "getTopArg default when missing" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expectEqualStrings("50", getTopArg(args));
}

test "getTopArg rejects non-numeric (OData injection)" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{\"top\":\"10&$select=body\"}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expectEqualStrings("50", getTopArg(args));
}

test "getTopArg rejects zero" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{\"top\":\"0\"}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expectEqualStrings("50", getTopArg(args));
}

test "getTopArg rejects over 50" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{\"top\":\"999\"}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expectEqualStrings("50", getTopArg(args));
}

test "getTopArg rejects empty string" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{\"top\":\"\"}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expectEqualStrings("50", getTopArg(args));
}

test "getTopArg rejects negative" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{\"top\":\"-1\"}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expectEqualStrings("50", getTopArg(args));
}

test "getTopArg accepts boundary value 1" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{\"top\":\"1\"}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expectEqualStrings("1", getTopArg(args));
}

test "getTopArg accepts boundary value 50" {
    var parsed = try parseTestJson("{\"params\":{\"arguments\":{\"top\":\"50\"}}}");
    defer parsed.deinit();
    const args = getToolArgs(parsed.value).?;
    try testing.expectEqualStrings("50", getTopArg(args));
}
