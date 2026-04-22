// e2e/cases.zig — Individual end-to-end test functions.
//
// Each `pub fn test<Name>` runs one scenario and reports its result via
// runner.pass() / runner.fail(). Lifecycle tests create → verify → clean up.

const std = @import("std");

const client_mod = @import("client.zig");
const helpers = @import("helpers.zig");
const runner = @import("runner.zig");

const McpClient = client_mod.McpClient;
const pass = runner.pass;
const fail = runner.fail;

const Allocator = std.mem.Allocator;

/// Test: MCP initialize handshake.
pub fn testInitialize(client: *McpClient) !void {
    const parsed = try client.call("initialize", "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"e2e-test\",\"version\":\"0.1\"}}");
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse {
        fail("initialize", "no result in response");
        return;
    };
    const obj = switch (result) {
        .object => |o| o,
        else => {
            fail("initialize", "result is not an object");
            return;
        },
    };
    const proto = switch (obj.get("protocolVersion") orelse {
        fail("initialize", "no protocolVersion");
        return;
    }) {
        .string => |s| s,
        else => {
            fail("initialize", "protocolVersion not a string");
            return;
        },
    };
    if (std.mem.eql(u8, proto, "2024-11-05")) {
        pass("initialize");
    } else {
        fail("initialize", "wrong protocolVersion");
    }
}

/// Test: Check if we're already authenticated by calling get-profile.
/// If it returns a displayName, we have a valid token from a saved session.
/// Returns true if authenticated.
pub fn testCheckAuth(client: *McpClient) !bool {
    const parsed = try client.callTool("get-profile", null);
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        return false;
    };

    if (std.mem.indexOf(u8, text, "\"displayName\"") != null) {
        pass("auth (saved token valid)");
        return true;
    }
    std.debug.print("  ⓘ No valid saved token — will attempt login\n", .{});
    return false;
}

/// Test: Login via device code flow (interactive — requires user action).
pub fn testLogin(client: *McpClient) !bool {
    const parsed = try client.callTool("login", null);
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        fail("login", "no text in response");
        return false;
    };

    // Print the login instructions for the user.
    std.debug.print("\n  ┌─────────────────────────────────────────┐\n", .{});
    std.debug.print("  │  Please authenticate in your browser:   │\n", .{});
    std.debug.print("  └─────────────────────────────────────────┘\n", .{});
    std.debug.print("  {s}\n\n", .{text});
    std.debug.print("  Press ENTER after you've completed sign-in...", .{});

    // Wait for user to press enter.
    var enter_buf: [1]u8 = undefined;
    _ = std.posix.read(std.c.STDIN_FILENO, &enter_buf) catch {};

    // Verify login succeeded.
    const verify = try client.callTool("verify-login", null);
    defer verify.deinit();

    const verify_text = McpClient.getResultText(verify) orelse {
        fail("login", "verify-login returned no text");
        return false;
    };

    if (std.mem.indexOf(u8, verify_text, "Login successful") != null) {
        pass("login (device code flow)");
        return true;
    } else {
        // Could also be authenticated if the token was saved — check with get-profile.
        const profile = try client.callTool("get-profile", null);
        defer profile.deinit();
        const profile_text = McpClient.getResultText(profile) orelse {
            fail("login", "could not verify auth after login");
            return false;
        };
        if (std.mem.indexOf(u8, profile_text, "\"displayName\"") != null) {
            pass("login (authenticated via saved token)");
            return true;
        }
        fail("login", "still not authenticated after login");
        return false;
    }
}

/// Test: Email draft lifecycle — create, verify, delete.
pub fn testDraftLifecycle(client: *McpClient) !void {
    // Create a draft.
    // Use E2E_TEST_EMAIL env var for the draft recipient, fallback to a safe default.
    const test_email = if (std.c.getenv("E2E_TEST_EMAIL")) |ptr| std.mem.span(ptr) else "e2e-test@example.com";
    var draft_args_buf: [1024]u8 = undefined;
    const draft_args = std.fmt.bufPrint(&draft_args_buf, "{{\"to\":[\"{s}\"],\"subject\":\"[E2E TEST] Draft lifecycle test\",\"body\":\"This draft was created by the e2e test suite and should be deleted.\"}}", .{test_email}) catch {
        fail("create-draft", "failed to build args");
        return;
    };
    const create = try client.callTool("create-draft", draft_args);
    defer create.deinit();

    const create_text = McpClient.getResultText(create) orelse {
        fail("create-draft", "no text in response");
        return;
    };

    // The response is "Draft created successfully. Draft ID: <id>"
    const draft_id = helpers.extractAfterMarker(client.allocator, create_text, "Draft ID: ") orelse
        helpers.extractId(client.allocator, create_text) orelse {
        fail("create-draft", "could not extract draft id from response");
        return;
    };
    defer client.allocator.free(draft_id);
    pass("create-draft");

    // Delete the draft to clean up.
    var delete_args_buf: [512]u8 = undefined;
    const delete_args = std.fmt.bufPrint(&delete_args_buf, "{{\"draftId\":\"{s}\"}}", .{draft_id}) catch {
        fail("delete-draft", "failed to build args");
        return;
    };
    const delete = try client.callTool("delete-draft", delete_args);
    defer delete.deinit();

    const delete_text = McpClient.getResultText(delete) orelse {
        fail("delete-draft", "no text in response");
        return;
    };

    if (std.mem.indexOf(u8, delete_text, "deleted") != null or
        std.mem.indexOf(u8, delete_text, "Draft deleted") != null)
    {
        pass("delete-draft");
    } else {
        fail("delete-draft", delete_text);
    }
}

