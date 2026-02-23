// graph.zig — Microsoft Graph API client.
//
// All Graph API calls go to https://graph.microsoft.com/v1.0/...
// Each request needs an Authorization: Bearer {access_token} header.
// This module provides helpers so callers don't have to build URLs
// or set headers manually.

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
pub fn post(allocator: Allocator, io: Io, access_token: []const u8, path: []const u8, json_body: []const u8) ![]u8 {
    return request(allocator, io, access_token, .POST, path, json_body);
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
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = json_body,
        .extra_headers = if (json_body != null) headers_with_content_type else headers_auth_only,
        .response_writer = &response_buf.writer,
    });

    // Check for HTTP errors (anything 400+).
    if (@intFromEnum(result.status) >= 400) {
        std.debug.print("ms-mcp: Graph API {s} {d}: {s}\n", .{
            @tagName(method),
            @intFromEnum(result.status),
            response_buf.written(),
        });
        return error.HttpError;
    }

    // Transfer ownership of the buffer to the caller.
    return response_buf.toOwnedSlice();
}
