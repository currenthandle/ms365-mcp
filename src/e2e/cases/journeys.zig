// e2e/cases/journeys.zig — Cross-tool user journey tests.

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

/// Chat journey: search for the recipient by name, open a chat with them,
/// send a unique message, verify the Microsoft Search index picks it up
/// via search-chat-messages, then clean up. This is the workflow that
/// a sales/support agent would actually run — and the one that would
/// have caught the phase-11 softDelete hang end-to-end.
pub fn testChatJourneySearchAndSend(client: *McpClient) !void {
    const recipient_email = std.mem.span(std.c.getenv("E2E_ATTENDEE_REQUIRED").?);

    // --- search-users to discover the recipient's name and email ---
    // The recipient's "first.last@c3.ai" gives us a search query of
    // their first name.
    const dot_idx = std.mem.indexOfScalar(u8, recipient_email, '.') orelse recipient_email.len;
    const first_name = recipient_email[0..dot_idx];

    var search_buf: [512]u8 = undefined;
    const search_args = std.fmt.bufPrint(&search_buf, "{{\"query\":\"{s}\"}}", .{first_name}) catch return;
    const search = try client.callTool("search-users", search_args);
    defer search.deinit();
    const search_text = McpClient.getResultText(search) orelse {
        fail("chat-journey: search-users", "no text");
        return;
    };
    // Microsoft normalizes the email casing in search results (e.g.
    // "Ishaan.Gupta@c3.ai" vs the .env's lowercased version), so do
    // a case-insensitive contains check.
    if (!shared.containsIgnoreCase(search_text, recipient_email)) {
        fail("chat-journey: search-users", "recipient not in search results");
        return;
    }
    pass("chat-journey: search-users found recipient");

    // --- Self email for create-chat ---
    const profile = try client.callTool("get-profile", null);
    defer profile.deinit();
    const profile_text = McpClient.getResultText(profile) orelse {
        fail("chat-journey: get-profile", "no text");
        return;
    };
    const my_email = shared.extractFormattedField(client.allocator, profile_text, "mail: ") orelse
        shared.extractFormattedField(client.allocator, profile_text, "upn: ") orelse {
        fail("chat-journey: get-profile", "could not extract email");
        return;
    };
    defer client.allocator.free(my_email);

    // --- create-chat (idempotent — returns existing chat if any) ---
    var create_buf: [1024]u8 = undefined;
    const create_args = std.fmt.bufPrint(
        &create_buf,
        "{{\"emailOne\":\"{s}\",\"emailTwo\":\"{s}\"}}",
        .{ my_email, recipient_email },
    ) catch return;
    const create_chat = try client.callTool("create-chat", create_args);
    defer create_chat.deinit();
    const create_text = McpClient.getResultText(create_chat) orelse {
        fail("chat-journey: create-chat", "no text");
        return;
    };
    const chat_id = helpers.extractJsonString(client.allocator, create_text, "id") orelse {
        fail("chat-journey: create-chat", "no id in response");
        return;
    };
    defer client.allocator.free(chat_id);
    pass("chat-journey: create-chat");

    // --- send-chat-message with a unique token so we can find it via search ---
    // The token is deliberately nonsense to minimize false positives in
    // anyone else's chat index.
    const unique_token = "E2E-JOURNEY-PROBE-X7K9";
    var send_buf: [1024]u8 = undefined;
    const send_args = std.fmt.bufPrint(
        &send_buf,
        "{{\"chatId\":\"{s}\",\"message\":\"[DISREGARD AUTOMATED TEST] {s}\"}}",
        .{ chat_id, unique_token },
    ) catch return;
    const send = try client.callTool("send-chat-message", send_args);
    defer send.deinit();
    const send_text = McpClient.getResultText(send) orelse {
        fail("chat-journey: send-chat-message", "no text");
        return;
    };
    if (std.mem.indexOf(u8, send_text, "sent") == null) {
        fail("chat-journey: send-chat-message", send_text);
        return;
    }
    pass("chat-journey: send-chat-message");

    // --- search-chat-messages should find the probe via the MS Search index ---
    // Poll for up to 60s — the search index typically lags 5-20s behind
    // the send.
    var found_via_search = false;
    var sx_attempts: usize = 0;
    while (sx_attempts < 20 and !found_via_search) : (sx_attempts += 1) {
        _ = std.c.nanosleep(&.{ .sec = 3, .nsec = 0 }, null);
        var sx_buf: [512]u8 = undefined;
        const sx_args = std.fmt.bufPrint(&sx_buf, "{{\"query\":\"{s}\"}}", .{unique_token}) catch return;
        const sx = try client.callTool("search-chat-messages", sx_args);
        defer sx.deinit();
        const sx_text = McpClient.getResultText(sx) orelse continue;
        if (std.mem.indexOf(u8, sx_text, unique_token) != null) found_via_search = true;
    }
    if (found_via_search) {
        pass("chat-journey: search-chat-messages found probe");
    } else {
        fail("chat-journey: search-chat-messages", "probe never surfaced in search index after 60s");
    }

    // --- Clean up: list messages, find our probe, softDelete it ---
    var list_buf: [512]u8 = undefined;
    const list_args = std.fmt.bufPrint(&list_buf, "{{\"chatId\":\"{s}\",\"top\":\"10\"}}", .{chat_id}) catch return;
    const list = try client.callTool("list-chat-messages", list_args);
    defer list.deinit();
    const list_text = McpClient.getResultText(list) orelse return;
    const msg_id = helpers.findMessageByContent(client.allocator, list_text, unique_token) orelse {
        fail("chat-journey: cleanup", "could not find probe in list-chat-messages");
        return;
    };
    defer client.allocator.free(msg_id);

    var del_buf: [1024]u8 = undefined;
    const del_args = std.fmt.bufPrint(
        &del_buf,
        "{{\"chatId\":\"{s}\",\"messageId\":\"{s}\"}}",
        .{ chat_id, msg_id },
    ) catch return;
    const del = try client.callTool("delete-chat-message", del_args);
    defer del.deinit();
    const del_text = McpClient.getResultText(del) orelse {
        fail("chat-journey: delete-chat-message", "no text");
        return;
    };
    if (std.mem.indexOf(u8, del_text, "deleted") != null) {
        pass("chat-journey: delete-chat-message");
    } else {
        fail("chat-journey: delete-chat-message", del_text);
    }
}


