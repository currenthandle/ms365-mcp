// e2e/cases/drafts.zig — Email draft lifecycle tests.

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