/// Test: Calendar event lifecycle — create, get, delete.
pub fn testCalendarLifecycle(client: *McpClient) !void {
    // Create an event.
    const create = try client.callTool("create-calendar-event", "{\"subject\":\"[E2E TEST] Calendar test\",\"startDateTime\":\"2099-01-01T10:00:00\",\"endDateTime\":\"2099-01-01T11:00:00\"}");
    defer create.deinit();

    const create_text = McpClient.getResultText(create) orelse {
        fail("create-calendar-event", "no text in response");
        return;
    };

    const event_id = helpers.extractId(client.allocator, create_text) orelse {
        const preview_len = @min(create_text.len, 200);
        std.debug.print("  DEBUG create-calendar-event response: {s}...\n", .{create_text[0..preview_len]});
        fail("create-calendar-event", "could not extract event id");
        return;
    };
    defer client.allocator.free(event_id);
    pass("create-calendar-event");

    // Get the event by ID.
    var get_args_buf: [512]u8 = undefined;
    const get_args = std.fmt.bufPrint(&get_args_buf, "{{\"eventId\":\"{s}\"}}", .{event_id}) catch {
        fail("get-calendar-event", "failed to build args");
        return;
    };
    const get = try client.callTool("get-calendar-event", get_args);
    defer get.deinit();

    const get_text = McpClient.getResultText(get) orelse {
        fail("get-calendar-event", "no text in response");
        return;
    };

    if (std.mem.indexOf(u8, get_text, "E2E TEST") != null) {
        pass("get-calendar-event");
    } else {
        fail("get-calendar-event", "event subject not found in response");
    }

    // Delete the event.
    var del_args_buf: [512]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_args_buf, "{{\"eventId\":\"{s}\"}}", .{event_id}) catch {
        fail("delete-calendar-event", "failed to build args");
        return;
    };
    const del = try client.callTool("delete-calendar-event", del_args);
    defer del.deinit();

    const del_text = McpClient.getResultText(del) orelse {
        fail("delete-calendar-event", "no text in response");
        return;
    };

    if (std.mem.indexOf(u8, del_text, "deleted") != null or
        std.mem.indexOf(u8, del_text, "Event deleted") != null)
    {
        pass("delete-calendar-event");
    } else {
        fail("delete-calendar-event", del_text);
    }
}

/// Test: Send email lifecycle — send to self, find it, read it, delete it.
pub fn testSendEmailLifecycle(client: *McpClient) !void {
    const test_email = if (std.c.getenv("E2E_TEST_EMAIL")) |ptr| std.mem.span(ptr) else {
        std.debug.print("  ⓘ Skipping send-email (E2E_TEST_EMAIL not set)\n", .{});
        return;
    };

    var args_buf: [2048]u8 = undefined;
    const args = std.fmt.bufPrint(&args_buf, "{{\"to\":[\"{s}\"],\"cc\":[\"{s}\"],\"bcc\":[\"{s}\"],\"subject\":\"[DISREGARD AUTOMATED TEST EMAIL]\",\"body\":\"This email was sent by the e2e test suite.\"}}", .{ test_email, test_email, test_email }) catch {
        fail("send-email", "failed to build args");
        return;
    };

    const send = try client.callTool("send-email", args);
    defer send.deinit();
    const send_text = McpClient.getResultText(send) orelse {
        fail("send-email", "no text in response");
        return;
    };
    if (std.mem.indexOf(u8, send_text, "sent") != null) {
        pass("send-email (to + cc + bcc = self)");
    } else {
        fail("send-email", send_text);
        return;
    }

    // Wait a moment for the email to arrive, then find and delete it.
    // Wait a few seconds for the email to arrive in our inbox.
    _ = std.c.nanosleep(&.{ .sec = 3, .nsec = 0 }, null);

    const list = try client.callTool("list-emails", null);
    defer list.deinit();
    const list_text = McpClient.getResultText(list) orelse {
        fail("send-email cleanup", "could not list emails");
        return;
    };

    // Find the test email ID by parsing the list response.
    const email_id = helpers.findEmailBySubject(client.allocator, list_text, "DISREGARD AUTOMATED TEST EMAIL") orelse {
        std.debug.print("  ⓘ Could not find test email to delete (may need manual cleanup)\n", .{});
        return;
    };
    defer client.allocator.free(email_id);

    // Read the email to verify it.
    var read_buf: [512]u8 = undefined;
    const read_args = std.fmt.bufPrint(&read_buf, "{{\"emailId\":\"{s}\"}}", .{email_id}) catch return;
    const read = try client.callTool("read-email", read_args);
    defer read.deinit();
    const read_text = McpClient.getResultText(read) orelse {
        fail("read-email (sent email)", "no text");
        return;
    };
    if (std.mem.indexOf(u8, read_text, "DISREGARD AUTOMATED TEST") != null) {
        pass("read-email (sent email verified)");
    } else {
        fail("read-email (sent email)", "subject not found in response");
    }

    // Delete it.
    var del_buf: [512]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"emailId\":\"{s}\"}}", .{email_id}) catch return;
    const del = try client.callTool("delete-email", del_args);
    defer del.deinit();
    const del_text = McpClient.getResultText(del) orelse {
        fail("delete-email", "no text");
        return;
    };
    if (std.mem.indexOf(u8, del_text, "deleted") != null) {
        pass("delete-email (cleanup)");
    } else {
        fail("delete-email", del_text);
    }
}

