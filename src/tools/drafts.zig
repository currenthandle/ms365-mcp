// tools/drafts.zig — Draft email and attachment tools.

const std = @import("std");
const types = @import("../types.zig");
const graph = @import("../graph.zig");
const json_rpc = @import("../json_rpc.zig");
const ToolContext = @import("context.zig").ToolContext;
const email_tools = @import("email.zig");

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Array = std.json.Array;

/// Create a draft email (saved to Drafts folder, not sent).
pub fn handleCreateDraft(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide to, subject, and body.") orelse return;

    const to = email_tools.parseRecipients(ctx.allocator, args, "to") catch return orelse {
        ctx.sendResult("Missing 'to' argument (array of email addresses).");
        return;
    };
    defer ctx.allocator.free(to);
    const cc = email_tools.parseRecipients(ctx.allocator, args, "cc") catch return;
    defer if (cc) |r| ctx.allocator.free(r);
    const bcc = email_tools.parseRecipients(ctx.allocator, args, "bcc") catch return;
    defer if (bcc) |r| ctx.allocator.free(r);

    const subject = ctx.getStringArg(args, "subject", "Missing 'subject' argument.") orelse return;
    const body_text = ctx.getStringArg(args, "body", "Missing 'body' argument.") orelse return;

    // Auto-detect HTML body.
    const body_is_html = std.mem.indexOf(u8, body_text, "<html") != null or
        std.mem.indexOf(u8, body_text, "<div") != null or
        std.mem.indexOf(u8, body_text, "<p>") != null or
        std.mem.indexOf(u8, body_text, "<br") != null or
        std.mem.indexOf(u8, body_text, "<img") != null or
        std.mem.indexOf(u8, body_text, "<table") != null;

    const draft_request = types.DraftMailRequest{
        .subject = subject,
        .body = .{ .contentType = if (body_is_html) "HTML" else "Text", .content = body_text },
        .toRecipients = to,
        .ccRecipients = cc,
        .bccRecipients = bcc,
    };

    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(draft_request, .{ .emit_null_optional_fields = false }, &json_buf.writer) catch return;

    const response = graph.post(ctx.allocator, ctx.io, token, "/me/messages", json_buf.written()) catch {
        ctx.sendResult("Failed to create draft.");
        return;
    };
    defer ctx.allocator.free(response);

    // Extract the draft ID from the response.
    const draft_id = extractJsonId(ctx.allocator, response);
    const msg = std.fmt.allocPrint(ctx.allocator, "Draft created successfully. Draft ID: {s}", .{draft_id}) catch return;
    defer ctx.allocator.free(msg);
    ctx.sendResult(msg);
}

/// Send a previously created draft email.
pub fn handleSendDraft(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide draftId.") orelse return;
    const draft_id = ctx.getPathArg(args, "draftId", "Missing 'draftId' argument.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}/send", .{draft_id}) catch return;
    defer ctx.allocator.free(path);

    // Empty JSON body required — Zig's HTTP client asserts on POST with null payload.
    _ = graph.post(ctx.allocator, ctx.io, token, path, "{}") catch {
        ctx.sendResult("Failed to send draft.");
        return;
    };

    ctx.sendResult("Draft sent successfully.");
}

