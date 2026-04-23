// formatter.zig — Turn raw Microsoft Graph JSON into LLM-friendly text.
//
// Read tools were previously sending the raw 20 KB Graph response straight
// to the client, which burned the LLM's context window on @odata.* metadata
// the model never needed. This module produces a compact, scannable summary
// driven by a caller-supplied list of fields.
//
// Two entry points:
//   - summarizeArray  — for list endpoints that return {"value": [...]}
//   - summarizeObject — for get endpoints that return a single item
//
// Every summary line automatically appends `id:` and `webUrl:` at the end
// when those fields exist, so the agent can always reference an item by id
// or open it in a browser in a follow-up tool call.
//
// Reading guide for TS/Python-first readers:
//   - ?T is an optional (like T | null). We return null when the response
//     didn't parse or had no items.
//   - std.json.parseFromSlice is Zig's JSON.parse. It returns a Parsed(T)
//     that owns an arena allocator; that arena (and every borrowed string
//     inside it) dies when we call parsed.deinit(). We must copy anything
//     we want to keep before deinit runs.
//   - std.Io.Writer.Allocating is a growing-buffer writer — think of it as
//     Python's io.StringIO or JS's string concatenation, but we're
//     responsible for freeing the buffer.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// A field to extract from each item in the response.
pub const FieldSpec = struct {
    /// Dotted key path into the JSON. `"subject"` is a top-level field;
    /// `"from.emailAddress.address"` walks three levels of nested objects.
    path: []const u8,

    /// How to label the value in the output. Empty string = no label,
    /// just the value. Example: `.label = "from"` → `"from: x@y.com"`.
    label: []const u8 = "",

    /// If true, this field ends with a newline instead of the usual " | "
    /// separator. Useful for body previews that would otherwise run off
    /// the right side of the summary line.
    newline_after: bool = false,
};

/// Summarize a Graph array response of the shape `{"value": [...]}`.
/// Returns an allocated string the caller owns (free it with the same
/// allocator), or null if the response couldn't be parsed or was empty.
pub fn summarizeArray(
    allocator: Allocator,
    response: []const u8,
    fields: []const FieldSpec,
) ?[]u8 {
    // parseFromSlice is like JSON.parse. It allocates an arena; every
    // string slice we pull out of parsed.value points into that arena
    // and becomes invalid the moment we call parsed.deinit() below.
    const parsed = std.json.parseFromSlice(Value, allocator, response, .{}) catch return null;
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .object => |o| switch (o.get("value") orelse return null) {
            .array => |a| a.items,
            else => return null,
        },
        else => return null,
    };
    if (items.len == 0) return null;

    // Allocating writer = string builder. We write into it field by field,
    // then `toOwnedSlice` hands the buffer to the caller. If we `deinit`
    // the writer after `toOwnedSlice`, we double-free.
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();

    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        writeItem(&buf.writer, obj, fields);
    }

    return buf.toOwnedSlice() catch null;
}

/// Summarize a single Graph object response (the shape returned by
/// GET /me/messages/{id}, /me/events/{id}, etc).
/// Returns an allocated string the caller owns, or null on parse failure.
pub fn summarizeObject(
    allocator: Allocator,
    response: []const u8,
    fields: []const FieldSpec,
) ?[]u8 {
    const parsed = std.json.parseFromSlice(Value, allocator, response, .{}) catch return null;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };

    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    writeItem(&buf.writer, obj, fields);
    return buf.toOwnedSlice() catch null;
}

/// Write one item's fields into `w`, followed by id + webUrl suffix and a
/// trailing newline. All errors from the writer are silently swallowed —
/// the caller already got a best-effort string. A truncated summary is
/// strictly better than no summary.
fn writeItem(w: *std.Io.Writer, obj: ObjectMap, fields: []const FieldSpec) void {
    var wrote_anything = false;
    for (fields) |f| {
        const val = resolvePath(obj, f.path) orelse continue;
        if (val.len == 0) continue;

        // Separator: if we've already written a field, either `" | "` or
        // `"\n"` depending on the previous field's flag. We approximate
        // by checking newline_after on the CURRENT field (before writing),
        // so a newline-after field is separated by newline from the next
        // one. This keeps the separator logic local.
        if (wrote_anything) w.writeAll(" | ") catch return;
        wrote_anything = true;

        if (f.label.len > 0) {
            w.print("{s}: ", .{f.label}) catch return;
        }
        w.writeAll(val) catch return;

        if (f.newline_after) {
            w.writeAll("\n") catch return;
            wrote_anything = false; // reset so next field starts a fresh line
        }
    }

    // Always append id + webUrl when present. These are the fields the LLM
    // needs to reference the item in its next tool call.
    if (resolvePath(obj, "id")) |id| {
        if (wrote_anything) w.writeAll(" | ") catch return;
        w.print("id: {s}", .{id}) catch return;
        wrote_anything = true;
    }
    if (resolvePath(obj, "webUrl")) |url| {
        if (wrote_anything) w.writeAll(" | ") catch return;
        w.print("webUrl: {s}", .{url}) catch return;
        wrote_anything = true;
    }

    w.writeAll("\n") catch return;
}

