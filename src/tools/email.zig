// tools/email.zig — Email reading and sending tools.

const std = @import("std");
const types = @import("../types.zig");
const graph = @import("../graph.zig");
const json_rpc = @import("../json_rpc.zig");
const state_mod = @import("../state.zig");
const ToolContext = @import("context.zig").ToolContext;

// Type aliases — keeps function signatures cleaner.
const Allocator = std.mem.Allocator;

/// Convert a JSON array of email strings into a slice of Recipient structs.
/// e.g. ["alice@foo.com", "bob@bar.com"] → two Recipient structs.
/// Returns null if the key is missing or isn't an array.
/// pub because drafts.zig also needs this for create-draft and update-draft.
pub fn parseRecipients(
    allocator: Allocator,
    args: std.json.ObjectMap,
    key: []const u8,
) !?[]const types.SendMailRequest.Message.Recipient {
    // Look up the key — if missing, return null (field is optional).
    const val = args.get(key) orelse return null;

    // It should be a JSON array.
    const arr = switch (val) {
        .array => |a| a,
        else => return null,
    };

    // Allocate a slice big enough for all the recipients.
    const recipients = try allocator.alloc(types.SendMailRequest.Message.Recipient, arr.items.len);

    // Fill in each recipient from the array elements.
    for (arr.items, 0..) |item, i| {
        // Each element should be a string (an email address).
        const email = switch (item) {
            .string => |s| s,
            else => {
                // Clean up what we allocated if we hit a non-string.
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
    // Check that the user is logged in.
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    // Call Graph API to list recent emails.
    // $top=10 — only get the 10 most recent
    // $select — only fetch the fields we need (saves bandwidth)
    // $orderby — newest first
    // %20 is a URL-encoded space for "receivedDateTime desc"
    const response_body = graph.get(
        ctx.allocator, ctx.io, token,
        "/me/messages?$top=10&$select=id,subject,from,receivedDateTime,bodyPreview&$orderby=receivedDateTime%20desc",
    ) catch |err| {
        std.debug.print("ms-mcp: list-emails failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to fetch emails." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    defer ctx.allocator.free(response_body);

    // Return the raw JSON to the LLM.
    // The LLM can parse and summarize it for the user.
    const content: []const types.TextContent = &.{
        .{ .text = response_body },
    };
    const result = types.ToolCallResult{ .content = content };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = result,
    });
}

/// Read the full content of a single email by ID.
pub fn handleReadEmail(ctx: ToolContext) void {
    // Check that the user is logged in.
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    // Get tool arguments — emailId is required.
    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing arguments. Provide emailId." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // "emailId" — the ID of the email to read (from list-emails results).
    const email_id = json_rpc.getStringArg(args, "emailId") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'emailId' argument." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // Build the path: /me/messages/{emailId}
    // $select limits to the fields we need — includes full body,
    // all recipients (to, cc), and read status.
    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/me/messages/{s}?$select=id,subject,from,toRecipients,ccRecipients,receivedDateTime,body,isRead",
        .{email_id},
    ) catch return;
    defer ctx.allocator.free(path);

    // GET the email.
    const response_body = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        std.debug.print("ms-mcp: read-email failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to fetch email." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };
    defer ctx.allocator.free(response_body);

    // Return the raw JSON — includes full body content, recipients, etc.
    const content: []const types.TextContent = &.{
        .{ .text = response_body },
    };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = .{ .content = content },
    });
}

/// Send an email immediately via Microsoft Graph.
pub fn handleSendEmail(ctx: ToolContext) void {
    // Check that the user is logged in.
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    // Extract the arguments: to, subject, body.
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

    // Parse "to" — required, must be a JSON array of email strings.
    const to_recipients = parseRecipients(ctx.allocator, args, "to") catch return orelse {
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

    // Parse "cc" — optional array of email addresses.
    const cc_recipients = parseRecipients(ctx.allocator, args, "cc") catch return;
    defer if (cc_recipients) |cc| ctx.allocator.free(cc);

    // Parse "bcc" — optional array of email addresses.
    const bcc_recipients = parseRecipients(ctx.allocator, args, "bcc") catch return;
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

    // Build the Graph API request body for POST /me/sendMail.
    // Using a typed struct instead of a raw format string —
    // Stringify handles JSON formatting, escaping quotes, etc.
    const mail_request = types.SendMailRequest{
        .message = .{
            .subject = subject,
            .body = .{ .content = body_text },
            .toRecipients = to_recipients,
            .ccRecipients = cc_recipients,
            .bccRecipients = bcc_recipients,
        },
    };

    // Serialize the struct to a JSON string.
    // Allocating writer grows a buffer as Stringify writes into it.
    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    // emit_null_optional_fields=false omits null cc/bcc fields
    // instead of sending "ccRecipients":null which Graph rejects.
    std.json.Stringify.value(mail_request, .{ .emit_null_optional_fields = false }, &json_buf.writer) catch return;

    // .written() returns the JSON bytes written so far as a slice.
    const json_body = json_buf.written();

    // Send the email via Graph API.
    _ = graph.post(ctx.allocator, ctx.io, token, "/me/sendMail", json_body) catch |err| {
        std.debug.print("ms-mcp: send-email failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to send email." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // Success!
    const content: []const types.TextContent = &.{
        .{ .text = "Email sent successfully." },
    };
    const result = types.ToolCallResult{ .content = content };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = result,
    });
}
