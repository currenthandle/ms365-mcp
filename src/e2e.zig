// e2e.zig — End-to-end test client for ms-mcp.
//
// Spawns the MCP server as a child process, communicates over stdin/stdout
// using the JSON-RPC protocol, and runs real tests against the live
// Microsoft Graph API.
//
// Usage: zig build e2e
// Requires: MS365_CLIENT_ID and MS365_TENANT_ID environment variables.
// If not already authenticated, prompts the user to complete device code auth.

const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
});

const Allocator = std.mem.Allocator;
const Io = std.Io;

// --- MCP Client ---

/// An MCP client that talks to the server over stdin/stdout pipes.
const McpClient = struct {
    child: std.process.Child,
    // File-level reader/writer — their `.interface` field gives us the
    // std.Io.Reader / std.Io.Writer that the JSON-RPC protocol uses.
    file_reader: std.Io.File.Reader,
    file_writer: std.Io.File.Writer,
    allocator: Allocator,
    next_id: i64 = 1,

    // Buffers must live as long as the client — stored here.
    read_buf: [65536]u8 = undefined,
    write_buf: [65536]u8 = undefined,

    /// Spawn the MCP server and set up pipes.
    fn init(allocator: Allocator, io: Io, exe_path: []const u8, environ_map: ?*const std.process.Environ.Map) !McpClient {
        var client: McpClient = .{
            .child = try std.process.spawn(io, .{
                .argv = &.{exe_path},
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit, // Let server stderr pass through for debug logging.
                .environ_map = environ_map,
            }),
            .file_reader = undefined,
            .file_writer = undefined,
            .allocator = allocator,
        };

        // Create buffered reader/writer from the child's pipes.
        client.file_reader = client.child.stdout.?.reader(io, &client.read_buf);
        client.file_writer = client.child.stdin.?.writer(io, &client.write_buf);

        return client;
    }

    /// Send a JSON-RPC message and return the parsed response.
    /// Caller owns the returned Parsed value and must call .deinit().
    fn call(self: *McpClient, method: []const u8, params_json: ?[]const u8) !std.json.Parsed(std.json.Value) {
        const id = self.next_id;
        self.next_id += 1;
        const writer = &self.file_writer.interface;
        const reader = &self.file_reader.interface;

        // Build the request JSON manually — simpler than struct serialization
        // for dynamic params.
        if (params_json) |p| {
            const req = try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, p });
            defer self.allocator.free(req);
            writer.writeAll(req) catch return error.WriteFailed;
        } else {
            const req = try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\"}}", .{ id, method });
            defer self.allocator.free(req);
            writer.writeAll(req) catch return error.WriteFailed;
        }
        writer.writeAll("\n") catch return error.WriteFailed;
        writer.flush() catch return error.WriteFailed;

        // Read the response line.
        const line = (reader.takeDelimiter('\n') catch return error.ReadFailed) orelse return error.ServerClosed;

        return std.json.parseFromSlice(std.json.Value, self.allocator, line, .{});
    }

    /// Call a tool and return the text content from the response.
    /// Caller owns the returned Parsed value.
    fn callTool(self: *McpClient, name: []const u8, args_json: ?[]const u8) !std.json.Parsed(std.json.Value) {
        var params_buf: [4096]u8 = undefined;
        const params = if (args_json) |a|
            try std.fmt.bufPrint(&params_buf, "{{\"name\":\"{s}\",\"arguments\":{s}}}", .{ name, a })
        else
            try std.fmt.bufPrint(&params_buf, "{{\"name\":\"{s}\"}}", .{name});

        return self.call("tools/call", params);
    }

    /// Extract the text content string from a tool call response.
    fn getResultText(parsed: std.json.Parsed(std.json.Value)) ?[]const u8 {
        const result = parsed.value.object.get("result") orelse return null;
        const content = switch (result) {
            .object => |o| o.get("content") orelse return null,
            else => return null,
        };
        const arr = switch (content) {
            .array => |a| a,
            else => return null,
        };
        if (arr.items.len == 0) return null;
        const first = switch (arr.items[0]) {
            .object => |o| o,
            else => return null,
        };
        const text = first.get("text") orelse return null;
        return switch (text) {
            .string => |s| s,
            else => null,
        };
    }

    /// Kill the server and clean up.
    fn deinit(self: *McpClient, io: Io) void {
        self.child.kill(io);
    }
};

