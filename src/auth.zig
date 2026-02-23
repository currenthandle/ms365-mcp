// auth.zig — OAuth 2.0 Device Code Flow for Microsoft 365.
//
// Microsoft's device code flow works in two phases:
// 1. Request a device code — we get back a short code + URL for the user
// 2. Poll for a token — we keep asking "did they log in yet?" until they do
//
// This module handles phase 1 for now. Phase 2 (polling) comes next.

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

    // Extract each field from the parsed JSON object.
    // We use allocator.dupe() to copy the strings out of the parsed JSON,
    // because parsed.deinit() will free the original memory.
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };

    return .{
        .user_code = try allocator.dupe(u8, switch (obj.get("user_code") orelse return error.InvalidResponse) {
            .string => |s| s,
            else => return error.InvalidResponse,
        }),
        .device_code = try allocator.dupe(u8, switch (obj.get("device_code") orelse return error.InvalidResponse) {
            .string => |s| s,
            else => return error.InvalidResponse,
        }),
        .verification_uri = try allocator.dupe(u8, switch (obj.get("verification_uri") orelse return error.InvalidResponse) {
            .string => |s| s,
            else => return error.InvalidResponse,
        }),
        .expires_in = switch (obj.get("expires_in") orelse return error.InvalidResponse) {
            .integer => |n| n,
            else => return error.InvalidResponse,
        },
        .interval = switch (obj.get("interval") orelse return error.InvalidResponse) {
            .integer => |n| n,
            else => return error.InvalidResponse,
        },
    };
}
