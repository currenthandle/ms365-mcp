// tools/channels.zig — Teams channel tools (teams, channels, channel messages).

const std = @import("std");
const types = @import("../types.zig");
const graph = @import("../graph.zig");
const json_rpc = @import("../json_rpc.zig");
const ToolContext = @import("context.zig").ToolContext;

/// List the Teams the user has joined.
pub fn handleListTeams(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;

    const response = graph.get(ctx.allocator, ctx.io, token, "/me/joinedTeams?$select=id,displayName,description") catch {
        ctx.sendResult("Failed to fetch teams.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(buildSummary(ctx, response) orelse "No teams found.");
}

/// List channels in a Team.
pub fn handleListChannels(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide teamId.") orelse return;
    const team_id = ctx.getPathArg(args, "teamId", "Missing 'teamId' argument. Use list-teams to find it.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/teams/{s}/channels?$select=id,displayName,description", .{team_id}) catch return;
    defer ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch {
        ctx.sendResult("Failed to fetch channels.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(buildSummary(ctx, response) orelse "No channels found.");
}

/// List messages (posts) in a Teams channel.
pub fn handleListChannelMessages(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide teamId and channelId.") orelse return;

    const page_token = json_rpc.getStringArg(args, "pageToken");
    const path = if (page_token) |pt| blk: {
        break :blk graph.stripGraphPrefix(pt) orelse {
            ctx.sendResult("Invalid pageToken — must be a Graph API URL.");
            return;
        };
    } else blk: {
        const team_id = ctx.getPathArg(args, "teamId", "Missing 'teamId' argument.") orelse return;
        const channel_id = ctx.getPathArg(args, "channelId", "Missing 'channelId' argument.") orelse return;
        const top = ctx.getTopArg(args);
        break :blk std.fmt.allocPrint(ctx.allocator, "/teams/{s}/channels/{s}/messages?$top={s}", .{ team_id, channel_id, top }) catch return;
    };
    defer if (page_token == null) ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch {
        ctx.sendResult("Failed to fetch channel messages.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}

/// Get replies to a specific message thread in a Teams channel.
pub fn handleGetChannelMessageReplies(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide teamId, channelId, and messageId.") orelse return;

    const page_token = json_rpc.getStringArg(args, "pageToken");
    const path = if (page_token) |pt| blk: {
        break :blk graph.stripGraphPrefix(pt) orelse {
            ctx.sendResult("Invalid pageToken — must be a Graph API URL.");
            return;
        };
    } else blk: {
        const team_id = ctx.getPathArg(args, "teamId", "Missing 'teamId' argument.") orelse return;
        const channel_id = ctx.getPathArg(args, "channelId", "Missing 'channelId' argument.") orelse return;
        const message_id = ctx.getPathArg(args, "messageId", "Missing 'messageId' argument.") orelse return;
        const top = ctx.getTopArg(args);
        break :blk std.fmt.allocPrint(ctx.allocator, "/teams/{s}/channels/{s}/messages/{s}/replies?$top={s}", .{ team_id, channel_id, message_id, top }) catch return;
    };
    defer if (page_token == null) ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch {
        ctx.sendResult("Failed to fetch message replies.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}

/// Reply to a message thread in a Teams channel. Supports @mentions.
pub fn handleReplyToChannelMessage(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide teamId, channelId, messageId, and message.") orelse return;
    const team_id = ctx.getPathArg(args, "teamId", "Missing 'teamId' argument.") orelse return;
    const channel_id = ctx.getPathArg(args, "channelId", "Missing 'channelId' argument.") orelse return;
    const message_id = ctx.getPathArg(args, "messageId", "Missing 'messageId' argument.") orelse return;
    const message = ctx.getStringArg(args, "message", "Missing 'message' argument.") orelse return;
    const mentions_str = json_rpc.getStringArg(args, "mentions");

    const path = std.fmt.allocPrint(ctx.allocator, "/teams/{s}/channels/{s}/messages/{s}/replies", .{ team_id, channel_id, message_id }) catch return;
    defer ctx.allocator.free(path);

    // Build the JSON body.
    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    const w = &json_buf.writer;

    if (mentions_str) |mentions_raw| {
        buildMentionedReply(ctx.allocator, w, message, mentions_raw);
    } else {
        // No mentions — send as HTML with auto-linked URLs.
        const html_content = types.htmlAutoLink(ctx.allocator, message) orelse message;
        defer if (html_content.ptr != message.ptr) ctx.allocator.free(html_content);
        const body = types.ChatMessageRequest{ .body = .{ .content = html_content } };
        std.json.Stringify.value(body, .{}, w) catch return;
    }

    _ = graph.post(ctx.allocator, ctx.io, token, path, json_buf.written()) catch {
        ctx.sendResult("Failed to send reply.");
        return;
    };

    ctx.sendResult("Reply sent.");
}

/// Soft-delete a channel message.
pub fn handleDeleteChannelMessage(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide teamId, channelId, and messageId.") orelse return;
    const team_id = ctx.getPathArg(args, "teamId", "Missing 'teamId' argument.") orelse return;
    const channel_id = ctx.getPathArg(args, "channelId", "Missing 'channelId' argument.") orelse return;
    const message_id = ctx.getPathArg(args, "messageId", "Missing 'messageId' argument.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/teams/{s}/channels/{s}/messages/{s}/softDelete", .{ team_id, channel_id, message_id }) catch return;
    defer ctx.allocator.free(path);

    _ = graph.post(ctx.allocator, ctx.io, token, path, "{}") catch {
        ctx.sendResult("Failed to delete channel message.");
        return;
    };

    ctx.sendResult("Channel message deleted.");
}

/// Soft-delete a reply to a channel message.
pub fn handleDeleteChannelReply(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide teamId, channelId, messageId, and replyId.") orelse return;
    const team_id = ctx.getPathArg(args, "teamId", "Missing 'teamId' argument.") orelse return;
    const channel_id = ctx.getPathArg(args, "channelId", "Missing 'channelId' argument.") orelse return;
    const message_id = ctx.getPathArg(args, "messageId", "Missing 'messageId' argument.") orelse return;
    const reply_id = ctx.getPathArg(args, "replyId", "Missing 'replyId' argument.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/teams/{s}/channels/{s}/messages/{s}/replies/{s}/softDelete", .{ team_id, channel_id, message_id, reply_id }) catch return;
    defer ctx.allocator.free(path);

    _ = graph.post(ctx.allocator, ctx.io, token, path, "{}") catch {
        ctx.sendResult("Failed to delete channel reply.");
        return;
    };

    ctx.sendResult("Channel reply deleted.");
}

// ---------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------

/// Build a condensed one-line-per-item summary from a Graph API response
/// containing a "value" array with objects that have displayName, description, and id.
fn buildSummary(ctx: ToolContext, response: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, response, .{}) catch return null;
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .object => |o| switch (o.get("value") orelse return null) {
            .array => |a| a.items,
            else => return null,
        },
        else => return null,
    };

    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer buf.deinit();
    const w = &buf.writer;

    for (items) |item| {
        const obj = switch (item) { .object => |o| o, else => continue };
        const name = switch (obj.get("displayName") orelse continue) { .string => |s| s, else => continue };
        const id = switch (obj.get("id") orelse continue) { .string => |s| s, else => continue };
        const desc = switch (obj.get("description") orelse .null) { .string => |s| s, else => "" };

        if (desc.len > 0) {
            w.print("{s} — {s} — id: {s}\n", .{ name, desc, id }) catch continue;
        } else {
            w.print("{s} — id: {s}\n", .{ name, id }) catch continue;
        }
    }

    const summary = buf.written();
    return if (summary.len > 0) summary else null;
}

/// Write a text segment as HTML, converting newlines to <br>,
/// wrapping URLs in <a> tags, and HTML-escaping all text.
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
            hw.writeAll("<a href=\"") catch return;
            types.writeHtmlEscaped(hw, url);
            hw.writeAll("\">") catch return;
            types.writeHtmlEscaped(hw, url);
            hw.writeAll("</a>") catch return;
            continue;
        }
        switch (text[i]) {
            '<' => hw.writeAll("&lt;") catch return,
            '>' => hw.writeAll("&gt;") catch return,
            '&' => hw.writeAll("&amp;") catch return,
            '"' => hw.writeAll("&quot;") catch return,
            else => hw.writeByte(text[i]) catch return,
        }
        i += 1;
    }
}

/// Build the JSON body for a channel reply with @mentions.
fn buildMentionedReply(allocator: std.mem.Allocator, w: anytype, message: []const u8, mentions_raw: []const u8) void {
    var html_buf: std.Io.Writer.Allocating = .init(allocator);
    defer html_buf.deinit();
    var mentions_json_buf: std.Io.Writer.Allocating = .init(allocator);
    defer mentions_json_buf.deinit();
    const mw = &mentions_json_buf.writer;

    // Parse "Name|id,Name2|id2" pairs.
    const MentionInfo = struct { name: []const u8, id: []const u8, idx: usize };
    var mention_infos: [16]MentionInfo = undefined;
    var mention_count: usize = 0;
    var mention_idx: usize = 0;

    mw.writeAll("[") catch return;
    var iter = std.mem.splitScalar(u8, mentions_raw, ',');
    while (iter.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " ");
        if (trimmed.len == 0) continue;
        const sep = std.mem.indexOfScalar(u8, trimmed, '|') orelse continue;
        const name = trimmed[0..sep];
        const user_id = trimmed[sep + 1 ..];
        if (name.len == 0 or user_id.len == 0) continue;

        if (mention_idx > 0) mw.writeAll(",") catch return;

        // Build mention JSON with safe escaping.
        mw.writeAll("{\"id\":") catch return;
        mw.print("{d}", .{mention_idx}) catch return;
        mw.writeAll(",\"mentionText\":") catch return;
        std.json.Stringify.encodeJsonString(name, .{}, mw) catch return;
        mw.writeAll(",\"mentioned\":{\"user\":{\"id\":") catch return;
        std.json.Stringify.encodeJsonString(user_id, .{}, mw) catch return;
        mw.writeAll(",\"displayName\":") catch return;
        std.json.Stringify.encodeJsonString(name, .{}, mw) catch return;
        mw.writeAll(",\"userIdentityType\":\"aadUser\"}}}") catch return;

        if (mention_count < 16) {
            mention_infos[mention_count] = .{ .name = name, .id = user_id, .idx = mention_idx };
            mention_count += 1;
        }
        mention_idx += 1;
    }
    mw.writeAll("]") catch return;

    // Build HTML body: replace @Name with <at id="N">Name</at>.
    const hw = &html_buf.writer;
    var remaining = message;
    while (remaining.len > 0) {
        if (std.mem.indexOfScalar(u8, remaining, '@')) |at_pos| {
            writeHtmlLinked(hw, remaining[0..at_pos]);
            const after_at = remaining[at_pos + 1 ..];

            var matched = false;
            for (mention_infos[0..mention_count]) |info| {
                const first_name_len = std.mem.indexOfScalar(u8, info.name, ' ') orelse info.name.len;
                const first_name = info.name[0..first_name_len];

                if (std.mem.startsWith(u8, after_at, info.name)) {
                    hw.print("<at id=\"{d}\">", .{info.idx}) catch return;
                    types.writeHtmlEscaped(hw, info.name);
                    hw.writeAll("</at>") catch return;
                    remaining = after_at[info.name.len..];
                    matched = true;
                    break;
                } else if (std.mem.startsWith(u8, after_at, first_name)) {
                    const end = first_name.len;
                    if (end < after_at.len and std.ascii.isAlphabetic(after_at[end])) {
                        // Not a word boundary — skip.
                    } else {
                        hw.print("<at id=\"{d}\">", .{info.idx}) catch return;
                        types.writeHtmlEscaped(hw, info.name);
                        hw.writeAll("</at>") catch return;
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

    // Assemble JSON with HTML body and mentions.
    w.writeAll("{\"body\":{\"contentType\":\"html\",\"content\":") catch return;
    std.json.Stringify.encodeJsonString(html_buf.written(), .{}, w) catch return;
    w.writeAll("},\"mentions\":") catch return;
    w.writeAll(mentions_json_buf.written()) catch return;
    w.writeAll("}") catch return;
}
