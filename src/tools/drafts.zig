// tools/drafts.zig — Draft email and attachment tools.

const std = @import("std");
const types = @import("../types.zig");
const graph = @import("../graph.zig");
const json_rpc = @import("../json_rpc.zig");
const state_mod = @import("../state.zig");
const ToolContext = @import("context.zig").ToolContext;
const email_tools = @import("email.zig");

// Type aliases — keeps function signatures cleaner.
const Allocator = std.mem.Allocator;

/// Create a draft email (saved to Drafts folder, not sent).
pub fn handleCreateDraft(ctx: ToolContext) void {
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing arguments. Provide to, subject, and body." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // Parse recipients (to is required, cc/bcc optional).
    const to_recipients = email_tools.parseRecipients(ctx.allocator, args, "to") catch return orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'to' argument (array of email addresses)." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    defer ctx.allocator.free(to_recipients);

    const cc_recipients = email_tools.parseRecipients(ctx.allocator, args, "cc") catch return;
    defer if (cc_recipients) |cc| ctx.allocator.free(cc);

    const bcc_recipients = email_tools.parseRecipients(ctx.allocator, args, "bcc") catch return;
    defer if (bcc_recipients) |bcc| ctx.allocator.free(bcc);

    const subject = json_rpc.getStringArg(args, "subject") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'subject' argument." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    const body_text = json_rpc.getStringArg(args, "body") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'body' argument." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // Build the Graph API request body for POST /me/messages.
    // This creates a draft — no sendMail wrapper needed.
    // Auto-detect HTML body: if it contains common HTML tags, set contentType to HTML.
    const body_is_html = std.mem.indexOf(u8, body_text, "<html") != null or
        std.mem.indexOf(u8, body_text, "<div") != null or
        std.mem.indexOf(u8, body_text, "<p>") != null or
        std.mem.indexOf(u8, body_text, "<br") != null or
        std.mem.indexOf(u8, body_text, "<img") != null or
        std.mem.indexOf(u8, body_text, "<table") != null;
    const body_content_type: []const u8 = if (body_is_html) "HTML" else "Text";

    const draft_request = types.DraftMailRequest{
        .subject = subject,
        .body = .{ .contentType = body_content_type, .content = body_text },
        .toRecipients = to_recipients,
        .ccRecipients = cc_recipients,
        .bccRecipients = bcc_recipients,
    };

    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(draft_request, .{ .emit_null_optional_fields = false }, &json_buf.writer) catch return;
    const json_body = json_buf.written();

    // POST /me/messages creates a draft in the Drafts folder.
    const response = graph.post(ctx.allocator, ctx.io, token, "/me/messages", json_body) catch |err| {
        std.debug.print("ms-mcp: create-draft failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to create draft." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    defer ctx.allocator.free(response);

    // Parse the response to extract the draft message ID.
    const draft_parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, response, .{}) catch {
        const content: []const types.TextContent = &.{
            .{ .text = "Draft created but could not parse response." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    defer draft_parsed.deinit();

    const draft_id = if (draft_parsed.value.object.get("id")) |id_val| switch (id_val) {
        .string => |s| s,
        else => "(unknown)",
    } else "(unknown)";

    // Format a success message with the draft ID.
    const msg = std.fmt.allocPrint(ctx.allocator, "Draft created successfully. Draft ID: {s}", .{draft_id}) catch return;
    defer ctx.allocator.free(msg);

    const content: []const types.TextContent = &.{
        .{ .text = msg },
    };
    const result = types.ToolCallResult{ .content = content };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = result,
    });
}

/// Send a previously created draft email.
pub fn handleSendDraft(ctx: ToolContext) void {
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing arguments. Provide draftId." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    const draft_id = json_rpc.getPathArg(args, "draftId") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'draftId' argument." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // POST /me/messages/{id}/send — sends the draft, no body needed.
    const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}/send", .{draft_id}) catch return;
    defer ctx.allocator.free(path);

    const send_response = graph.post(ctx.allocator, ctx.io, token, path, null) catch |err| {
        std.debug.print("ms-mcp: send-draft failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to send draft." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    defer ctx.allocator.free(send_response);

    const content: []const types.TextContent = &.{
        .{ .text = "Draft sent successfully." },
    };
    const result = types.ToolCallResult{ .content = content };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = result,
    });
}

/// Update an existing draft email's subject, body, or recipients.
pub fn handleUpdateDraft(ctx: ToolContext) void {
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing arguments. Provide draftId and fields to update." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    const draft_id = json_rpc.getPathArg(args, "draftId") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'draftId' argument." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // Build the PATCH body with only the fields that were provided.
    // We use std.json.Value to build a dynamic object.
    var patch_obj = std.json.ObjectMap.init(ctx.allocator);
    defer patch_obj.deinit();

    // Optional subject update.
    if (json_rpc.getStringArg(args, "subject")) |subject| {
        patch_obj.put("subject", .{ .string = subject }) catch return;
    }

    // Optional body update.
    // Auto-detect HTML: if the body contains common HTML tags, use HTML content type.
    if (json_rpc.getStringArg(args, "body")) |body_text| {
        const update_is_html = std.mem.indexOf(u8, body_text, "<html") != null or
            std.mem.indexOf(u8, body_text, "<div") != null or
            std.mem.indexOf(u8, body_text, "<p>") != null or
            std.mem.indexOf(u8, body_text, "<br") != null or
            std.mem.indexOf(u8, body_text, "<img") != null or
            std.mem.indexOf(u8, body_text, "<table") != null;
        const update_body_type: []const u8 = if (update_is_html) "HTML" else "Text";
        var body_obj = std.json.ObjectMap.init(ctx.allocator);
        body_obj.put("contentType", .{ .string = update_body_type }) catch return;
        body_obj.put("content", .{ .string = body_text }) catch return;
        patch_obj.put("body", .{ .object = body_obj }) catch return;
    }

    // Optional toRecipients update.
    if (email_tools.parseRecipients(ctx.allocator, args, "to") catch return) |to_recipients| {
        defer ctx.allocator.free(to_recipients);
        var to_arr = std.json.Array.initCapacity(ctx.allocator, to_recipients.len) catch return;
        for (to_recipients) |r| {
            var email_obj = std.json.ObjectMap.init(ctx.allocator);
            email_obj.put("address", .{ .string = r.emailAddress.address }) catch return;
            var recip_obj = std.json.ObjectMap.init(ctx.allocator);
            recip_obj.put("emailAddress", .{ .object = email_obj }) catch return;
            to_arr.appendAssumeCapacity(.{ .object = recip_obj });
        }
        patch_obj.put("toRecipients", .{ .array = to_arr }) catch return;
    }

    // Optional ccRecipients update.
    if (email_tools.parseRecipients(ctx.allocator, args, "cc") catch return) |cc_recipients| {
        defer ctx.allocator.free(cc_recipients);
        var cc_arr = std.json.Array.initCapacity(ctx.allocator, cc_recipients.len) catch return;
        for (cc_recipients) |r| {
            var email_obj = std.json.ObjectMap.init(ctx.allocator);
            email_obj.put("address", .{ .string = r.emailAddress.address }) catch return;
            var recip_obj = std.json.ObjectMap.init(ctx.allocator);
            recip_obj.put("emailAddress", .{ .object = email_obj }) catch return;
            cc_arr.appendAssumeCapacity(.{ .object = recip_obj });
        }
        patch_obj.put("ccRecipients", .{ .array = cc_arr }) catch return;
    }

    // Optional bccRecipients update.
    if (email_tools.parseRecipients(ctx.allocator, args, "bcc") catch return) |bcc_recipients| {
        defer ctx.allocator.free(bcc_recipients);
        var bcc_arr = std.json.Array.initCapacity(ctx.allocator, bcc_recipients.len) catch return;
        for (bcc_recipients) |r| {
            var email_obj = std.json.ObjectMap.init(ctx.allocator);
            email_obj.put("address", .{ .string = r.emailAddress.address }) catch return;
            var recip_obj = std.json.ObjectMap.init(ctx.allocator);
            recip_obj.put("emailAddress", .{ .object = email_obj }) catch return;
            bcc_arr.appendAssumeCapacity(.{ .object = recip_obj });
        }
        patch_obj.put("bccRecipients", .{ .array = bcc_arr }) catch return;
    }

    // Serialize the patch object to JSON.
    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    const patch_val = std.json.Value{ .object = patch_obj };
    std.json.Stringify.value(patch_val, .{}, &json_buf.writer) catch return;
    const json_body = json_buf.written();

    // PATCH /me/messages/{id}
    const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}", .{draft_id}) catch return;
    defer ctx.allocator.free(path);

    const patch_response = graph.patch(ctx.allocator, ctx.io, token, path, json_body) catch |err| {
        std.debug.print("ms-mcp: update-draft failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to update draft." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    defer ctx.allocator.free(patch_response);

    const content: []const types.TextContent = &.{
        .{ .text = "Draft updated successfully." },
    };
    const result = types.ToolCallResult{ .content = content };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = result,
    });
}

