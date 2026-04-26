// tools/channels.zig — Teams channel tools (teams, channels, channel messages).

const std = @import("std");
const types = @import("../types.zig");
const graph = @import("../graph.zig");
const json_rpc = @import("../json_rpc.zig");
const binary_download = @import("../binary_download.zig");
const formatter = @import("../formatter.zig");
const ToolContext = @import("context.zig").ToolContext;

const ObjectMap = std.json.ObjectMap;

// Fields we surface from /me/joinedTeams and /teams/{id}/channels.
// Both endpoints return items shaped `{id, displayName, description, ...}`.
const team_or_channel_fields = [_]formatter.FieldSpec{
    .{ .path = "displayName", .label = "name" },
    .{ .path = "description", .label = "desc" },
};

// Fields surfaced from channel messages + replies (same shape for both).
const channel_message_fields = [_]formatter.FieldSpec{
    .{ .path = "createdDateTime", .label = "sent" },
    .{ .path = "from.user.displayName", .label = "from" },
    .{ .path = "subject", .label = "subject" },
    .{ .path = "body.content", .label = "body", .newline_after = true },
};

/// Everything every channel-scoped handler needs: an auth token plus a
/// team+channel ID pair extracted from the tool arguments.
/// Returned by `authAndChannel`; handlers short-circuit via `orelse return`.
const ChannelAuth = struct {
    token: []const u8,
    args: ObjectMap,
    team_id: []const u8,
    channel_id: []const u8,
};

/// Shared prelude for channel handlers that need a team+channel path.
/// Returns null (after sending a tool error) if auth fails or either ID is missing.
fn authAndChannel(ctx: ToolContext, missing_args_msg: []const u8) ?ChannelAuth {
    const token = ctx.requireAuth() orelse return null;
    const args = ctx.getArgs(missing_args_msg) orelse return null;
    const team_id = ctx.getPathArg(args, "teamId", "Missing 'teamId' argument.") orelse return null;
    const channel_id = ctx.getPathArg(args, "channelId", "Missing 'channelId' argument.") orelse return null;
    return .{ .token = token, .args = args, .team_id = team_id, .channel_id = channel_id };
}

/// List the Teams the user has joined.
pub fn handleListTeams(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;

    const response = graph.get(ctx.allocator, ctx.io, token, "/me/joinedTeams?$select=id,displayName,description") catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    if (formatter.summarizeArray(ctx.allocator, response, &team_or_channel_fields)) |summary| {
        defer ctx.allocator.free(summary);
        ctx.sendResult(summary);
    } else {
        ctx.sendResult("No teams found.");
    }
}

/// List channels in a Team. Optional `query` filters channel names case-
/// insensitively in-process — Graph's $filter doesn't support `contains`
/// on channel collections, so we slice client-side. Optional `top` caps
/// the number of matches returned (default 50).
pub fn handleListChannels(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide teamId.") orelse return;
    const team_id = ctx.getPathArg(args, "teamId", "Missing 'teamId' argument. Use list-teams to find it.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/teams/{s}/channels?$select=id,displayName,description", .{team_id}) catch return;
    defer ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    const query = json_rpc.getStringArg(args, "query");
    const top_str = json_rpc.getStringArg(args, "top") orelse "50";
    const top = std.fmt.parseInt(usize, top_str, 10) catch 50;

    if (query == null and top_str.len == 0) {
        // Fast path: no filter, no cap — render everything via formatter.
        if (formatter.summarizeArray(ctx.allocator, response, &team_or_channel_fields)) |summary| {
            defer ctx.allocator.free(summary);
            ctx.sendResult(summary);
        } else {
            ctx.sendResult("No channels found.");
        }
        return;
    }

    const filtered = filterChannelsByName(ctx.allocator, response, query, top) catch {
        ctx.sendResult(response);
        return;
    };
    defer ctx.allocator.free(filtered);
    ctx.sendResult(if (filtered.len > 0) filtered else "No channels matched.");
}

