// tools/email.zig — Email reading and sending tools.

const std = @import("std");
const types = @import("../types.zig");
const graph = @import("../graph.zig");
const json_rpc = @import("../json_rpc.zig");
const url_util = @import("../url.zig");
const ToolContext = @import("context.zig").ToolContext;
const formatter = @import("../formatter.zig");
const json_util = @import("../json_util.zig");
const binary_download = @import("../binary_download.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Array = std.json.Array;

// Fields surfaced from /me/messages list + single-message get responses.
// We show subject + sender + received date + preview, then the formatter
// automatically appends id: and webUrl: suffixes.
const list_email_fields = [_]formatter.FieldSpec{
    .{ .path = "subject", .label = "subject" },
    .{ .path = "from.emailAddress.address", .label = "from" },
    .{ .path = "receivedDateTime", .label = "received" },
    .{ .path = "bodyPreview", .label = "preview", .newline_after = true },
};

const read_email_fields = [_]formatter.FieldSpec{
    .{ .path = "subject", .label = "subject" },
    .{ .path = "from.emailAddress.address", .label = "from" },
    .{ .path = "receivedDateTime", .label = "received" },
    // body is an object {contentType, content} — we surface just the content.
    .{ .path = "body.content", .label = "body", .newline_after = true },
    .{ .path = "isRead", .label = "isRead" },
};

const mail_folder_fields = [_]formatter.FieldSpec{
    .{ .path = "displayName", .label = "name" },
    .{ .path = "parentFolderId", .label = "parent" },
};

const attachment_list_fields = [_]formatter.FieldSpec{
    .{ .path = "name", .label = "name" },
    .{ .path = "contentType", .label = "type" },
    // size is an int — formatter skips non-strings for now, but we leave
    // the FieldSpec as documentation of what we'd surface.
    .{ .path = "size", .label = "bytes" },
};

const attachment_read_fields = [_]formatter.FieldSpec{
    .{ .path = "name", .label = "name" },
    .{ .path = "contentType", .label = "type" },
    .{ .path = "contentBytes", .label = "contentBase64", .newline_after = true },
};

/// Convert a JSON array of email strings into a slice of Recipient structs.
/// Returns null if the key is missing or isn't an array.
/// pub because drafts.zig also needs this.
pub fn parseRecipients(
    allocator: Allocator,
    args: ObjectMap,
    key: []const u8,
) !?[]const types.SendMailRequest.Message.Recipient {
    const val = args.get(key) orelse return null;
    const arr = switch (val) {
        .array => |a| a,
        else => return null,
    };

    const recipients = try allocator.alloc(types.SendMailRequest.Message.Recipient, arr.items.len);
    for (arr.items, 0..) |item, i| {
        const email = switch (item) {
            .string => |s| s,
            else => {
                allocator.free(recipients);
                return null;
            },
        };
        recipients[i] = .{ .emailAddress = .{ .address = email } };
    }
    return recipients;
}

/// List the 10 most recent emails from the user's inbox.
pub fn handleListEmails(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;

    // $select scopes the columns Graph returns. Combined with the formatter,
    // this keeps the LLM-facing summary tiny — one line per email.
    const response = graph.get(
        ctx.allocator, ctx.io, token,
        "/me/messages?$top=10&$select=id,subject,from,receivedDateTime,bodyPreview,webLink&$orderby=receivedDateTime%20desc",
    ) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    if (formatter.summarizeArray(ctx.allocator, response, &list_email_fields)) |summary| {
        defer ctx.allocator.free(summary);
        ctx.sendResult(summary);
    } else {
        ctx.sendResult("No emails found.");
    }
}

/// Read the full content of a single email by ID.
pub fn handleReadEmail(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide emailId.") orelse return;
    const email_id = ctx.getPathArg(args, "emailId", "Missing 'emailId' argument.") orelse return;

    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/me/messages/{s}?$select=id,subject,from,toRecipients,ccRecipients,receivedDateTime,body,isRead,webLink",
        .{email_id},
    ) catch return;
    defer ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    if (formatter.summarizeObject(ctx.allocator, response, &read_email_fields)) |summary| {
        defer ctx.allocator.free(summary);
        ctx.sendResult(summary);
    } else {
        ctx.sendResult("Email not found.");
    }
}

