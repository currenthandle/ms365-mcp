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

    // fetch() sends the request and reads the response in one call.
    // .method defaults to GET when no .payload is set.
    // .extra_headers attaches the Bearer token to every request.
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_header },
        },
        .response_writer = &response_buf.writer,
    });

    // Check for HTTP errors.
    if (@intFromEnum(result.status) >= 400) {
        std.debug.print("ms-mcp: Graph API {d}: {s}\n", .{
            @intFromEnum(result.status),
            response_buf.written(),
        });
        return error.HttpError;
    }

    // Transfer ownership of the buffer to the caller.
    return response_buf.toOwnedSlice();
}

/// Make an authenticated POST request to the Graph API with a JSON body.
///
/// `path` is the API path after /v1.0, e.g. "/me/sendMail".
/// `json_body` is the JSON string to send as the request body.
///
/// Returns the response body as an allocated slice — caller must free it.
/// Note: some Graph endpoints (like sendMail) return 202 with an empty body on success.
pub fn post(allocator: Allocator, io: Io, access_token: []const u8, path: []const u8, json_body: []const u8) ![]u8 {
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

    // fetch() sends the request and reads the response in one call.
    // .method = .POST and .payload sets the request body.
    // Two headers: Bearer token for auth, Content-Type for JSON body.
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = json_body,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .response_writer = &response_buf.writer,
    });

    // Check for HTTP errors.
    if (@intFromEnum(result.status) >= 400) {
        std.debug.print("ms-mcp: Graph API POST {d}: {s}\n", .{
            @intFromEnum(result.status),
            response_buf.written(),
        });
        return error.HttpError;
    }

    // Transfer ownership of the buffer to the caller.
    return response_buf.toOwnedSlice();
}
