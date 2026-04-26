// tools/chat.zig — Teams chat tools.

const std = @import("std");
const types = @import("../types.zig");
const graph = @import("../graph.zig");
const json_rpc = @import("../json_rpc.zig");
const binary_download = @import("../binary_download.zig");
const ToolContext = @import("context.zig").ToolContext;
const formatter = @import("../formatter.zig");

const Allocator = std.mem.Allocator;

// Fields surfaced from /me/chats/{id}/messages.
const chat_message_fields = [_]formatter.FieldSpec{
    .{ .path = "createdDateTime", .label = "sent", .is_date = true },
    .{ .path = "from.user.displayName", .label = "from" },
    .{ .path = "body.content", .label = "body", .newline_after = true },
};

/// Build a single member JSON object for the create-chat API.
/// Uses JSON serialization to safely escape the identifier.
fn buildMemberJson(allocator: Allocator, identifier: []const u8) ![]u8 {
    const bind_value = try std.fmt.allocPrint(allocator,
        "https://graph.microsoft.com/v1.0/users('{s}')", .{identifier});
    defer allocator.free(bind_value);

    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;
    w.writeAll("{") catch return error.OutOfMemory;
    w.writeAll("\"@odata.type\":\"#microsoft.graph.aadUserConversationMember\",") catch return error.OutOfMemory;
    w.writeAll("\"roles\":[\"owner\"],") catch return error.OutOfMemory;
    w.writeAll("\"user@odata.bind\":") catch return error.OutOfMemory;
    std.json.Stringify.encodeJsonString(bind_value, .{}, w) catch return error.OutOfMemory;
    w.writeAll("}") catch return error.OutOfMemory;
    return buf.toOwnedSlice() catch return error.OutOfMemory;
}

/// List messages in a Teams chat by chat ID.
pub fn handleListChatMessages(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide chatId.") orelse return;

    // If pageToken is provided, use it directly as the path.
    const page_token = json_rpc.getStringArg(args, "pageToken");
    const path = if (page_token) |pt| blk: {
        break :blk graph.stripGraphPrefix(pt) orelse {
            ctx.sendResult("Invalid pageToken — must be a Graph API URL.");
            return;
        };
    } else blk: {
        const chat_id = ctx.getPathArg(args, "chatId", "Missing 'chatId' argument.") orelse return;
        const top = ctx.getTopArg(args);
        break :blk std.fmt.allocPrint(ctx.allocator, "/me/chats/{s}/messages?$top={s}", .{ chat_id, top }) catch return;
    };
    defer if (page_token == null) ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    if (formatter.summarizeArray(ctx.allocator, response, &chat_message_fields)) |summary| {
        defer ctx.allocator.free(summary);
        ctx.sendResult(summary);
    } else {
        ctx.sendResult("No messages in this chat.");
    }
}

/// List Teams chats with condensed member summaries.
pub fn handleListChats(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;

    const args = json_rpc.getToolArgs(ctx.parsed);
    const page_token = if (args) |a| json_rpc.getStringArg(a, "pageToken") else null;

    const path = if (page_token) |pt| blk: {
        break :blk graph.stripGraphPrefix(pt) orelse {
            ctx.sendResult("Invalid pageToken — must be a Graph API URL.");
            return;
        };
    } else blk: {
        const top = if (args) |a| json_rpc.getTopArg(a) else "50";
        break :blk std.fmt.allocPrint(
            ctx.allocator,
            "/me/chats?$top={s}&$select=id,topic,chatType,lastUpdatedDateTime&$expand=members",
            .{top},
        ) catch return;
    };
    defer if (page_token == null) ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    // Parse and build a condensed summary (raw response is ~135k tokens).
    const chats_parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, response, .{}) catch {
        ctx.sendResult(response);
        return;
    };
    defer chats_parsed.deinit();

    var summary_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer summary_buf.deinit();
    const sw = &summary_buf.writer;

    const root = switch (chats_parsed.value) { .object => |o| o, else => return };
    const chats = switch (root.get("value") orelse return) { .array => |a| a, else => return };

    for (chats.items) |chat_val| {
        const chat = switch (chat_val) { .object => |o| o, else => continue };
        const chat_type = switch (chat.get("chatType") orelse continue) { .string => |s| s, else => "unknown" };
        const topic = switch (chat.get("topic") orelse .null) { .string => |s| s, else => "(no topic)" };
        const chat_id = switch (chat.get("id") orelse continue) { .string => |s| s, else => continue };

        sw.print("[{s}] {s}", .{ chat_type, topic }) catch continue;

        // Extract member display names.
        if (chat.get("members")) |members_val| {
            if (switch (members_val) { .array => |a| a, else => null }) |members| {
                sw.writeAll(" — ") catch continue;
                for (members.items, 0..) |member_val, i| {
                    const member = switch (member_val) { .object => |o| o, else => continue };
                    const name = switch (member.get("displayName") orelse continue) { .string => |s| s, else => continue };
                    if (i > 0) sw.writeAll(", ") catch continue;
                    sw.writeAll(name) catch continue;
                }
            }
        }

        sw.print(" — id: {s}\n", .{chat_id}) catch continue;
    }

    // Include nextLink for pagination.
    if (root.get("@odata.nextLink")) |next_val| {
        if (switch (next_val) { .string => |s| s, else => null }) |nl| {
            sw.print("\nnextLink: {s}\n", .{nl}) catch {};
        }
    }

    const summary = summary_buf.written();
    ctx.sendResult(if (summary.len > 0) summary else "No chats found.");
}

