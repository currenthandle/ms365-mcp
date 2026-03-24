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
/// Supports pagination via pageToken (the @odata.nextLink from a previous response).
/// Calls GET /teams/{teamId}/channels/{channelId}/messages.
pub fn handleListChannelMessages(ctx: ToolContext) void {
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        sendToolError(ctx, "Missing arguments. Provide teamId and channelId.");
        return;
    };

    // If pageToken is provided, use it directly as the full URL path.
    const page_token = json_rpc.getStringArg(args, "pageToken");
    const path = if (page_token) |pt| blk: {
        break :blk graph.stripGraphPrefix(pt) orelse {
            sendToolError(ctx, "Invalid pageToken — must be a Graph API URL.");
            return;
        };
    } else blk: {
        const team_id = json_rpc.getStringArg(args, "teamId") orelse {
            sendToolError(ctx, "Missing 'teamId' argument. Use list-teams to find it.");
            return;
        };
        const channel_id = json_rpc.getStringArg(args, "channelId") orelse {
            sendToolError(ctx, "Missing 'channelId' argument. Use list-channels to find it.");
            return;
        };

        // Default to 50 messages per page (Graph API max for channel messages).
        const top = json_rpc.getStringArg(args, "top") orelse "50";

        break :blk std.fmt.allocPrint(
            ctx.allocator,
            "/teams/{s}/channels/{s}/messages?$top={s}",
            .{ team_id, channel_id, top },
        ) catch return;
    };
    defer if (page_token == null) ctx.allocator.free(path);

    const response_body = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        std.debug.print("ms-mcp: list-channel-messages failed: {}\n", .{err});
        sendToolError(ctx, "Failed to fetch channel messages.");
        return;
    };
    defer ctx.allocator.free(response_body);

    // Return raw JSON — includes @odata.nextLink for pagination.
    sendToolResult(ctx, response_body);
}

/// Get replies to a specific message (thread) in a Teams channel.
/// Supports pagination via pageToken (the @odata.nextLink from a previous response).
/// Calls GET /teams/{teamId}/channels/{channelId}/messages/{messageId}/replies.
pub fn handleGetChannelMessageReplies(ctx: ToolContext) void {
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        sendToolError(ctx, "Missing arguments. Provide teamId, channelId, and messageId.");
        return;
    };

    // If pageToken is provided, use it directly as the full URL path.
    const page_token = json_rpc.getStringArg(args, "pageToken");
    const path = if (page_token) |pt| blk: {
        break :blk graph.stripGraphPrefix(pt) orelse {
            sendToolError(ctx, "Invalid pageToken — must be a Graph API URL.");
            return;
        };
    } else blk: {
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

        const top = json_rpc.getStringArg(args, "top") orelse "50";

        break :blk std.fmt.allocPrint(
            ctx.allocator,
            "/teams/{s}/channels/{s}/messages/{s}/replies?$top={s}",
            .{ team_id, channel_id, message_id, top },
        ) catch return;
    };
    defer if (page_token == null) ctx.allocator.free(path);

    const response_body = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        std.debug.print("ms-mcp: get-channel-message-replies failed: {}\n", .{err});
        sendToolError(ctx, "Failed to fetch message replies.");
        return;
    };
    defer ctx.allocator.free(response_body);

    // Return raw JSON — includes @odata.nextLink for pagination.
    sendToolResult(ctx, response_body);
}

