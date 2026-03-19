// tools/auth_tools.zig — Login, session setup, and account tools.

const std = @import("std");
const types = @import("../types.zig");
const auth = @import("../auth.zig");
const graph = @import("../graph.zig");
const json_rpc = @import("../json_rpc.zig");
const state_mod = @import("../state.zig");
const tz = @import("../timezone.zig");
const ToolContext = @import("context.zig").ToolContext;

/// Start the OAuth device code flow — ask Microsoft for a code.
pub fn handleLogin(ctx: ToolContext) void {
    const dc = auth.requestDeviceCode(ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id) catch |err| {
        // Print the actual error so we can debug.
        std.debug.print("ms-mcp: device code request failed: {}\n", .{err});

        // Tell the client the login failed.
        // Explicit type annotation so Zig knows this is []const TextContent.
        const error_content: []const types.TextContent = &.{
            .{ .text = "Failed to start login flow" },
        };
        const error_result = types.ToolCallResult{ .content = error_content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = error_result,
        });
        return;
    };

    // Stash the device code in state so verify-login can use it.
    // Don't free dc strings here — state now owns them.
    ctx.state.pending_device_code = dc;

    // Build a message telling the user where to go and what code to enter.
    const msg = std.fmt.allocPrint(
        ctx.allocator,
        "Go to {s} and enter code: {s}\nImmediately call the verify-login tool now. It will poll and wait for the user to complete sign-in.",
        .{ dc.verification_uri, dc.user_code },
    ) catch return;
    defer ctx.allocator.free(msg);

    // Send the message back to the client.
    const content: []const types.TextContent = &.{
        .{ .text = msg },
    };
    const result = types.ToolCallResult{ .content = content };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = result,
    });
}

/// Poll Microsoft's token endpoint until the user completes login.
pub fn handleVerifyLogin(ctx: ToolContext) void {
    // Check that login was called first —
    // we need the device code from the login step.
    const dc = ctx.state.pending_device_code orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "No pending login. Call login first." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };

    // Poll Microsoft's token endpoint until the user completes login.
    // This blocks until success or the device code expires.
    const token = auth.pollForToken(
        ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id,
        dc.device_code, dc.expires_in, dc.interval,
    ) catch |err| {
        std.debug.print("ms-mcp: token poll failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Login failed or timed out. Try login again." },
        };
        const result = types.ToolCallResult{ .content = content };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = result,
        });
        return;
    };
    // Save tokens to disk so we can re-use them next session.
    auth.saveToken(ctx.allocator, ctx.io, token.access_token, token.refresh_token, token.expires_in) catch |err| {
        std.debug.print("ms-mcp: failed to save token: {}\n", .{err});
    };

    // Store all token info in state for future Graph API calls
    // and silent refresh when the access token expires.
    ctx.state.access_token = token.access_token;
    ctx.state.refresh_token = token.refresh_token;
    const now_secs = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    ctx.state.expires_at = now_secs + token.expires_in;

    // Clean up the pending device code — login is complete.
    // These strings were allocated in requestDeviceCode.
    ctx.allocator.free(dc.user_code);
    ctx.allocator.free(dc.device_code);
    ctx.allocator.free(dc.verification_uri);
    ctx.state.pending_device_code = null;

    const content: []const types.TextContent = &.{
        .{ .text = "Login successful!" },
    };
    const result = types.ToolCallResult{ .content = content };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = result,
    });
}

/// Fetch the user's mailbox settings (timezone, locale, date/time formats).
pub fn handleGetMailboxSettings(ctx: ToolContext) void {
    // Check that the user is logged in.
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    // GET /me/mailboxSettings — returns timezone, locale, date/time formats.
    const response_body = graph.get(ctx.allocator, ctx.io, token, "/me/mailboxSettings") catch |err| {
        std.debug.print("ms-mcp: get-mailbox-settings failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to fetch mailbox settings." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };
    defer ctx.allocator.free(response_body);

    // Return the raw JSON — includes timeZone, language, dateFormat, etc.
    const content: []const types.TextContent = &.{
        .{ .text = response_body },
    };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = .{ .content = content },
    });
}

/// Detect system timezone and update Microsoft 365 mailbox to match.
pub fn handleSyncTimezone(ctx: ToolContext) void {
    // Check that the user is logged in.
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;

    // Step 1: Read the system timezone (IANA format from macOS).
    var sync_tz_buf: [256]u8 = undefined;
    const iana_tz = tz.getSystemTimezone(&sync_tz_buf) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Could not detect system timezone from /etc/localtime." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // Step 2: Map IANA → Windows timezone name.
    const windows_tz = tz.ianaToWindows(iana_tz) orelse {
        // Unknown IANA timezone — tell the user what we found.
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "Unknown timezone: {s}. Add it to the IANA-to-Windows mapping table.",
            .{iana_tz},
        ) catch return;
        defer ctx.allocator.free(msg);
        const content: []const types.TextContent = &.{
            .{ .text = msg },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // Step 3: PATCH /me/mailboxSettings to update the timezone.
    const patch_body = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"timeZone\":\"{s}\"}}",
        .{windows_tz},
    ) catch return;
    defer ctx.allocator.free(patch_body);

    const response_body = graph.patch(ctx.allocator, ctx.io, token, "/me/mailboxSettings", patch_body) catch |err| {
        std.debug.print("ms-mcp: sync-timezone PATCH failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to update mailbox timezone." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };
    defer ctx.allocator.free(response_body);

    // Step 4: Update our in-memory state so all subsequent
    // calendar operations use the new timezone.
    ctx.state.timezone = windows_tz;
    ctx.state.timezone_checked = true;
    std.debug.print("ms-mcp: timezone synced to {s} ({s})\n", .{ windows_tz, iana_tz });

    // Return a confirmation message.
    const msg = std.fmt.allocPrint(
        ctx.allocator,
        "Timezone synced: {s} → {s}",
        .{ iana_tz, windows_tz },
    ) catch return;
    defer ctx.allocator.free(msg);
    const content: []const types.TextContent = &.{
        .{ .text = msg },
    };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = .{ .content = content },
    });
}