/// Send an email immediately via Microsoft Graph.
pub fn handleSendEmail(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide to, subject, and body.") orelse return;

    const to = parseRecipients(ctx.allocator, args, "to") catch return orelse {
        ctx.sendResult("Missing 'to' argument (array of email addresses).");
        return;
    };
    defer ctx.allocator.free(to);
    const cc = parseRecipients(ctx.allocator, args, "cc") catch return;
    defer if (cc) |r| ctx.allocator.free(r);
    const bcc = parseRecipients(ctx.allocator, args, "bcc") catch return;
    defer if (bcc) |r| ctx.allocator.free(r);

    const subject = ctx.getStringArg(args, "subject", "Missing 'subject' argument.") orelse return;
    const body_text = ctx.getStringArg(args, "body", "Missing 'body' argument.") orelse return;

    // format=html sends the body with contentType=HTML and trusts the caller's
    // markup. format=text (default) sends contentType=Text and Outlook renders
    // it exactly as plain text — no escaping pass needed.
    const format = json_rpc.getStringArg(args, "format") orelse "text";
    const is_html = std.mem.eql(u8, format, "html");
    const content_type: []const u8 = if (is_html) "HTML" else "Text";

    const mail_request = types.SendMailRequest{
        .message = .{
            .subject = subject,
            .body = .{ .contentType = content_type, .content = body_text },
            .toRecipients = to,
            .ccRecipients = cc,
            .bccRecipients = bcc,
        },
    };
    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(mail_request, .{ .emit_null_optional_fields = false }, &json_buf.writer) catch return;

    _ = graph.post(ctx.allocator, ctx.io, token, "/me/sendMail", json_buf.written()) catch |err| {
        ctx.sendGraphError(err);
        return;
    };

    ctx.sendResult("Email sent successfully.");
}

/// Delete multiple emails in one call. Takes an array of emailIds and
/// issues a DELETE per id. Returns a count of successful deletions plus
/// any per-id errors. Used by the e2e suite to clean up lingering test
/// emails from pre-fix runs, and generally useful when an agent needs
/// to clear out search results without 25 separate delete calls.
pub fn handleBatchDeleteEmails(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide emailIds (array).") orelse return;

    const ids_val = args.get("emailIds") orelse {
        ctx.sendResult("Missing 'emailIds' argument — pass an array of email IDs.");
        return;
    };
    const ids_arr = switch (ids_val) {
        .array => |a| a,
        else => {
            ctx.sendResult("'emailIds' must be an array of strings.");
            return;
        },
    };

    var ok: u32 = 0;
    var failed: u32 = 0;
    var first_err_buf: [256]u8 = undefined;
    var first_err: ?[]const u8 = null;

    for (ids_arr.items) |item| {
        const email_id = switch (item) {
            .string => |s| s,
            else => {
                failed += 1;
                continue;
            },
        };
        const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}", .{email_id}) catch {
            failed += 1;
            continue;
        };
        defer ctx.allocator.free(path);
        graph.delete(ctx.allocator, ctx.io, token, path) catch |err| {
            failed += 1;
            if (first_err == null) {
                first_err = std.fmt.bufPrint(&first_err_buf, "{}", .{err}) catch null;
            }
            continue;
        };
        ok += 1;
    }

    const msg = if (failed == 0)
        std.fmt.allocPrint(ctx.allocator, "Deleted {d} email(s).", .{ok}) catch return
    else
        std.fmt.allocPrint(
            ctx.allocator,
            "Deleted {d}/{d} email(s). {d} failed (first error: {s}).",
            .{ ok, ok + failed, failed, first_err orelse "unknown" },
        ) catch return;
    defer ctx.allocator.free(msg);
    ctx.sendResult(msg);
}