/// Reply to a message thread in a Teams channel.
/// Calls POST /teams/{teamId}/channels/{channelId}/messages/{messageId}/replies.
/// Supports optional @mentions via the "mentions" parameter.
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

    // Optional mentions — format: "DisplayName|userId,DisplayName2|userId2"
    // Each mention becomes an <at> tag in the HTML body and an entry in
    // the mentions array. The userId is the Azure AD object ID, which you
    // can find in the from.user.id field of channel message replies.
    const mentions_str = json_rpc.getStringArg(args, "mentions");

    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/teams/{s}/channels/{s}/messages/{s}/replies",
        .{ team_id, channel_id, message_id },
    ) catch return;
    defer ctx.allocator.free(path);

    // Build the JSON body manually to support the mentions array.
    // We construct the HTML body by replacing @DisplayName with <at> tags,
    // and build the mentions metadata array for the Graph API.
    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    const w = &json_buf.writer;

    if (mentions_str) |mentions_raw| {
        // Build HTML body: replace @Name with <at id="N">Name</at>
        // and construct the mentions array.
        var html_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer html_buf.deinit();
        var mentions_json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer mentions_json_buf.deinit();
        const mw = &mentions_json_buf.writer;

        // Start with the original message text as HTML.
        // We'll copy it, replacing @Name patterns with <at> tags.
        var html_content = message;
        _ = &html_content;

        // Parse "Name|id,Name2|id2" pairs and build mentions.
        mw.writeAll("[") catch return;
        var mention_idx: usize = 0;
        var iter = std.mem.splitScalar(u8, mentions_raw, ',');
        // First pass: build mentions JSON and collect names for replacement.
        // Store mention data for HTML replacement.
        const MentionInfo = struct { name: []const u8, id: []const u8, idx: usize };
        var mention_infos: [16]MentionInfo = undefined;
        var mention_count: usize = 0;

        while (iter.next()) |pair| {
            const trimmed = std.mem.trim(u8, pair, " ");
            if (trimmed.len == 0) continue;

            // Split on '|' — "DisplayName|userId"
            if (std.mem.indexOfScalar(u8, trimmed, '|')) |sep| {
                const name = trimmed[0..sep];
                const user_id = trimmed[sep + 1 ..];
                if (name.len == 0 or user_id.len == 0) continue;

                if (mention_idx > 0) mw.writeAll(",") catch return;

                // Build mention JSON object.
                mw.print(
                    \\{{"id":{d},"mentionText":"{s}","mentioned":{{"user":{{"id":"{s}","displayName":"{s}","userIdentityType":"aadUser"}}}}}}
                , .{ mention_idx, name, user_id, name }) catch return;

                if (mention_count < 16) {
                    mention_infos[mention_count] = .{ .name = name, .id = user_id, .idx = mention_idx };
                    mention_count += 1;
                }
                mention_idx += 1;
            }
        }
        mw.writeAll("]") catch return;

        // Build HTML body: replace @Name with <at id="N">DisplayName</at>.
        // We match @-prefixed text against both the full display name and
        // the first name (everything before the first space), so "@Rohit"
        // matches "Rohit Sureka".
        const hw = &html_buf.writer;
        var remaining = message;
        while (remaining.len > 0) {
            if (std.mem.indexOfScalar(u8, remaining, '@')) |at_pos| {
                writeHtmlLinked(hw, remaining[0..at_pos]);
                const after_at = remaining[at_pos + 1 ..];

                var matched = false;
                for (mention_infos[0..mention_count]) |info| {
                    // Try matching full display name first, then first name.
                    const first_name_len = std.mem.indexOfScalar(u8, info.name, ' ') orelse info.name.len;
                    const first_name = info.name[0..first_name_len];

                    if (std.mem.startsWith(u8, after_at, info.name)) {
                        // Full name match: "@Rohit Sureka" → <at>Rohit Sureka</at>
                        hw.print("<at id=\"{d}\">{s}</at>", .{ info.idx, info.name }) catch return;
                        remaining = after_at[info.name.len..];
                        matched = true;
                        break;
                    } else if (std.mem.startsWith(u8, after_at, first_name)) {
                        // First name match: "@Rohit" → <at>Rohit Sureka</at>
                        // Check that the next char after the name isn't a letter
                        // (so "@Rohits" doesn't match).
                        const end = first_name.len;
                        if (end < after_at.len and std.ascii.isAlphabetic(after_at[end])) {
                            // Not a word boundary — skip.
                        } else {
                            hw.print("<at id=\"{d}\">{s}</at>", .{ info.idx, info.name }) catch return;
                            remaining = after_at[first_name.len..];
                            matched = true;
                            break;
                        }
                    }
                }
                if (!matched) {
                    hw.writeAll("@") catch return;
                    remaining = after_at;
                }
            } else {
                writeHtmlLinked(hw, remaining);
                break;
            }
        }

        // Assemble the full JSON with HTML body and mentions.
        // We use Stringify for the HTML content to properly escape quotes,
        // then splice in the pre-built mentions array as raw JSON.
        w.writeAll("{\"body\":{\"contentType\":\"html\",\"content\":") catch return;
        std.json.Stringify.encodeJsonString(html_buf.written(), .{}, w) catch return;
        w.writeAll("},\"mentions\":") catch return;
        w.writeAll(mentions_json_buf.written()) catch return;
        w.writeAll("}") catch return;
    } else {
        // No mentions — send as HTML so URLs become clickable hyperlinks.
        const html_content = types.htmlAutoLink(ctx.allocator, message) orelse message;
        defer if (html_content.ptr != message.ptr) ctx.allocator.free(html_content);
        const body = types.ChatMessageRequest{
            .body = .{ .content = html_content },
        };
        std.json.Stringify.value(body, .{}, w) catch return;
    }

    const response_body = graph.post(ctx.allocator, ctx.io, token, path, json_buf.written()) catch |err| {
        std.debug.print("ms-mcp: reply-to-channel-message failed: {}\n", .{err});
        sendToolError(ctx, "Failed to send reply.");
        return;
    };
    defer ctx.allocator.free(response_body);

    sendToolResult(ctx, "Reply sent.");
}

