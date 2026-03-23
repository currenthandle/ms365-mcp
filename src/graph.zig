// graph.zig — Microsoft Graph API client.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Base URL for all Microsoft Graph API v1.0 endpoints.
const base_url = "https://graph.microsoft.com/v1.0";

/// Make an authenticated GET request to the Graph API.
///
/// `path` is the API path after /v1.0, e.g. "/me/messages".
/// `access_token` is the OAuth Bearer token from the login flow.
///
/// Returns the response body as an allocated slice — caller must free it.
pub fn get(allocator: Allocator, io: Io, access_token: []const u8, path: []const u8) ![]u8 {
    return request(allocator, io, access_token, .GET, path, null);
}

/// Make an authenticated POST request to the Graph API with a JSON body.
///
/// `path` is the API path after /v1.0, e.g. "/me/sendMail".
/// `json_body` is the JSON string to send as the request body.
///
/// Returns the response body as an allocated slice — caller must free it.
/// Note: some Graph endpoints (like sendMail) return 202 with an empty body on success.
pub fn post(allocator: Allocator, io: Io, access_token: []const u8, path: []const u8, json_body: ?[]const u8) ![]u8 {
    return request(allocator, io, access_token, .POST, path, json_body);
}

/// Strip the Graph API base URL prefix from a full URL.
/// The @odata.nextLink values are full URLs like
/// "https://graph.microsoft.com/v1.0/teams/..." — this returns just the
/// path portion "/teams/..." so it can be passed to our get() function.
/// If the prefix isn't found, returns the input unchanged.
pub fn stripGraphPrefix(url: []const u8) []const u8 {
    if (std.mem.startsWith(u8, url, base_url)) {
        return url[base_url.len..];
    }
    return url;
}

/// Make an authenticated GET request with an additional Prefer header.
/// Used for calendar endpoints that accept `Prefer: outlook.timezone="..."`.
/// This makes the API return times in the specified timezone AND interpret
/// query parameters (like startDateTime) in that timezone.
pub fn getWithPrefer(allocator: Allocator, io: Io, access_token: []const u8, path: []const u8, prefer: []const u8) ![]u8 {
    // Build the full URL.
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, path });
    defer allocator.free(url);

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth_header);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var response_buf: std.Io.Writer.Allocating = .init(allocator);
    defer response_buf.deinit();

    // Debug: log the request.
    std.debug.print("ms-mcp: {s} {s}\n", .{ "GET", url });

    // Three headers: Authorization, Prefer, and no Content-Type (GET has no body).
    const headers = &[_]std.http.Header{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Prefer", .value = prefer },
    };

    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = headers,
        .response_writer = &response_buf.writer,
    });

    return response_buf.toOwnedSlice();
}

/// Make an authenticated PATCH request to the Graph API with a JSON body.
///
/// `path` is the API path after /v1.0, e.g. "/me/events/{id}".
/// `json_body` is the JSON string with the fields to update.
///
/// Returns the response body as an allocated slice — caller must free it.
pub fn patch(allocator: Allocator, io: Io, access_token: []const u8, path: []const u8, json_body: []const u8) ![]u8 {
    return request(allocator, io, access_token, .PATCH, path, json_body);
}

/// Make an authenticated DELETE request to the Graph API.
///
/// `path` is the API path after /v1.0, e.g. "/me/events/{id}".
///
/// DELETE endpoints return 204 No Content — no response body.
/// We skip the response_writer to avoid hanging on the empty body.
pub fn delete(allocator: Allocator, io: Io, access_token: []const u8, path: []const u8) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, path });
    defer allocator.free(url);

    std.debug.print("ms-mcp: DELETE {s}\n", .{url});

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth_header);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    // keep_alive=false sends "Connection: close" so the server closes the
    // connection after the 204 response. Without this, discardRemaining()
    // blocks waiting for data that will never come on the keep-alive connection.
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .DELETE,
        .keep_alive = false,
        .extra_headers = &[_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
        },
    });
}

/// Internal: shared logic for all Graph API requests.
/// Builds the URL, sets up auth headers, sends the request, checks for errors.
///
/// If `json_body` is non-null, sends it as a JSON POST/PATCH/etc.
/// If null, sends a GET (or whatever `method` says) with no body.
fn request(
    allocator: Allocator,
    io: Io,
    access_token: []const u8,
    method: std.http.Method,
    path: []const u8,
    json_body: ?[]const u8,
) ![]u8 {
    // Build the full URL: https://graph.microsoft.com/v1.0{path}
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, path });
    defer allocator.free(url);

    // Debug: log the full URL and body so we can diagnose request issues.
    std.debug.print("ms-mcp: {s} {s}\n", .{ @tagName(method), url });
    if (json_body) |b| std.debug.print("ms-mcp: body={s}\n", .{b});

    // Build the Authorization header value: "Bearer {token}"
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth_header);

    // Create an HTTP client with network-capable Io.
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    // Dynamically growing buffer for the response body.
    var response_buf: std.Io.Writer.Allocating = .init(allocator);
    defer response_buf.deinit();

    // Build the headers list.
    // Always include Authorization. Add Content-Type if we have a JSON body.
    const headers_with_content_type = &[_]std.http.Header{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Content-Type", .value = "application/json" },
    };
    const headers_auth_only = &[_]std.http.Header{
        .{ .name = "Authorization", .value = auth_header },
    };

    // fetch() sends the request and reads the response in one call.
    // We don't check the status — we always return the body.
    // _ discards the result since Zig requires all values to be used.
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = json_body,
        .extra_headers = if (json_body != null) headers_with_content_type else headers_auth_only,
        .response_writer = &response_buf.writer,
    });

    // Always return the response body — even on errors.
    // If Microsoft returns a 4xx/5xx, the body contains a JSON error
    // message explaining what went wrong. The LLM can read it and
    // tell the user, which is way more useful than a generic "failed".
    return response_buf.toOwnedSlice();
}

// --- Tests ---

const testing = std.testing;

test "stripGraphPrefix removes base URL" {
    const result = stripGraphPrefix("https://graph.microsoft.com/v1.0/teams/abc");
    try testing.expectEqualStrings("/teams/abc", result);
}

test "stripGraphPrefix relative path unchanged" {
    const result = stripGraphPrefix("/me/messages");
    try testing.expectEqualStrings("/me/messages", result);
}

test "stripGraphPrefix empty string" {
    const result = stripGraphPrefix("");
    try testing.expectEqualStrings("", result);
}

test "stripGraphPrefix SSRF: @-sign after prefix strips to unsafe path" {
    // Documents the SSRF vulnerability: a crafted nextLink like
    // "https://graph.microsoft.com/v1.0@evil.com/x" strips to "@evil.com/x"
    // which does NOT start with "/" — this should be validated by callers.
    const result = stripGraphPrefix("https://graph.microsoft.com/v1.0@evil.com/x");
    try testing.expectEqualStrings("@evil.com/x", result);
}