/// Delete a draft email.
pub fn handleDeleteDraft(ctx: ToolContext) void {
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing arguments. Provide draftId." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    const draft_id = json_rpc.getPathArg(args, "draftId") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'draftId' argument." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // DELETE /me/messages/{id}
    const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}", .{draft_id}) catch return;
    defer ctx.allocator.free(path);

    graph.delete(ctx.allocator, ctx.io, token, path) catch |err| {
        std.debug.print("ms-mcp: delete-draft failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to delete draft." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    const content: []const types.TextContent = &.{
        .{ .text = "Draft deleted successfully." },
    };
    const result = types.ToolCallResult{ .content = content };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = result,
    });
}

/// Add a file attachment to a draft email.
/// Reads the file from disk and base64-encodes it server-side
/// so the LLM doesn't have to pass huge base64 strings.
pub fn handleAddAttachment(ctx: ToolContext) void {
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing arguments. Provide draftId and filePath." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    const draft_id = json_rpc.getPathArg(args, "draftId") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'draftId' argument." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    const file_path = json_rpc.getStringArg(args, "filePath") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'filePath' argument (absolute path to the file)." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // Reject paths with ".." to prevent directory traversal attacks.
    // An attacker via prompt injection could try to exfiltrate sensitive files
    // like ~/.ms365-zig-mcp-token.json or SSH keys.
    if (std.mem.indexOf(u8, file_path, "..") != null) {
        const content: []const types.TextContent = &.{
            .{ .text = "Invalid file path — '..' is not allowed." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    }

    // Read the file from disk (up to 10 MB).
    const file_data = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, file_path, ctx.allocator, .unlimited) catch |err| {
        std.debug.print("ms-mcp: add-attachment read file failed: {}\n", .{err});
        const err_msg = std.fmt.allocPrint(ctx.allocator, "Failed to read file: {s}", .{file_path}) catch return;
        defer ctx.allocator.free(err_msg);
        const content: []const types.TextContent = &.{
            .{ .text = err_msg },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    defer ctx.allocator.free(file_data);

    // Base64-encode the file contents.
    const b64_encoded = std.base64.standard.Encoder.encode(
        ctx.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(file_data.len)) catch return,
        file_data,
    );
    defer ctx.allocator.free(b64_encoded);

    // Derive the filename from the path (everything after the last /).
    // Use the "name" arg if provided, otherwise extract from filePath.
    const file_name = json_rpc.getStringArg(args, "name") orelse blk: {
        const path_slice = file_path;
        if (std.mem.lastIndexOfScalar(u8, path_slice, '/')) |idx| {
            break :blk path_slice[idx + 1 ..];
        }
        break :blk path_slice;
    };

    // Infer MIME type from extension if not provided.
    const content_type = json_rpc.getStringArg(args, "contentType") orelse blk: {
        const ext = std.fs.path.extension(file_path);
        if (std.mem.eql(u8, ext, ".png")) break :blk "image/png";
        if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) break :blk "image/jpeg";
        if (std.mem.eql(u8, ext, ".gif")) break :blk "image/gif";
        if (std.mem.eql(u8, ext, ".pdf")) break :blk "application/pdf";
        if (std.mem.eql(u8, ext, ".doc")) break :blk "application/msword";
        if (std.mem.eql(u8, ext, ".docx")) break :blk "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
        if (std.mem.eql(u8, ext, ".xls")) break :blk "application/vnd.ms-excel";
        if (std.mem.eql(u8, ext, ".xlsx")) break :blk "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
        if (std.mem.eql(u8, ext, ".ppt")) break :blk "application/vnd.ms-powerpoint";
        if (std.mem.eql(u8, ext, ".pptx")) break :blk "application/vnd.openxmlformats-officedocument.presentationml.presentation";
        if (std.mem.eql(u8, ext, ".txt")) break :blk "text/plain";
        if (std.mem.eql(u8, ext, ".csv")) break :blk "text/csv";
        if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm")) break :blk "text/html";
        if (std.mem.eql(u8, ext, ".zip")) break :blk "application/zip";
        if (std.mem.eql(u8, ext, ".svg")) break :blk "image/svg+xml";
        if (std.mem.eql(u8, ext, ".webp")) break :blk "image/webp";
        break :blk "application/octet-stream";
    };

    // Check for inline attachment options.
    // isInline=true marks the attachment as embedded in the HTML body.
    // contentId is the CID referenced by <img src="cid:..."> in the body.
    const is_inline = if (args.get("isInline")) |v| switch (v) {
        .bool => |b| b,
        else => false,
    } else false;
    const content_id = json_rpc.getStringArg(args, "contentId");

    // Build the attachment JSON payload.
    // Graph API expects @odata.type for file attachments.
    var attach_obj = std.json.ObjectMap.init(ctx.allocator);
    defer attach_obj.deinit();
    attach_obj.put("@odata.type", .{ .string = "#microsoft.graph.fileAttachment" }) catch return;
    attach_obj.put("name", .{ .string = file_name }) catch return;
    attach_obj.put("contentType", .{ .string = content_type }) catch return;
    attach_obj.put("contentBytes", .{ .string = b64_encoded }) catch return;
    if (is_inline) {
        attach_obj.put("isInline", .{ .bool = true }) catch return;
        if (content_id) |cid| {
            attach_obj.put("contentId", .{ .string = cid }) catch return;
        }
    }

    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    const attach_val = std.json.Value{ .object = attach_obj };
    std.json.Stringify.value(attach_val, .{}, &json_buf.writer) catch return;
    const json_body = json_buf.written();

    // POST /me/messages/{id}/attachments
    const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}/attachments", .{draft_id}) catch return;
    defer ctx.allocator.free(path);

    const response = graph.post(ctx.allocator, ctx.io, token, path, json_body) catch |err| {
        std.debug.print("ms-mcp: add-attachment failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to add attachment." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    defer ctx.allocator.free(response);

    // Parse response to get attachment ID.
    const attach_parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, response, .{}) catch {
        const content: []const types.TextContent = &.{
            .{ .text = "Attachment added but could not parse response." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    defer attach_parsed.deinit();

    const attach_id = if (attach_parsed.value.object.get("id")) |id_val| switch (id_val) {
        .string => |s| s,
        else => "(unknown)",
    } else "(unknown)";

    const msg = std.fmt.allocPrint(ctx.allocator, "Attachment '{s}' added. Attachment ID: {s}", .{ file_name, attach_id }) catch return;
    defer ctx.allocator.free(msg);

    const content: []const types.TextContent = &.{
        .{ .text = msg },
    };
    const result = types.ToolCallResult{ .content = content };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = result,
    });
}

/// List attachments on a draft email.
pub fn handleListAttachments(ctx: ToolContext) void {
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing arguments. Provide draftId." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    const draft_id = json_rpc.getPathArg(args, "draftId") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'draftId' argument." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // GET /me/messages/{id}/attachments
    const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}/attachments", .{draft_id}) catch return;
    defer ctx.allocator.free(path);

    const response_body = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        std.debug.print("ms-mcp: list-attachments failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to list attachments." },
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

/// Remove an attachment from a draft email.
pub fn handleRemoveAttachment(ctx: ToolContext) void {
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing arguments. Provide draftId and attachmentId." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    const draft_id = json_rpc.getPathArg(args, "draftId") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'draftId' argument." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    const attachment_id = json_rpc.getPathArg(args, "attachmentId") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'attachmentId' argument. Use list-attachments to find IDs." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // DELETE /me/messages/{id}/attachments/{attachmentId}
    const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}/attachments/{s}", .{ draft_id, attachment_id }) catch return;
    defer ctx.allocator.free(path);

    graph.delete(ctx.allocator, ctx.io, token, path) catch |err| {
        std.debug.print("ms-mcp: remove-attachment failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to remove attachment." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    const content: []const types.TextContent = &.{
        .{ .text = "Attachment removed successfully." },
    };
    const result = types.ToolCallResult{ .content = content };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = result,
    });
}