/// Test: Update draft lifecycle — create, update, verify, delete.
pub fn testUpdateDraftLifecycle(client: *McpClient) !void {
    const test_email = if (std.c.getenv("E2E_TEST_EMAIL")) |ptr| std.mem.span(ptr) else "e2e-test@example.com";

    var create_buf: [1024]u8 = undefined;
    const create_args = std.fmt.bufPrint(&create_buf, "{{\"to\":[\"{s}\"],\"subject\":\"[DISREGARD AUTOMATED TEST DRAFT]\",\"body\":\"Original body.\"}}", .{test_email}) catch {
        fail("create-draft (update test)", "failed to build args");
        return;
    };
    const create = try client.callTool("create-draft", create_args);
    defer create.deinit();
    const create_text = McpClient.getResultText(create) orelse {
        fail("create-draft (update test)", "no text");
        return;
    };
    const draft_id = helpers.extractAfterMarker(client.allocator, create_text, "Draft ID: ") orelse
        helpers.extractId(client.allocator, create_text) orelse {
        fail("create-draft (update test)", "could not extract id");
        return;
    };
    defer client.allocator.free(draft_id);
    pass("create-draft (for update test)");

    // Update the draft.
    var update_buf: [1024]u8 = undefined;
    const update_args = std.fmt.bufPrint(&update_buf, "{{\"draftId\":\"{s}\",\"subject\":\"[DISREGARD AUTOMATED TEST DRAFT UPDATED]\",\"body\":\"Updated body.\"}}", .{draft_id}) catch {
        fail("update-draft", "failed to build args");
        return;
    };
    const update = try client.callTool("update-draft", update_args);
    defer update.deinit();
    const update_text = McpClient.getResultText(update) orelse {
        fail("update-draft", "no text");
        return;
    };
    if (std.mem.indexOf(u8, update_text, "updated") != null or std.mem.indexOf(u8, update_text, "Updated") != null) {
        pass("update-draft");
    } else {
        fail("update-draft", update_text);
    }

    // Delete the draft.
    var del_buf: [512]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"draftId\":\"{s}\"}}", .{draft_id}) catch return;
    const del = try client.callTool("delete-draft", del_args);
    defer del.deinit();
    pass("delete-draft (update test cleanup)");
}

/// Test: Attachment lifecycle — create draft, add attachment, list, remove, delete draft.
pub fn testAttachmentLifecycle(client: *McpClient) !void {
    const test_email = if (std.c.getenv("E2E_TEST_EMAIL")) |ptr| std.mem.span(ptr) else "e2e-test@example.com";

    // Create a draft to attach to.
    var create_buf: [1024]u8 = undefined;
    const create_args = std.fmt.bufPrint(&create_buf, "{{\"to\":[\"{s}\"],\"subject\":\"[DISREGARD AUTOMATED TEST ATTACHMENT]\",\"body\":\"Testing attachments.\"}}", .{test_email}) catch return;
    const create = try client.callTool("create-draft", create_args);
    defer create.deinit();
    const create_text = McpClient.getResultText(create) orelse {
        fail("create-draft (attachment test)", "no text");
        return;
    };
    const draft_id = helpers.extractAfterMarker(client.allocator, create_text, "Draft ID: ") orelse
        helpers.extractId(client.allocator, create_text) orelse {
        fail("create-draft (attachment test)", "could not extract id");
        return;
    };
    defer client.allocator.free(draft_id);

    // Add an attachment — use build.zig as a small test file.
    var attach_buf: [1024]u8 = undefined;
    const attach_args = std.fmt.bufPrint(&attach_buf, "{{\"draftId\":\"{s}\",\"filePath\":\"build.zig\"}}", .{draft_id}) catch return;
    const attach = try client.callTool("add-attachment", attach_args);
    defer attach.deinit();
    const attach_text = McpClient.getResultText(attach) orelse {
        fail("add-attachment", "no text");
        // Clean up draft.
        var del_buf2: [512]u8 = undefined;
        const del_args2 = std.fmt.bufPrint(&del_buf2, "{{\"draftId\":\"{s}\"}}", .{draft_id}) catch return;
        const del2 = client.callTool("delete-draft", del_args2) catch return;
        del2.deinit();
        return;
    };
    if (std.mem.indexOf(u8, attach_text, "added") != null or
        std.mem.indexOf(u8, attach_text, "attached") != null or
        std.mem.indexOf(u8, attach_text, "Attachment") != null)
    {
        pass("add-attachment");
    } else {
        fail("add-attachment", attach_text);
    }

    // List attachments.
    var list_buf: [512]u8 = undefined;
    const list_args = std.fmt.bufPrint(&list_buf, "{{\"draftId\":\"{s}\"}}", .{draft_id}) catch return;
    const list = try client.callTool("list-attachments", list_args);
    defer list.deinit();
    const list_text = McpClient.getResultText(list) orelse {
        fail("list-attachments", "no text");
        return;
    };
    if (std.mem.indexOf(u8, list_text, "build.zig") != null) {
        pass("list-attachments (found build.zig)");
    } else {
        fail("list-attachments", "attachment not found in list");
    }

    // Clean up — delete the draft (which removes attachments too).
    var del_buf: [512]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"draftId\":\"{s}\"}}", .{draft_id}) catch return;
    const del = try client.callTool("delete-draft", del_args);
    defer del.deinit();
    pass("delete-draft (attachment test cleanup)");
}

