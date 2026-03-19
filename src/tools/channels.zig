// tools/channels.zig — Teams channel tools (teams, channels, channel messages).
//
// Teams chats (1:1 and group) live under /me/chats.
// Channel conversations live under /teams/{id}/channels/{id}/messages —
// a completely separate API surface. These tools bridge that gap.

const std = @import("std");
const types = @import("../types.zig");
const graph = @import("../graph.zig");
const json_rpc = @import("../json_rpc.zig");
const state_mod = @import("../state.zig");
const ToolContext = @import("context.zig").ToolContext;

/// List the Teams the user has joined.
/// Calls GET /me/joinedTeams and returns a condensed summary.
pub fn handleListTeams(ctx: ToolContext) void {
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    const response_body = graph.get(
        ctx.allocator, ctx.io, token,
        "/me/joinedTeams?$select=id,displayName,description",
    ) catch |err| {
        std.debug.print("ms-mcp: list-teams failed: {}\n", .{err});
        sendToolError(ctx, "Failed to fetch teams.");
        return;
    };
    defer ctx.allocator.free(response_body);

    // Parse and build a condensed summary: one line per team.
    const parsed = std.json.parseFromSlice(
        std.json.Value, ctx.allocator, response_body, .{},
    ) catch {
        sendToolResult(ctx, response_body);
        return;
    };
    defer parsed.deinit();

    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer buf.deinit();
    const w = &buf.writer;

    const items = getValueArray(parsed.value) orelse {
        sendToolResult(ctx, "No teams found.");
        return;
    };

    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = getStr(obj, "displayName") orelse "(unnamed)";
        const id = getStr(obj, "id") orelse continue;
        const desc = getStr(obj, "description") orelse "";

        if (desc.len > 0) {
            w.print("{s} — {s} — id: {s}\n", .{ name, desc, id }) catch continue;
        } else {
            w.print("{s} — id: {s}\n", .{ name, id }) catch continue;
        }
    }

    const summary = buf.written();
    sendToolResult(ctx, if (summary.len > 0) summary else "No teams found.");
}

/// List channels in a Team.
/// Calls GET /teams/{teamId}/channels and returns a condensed summary.
pub fn handleListChannels(ctx: ToolContext) void {
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        sendToolError(ctx, "Missing arguments. Provide teamId.");
        return;
    };
    const team_id = json_rpc.getStringArg(args, "teamId") orelse {
        sendToolError(ctx, "Missing 'teamId' argument. Use list-teams to find it.");
        return;
    };

    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/teams/{s}/channels?$select=id,displayName,description",
        .{team_id},
    ) catch return;
    defer ctx.allocator.free(path);

    const response_body = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        std.debug.print("ms-mcp: list-channels failed: {}\n", .{err});
        sendToolError(ctx, "Failed to fetch channels.");
        return;
    };
    defer ctx.allocator.free(response_body);

    // Parse and build a condensed summary.
    const parsed = std.json.parseFromSlice(
        std.json.Value, ctx.allocator, response_body, .{},
    ) catch {
        sendToolResult(ctx, response_body);
        return;
    };
    defer parsed.deinit();

    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer buf.deinit();
    const w = &buf.writer;

    const items = getValueArray(parsed.value) orelse {
        sendToolResult(ctx, "No channels found.");
        return;
    };

    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = getStr(obj, "displayName") orelse "(unnamed)";
        const id = getStr(obj, "id") orelse continue;
        const desc = getStr(obj, "description") orelse "";

        if (desc.len > 0) {
            w.print("{s} — {s} — id: {s}\n", .{ name, desc, id }) catch continue;
        } else {
            w.print("{s} — id: {s}\n", .{ name, id }) catch continue;
        }
    }

    const summary = buf.written();
    sendToolResult(ctx, if (summary.len > 0) summary else "No channels found.");
}

