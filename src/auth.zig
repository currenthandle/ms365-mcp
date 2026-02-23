// auth.zig — OAuth 2.0 Device Code Flow for Microsoft 365.
//
// Microsoft's device code flow works in two phases:
// 1. Request a device code — we get back a short code + URL for the user
// 2. Poll for a token — we keep asking "did they log in yet?" until they do

const std = @import("std");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;

/// All the Microsoft Graph permissions we need.
/// "offline_access" gives us a refresh token so we can get new access tokens
/// without making the user log in again.
const scopes =
    "User.Read " ++
    "Mail.Read " ++
    "Mail.Send " ++
    "Calendars.ReadWrite " ++
    "Chat.Read " ++
    "Chat.ReadWrite " ++
    "ChatMessage.Send " ++
    "offline_access";

/// What Microsoft sends back when we request a device code.
/// The user_code and verification_uri are what we show to the user.
/// The device_code is what we use to poll for the token (phase 2).
pub const DeviceCodeResponse = struct {
    user_code: []const u8,
    device_code: []const u8,
    verification_uri: []const u8,
    expires_in: i64,
    interval: i64,
};

/// What Microsoft sends back when the user completes login.
/// access_token is what we attach to Graph API calls.
/// refresh_token lets us get a new access_token without re-login.
pub const TokenResponse = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    expires_in: i64,
};

/// Phase 1: Ask Microsoft for a device code.
///
/// Returns a DeviceCodeResponse with the code + URL to show the user.
/// The caller is responsible for freeing the returned strings
/// (user_code, device_code, verification_uri) with the same allocator.
pub fn requestDeviceCode(
    allocator: Allocator,
    client_id: []const u8,
    tenant_id: []const u8,
) !DeviceCodeResponse {
    // Build the URL: https://login.microsoftonline.com/{tenant}/oauth2/v2.0/devicecode
    const url = try std.fmt.allocPrint(
        allocator,
        "https://login.microsoftonline.com/{s}/oauth2/v2.0/devicecode",
        .{tenant_id},
    );
    defer allocator.free(url);

    // Build the form body: client_id=...&scope=...
    const body = try std.fmt.allocPrint(
        allocator,
        "client_id={s}&scope={s}",
        .{ client_id, scopes },
    );
    defer allocator.free(body);

    // POST to Microsoft's device code endpoint.
    // http.post returns the raw response body as an allocated slice.
    const response_body = try http.post(allocator, url, body);
    defer allocator.free(response_body);

    // Parse the JSON response into a dynamic Value so we can extract fields.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        response_body,
        .{},
    );
    defer parsed.deinit();

    // The top-level response should be a JSON object.
    // Switch on the parsed value to unwrap it; error if it's not an object.
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };

    // Extract each field from the JSON response.
    // Pattern for each field:
    //   1. obj.get("key") — returns optional (?Value), null if key missing
    //   2. orelse — if null (key missing), return error
    //   3. switch on the Value type — .string or .integer
    //   4. else — if wrong type, return error
    //   5. allocator.dupe() — copy string into caller-owned memory,
    //      because parsed.deinit() will free the original JSON buffer

    // "user_code" — the short code the user types into the browser.
    const user_code_val = obj.get("user_code") orelse return error.InvalidResponse;
    const user_code_str = switch (user_code_val) {
        .string => |s| s,
        else => return error.InvalidResponse,
    };

    // "device_code" — long opaque string we send back when polling for the token.
    const device_code_val = obj.get("device_code") orelse return error.InvalidResponse;
    const device_code_str = switch (device_code_val) {
        .string => |s| s,
        else => return error.InvalidResponse,
    };

    // "verification_uri" — URL where the user enters the code.
    const verification_uri_val = obj.get("verification_uri") orelse return error.InvalidResponse;
    const verification_uri_str = switch (verification_uri_val) {
        .string => |s| s,
        else => return error.InvalidResponse,
    };

    // "expires_in" — how many seconds until the device code expires.
    const expires_in_val = obj.get("expires_in") orelse return error.InvalidResponse;
    const expires_in_int = switch (expires_in_val) {
        .integer => |n| n,
        else => return error.InvalidResponse,
    };

    // "interval" — how many seconds to wait between poll attempts.
    const interval_val = obj.get("interval") orelse return error.InvalidResponse;
    const interval_int = switch (interval_val) {
        .integer => |n| n,
        else => return error.InvalidResponse,
    };

    // Build the result. dupe() copies strings into caller-owned memory,
    // because parsed.deinit() above will free the original JSON buffer.
    return .{
        .user_code = try allocator.dupe(u8, user_code_str),
        .device_code = try allocator.dupe(u8, device_code_str),
        .verification_uri = try allocator.dupe(u8, verification_uri_str),
        .expires_in = expires_in_int,
        .interval = interval_int,
    };
}