/// Update an existing draft email's subject, body, or recipients.
pub fn handleUpdateDraft(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide draftId and fields to update.") orelse return;
    const draft_id = ctx.getPathArg(args, "draftId", "Missing 'draftId' argument.") orelse return;

    // Build PATCH body with only provided fields.
    var patch_obj: ObjectMap = .empty;
    defer patch_obj.deinit(ctx.allocator);

    if (json_rpc.getStringArg(args, "subject")) |subject|
        patch_obj.put(ctx.allocator, "subject", .{ .string = subject }) catch return;

    if (json_rpc.getStringArg(args, "body")) |body_text| {
        const is_html = std.mem.indexOf(u8, body_text, "<html") != null or
            std.mem.indexOf(u8, body_text, "<div") != null or
            std.mem.indexOf(u8, body_text, "<p>") != null or
            std.mem.indexOf(u8, body_text, "<br") != null or
            std.mem.indexOf(u8, body_text, "<img") != null or
            std.mem.indexOf(u8, body_text, "<table") != null;
        var body_obj: ObjectMap = .empty;
        body_obj.put(ctx.allocator, "contentType", .{ .string = if (is_html) "HTML" else "Text" }) catch return;
        body_obj.put(ctx.allocator, "content", .{ .string = body_text }) catch return;
        patch_obj.put(ctx.allocator, "body", .{ .object = body_obj }) catch return;
    }

    // Optional recipient updates.
    inline for (.{ .{ "to", "toRecipients" }, .{ "cc", "ccRecipients" }, .{ "bcc", "bccRecipients" } }) |pair| {
        if (email_tools.parseRecipients(ctx.allocator, args, pair[0]) catch return) |recipients| {
            defer ctx.allocator.free(recipients);
            var arr = Array.initCapacity(ctx.allocator, recipients.len) catch return;
            for (recipients) |r| {
                var email_obj: ObjectMap = .empty;
                email_obj.put(ctx.allocator, "address", .{ .string = r.emailAddress.address }) catch return;
                var recip_obj: ObjectMap = .empty;
                recip_obj.put(ctx.allocator, "emailAddress", .{ .object = email_obj }) catch return;
                arr.appendAssumeCapacity(.{ .object = recip_obj });
            }
            patch_obj.put(ctx.allocator, pair[1], .{ .array = arr }) catch return;
        }
    }

    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(Value{ .object = patch_obj }, .{}, &json_buf.writer) catch return;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}", .{draft_id}) catch return;
    defer ctx.allocator.free(path);

    _ = graph.patch(ctx.allocator, ctx.io, token, path, json_buf.written()) catch {
        ctx.sendResult("Failed to update draft.");
        return;
    };

    ctx.sendResult("Draft updated successfully.");
}

/// Delete a draft email.
pub fn handleDeleteDraft(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide draftId.") orelse return;
    const draft_id = ctx.getPathArg(args, "draftId", "Missing 'draftId' argument.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}", .{draft_id}) catch return;
    defer ctx.allocator.free(path);

    graph.delete(ctx.allocator, ctx.io, token, path) catch {
        ctx.sendResult("Failed to delete draft.");
        return;
    };

    ctx.sendResult("Draft deleted successfully.");
}

/// Add a file attachment to a draft email.
pub fn handleAddAttachment(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide draftId and filePath.") orelse return;
    const draft_id = ctx.getPathArg(args, "draftId", "Missing 'draftId' argument.") orelse return;
    const file_path = ctx.getStringArg(args, "filePath", "Missing 'filePath' argument (absolute path to the file).") orelse return;

    // Reject paths with ".." to prevent directory traversal attacks.
    if (std.mem.indexOf(u8, file_path, "..") != null) {
        ctx.sendResult("Invalid file path — '..' is not allowed.");
        return;
    }

    // Read the file from disk.
    const file_data = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, file_path, ctx.allocator, .unlimited) catch {
        const err_msg = std.fmt.allocPrint(ctx.allocator, "Failed to read file: {s}", .{file_path}) catch return;
        defer ctx.allocator.free(err_msg);
        ctx.sendResult(err_msg);
        return;
    };
    defer ctx.allocator.free(file_data);

    // Base64-encode the file contents.
    const b64 = std.base64.standard.Encoder.encode(
        ctx.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(file_data.len)) catch return,
        file_data,
    );
    defer ctx.allocator.free(b64);

    // Derive filename and MIME type.
    const file_name = json_rpc.getStringArg(args, "name") orelse blk: {
        if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |idx| break :blk file_path[idx + 1 ..];
        break :blk file_path;
    };
    const content_type = json_rpc.getStringArg(args, "contentType") orelse inferMimeType(file_path);

    const is_inline = if (args.get("isInline")) |v| switch (v) { .bool => |b| b, else => false } else false;
    const content_id = json_rpc.getStringArg(args, "contentId");

    // Build attachment JSON.
    var obj: ObjectMap = .empty;
    defer obj.deinit(ctx.allocator);
    obj.put(ctx.allocator, "@odata.type", .{ .string = "#microsoft.graph.fileAttachment" }) catch return;
    obj.put(ctx.allocator, "name", .{ .string = file_name }) catch return;
    obj.put(ctx.allocator, "contentType", .{ .string = content_type }) catch return;
    obj.put(ctx.allocator, "contentBytes", .{ .string = b64 }) catch return;
    if (is_inline) {
        obj.put(ctx.allocator, "isInline", .{ .bool = true }) catch return;
        if (content_id) |cid| obj.put(ctx.allocator, "contentId", .{ .string = cid }) catch return;
    }

    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(Value{ .object = obj }, .{}, &json_buf.writer) catch return;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}/attachments", .{draft_id}) catch return;
    defer ctx.allocator.free(path);

    const response = graph.post(ctx.allocator, ctx.io, token, path, json_buf.written()) catch {
        ctx.sendResult("Failed to add attachment.");
        return;
    };
    defer ctx.allocator.free(response);

    const attach_id = extractJsonId(ctx.allocator, response);
    const msg = std.fmt.allocPrint(ctx.allocator, "Attachment '{s}' added. Attachment ID: {s}", .{ file_name, attach_id }) catch return;
    defer ctx.allocator.free(msg);
    ctx.sendResult(msg);
}