/// List messages (posts) in a Teams channel.
/// Calls GET /teams/{teamId}/channels/{channelId}/messages.
pub fn handleListChannelMessages(ctx: ToolContext) void {
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        sendToolError(ctx, "Missing arguments. Provide teamId and channelId.");
        return;
    };
    const team_id = json_rpc.getStringArg(args, "teamId") orelse {
        sendToolError(ctx, "Missing 'teamId' argument. Use list-teams to find it.");
        return;
    };
    const channel_id = json_rpc.getStringArg(args, "channelId") orelse {
        sendToolError(ctx, "Missing 'channelId' argument. Use list-channels to find it.");
        return;
    };

    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/teams/{s}/channels/{s}/messages?$top=20",
        .{ team_id, channel_id },
    ) catch return;
    defer ctx.allocator.free(path);

    const response_body = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        std.debug.print("ms-mcp: list-channel-messages failed: {}\n", .{err});
        sendToolError(ctx, "Failed to fetch channel messages.");
        return;
    };
    defer ctx.allocator.free(response_body);

    // Return raw JSON — the LLM will summarize it.
    sendToolResult(ctx, response_body);
}

/// Get replies to a specific message (thread) in a Teams channel.
/// Calls GET /teams/{teamId}/channels/{channelId}/messages/{messageId}/replies.
pub fn handleGetChannelMessageReplies(ctx: ToolContext) void {
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        sendToolError(ctx, "Missing arguments. Provide teamId, channelId, and messageId.");
        return;
    };
    const team_id = json_rpc.getStringArg(args, "teamId") orelse {
        sendToolError(ctx, "Missing 'teamId' argument.");
        return;
    };
    const channel_id = json_rpc.getStringArg(args, "channelId") orelse {
        sendToolError(ctx, "Missing 'channelId' argument.");
        return;
    };
    const message_id = json_rpc.getStringArg(args, "messageId") orelse {
        sendToolError(ctx, "Missing 'messageId' argument. Use list-channel-messages to find it.");
        return;
    };

    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/teams/{s}/channels/{s}/messages/{s}/replies?$top=50",
        .{ team_id, channel_id, message_id },
    ) catch return;
    defer ctx.allocator.free(path);

    const response_body = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        std.debug.print("ms-mcp: get-channel-message-replies failed: {}\n", .{err});
        sendToolError(ctx, "Failed to fetch message replies.");
        return;
    };
    defer ctx.allocator.free(response_body);

    // Return raw JSON — the LLM will summarize it.
    sendToolResult(ctx, response_body);
}

/// Reply to a message thread in a Teams channel.
/// Calls POST /teams/{teamId}/channels/{channelId}/messages/{messageId}/replies.
pub fn handleReplyToChannelMessage(ctx: ToolContext) void {
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        sendToolError(ctx, "Missing arguments. Provide teamId, channelId, messageId, and message.");
        return;
    };
    const team_id = json_rpc.getStringArg(args, "teamId") orelse {
        sendToolError(ctx, "Missing 'teamId' argument.");
        return;
    };
    const channel_id = json_rpc.getStringArg(args, "channelId") orelse {
        sendToolError(ctx, "Missing 'channelId' argument.");
        return;
    };
    const message_id = json_rpc.getStringArg(args, "messageId") orelse {
        sendToolError(ctx, "Missing 'messageId' argument.");
        return;
    };
    const message = json_rpc.getStringArg(args, "message") orelse {
        sendToolError(ctx, "Missing 'message' argument.");
        return;
    };

    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/teams/{s}/channels/{s}/messages/{s}/replies",
        .{ team_id, channel_id, message_id },
    ) catch return;
    defer ctx.allocator.free(path);

    // Build the JSON body — same shape as chat messages.
    const body = types.ChatMessageRequest{
        .body = .{ .content = message },
    };
    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(body, .{}, &json_buf.writer) catch return;

    _ = graph.post(ctx.allocator, ctx.io, token, path, json_buf.written()) catch |err| {
        std.debug.print("ms-mcp: reply-to-channel-message failed: {}\n", .{err});
        sendToolError(ctx, "Failed to send reply.");
        return;
    };

    sendToolResult(ctx, "Reply sent.");
}

// ---------------------------------------------------------------
// Helpers — reduce boilerplate for common response patterns.
// ---------------------------------------------------------------

/// Extract the "value" array from a Graph API response object.
fn getValueArray(value: std.json.Value) ?[]std.json.Value {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get("value") orelse return null) {
        .array => |a| a.items,
        else => null,
    };
}

/// Get a string field from a JSON object.
fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Send a simple text result back to the MCP client.
fn sendToolResult(ctx: ToolContext, text: []const u8) void {
    const content: []const types.TextContent = &.{
        .{ .text = text },
    };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = .{ .content = content },
    });
}

/// Send an error text result back to the MCP client.
fn sendToolError(ctx: ToolContext, text: []const u8) void {
    sendToolResult(ctx, text);
}
