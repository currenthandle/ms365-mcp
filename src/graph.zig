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

/// Strip the Graph API base URL prefix from a full URL and validate the path.
/// The @odata.nextLink values are full URLs like
/// "https://graph.microsoft.com/v1.0/teams/..." — this returns just the
/// path portion "/teams/..." so it can be passed to our get() function.
/// Returns null if the result is not a valid relative path starting with "/".
/// This prevents SSRF attacks where a crafted pageToken like
/// "https://graph.microsoft.com/v1.0@attacker.com/..." could redirect
/// requests (and the OAuth token) to an attacker-controlled host.
pub fn stripGraphPrefix(url: []const u8) ?[]const u8 {
    const path = if (std.mem.startsWith(u8, url, base_url))
        url[base_url.len..]
    else
        url;
    // Must start with "/" to be a valid Graph API path.
    if (path.len == 0 or path[0] != '/') return null;
    return path;
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

/// Make an authenticated PUT request to the Graph API with a raw body.
///
/// Unlike post/patch, this lets the caller specify Content-Type — required for
/// SharePoint / OneDrive file upload where the body is arbitrary bytes.
/// `path` is the API path after /v1.0.
/// `body` is the raw bytes to upload.
/// `content_type` is the MIME type (e.g. "application/pdf", "text/markdown").
///
/// Returns the response body as an allocated slice — caller must free it.
pub fn put(
    allocator: Allocator,
    io: Io,
    access_token: []const u8,
    path: []const u8,
    body: []const u8,
    content_type: []const u8,
) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, path });
    defer allocator.free(url);

    std.debug.print("ms-mcp: PUT {s} ({d} bytes, {s})\n", .{ url, body.len, content_type });

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth_header);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var response_buf: std.Io.Writer.Allocating = .init(allocator);
    defer response_buf.deinit();

    const headers = &[_]std.http.Header{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Content-Type", .value = content_type },
    };

    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .PUT,
        .payload = body,
        .extra_headers = headers,
        .response_writer = &response_buf.writer,
    });

    return response_buf.toOwnedSlice();
}

/// PUT one chunk of a large-file upload to a pre-authed upload session URL.
///
/// The `upload_url` is the absolute URL returned by createUploadSession
/// (NOT a Graph path) — it already embeds an auth token, so we must NOT
/// send a Bearer header (that would double-auth and fail).
///
/// `chunk` is the bytes for this chunk.
/// `content_range` is the HTTP Content-Range header value, e.g.
/// "bytes 0-10485759/52428800" (start-end inclusive, total file size).
///
/// Returns the response body as an allocated slice — caller must free it.
/// A 202 response means "continue with next chunk"; a 200/201 means "done"
/// and contains the DriveItem JSON.
pub fn putChunk(
    allocator: Allocator,
    io: Io,
    upload_url: []const u8,
    chunk: []const u8,
    content_range: []const u8,
) ![]u8 {
    std.debug.print("ms-mcp: PUT (upload session chunk) {s} bytes, range={s}\n", .{ content_range, content_range });

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var response_buf: std.Io.Writer.Allocating = .init(allocator);
    defer response_buf.deinit();

    // No Authorization header — upload_url is pre-signed.
    const headers = &[_]std.http.Header{
        .{ .name = "Content-Range", .value = content_range },
    };

    _ = try client.fetch(.{
        .location = .{ .url = upload_url },
        .method = .PUT,
        .payload = chunk,
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

    // For empty body (e.g. softDelete), send with Content-Length: 0 but no Content-Type.
    const has_body = if (json_body) |b| b.len > 0 else false;

    // fetch() sends the request and reads the response in one call.
    // We don't check the status — we always return the body.
    // _ discards the result since Zig requires all values to be used.
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = json_body,
        .extra_headers = if (has_body) headers_with_content_type else headers_auth_only,
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
    try testing.expectEqualStrings("/teams/abc", stripGraphPrefix("https://graph.microsoft.com/v1.0/teams/abc").?);
}

test "stripGraphPrefix relative path unchanged" {
    try testing.expectEqualStrings("/me/messages", stripGraphPrefix("/me/messages").?);
}

test "stripGraphPrefix empty string returns null" {
    try testing.expect(stripGraphPrefix("") == null);
}

test "stripGraphPrefix SSRF: @-sign after prefix returns null" {
    // A crafted nextLink like "https://graph.microsoft.com/v1.0@evil.com/x"
    // strips to "@evil.com/x" which doesn't start with "/" — rejected as null.
    try testing.expect(stripGraphPrefix("https://graph.microsoft.com/v1.0@evil.com/x") == null);
}

test "stripGraphPrefix SSRF: different host returns null" {
    try testing.expect(stripGraphPrefix("https://evil.com/steal") == null);
}

// --- Security: additional SSRF attack vectors ---

test "stripGraphPrefix SSRF: double-slash protocol relative" {
    try testing.expect(stripGraphPrefix("//evil.com/steal") == null);
}

test "stripGraphPrefix SSRF: backslash trick" {
    try testing.expect(stripGraphPrefix("https://graph.microsoft.com/v1.0\\@evil.com") == null);
}

test "stripGraphPrefix SSRF: prefix without path" {
    // Just the base URL with no trailing path — should return null since
    // there's no "/" after the prefix.
    try testing.expect(stripGraphPrefix("https://graph.microsoft.com/v1.0") == null);
}

test "stripGraphPrefix SSRF: empty after prefix" {
    try testing.expect(stripGraphPrefix("https://graph.microsoft.com/v1.0") == null);
}

test "stripGraphPrefix SSRF: userinfo in URL" {
    // "https://graph.microsoft.com/v1.0" is the prefix;
    // after stripping, "user@evil.com/..." doesn't start with "/"
    try testing.expect(stripGraphPrefix("https://graph.microsoft.com/v1.0user@evil.com/x") == null);
}

test "stripGraphPrefix valid deep path" {
    try testing.expectEqualStrings(
        "/teams/abc/channels/def/messages",
        stripGraphPrefix("https://graph.microsoft.com/v1.0/teams/abc/channels/def/messages").?,
    );
}

test "stripGraphPrefix valid path with query" {
    try testing.expectEqualStrings(
        "/me/chats?$top=50",
        stripGraphPrefix("https://graph.microsoft.com/v1.0/me/chats?$top=50").?,
    );
}

test "stripGraphPrefix SSRF: data URI" {
    try testing.expect(stripGraphPrefix("data:text/html,<script>alert(1)</script>") == null);
}

test "stripGraphPrefix SSRF: ftp protocol" {
    try testing.expect(stripGraphPrefix("ftp://evil.com/steal") == null);
}
