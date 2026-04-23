// tools/email.zig — Email reading and sending tools.

const std = @import("std");
const types = @import("../types.zig");
const graph = @import("../graph.zig");
const json_rpc = @import("../json_rpc.zig");
const ToolContext = @import("context.zig").ToolContext;
const formatter = @import("../formatter.zig");

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
    ) catch {
        ctx.sendResult("Failed to fetch emails.");
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

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch {
        ctx.sendResult("Failed to fetch email.");
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

    // Serialize the request struct to JSON.
    const mail_request = types.SendMailRequest{
        .message = .{
            .subject = subject,
            .body = .{ .content = body_text },
            .toRecipients = to,
            .ccRecipients = cc,
            .bccRecipients = bcc,
        },
    };
    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(mail_request, .{ .emit_null_optional_fields = false }, &json_buf.writer) catch return;

    _ = graph.post(ctx.allocator, ctx.io, token, "/me/sendMail", json_buf.written()) catch {
        ctx.sendResult("Failed to send email.");
        return;
    };

    ctx.sendResult("Email sent successfully.");
}

/// Delete an email by ID.
pub fn handleDeleteEmail(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide emailId.") orelse return;
    const email_id = ctx.getPathArg(args, "emailId", "Missing 'emailId' argument.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/messages/{s}", .{email_id}) catch return;
    defer ctx.allocator.free(path);

    graph.delete(ctx.allocator, ctx.io, token, path) catch {
        ctx.sendResult("Failed to delete email.");
        return;
    };

    ctx.sendResult("Email deleted.");
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