/// Search chats by participant name OR topic, walking paginated
/// /me/chats and filtering client-side.
///
/// Microsoft Graph's /search/query doesn't index chat *containers* —
/// only individual chat messages — so there's no server-side search for
/// "the 1:1 chat I have with Marcus" or "the group chat with topic
/// pricing". This tool paginates list-chats up to `maxScan` chats
/// (default 200), filters by name fragment against members or topic,
/// and stops once `top` matches accumulate.
pub fn handleSearchChats(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide query.") orelse return;
    const query = ctx.getStringArg(args, "query", "Missing 'query' argument (member name or topic fragment).") orelse return;

    const top_str = json_rpc.getStringArg(args, "top") orelse "10";
    const top = std.fmt.parseInt(usize, top_str, 10) catch 10;
    const max_scan_str = json_rpc.getStringArg(args, "maxScan") orelse "200";
    const max_scan = std.fmt.parseInt(usize, max_scan_str, 10) catch 200;

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    const w = &out.writer;

    var matches: usize = 0;
    var scanned: usize = 0;

    var next_path: ?[]u8 = std.fmt.allocPrint(
        ctx.allocator,
        "/me/chats?$top=50&$select=id,topic,chatType,lastUpdatedDateTime&$expand=members",
        .{},
    ) catch return;

    while (next_path) |path| : (next_path = next_path) {
        defer ctx.allocator.free(path);
        next_path = null;

        const response = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
            ctx.sendGraphError(err);
            return;
        };
        defer ctx.allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, response, .{}) catch break;
        defer parsed.deinit();

        const root = switch (parsed.value) { .object => |o| o, else => break };
        const chats = switch (root.get("value") orelse break) { .array => |a| a, else => break };

        for (chats.items) |chat_val| {
            if (matches >= top or scanned >= max_scan) break;
            scanned += 1;

            const chat = switch (chat_val) { .object => |o| o, else => continue };
            const chat_type = switch (chat.get("chatType") orelse .null) { .string => |s| s, else => "unknown" };
            const topic = switch (chat.get("topic") orelse .null) { .string => |s| s, else => "" };
            const chat_id = switch (chat.get("id") orelse continue) { .string => |s| s, else => continue };

            // Match topic OR any member's displayName.
            var hit = topic.len > 0 and containsIgnoreCase(topic, query);
            if (!hit) {
                if (chat.get("members")) |members_val| {
                    if (switch (members_val) { .array => |a| a, else => null }) |members| {
                        for (members.items) |m_val| {
                            const m = switch (m_val) { .object => |o| o, else => continue };
                            const name = switch (m.get("displayName") orelse continue) { .string => |s| s, else => continue };
                            if (containsIgnoreCase(name, query)) {
                                hit = true;
                                break;
                            }
                        }
                    }
                }
            }
            if (!hit) continue;

            // Render this match.
            w.print("[{s}] {s}", .{ chat_type, if (topic.len > 0) topic else "(no topic)" }) catch continue;
            if (chat.get("members")) |members_val| {
                if (switch (members_val) { .array => |a| a, else => null }) |members| {
                    w.writeAll(" — ") catch continue;
                    for (members.items, 0..) |m_val, i| {
                        const m = switch (m_val) { .object => |o| o, else => continue };
                        const name = switch (m.get("displayName") orelse continue) { .string => |s| s, else => continue };
                        if (i > 0) w.writeAll(", ") catch continue;
                        w.writeAll(name) catch continue;
                    }
                }
            }
            w.print(" — id: {s}\n", .{chat_id}) catch continue;
            matches += 1;
        }
        if (matches >= top or scanned >= max_scan) break;

        // Follow nextLink if there is one.
        if (root.get("@odata.nextLink")) |next_val| {
            if (switch (next_val) { .string => |s| s, else => null }) |nl| {
                if (graph.stripGraphPrefix(nl)) |stripped| {
                    next_path = ctx.allocator.dupe(u8, stripped) catch null;
                }
            }
        }
    }

    if (matches == 0) {
        const msg = std.fmt.allocPrint(ctx.allocator, "No chats matched '{s}' after scanning {d} chat(s).", .{ query, scanned }) catch {
            ctx.sendResult("No matches.");
            return;
        };
        defer ctx.allocator.free(msg);
        ctx.sendResult(msg);
        return;
    }
    ctx.sendResult(out.written());
}

