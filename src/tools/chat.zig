// tools/chat.zig — Teams chat tools.

const std = @import("std");
const types = @import("../types.zig");
const graph = @import("../graph.zig");
const json_rpc = @import("../json_rpc.zig");
const state_mod = @import("../state.zig");
const ToolContext = @import("context.zig").ToolContext;

// Type aliases — keeps function signatures cleaner.
const Allocator = std.mem.Allocator;

/// Build a single member JSON object for the create-chat API.
/// Template string because the field names have @ characters
/// that can't be Zig struct field names.
/// `identifier` can be a user ID (GUID) or email address —
/// the Graph API accepts both in the users('...') binding.
fn buildMemberJson(allocator: Allocator, identifier: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"@odata.type":"#microsoft.graph.aadUserConversationMember","roles":["owner"],"user@odata.bind":"https://graph.microsoft.com/v1.0/users('{s}')"}}
    , .{identifier});
}

/// List recent messages in a Teams chat by chat ID.
pub fn handleListChatMessages(ctx: ToolContext) void {
    // Check that the user is logged in.
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    // Get the tool arguments — we need "chatId".
    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing arguments. Provide chatId." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // "chatId" — the ID of the chat to read messages from.
    // The LLM gets this from the list-chats results.
    const chat_id = json_rpc.getStringArg(args, "chatId") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'chatId' argument." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // Build the path with the chatId baked in.
    // $top=20 — get the 20 most recent messages
    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/me/chats/{s}/messages?$top=20",
        .{chat_id},
    ) catch return;
    defer ctx.allocator.free(path);

    // GET the messages.
    const response_body = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        std.debug.print("ms-mcp: list-chat-messages failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to fetch chat messages." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    defer ctx.allocator.free(response_body);

    // Return the raw JSON — the LLM will summarize it.
    const content: []const types.TextContent = &.{
        .{ .text = response_body },
    };
    const result = types.ToolCallResult{ .content = content };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = result,
    });
}

