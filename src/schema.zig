// schema.zig — JSON Schema construction helpers for MCP tool definitions.

const std = @import("std");

/// Build a JSON Schema "property" object: {"type": "...", "description": "..."}
/// We build schemas at runtime (not comptime) because JSON Schema has dynamic
/// structure — different tools have different properties, and std.json.ObjectMap
/// requires heap allocation.
pub fn schemaProperty(prop_type: []const u8, description: []const u8) std.json.Value {
    // Build a JSON object with "type" and "description" keys.
    // We use raw pointers to static strings, so no allocation needed.
    var obj = std.json.ObjectMap.init(std.heap.page_allocator);
    obj.put("type", .{ .string = prop_type }) catch {};
    obj.put("description", .{ .string = description }) catch {};
    return .{ .object = obj };
}

/// Build a JSON Schema object for a tool with no parameters.
/// Returns: {"type": "object"}
pub fn emptySchema() std.json.Value {
    var obj = std.json.ObjectMap.init(std.heap.page_allocator);
    obj.put("type", .{ .string = "object" }) catch {};
    return .{ .object = obj };
}

/// Build a complete JSON Schema object for a tool with parameters.
/// `properties` is an already-built ObjectMap of property names → schema objects.
/// `required` is a list of required property names.
/// Returns: {"type": "object", "properties": {...}, "required": [...]}
pub fn buildSchema(properties: std.json.ObjectMap, required: []const []const u8) std.json.Value {
    var obj = std.json.ObjectMap.init(std.heap.page_allocator);
    obj.put("type", .{ .string = "object" }) catch {};
    obj.put("properties", .{ .object = properties }) catch {};

    // Build the "required" array from the string slice.
    var req_array = std.json.Array.init(std.heap.page_allocator);
    for (required) |name| {
        req_array.append(.{ .string = name }) catch {};
    }
    obj.put("required", .{ .array = req_array }) catch {};

    return .{ .object = obj };
}