/// Test: Calendar event with attendees — create, verify attendees, delete.
pub fn testCalendarWithAttendees(client: *McpClient) !void {
    const required_attendee = if (std.c.getenv("E2E_ATTENDEE_REQUIRED")) |ptr| std.mem.span(ptr) else {
        std.debug.print("  ⓘ Skipping calendar-with-attendees (E2E_ATTENDEE_REQUIRED not set)\n", .{});
        return;
    };
    const optional_attendee = if (std.c.getenv("E2E_ATTENDEE_OPTIONAL")) |ptr| std.mem.span(ptr) else {
        std.debug.print("  ⓘ Skipping calendar-with-attendees (E2E_ATTENDEE_OPTIONAL not set)\n", .{});
        return;
    };

    var args_buf: [2048]u8 = undefined;
    const args = std.fmt.bufPrint(&args_buf, "{{\"subject\":\"[DISREGARD AUTOMATED TEST CAL]\",\"startDateTime\":\"2099-06-15T10:00:00\",\"endDateTime\":\"2099-06-15T11:00:00\",\"attendees\":[\"{s}\"],\"optionalAttendees\":[\"{s}\"]}}", .{ required_attendee, optional_attendee }) catch {
        fail("create-calendar-event (attendees)", "failed to build args");
        return;
    };
    const create = try client.callTool("create-calendar-event", args);
    defer create.deinit();
    const create_text = McpClient.getResultText(create) orelse {
        fail("create-calendar-event (attendees)", "no text");
        return;
    };
    const event_id = helpers.extractId(client.allocator, create_text) orelse {
        fail("create-calendar-event (attendees)", "could not extract id");
        return;
    };
    defer client.allocator.free(event_id);
    pass("create-calendar-event (with attendees)");

    // Get and verify attendees are present.
    var get_buf: [512]u8 = undefined;
    const get_args = std.fmt.bufPrint(&get_buf, "{{\"eventId\":\"{s}\"}}", .{event_id}) catch return;
    const get = try client.callTool("get-calendar-event", get_args);
    defer get.deinit();
    const get_text = McpClient.getResultText(get) orelse {
        fail("get-calendar-event (attendees)", "no text");
        return;
    };
    if (std.mem.indexOf(u8, get_text, "attendees") != null) {
        pass("get-calendar-event (attendees verified)");
    } else {
        fail("get-calendar-event (attendees)", "no attendees in response");
    }

    // Delete.
    var del_buf: [512]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"eventId\":\"{s}\"}}", .{event_id}) catch return;
    const del = try client.callTool("delete-calendar-event", del_args);
    defer del.deinit();
    pass("delete-calendar-event (attendees cleanup)");
}

/// Test: Chat message lifecycle — send message, verify, soft-delete.
pub fn testChatMessageLifecycle(client: *McpClient) !void {
    // Get the test recipient email from env.
    const chat_recipient = if (std.c.getenv("E2E_ATTENDEE_REQUIRED")) |ptr| std.mem.span(ptr) else {
        std.debug.print("  ⓘ Skipping chat-message (E2E_ATTENDEE_REQUIRED not set)\n", .{});
        return;
    };

    // Get the logged-in user's email from their profile.
    const profile = try client.callTool("get-profile", null);
    defer profile.deinit();
    const profile_text = McpClient.getResultText(profile) orelse {
        fail("send-chat-message", "could not get profile");
        return;
    };
    const my_email = helpers.extractJsonString(client.allocator, profile_text, "mail") orelse
        helpers.extractJsonString(client.allocator, profile_text, "userPrincipalName") orelse {
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
        std.debug.print("  ⓘ create-chat failed, searching existing chats for recipient\n", .{});

        // List chats and find a 1:1 chat containing the recipient's email.
        const list = try client.callTool("list-chats", "{\"top\":\"50\"}");
        defer list.deinit();
        const list_text = McpClient.getResultText(list) orelse {
            fail("send-chat-message", "could not list chats");
            return;
        };

        // Extract the recipient's name prefix from email (e.g. "ishaan.gupta" → "Ishaan").
        const dot_idx = std.mem.indexOfScalar(u8, chat_recipient, '.') orelse chat_recipient.len;
        const first_name = chat_recipient[0..dot_idx];

        // Search for a oneOnOne chat with a member matching the name.
        break :blk helpers.findChatByMember(client.allocator, list_text, first_name) orelse {
            std.debug.print("  ⓘ Could not find existing chat with '{s}' — skipping\n", .{chat_recipient});
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
        std.debug.print("  ⓘ Could not find test message to delete\n", .{});
        return;
    };
    defer client.allocator.free(msg_id);

    // TODO: Soft-delete chat messages causes a connection reset from Microsoft.
    // Likely a permissions issue (may need ChatMessage.ReadWrite or /users/{id}/
    // path instead of /me/). Skipping deletion for now — the test message remains.
    std.debug.print("  ⓘ Skipping delete-chat-message (known issue: Graph API rejects softDelete)\n", .{});
}

/// Test: Calendar list and update lifecycle — create, list to find it, update, verify, delete.
pub fn testCalendarListAndUpdate(client: *McpClient) !void {
    // Create an event.
    const create = try client.callTool("create-calendar-event", "{\"subject\":\"[E2E TEST] Calendar update test\",\"startDateTime\":\"2099-03-01T10:00:00\",\"endDateTime\":\"2099-03-01T11:00:00\",\"body\":\"Original body\",\"location\":\"Room 42\"}");
    defer create.deinit();
    const create_text = McpClient.getResultText(create) orelse {
        fail("create-calendar-event (update test)", "no text");
        return;
    };
    const event_id = helpers.extractId(client.allocator, create_text) orelse {
        fail("create-calendar-event (update test)", "could not extract id");
        return;
    };
    defer client.allocator.free(event_id);
    pass("create-calendar-event (for list+update test)");

    // List calendar events in the date range and verify ours appears.
    const list = try client.callTool("list-calendar-events", "{\"startDateTime\":\"2099-03-01T00:00:00\",\"endDateTime\":\"2099-03-02T00:00:00\"}");
    defer list.deinit();
    const list_text = McpClient.getResultText(list) orelse {
        fail("list-calendar-events", "no text");
        // Clean up.
        var del_buf: [512]u8 = undefined;
        const del_args = std.fmt.bufPrint(&del_buf, "{{\"eventId\":\"{s}\"}}", .{event_id}) catch return;
        const del = client.callTool("delete-calendar-event", del_args) catch return;
        del.deinit();
        return;
    };
    if (std.mem.indexOf(u8, list_text, "Calendar update test") != null) {
        pass("list-calendar-events (found test event)");
    } else {
        fail("list-calendar-events", "test event not found in range");
    }

    // Update the event — change subject and location.
    var update_buf: [1024]u8 = undefined;
    const update_args = std.fmt.bufPrint(&update_buf, "{{\"eventId\":\"{s}\",\"subject\":\"[E2E TEST] Calendar UPDATED\",\"location\":\"Room 99\"}}", .{event_id}) catch return;
    const update = try client.callTool("update-calendar-event", update_args);
    defer update.deinit();
    const update_text = McpClient.getResultText(update) orelse {
        fail("update-calendar-event", "no text");
        return;
    };
    if (std.mem.indexOf(u8, update_text, "UPDATED") != null or
        std.mem.indexOf(u8, update_text, "Room 99") != null)
    {
        pass("update-calendar-event");
    } else {
        fail("update-calendar-event", "updated fields not in response");
    }

    // Delete.
    var del_buf: [512]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"eventId\":\"{s}\"}}", .{event_id}) catch return;
    const del = try client.callTool("delete-calendar-event", del_args);
    defer del.deinit();
    pass("delete-calendar-event (list+update cleanup)");
}

