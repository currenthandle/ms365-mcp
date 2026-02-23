// http.zig — Thin wrapper around std.http.Client for making HTTPS requests.
//
// Both the OAuth auth flow and the Graph API need HTTP requests.
// This module provides simple helpers so the callers don't have to
// deal with the low-level Client setup each time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Make an HTTPS POST request with a form-encoded body.
/// Used by the OAuth device code flow which expects
/// Content-Type: application/x-www-form-urlencoded.
///
/// The `io` parameter provides the network I/O context — it must support
/// networking (not debug_io, which has networking disabled).
///
/// Returns the response body as an allocated slice — caller must free it.
pub fn post(allocator: Allocator, io: Io, url: []const u8, body: []const u8) ![]u8 {
    // The HTTP client needs an Io context for network operations
    // and an allocator for internal buffers (connection pool, TLS, etc).
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    // Writer.Allocating is a dynamically growing buffer backed by an allocator.
    // The HTTP client writes the response body into it.
    var response_buf: std.Io.Writer.Allocating = .init(allocator);
    defer response_buf.deinit();

    // fetch() is a one-shot convenience method — it opens a connection,
    // sends the request, and reads the response in one call.
    // .payload sets the request body (and implies POST method).
    // .extra_headers adds headers that persist across redirects.
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        },
        .response_writer = &response_buf.writer,
    });

    // Check for HTTP errors (anything outside 200-299).
    if (@intFromEnum(result.status) >= 400) {
        std.debug.print("ms-mcp: HTTP {d}: {s}\n", .{
            @intFromEnum(result.status),
            response_buf.written(),
        });
        return error.HttpError;
    }

    // Transfer ownership of the buffer to the caller.
    return response_buf.toOwnedSlice();
}
