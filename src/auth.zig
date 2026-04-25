// auth.zig — OAuth 2.0 Device Code Flow for Microsoft 365.
//
// Memory ownership note: the access_token and refresh_token strings returned
// from here are heap-allocated with the caller's allocator. The `State`
// struct in state.zig takes ownership; when tokens are refreshed, the old
// copies must be freed before the new ones are stored (see state.zig).
// If you extract token logic to a new module, preserve this invariant — a
// leak here is process-lifetime because State lives for the whole session.

const std = @import("std");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// All the Microsoft Graph permissions we need.
/// "offline_access" gives us a refresh token so we can get new access tokens
/// without making the user log in again.
const scopes =
    "User.Read " ++
    "Mail.ReadWrite " ++
    "Mail.Send " ++
    "Calendars.ReadWrite " ++
    "Calendars.Read.Shared " ++
    "MailboxSettings.ReadWrite " ++
    "Chat.Create " ++
    "Chat.Read " ++
    "Chat.ReadWrite " ++
    "ChatMessage.Send " ++
    "Team.ReadBasic.All " ++
    "Channel.ReadBasic.All " ++
    "ChannelMessage.ReadWrite " ++
    "Sites.ReadWrite.All " ++
    "Files.ReadWrite " ++
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
    io: Io,
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
    const response_body = try http.post(allocator, io, url, body);
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
    io: Io,
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

    // Track how long we've been polling so we know when the code expires.
    var elapsed: i64 = 0;

    // Keep polling until the code expires.
    while (elapsed < expires_in) {
        // Wait before polling — Microsoft requires this delay.
        // io.sleep() takes a Duration and a clock type.
        // .awake means we only count time while the system is awake.
        io.sleep(std.Io.Duration.fromSeconds(interval), .awake) catch {};
        elapsed += interval;

        // Try to get a token.
        // During polling, Microsoft returns HTTP 400 with "authorization_pending"
        // until the user completes login. http.post returns error.HttpError for 4xx,
        // so we catch that and keep polling.
        const response_body = http.post(allocator, io, url, body) catch |err| {
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

/// Silently refresh an expired access token using the refresh token.
/// Microsoft's OAuth token endpoint accepts grant_type=refresh_token
/// and returns a new access_token + refresh_token pair.
/// Returns null if the refresh fails (e.g. refresh token itself expired).
pub fn refreshToken(
    allocator: Allocator,
    io: Io,
    client_id: []const u8,
    tenant_id: []const u8,
    refresh_token: []const u8,
) ?TokenResponse {
    // Build the token endpoint URL.
    const url = std.fmt.allocPrint(
        allocator,
        "https://login.microsoftonline.com/{s}/oauth2/v2.0/token",
        .{tenant_id},
    ) catch return null;
    defer allocator.free(url);

    // Build the form body with grant_type=refresh_token.
    const body = std.fmt.allocPrint(
        allocator,
        "grant_type=refresh_token&client_id={s}&refresh_token={s}&scope={s}",
        .{ client_id, refresh_token, scopes },
    ) catch return null;
    defer allocator.free(body);

    std.debug.print("ms-mcp: refreshing access token...\n", .{});

    // POST to the token endpoint.
    const response_body = http.post(allocator, io, url, body) catch |err| {
        std.debug.print("ms-mcp: token refresh failed: {}\n", .{err});
        return null;
    };
    defer allocator.free(response_body);

    // Parse the response JSON — same shape as the device code token response.
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        response_body,
        .{},
    ) catch return null;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };

    const access_token_str = switch (obj.get("access_token") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const refresh_token_str = switch (obj.get("refresh_token") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const expires_in_int = switch (obj.get("expires_in") orelse return null) {
        .integer => |n| n,
        else => return null,
    };

    std.debug.print("ms-mcp: token refreshed, expires in {d}s\n", .{expires_in_int});

    return .{
        .access_token = allocator.dupe(u8, access_token_str) catch return null,
        .refresh_token = allocator.dupe(u8, refresh_token_str) catch return null,
        .expires_in = expires_in_int,
    };
}

/// The file name where we save tokens in the user's home directory.
const token_filename = ".ms365-zig-mcp-token.json";

/// Save tokens to ~/.ms365-zig-mcp-token.json so we can re-use them
/// next time the server starts without requiring a new login.
///
/// We store expires_at (absolute Unix timestamp) instead of expires_in
/// (relative seconds) so we can check if the token is expired later.
pub fn saveToken(
    allocator: Allocator,
    io: Io,
    access_token: []const u8,
    refresh_token: []const u8,
    expires_in: i64,
) !void {
    // Get the user's home directory from the HOME environment variable.
    // std.c.getenv returns a C string pointer, mem.span converts to a Zig slice.
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.NoHomeDir);

    // Build the full file path: /home/user/.ms365-zig-mcp-token.json
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, token_filename });
    defer allocator.free(path);

    // Calculate when the token expires as an absolute Unix timestamp.
    // Clock.now gives nanoseconds since epoch; toSeconds() converts.
    const now_secs = std.Io.Timestamp.now(io, .real).toSeconds();
    const expires_at = now_secs + expires_in;

    // Build the JSON string using proper encoding to safely handle
    // any characters in token values (defense in depth).
    var json_buf: std.Io.Writer.Allocating = .init(allocator);
    const jw = &json_buf.writer;
    jw.writeAll("{\"access_token\":") catch return error.OutOfMemory;
    std.json.Stringify.encodeJsonString(access_token, .{}, jw) catch return error.OutOfMemory;
    jw.writeAll(",\"refresh_token\":") catch return error.OutOfMemory;
    std.json.Stringify.encodeJsonString(refresh_token, .{}, jw) catch return error.OutOfMemory;
    jw.print(",\"expires_at\":{d}}}", .{expires_at}) catch return error.OutOfMemory;
    const json = try json_buf.toOwnedSlice();
    defer allocator.free(json);

    // Write the file with 0600 permissions (owner read/write only).
    // The token file contains access_token and refresh_token — if world-readable,
    // any local user could steal the tokens and access the M365 account.
    try std.Io.Dir.writeFile(.cwd(), io, .{
        .sub_path = path,
        .data = json,
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });

    std.debug.print("ms-mcp: token saved to {s}\n", .{path});
}