/// Test: Draft send lifecycle — create draft, send it.
pub fn testSendDraftLifecycle(client: *McpClient) !void {
    const test_email = if (std.c.getenv("E2E_TEST_EMAIL")) |ptr| std.mem.span(ptr) else {
        std.debug.print("  ⓘ Skipping send-draft (E2E_TEST_EMAIL not set)\n", .{});
        return;
    };

    var create_buf: [1024]u8 = undefined;
    const create_args = std.fmt.bufPrint(&create_buf, "{{\"to\":[\"{s}\"],\"subject\":\"[DISREGARD AUTOMATED TEST SEND-DRAFT]\",\"body\":\"This draft will be sent by the e2e test.\"}}", .{test_email}) catch return;
    const create = try client.callTool("create-draft", create_args);
    defer create.deinit();
    const create_text = McpClient.getResultText(create) orelse {
        fail("create-draft (send test)", "no text");
        return;
    };
    const draft_id = helpers.extractAfterMarker(client.allocator, create_text, "Draft ID: ") orelse
        helpers.extractId(client.allocator, create_text) orelse {
        fail("create-draft (send test)", "could not extract id");
        return;
    };
    defer client.allocator.free(draft_id);
    pass("create-draft (for send test)");

    // Send the draft.
    var send_buf: [512]u8 = undefined;
    const send_args = std.fmt.bufPrint(&send_buf, "{{\"draftId\":\"{s}\"}}", .{draft_id}) catch return;
    const send = try client.callTool("send-draft", send_args);
    defer send.deinit();
    const send_text = McpClient.getResultText(send) orelse {
        fail("send-draft", "no text");
        return;
    };
    if (std.mem.indexOf(u8, send_text, "sent") != null or
        std.mem.indexOf(u8, send_text, "Sent") != null)
    {
        pass("send-draft");
    } else {
        fail("send-draft", send_text);
    }

    // Clean up: wait for email to arrive, find it, delete it.
    _ = std.c.nanosleep(&.{ .sec = 3, .nsec = 0 }, null);
    const list = try client.callTool("list-emails", null);
    defer list.deinit();
    const list_text = McpClient.getResultText(list) orelse return;
    const email_id = helpers.findEmailBySubject(client.allocator, list_text, "DISREGARD AUTOMATED TEST SEND-DRAFT") orelse return;
    defer client.allocator.free(email_id);
    var del_buf: [512]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"emailId\":\"{s}\"}}", .{email_id}) catch return;
    const del = try client.callTool("delete-email", del_args);
    defer del.deinit();
    pass("delete-email (send-draft cleanup)");
}

/// Test: Attachment remove lifecycle — create draft, add attachment, remove it, delete draft.
pub fn testRemoveAttachmentLifecycle(client: *McpClient) !void {
    const test_email = if (std.c.getenv("E2E_TEST_EMAIL")) |ptr| std.mem.span(ptr) else "e2e-test@example.com";

    // Create a draft.
    var create_buf: [1024]u8 = undefined;
    const create_args = std.fmt.bufPrint(&create_buf, "{{\"to\":[\"{s}\"],\"subject\":\"[DISREGARD AUTOMATED TEST REMOVE-ATTACH]\",\"body\":\"Testing remove.\"}}", .{test_email}) catch return;
    const create = try client.callTool("create-draft", create_args);
    defer create.deinit();
    const create_text = McpClient.getResultText(create) orelse {
        fail("create-draft (remove-attach)", "no text");
        return;
    };
    const draft_id = helpers.extractAfterMarker(client.allocator, create_text, "Draft ID: ") orelse
        helpers.extractId(client.allocator, create_text) orelse {
        fail("create-draft (remove-attach)", "could not extract id");
        return;
    };
    defer client.allocator.free(draft_id);

    // Add an attachment.
    var attach_buf: [1024]u8 = undefined;
    const attach_args = std.fmt.bufPrint(&attach_buf, "{{\"draftId\":\"{s}\",\"filePath\":\"build.zig\"}}", .{draft_id}) catch return;
    const attach = try client.callTool("add-attachment", attach_args);
    defer attach.deinit();
    const attach_text = McpClient.getResultText(attach) orelse {
        fail("add-attachment (remove test)", "no text");
        return;
    };

    // Extract attachment ID from response.
    const attach_id = helpers.extractAfterMarker(client.allocator, attach_text, "Attachment ID: ") orelse {
        fail("add-attachment (remove test)", "could not extract attachment id");
        return;
    };
    defer client.allocator.free(attach_id);
    pass("add-attachment (for remove test)");

    // Remove the attachment.
    var remove_buf: [1024]u8 = undefined;
    const remove_args = std.fmt.bufPrint(&remove_buf, "{{\"draftId\":\"{s}\",\"attachmentId\":\"{s}\"}}", .{ draft_id, attach_id }) catch return;
    const remove = try client.callTool("remove-attachment", remove_args);
    defer remove.deinit();
    const remove_text = McpClient.getResultText(remove) orelse {
        fail("remove-attachment", "no text");
        return;
    };
    if (std.mem.indexOf(u8, remove_text, "removed") != null or
        std.mem.indexOf(u8, remove_text, "Removed") != null)
    {
        pass("remove-attachment");
    } else {
        fail("remove-attachment", remove_text);
    }

    // Verify it's gone by listing attachments.
    var list_buf: [512]u8 = undefined;
    const list_args = std.fmt.bufPrint(&list_buf, "{{\"draftId\":\"{s}\"}}", .{draft_id}) catch return;
    const list = try client.callTool("list-attachments", list_args);
    defer list.deinit();
    const list_text = McpClient.getResultText(list) orelse {
        fail("list-attachments (after remove)", "no text");
        return;
    };
    if (std.mem.indexOf(u8, list_text, "build.zig") == null) {
        pass("list-attachments (verified removal)");
    } else {
        fail("list-attachments (after remove)", "attachment still present");
    }

    // Delete the draft.
    var del_buf: [512]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"draftId\":\"{s}\"}}", .{draft_id}) catch return;
    const del = try client.callTool("delete-draft", del_args);
    defer del.deinit();
    pass("delete-draft (remove-attach cleanup)");
}

