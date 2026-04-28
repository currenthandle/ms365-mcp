// graph_errors.zig — Typed errors from Microsoft Graph + user-facing hints.
//
// Context: graph.zig historically returned the raw response body no matter
// what the HTTP status was. Handlers couldn't tell a 401 (token stale) from
// a 403 (scope missing) from a 500 (server down) — they just saw "something
// failed" and sent a generic "Failed to fetch foo" string to the client.
//
// This module defines a real error set the graph.zig request layer maps
// status codes into, and a human-readable `explain` function that turns
// one of those errors into a message the LLM can show the user along
// with a next-step hint (e.g. "run login to refresh your session").
//
// Reading guide for TS/Python readers:
//   - `error{ A, B, C }` defines a Zig error set. Errors are values, not
//     exceptions. Functions declare them in their return type as `!T`.
//   - `allocPrint` is like Python's f-strings or JS template literals, but
//     it allocates a new string the caller must free.

const std = @import("std");

/// Errors the graph.zig request layer may return based on HTTP status.
/// Every Graph-calling handler should catch these and route through
/// ctx.sendGraphError, which turns them into user-facing messages.
pub const GraphError = error{
    /// 401 — access token is stale or invalid. User must log in again.
    Unauthorized,
    /// 403 with generic wording — the user is forbidden from this action.
    /// Often means the tenant blocks the operation for this account.
    Forbidden,
    /// 403 with an `insufficient_scope` or `InvalidAuthenticationToken`
    /// marker — the app is missing an OAuth scope. User must log in again
    /// to consent to the new scope, or an admin must grant it.
    InsufficientScope,
    /// 429 — Graph is throttling this account. Back off and retry later.
    Throttled,
    /// 404 — resource with the given ID/path does not exist.
    NotFound,
    /// 409 — conflict (e.g. upload would overwrite a locked file).
    Conflict,
    /// 400 — the request was malformed in a way the server rejected.
    BadRequest,
    /// 5xx — Graph itself had a problem.
    ServerError,
    /// Any non-HTTP failure (TLS handshake, DNS, socket closed, etc.).
    NetworkError,
};

/// Turn a GraphError (and an optional Graph response body) into a message
/// the MCP client can show the user. Always includes a next-step hint
/// when the error is actionable (re-login, wait, check the ID, etc).
///
/// Returns an allocated string the caller owns and must free.
pub fn explain(
    allocator: std.mem.Allocator,
    err: GraphError,
    body: ?[]const u8,
) ![]u8 {
    // The `body orelse "(no body)"` pattern is Zig's version of `body ?? "(no body)"`.
    const b = body orelse "(no body)";
    return switch (err) {
        error.Unauthorized => try std.fmt.allocPrint(
            allocator,
            "Authentication failed (401). Your Microsoft 365 session has expired. Run the 'login' tool and then 'verify-login' to refresh it.",
            .{},
        ),
        error.Forbidden => try std.fmt.allocPrint(
            allocator,
            "Access denied (403). The tenant or your account is blocked from this operation. Server said: {s}",
            .{b},
        ),
        error.InsufficientScope => try std.fmt.allocPrint(
            allocator,
            "Access denied (403) — the app is missing a required OAuth scope. Run the 'login' tool to re-consent, or ask an admin to grant the scope. Server said: {s}",
            .{b},
        ),
        error.Throttled => try std.fmt.allocPrint(
            allocator,
            "Microsoft Graph is rate-limiting this account (429). Wait 30-60 seconds and try again.",
            .{},
        ),
        error.NotFound => try std.fmt.allocPrint(
            allocator,
            "Resource not found (404). The ID or path may be stale or deleted. Server said: {s}",
            .{b},
        ),
        error.Conflict => try std.fmt.allocPrint(
            allocator,
            "Conflict (409). Another change may have happened first. Server said: {s}",
            .{b},
        ),
        error.BadRequest => try std.fmt.allocPrint(
            allocator,
            "Bad request (400). The server rejected the shape of the request. Server said: {s}",
            .{b},
        ),
        error.ServerError => try std.fmt.allocPrint(
            allocator,
            "Microsoft Graph server error (5xx). Try again in a moment.",
            .{},
        ),
        error.NetworkError => try std.fmt.allocPrint(
            allocator,
            "Network error reaching Microsoft Graph.",
            .{},
        ),
    };
}

// --- Tests ---

const testing = std.testing;

test "explain: Unauthorized mentions login" {
    const msg = try explain(testing.allocator, error.Unauthorized, null);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "401") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "login") != null);
}

test "explain: InsufficientScope mentions consent" {
    const msg = try explain(testing.allocator, error.InsufficientScope, "{\"error\":\"insufficient_scope\"}");
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "scope") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "login") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "insufficient_scope") != null);
}

test "explain: Throttled mentions retry" {
    const msg = try explain(testing.allocator, error.Throttled, null);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "429") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "try again") != null or
        std.mem.indexOf(u8, msg, "Wait") != null);
}

test "explain: NotFound mentions stale" {
    const msg = try explain(testing.allocator, error.NotFound, "gone");
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "404") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "stale") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "gone") != null);
}

test "explain: ServerError generic retry hint" {
    const msg = try explain(testing.allocator, error.ServerError, null);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "server error") != null or
        std.mem.indexOf(u8, msg, "Graph") != null);
}

test "explain: NetworkError" {
    const msg = try explain(testing.allocator, error.NetworkError, null);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "Network") != null);
}

test "explain: null body rendered as (no body)" {
    const msg = try explain(testing.allocator, error.BadRequest, null);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "(no body)") != null);
}