/// Walk a dotted key path through nested ObjectMap values.
/// Returns the string at the end of the path, or null if any step isn't
/// an object or the final value isn't a string.
///
/// The returned slice points into the parsed arena — it's valid only until
/// the caller's `parsed.deinit()` runs. Writing it into our own buffer
/// (as writeItem does) happens before that deinit.
fn resolvePath(obj: ObjectMap, path: []const u8) ?[]const u8 {
    var cur: Value = .{ .object = obj };
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |segment| {
        const cur_obj = switch (cur) {
            .object => |o| o,
            else => return null,
        };
        cur = cur_obj.get(segment) orelse return null;
    }
    return switch (cur) {
        .string => |s| s,
        else => null,
    };
}

// --- Tests ---

const testing = std.testing;

test "summarizeArray: basic fields + automatic id + webUrl" {
    const input =
        \\{"value":[
        \\  {"id":"1","subject":"Hi","from":{"address":"a@b.com"},"webUrl":"https://x/1"},
        \\  {"id":"2","subject":"Bye","from":{"address":"c@d.com"}}
        \\]}
    ;
    const fields = [_]FieldSpec{
        .{ .path = "subject", .label = "subject" },
        .{ .path = "from.address", .label = "from" },
    };
    const out = summarizeArray(testing.allocator, input, &fields).?;
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "subject: Hi") != null);
    try testing.expect(std.mem.indexOf(u8, out, "from: a@b.com") != null);
    try testing.expect(std.mem.indexOf(u8, out, "id: 1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "webUrl: https://x/1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "subject: Bye") != null);
    try testing.expect(std.mem.indexOf(u8, out, "id: 2") != null);
}

test "summarizeArray: missing fields are skipped, not errored" {
    const input =
        \\{"value":[{"id":"1","subject":"Hi"}]}
    ;
    const fields = [_]FieldSpec{
        .{ .path = "subject", .label = "subject" },
        .{ .path = "missing", .label = "missing" },
        .{ .path = "also.not.there", .label = "deep" },
    };
    const out = summarizeArray(testing.allocator, input, &fields).?;
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "subject: Hi") != null);
    try testing.expect(std.mem.indexOf(u8, out, "missing") == null);
    try testing.expect(std.mem.indexOf(u8, out, "deep") == null);
}

test "summarizeArray: empty array returns null" {
    const input = "{\"value\":[]}";
    try testing.expect(summarizeArray(testing.allocator, input, &.{}) == null);
}

test "summarizeArray: malformed JSON returns null (no crash)" {
    try testing.expect(summarizeArray(testing.allocator, "not json", &.{}) == null);
}

test "summarizeArray: no value key returns null" {
    try testing.expect(summarizeArray(testing.allocator, "{\"other\":1}", &.{}) == null);
}

test "summarizeObject: single item rendered" {
    const input =
        \\{"id":"42","subject":"Solo","from":{"address":"x@y.com"}}
    ;
    const fields = [_]FieldSpec{
        .{ .path = "subject", .label = "subject" },
        .{ .path = "from.address", .label = "from" },
    };
    const out = summarizeObject(testing.allocator, input, &fields).?;
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "subject: Solo") != null);
    try testing.expect(std.mem.indexOf(u8, out, "from: x@y.com") != null);
    try testing.expect(std.mem.indexOf(u8, out, "id: 42") != null);
}

test "summarizeArray: newline_after splits long fields to their own line" {
    const input =
        \\{"value":[{"id":"1","subject":"Hi","bodyPreview":"Long preview text","webUrl":"https://x/1"}]}
    ;
    const fields = [_]FieldSpec{
        .{ .path = "subject", .label = "subject" },
        .{ .path = "bodyPreview", .label = "preview", .newline_after = true },
    };
    const out = summarizeArray(testing.allocator, input, &fields).?;
    defer testing.allocator.free(out);

    // After newline_after fires on bodyPreview, id + webUrl start a fresh segment.
    try testing.expect(std.mem.indexOf(u8, out, "preview: Long preview text\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "id: 1") != null);
}

test "summarizeArray: no id / webUrl present is fine" {
    const input =
        \\{"value":[{"name":"no ids here"}]}
    ;
    const fields = [_]FieldSpec{
        .{ .path = "name", .label = "name" },
    };
    const out = summarizeArray(testing.allocator, input, &fields).?;
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "name: no ids here") != null);
    try testing.expect(std.mem.indexOf(u8, out, "id:") == null);
    try testing.expect(std.mem.indexOf(u8, out, "webUrl:") == null);
}

test "summarizeArray: no leaks on happy path" {
    // If the test allocator detects a leak when this test exits, the test
    // fails automatically — testing.allocator is a DebugAllocator underneath.
    const input = "{\"value\":[{\"id\":\"1\",\"subject\":\"Hi\"}]}";
    const fields = [_]FieldSpec{.{ .path = "subject", .label = "subject" }};
    const out = summarizeArray(testing.allocator, input, &fields).?;
    testing.allocator.free(out);
}