/// Delete an email by ID.
pub fn handleDeleteEmail(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide emailId.") orelse return;
    const email_id = ctx.getPathArg(args, "emailId", "Missing 'emailId' argument.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}", .{email_id}) catch return;
    defer ctx.allocator.free(path);

    graph.delete(ctx.allocator, ctx.io, token, path) catch |err| {
        ctx.sendGraphError(err);
        return;
    };

    ctx.sendResult("Email deleted.");
}

// --- Reply / Forward helpers ---

/// Build the JSON body for a /reply, /replyAll, or /forward POST.
/// All three Graph endpoints accept the same shape:
///   { "comment": "...", "toRecipients": [{"emailAddress":{"address":"..."}}, ...] }
/// toRecipients is omitted when not provided (reply/replyAll typically omit;
/// forward requires it).
///
/// Returns an allocated JSON string — caller must free.
fn buildCommentedBody(
    allocator: Allocator,
    comment: []const u8,
    recipients: ?[]const types.SendMailRequest.Message.Recipient,
) ![]u8 {
    var body: ObjectMap = .empty;
    defer body.deinit(allocator);

    try body.put(allocator, "comment", .{ .string = comment });

    if (recipients) |list| {
        // Array.initCapacity is like Python's list() with a pre-sized backing.
        var arr = try Array.initCapacity(allocator, list.len);
        for (list) |r| {
            var email_obj: ObjectMap = .empty;
            try email_obj.put(allocator, "address", .{ .string = r.emailAddress.address });
            var recip_obj: ObjectMap = .empty;
            try recip_obj.put(allocator, "emailAddress", .{ .object = email_obj });
            arr.appendAssumeCapacity(.{ .object = recip_obj });
        }
        try body.put(allocator, "toRecipients", .{ .array = arr });
    }

    var json_buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer json_buf.deinit();
    try std.json.Stringify.value(Value{ .object = body }, .{}, &json_buf.writer);
    return json_buf.toOwnedSlice();
}

/// Shared POST for reply / replyAll / forward.
/// `action` is one of "reply", "replyAll", "forward" — appended to the URL.
/// `require_to` fails the request if toRecipients is empty (used by forward).
fn sendCommentAction(
    ctx: ToolContext,
    token: []const u8,
    email_id: []const u8,
    action: []const u8,
    comment: []const u8,
    recipients: ?[]const types.SendMailRequest.Message.Recipient,
    require_to: bool,
    success_msg: []const u8,
) void {
    if (require_to) {
        if (recipients == null or recipients.?.len == 0) {
            ctx.sendResult("Missing 'to' argument — forward requires at least one recipient.");
            return;
        }
    }

    const body = buildCommentedBody(ctx.allocator, comment, recipients) catch {
        ctx.sendResult("Failed to build request body.");
        return;
    };
    defer ctx.allocator.free(body);

    const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}/{s}", .{ email_id, action }) catch return;
    defer ctx.allocator.free(path);

    _ = graph.post(ctx.allocator, ctx.io, token, path, body) catch |err| {
        ctx.sendGraphError(err);
        return;
    };

    ctx.sendResult(success_msg);
}

/// Reply to an email (only the original sender gets the reply).
/// Graph: POST /me/messages/{id}/reply with { comment, toRecipients? }
pub fn handleReplyEmail(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide emailId and comment.") orelse return;
    const email_id = ctx.getPathArg(args, "emailId", "Missing 'emailId' argument.") orelse return;
    const comment = ctx.getStringArg(args, "comment", "Missing 'comment' argument (the reply text).") orelse return;

    const extra_to = parseRecipients(ctx.allocator, args, "to") catch return;
    defer if (extra_to) |r| ctx.allocator.free(r);

    sendCommentAction(ctx, token, email_id, "reply", comment, extra_to, false, "Reply sent.");
}