// ---------------------------------------------------------------
// Helpers — reduce boilerplate for common response patterns.
// ---------------------------------------------------------------

/// Write a text segment as HTML, converting newlines to <br> and
/// wrapping bare http/https URLs in <a> tags.
fn writeHtmlLinked(hw: anytype, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            hw.writeAll("<br>") catch return;
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, text[i..], "https://") or
            std.mem.startsWith(u8, text[i..], "http://"))
        {
            const url_start = i;
            while (i < text.len and text[i] != ' ' and text[i] != '\t' and
                text[i] != '\n' and text[i] != '\r') : (i += 1)
            {}
            const url = text[url_start..i];
            hw.print("<a href=\"{s}\">{s}</a>", .{ url, url }) catch return;
            continue;
        }
        hw.writeByte(text[i]) catch return;
        i += 1;
    }
}

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

/// Soft-delete a channel message.
/// Calls POST /teams/{teamId}/channels/{channelId}/messages/{messageId}/softDelete.
pub fn handleDeleteChannelMessage(ctx: ToolContext) void {
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
        sendToolError(ctx, "Missing 'messageId' argument.");
        return;
    };

    const path = std.fmt.allocPrint(ctx.allocator, "/teams/{s}/channels/{s}/messages/{s}/softDelete", .{ team_id, channel_id, message_id }) catch return;
    defer ctx.allocator.free(path);

    const soft_del_response = graph.post(ctx.allocator, ctx.io, token, path, "{}") catch |err| {
        std.debug.print("ms-mcp: delete-channel-message failed: {}\n", .{err});
        sendToolError(ctx, "Failed to delete channel message.");
        return;
    };
    defer ctx.allocator.free(soft_del_response);

    sendToolResult(ctx, "Channel message deleted.");
}

/// Soft-delete a reply to a channel message.
/// Calls POST /teams/{teamId}/channels/{channelId}/messages/{messageId}/replies/{replyId}/softDelete.
pub fn handleDeleteChannelReply(ctx: ToolContext) void {
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        sendToolError(ctx, "Missing arguments. Provide teamId, channelId, messageId, and replyId.");
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
    const reply_id = json_rpc.getStringArg(args, "replyId") orelse {
        sendToolError(ctx, "Missing 'replyId' argument.");
        return;
    };

    const path = std.fmt.allocPrint(ctx.allocator, "/teams/{s}/channels/{s}/messages/{s}/replies/{s}/softDelete", .{ team_id, channel_id, message_id, reply_id }) catch return;
    defer ctx.allocator.free(path);

    const soft_del_response = graph.post(ctx.allocator, ctx.io, token, path, "{}") catch |err| {
        std.debug.print("ms-mcp: delete-channel-reply failed: {}\n", .{err});
        sendToolError(ctx, "Failed to delete channel reply.");
        return;
    };
    defer ctx.allocator.free(soft_del_response);

    sendToolResult(ctx, "Channel reply deleted.");
}