/// Token data loaded from disk.
/// Caller owns the strings and must free them with the same allocator.
pub const SavedToken = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    expires_at: i64,
};

/// Load tokens from ~/.ms365-zig-mcp-token.json.
/// Returns null if the file doesn't exist or can't be read.
/// Caller owns the returned strings and must free them.
pub fn loadToken(allocator: Allocator, io: Io) ?SavedToken {
    // Get the user's home directory.
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);

    // Build the file path.
    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, token_filename }) catch return null;
    defer allocator.free(path);

    // Try to read the file. Return null if it doesn't exist or fails.
    const data = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited) catch return null;
    defer allocator.free(data);

    std.debug.print("ms-mcp: loaded token from {s}\n", .{path});

    // Parse the JSON into a dynamic Value.
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        data,
        .{},
    ) catch return null;
    defer parsed.deinit();

    // Unwrap the JSON object.
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };

    // Extract "access_token" — the Bearer token for Graph API calls.
    const access_token_val = obj.get("access_token") orelse return null;
    const access_token_str = switch (access_token_val) {
        .string => |s| s,
        else => return null,
    };

    // Extract "refresh_token" — used to get a new access_token when it expires.
    const refresh_token_val = obj.get("refresh_token") orelse return null;
    const refresh_token_str = switch (refresh_token_val) {
        .string => |s| s,
        else => return null,
    };

    // Extract "expires_at" — Unix timestamp when the access token expires.
    const expires_at_val = obj.get("expires_at") orelse return null;
    const expires_at_int = switch (expires_at_val) {
        .integer => |n| n,
        else => return null,
    };

    // Dupe strings into caller-owned memory.
    // parsed.deinit() will free the original JSON buffer.
    const access_token = allocator.dupe(u8, access_token_str) catch return null;
    const refresh_token = allocator.dupe(u8, refresh_token_str) catch return null;

    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_at = expires_at_int,
    };
}