/// Reply to everyone on the original email (original sender + all toRecipients
/// + all ccRecipients).
/// Graph: POST /me/messages/{id}/replyAll with { comment }
pub fn handleReplyAllEmail(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide emailId and comment.") orelse return;
    const email_id = ctx.getPathArg(args, "emailId", "Missing 'emailId' argument.") orelse return;
    const comment = ctx.getStringArg(args, "comment", "Missing 'comment' argument (the reply text).") orelse return;

    sendCommentAction(ctx, token, email_id, "replyAll", comment, null, false, "Reply-all sent.");
}

/// Search the user's mailbox for emails matching a keyword.
/// Graph: GET /me/messages?$search="{q}" with 'ConsistencyLevel: eventual'.
/// The quoted query syntax and ConsistencyLevel header are both required,
/// or the query silently drops attributes on certain fields.
pub fn handleSearchEmails(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide query.") orelse return;
    const query = ctx.getStringArg(args, "query", "Missing 'query' argument.") orelse return;

    // URL-encode the query for path safety. url.encode handles spaces,
    // quotes, and other reserved characters per RFC 3986.
    const encoded = url_util.encode(ctx.allocator, query) catch return;
    defer ctx.allocator.free(encoded);

    // $search values must be wrapped in %22-escaped double-quotes per the
    // Graph spec; otherwise multi-word searches fail.
    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/me/messages?$search=%22{s}%22&$top=25&$select=id,subject,from,receivedDateTime,bodyPreview,webLink",
        .{encoded},
    ) catch return;
    defer ctx.allocator.free(path);

    const headers = [_]std.http.Header{
        .{ .name = "ConsistencyLevel", .value = "eventual" },
    };
    const response = graph.getWithHeaders(ctx.allocator, ctx.io, token, path, &headers) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    if (formatter.summarizeArray(ctx.allocator, response, &list_email_fields)) |summary| {
        defer ctx.allocator.free(summary);
        ctx.sendResult(summary);
    } else {
        ctx.sendResult("No emails matched that query.");
    }
}

/// List the user's mail folders (Inbox, Sent, Drafts, custom folders).
/// Graph: GET /me/mailFolders. IDs are needed for move-email.
pub fn handleListMailFolders(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;

    const response = graph.get(
        ctx.allocator,
        ctx.io,
        token,
        "/me/mailFolders?$top=50&$select=id,displayName,parentFolderId",
    ) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    if (formatter.summarizeArray(ctx.allocator, response, &mail_folder_fields)) |summary| {
        defer ctx.allocator.free(summary);
        ctx.sendResult(summary);
    } else {
        ctx.sendResult("No mail folders found.");
    }
}

/// Forward an email to one or more new recipients.
/// Graph: POST /me/messages/{id}/forward with { comment, toRecipients }
pub fn handleForwardEmail(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide emailId, comment, and to.") orelse return;
    const email_id = ctx.getPathArg(args, "emailId", "Missing 'emailId' argument.") orelse return;
    const comment = ctx.getStringArg(args, "comment", "Missing 'comment' argument (the forward text).") orelse return;

    const to = parseRecipients(ctx.allocator, args, "to") catch return;
    defer if (to) |r| ctx.allocator.free(r);

    sendCommentAction(ctx, token, email_id, "forward", comment, to, true, "Forward sent.");
}

/// List attachments on a received email.
/// Graph: GET /me/messages/{id}/attachments
pub fn handleListEmailAttachments(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide emailId.") orelse return;
    const email_id = ctx.getPathArg(args, "emailId", "Missing 'emailId' argument.") orelse return;

    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/me/messages/{s}/attachments?$select=id,name,contentType,size",
        .{email_id},
    ) catch return;
    defer ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    if (formatter.summarizeArray(ctx.allocator, response, &attachment_list_fields)) |summary| {
        defer ctx.allocator.free(summary);
        ctx.sendResult(summary);
    } else {
        ctx.sendResult("No attachments on this email.");
    }
}

