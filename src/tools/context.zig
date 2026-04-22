// tools/context.zig — Shared context and helpers for tool handlers.
//
// Every tool handler takes a single parameter: a `ToolContext`. Think of it
// as a request-scoped dependency injection container (allocator, I/O,
// writer, auth state, parsed JSON-RPC request).
//
// The helpers on ToolContext (requireAuth, getArgs, getStringArg, ...) wrap
// the raw json_rpc and state_mod functions and automatically send an error
// response on the JSON-RPC writer if their precondition fails. A handler
// typically looks like:
//
//     const token = ctx.requireAuth() orelse return;
//     const args  = ctx.getArgs("Missing arguments.") orelse return;
//     const name  = ctx.getStringArg(args, "name", "Missing 'name'.") orelse return;
//     // ...do work, then ctx.sendResult("ok");
//
// Each `orelse return` short-circuits because the helper already wrote an
// error to the client.

const std = @import("std");
const json_rpc = @import("../json_rpc.zig");
const state_mod = @import("../state.zig");
const types = @import("../types.zig");

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

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
    parsed: Value,

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
    pub fn getArgs(self: ToolContext, err_msg: []const u8) ?ObjectMap {
        return json_rpc.getToolArgs(self.parsed) orelse {
            self.sendResult(err_msg);
            return null;
        };
    }

    /// Get a string argument by key, or send an error and return null.
    pub fn getStringArg(self: ToolContext, args: ObjectMap, key: []const u8, err_msg: []const u8) ?[]const u8 {
        return json_rpc.getStringArg(args, key) orelse {
            self.sendResult(err_msg);
            return null;
        };
    }

    /// Get a path-safe argument (rejects /, ?, &, #), or send an error and return null.
    pub fn getPathArg(self: ToolContext, args: ObjectMap, key: []const u8, err_msg: []const u8) ?[]const u8 {
        return json_rpc.getPathArg(args, key) orelse {
            self.sendResult(err_msg);
            return null;
        };
    }

    /// Get the validated "top" pagination parameter (numeric 1-50, default "50").
    pub fn getTopArg(self: ToolContext, args: ObjectMap) []const u8 {
        _ = self;
        return json_rpc.getTopArg(args);
    }

    // --- JSON body helpers ---

    /// If `args` has a string at `key`, copy it into `map` under the same key.
    /// No-op if the arg is missing or not a string. Silently drops allocation
    /// failures — follows the existing `catch return` pattern used in patch builders.
    pub fn putStringIfPresent(
        self: ToolContext,
        map: *ObjectMap,
        args: ObjectMap,
        key: []const u8,
    ) void {
        if (json_rpc.getStringArg(args, key)) |v| {
            map.put(self.allocator, key, .{ .string = v }) catch {};
        }
    }
};