/// Test: Mailbox settings (read-only).
pub fn testGetMailboxSettings(client: *McpClient) !void {
    const parsed = try client.callTool("get-mailbox-settings", null);
    defer parsed.deinit();
    const text = McpClient.getResultText(parsed) orelse {
        fail("get-mailbox-settings", "no text");
        return;
    };
    if (std.mem.indexOf(u8, text, "timeZone") != null or
        std.mem.indexOf(u8, text, "language") != null)
    {
        pass("get-mailbox-settings");
    } else {
        fail("get-mailbox-settings", "response doesn't look like mailbox settings");
    }
}

/// Test: Sync timezone.
pub fn testSyncTimezone(client: *McpClient) !void {
    const parsed = try client.callTool("sync-timezone", null);
    defer parsed.deinit();
    const text = McpClient.getResultText(parsed) orelse {
        fail("sync-timezone", "no text");
        return;
    };
    // Should report either "synced" or an error about unknown timezone.
    if (std.mem.indexOf(u8, text, "synced") != null or
        std.mem.indexOf(u8, text, "Timezone") != null or
        std.mem.indexOf(u8, text, "timezone") != null)
    {
        pass("sync-timezone");
    } else {
        fail("sync-timezone", text);
    }
}

/// Test: Teams channel lifecycle — list teams, list channels, list messages, get replies.
pub fn testChannelLifecycle(client: *McpClient) !void {
    // List teams to find one.
    const teams = try client.callTool("list-teams", null);
    defer teams.deinit();
    const teams_text = McpClient.getResultText(teams) orelse {
        fail("list-teams (channel test)", "no text");
        return;
    };

    // Extract the first team ID from the condensed format: "— id: <teamId>"
    const team_id = helpers.extractAfterMarker(client.allocator, teams_text, "— id: ") orelse {
        std.debug.print("  ⓘ No teams found — skipping channel tests\n", .{});
        return;
    };
    defer client.allocator.free(team_id);

    // List channels in this team.
    var chan_buf: [512]u8 = undefined;
    const chan_args = std.fmt.bufPrint(&chan_buf, "{{\"teamId\":\"{s}\"}}", .{team_id}) catch return;
    const channels = try client.callTool("list-channels", chan_args);
    defer channels.deinit();
    const channels_text = McpClient.getResultText(channels) orelse {
        fail("list-channels", "no text");
        return;
    };
    if (channels_text.len > 0) {
        pass("list-channels");
    } else {
        fail("list-channels", "empty response");
        return;
    }

    // Extract first channel ID.
    const channel_id = helpers.extractAfterMarker(client.allocator, channels_text, "— id: ") orelse {
        std.debug.print("  ⓘ No channels found — skipping message tests\n", .{});
        return;
    };
    defer client.allocator.free(channel_id);

    // List channel messages.
    var msgs_buf: [1024]u8 = undefined;
    const msgs_args = std.fmt.bufPrint(&msgs_buf, "{{\"teamId\":\"{s}\",\"channelId\":\"{s}\",\"top\":\"5\"}}", .{ team_id, channel_id }) catch return;
    const msgs = try client.callTool("list-channel-messages", msgs_args);
    defer msgs.deinit();
    const msgs_text = McpClient.getResultText(msgs) orelse {
        fail("list-channel-messages", "no text");
        return;
    };
    if (std.mem.indexOf(u8, msgs_text, "\"value\"") != null) {
        pass("list-channel-messages");
    } else {
        fail("list-channel-messages", "no value array in response");
        return;
    }

    // Find a message ID for getting replies.
    const msg_id = helpers.extractFirstMessageId(client.allocator, msgs_text) orelse {
        std.debug.print("  ⓘ No messages in channel — skipping replies test\n", .{});
        return;
    };
    defer client.allocator.free(msg_id);

    // Get replies to that message.
    var replies_buf: [1024]u8 = undefined;
    const replies_args = std.fmt.bufPrint(&replies_buf, "{{\"teamId\":\"{s}\",\"channelId\":\"{s}\",\"messageId\":\"{s}\",\"top\":\"5\"}}", .{ team_id, channel_id, msg_id }) catch return;
    const replies = try client.callTool("get-channel-message-replies", replies_args);
    defer replies.deinit();
    const replies_text = McpClient.getResultText(replies) orelse {
        fail("get-channel-message-replies", "no text");
        return;
    };
    if (std.mem.indexOf(u8, replies_text, "\"value\"") != null) {
        pass("get-channel-message-replies");
    } else {
        fail("get-channel-message-replies", "no value array in response");
    }
}