/// Walk a Graph `{value: [...]}` channel response, filter by name, and
/// render a formatter-style summary. Each row: "name: X | desc: Y | id: Z".
fn filterChannelsByName(
    allocator: std.mem.Allocator,
    response: []const u8,
    query: ?[]const u8,
    top: usize,
) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return error.ParseFailed;
    defer parsed.deinit();

    const root = switch (parsed.value) { .object => |o| o, else => return error.ParseFailed };
    const items = switch (root.get("value") orelse return error.ParseFailed) { .array => |a| a, else => return error.ParseFailed };

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    var written: usize = 0;
    for (items.items) |item_val| {
        if (written >= top) break;
        const obj = switch (item_val) { .object => |o| o, else => continue };
        const name = switch (obj.get("displayName") orelse continue) { .string => |s| s, else => continue };
        if (query) |q| {
            if (q.len > 0 and !containsIgnoreCase(name, q)) continue;
        }
        const desc = if (obj.get("description")) |d| switch (d) { .string => |s| s, else => "" } else "";
        const id = switch (obj.get("id") orelse continue) { .string => |s| s, else => continue };
        if (desc.len > 0) {
            w.print("name: {s} | desc: {s} | id: {s}\n", .{ name, desc, id }) catch continue;
        } else {
            w.print("name: {s} | id: {s}\n", .{ name, id }) catch continue;
        }
        written += 1;
    }

    return out.toOwnedSlice();
}

/// Case-insensitive substring check over ASCII. Graph names are
/// always Latin/ASCII for channel/team display names in practice.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |n_ch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(n_ch)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// Search channels by name across every team the user has joined.
///
/// Workflow this exists to short-circuit: list-teams (~10 teams),
/// list-channels per team (~100 channels each), eyeball-grep. With this
/// tool the agent passes a name fragment and gets back matching channels
/// with the teamId + channelId pair already paired up for post-channel-
/// message or reply-to-channel-message.
pub fn handleSearchChannels(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide query.") orelse return;
    const query = ctx.getStringArg(args, "query", "Missing 'query' argument (channel name fragment).") orelse return;

    // Default top=10 keeps the team walk short. Without a cap, a query
    // like "general" matches in every joined team and the walk runs
    // the full inventory — slow enough to hit common per-call deadlines.
    const top_str = json_rpc.getStringArg(args, "top") orelse "10";
    const top_total = std.fmt.parseInt(usize, top_str, 10) catch 10;

    // Pull joined teams first.
    const teams_response = graph.get(ctx.allocator, ctx.io, token, "/me/joinedTeams?$select=id,displayName") catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(teams_response);

    const teams_parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, teams_response, .{}) catch {
        ctx.sendResult("Failed to parse teams response.");
        return;
    };
    defer teams_parsed.deinit();

    const teams_root = switch (teams_parsed.value) {
        .object => |o| o,
        else => {
            ctx.sendResult("Unexpected teams response shape.");
            return;
        },
    };
    const teams_arr = switch (teams_root.get("value") orelse return) {
        .array => |a| a,
        else => return,
    };

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    const w = &out.writer;

    var written: usize = 0;
    var teams_searched: usize = 0;

    for (teams_arr.items) |team_val| {
        if (written >= top_total) break;
        const team = switch (team_val) { .object => |o| o, else => continue };
        const team_id = switch (team.get("id") orelse continue) { .string => |s| s, else => continue };
        const team_name = switch (team.get("displayName") orelse .null) { .string => |s| s, else => "(unknown team)" };
        teams_searched += 1;

        // Fetch this team's channels.
        const path = std.fmt.allocPrint(ctx.allocator, "/teams/{s}/channels?$select=id,displayName,description", .{team_id}) catch continue;
        defer ctx.allocator.free(path);

        const channels_response = graph.get(ctx.allocator, ctx.io, token, path) catch continue;
        defer ctx.allocator.free(channels_response);

        const ch_parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, channels_response, .{}) catch continue;
        defer ch_parsed.deinit();
        const ch_root = switch (ch_parsed.value) { .object => |o| o, else => continue };
        const ch_arr = switch (ch_root.get("value") orelse continue) { .array => |a| a, else => continue };

        for (ch_arr.items) |ch_val| {
            if (written >= top_total) break;
            const ch = switch (ch_val) { .object => |o| o, else => continue };
            const ch_name = switch (ch.get("displayName") orelse continue) { .string => |s| s, else => continue };
            if (!containsIgnoreCase(ch_name, query)) continue;
            const ch_id = switch (ch.get("id") orelse continue) { .string => |s| s, else => continue };

            w.print("team: {s} | channel: {s} | teamId: {s} | channelId: {s}\n", .{ team_name, ch_name, team_id, ch_id }) catch continue;
            written += 1;
        }
    }

    if (written == 0) {
        const msg = std.fmt.allocPrint(ctx.allocator, "No channels matched '{s}' across {d} joined team(s).", .{ query, teams_searched }) catch {
            ctx.sendResult("No matches.");
            return;
        };
        defer ctx.allocator.free(msg);
        ctx.sendResult(msg);
        return;
    }
    ctx.sendResult(out.written());
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

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    if (formatter.summarizeArray(ctx.allocator, response, &channel_message_fields)) |summary| {
        defer ctx.allocator.free(summary);
        ctx.sendResult(summary);
    } else {
        ctx.sendResult("No messages in this channel.");
    }
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

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    if (formatter.summarizeArray(ctx.allocator, response, &channel_message_fields)) |summary| {
        defer ctx.allocator.free(summary);
        ctx.sendResult(summary);
    } else {
        ctx.sendResult("No replies to this message.");
    }
}

