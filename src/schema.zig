// schema.zig — JSON Schema construction helpers for MCP tool definitions.

const std = @import("std");

const page = std.heap.page_allocator;

pub fn schemaProperty(prop_type: []const u8, description: []const u8) std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    obj.put(page, "type", .{ .string = prop_type }) catch {};
    obj.put(page, "description", .{ .string = description }) catch {};
    return .{ .object = obj };
}

pub fn emptySchema() std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    obj.put(page, "type", .{ .string = "object" }) catch {};
    return .{ .object = obj };
}

pub fn buildSchema(properties: std.json.ObjectMap, required: []const []const u8) std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    obj.put(page, "type", .{ .string = "object" }) catch {};
    obj.put(page, "properties", .{ .object = properties }) catch {};

    var req_array = std.json.Array.init(page);
    for (required) |name| {
        req_array.append(.{ .string = name }) catch {};
    }
    obj.put(page, "required", .{ .array = req_array }) catch {};

    return .{ .object = obj };
}

// --- Tests ---

const testing = std.testing;

test "schemaProperty creates type and description" {
    const prop = schemaProperty("string", "A name");
    const obj = prop.object;
    try testing.expectEqualStrings("string", obj.get("type").?.string);
    try testing.expectEqualStrings("A name", obj.get("description").?.string);
}

test "emptySchema creates object type" {
    const s = emptySchema();
    try testing.expectEqualStrings("object", s.object.get("type").?.string);
}

test "buildSchema includes properties and required" {
    var props: std.json.ObjectMap = .empty;
    props.put(page, "to", schemaProperty("string", "Recipient")) catch {};
    const s = buildSchema(props, &.{"to"});
    const obj = s.object;
    try testing.expectEqualStrings("object", obj.get("type").?.string);
    try testing.expect(obj.get("properties") != null);
    const req = obj.get("required").?.array;
    try testing.expectEqual(@as(usize, 1), req.items.len);
    try testing.expectEqualStrings("to", req.items[0].string);
}

test "buildSchema empty required array" {
    const props: std.json.ObjectMap = .empty;
    const s = buildSchema(props, &.{});
    const req = s.object.get("required").?.array;
    try testing.expectEqual(@as(usize, 0), req.items.len);
}