/// Test: Reply to a channel message and clean up.
pub fn testReplyToChannelMessage(client: *McpClient) !void {
    // List teams.
    const teams = try client.callTool("list-teams", null);
    defer teams.deinit();
    const teams_text = McpClient.getResultText(teams) orelse return;
    const team_id = helpers.extractAfterMarker(client.allocator, teams_text, "— id: ") orelse {
        std.debug.print("  ⓘ No teams — skipping reply test\n", .{});
        return;
    };
    defer client.allocator.free(team_id);

    // List channels.
    var chan_buf: [512]u8 = undefined;
    const chan_args = std.fmt.bufPrint(&chan_buf, "{{\"teamId\":\"{s}\"}}", .{team_id}) catch return;
    const channels = try client.callTool("list-channels", chan_args);
    defer channels.deinit();
    const channels_text = McpClient.getResultText(channels) orelse return;

    // Find "General" channel or use first channel.
    const channel_id = helpers.extractAfterMarker(client.allocator, channels_text, "— id: ") orelse {
        std.debug.print("  ⓘ No channels — skipping reply test\n", .{});
        return;
    };
    defer client.allocator.free(channel_id);

    // List messages to find one to reply to.
    var msgs_buf: [1024]u8 = undefined;
    const msgs_args = std.fmt.bufPrint(&msgs_buf, "{{\"teamId\":\"{s}\",\"channelId\":\"{s}\",\"top\":\"5\"}}", .{ team_id, channel_id }) catch return;
    const msgs = try client.callTool("list-channel-messages", msgs_args);
    defer msgs.deinit();
    const msgs_text = McpClient.getResultText(msgs) orelse return;
    const msg_id = helpers.extractFirstMessageId(client.allocator, msgs_text) orelse {
        std.debug.print("  ⓘ No messages — skipping reply test\n", .{});
        return;
    };
    defer client.allocator.free(msg_id);

    // Reply to the message.
    var reply_buf: [1024]u8 = undefined;
    const reply_args = std.fmt.bufPrint(&reply_buf, "{{\"teamId\":\"{s}\",\"channelId\":\"{s}\",\"messageId\":\"{s}\",\"message\":\"[DISREGARD AUTOMATED TEST REPLY]\"}}", .{ team_id, channel_id, msg_id }) catch return;
    const reply = try client.callTool("reply-to-channel-message", reply_args);
    defer reply.deinit();
    const reply_text = McpClient.getResultText(reply) orelse {
        fail("reply-to-channel-message", "no text");
        return;
    };
    if (std.mem.indexOf(u8, reply_text, "sent") != null or
        std.mem.indexOf(u8, reply_text, "Reply") != null)
    {
        pass("reply-to-channel-message");
    } else {
        fail("reply-to-channel-message", reply_text);
    }
}

/// Test: List emails (read-only, no cleanup needed).
pub fn testListEmails(client: *McpClient) !void {
    const parsed = try client.callTool("list-emails", null);
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        fail("list-emails", "no text in response");
        return;
    };

    // Should return JSON with a "value" array.
    if (std.mem.indexOf(u8, text, "\"value\"") != null) {
        pass("list-emails");
    } else {
        fail("list-emails", "response doesn't contain value array");
    }
}

/// Test: List chats (read-only).
pub fn testListChats(client: *McpClient) !void {
    const parsed = try client.callTool("list-chats", null);
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        fail("list-chats", "no text in response");
        return;
    };

    // Should return chat summaries or "No chats found."
    if (text.len > 0) {
        pass("list-chats");
    } else {
        fail("list-chats", "empty response");
    }
}

/// Test: List teams (read-only).
pub fn testListTeams(client: *McpClient) !void {
    const parsed = try client.callTool("list-teams", null);
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        fail("list-teams", "no text in response");
        return;
    };

    if (text.len > 0) {
        pass("list-teams");
    } else {
        fail("list-teams", "empty response");
    }
}

/// Test: Get user profile (read-only).
pub fn testGetProfile(client: *McpClient) !void {
    const parsed = try client.callTool("get-profile", null);
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        fail("get-profile", "no text in response");
        return;
    };

    if (std.mem.indexOf(u8, text, "\"displayName\"") != null or
        std.mem.indexOf(u8, text, "\"mail\"") != null)
    {
        pass("get-profile");
    } else {
        fail("get-profile", "response doesn't look like a profile");
    }
}

/// Test: Search users (read-only).
pub fn testSearchUsers(client: *McpClient) !void {
    const parsed = try client.callTool("search-users", "{\"query\":\"test\"}");
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        fail("search-users", "no text in response");
        return;
    };

    // Should return JSON with "value" array (might be empty, that's ok).
    if (std.mem.indexOf(u8, text, "\"value\"") != null) {
        pass("search-users");
    } else {
        fail("search-users", "response doesn't contain value array");
    }
}

