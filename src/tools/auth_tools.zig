// tools/auth_tools.zig — Login, session setup, and account tools.

const std = @import("std");
const auth = @import("../auth.zig");
const graph = @import("../graph.zig");
const json_rpc = @import("../json_rpc.zig");
const tz = @import("../timezone.zig");
const ToolContext = @import("context.zig").ToolContext;

/// Start the OAuth device code flow — ask Microsoft for a code.
pub fn handleLogin(ctx: ToolContext) void {
    const dc = auth.requestDeviceCode(ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id) catch {
        ctx.sendResult("Failed to start login flow");
        return;
    };

    // Stash the device code in state so verify-login can use it.
    ctx.state.pending_device_code = dc;

    const msg = std.fmt.allocPrint(
        ctx.allocator,
        "Go to {s} and enter code: {s}\nImmediately call the verify-login tool now. It will poll and wait for the user to complete sign-in.",
        .{ dc.verification_uri, dc.user_code },
    ) catch return;
    defer ctx.allocator.free(msg);

    ctx.sendResult(msg);
}

/// Poll Microsoft's token endpoint until the user completes login.
pub fn handleVerifyLogin(ctx: ToolContext) void {
    const dc = ctx.state.pending_device_code orelse {
        ctx.sendResult("No pending login. Call login first.");
        return;
    };

    const token = auth.pollForToken(
        ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id,
        dc.device_code, dc.expires_in, dc.interval,
    ) catch {
        ctx.sendResult("Login failed or timed out. Try login again.");
        return;
    };

    // Save tokens to disk for next session.
    auth.saveToken(ctx.allocator, ctx.io, token.access_token, token.refresh_token, token.expires_in) catch {};

    // Store in state for Graph API calls.
    ctx.state.access_token = token.access_token;
    ctx.state.refresh_token = token.refresh_token;
    ctx.state.expires_at = std.Io.Timestamp.now(ctx.io, .real).toSeconds() + token.expires_in;

    // Clean up pending device code.
    ctx.allocator.free(dc.user_code);
    ctx.allocator.free(dc.device_code);
    ctx.allocator.free(dc.verification_uri);
    ctx.state.pending_device_code = null;

    ctx.sendResult("Login successful!");
}

/// Fetch the user's mailbox settings (timezone, locale, date/time formats).
pub fn handleGetMailboxSettings(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;

    const response = graph.get(ctx.allocator, ctx.io, token, "/me/mailboxSettings") catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}

/// Detect system timezone and update Microsoft 365 mailbox to match.
pub fn handleSyncTimezone(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;

    // Step 1: Read the system timezone (IANA format from macOS).
    var tz_buf: [256]u8 = undefined;
    const iana_tz = tz.getSystemTimezone(&tz_buf) orelse {
        ctx.sendResult("Could not detect system timezone from /etc/localtime.");
        return;
    };

    // Step 2: Map IANA → Windows timezone name.
    const windows_tz = tz.ianaToWindows(iana_tz) orelse {
        const msg = std.fmt.allocPrint(ctx.allocator, "Unknown timezone: {s}. Add it to the IANA-to-Windows mapping table.", .{iana_tz}) catch return;
        defer ctx.allocator.free(msg);
        ctx.sendResult(msg);
        return;
    };

    // Step 3: PATCH /me/mailboxSettings to update the timezone.
    const patch_body = std.fmt.allocPrint(ctx.allocator, "{{\"timeZone\":\"{s}\"}}", .{windows_tz}) catch return;
    defer ctx.allocator.free(patch_body);

    _ = graph.patch(ctx.allocator, ctx.io, token, "/me/mailboxSettings", patch_body) catch |err| {
        ctx.sendGraphError(err);
        return;
    };

    // Step 4: Update in-memory state.
    ctx.state.timezone = windows_tz;
    ctx.state.timezone_checked = true;

    const msg = std.fmt.allocPrint(ctx.allocator, "Timezone synced: {s} → {s}", .{ iana_tz, windows_tz }) catch return;
    defer ctx.allocator.free(msg);
    ctx.sendResult(msg);
}
