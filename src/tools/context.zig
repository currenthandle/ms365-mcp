// tools/context.zig — Shared context and helpers for tool handlers.

const std = @import("std");
const json_rpc = @import("../json_rpc.zig");
const state_mod = @import("../state.zig");
const types = @import("../types.zig");

/// Bundles everything a tool handler needs into one struct.
/// Constructed once per tools/call in main.zig's message loop.
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *json_rpc.Writer,
    state: *state_mod.State,
    client_id: []const u8,
    tenant_id: []const u8,
    /// Borrows data from main.zig's message loop — valid for one handler call only.
    parsed: std.json.Value,

    // --- Response helpers ---

    /// Send a text result back to the MCP client.
    pub fn sendResult(self: ToolContext, text: []const u8) void {
        const content: []const types.TextContent = &.{.{ .text = text }};
        json_rpc.sendJsonResponse(self.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = self.requestId(),
            .result = .{ .content = content },
        });
    }

    /// Get the JSON-RPC request ID.
    pub fn requestId(self: ToolContext) i64 {
        return json_rpc.getRequestId(self.parsed);
    }

    // --- Auth helper ---

    /// Check login, refresh if needed. Returns access token or sends error and returns null.
    pub fn requireAuth(self: ToolContext) ?[]const u8 {
        return state_mod.requireAuth(
            self.state, self.allocator, self.io,
            self.client_id, self.tenant_id,
            self.writer, self.requestId(),
        );
    }

    // --- Argument helpers ---

    /// Get the tool arguments object, or send an error and return null.
    pub fn getArgs(self: ToolContext, err_msg: []const u8) ?std.json.ObjectMap {
        return json_rpc.getToolArgs(self.parsed) orelse {
            self.sendResult(err_msg);
            return null;
        };
    }

    /// Get a string argument by key, or send an error and return null.
    pub fn getStringArg(self: ToolContext, args: std.json.ObjectMap, key: []const u8, err_msg: []const u8) ?[]const u8 {
        return json_rpc.getStringArg(args, key) orelse {
            self.sendResult(err_msg);
            return null;
        };
    }

    /// Get a path-safe argument (rejects /, ?, &, #), or send an error and return null.
    pub fn getPathArg(self: ToolContext, args: std.json.ObjectMap, key: []const u8, err_msg: []const u8) ?[]const u8 {
        return json_rpc.getPathArg(args, key) orelse {
            self.sendResult(err_msg);
            return null;
        };
    }

    /// Get the validated "top" pagination parameter (numeric 1-50, default "50").
    pub fn getTopArg(self: ToolContext, args: std.json.ObjectMap) []const u8 {
        _ = self;
        return json_rpc.getTopArg(args);
    }
};