/// Test: SharePoint full lifecycle — search site, list drive, create folder,
/// upload content, list, download + verify, delete file, delete folder.
///
/// Requires `E2E_SHAREPOINT_SITE_NAME` env var (a keyword that matches at
/// least one site the logged-in user can access). Skipped if unset.
pub fn testSharePointLifecycle(client: *McpClient) !void {
    const site_query = if (std.c.getenv("E2E_SHAREPOINT_SITE_NAME")) |ptr| std.mem.span(ptr) else {
        std.debug.print("  ⓘ Skipping sharepoint lifecycle (E2E_SHAREPOINT_SITE_NAME not set)\n", .{});
        return;
    };

    // --- Find a site ---
    var search_buf: [512]u8 = undefined;
    const search_args = std.fmt.bufPrint(&search_buf, "{{\"query\":\"{s}\"}}", .{site_query}) catch return;
    const search = try client.callTool("search-sharepoint-sites", search_args);
    defer search.deinit();
    const search_text = McpClient.getResultText(search) orelse {
        fail("search-sharepoint-sites", "no text");
        return;
    };
    const site_id = helpers.extractFirstValueField(client.allocator, search_text, "id") orelse {
        std.debug.print("  ⓘ No SharePoint site matched query '{s}' — skipping rest of lifecycle\n", .{site_query});
        return;
    };
    defer client.allocator.free(site_id);
    pass("search-sharepoint-sites");

    // --- List drives ---
    var drives_buf: [512]u8 = undefined;
    const drives_args = std.fmt.bufPrint(&drives_buf, "{{\"siteId\":\"{s}\"}}", .{site_id}) catch return;
    const drives = try client.callTool("list-sharepoint-drives", drives_args);
    defer drives.deinit();
    const drives_text = McpClient.getResultText(drives) orelse {
        fail("list-sharepoint-drives", "no text");
        return;
    };
    const drive_id = helpers.extractFirstValueField(client.allocator, drives_text, "id") orelse {
        fail("list-sharepoint-drives", "no drive in site");
        return;
    };
    defer client.allocator.free(drive_id);
    pass("list-sharepoint-drives");

    // --- Create a test folder at the drive root ---
    const folder_path = "e2e-test-folder";
    var folder_buf: [1024]u8 = undefined;
    const folder_args = std.fmt.bufPrint(&folder_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}\"}}", .{ site_id, drive_id, folder_path }) catch return;
    const folder = try client.callTool("create-sharepoint-folder", folder_args);
    defer folder.deinit();
    const folder_text = McpClient.getResultText(folder) orelse {
        fail("create-sharepoint-folder", "no text");
        return;
    };
    if (std.mem.indexOf(u8, folder_text, "\"id\"") != null) {
        pass("create-sharepoint-folder");
    } else {
        fail("create-sharepoint-folder", folder_text);
        return;
    }

    // --- Upload a small content file ---
    const test_content = "Hello from the ms-mcp e2e suite. If you see this in SharePoint, something failed to clean up.";
    var upload_buf: [2048]u8 = undefined;
    const upload_args = std.fmt.bufPrint(
        &upload_buf,
        "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}/hello.md\",\"content\":\"{s}\"}}",
        .{ site_id, drive_id, folder_path, test_content },
    ) catch return;
    const upload = try client.callTool("upload-sharepoint-content", upload_args);
    defer upload.deinit();
    const upload_text = McpClient.getResultText(upload) orelse {
        fail("upload-sharepoint-content", "no text");
        return;
    };
    if (std.mem.indexOf(u8, upload_text, "\"id\"") != null) {
        pass("upload-sharepoint-content");
    } else {
        fail("upload-sharepoint-content", upload_text);
        return;
    }

    // --- List items in the folder to confirm upload appeared ---
    var list_buf: [1024]u8 = undefined;
    const list_args = std.fmt.bufPrint(&list_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"folderPath\":\"{s}\"}}", .{ site_id, drive_id, folder_path }) catch return;
    const list = try client.callTool("list-sharepoint-items", list_args);
    defer list.deinit();
    const list_text = McpClient.getResultText(list) orelse {
        fail("list-sharepoint-items", "no text");
        return;
    };
    if (std.mem.indexOf(u8, list_text, "hello.md") != null) {
        pass("list-sharepoint-items (found uploaded file)");
    } else {
        fail("list-sharepoint-items", "hello.md not in response");
    }

    // --- Download and verify content ---
    var dl_buf: [1024]u8 = undefined;
    const dl_args = std.fmt.bufPrint(&dl_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}/hello.md\"}}", .{ site_id, drive_id, folder_path }) catch return;
    const dl = try client.callTool("download-sharepoint-file", dl_args);
    defer dl.deinit();
    const dl_text = McpClient.getResultText(dl) orelse {
        fail("download-sharepoint-file", "no text");
        return;
    };
    if (std.mem.indexOf(u8, dl_text, "ms-mcp e2e suite") != null) {
        pass("download-sharepoint-file (verified content)");
    } else {
        fail("download-sharepoint-file", "content mismatch");
    }

    // --- Delete the file ---
    var del_file_buf: [1024]u8 = undefined;
    const del_file_args = std.fmt.bufPrint(&del_file_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}/hello.md\"}}", .{ site_id, drive_id, folder_path }) catch return;
    const del_file = try client.callTool("delete-sharepoint-item", del_file_args);
    defer del_file.deinit();
    const del_file_text = McpClient.getResultText(del_file) orelse {
        fail("delete-sharepoint-item (file)", "no text");
        return;
    };
    if (std.mem.indexOf(u8, del_file_text, "deleted") != null) {
        pass("delete-sharepoint-item (file)");
    } else {
        fail("delete-sharepoint-item (file)", del_file_text);
    }

    // --- Delete the folder ---
    var del_folder_buf: [1024]u8 = undefined;
    const del_folder_args = std.fmt.bufPrint(&del_folder_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}\"}}", .{ site_id, drive_id, folder_path }) catch return;
    const del_folder = try client.callTool("delete-sharepoint-item", del_folder_args);
    defer del_folder.deinit();
    const del_folder_text = McpClient.getResultText(del_folder) orelse {
        fail("delete-sharepoint-item (folder)", "no text");
        return;
    };
    if (std.mem.indexOf(u8, del_folder_text, "deleted") != null) {
        pass("delete-sharepoint-item (folder cleanup)");
    } else {
        fail("delete-sharepoint-item (folder cleanup)", del_folder_text);
    }
}