/// Fetch a single attachment's metadata + base64-encoded bytes.
/// Graph: GET /me/messages/{id}/attachments/{aid}
/// For text attachments (small notes, JSON, markdown), base64 is decodable
/// by the LLM client. Binary attachments (PDFs, images) will be moved to
/// a binary-safe temp-file download in Phase 5 — this tool is for text.
pub fn handleReadEmailAttachment(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide emailId and attachmentId.") orelse return;
    const email_id = ctx.getPathArg(args, "emailId", "Missing 'emailId' argument.") orelse return;
    const attach_id = ctx.getPathArg(args, "attachmentId", "Missing 'attachmentId' argument.") orelse return;

    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/me/messages/{s}/attachments/{s}",
        .{ email_id, attach_id },
    ) catch return;
    defer ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    if (formatter.summarizeObject(ctx.allocator, response, &attachment_read_fields)) |summary| {
        defer ctx.allocator.free(summary);
        ctx.sendResult(summary);
    } else {
        ctx.sendResult("Attachment not found.");
    }
}

/// Download a binary email attachment to a temp file.
/// Graph: GET /me/messages/{id}/attachments/{aid} — same endpoint as
/// read-email-attachment, but we base64-decode `contentBytes` and write
/// the raw bytes to /tmp/ via binary_download.saveToTempFile.
///
/// Text attachments also work here, but for small text blobs
/// read-email-attachment is easier because it returns the base64 inline.
pub fn handleDownloadEmailAttachment(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide emailId and attachmentId.") orelse return;
    const email_id = ctx.getPathArg(args, "emailId", "Missing 'emailId' argument.") orelse return;
    const attach_id = ctx.getPathArg(args, "attachmentId", "Missing 'attachmentId' argument.") orelse return;

    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/me/messages/{s}/attachments/{s}",
        .{ email_id, attach_id },
    ) catch return;
    defer ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    // Pull `name` and `contentBytes` out of the response. contentBytes is
    // base64-encoded per Graph's FileAttachment schema.
    const name = json_util.extractString(ctx.allocator, response, "name") orelse
        (ctx.allocator.dupe(u8, "attachment.bin") catch return);
    defer ctx.allocator.free(name);

    const b64 = json_util.extractString(ctx.allocator, response, "contentBytes") orelse {
        ctx.sendResult("Attachment response missing contentBytes — is this a reference attachment (ItemAttachment)? Only FileAttachment is supported.");
        return;
    };
    defer ctx.allocator.free(b64);

    // base64.standard.Decoder.calcSizeForSlice tells us the exact decoded
    // byte count; allocate a buffer that size, then decode into it.
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(b64) catch {
        ctx.sendResult("Attachment contentBytes is not valid base64.");
        return;
    };
    const decoded = ctx.allocator.alloc(u8, decoded_len) catch return;
    defer ctx.allocator.free(decoded);
    decoder.decode(decoded, b64) catch {
        ctx.sendResult("Failed to decode attachment contentBytes.");
        return;
    };

    const local_path = binary_download.saveToTempFile(
        ctx.allocator,
        ctx.io,
        name,
        decoded,
    ) catch {
        ctx.sendResult("Failed to write attachment to a temp path.");
        return;
    };
    defer ctx.allocator.free(local_path);

    const msg = std.fmt.allocPrint(
        ctx.allocator,
        "Downloaded {d} bytes | name: {s} | local_path: {s}",
        .{ decoded.len, name, local_path },
    ) catch return;
    defer ctx.allocator.free(msg);
    ctx.sendResult(msg);
}

/// Mark an email read or unread by flipping its isRead boolean.
/// Graph: PATCH /me/messages/{id} with { "isRead": bool }
pub fn handleMarkReadEmail(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide emailId.") orelse return;
    const email_id = ctx.getPathArg(args, "emailId", "Missing 'emailId' argument.") orelse return;

    // isRead defaults to true ("mark this as read"). args.get returns ?Value;
    // we pattern-match to pull out the bool, defaulting on anything else.
    const is_read: bool = if (args.get("isRead")) |v| switch (v) {
        .bool => |b| b,
        else => true,
    } else true;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}", .{email_id}) catch return;
    defer ctx.allocator.free(path);

    // Tiny fixed-body PATCH — no JSON builder needed.
    const body = if (is_read) "{\"isRead\":true}" else "{\"isRead\":false}";

    _ = graph.patch(ctx.allocator, ctx.io, token, path, body) catch |err| {
        ctx.sendGraphError(err);
        return;
    };

    ctx.sendResult(if (is_read) "Email marked read." else "Email marked unread.");
}