/// Case-insensitive substring check over ASCII.
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

/// Send a message in a Teams chat.
pub fn handleSendChatMessage(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide chatId and message.") orelse return;
    const chat_id = ctx.getPathArg(args, "chatId", "Missing 'chatId' argument.") orelse return;
    const message = ctx.getStringArg(args, "message", "Missing 'message' argument.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/chats/{s}/messages", .{chat_id}) catch return;
    defer ctx.allocator.free(path);

    // format=html trusts the caller's HTML as-is (clickable links, bold,
    // line breaks, etc.). format=text (default) runs htmlAutoLink which
    // HTML-escapes angle brackets + ampersands + quotes, wraps bare URLs
    // in <a> tags, and converts \n to <br>.
    const format = json_rpc.getStringArg(args, "format") orelse "text";
    const is_html = std.mem.eql(u8, format, "html");

    const content = if (is_html) message else (types.htmlAutoLink(ctx.allocator, message) orelse message);
    defer if (!is_html and content.ptr != message.ptr) ctx.allocator.free(content);

    const chat_msg = types.ChatMessageRequest{ .body = .{ .content = content } };
    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(chat_msg, .{}, &json_buf.writer) catch return;

    _ = graph.post(ctx.allocator, ctx.io, token, path, json_buf.written()) catch |err| {
        ctx.sendGraphError(err);
        return;
    };

    ctx.sendResult("Chat message sent.");
}

/// Create or find an existing 1:1 Teams chat between two users.
pub fn handleCreateChat(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide emailOne and emailTwo.") orelse return;
    const email_one = ctx.getStringArg(args, "emailOne", "Missing 'emailOne' argument.") orelse return;
    const email_two = ctx.getStringArg(args, "emailTwo", "Missing 'emailTwo' argument.") orelse return;

    const member1 = buildMemberJson(ctx.allocator, email_one) catch return;
    defer ctx.allocator.free(member1);
    const member2 = buildMemberJson(ctx.allocator, email_two) catch return;
    defer ctx.allocator.free(member2);

    const json_body = std.fmt.allocPrint(ctx.allocator,
        \\{{"chatType":"oneOnOne","members":[{s},{s}]}}
    , .{ member1, member2 }) catch return;
    defer ctx.allocator.free(json_body);

    // /chats (application-scope URL), NOT /me/chats. On some tenants
    // POST /me/chats returns a bare 400 "UnknownError" with no message,
    // while POST /chats with identical body succeeds. Delegated token
    // carries the caller's identity either way — /me/ prefix isn't
    // needed for chat creation and actively breaks on this tenant.
    const response = graph.post(ctx.allocator, ctx.io, token, "/chats", json_body) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}