/// Post a new top-level message to a Teams channel. Supports @mentions and optional subject.
pub fn handlePostChannelMessage(ctx: ToolContext) void {
    const ch = authAndChannel(ctx, "Missing arguments. Provide teamId, channelId, and message.") orelse return;
    const message = ctx.getStringArg(ch.args, "message", "Missing 'message' argument.") orelse return;
    const mentions_str = json_rpc.getStringArg(ch.args, "mentions");
    const subject = json_rpc.getStringArg(ch.args, "subject");

    const path = std.fmt.allocPrint(ctx.allocator, "/teams/{s}/channels/{s}/messages", .{ ch.team_id, ch.channel_id }) catch return;
    defer ctx.allocator.free(path);

    // Build the JSON body.
    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    const w = &json_buf.writer;

    if (mentions_str) |mentions_raw| {
        buildMentionedMessage(ctx.allocator, w, message, mentions_raw, subject);
    } else {
        // format=html trusts caller-supplied HTML as-is. format=text
        // (default) HTML-escapes + auto-links URLs + converts \n to <br>.
        const format = json_rpc.getStringArg(ch.args, "format") orelse "text";
        const is_html = std.mem.eql(u8, format, "html");
        const content = if (is_html) message else (types.htmlAutoLink(ctx.allocator, message) orelse message);
        defer if (!is_html and content.ptr != message.ptr) ctx.allocator.free(content);

        w.writeAll("{\"body\":{\"contentType\":\"html\",\"content\":") catch return;
        std.json.Stringify.encodeJsonString(content, .{}, w) catch return;
        w.writeAll("}") catch return;
        if (subject) |subj| {
            w.writeAll(",\"subject\":") catch return;
            std.json.Stringify.encodeJsonString(subj, .{}, w) catch return;
        }
        w.writeAll("}") catch return;
    }

    _ = graph.post(ctx.allocator, ctx.io, ch.token, path, json_buf.written()) catch |err| {
        ctx.sendGraphError(err);
        return;
    };

    ctx.sendResult("Channel message posted.");
}

/// Reply to a message thread in a Teams channel. Supports @mentions.
pub fn handleReplyToChannelMessage(ctx: ToolContext) void {
    const ch = authAndChannel(ctx, "Missing arguments. Provide teamId, channelId, messageId, and message.") orelse return;
    const message_id = ctx.getPathArg(ch.args, "messageId", "Missing 'messageId' argument.") orelse return;
    const message = ctx.getStringArg(ch.args, "message", "Missing 'message' argument.") orelse return;
    const mentions_str = json_rpc.getStringArg(ch.args, "mentions");

    const path = std.fmt.allocPrint(ctx.allocator, "/teams/{s}/channels/{s}/messages/{s}/replies", .{ ch.team_id, ch.channel_id, message_id }) catch return;
    defer ctx.allocator.free(path);

    // Build the JSON body.
    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    const w = &json_buf.writer;

    if (mentions_str) |mentions_raw| {
        buildMentionedMessage(ctx.allocator, w, message, mentions_raw, null);
    } else {
        // format=html trusts the caller's HTML; text (default) auto-escapes + links.
        const format = json_rpc.getStringArg(ch.args, "format") orelse "text";
        const is_html = std.mem.eql(u8, format, "html");
        const content = if (is_html) message else (types.htmlAutoLink(ctx.allocator, message) orelse message);
        defer if (!is_html and content.ptr != message.ptr) ctx.allocator.free(content);
        const body = types.ChatMessageRequest{ .body = .{ .content = content } };
        std.json.Stringify.value(body, .{}, w) catch return;
    }

    _ = graph.post(ctx.allocator, ctx.io, ch.token, path, json_buf.written()) catch |err| {
        ctx.sendGraphError(err);
        return;
    };

    ctx.sendResult("Reply sent.");
}