/// List recent Teams chats with condensed member summaries.
pub fn handleListChats(ctx: ToolContext) void {
    // Check that the user is logged in.
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    // Call Graph API to list the user's Teams chats.
    // $expand=members includes participant names in the response.
    const response_body = graph.get(
        ctx.allocator, ctx.io, token,
        "/me/chats?$top=20&$select=id,topic,chatType,lastUpdatedDateTime&$expand=members",
    ) catch |err| {
        std.debug.print("ms-mcp: list-chats failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to fetch chats." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    defer ctx.allocator.free(response_body);

    // Parse the raw JSON so we can build a condensed summary.
    // The raw response with $expand=members is ~135k tokens —
    // way too much for the LLM's context window.
    const chats_parsed = std.json.parseFromSlice(
        std.json.Value, ctx.allocator, response_body, .{},
    ) catch {
        const content: []const types.TextContent = &.{
            .{ .text = response_body },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    defer chats_parsed.deinit();

    // Build a condensed plain-text summary.
    // One line per chat: "[type] Topic — Members — id: ..."
    var summary_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer summary_buf.deinit();
    const sw = &summary_buf.writer;

    // Get the "value" array from the response — that's the list of chats.
    const chats_root = switch (chats_parsed.value) {
        .object => |o| o,
        else => return,
    };
    const chats_array = switch (chats_root.get("value") orelse return) {
        .array => |a| a,
        else => return,
    };

    // Loop through each chat and extract the key fields.
    for (chats_array.items) |chat_val| {
        const chat = switch (chat_val) {
            .object => |o| o,
            else => continue,
        };

        // Chat type: oneOnOne, group, or meeting.
        const chat_type = switch (chat.get("chatType") orelse continue) {
            .string => |s| s,
            else => "unknown",
        };

        // Topic — may be null for 1:1 chats.
        const topic = switch (chat.get("topic") orelse .null) {
            .string => |s| s,
            .null => "(no topic)",
            else => "(no topic)",
        };

        // Chat ID — needed to send messages or read history.
        const chat_id = switch (chat.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };

        // Write the chat type and topic.
        sw.print("[{s}] {s}", .{ chat_type, topic }) catch continue;

        // Extract member display names from the expanded members array.
        if (chat.get("members")) |members_val| {
            const members = switch (members_val) {
                .array => |a| a,
                else => null,
            };
            if (members) |member_list| {
                sw.writeAll(" — ") catch continue;
                for (member_list.items, 0..) |member_val, i| {
                    const member = switch (member_val) {
                        .object => |o| o,
                        else => continue,
                    };
                    // "displayName" is the human-readable name.
                    const display_name = switch (member.get("displayName") orelse continue) {
                        .string => |s| s,
                        else => continue,
                    };
                    if (i > 0) sw.writeAll(", ") catch continue;
                    sw.writeAll(display_name) catch continue;
                }
            }
        }

        // Write the chat ID last — the LLM needs this to send messages.
        sw.print(" — id: {s}\n", .{chat_id}) catch continue;
    }

    // Return the condensed summary.
    const summary = summary_buf.written();
    const content: []const types.TextContent = &.{
        .{ .text = if (summary.len > 0) summary else "No chats found." },
    };
    const result = types.ToolCallResult{ .content = content };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = result,
    });
}

/// Send a message in a Teams chat.
pub fn handleSendChatMessage(ctx: ToolContext) void {
    // Check that the user is logged in.
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    // Get the tool arguments — we need "chatId" and "message".
    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing arguments. Provide chatId and message." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // "chatId" — which chat to send the message to.
    const chat_id = json_rpc.getStringArg(args, "chatId") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'chatId' argument." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // "message" — the text to send.
    const message = json_rpc.getStringArg(args, "message") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'message' argument." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // Build the path: /me/chats/{chatId}/messages
    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/me/chats/{s}/messages",
        .{chat_id},
    ) catch return;
    defer ctx.allocator.free(path);

    // Build the request body using a typed struct.
    // Send as HTML so URLs become clickable hyperlinks.
    const html_content = types.htmlAutoLink(ctx.allocator, message) orelse message;
    const chat_msg = types.ChatMessageRequest{
        .body = .{ .content = html_content },
    };

    // Serialize the struct to JSON.
    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(chat_msg, .{}, &json_buf.writer) catch return;
    const json_body = json_buf.written();

    // POST the message.
    _ = graph.post(ctx.allocator, ctx.io, token, path, json_body) catch |err| {
        std.debug.print("ms-mcp: send-chat-message failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to send chat message." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // Success!
    const content: []const types.TextContent = &.{
        .{ .text = "Chat message sent." },
    };
    const result = types.ToolCallResult{ .content = content };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = result,
    });
}

/// Create or find an existing 1:1 Teams chat between two users.
pub fn handleCreateChat(ctx: ToolContext) void {
    // Check that the user is logged in.
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    // Get the two email addresses.
    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing arguments. Provide emailOne and emailTwo." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // "emailOne" — first member's email (use search-users to find it).
    const email_one = json_rpc.getStringArg(args, "emailOne") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'emailOne' argument." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // "emailTwo" — second member's email.
    const email_two = json_rpc.getStringArg(args, "emailTwo") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'emailTwo' argument." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // Build the two member JSON objects using the helper.
    // buildMemberJson accepts both emails and GUIDs —
    // the Graph API users('...') binding works with either.
    const member1 = buildMemberJson(ctx.allocator, email_one) catch return;
    defer ctx.allocator.free(member1);
    const member2 = buildMemberJson(ctx.allocator, email_two) catch return;
    defer ctx.allocator.free(member2);

    // Assemble the full request body.
    // chatType is "oneOnOne", members is the two member objects.
    const json_body = std.fmt.allocPrint(ctx.allocator,
        \\{{"chatType":"oneOnOne","members":[{s},{s}]}}
    , .{ member1, member2 }) catch return;
    defer ctx.allocator.free(json_body);

    // POST /me/chats — creates the chat or returns existing one.
    const response_body = graph.post(ctx.allocator, ctx.io, token, "/me/chats", json_body) catch |err| {
        std.debug.print("ms-mcp: create-chat failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to create chat." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    defer ctx.allocator.free(response_body);

    // Return the response — includes the chat ID.
    const content: []const types.TextContent = &.{
        .{ .text = response_body },
    };
    const result = types.ToolCallResult{ .content = content };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = result,
    });
}