/// Search Teams chat messages by keyword across the user's entire history.
///
/// Uses POST /search/query with entityTypes=["chatMessage"] — the Microsoft
/// Search index. Unlike /me/chats/{id}/messages, this endpoint searches
/// across ALL chats (1:1, group, meeting) AND covers older content that
/// chat-message pagination silently stops returning. It's the only way to
/// find Teams messages from more than a few weeks ago by keyword.
///
/// Graph caps each search at 25 results by default; pass 'size' (1-500)
/// to raise the cap, or 'from' to paginate.
pub fn handleSearchChatMessages(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide query.") orelse return;
    const query = ctx.getStringArg(args, "query", "Missing 'query' argument.") orelse return;

    const size = json_rpc.getStringArg(args, "size") orelse "25";
    const from = json_rpc.getStringArg(args, "from") orelse "0";

    // Build the search request body. The query is JSON-escaped so quotes
    // and backslashes in the user's keywords don't break the body.
    var body_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer body_buf.deinit();
    const bw = &body_buf.writer;
    bw.writeAll("{\"requests\":[{\"entityTypes\":[\"chatMessage\"],\"query\":{\"queryString\":") catch return;
    std.json.Stringify.encodeJsonString(query, .{}, bw) catch return;
    bw.print("}},\"from\":{s},\"size\":{s}}}]}}", .{ from, size }) catch return;
    // Note: the closing braces above intentionally balance the opening
    // "{\"requests\":[{..." — two for the request object, one for the array
    // wrapper, one for the top-level object.

    const response = graph.post(ctx.allocator, ctx.io, token, "/search/query", body_buf.written()) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    const summary = summarizeSearchResponse(ctx.allocator, response) catch {
        ctx.sendResult(response);
        return;
    };
    defer ctx.allocator.free(summary);
    ctx.sendResult(if (summary.len > 0) summary else "No chat messages matched that query.");
}

/// Parse /search/query's nested response and produce a condensed summary.
///
/// Shape (abridged): { value: [ { hitsContainers: [ { hits: [ { resource: {
///   from, createdDateTime, chatId, body: { content } } } ] } ] } ] }
fn summarizeSearchResponse(allocator: Allocator, response: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return error.ParseFailed;
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    const root = switch (parsed.value) { .object => |o| o, else => return error.ParseFailed };
    const value_arr = switch (root.get("value") orelse return error.ParseFailed) { .array => |a| a, else => return error.ParseFailed };

    for (value_arr.items) |resp_val| {
        const resp = switch (resp_val) { .object => |o| o, else => continue };
        const containers = switch (resp.get("hitsContainers") orelse continue) { .array => |a| a, else => continue };
        for (containers.items) |container_val| {
            const container = switch (container_val) { .object => |o| o, else => continue };
            const hits = switch (container.get("hits") orelse continue) { .array => |a| a, else => continue };
            for (hits.items) |hit_val| {
                const hit = switch (hit_val) { .object => |o| o, else => continue };
                const resource = switch (hit.get("resource") orelse continue) { .object => |o| o, else => continue };

                const when = switch (resource.get("createdDateTime") orelse .null) { .string => |s| s, else => "?" };
                const chat_id = switch (resource.get("chatId") orelse .null) { .string => |s| s, else => "" };
                var from_name: []const u8 = "?";
                if (resource.get("from")) |f_val| {
                    if (switch (f_val) { .object => |o| o, else => null }) |f_obj| {
                        if (f_obj.get("user")) |u_val| {
                            if (switch (u_val) { .object => |o| o, else => null }) |u_obj| {
                                if (u_obj.get("displayName")) |n_val| {
                                    if (switch (n_val) { .string => |s| s, else => null }) |n| from_name = n;
                                }
                            }
                        }
                    }
                }
                var preview: []const u8 = "";
                if (resource.get("body")) |b_val| {
                    if (switch (b_val) { .object => |o| o, else => null }) |b_obj| {
                        if (b_obj.get("content")) |c_val| {
                            if (switch (c_val) { .string => |s| s, else => null }) |c| preview = c;
                        }
                    }
                }
                // Fall back to summary when body isn't hydrated.
                if (preview.len == 0) {
                    if (hit.get("summary")) |s_val| {
                        if (switch (s_val) { .string => |s| s, else => null }) |s| preview = s;
                    }
                }

                w.print("[{s}] from {s} — chatId: {s}\n", .{ when, from_name, chat_id }) catch continue;
                if (preview.len > 0) w.print("  {s}\n", .{preview}) catch {};
            }
        }
    }

    return out.toOwnedSlice();
}

