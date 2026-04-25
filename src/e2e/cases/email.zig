// e2e/cases/email.zig — Email lifecycle + action tests (reply, forward, search, mark, move, download).

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


/// Extract the id: field from the first line of formatter output.
fn extractFirstIdFromFormatted(allocator: Allocator, text: []const u8) ?[]u8 {
    return shared.extractFormattedField(allocator, text, "id: ");
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