/// Soft-delete a channel message.
pub fn handleDeleteChannelMessage(ctx: ToolContext) void {
    const ch = authAndChannel(ctx, "Missing arguments. Provide teamId, channelId, and messageId.") orelse return;
    const message_id = ctx.getPathArg(ch.args, "messageId", "Missing 'messageId' argument.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/teams/{s}/channels/{s}/messages/{s}/softDelete", .{ ch.team_id, ch.channel_id, message_id }) catch return;
    defer ctx.allocator.free(path);

    graph.postNoContent(ctx.allocator, ctx.io, ch.token, path, "{}") catch |err| {
        ctx.sendGraphError(err);
        return;
    };

    ctx.sendResult("Channel message deleted.");
}

/// Soft-delete a reply to a channel message.
pub fn handleDeleteChannelReply(ctx: ToolContext) void {
    const ch = authAndChannel(ctx, "Missing arguments. Provide teamId, channelId, messageId, and replyId.") orelse return;
    const message_id = ctx.getPathArg(ch.args, "messageId", "Missing 'messageId' argument.") orelse return;
    const reply_id = ctx.getPathArg(ch.args, "replyId", "Missing 'replyId' argument.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/teams/{s}/channels/{s}/messages/{s}/replies/{s}/softDelete", .{ ch.team_id, ch.channel_id, message_id, reply_id }) catch return;
    defer ctx.allocator.free(path);

    graph.postNoContent(ctx.allocator, ctx.io, ch.token, path, "{}") catch |err| {
        ctx.sendGraphError(err);
        return;
    };

    ctx.sendResult("Channel reply deleted.");
}

/// Download an inline image (or other hosted content) from a Teams
/// channel message and write the bytes to a local temp file.
///
/// Channel hosted contents live at:
///   GET /teams/{teamId}/channels/{channelId}/messages/{msgId}/hostedContents/{contentId}/$value
///
/// Two call shapes:
///   1. Pass `url` — the full graph.microsoft.com .../hostedContents/.../$value
///      URL pulled straight from the message body's `<img src=...>`.
///   2. Pass `teamId` + `channelId` + `messageId` + `contentId`.
pub fn handleDownloadChannelImage(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide either 'url' or all of teamId+channelId+messageId+contentId.") orelse return;

    const path = path: {
        if (json_rpc.getStringArg(args, "url")) |url| {
            // Same /v1.0/ stripping as the chat helper — both paths sit
            // under the same Graph version prefix.
            const v1_marker = "/v1.0";
            const idx = std.mem.indexOf(u8, url, v1_marker) orelse {
                ctx.sendResult("Could not parse the hostedContents URL. Expected something like https://graph.microsoft.com/v1.0/teams/.../hostedContents/.../$value");
                return;
            };
            const after_version = url[idx + v1_marker.len ..];
            if (after_version.len == 0 or after_version[0] != '/') {
                ctx.sendResult("Hosted-content URL is missing the path after /v1.0.");
                return;
            }
            break :path ctx.allocator.dupe(u8, after_version) catch return;
        }
        const team_id = ctx.getPathArg(args, "teamId", "Missing 'teamId' (or pass 'url' instead).") orelse return;
        const channel_id = ctx.getPathArg(args, "channelId", "Missing 'channelId' (or pass 'url' instead).") orelse return;
        const message_id = ctx.getPathArg(args, "messageId", "Missing 'messageId' (or pass 'url' instead).") orelse return;
        const content_id = ctx.getPathArg(args, "contentId", "Missing 'contentId' (or pass 'url' instead).") orelse return;
        break :path std.fmt.allocPrint(
            ctx.allocator,
            "/teams/{s}/channels/{s}/messages/{s}/hostedContents/{s}/$value",
            .{ team_id, channel_id, message_id, content_id },
        ) catch return;
    };
    defer ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    const name_override = json_rpc.getStringArg(args, "name");
    const default_name = "channel-image.bin";
    const name = if (name_override) |n| n else default_name;

    const local_path = binary_download.saveToTempFile(
        ctx.allocator,
        ctx.io,
        name,
        response,
    ) catch {
        ctx.sendResult("Failed to write hosted content to a temp path.");
        return;
    };
    defer ctx.allocator.free(local_path);

    const msg = std.fmt.allocPrint(
        ctx.allocator,
        "Downloaded {d} bytes | local_path: {s}",
        .{ response.len, local_path },
    ) catch return;
    defer ctx.allocator.free(msg);
    ctx.sendResult(msg);
}

// ---------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------

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