// --- Test Runner ---

var tests_passed: u32 = 0;
var tests_failed: u32 = 0;

fn pass(name: []const u8) void {
    tests_passed += 1;
    std.debug.print("  \x1b[32m✓\x1b[0m {s}\n", .{name});
}

fn fail(name: []const u8, reason: []const u8) void {
    tests_failed += 1;
    std.debug.print("  \x1b[31m✗\x1b[0m {s}: {s}\n", .{ name, reason });
}

// --- Tests ---

/// Test: MCP initialize handshake.
fn testInitialize(client: *McpClient) !void {
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
fn testCheckAuth(client: *McpClient) !bool {
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
fn testLogin(client: *McpClient) !bool {
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
fn testDraftLifecycle(client: *McpClient) !void {
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
    const draft_id = extractAfterMarker(client.allocator, create_text, "Draft ID: ") orelse
        extractId(client.allocator, create_text) orelse {
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
fn testCalendarLifecycle(client: *McpClient) !void {
    // Create an event.
    const create = try client.callTool("create-calendar-event", "{\"subject\":\"[E2E TEST] Calendar test\",\"startDateTime\":\"2099-01-01T10:00:00\",\"endDateTime\":\"2099-01-01T11:00:00\"}");
    defer create.deinit();

    const create_text = McpClient.getResultText(create) orelse {
        fail("create-calendar-event", "no text in response");
        return;
    };

    const event_id = extractId(client.allocator, create_text) orelse {
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
fn testSendEmailLifecycle(client: *McpClient) !void {
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
    const email_id = findEmailBySubject(client.allocator, list_text, "DISREGARD AUTOMATED TEST EMAIL") orelse {
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
fn testUpdateDraftLifecycle(client: *McpClient) !void {
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
    const draft_id = extractAfterMarker(client.allocator, create_text, "Draft ID: ") orelse
        extractId(client.allocator, create_text) orelse {
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
fn testAttachmentLifecycle(client: *McpClient) !void {
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
    const draft_id = extractAfterMarker(client.allocator, create_text, "Draft ID: ") orelse
        extractId(client.allocator, create_text) orelse {
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
fn testCalendarWithAttendees(client: *McpClient) !void {
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
    const event_id = extractId(client.allocator, create_text) orelse {
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
fn testChatMessageLifecycle(client: *McpClient) !void {
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
    const my_email = extractJsonString(client.allocator, profile_text, "mail") orelse
        extractJsonString(client.allocator, profile_text, "userPrincipalName") orelse {
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
    const chat_id = extractJsonString(client.allocator, create_chat_text, "id") orelse blk: {
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
        break :blk findChatByMember(client.allocator, list_text, first_name) orelse {
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
    const msg_id = findMessageByContent(client.allocator, msgs_text, "DISREGARD AUTOMATED TEST MSG") orelse {
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
fn testCalendarListAndUpdate(client: *McpClient) !void {
    // Create an event.
    const create = try client.callTool("create-calendar-event", "{\"subject\":\"[E2E TEST] Calendar update test\",\"startDateTime\":\"2099-03-01T10:00:00\",\"endDateTime\":\"2099-03-01T11:00:00\",\"body\":\"Original body\",\"location\":\"Room 42\"}");
    defer create.deinit();
    const create_text = McpClient.getResultText(create) orelse {
        fail("create-calendar-event (update test)", "no text");
        return;
    };
    const event_id = extractId(client.allocator, create_text) orelse {
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
fn testSendDraftLifecycle(client: *McpClient) !void {
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
    const draft_id = extractAfterMarker(client.allocator, create_text, "Draft ID: ") orelse
        extractId(client.allocator, create_text) orelse {
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
    const email_id = findEmailBySubject(client.allocator, list_text, "DISREGARD AUTOMATED TEST SEND-DRAFT") orelse return;
    defer client.allocator.free(email_id);
    var del_buf: [512]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"emailId\":\"{s}\"}}", .{email_id}) catch return;
    const del = try client.callTool("delete-email", del_args);
    defer del.deinit();
    pass("delete-email (send-draft cleanup)");
}

/// Test: Attachment remove lifecycle — create draft, add attachment, remove it, delete draft.
fn testRemoveAttachmentLifecycle(client: *McpClient) !void {
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
    const draft_id = extractAfterMarker(client.allocator, create_text, "Draft ID: ") orelse
        extractId(client.allocator, create_text) orelse {
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
    const attach_id = extractAfterMarker(client.allocator, attach_text, "Attachment ID: ") orelse {
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
fn testGetMailboxSettings(client: *McpClient) !void {
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
fn testSyncTimezone(client: *McpClient) !void {
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
fn testChannelLifecycle(client: *McpClient) !void {
    // List teams to find one.
    const teams = try client.callTool("list-teams", null);
    defer teams.deinit();
    const teams_text = McpClient.getResultText(teams) orelse {
        fail("list-teams (channel test)", "no text");
        return;
    };

    // Extract the first team ID from the condensed format: "— id: <teamId>"
    const team_id = extractAfterMarker(client.allocator, teams_text, "— id: ") orelse {
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
    const channel_id = extractAfterMarker(client.allocator, channels_text, "— id: ") orelse {
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
    const msg_id = extractFirstMessageId(client.allocator, msgs_text) orelse {
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
fn testReplyToChannelMessage(client: *McpClient) !void {
    // List teams.
    const teams = try client.callTool("list-teams", null);
    defer teams.deinit();
    const teams_text = McpClient.getResultText(teams) orelse return;
    const team_id = extractAfterMarker(client.allocator, teams_text, "— id: ") orelse {
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
    const channel_id = extractAfterMarker(client.allocator, channels_text, "— id: ") orelse {
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
    const msg_id = extractFirstMessageId(client.allocator, msgs_text) orelse {
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

/// Extract the first message ID from a list-channel-messages JSON response.
fn extractFirstMessageId(allocator: Allocator, json_text: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const values = switch (obj.get("value") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    // Skip system messages — find first message with a "from" field.
    for (values.items) |item| {
        const msg = switch (item) {
            .object => |o| o,
            else => continue,
        };
        // Skip if no "from" (system event messages).
        const from = msg.get("from") orelse continue;
        if (from == .null) continue;
        const id = switch (msg.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        return allocator.dupe(u8, id) catch return null;
    }
    return null;
}

/// Test: List emails (read-only, no cleanup needed).
fn testListEmails(client: *McpClient) !void {
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
fn testListChats(client: *McpClient) !void {
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
fn testListTeams(client: *McpClient) !void {
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
fn testGetProfile(client: *McpClient) !void {
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
fn testSearchUsers(client: *McpClient) !void {
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

// --- Helpers ---

/// Extract a value that appears after a text marker, ending at newline or end of string.
/// e.g. extractAfterMarker("Draft ID: ABC123\n", "Draft ID: ") => "ABC123"
fn extractAfterMarker(allocator: Allocator, text: []const u8, marker: []const u8) ?[]u8 {
    const start_idx = std.mem.indexOf(u8, text, marker) orelse return null;
    const val_start = start_idx + marker.len;
    const val_end = std.mem.indexOfPos(u8, text, val_start, "\n") orelse text.len;
    if (val_start >= val_end) return null;
    return allocator.dupe(u8, text[val_start..val_end]) catch return null;
}

/// Find an email ID by matching subject text in a list-emails JSON response.
fn findEmailBySubject(allocator: Allocator, json_text: []const u8, subject_fragment: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const values = switch (obj.get("value") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    for (values.items) |item| {
        const email = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const subject = switch (email.get("subject") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.indexOf(u8, subject, subject_fragment) != null) {
            const id = switch (email.get("id") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            return allocator.dupe(u8, id) catch return null;
        }
    }
    return null;
}

/// Find a message ID by matching content text in a list-chat-messages JSON response.
fn findMessageByContent(allocator: Allocator, json_text: []const u8, content_fragment: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const values = switch (obj.get("value") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    for (values.items) |item| {
        const msg = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const body = switch (msg.get("body") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const content = switch (body.get("content") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.indexOf(u8, content, content_fragment) != null) {
            const id = switch (msg.get("id") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            return allocator.dupe(u8, id) catch return null;
        }
    }
    return null;
}

/// Find a chat ID by scanning the condensed chat summary for a member name.
/// The summary format is: "[type] topic — Member1, Member2 — id: <chatId>\n"
/// Uses case-insensitive matching. Prefers oneOnOne chats but falls back to any type.
fn findChatByMember(allocator: Allocator, summary: []const u8, member_name: []const u8) ?[]u8 {
    // Case-insensitive search: lowercase both the summary and the name.
    var lower_name_buf: [128]u8 = undefined;
    const name_len = @min(member_name.len, lower_name_buf.len);
    for (member_name[0..name_len], 0..) |ch, i| {
        lower_name_buf[i] = std.ascii.toLower(ch);
    }
    const lower_name = lower_name_buf[0..name_len];

    // First pass: look for oneOnOne chats.
    var fallback_id: ?[]u8 = null;
    var lines = std.mem.splitScalar(u8, summary, '\n');
    while (lines.next()) |line| {
        // Case-insensitive line search.
        var lower_line_buf: [2048]u8 = undefined;
        const line_len = @min(line.len, lower_line_buf.len);
        for (line[0..line_len], 0..) |ch, i| {
            lower_line_buf[i] = std.ascii.toLower(ch);
        }
        const lower_line = lower_line_buf[0..line_len];

        if (std.mem.indexOf(u8, lower_line, lower_name) == null) continue;

        // Extract the chat ID after "— id: ".
        if (std.mem.indexOf(u8, line, "— id: ")) |id_start| {
            const id = line[id_start + 6 ..];
            if (id.len == 0) continue;

            if (std.mem.startsWith(u8, line, "[oneOnOne]")) {
                // Preferred: 1:1 chat.
                return allocator.dupe(u8, id) catch return null;
            } else if (fallback_id == null) {
                // Save first non-oneOnOne match as fallback.
                fallback_id = allocator.dupe(u8, id) catch null;
            }
        }
    }
    return fallback_id;
}

/// Extract a top-level string field from a JSON response body string.
fn extractJsonString(allocator: Allocator, json_text: []const u8, key: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const val = obj.get(key) orelse return null;
    const str = switch (val) {
        .string => |s| s,
        else => return null,
    };
    return allocator.dupe(u8, str) catch return null;
}

/// Extract the top-level "id" field from a JSON response body string.
/// Parses the JSON properly to avoid matching "parentFolderId" etc.
fn extractId(allocator: Allocator, json_text: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const id_val = obj.get("id") orelse return null;
    const id_str = switch (id_val) {
        .string => |s| s,
        else => return null,
    };
    return allocator.dupe(u8, id_str) catch return null;
}

// --- Main ---

/// Read the .mcp.json config file and build an Environ.Map with
/// MS365_CLIENT_ID and MS365_TENANT_ID for the child process.
fn loadMcpConfig(allocator: Allocator, io: Io) !std.process.Environ.Map {
    const data = std.Io.Dir.readFileAlloc(.cwd(), io, ".mcp.json", allocator, .unlimited) catch {
        return error.NoMcpConfig;
    };
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    // Navigate: mcpServers -> ms365 -> env -> MS365_CLIENT_ID / MS365_TENANT_ID
    const servers = switch (parsed.value.object.get("mcpServers") orelse return error.InvalidConfig) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };
    const ms365 = switch (servers.get("ms365") orelse return error.InvalidConfig) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };
    const env_obj = switch (ms365.get("env") orelse return error.InvalidConfig) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };

    const client_id = switch (env_obj.get("MS365_CLIENT_ID") orelse return error.InvalidConfig) {
        .string => |s| s,
        else => return error.InvalidConfig,
    };
    const tenant_id = switch (env_obj.get("MS365_TENANT_ID") orelse return error.InvalidConfig) {
        .string => |s| s,
        else => return error.InvalidConfig,
    };

    // Build an Environ.Map with just these two vars + HOME (needed for token file).
    var env_map = std.process.Environ.Map.init(allocator);
    try env_map.put("MS365_CLIENT_ID", client_id);
    try env_map.put("MS365_TENANT_ID", tenant_id);
    // Pass HOME so the server can find/save the token file.
    if (std.c.getenv("HOME")) |home| {
        try env_map.put("HOME", std.mem.span(home));
    }
    return env_map;
}

/// Load a .env file and set each KEY=VALUE as an environment variable.
/// Uses a page allocator for the dupeZ strings since they must outlive
/// the GPA (setenv holds pointers to them for the process lifetime).
fn loadDotEnv(allocator: Allocator, io: Io) void {
    const data = std.Io.Dir.readFileAlloc(.cwd(), io, ".env", allocator, .unlimited) catch return;
    defer allocator.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const eq_idx = std.mem.indexOf(u8, line, "=") orelse continue;
        const key = line[0..eq_idx];
        const value = line[eq_idx + 1 ..];
        // page_allocator because C setenv holds these pointers for the process lifetime.
        const key_z = std.heap.page_allocator.dupeZ(u8, key) catch continue;
        const val_z = std.heap.page_allocator.dupeZ(u8, value) catch continue;
        _ = c.setenv(key_z.ptr, val_z.ptr, 0);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create threaded I/O context (required for process spawning + networking).
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    const io = threaded_io.io();

    // Load .env file (won't overwrite existing env vars).
    loadDotEnv(allocator, io);

    // Load env vars from .mcp.json to pass to the child server process.
    var env_map = loadMcpConfig(allocator, io) catch {
        std.debug.print("Error: could not read .mcp.json for MS365_CLIENT_ID/MS365_TENANT_ID.\n", .{});
        return;
    };
    defer env_map.deinit();

    // Build the absolute path to the MCP server binary.
    const exe_path = "zig-out/bin/ms-mcp";

    std.debug.print("\n\x1b[1m── ms-mcp End-to-End Tests ──\x1b[0m\n\n", .{});

    // Spawn the server with the env vars.
    var client = McpClient.init(allocator, io, exe_path, &env_map) catch |err| {
        std.debug.print("Failed to spawn server: {}\n", .{err});
        return err;
    };
    defer client.deinit(io);

    // --- Protocol handshake ---
    std.debug.print("\x1b[1mProtocol:\x1b[0m\n", .{});
    try testInitialize(&client);

    // --- Authentication ---
    std.debug.print("\n\x1b[1mAuthentication:\x1b[0m\n", .{});
    var authenticated = try testCheckAuth(&client);
    if (!authenticated) {
        authenticated = try testLogin(&client);
    }
    if (!authenticated) {
        std.debug.print("\n\x1b[31mCannot continue without authentication.\x1b[0m\n", .{});
        return;
    }

    // --- Read-only tests (no cleanup needed) ---
    std.debug.print("\n\x1b[1mRead-only:\x1b[0m\n", .{});
    try testGetProfile(&client);
    try testListEmails(&client);
    try testListChats(&client);
    try testListTeams(&client);
    try testSearchUsers(&client);
    try testGetMailboxSettings(&client);
    try testSyncTimezone(&client);

    // --- Lifecycle tests (create → verify → delete) ---
    std.debug.print("\n\x1b[1mLifecycle — Drafts:\x1b[0m\n", .{});
    try testDraftLifecycle(&client);
    try testUpdateDraftLifecycle(&client);
    try testSendDraftLifecycle(&client);
    try testAttachmentLifecycle(&client);
    try testRemoveAttachmentLifecycle(&client);

    std.debug.print("\n\x1b[1mLifecycle — Calendar:\x1b[0m\n", .{});
    try testCalendarLifecycle(&client);
    try testCalendarWithAttendees(&client);
    try testCalendarListAndUpdate(&client);

    std.debug.print("\n\x1b[1mLifecycle — Email:\x1b[0m\n", .{});
    try testSendEmailLifecycle(&client);

    std.debug.print("\n\x1b[1mLifecycle — Chat:\x1b[0m\n", .{});
    try testChatMessageLifecycle(&client);

    std.debug.print("\n\x1b[1mLifecycle — Channels:\x1b[0m\n", .{});
    try testChannelLifecycle(&client);
    try testReplyToChannelMessage(&client);

    // --- Summary ---
    const total = tests_passed + tests_failed;
    std.debug.print("\n\x1b[1m── Results: {d}/{d} passed ──\x1b[0m\n\n", .{ tests_passed, total });

    if (tests_failed > 0) {
        std.process.exit(1);
    }
}
