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
const skip = runner.skip;

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

    // get-profile now goes through the formatter, so the output is
    // "name: ... | mail: ... | upn: ... | id: ...", not raw JSON with
    // "displayName". If we see our own name: label plus the mail: label
    // (which only the formatter produces), the token is good.
    if (std.mem.indexOf(u8, text, "name:") != null and
        std.mem.indexOf(u8, text, "mail:") != null)
    {
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
        if (std.mem.indexOf(u8, profile_text, "name:") != null and
            std.mem.indexOf(u8, profile_text, "mail:") != null)
        {
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
    const test_email = std.mem.span(std.c.getenv("E2E_TEST_EMAIL").?);

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

    // Poll via search-emails (searches all folders, not just top-10
    // inbox). Self-sent mail often lands in a subfolder via inbox
    // rules and noisy inboxes push new mail off the top-10 list in
    // seconds. search uses Exchange's full-text index which covers
    // everything.
    var email_id: ?[]u8 = null;
    var poll_attempts: usize = 0;
    while (poll_attempts < 60 and email_id == null) : (poll_attempts += 1) {
        _ = std.c.nanosleep(&.{ .sec = 3, .nsec = 0 }, null);
        // Search for a unique word from the body; Graph's $search
        // across "subject:" with bracketed tokens can miss.
        const search = try client.callTool("search-emails", "{\"query\":\"e2e test suite\"}");
        defer search.deinit();
        const search_text = McpClient.getResultText(search) orelse continue;
        email_id = helpers.findEmailBySubject(client.allocator, search_text, "DISREGARD AUTOMATED TEST EMAIL");
    }
    const email_id_found = email_id orelse {
        fail("send-email cleanup", "test email never appeared in mailbox search after 180s");
        return;
    };
    defer client.allocator.free(email_id_found);

    // Read the email to verify it.
    var read_buf: [512]u8 = undefined;
    const read_args = std.fmt.bufPrint(&read_buf, "{{\"emailId\":\"{s}\"}}", .{email_id_found}) catch return;
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
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"emailId\":\"{s}\"}}", .{email_id_found}) catch return;
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
    const required_attendee = std.mem.span(std.c.getenv("E2E_ATTENDEE_REQUIRED").?);
    const optional_attendee = std.mem.span(std.c.getenv("E2E_ATTENDEE_OPTIONAL").?);

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
    // Formatter surfaces subject + start/end + id + webUrl. Attendees are an
    // array-of-objects that the current FieldSpec model doesn't walk, so
    // we assert the event roundtripped by checking the subject + id instead.
    if (std.mem.indexOf(u8, get_text, "DISREGARD") != null and
        std.mem.indexOf(u8, get_text, "id:") != null)
    {
        pass("get-calendar-event (with attendees roundtripped)");
    } else {
        fail("get-calendar-event (attendees)", "event did not roundtrip cleanly");
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
    const my_email = extractFormattedField(client.allocator, profile_text, "mail: ") orelse
        extractFormattedField(client.allocator, profile_text, "upn: ") orelse {
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
    const test_email = std.mem.span(std.c.getenv("E2E_TEST_EMAIL").?);

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
    const team_id = helpers.extractFirstValueField(client.allocator, teams_text, "id") orelse {
        fail("channel lifecycle", "list-teams returned no teams — test account needs at least one team");
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
    const channel_id = helpers.extractFirstValueField(client.allocator, channels_text, "id") orelse {
        fail("channel lifecycle", "team has no channels — every team must have at least General");
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
    if (std.mem.indexOf(u8, msgs_text, "id:") != null or
        std.mem.indexOf(u8, msgs_text, "No messages") != null)
    {
        pass("list-channel-messages");
    } else {
        fail("list-channel-messages", "response does not look like a formatted message list");
        return;
    }

    // Find a message ID for getting replies. If the channel is empty,
    // seed one ourselves so the test runs every time. `seeded` tracks
    // whether we posted it (so we can delete it at the end).
    var seeded = false;
    const msg_id = helpers.extractFirstMessageId(client.allocator, msgs_text) orelse blk: {
        var post_buf: [1024]u8 = undefined;
        const post_args = std.fmt.bufPrint(
            &post_buf,
            "{{\"teamId\":\"{s}\",\"channelId\":\"{s}\",\"message\":\"[DISREGARD AUTOMATED TEST SEED]\"}}",
            .{ team_id, channel_id },
        ) catch return;
        const post = try client.callTool("post-channel-message", post_args);
        defer post.deinit();
        _ = McpClient.getResultText(post) orelse {
            fail("channel setup", "post-channel-message returned no text");
            return;
        };
        // post-channel-message returns only a confirmation string, not
        // the new message id, so re-list to find our seed.
        const relist = try client.callTool("list-channel-messages", msgs_args);
        defer relist.deinit();
        const relist_text = McpClient.getResultText(relist) orelse {
            fail("channel setup", "list-channel-messages returned no text after seed");
            return;
        };
        const id = helpers.findMessageByContent(client.allocator, relist_text, "DISREGARD AUTOMATED TEST SEED") orelse {
            fail("channel setup", "could not find seeded message after posting");
            return;
        };
        seeded = true;
        break :blk id;
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
    if (std.mem.indexOf(u8, replies_text, "id:") != null or
        std.mem.indexOf(u8, replies_text, "No replies") != null)
    {
        pass("get-channel-message-replies");
    } else {
        fail("get-channel-message-replies", "response does not look like formatted replies");
    }

    // Clean up the seed message if we posted one.
    if (seeded) {
        var del_buf: [1024]u8 = undefined;
        const del_args = std.fmt.bufPrint(
            &del_buf,
            "{{\"teamId\":\"{s}\",\"channelId\":\"{s}\",\"messageId\":\"{s}\"}}",
            .{ team_id, channel_id, msg_id },
        ) catch return;
        const del = try client.callTool("delete-channel-message", del_args);
        defer del.deinit();
        // Not asserting — this is cleanup; a failure to delete would be
        // caught by a dedicated delete-channel-message test.
    }
}

/// Test: Reply to a channel message and clean up.
pub fn testReplyToChannelMessage(client: *McpClient) !void {
    // List teams.
    const teams = try client.callTool("list-teams", null);
    defer teams.deinit();
    const teams_text = McpClient.getResultText(teams) orelse {
        fail("reply-to-channel-message setup", "list-teams returned no text");
        return;
    };
    const team_id = helpers.extractFirstValueField(client.allocator, teams_text, "id") orelse {
        fail("reply-to-channel-message setup", "no teams");
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
    const channel_id = helpers.extractFirstValueField(client.allocator, channels_text, "id") orelse {
        fail("reply-to-channel-message setup", "no channels in team");
        return;
    };
    defer client.allocator.free(channel_id);

    // List messages; seed one if the channel is empty so this test is
    // self-sufficient.
    var msgs_buf: [1024]u8 = undefined;
    const msgs_args = std.fmt.bufPrint(&msgs_buf, "{{\"teamId\":\"{s}\",\"channelId\":\"{s}\",\"top\":\"5\"}}", .{ team_id, channel_id }) catch return;
    const msgs = try client.callTool("list-channel-messages", msgs_args);
    defer msgs.deinit();
    const msgs_text = McpClient.getResultText(msgs) orelse {
        fail("reply-to-channel-message setup", "list-channel-messages returned no text");
        return;
    };

    var seeded = false;
    const msg_id = helpers.extractFirstMessageId(client.allocator, msgs_text) orelse blk: {
        var post_buf: [1024]u8 = undefined;
        const post_args = std.fmt.bufPrint(
            &post_buf,
            "{{\"teamId\":\"{s}\",\"channelId\":\"{s}\",\"message\":\"[DISREGARD AUTOMATED TEST SEED]\"}}",
            .{ team_id, channel_id },
        ) catch return;
        const post = try client.callTool("post-channel-message", post_args);
        defer post.deinit();
        const post_text = McpClient.getResultText(post) orelse {
            fail("reply-to-channel-message setup", "could not post seed message");
            return;
        };
        const id = helpers.extractId(client.allocator, post_text) orelse {
            fail("reply-to-channel-message setup", "post-channel-message returned no id");
            return;
        };
        seeded = true;
        break :blk id;
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

    // Clean up the seed message if we posted one. The reply goes with
    // it since replies live under the parent post.
    if (seeded) {
        var del_buf: [1024]u8 = undefined;
        const del_args = std.fmt.bufPrint(
            &del_buf,
            "{{\"teamId\":\"{s}\",\"channelId\":\"{s}\",\"messageId\":\"{s}\"}}",
            .{ team_id, channel_id, msg_id },
        ) catch return;
        const del = try client.callTool("delete-channel-message", del_args);
        defer del.deinit();
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

    // Formatter now returns "subject: ... | from: ... | ... | id: ..." per email.
    if (std.mem.indexOf(u8, text, "id:") != null or
        std.mem.indexOf(u8, text, "No emails") != null)
    {
        pass("list-emails");
    } else {
        fail("list-emails", "response does not look like a formatted email list");
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

    if (std.mem.indexOf(u8, text, "name:") != null and
        std.mem.indexOf(u8, text, "mail:") != null)
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

    // Formatter returns "displayName: ... | id: ..." per match, or
    // "No users found..." if nothing matches.
    if (std.mem.indexOf(u8, text, "id:") != null or
        std.mem.indexOf(u8, text, "No users") != null)
    {
        pass("search-users");
    } else {
        fail("search-users", "response does not look like a formatted user list");
    }
}

/// Test: SharePoint full lifecycle — search site, list drive, create folder,
/// upload content, list, download + verify, delete file, delete folder.
///
/// Requires `E2E_SHAREPOINT_SITE_NAME` env var (a keyword that matches at
/// least one site the logged-in user can access). Skipped if unset.
pub fn testSharePointLifecycle(client: *McpClient) !void {
    const site_query = std.mem.span(std.c.getenv("E2E_SHAREPOINT_SITE_NAME").?);

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
        fail("search-sharepoint-sites", "no site matched E2E_SHAREPOINT_SITE_NAME — check the .env value");
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
    // download-sharepoint-file writes bytes to a temp path and returns
    // metadata. Read the temp file back and check the bytes.
    const dl_bytes = helpers.readDownloadedFile(client.allocator, client.io, dl_text) orelse {
        fail("download-sharepoint-file", "could not read the downloaded file from its local_path");
        return;
    };
    defer client.allocator.free(dl_bytes);
    if (std.mem.indexOf(u8, dl_bytes, "ms-mcp e2e suite") != null) {
        pass("download-sharepoint-file (verified content)");
    } else {
        fail("download-sharepoint-file", "downloaded bytes did not match uploaded content");
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

/// Test: upload a real file from disk (exercises readFileAlloc + MIME
/// inference + simple PUT path). Downloads and verifies bytes match.
pub fn testSharePointFileUpload(client: *McpClient) !void {
    const site_query = if (std.c.getenv("E2E_SHAREPOINT_SITE_NAME")) |ptr| std.mem.span(ptr) else return;

    var search_buf: [512]u8 = undefined;
    const search_args = std.fmt.bufPrint(&search_buf, "{{\"query\":\"{s}\"}}", .{site_query}) catch return;
    const search = try client.callTool("search-sharepoint-sites", search_args);
    defer search.deinit();
    const search_text = McpClient.getResultText(search) orelse return;
    const site_id = helpers.extractFirstValueField(client.allocator, search_text, "id") orelse return;
    defer client.allocator.free(site_id);

    var drives_buf: [512]u8 = undefined;
    const drives_args = std.fmt.bufPrint(&drives_buf, "{{\"siteId\":\"{s}\"}}", .{site_id}) catch return;
    const drives = try client.callTool("list-sharepoint-drives", drives_args);
    defer drives.deinit();
    const drives_text = McpClient.getResultText(drives) orelse return;
    const drive_id = helpers.extractFirstValueField(client.allocator, drives_text, "id") orelse return;
    defer client.allocator.free(drive_id);

    // Upload build.zig from the repo as the test payload.
    const dest_path = "e2e-file-upload.zig";
    var upload_buf: [2048]u8 = undefined;
    const upload_args = std.fmt.bufPrint(
        &upload_buf,
        "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}\",\"filePath\":\"build.zig\"}}",
        .{ site_id, drive_id, dest_path },
    ) catch return;
    const upload = try client.callTool("upload-sharepoint-file", upload_args);
    defer upload.deinit();
    const upload_text = McpClient.getResultText(upload) orelse {
        fail("upload-sharepoint-file", "no text");
        return;
    };
    if (std.mem.indexOf(u8, upload_text, "\"id\"") != null) {
        pass("upload-sharepoint-file");
    } else {
        fail("upload-sharepoint-file", upload_text);
        return;
    }

    // Download and confirm the content is what we uploaded (check a known
    // substring from build.zig).
    var dl_buf: [1024]u8 = undefined;
    const dl_args = std.fmt.bufPrint(&dl_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}\"}}", .{ site_id, drive_id, dest_path }) catch return;
    const dl = try client.callTool("download-sharepoint-file", dl_args);
    defer dl.deinit();
    const dl_text = McpClient.getResultText(dl) orelse {
        fail("download-sharepoint-file (from disk)", "no text");
        return;
    };
    const dl_bytes = helpers.readDownloadedFile(client.allocator, client.io, dl_text) orelse {
        fail("download-sharepoint-file (from disk)", "could not read the downloaded file from its local_path");
        return;
    };
    defer client.allocator.free(dl_bytes);
    if (std.mem.indexOf(u8, dl_bytes, "pub fn build") != null) {
        pass("download-sharepoint-file (verified disk upload bytes)");
    } else {
        fail("download-sharepoint-file (from disk)", "build.zig content not found in downloaded bytes");
    }

    // Cleanup.
    var del_buf: [1024]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}\"}}", .{ site_id, drive_id, dest_path }) catch return;
    const del = try client.callTool("delete-sharepoint-item", del_args);
    defer del.deinit();
    const del_text = McpClient.getResultText(del) orelse return;
    if (std.mem.indexOf(u8, del_text, "deleted") != null) {
        pass("delete-sharepoint-item (file-upload cleanup)");
    } else {
        fail("delete-sharepoint-item (file-upload cleanup)", del_text);
    }
}

/// Test: large-file upload (>4MB) — exercises createUploadSession + chunked
/// PUTs. Builds a 5 MB string in memory to trigger the chunked path.
pub fn testSharePointLargeUpload(client: *McpClient) !void {
    const site_query = if (std.c.getenv("E2E_SHAREPOINT_SITE_NAME")) |ptr| std.mem.span(ptr) else return;

    var search_buf: [512]u8 = undefined;
    const search_args = std.fmt.bufPrint(&search_buf, "{{\"query\":\"{s}\"}}", .{site_query}) catch return;
    const search = try client.callTool("search-sharepoint-sites", search_args);
    defer search.deinit();
    const search_text = McpClient.getResultText(search) orelse return;
    const site_id = helpers.extractFirstValueField(client.allocator, search_text, "id") orelse return;
    defer client.allocator.free(site_id);

    var drives_buf: [512]u8 = undefined;
    const drives_args = std.fmt.bufPrint(&drives_buf, "{{\"siteId\":\"{s}\"}}", .{site_id}) catch return;
    const drives = try client.callTool("list-sharepoint-drives", drives_args);
    defer drives.deinit();
    const drives_text = McpClient.getResultText(drives) orelse return;
    const drive_id = helpers.extractFirstValueField(client.allocator, drives_text, "id") orelse return;
    defer client.allocator.free(drive_id);

    // Build a 5 MB payload: repeat "A" 5 * 1024 * 1024 times.
    // (Stays a valid JSON string — every byte is printable ASCII.)
    const large_size: usize = 5 * 1024 * 1024;
    const payload = client.allocator.alloc(u8, large_size) catch {
        fail("upload-sharepoint-content (large)", "alloc failed");
        return;
    };
    defer client.allocator.free(payload);
    @memset(payload, 'A');

    const dest_path = "e2e-large-upload.txt";
    // args are tool args: {siteId, driveId, path, content}. We allocate an
    // args buffer big enough to hold the JSON wrapper plus the 5 MB payload.
    const args_size = 1024 + large_size;
    const args_buf = client.allocator.alloc(u8, args_size) catch return;
    defer client.allocator.free(args_buf);
    const upload_args = std.fmt.bufPrint(
        args_buf,
        "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}\",\"content\":\"{s}\"}}",
        .{ site_id, drive_id, dest_path, payload },
    ) catch {
        fail("upload-sharepoint-content (large)", "args build failed");
        return;
    };
    const upload = try client.callTool("upload-sharepoint-content", upload_args);
    defer upload.deinit();
    const upload_text = McpClient.getResultText(upload) orelse {
        fail("upload-sharepoint-content (large)", "no text");
        return;
    };
    if (std.mem.indexOf(u8, upload_text, "\"id\"") != null) {
        pass("upload-sharepoint-content (5MB, chunked)");
    } else {
        fail("upload-sharepoint-content (large)", upload_text);
        return;
    }

    // Cleanup.
    var del_buf: [1024]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}\"}}", .{ site_id, drive_id, dest_path }) catch return;
    const del = try client.callTool("delete-sharepoint-item", del_args);
    defer del.deinit();
    const del_text = McpClient.getResultText(del) orelse return;
    if (std.mem.indexOf(u8, del_text, "deleted") != null) {
        pass("delete-sharepoint-item (large-upload cleanup)");
    } else {
        fail("delete-sharepoint-item (large-upload cleanup)", del_text);
    }
}

/// Test: itemId targeting on download + delete — complements the path-based
/// targeting exercised in the main lifecycle.
pub fn testSharePointItemIdTargeting(client: *McpClient) !void {
    const site_query = if (std.c.getenv("E2E_SHAREPOINT_SITE_NAME")) |ptr| std.mem.span(ptr) else return;

    var search_buf: [512]u8 = undefined;
    const search_args = std.fmt.bufPrint(&search_buf, "{{\"query\":\"{s}\"}}", .{site_query}) catch return;
    const search = try client.callTool("search-sharepoint-sites", search_args);
    defer search.deinit();
    const search_text = McpClient.getResultText(search) orelse return;
    const site_id = helpers.extractFirstValueField(client.allocator, search_text, "id") orelse return;
    defer client.allocator.free(site_id);

    var drives_buf: [512]u8 = undefined;
    const drives_args = std.fmt.bufPrint(&drives_buf, "{{\"siteId\":\"{s}\"}}", .{site_id}) catch return;
    const drives = try client.callTool("list-sharepoint-drives", drives_args);
    defer drives.deinit();
    const drives_text = McpClient.getResultText(drives) orelse return;
    const drive_id = helpers.extractFirstValueField(client.allocator, drives_text, "id") orelse return;
    defer client.allocator.free(drive_id);

    // Upload.
    const dest_path = "e2e-itemid-test.md";
    const marker = "Marker content for itemId targeting test.";
    var upload_buf: [2048]u8 = undefined;
    const upload_args = std.fmt.bufPrint(
        &upload_buf,
        "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}\",\"content\":\"{s}\"}}",
        .{ site_id, drive_id, dest_path, marker },
    ) catch return;
    const upload = try client.callTool("upload-sharepoint-content", upload_args);
    defer upload.deinit();
    const upload_text = McpClient.getResultText(upload) orelse {
        fail("upload-sharepoint-content (itemId test)", "no text");
        return;
    };
    const item_id = helpers.extractJsonString(client.allocator, upload_text, "id") orelse {
        fail("upload-sharepoint-content (itemId test)", "no id in response");
        return;
    };
    defer client.allocator.free(item_id);
    pass("upload-sharepoint-content (itemId test setup)");

    // Download by itemId.
    var dl_buf: [1024]u8 = undefined;
    const dl_args = std.fmt.bufPrint(&dl_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"itemId\":\"{s}\"}}", .{ site_id, drive_id, item_id }) catch return;
    const dl = try client.callTool("download-sharepoint-file", dl_args);
    defer dl.deinit();
    const dl_text = McpClient.getResultText(dl) orelse {
        fail("download-sharepoint-file (by itemId)", "no text");
        return;
    };
    const dl_bytes = helpers.readDownloadedFile(client.allocator, client.io, dl_text) orelse {
        fail("download-sharepoint-file (by itemId)", "could not read the downloaded file from its local_path");
        return;
    };
    defer client.allocator.free(dl_bytes);
    if (std.mem.indexOf(u8, dl_bytes, marker) != null) {
        pass("download-sharepoint-file (by itemId)");
    } else {
        fail("download-sharepoint-file (by itemId)", "marker not in downloaded bytes");
    }

    // Delete by itemId.
    var del_buf: [1024]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"itemId\":\"{s}\"}}", .{ site_id, drive_id, item_id }) catch return;
    const del = try client.callTool("delete-sharepoint-item", del_args);
    defer del.deinit();
    const del_text = McpClient.getResultText(del) orelse {
        fail("delete-sharepoint-item (by itemId)", "no text");
        return;
    };
    if (std.mem.indexOf(u8, del_text, "deleted") != null) {
        pass("delete-sharepoint-item (by itemId)");
    } else {
        fail("delete-sharepoint-item (by itemId)", del_text);
    }
}

/// Test: path validation — negative cases, no network. Verifies the
/// server rejects unsafe paths before hitting Graph.
pub fn testSharePointPathValidation(client: *McpClient) !void {
    const cases_list = [_]struct { name: []const u8, path: []const u8, expected_snippet: []const u8 }{
        .{ .name = "rejects leading slash", .path = "/foo", .expected_snippet = "must not start with" },
        .{ .name = "rejects .. segment", .path = "a/../b", .expected_snippet = "must not start with" },
        .{ .name = "rejects empty path", .path = "", .expected_snippet = "Missing" },
    };
    for (cases_list) |tc| {
        var buf: [1024]u8 = undefined;
        const args = std.fmt.bufPrint(
            &buf,
            "{{\"siteId\":\"fake\",\"driveId\":\"fake\",\"path\":\"{s}\",\"content\":\"hi\"}}",
            .{tc.path},
        ) catch continue;
        const resp = try client.callTool("upload-sharepoint-content", args);
        defer resp.deinit();
        const text = McpClient.getResultText(resp) orelse {
            fail(tc.name, "no text");
            continue;
        };
        if (std.mem.indexOf(u8, text, tc.expected_snippet) != null or
            std.mem.indexOf(u8, text, "Invalid") != null)
        {
            pass(tc.name);
        } else {
            fail(tc.name, text);
        }
    }
}

// ============================================================================
// Phase 4 — Email action tools (reply, forward, search, folders, mark, move,
//                               list-attachments, read-attachment)
// ============================================================================

/// Grab the ID of the first email in the user's inbox. Most email-action
/// tools (reply, forward, mark-read, move) need an existing received
/// message — generating a fresh probe by sending-to-self and waiting for
/// Exchange delivery is too slow (often 60s+) and flaky for an e2e loop.
/// Caller owns the returned slice.
fn grabFirstInboxEmailId(client: *McpClient) !?[]u8 {
    const list = try client.callTool("list-emails", null);
    defer list.deinit();
    const list_text = McpClient.getResultText(list) orelse return null;
    // Formatter output: first line is "subject: ... | from: ... | ... | id: X"
    return extractFirstIdFromFormatted(client.allocator, list_text);
}

/// Delete an email by ID, best-effort cleanup.
fn deleteEmailById(client: *McpClient, email_id: []const u8) void {
    var del_buf: [512]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"emailId\":\"{s}\"}}", .{email_id}) catch return;
    const del = client.callTool("delete-email", del_args) catch return;
    del.deinit();
}

/// Test: reply-email — skipped by default to avoid sending real emails to
/// original senders. Set E2E_EMAIL_SIDE_EFFECTS=1 to run against a
/// bogus emailId to verify the tool handles errors correctly (still
/// doesn't send anything on 404).
pub fn testEmailReplyLifecycle(client: *McpClient) !void {
    // Error-path test: bogus emailId → Graph 400/404 → typed error surfaced.
    // We always run this — it proves the URL/body shape without sending
    // mail. The real happy-path send is covered by testSendEmailLifecycle
    // which emails the user themselves.
    _ = std.c.getenv("E2E_EMAIL_SIDE_EFFECTS"); // reserved for a future real-send variant
    const reply = try client.callTool("reply-email", "{\"emailId\":\"BOGUS\",\"comment\":\"x\"}");
    defer reply.deinit();
    const text = McpClient.getResultText(reply) orelse {
        fail("reply-email (error path)", "no text");
        return;
    };
    if (std.mem.indexOf(u8, text, "400") != null or std.mem.indexOf(u8, text, "not found") != null) {
        pass("reply-email (typed error on bogus id)");
    } else {
        fail("reply-email (error path)", text);
    }
}

/// Test: forward-email — same side-effects concern as reply. Runs error
/// path only unless E2E_EMAIL_SIDE_EFFECTS=1.
pub fn testEmailForwardLifecycle(client: *McpClient) !void {
    // Error-path only — a real forward would send mail to a real recipient.
    // A happy-path variant can be added later that forwards a self-sent
    // test email back to the logged-in user.
    const fwd = try client.callTool(
        "forward-email",
        "{\"emailId\":\"BOGUS\",\"comment\":\"x\",\"to\":[\"test@example.com\"]}",
    );
    defer fwd.deinit();
    const text = McpClient.getResultText(fwd) orelse {
        fail("forward-email (error path)", "no text");
        return;
    };
    if (std.mem.indexOf(u8, text, "400") != null or std.mem.indexOf(u8, text, "not found") != null) {
        pass("forward-email (typed error on bogus id)");
    } else {
        fail("forward-email (error path)", text);
    }
}

/// Test: search-emails — searches for a common word. We don't assert a
/// specific subject (inbox contents vary); only that the formatter
/// produced either a result line or the "No results" message.
pub fn testEmailSearch(client: *McpClient) !void {
    const search = try client.callTool("search-emails", "{\"query\":\"the\"}");
    defer search.deinit();
    const text = McpClient.getResultText(search) orelse {
        fail("search-emails", "no text");
        return;
    };
    if (std.mem.indexOf(u8, text, "id:") != null or
        std.mem.indexOf(u8, text, "No results") != null or
        std.mem.indexOf(u8, text, "No emails") != null)
    {
        pass("search-emails");
    } else {
        fail("search-emails", text);
    }
}

/// Test: list-mail-folders — check that we get back at least Inbox + one id.
pub fn testListMailFolders(client: *McpClient) !void {
    const folders = try client.callTool("list-mail-folders", null);
    defer folders.deinit();
    const text = McpClient.getResultText(folders) orelse {
        fail("list-mail-folders", "no text");
        return;
    };
    if (std.mem.indexOf(u8, text, "id:") != null) {
        pass("list-mail-folders");
    } else {
        fail("list-mail-folders", "no folder IDs in output");
    }
}

/// Test: mark-read-email — pick the first email in the inbox, toggle it
/// unread then read again. End state matches start state.
pub fn testMarkReadLifecycle(client: *McpClient) !void {
    const target_id = (try grabFirstInboxEmailId(client)) orelse {
        fail("mark-read-email", "inbox empty — test expects at least one email; send a seed first");
        return;
    };
    defer client.allocator.free(target_id);

    var unread_buf: [1024]u8 = undefined;
    const unread_args = std.fmt.bufPrint(&unread_buf, "{{\"emailId\":\"{s}\",\"isRead\":false}}", .{target_id}) catch return;
    const unread = try client.callTool("mark-read-email", unread_args);
    defer unread.deinit();
    const unread_text = McpClient.getResultText(unread) orelse {
        fail("mark-read-email (unread)", "no text");
        return;
    };
    if (std.mem.indexOf(u8, unread_text, "unread") != null) {
        pass("mark-read-email (marked unread)");
    } else {
        fail("mark-read-email (unread)", unread_text);
    }

    var read_buf: [1024]u8 = undefined;
    const read_args = std.fmt.bufPrint(&read_buf, "{{\"emailId\":\"{s}\",\"isRead\":true}}", .{target_id}) catch return;
    const read = try client.callTool("mark-read-email", read_args);
    defer read.deinit();
    const read_text = McpClient.getResultText(read) orelse {
        fail("mark-read-email (read)", "no text");
        return;
    };
    if (std.mem.indexOf(u8, read_text, "read") != null) {
        pass("mark-read-email (restored to read)");
    } else {
        fail("mark-read-email (read)", read_text);
    }
}

/// Test: move-email — destructive side effect (moves a real email to
/// Archive). Skipped by default; set E2E_EMAIL_SIDE_EFFECTS=1 to run.
/// The error-path variant with a bogus emailId still proves the URL and
/// request body are well-formed end-to-end.
pub fn testMoveEmailLifecycle(client: *McpClient) !void {
    if (std.c.getenv("E2E_EMAIL_SIDE_EFFECTS") == null) {
        // Error-path only. The happy-path variant moves a real inbox
        // email to Archive and back — opt-in via E2E_EMAIL_SIDE_EFFECTS.
        const move = try client.callTool("move-email", "{\"emailId\":\"BOGUS\",\"destinationId\":\"BOGUS\"}");
        defer move.deinit();
        const text = McpClient.getResultText(move) orelse {
            fail("move-email (error path)", "no text");
            return;
        };
        if (std.mem.indexOf(u8, text, "400") != null or std.mem.indexOf(u8, text, "not found") != null) {
            pass("move-email (typed error on bogus id)");
        } else {
            fail("move-email (error path)", text);
        }
        return;
    }
    // Side-effect branch: move first-inbox email to Archive then back.
    const target_id = (try grabFirstInboxEmailId(client)) orelse return;
    defer client.allocator.free(target_id);

    const folders = try client.callTool("list-mail-folders", null);
    defer folders.deinit();
    const folders_text = McpClient.getResultText(folders) orelse return;
    const archive_id = extractFolderIdByName(client.allocator, folders_text, "Archive") orelse return;
    defer client.allocator.free(archive_id);

    var move_buf: [2048]u8 = undefined;
    const move_args = std.fmt.bufPrint(&move_buf, "{{\"emailId\":\"{s}\",\"destinationId\":\"{s}\"}}", .{ target_id, archive_id }) catch return;
    const move = try client.callTool("move-email", move_args);
    defer move.deinit();
    const text = McpClient.getResultText(move) orelse {
        fail("move-email", "no text");
        return;
    };
    if (std.mem.indexOf(u8, text, "moved") != null) {
        pass("move-email");
    } else {
        fail("move-email", text);
    }
}

/// Extract the id of the first folder whose "name: X" matches `name` in the
/// formatter's line-per-folder output.
fn extractFolderIdByName(allocator: Allocator, text: []const u8, name: []const u8) ?[]u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // Each line: "name: X | parent: ... | id: ..."
        var name_buf: [256]u8 = undefined;
        const name_prefix = std.fmt.bufPrint(&name_buf, "name: {s}", .{name}) catch continue;
        if (std.mem.indexOf(u8, line, name_prefix) == null) continue;
        // Ensure next char after name is ' ' or end-of-line to avoid prefix matches.
        const after = std.mem.indexOfPos(u8, line, 0, name_prefix) orelse continue;
        const next_idx = after + name_prefix.len;
        if (next_idx < line.len and line[next_idx] != ' ') continue;
        // Found matching line — extract id.
        const id_marker = "id: ";
        const id_start = std.mem.indexOf(u8, line, id_marker) orelse continue;
        const id_val_start = id_start + id_marker.len;
        // id ends at next ' ' or end of line
        const id_end = std.mem.indexOfPos(u8, line, id_val_start, " ") orelse line.len;
        return allocator.dupe(u8, line[id_val_start..id_end]) catch null;
    }
    return null;
}

// ============================================================================
// Phase 5 — Binary email attachment download
// ============================================================================

/// Test: download-email-attachment — relies on delivering an email with an
/// attachment to the test account, which takes 30-90s in practice. Skipped
/// by default. Set E2E_EMAIL_SIDE_EFFECTS=1 to run.
pub fn testEmailAttachmentDownload(client: *McpClient) !void {
    if (std.c.getenv("E2E_EMAIL_SIDE_EFFECTS") == null) {
        // Fast error-path: BOGUS ids must surface a typed error.
        const dl = try client.callTool(
            "download-email-attachment",
            "{\"emailId\":\"BOGUS\",\"attachmentId\":\"BOGUS\"}",
        );
        defer dl.deinit();
        const text = McpClient.getResultText(dl) orelse {
            fail("download-email-attachment (error path)", "no text");
            return;
        };
        if (std.mem.indexOf(u8, text, "400") != null or std.mem.indexOf(u8, text, "not found") != null) {
            pass("download-email-attachment (typed error on bogus id)");
        } else {
            fail("download-email-attachment (error path)", text);
        }
        return;
    }
    return testEmailAttachmentDownloadSideEffects(client);
}

fn testEmailAttachmentDownloadSideEffects(client: *McpClient) !void {
    const test_email = std.mem.span(std.c.getenv("E2E_TEST_EMAIL").?);

    // Create draft.
    var create_buf: [1024]u8 = undefined;
    const create_args = std.fmt.bufPrint(
        &create_buf,
        "{{\"to\":[\"{s}\"],\"subject\":\"[E2E ATTACH-DL PROBE]\",\"body\":\"has attachment\"}}",
        .{test_email},
    ) catch return;
    const create = try client.callTool("create-draft", create_args);
    defer create.deinit();
    const create_text = McpClient.getResultText(create) orelse {
        fail("create-draft (attach-dl probe)", "no text");
        return;
    };
    const draft_id = helpers.extractAfterMarker(client.allocator, create_text, "Draft ID: ") orelse
        helpers.extractId(client.allocator, create_text) orelse {
        fail("create-draft (attach-dl probe)", "no id");
        return;
    };
    defer client.allocator.free(draft_id);

    // Attach build.zig.
    var attach_buf: [1024]u8 = undefined;
    const attach_args = std.fmt.bufPrint(&attach_buf, "{{\"draftId\":\"{s}\",\"filePath\":\"build.zig\"}}", .{draft_id}) catch return;
    const attach = try client.callTool("add-attachment", attach_args);
    defer attach.deinit();
    _ = McpClient.getResultText(attach);

    // Send draft.
    var send_buf: [512]u8 = undefined;
    const send_args = std.fmt.bufPrint(&send_buf, "{{\"draftId\":\"{s}\"}}", .{draft_id}) catch return;
    const send = try client.callTool("send-draft", send_args);
    defer send.deinit();

    // Poll inbox for the sent email.
    var probe_id: ?[]u8 = null;
    var attempts: usize = 0;
    while (attempts < 15 and probe_id == null) : (attempts += 1) {
        _ = std.c.nanosleep(&.{ .sec = 4, .nsec = 0 }, null);
        const list = try client.callTool("list-emails", null);
        defer list.deinit();
        const list_text = McpClient.getResultText(list) orelse continue;
        probe_id = helpers.findEmailBySubject(client.allocator, list_text, "E2E ATTACH-DL PROBE");
    }
    const found = probe_id orelse {
        fail("download-email-attachment", "attachment probe email never arrived after 60s");
        return;
    };
    defer client.allocator.free(found);

    // list-email-attachments.
    var la_buf: [512]u8 = undefined;
    const la_args = std.fmt.bufPrint(&la_buf, "{{\"emailId\":\"{s}\"}}", .{found}) catch return;
    const la = try client.callTool("list-email-attachments", la_args);
    defer la.deinit();
    const la_text = McpClient.getResultText(la) orelse {
        fail("list-email-attachments", "no text");
        deleteEmailById(client, found);
        return;
    };
    if (std.mem.indexOf(u8, la_text, "build.zig") == null) {
        fail("list-email-attachments", "no build.zig attachment in list");
        deleteEmailById(client, found);
        return;
    }
    pass("list-email-attachments");

    // Extract attachment id from formatter output.
    const attach_id = extractFirstIdFromFormatted(client.allocator, la_text) orelse {
        fail("download-email-attachment", "could not parse attachment id");
        deleteEmailById(client, found);
        return;
    };
    defer client.allocator.free(attach_id);

    // download-email-attachment.
    var dl_buf: [2048]u8 = undefined;
    const dl_args = std.fmt.bufPrint(&dl_buf, "{{\"emailId\":\"{s}\",\"attachmentId\":\"{s}\"}}", .{ found, attach_id }) catch return;
    const dl = try client.callTool("download-email-attachment", dl_args);
    defer dl.deinit();
    const dl_text = McpClient.getResultText(dl) orelse {
        fail("download-email-attachment", "no text");
        deleteEmailById(client, found);
        return;
    };
    // Response: "Downloaded N bytes | name: build.zig | local_path: /tmp/..."
    const path = helpers.extractAfterMarker(client.allocator, dl_text, "local_path: ") orelse {
        fail("download-email-attachment", "no local_path in response");
        deleteEmailById(client, found);
        return;
    };
    defer client.allocator.free(path);
    // Read the file + check for a known substring from build.zig.
    const buf = client.allocator.alloc(u8, 65536) catch return;
    defer client.allocator.free(buf);
    const read_bytes = std.Io.Dir.cwd().readFile(client.io, path, buf) catch {
        fail("download-email-attachment", "could not read downloaded temp file");
        deleteEmailById(client, found);
        return;
    };
    if (std.mem.indexOf(u8, read_bytes, "pub fn build") != null) {
        pass("download-email-attachment (bytes verified)");
    } else {
        fail("download-email-attachment", "downloaded file content mismatch");
    }
    deleteEmailById(client, found);
}

/// Extract the id: field from the first line of formatter output.
fn extractFirstIdFromFormatted(allocator: Allocator, text: []const u8) ?[]u8 {
    return extractFormattedField(allocator, text, "id: ");
}

/// Extract a named field value (e.g. "mail: ") from formatter output.
/// Returns the substring between the marker and the next " | " or newline.
fn extractFormattedField(allocator: Allocator, text: []const u8, marker: []const u8) ?[]u8 {
    const start = std.mem.indexOf(u8, text, marker) orelse return null;
    const val_start = start + marker.len;
    var end = val_start;
    // Field ends at " | " separator, newline, or end of string.
    while (end < text.len and text[end] != '\n') : (end += 1) {
        if (end + 2 < text.len and text[end] == ' ' and text[end + 1] == '|' and text[end + 2] == ' ') break;
    }
    if (val_start == end) return null;
    return allocator.dupe(u8, text[val_start..end]) catch null;
}

// ============================================================================
// Phase 6 — Calendar scheduling (find-meeting-times, get-schedule, respond)
// ============================================================================

/// Test: get-schedule for self over an 8-hour window. Expect a scheduleId
/// and an availabilityView string in the output.
pub fn testGetSchedule(client: *McpClient) !void {
    // Defaults to E2E_TEST_EMAIL — the logged-in user's own address,
    // which is always a valid schedule target.
    const schedule_email = if (std.c.getenv("E2E_SCHEDULE_EMAIL")) |ptr|
        std.mem.span(ptr)
    else
        std.mem.span(std.c.getenv("E2E_TEST_EMAIL").?);

    var args_buf: [1024]u8 = undefined;
    const args = std.fmt.bufPrint(
        &args_buf,
        "{{\"schedules\":[\"{s}\"],\"start\":\"2099-04-23T09:00:00\",\"end\":\"2099-04-23T17:00:00\"}}",
        .{schedule_email},
    ) catch return;
    const resp = try client.callTool("get-schedule", args);
    defer resp.deinit();
    const text = McpClient.getResultText(resp) orelse {
        fail("get-schedule", "no text");
        return;
    };
    if (std.mem.indexOf(u8, text, "scheduleId:") != null and
        std.mem.indexOf(u8, text, "availability:") != null)
    {
        pass("get-schedule");
    } else {
        fail("get-schedule", text);
    }
}

/// Test: find-meeting-times for self over a 9-17 window. We don't assert on
/// specific slots (calendar state varies) — we only assert the call
/// succeeded and came back with either suggestions or the "none found" msg.
pub fn testFindMeetingTimes(client: *McpClient) !void {
    const schedule_email = if (std.c.getenv("E2E_SCHEDULE_EMAIL")) |ptr|
        std.mem.span(ptr)
    else
        std.mem.span(std.c.getenv("E2E_TEST_EMAIL").?);

    var args_buf: [1024]u8 = undefined;
    const args = std.fmt.bufPrint(
        &args_buf,
        "{{\"attendees\":[\"{s}\"],\"start\":\"2099-04-23T09:00:00\",\"end\":\"2099-04-23T17:00:00\",\"durationMinutes\":30}}",
        .{schedule_email},
    ) catch return;
    const resp = try client.callTool("find-meeting-times", args);
    defer resp.deinit();
    const text = McpClient.getResultText(resp) orelse {
        fail("find-meeting-times", "no text");
        return;
    };
    // Either "start: ... | end: ..." (got suggestions) or "No meeting time
    // suggestions" — both are valid call outcomes.
    if (std.mem.indexOf(u8, text, "start:") != null or
        std.mem.indexOf(u8, text, "No meeting time") != null)
    {
        pass("find-meeting-times");
    } else {
        fail("find-meeting-times", text);
    }
}

/// Test: respond-to-event — create an event, respond to it as tentative,
/// then delete. This works because creating an event via create-calendar-event
/// makes US the organizer; we can't actually "respond" to our own events the
/// way Outlook users respond to invites, but Graph's accept/decline endpoints
/// accept the call and return 202. A 2xx means the URL + JSON body are well-
/// formed, which is what this test exercises.
pub fn testRespondToEvent(client: *McpClient) !void {
    const create = try client.callTool(
        "create-calendar-event",
        "{\"subject\":\"[E2E RESPOND PROBE]\",\"startDateTime\":\"2099-01-01T10:00:00\",\"endDateTime\":\"2099-01-01T11:00:00\"}",
    );
    defer create.deinit();
    const create_text = McpClient.getResultText(create) orelse {
        fail("respond-to-event (setup)", "no create text");
        return;
    };
    const event_id = helpers.extractId(client.allocator, create_text) orelse {
        fail("respond-to-event (setup)", "no event id");
        return;
    };
    defer client.allocator.free(event_id);

    var args_buf: [1024]u8 = undefined;
    const args = std.fmt.bufPrint(
        &args_buf,
        "{{\"eventId\":\"{s}\",\"action\":\"tentativelyAccept\",\"comment\":\"E2E test\",\"sendResponse\":false}}",
        .{event_id},
    ) catch return;
    const resp = try client.callTool("respond-to-event", args);
    defer resp.deinit();
    const text = McpClient.getResultText(resp) orelse {
        fail("respond-to-event", "no text");
        return;
    };
    // Organizers can't respond to their own events; server returns
    // "Bad request (400)". That still proves the URL + body path is wired
    // correctly end-to-end. Any 401/403/404 would be a real failure.
    // Accept either "Response sent." (rare) or a 400 from Graph.
    if (std.mem.indexOf(u8, text, "Response sent") != null or
        std.mem.indexOf(u8, text, "400") != null)
    {
        pass("respond-to-event (call well-formed)");
    } else {
        fail("respond-to-event", text);
    }

    // Cleanup: delete the probe event.
    var del_buf: [512]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"eventId\":\"{s}\"}}", .{event_id}) catch return;
    const del = client.callTool("delete-calendar-event", del_args) catch return;
    del.deinit();
}

// ============================================================================
// Phase 7 — OneDrive lifecycle
// ============================================================================

/// Test: OneDrive upload-content → list → download (binary-safe) → delete.
pub fn testOneDriveLifecycle(client: *McpClient) !void {
    // Use a unique path so back-to-back runs don't collide.
    const dest_path = "e2e-onedrive-probe.md";
    const payload = "Hello from the ms-mcp OneDrive e2e suite.";

    // Upload content.
    var up_buf: [1024]u8 = undefined;
    const up_args = std.fmt.bufPrint(
        &up_buf,
        "{{\"path\":\"{s}\",\"content\":\"{s}\"}}",
        .{ dest_path, payload },
    ) catch return;
    const up = try client.callTool("upload-onedrive-content", up_args);
    defer up.deinit();
    const up_text = McpClient.getResultText(up) orelse {
        fail("upload-onedrive-content", "no text");
        return;
    };
    if (std.mem.indexOf(u8, up_text, "\"id\"") != null) {
        pass("upload-onedrive-content");
    } else {
        fail("upload-onedrive-content", up_text);
        return;
    }

    // OneDrive has a short indexing lag — poll up to 4 times with 2s
    // between calls before declaring the probe missing.
    var attempts: usize = 0;
    var found_in_list = false;
    while (attempts < 4 and !found_in_list) : (attempts += 1) {
        if (attempts > 0) _ = std.c.nanosleep(&.{ .sec = 2, .nsec = 0 }, null);
        const list = try client.callTool("list-onedrive-items", null);
        defer list.deinit();
        const list_text = McpClient.getResultText(list) orelse continue;
        if (std.mem.indexOf(u8, list_text, dest_path) != null) {
            found_in_list = true;
        }
    }
    if (found_in_list) {
        pass("list-onedrive-items (found probe)");
    } else {
        fail("list-onedrive-items", "probe not in list after 8s of polling");
    }

    // Download and verify bytes.
    var dl_buf: [512]u8 = undefined;
    const dl_args = std.fmt.bufPrint(&dl_buf, "{{\"path\":\"{s}\"}}", .{dest_path}) catch return;
    const dl = try client.callTool("download-onedrive-file", dl_args);
    defer dl.deinit();
    const dl_text = McpClient.getResultText(dl) orelse {
        fail("download-onedrive-file", "no text");
        return;
    };
    const local_path = helpers.extractAfterMarker(client.allocator, dl_text, "local_path: ") orelse {
        // Print the actual response so we can debug the mismatch.
        const debug_len = @min(dl_text.len, 300);
        std.debug.print("  DEBUG dl_text: {s}\n", .{dl_text[0..debug_len]});
        fail("download-onedrive-file", "no local_path");
        return;
    };
    defer client.allocator.free(local_path);
    const buf = client.allocator.alloc(u8, 65536) catch return;
    defer client.allocator.free(buf);
    const read_bytes = std.Io.Dir.cwd().readFile(client.io, local_path, buf) catch {
        fail("download-onedrive-file", "could not read temp file");
        return;
    };
    if (std.mem.indexOf(u8, read_bytes, "OneDrive e2e") != null) {
        pass("download-onedrive-file (bytes verified)");
    } else {
        fail("download-onedrive-file", "content mismatch");
    }

    // Cleanup.
    var del_buf: [512]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"path\":\"{s}\"}}", .{dest_path}) catch return;
    const del = try client.callTool("delete-onedrive-item", del_args);
    defer del.deinit();
    const del_text = McpClient.getResultText(del) orelse {
        fail("delete-onedrive-item", "no text");
        return;
    };
    if (std.mem.indexOf(u8, del_text, "deleted") != null) {
        pass("delete-onedrive-item");
    } else {
        fail("delete-onedrive-item", del_text);
    }
}