/// Build the JSON body for a channel message with @mentions and optional subject.
/// Used by both post-channel-message and reply-to-channel-message.
fn buildMentionedMessage(allocator: std.mem.Allocator, w: anytype, message: []const u8, mentions_raw: []const u8, subject: ?[]const u8) void {
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

    // Assemble JSON with HTML body, mentions, and optional subject.
    w.writeAll("{\"body\":{\"contentType\":\"html\",\"content\":") catch return;
    std.json.Stringify.encodeJsonString(html_buf.written(), .{}, w) catch return;
    w.writeAll("},\"mentions\":") catch return;
    w.writeAll(mentions_json_buf.written()) catch return;
    if (subject) |subj| {
        w.writeAll(",\"subject\":") catch return;
        std.json.Stringify.encodeJsonString(subj, .{}, w) catch return;
    }
    w.writeAll("}") catch return;
}

// ---------------------------------------------------------------
// Tests
// ---------------------------------------------------------------

test "buildMentionedMessage basic mention" {
    const allocator = std.testing.allocator;
    var json_buf: std.Io.Writer.Allocating = .init(allocator);
    defer json_buf.deinit();

    buildMentionedMessage(allocator, &json_buf.writer, "Hey @Rohit check this", "Rohit Sureka|abc-123", null);

    const result = json_buf.written();
    try std.testing.expect(std.mem.indexOf(u8, result, "<at id=\\\"0\\\">Rohit Sureka</at>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"mentionText\":\"Rohit Sureka\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":\"abc-123\"") != null);
}

test "buildMentionedMessage with subject" {
    const allocator = std.testing.allocator;
    var json_buf: std.Io.Writer.Allocating = .init(allocator);
    defer json_buf.deinit();

    buildMentionedMessage(allocator, &json_buf.writer, "Hello world", "", "My Subject");

    const result = json_buf.written();
    try std.testing.expect(std.mem.indexOf(u8, result, "\"subject\":\"My Subject\"") != null);
}

test "buildMentionedMessage without subject" {
    const allocator = std.testing.allocator;
    var json_buf: std.Io.Writer.Allocating = .init(allocator);
    defer json_buf.deinit();

    buildMentionedMessage(allocator, &json_buf.writer, "Hello world", "", null);

    const result = json_buf.written();
    try std.testing.expect(std.mem.indexOf(u8, result, "subject") == null);
}

test "buildMentionedMessage multiple mentions" {
    const allocator = std.testing.allocator;
    var json_buf: std.Io.Writer.Allocating = .init(allocator);
    defer json_buf.deinit();

    buildMentionedMessage(allocator, &json_buf.writer, "@Alice and @Bob please review", "Alice Smith|id-1,Bob Jones|id-2", null);

    const result = json_buf.written();
    try std.testing.expect(std.mem.indexOf(u8, result, "<at id=\\\"0\\\">Alice Smith</at>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<at id=\\\"1\\\">Bob Jones</at>") != null);
}

test "buildMentionedMessage first-name matching" {
    const allocator = std.testing.allocator;
    var json_buf: std.Io.Writer.Allocating = .init(allocator);
    defer json_buf.deinit();

    buildMentionedMessage(allocator, &json_buf.writer, "Hey @Rohit check this", "Rohit Sureka|abc-123", null);

    const result = json_buf.written();
    // @Rohit should match "Rohit Sureka" by first name
    try std.testing.expect(std.mem.indexOf(u8, result, "<at id=\\\"0\\\">Rohit Sureka</at>") != null);
}

test "buildMentionedMessage unmatched @ preserved" {
    const allocator = std.testing.allocator;
    var json_buf: std.Io.Writer.Allocating = .init(allocator);
    defer json_buf.deinit();

    buildMentionedMessage(allocator, &json_buf.writer, "email me @unknown", "Alice|id-1", null);

    const result = json_buf.written();
    try std.testing.expect(std.mem.indexOf(u8, result, "@unknown") != null);
}

test "teams/channels summary via formatter" {
    const response =
        \\{"value":[{"displayName":"Team A","id":"id-a","description":"Desc A"},{"displayName":"Team B","id":"id-b","description":""}]}
    ;
    const result = formatter.summarizeArray(std.testing.allocator, response, &team_or_channel_fields).?;
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "name: Team A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "desc: Desc A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "id: id-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "name: Team B") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "id: id-b") != null);
}

test "writeHtmlLinked escapes HTML and links URLs" {
    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    writeHtmlLinked(&buf.writer, "Check https://example.com & <script>");

    const result = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, result, "<a href=\"https://example.com\">https://example.com</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "&amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "&lt;script&gt;") != null);
}