/// List attachments on a draft email.
pub fn handleListAttachments(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide draftId.") orelse return;
    const draft_id = ctx.getPathArg(args, "draftId", "Missing 'draftId' argument.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}/attachments", .{draft_id}) catch return;
    defer ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch {
        ctx.sendResult("Failed to list attachments.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}

/// Remove an attachment from a draft email.
pub fn handleRemoveAttachment(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide draftId and attachmentId.") orelse return;
    const draft_id = ctx.getPathArg(args, "draftId", "Missing 'draftId' argument.") orelse return;
    const attachment_id = ctx.getPathArg(args, "attachmentId", "Missing 'attachmentId' argument. Use list-attachments to find IDs.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}/attachments/{s}", .{ draft_id, attachment_id }) catch return;
    defer ctx.allocator.free(path);

    graph.delete(ctx.allocator, ctx.io, token, path) catch {
        ctx.sendResult("Failed to remove attachment.");
        return;
    };

    ctx.sendResult("Attachment removed successfully.");
}

// ---------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------

/// Extract the top-level "id" field from a JSON response string.
fn extractJsonId(allocator: std.mem.Allocator, json_text: []const u8) []const u8 {
    const parsed = std.json.parseFromSlice(Value, allocator, json_text, .{}) catch return "(unknown)";
    defer parsed.deinit();
    const id_val = switch (parsed.value) {
        .object => |o| o.get("id") orelse return "(unknown)",
        else => return "(unknown)",
    };
    return switch (id_val) {
        .string => |s| s,
        else => "(unknown)",
    };
}

/// Infer MIME type from file extension.
fn inferMimeType(file_path: []const u8) []const u8 {
    const ext = std.fs.path.extension(file_path);
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".gif")) return "image/gif";
    if (std.mem.eql(u8, ext, ".pdf")) return "application/pdf";
    if (std.mem.eql(u8, ext, ".doc")) return "application/msword";
    if (std.mem.eql(u8, ext, ".docx")) return "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
    if (std.mem.eql(u8, ext, ".xls")) return "application/vnd.ms-excel";
    if (std.mem.eql(u8, ext, ".xlsx")) return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
    if (std.mem.eql(u8, ext, ".ppt")) return "application/vnd.ms-powerpoint";
    if (std.mem.eql(u8, ext, ".pptx")) return "application/vnd.openxmlformats-officedocument.presentationml.presentation";
    if (std.mem.eql(u8, ext, ".txt")) return "text/plain";
    if (std.mem.eql(u8, ext, ".csv")) return "text/csv";
    if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm")) return "text/html";
    if (std.mem.eql(u8, ext, ".zip")) return "application/zip";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".webp")) return "image/webp";
    return "application/octet-stream";
}
