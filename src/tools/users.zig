// tools/users.zig — User lookup and profile tools.

const std = @import("std");
const types = @import("../types.zig");
const graph = @import("../graph.zig");
const json_rpc = @import("../json_rpc.zig");
const state_mod = @import("../state.zig");
const url = @import("../url.zig");
const ToolContext = @import("context.zig").ToolContext;

/// Search for people in the Microsoft 365 organization by name.
pub fn handleSearchUsers(ctx: ToolContext) void {
    // Check that the user is logged in.
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    // Get tool arguments — query is required.
    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing arguments. Provide query (name to search for)." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // "query" — the person's name to search for.
    const query = json_rpc.getStringArg(args, "query") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'query' argument." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // URL-encode the query so spaces and special characters
    // don't break the URL. e.g. "Berry Cheung" → "Berry%20Cheung".
    const encoded_query = url.encode(ctx.allocator, query) catch return;
    defer ctx.allocator.free(encoded_query);

    // Build the path: /me/people?$search=%22query%22&$top=5&$select=...
    // The People API searches contacts and colleagues by name.
    // $search requires quotes around the query string.
    // %22 is the URL-encoded double-quote — $search requires
    // quoted strings per the Graph API spec.
    // scoredEmailAddresses contains the person's email(s).
    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/me/people?$search=%22{s}%22&$top=5&$select=displayName,scoredEmailAddresses,userPrincipalName",
        .{encoded_query},
    ) catch return;
    defer ctx.allocator.free(path);

    // GET the search results.
    const response_body = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        std.debug.print("ms-mcp: search-users failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to search users." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };
    defer ctx.allocator.free(response_body);

    // Return raw JSON — small response, LLM can pick the right person.
    const content: []const types.TextContent = &.{
        .{ .text = response_body },
    };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = .{ .content = content },
    });
}

/// Get the logged-in user's Microsoft 365 profile.
pub fn handleGetProfile(ctx: ToolContext) void {
    // Check that the user is logged in.
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    // GET /me — returns the logged-in user's profile.
    // $select limits to just the fields we care about.
    const response_body = graph.get(
        ctx.allocator, ctx.io, token,
        "/me?$select=id,displayName,mail,userPrincipalName",
    ) catch |err| {
        std.debug.print("ms-mcp: get-profile failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to fetch profile." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    defer ctx.allocator.free(response_body);

    // Return raw JSON — it's small, just a few fields.
    const content: []const types.TextContent = &.{
        .{ .text = response_body },
    };
    const result = types.ToolCallResult{ .content = content };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = result,
    });
}