/// Soft-delete a chat message.
pub fn handleDeleteChatMessage(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide chatId and messageId.") orelse return;
    const chat_id = ctx.getPathArg(args, "chatId", "Missing 'chatId' argument.") orelse return;
    const message_id = ctx.getPathArg(args, "messageId", "Missing 'messageId' argument.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/chats/{s}/messages/{s}/softDelete", .{ chat_id, message_id }) catch return;
    defer ctx.allocator.free(path);

    graph.postNoContent(ctx.allocator, ctx.io, token, path, "{}") catch |err| {
        ctx.sendGraphError(err);
        return;
    };

    ctx.sendResult("Chat message deleted.");
}

/// Download an inline image (or other hosted content) from a Teams chat
/// message and write the bytes to a local temp file.
///
/// Inline images pasted into Teams chats live at:
///   GET /chats/{chatId}/messages/{msgId}/hostedContents/{contentId}/$value
///
/// You can call this two ways:
///   1. Pass `url` — the full https://graph.microsoft.com/.../hostedContents/.../$value
///      URL pulled straight from the message body's `<img src=...>`. Easiest
///      when the agent is parsing chat messages.
///   2. Pass `chatId` + `messageId` + `contentId` separately.
///
/// Optional `name` overrides the default filename. Returns `local_path:`
/// pointing at the saved file — same flow as download-email-attachment.
pub fn handleDownloadChatImage(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide either 'url' or all of chatId+messageId+contentId.") orelse return;

    const path = buildHostedContentPath(ctx, args, "/chats/", "chatId") orelse return;
    defer ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    const name_override = json_rpc.getStringArg(args, "name");
    const default_name = "chat-image.bin";
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

/// Build the hosted-content Graph path from either a `url` arg (parsed)
/// or the {scope}Id+messageId+contentId triple. `scope_prefix` is
/// "/chats/" for chat messages or "/teams/{teamId}/channels/{channelId}/"
/// for channel messages — caller passes the appropriate value.
///
/// Returns an allocated path the caller owns, or null on error (with
/// the error message already sent to the client).
fn buildHostedContentPath(
    ctx: ToolContext,
    args: std.json.ObjectMap,
    /// "/chats/" for chat messages. Channels use a different path-builder
    /// because they need teamId+channelId in the prefix; this helper just
    /// covers the simpler chat case where one identifier (chatId) leads
    /// the URL.
    scope_prefix: []const u8,
    /// "chatId" — the JSON arg name for the leading identifier when url
    /// isn't passed.
    leading_id_arg: []const u8,
) ?[]u8 {
    if (json_rpc.getStringArg(args, "url")) |url| {
        return parseHostedContentUrl(ctx.allocator, url) orelse {
            ctx.sendResult("Could not parse the hostedContents URL. Expected something like https://graph.microsoft.com/v1.0/chats/.../messages/.../hostedContents/.../$value");
            return null;
        };
    }

    const leading_id = json_rpc.getStringArg(args, leading_id_arg) orelse {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Missing '{s}' (or pass 'url' instead).", .{leading_id_arg}) catch "Missing identifier.";
        ctx.sendResult(msg);
        return null;
    };
    const message_id = json_rpc.getStringArg(args, "messageId") orelse {
        ctx.sendResult("Missing 'messageId' (or pass 'url' instead).");
        return null;
    };
    const content_id = json_rpc.getStringArg(args, "contentId") orelse {
        ctx.sendResult("Missing 'contentId' (or pass 'url' instead).");
        return null;
    };

    return std.fmt.allocPrint(
        ctx.allocator,
        "{s}{s}/messages/{s}/hostedContents/{s}/$value",
        .{ scope_prefix, leading_id, message_id, content_id },
    ) catch null;
}

/// Strip the Graph host prefix off a hosted-content URL, leaving the
/// path Graph helpers expect. We accept these two forms:
///   https://graph.microsoft.com/v1.0/chats/.../messages/.../hostedContents/.../$value
///   https://graph.microsoft.com/v1.0/teams/.../channels/.../messages/.../hostedContents/.../$value
fn parseHostedContentUrl(allocator: Allocator, url: []const u8) ?[]u8 {
    const v1_marker = "/v1.0";
    const idx = std.mem.indexOf(u8, url, v1_marker) orelse return null;
    const after_version = url[idx + v1_marker.len ..];
    if (after_version.len == 0 or after_version[0] != '/') return null;
    return allocator.dupe(u8, after_version) catch null;
}
