// types.zig — JSON-RPC and MCP protocol types.
//
// These structs mirror the JSON shapes the MCP protocol expects.
// std.json.Stringify can automatically serialize any Zig struct to JSON,
// so defining these types is all we need — no manual JSON building.

const std = @import("std");

/// A JSON-RPC 2.0 response wrapper. Generic over the result type
/// so we can reuse it for different response shapes.
///
/// This is a "comptime generic" — a function that returns a *type*.
/// In Zig, types are values at compile time. Instead of TypeScript's
/// `JsonRpcResponse<T>`, you write `JsonRpcResponse(InitializeResult)`
/// and Zig generates a struct with that result type baked in.
pub fn JsonRpcResponse(comptime ResultType: type) type {
    return struct {
        jsonrpc: []const u8 = "2.0",
        id: i64,
        result: ResultType,
    };
}

/// The result of an "initialize" response.
/// Tells the client what protocol version we speak and what we can do.
pub const InitializeResult = struct {
    protocolVersion: []const u8 = "2024-11-05",
    capabilities: Capabilities = .{},
    serverInfo: ServerInfo = .{},
};

/// What this server supports. For now, just tools.
pub const Capabilities = struct {
    tools: struct {} = .{}, // empty object — no special tool capabilities
};

/// Identifies this server to the client.
pub const ServerInfo = struct {
    name: []const u8 = "ms-mcp",
    version: []const u8 = "0.1.0",
};

/// The result of a "tools/list" response.
pub const ToolsListResult = struct {
    tools: []const ToolDefinition,
};

/// Describes a single tool the server offers.
/// The client uses this to know what tools are available and how to call them.
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: InputSchema,
};

/// JSON Schema describing what arguments a tool accepts.
pub const InputSchema = struct {
    type: []const u8 = "object",
    properties: struct {} = .{}, // empty for now — tools with no required args
};

/// The result of a "tools/call" response.
/// MCP tool results are a list of content blocks (text, images, etc).
pub const ToolCallResult = struct {
    content: []const TextContent,
};

/// A text content block returned by a tool.
/// The "type" field tells the client how to render it.
pub const TextContent = struct {
    type: []const u8 = "text",
    text: []const u8,
};