/// Phase 2: Poll Microsoft's token endpoint until the user logs in.
///
/// After requestDeviceCode, the user has a code to enter at a URL.
/// This function keeps asking "did they log in yet?" every `interval` seconds
/// until either:
/// - They log in → we get back tokens
/// - The code expires → we return an error
/// - Microsoft says to slow down → we increase the interval
///
/// The caller is responsible for freeing the returned strings
/// (access_token, refresh_token) with the same allocator.
pub fn pollForToken(
    allocator: Allocator,
    client_id: []const u8,
    tenant_id: []const u8,
    device_code: []const u8,
    expires_in: i64,
    interval: i64,
) !TokenResponse {
    // Build the token endpoint URL.
    const url = try std.fmt.allocPrint(
        allocator,
        "https://login.microsoftonline.com/{s}/oauth2/v2.0/token",
        .{tenant_id},
    );
    defer allocator.free(url);

    // Build the form body. "grant_type=urn:ietf:params:oauth:grant-type:device_code"
    // tells Microsoft we're using the device code flow.
    const body = try std.fmt.allocPrint(
        allocator,
        "grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id={s}&device_code={s}",
        .{ client_id, device_code },
    );
    defer allocator.free(body);

    // Poll interval in seconds. @intCast converts i64 to u64 since sleep takes unsigned.
    // TODO: make this var once we handle Microsoft's "slow_down" response
    // (which tells us to increase the interval).
    const poll_interval: u64 = @intCast(interval);

    // Total seconds before the device code expires.
    const deadline: u64 = @intCast(expires_in);
    var elapsed: u64 = 0;

    // Keep polling until the code expires.
    while (elapsed < deadline) {
        // Wait before polling — Microsoft requires this delay.
        // std.Thread.sleep takes nanoseconds, so multiply by ns_per_s.
        std.Thread.sleep(poll_interval * std.time.ns_per_s);
        elapsed += poll_interval;

        // Try to get a token.
        // During polling, Microsoft returns HTTP 400 with "authorization_pending"
        // until the user completes login. http.post returns error.HttpError for 4xx,
        // so we catch that and keep polling.
        const response_body = http.post(allocator, url, body) catch |err| {
            if (err == error.HttpError) {
                // Expected — user hasn't logged in yet. Keep waiting.
                std.debug.print("ms-mcp: waiting for user to log in...\n", .{});
                continue;
            }
            // Unexpected error (network failure, etc.) — give up.
            return err;
        };
        defer allocator.free(response_body);

        // If we got here, Microsoft returned 2xx — the user logged in!
        // Parse the token response JSON.
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            response_body,
            .{},
        );
        defer parsed.deinit();

        // Unwrap the JSON object.
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidResponse,
        };

        // Look up "access_token" in the JSON object.
        // obj.get() returns an optional (?Value) — null if the key doesn't exist.
        // orelse: if null, bail out with an error.
        const access_token_val = obj.get("access_token") orelse return error.InvalidResponse;
        // The value exists, but is it a string? Switch on the JSON type.
        // .string => extract the string slice; else => wrong type, bail out.
        const access_token_str = switch (access_token_val) {
            .string => |s| s,
            else => return error.InvalidResponse,
        };

        // Same pattern for refresh_token.
        const refresh_token_val = obj.get("refresh_token") orelse return error.InvalidResponse;
        const refresh_token_str = switch (refresh_token_val) {
            .string => |s| s,
            else => return error.InvalidResponse,
        };

        // expires_in is an integer (seconds until the access token expires).
        const expires_in_val = obj.get("expires_in") orelse return error.InvalidResponse;
        const expires_in_int = switch (expires_in_val) {
            .integer => |n| n,
            else => return error.InvalidResponse,
        };

        // Build the result. dupe() copies strings into caller-owned memory,
        // because parsed.deinit() above will free the original JSON buffer.
        return .{
            .access_token = try allocator.dupe(u8, access_token_str),
            .refresh_token = try allocator.dupe(u8, refresh_token_str),
            .expires_in = expires_in_int,
        };
    }

    // If we get here, the device code expired before the user logged in.
    return error.DeviceCodeExpired;
}
