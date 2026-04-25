// e2e/cases/chat.zig — Teams 1:1 chat tests.

const std = @import("std");

const client_mod = @import("../client.zig");
const helpers = @import("../helpers.zig");
const runner = @import("../runner.zig");
const shared = @import("shared.zig");

const McpClient = client_mod.McpClient;
const pass = runner.pass;
const fail = runner.fail;
const skip = runner.skip;

const Allocator = std.mem.Allocator;

/// Test: Chat message lifecycle — send message, verify, soft-delete.
pub fn testChatMessageLifecycle(client: *McpClient) !void {
    const chat_recipient = std.mem.span(std.c.getenv("E2E_ATTENDEE_REQUIRED").?);

    // Get the logged-in user's email from their profile.
    const profile = try client.callTool("get-profile", null);
    defer profile.deinit();
    const profile_text = McpClient.getResultText(profile) orelse {
        fail("send-chat-message", "could not get profile");
        return;
    };
    // Profile now comes through the formatter: "name: ... | mail: foo@bar | upn: ... | id: ..."
    // Extract the mail: field.
    const my_email = shared.extractFormattedField(client.allocator, profile_text, "mail: ") orelse
        shared.extractFormattedField(client.allocator, profile_text, "upn: ") orelse {
        fail("send-chat-message", "could not extract email from profile");
        return;
    };
    defer client.allocator.free(my_email);

    // Create or find a 1:1 chat with the recipient via create-chat.
    // The Graph API returns the existing chat if one already exists.
    var create_chat_buf: [1024]u8 = undefined;
    const create_chat_args = std.fmt.bufPrint(&create_chat_buf, "{{\"emailOne\":\"{s}\",\"emailTwo\":\"{s}\"}}", .{ my_email, chat_recipient }) catch return;
    const create_chat = try client.callTool("create-chat", create_chat_args);
    defer create_chat.deinit();
    const create_chat_text = McpClient.getResultText(create_chat) orelse {
        fail("send-chat-message", "could not create chat");
        return;
    };

    // Extract the chat ID from the response.
    // If create-chat fails (e.g. tenant policy), fall back to searching existing chats.
    const chat_id = helpers.extractJsonString(client.allocator, create_chat_text, "id") orelse blk: {
        // create-chat failed — fall back to listing + finding an existing chat.
        // The test still runs; we just skip the "create" half of the journey.
        const list = try client.callTool("list-chats", "{\"top\":\"50\"}");
        defer list.deinit();
        const list_text = McpClient.getResultText(list) orelse {
            fail("send-chat-message", "could not list chats");
            return;
        };

        const dot_idx = std.mem.indexOfScalar(u8, chat_recipient, '.') orelse chat_recipient.len;
        const first_name = chat_recipient[0..dot_idx];

        break :blk helpers.findChatByMember(client.allocator, list_text, first_name) orelse {
            skip("chat lifecycle", "create-chat failed and no existing 1:1 chat with recipient");
            return;
        };
    };
    defer client.allocator.free(chat_id);
    pass("find chat (1:1 with test recipient)");

    // Send a test message.
    var send_buf: [1024]u8 = undefined;
    const send_args = std.fmt.bufPrint(&send_buf, "{{\"chatId\":\"{s}\",\"message\":\"[DISREGARD AUTOMATED TEST MSG]\"}}", .{chat_id}) catch return;
    const send = try client.callTool("send-chat-message", send_args);
    defer send.deinit();
    const send_text = McpClient.getResultText(send) orelse {
        fail("send-chat-message", "no text");
        return;
    };
    if (std.mem.indexOf(u8, send_text, "sent") != null) {
        pass("send-chat-message");
    } else {
        fail("send-chat-message", send_text);
        return;
    }

    // List messages to find the one we just sent, then delete it.
    var msgs_buf: [512]u8 = undefined;
    const msgs_args = std.fmt.bufPrint(&msgs_buf, "{{\"chatId\":\"{s}\",\"top\":\"5\"}}", .{chat_id}) catch return;
    const msgs = try client.callTool("list-chat-messages", msgs_args);
    defer msgs.deinit();
    const msgs_text = McpClient.getResultText(msgs) orelse {
        fail("delete-chat-message", "could not list messages");
        return;
    };

    // Find our test message ID.
    const msg_id = helpers.findMessageByContent(client.allocator, msgs_text, "DISREGARD AUTOMATED TEST MSG") orelse {
        fail("delete-chat-message setup", "sent message was not visible in list-chat-messages");
        return;
    };
    defer client.allocator.free(msg_id);

    // Actually delete the message. This used to hang the MCP process
    // because graph.post() waited on a response body that the softDelete
    // endpoint never sends (it returns 204). graph.postNoContent fixes
    // that — if the server now hangs or crashes here, the client timeout
    // will surface it as a test failure instead of wedging the run.
    var del_buf: [1024]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"chatId\":\"{s}\",\"messageId\":\"{s}\"}}", .{ chat_id, msg_id }) catch return;
    const del = try client.callTool("delete-chat-message", del_args);
    defer del.deinit();
    const del_text = McpClient.getResultText(del) orelse {
        fail("delete-chat-message", "no text in response");
        return;
    };
    if (std.mem.indexOf(u8, del_text, "deleted") == null) {
        fail("delete-chat-message", del_text);
        return;
    }
    pass("delete-chat-message");

    // Verify softDelete took effect. Teams keeps the message row but
    // empties its body; the fragment should no longer appear. Poll for
    // up to 5s since the index can lag a beat behind the write.
    var verified = false;
    var verify_attempts: usize = 0;
    while (verify_attempts < 5 and !verified) : (verify_attempts += 1) {
        _ = std.c.nanosleep(&.{ .sec = 1, .nsec = 0 }, null);
        const msgs2 = try client.callTool("list-chat-messages", msgs_args);
        defer msgs2.deinit();
        const msgs2_text = McpClient.getResultText(msgs2) orelse continue;
        if (std.mem.indexOf(u8, msgs2_text, "DISREGARD AUTOMATED TEST MSG") == null) {
            verified = true;
        }
    }
    if (verified) {
        pass("delete-chat-message verified gone");
    } else {
        fail("delete-chat-message verify", "deleted message still visible in list after 5s");
    }
}

/// Tool-level test: search-chats finds a chat by participant name.
/// Uses E2E_ATTENDEE_REQUIRED — the chat lifecycle test above opens a
/// 1:1 chat with that recipient and Teams keeps the chat row even after
/// the test message is softDeleted, so search-chats should find it on
/// subsequent runs.
pub fn testSearchChats(client: *McpClient) !void {
    const recipient = std.mem.span(std.c.getenv("E2E_ATTENDEE_REQUIRED").?);
    const dot = std.mem.indexOfScalar(u8, recipient, '.') orelse recipient.len;
    const first_name = recipient[0..dot];

    var args_buf: [512]u8 = undefined;
    const args = std.fmt.bufPrint(&args_buf, "{{\"query\":\"{s}\"}}", .{first_name}) catch return;
    const search = try client.callTool("search-chats", args);
    defer search.deinit();
    const text = McpClient.getResultText(search) orelse {
        fail("search-chats", "no text");
        return;
    };

    if (std.mem.indexOf(u8, text, "id:") != null and shared.containsIgnoreCase(text, first_name)) {
        pass("search-chats found chat with recipient");
    } else if (std.mem.indexOf(u8, text, "No chats matched") != null) {
        skip("search-chats", "no chat with E2E_ATTENDEE_REQUIRED — run chat lifecycle first");
    } else {
        fail("search-chats", text);
    }
}
