// tools/chat.zig — Teams chat tools.

const std = @import("std");
const types = @import("../types.zig");
const graph = @import("../graph.zig");
const json_rpc = @import("../json_rpc.zig");
const ToolContext = @import("context.zig").ToolContext;
const formatter = @import("../formatter.zig");

const Allocator = std.mem.Allocator;

// Fields surfaced from /me/chats/{id}/messages.
const chat_message_fields = [_]formatter.FieldSpec{
    .{ .path = "createdDateTime", .label = "sent" },
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

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch {
        ctx.sendResult("Failed to fetch chat messages.");
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

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch {
        ctx.sendResult("Failed to fetch chats.");
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

/// Send a message in a Teams chat.
pub fn handleSendChatMessage(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide chatId and message.") orelse return;
    const chat_id = ctx.getPathArg(args, "chatId", "Missing 'chatId' argument.") orelse return;
    const message = ctx.getStringArg(args, "message", "Missing 'message' argument.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/chats/{s}/messages", .{chat_id}) catch return;
    defer ctx.allocator.free(path);

    // Send as HTML so URLs become clickable hyperlinks.
    const html_content = types.htmlAutoLink(ctx.allocator, message) orelse message;
    defer if (html_content.ptr != message.ptr) ctx.allocator.free(html_content);

    const chat_msg = types.ChatMessageRequest{ .body = .{ .content = html_content } };
    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(chat_msg, .{}, &json_buf.writer) catch return;

    _ = graph.post(ctx.allocator, ctx.io, token, path, json_buf.written()) catch {
        ctx.sendResult("Failed to send chat message.");
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

    const response = graph.post(ctx.allocator, ctx.io, token, "/me/chats", json_body) catch {
        ctx.sendResult("Failed to create chat.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}

/// Soft-delete a chat message.
pub fn handleDeleteChatMessage(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide chatId and messageId.") orelse return;
    const chat_id = ctx.getPathArg(args, "chatId", "Missing 'chatId' argument.") orelse return;
    const message_id = ctx.getPathArg(args, "messageId", "Missing 'messageId' argument.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/chats/{s}/messages/{s}/softDelete", .{ chat_id, message_id }) catch return;
    defer ctx.allocator.free(path);

    _ = graph.post(ctx.allocator, ctx.io, token, path, "{}") catch {
        ctx.sendResult("Failed to delete chat message.");
        return;
    };

    ctx.sendResult("Chat message deleted.");
}
