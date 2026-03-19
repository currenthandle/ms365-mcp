// state.zig — Session state and authentication guards.

const std = @import("std");
const types = @import("types.zig");
const auth = @import("auth.zig");
const graph = @import("graph.zig");
const json_rpc = @import("json_rpc.zig");

/// Server state that persists across tool calls within a session.
/// We need this because the login flow is split across two tool calls:
///   1. "login" gets the device code and stashes it here
///   2. "verify-login" reads it from here and polls for the token
pub const State = struct {
    pending_device_code: ?auth.DeviceCodeResponse = null,
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    /// Unix timestamp (seconds) when the access token expires.
    expires_at: i64 = 0,
    /// The user's timezone in Microsoft format (e.g. "Eastern Standard Time").
    /// Detected from the system clock at startup. On first calendar tool call,
    /// we fetch from /me/mailboxSettings and compare. Updated by sync-timezone.
    timezone: []const u8 = "UTC",
    /// Whether we've done the one-time timezone check against mailbox settings.
    /// false = not yet checked, true = checked (and either matched or user was notified).
    timezone_checked: bool = false,
};

/// Check if the user is logged in. If yes, returns the access token.
/// If the token is expired, silently refreshes it using the refresh token.
/// If not logged in at all, sends an error response to the client and returns null.
/// Every tool that needs Graph API access calls this first.
pub fn requireAuth(state: *State, allocator: std.mem.Allocator, io: std.Io, client_id: []const u8, tenant_id: []const u8, writer: *json_rpc.Writer, request_id: i64) ?[]const u8 {
    if (state.access_token) |token| {
        // Check if token is expired (with 5-minute buffer).
        const now_secs = std.Io.Timestamp.now(io, .real).toSeconds();
        if (now_secs < state.expires_at - 300) {
            // Token is still valid — use it.
            return token;
        }

        // Token expired or about to expire — try silent refresh.
        if (state.refresh_token) |rt| {
            if (auth.refreshToken(allocator, io, client_id, tenant_id, rt)) |new_token| {
                // Free old token strings.
                allocator.free(token);
                allocator.free(rt);

                // Update state with new tokens.
                state.access_token = new_token.access_token;
                state.refresh_token = new_token.refresh_token;
                const new_expires_at = now_secs + new_token.expires_in;
                state.expires_at = new_expires_at;

                // Save to disk so next startup uses the fresh token.
                auth.saveToken(allocator, io, new_token.access_token, new_token.refresh_token, new_token.expires_in) catch |err| {
                    std.debug.print("ms-mcp: failed to save refreshed token: {}\n", .{err});
                };

                return state.access_token;
            }
        }

        // Refresh failed — token is expired and we can't fix it.
        // Clear the stale token so the LLM knows to call login.
        state.access_token = null;
        state.refresh_token = null;
        state.expires_at = 0;
    }

    // No token — send an error telling the LLM to call login first.
    const content: []const types.TextContent = &.{
        .{ .text = "Not logged in. Call login first." },
    };
    json_rpc.sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = request_id,
        .result = .{ .content = content },
    });
    return null;
}

/// One-time timezone check for calendar tools.
/// On first calendar call, fetches the timezone from /me/mailboxSettings
/// and compares it to the system timezone. If they differ, sends a message
/// asking the user if they want to sync. Returns true if the calendar tool
/// should proceed, false if we sent a mismatch warning instead.
pub fn checkTimezone(state: *State, allocator: std.mem.Allocator, io: std.Io, token: []const u8, writer: *json_rpc.Writer, request_id: i64) bool {
    // Already checked this session — proceed.
    if (state.timezone_checked) return true;

    // Mark as checked so we only do this once.
    state.timezone_checked = true;

    // Fetch the mailbox timezone from Microsoft.
    const response_body = graph.get(allocator, io, token, "/me/mailboxSettings/timeZone") catch |err| {
        // Can't reach the API — log it and proceed with the system timezone.
        std.debug.print("ms-mcp: could not fetch mailbox timezone: {}\n", .{err});
        return true;
    };
    defer allocator.free(response_body);

    // Parse the response. Shape: {"@odata.context": "...", "value": "Pacific Standard Time"}
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        response_body,
        .{},
    ) catch return true;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return true,
    };

    const mailbox_tz_val = obj.get("value") orelse return true;
    const mailbox_tz = switch (mailbox_tz_val) {
        .string => |s| s,
        else => return true,
    };

    // Compare mailbox timezone to system timezone.
    if (std.mem.eql(u8, mailbox_tz, state.timezone)) {
        // They match — proceed normally.
        std.debug.print("ms-mcp: mailbox timezone matches system: {s}\n", .{state.timezone});
        return true;
    }

    // Mismatch — tell the user and suggest sync-timezone.
    std.debug.print("ms-mcp: timezone mismatch: mailbox={s} system={s}\n", .{ mailbox_tz, state.timezone });
    const msg = std.fmt.allocPrint(
        allocator,
        "Timezone mismatch detected: your Microsoft 365 mailbox is set to \"{s}\" but your computer is set to \"{s}\". Call the sync-timezone tool to update your mailbox to match your computer, then retry this command.",
        .{ mailbox_tz, state.timezone },
    ) catch return true;
    defer allocator.free(msg);
    const content: []const types.TextContent = &.{
        .{ .text = msg },
    };
    json_rpc.sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = request_id,
        .result = .{ .content = content },
    });
    return false;
}