/// Batch-delete smoke test: send a quick draft email to self, then
/// use batch-delete-emails to delete it. Also exercises the failure
/// path by passing one bogus id alongside the valid one.
pub fn testBatchDeleteEmails(client: *McpClient) !void {
    const test_email = std.mem.span(std.c.getenv("E2E_TEST_EMAIL").?);

    // Seed a test email via draft to avoid the long send-to-self delay.
    var draft_buf: [1024]u8 = undefined;
    const draft_args = std.fmt.bufPrint(
        &draft_buf,
        "{{\"to\":[\"{s}\"],\"subject\":\"[DISREGARD AUTOMATED TEST BATCH-DELETE]\",\"body\":\"batch-delete probe\"}}",
        .{test_email},
    ) catch return;
    const draft = try client.callTool("create-draft", draft_args);
    defer draft.deinit();
    const draft_text = McpClient.getResultText(draft) orelse {
        fail("batch-delete: setup", "no draft text");
        return;
    };
    const draft_id = helpers.extractAfterMarker(client.allocator, draft_text, "Draft ID: ") orelse
        helpers.extractId(client.allocator, draft_text) orelse {
        fail("batch-delete: setup", "no draft id");
        return;
    };
    defer client.allocator.free(draft_id);

    // Drafts live in the user's mailbox and are deletable via /messages/{id}.
    // Use batch-delete-emails with the draft id + one garbage id.
    var batch_buf: [2048]u8 = undefined;
    const batch_args = std.fmt.bufPrint(
        &batch_buf,
        "{{\"emailIds\":[\"{s}\",\"DEFINITELY-NOT-A-REAL-ID\"]}}",
        .{draft_id},
    ) catch return;
    const batch = try client.callTool("batch-delete-emails", batch_args);
    defer batch.deinit();
    const batch_text = McpClient.getResultText(batch) orelse {
        fail("batch-delete-emails", "no text");
        return;
    };
    if (std.mem.indexOf(u8, batch_text, "Deleted 1/2") != null or
        std.mem.indexOf(u8, batch_text, "1 failed") != null)
    {
        pass("batch-delete-emails (mixed success + failure)");
    } else {
        fail("batch-delete-emails", batch_text);
    }
}