/// Move an email to a different mail folder.
/// Graph: POST /me/messages/{id}/move with { "destinationId": "..." }
/// destinationId is a folder ID (from list-mail-folders), NOT a folder name.
pub fn handleMoveEmail(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide emailId and destinationId.") orelse return;
    const email_id = ctx.getPathArg(args, "emailId", "Missing 'emailId' argument.") orelse return;
    const dest = ctx.getStringArg(args, "destinationId", "Missing 'destinationId' argument (folder ID from list-mail-folders).") orelse return;

    // Build the tiny body with std.json so we properly escape the folder ID.
    var body: ObjectMap = .empty;
    defer body.deinit(ctx.allocator);
    body.put(ctx.allocator, "destinationId", .{ .string = dest }) catch return;

    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(Value{ .object = body }, .{}, &json_buf.writer) catch return;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}/move", .{email_id}) catch return;
    defer ctx.allocator.free(path);

    _ = graph.post(ctx.allocator, ctx.io, token, path, json_buf.written()) catch |err| {
        ctx.sendGraphError(err);
        return;
    };

    ctx.sendResult("Email moved.");
}

// --- Tests ---

const testing = std.testing;

fn buildTestArgs(key: []const u8, items: []const Value) ObjectMap {
    var args: ObjectMap = .empty;
    var arr = Array.init(testing.allocator);
    for (items) |item| {
        arr.append(item) catch {};
    }
    args.put(testing.allocator, key, .{ .array = arr }) catch {};
    return args;
}

test "parseRecipients valid array" {
    var args = buildTestArgs("to", &.{ .{ .string = "a@b.com" }, .{ .string = "c@d.com" } });
    defer args.deinit(testing.allocator);
    const recipients = (try parseRecipients(testing.allocator, args, "to")).?;
    defer testing.allocator.free(recipients);
    try testing.expectEqual(@as(usize, 2), recipients.len);
    try testing.expectEqualStrings("a@b.com", recipients[0].emailAddress.address);
    try testing.expectEqualStrings("c@d.com", recipients[1].emailAddress.address);
}

test "parseRecipients missing key returns null" {
    var args: ObjectMap = .empty;
    defer args.deinit(testing.allocator);
    try testing.expect((try parseRecipients(testing.allocator, args, "to")) == null);
}

test "parseRecipients non-array returns null" {
    var args: ObjectMap = .empty;
    defer args.deinit(testing.allocator);
    args.put(testing.allocator, "to", .{ .string = "a@b.com" }) catch {};
    try testing.expect((try parseRecipients(testing.allocator, args, "to")) == null);
}

test "parseRecipients non-string element returns null" {
    var args = buildTestArgs("to", &.{.{ .integer = 42 }});
    defer args.deinit(testing.allocator);
    try testing.expect((try parseRecipients(testing.allocator, args, "to")) == null);
}

test "parseRecipients empty array" {
    var args = buildTestArgs("to", &.{});
    defer args.deinit(testing.allocator);
    const recipients = (try parseRecipients(testing.allocator, args, "to")).?;
    defer testing.allocator.free(recipients);
    try testing.expectEqual(@as(usize, 0), recipients.len);
}

test "parseRecipients struct shape" {
    var args = buildTestArgs("to", &.{.{ .string = "test@example.com" }});
    defer args.deinit(testing.allocator);
    const recipients = (try parseRecipients(testing.allocator, args, "to")).?;
    defer testing.allocator.free(recipients);
    try testing.expectEqualStrings("test@example.com", recipients[0].emailAddress.address);
}
