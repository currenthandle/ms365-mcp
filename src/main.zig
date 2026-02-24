const std = @import("std");
const types = @import("types.zig");
const http = @import("http.zig");
const auth = @import("auth.zig");
const graph = @import("graph.zig");

// Type aliases — keeps function signatures cleaner.
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("ms-mcp: server starting\n", .{});

    // Read Microsoft OAuth config from environment variables.
    // These are set in the MCP server config (.mcp.json).
    // std.c.getenv calls the C library's getenv() — returns a pointer to the
    // value string, or null if the variable isn't set.
    // mem.span() converts the null-terminated C string to a Zig slice.
    const client_id: []const u8 = if (std.c.getenv("MS365_CLIENT_ID")) |ptr|
        std.mem.span(ptr)
    else {
        std.debug.print("ms-mcp: MS365_CLIENT_ID not set\n", .{});
        return;
    };

    const tenant_id: []const u8 = if (std.c.getenv("MS365_TENANT_ID")) |ptr|
        std.mem.span(ptr)
    else {
        std.debug.print("ms-mcp: MS365_TENANT_ID not set\n", .{});
        return;
    };

    // Create a full I/O context with networking support.
    // Threaded.init() sets up an Io that can do real network operations (TCP, TLS).
    // debug_io (what we used before) only supports file I/O, not networking.
    // We use this for both stdin/stdout and HTTP requests.
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    const io = threaded_io.io();

    var read_buf: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &read_buf);

    // Stdout writer — where we send JSON-RPC responses back to the client.
    var write_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &write_buf);

    // Try to load a saved token from a previous session.
    // If found, we can skip the login flow entirely.
    const saved_token = auth.loadToken(allocator, io);
    // Free the saved token strings when we're done.
    defer if (saved_token) |t| {
        allocator.free(t.access_token);
        allocator.free(t.refresh_token);
    };

    runMessageLoop(allocator, io, &stdin.interface, &stdout.interface, client_id, tenant_id, saved_token);
}

/// Extract the integer "id" field from a JSON-RPC message object.
/// JSON-RPC clients assign an id to each request so they can match our response.
/// Returns 0 if missing or not an integer.
fn getRequestId(value: std.json.Value) i64 {
    // We can only look up "id" if the value is a JSON object.
    const obj = switch (value) {
        .object => |o| o,
        else => return 0,
    };

    const id = obj.get("id") orelse return 0;

    return switch (id) {
        .integer => |n| n,
        else => 0,
    };
}

/// Extract the tool name from a "tools/call" request.
/// In JSON-RPC, tool calls look like: {"params": {"name": "login", ...}}
/// Returns null if missing or malformed.
fn getToolName(value: std.json.Value) ?[]const u8 {
    // Same pattern as getRequestId — unwrap one layer at a time.
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    // "params" contains the tool call details.
    const params = switch (obj.get("params") orelse return null) {
        .object => |o| o,
        else => return null,
    };

    // "name" is which tool the client wants to invoke.
    return switch (params.get("name") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Extract the "arguments" object from a "tools/call" request.
/// Tool calls with parameters look like:
///   {"params": {"name": "send-email", "arguments": {"to": "...", "subject": "..."}}}
/// Returns the arguments as a JSON ObjectMap, or null if missing.
fn getToolArgs(value: std.json.Value) ?std.json.ObjectMap {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    const params = switch (obj.get("params") orelse return null) {
        .object => |o| o,
        else => return null,
    };

    // "arguments" contains the tool-specific parameters.
    return switch (params.get("arguments") orelse return null) {
        .object => |o| o,
        else => null,
    };
}

/// Helper to extract a string value from a JSON ObjectMap.
/// Returns null if the key is missing or the value isn't a string.
fn getStringArg(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = args.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Convert a JSON array of email strings into a slice of Recipient structs.
/// e.g. ["alice@foo.com", "bob@bar.com"] → two Recipient structs.
/// Returns null if the key is missing or isn't an array.
fn parseRecipients(
    allocator: Allocator,
    args: std.json.ObjectMap,
    key: []const u8,
) !?[]const types.SendMailRequest.Message.Recipient {
    // Look up the key — if missing, return null (field is optional).
    const val = args.get(key) orelse return null;

    // It should be a JSON array.
    const arr = switch (val) {
        .array => |a| a,
        else => return null,
    };

    // Allocate a slice big enough for all the recipients.
    const recipients = try allocator.alloc(types.SendMailRequest.Message.Recipient, arr.items.len);

    // Fill in each recipient from the array elements.
    for (arr.items, 0..) |item, i| {
        // Each element should be a string (an email address).
        const email = switch (item) {
            .string => |s| s,
            else => {
                // Clean up what we allocated if we hit a non-string.
                allocator.free(recipients);
                return null;
            },
        };
        recipients[i] = .{ .emailAddress = .{ .address = email } };
    }

    return recipients;
}

/// Convert a JSON array of email strings into a slice of Attendee structs.
/// `attendee_type` is "required" or "optional" — sets the type field on each attendee.
/// Returns null if the key is missing or isn't an array.
fn parseAttendees(
    allocator: Allocator,
    args: std.json.ObjectMap,
    key: []const u8,
    attendee_type: []const u8,
) !?[]const types.CreateEventRequest.Attendee {
    // Look up the key — if missing, return null (field is optional).
    const val = args.get(key) orelse return null;

    // It should be a JSON array.
    const arr = switch (val) {
        .array => |a| a,
        else => return null,
    };

    // Allocate a slice big enough for all attendees.
    const attendees = try allocator.alloc(types.CreateEventRequest.Attendee, arr.items.len);

    // Fill in each attendee from the array elements.
    for (arr.items, 0..) |item, i| {
        const email = switch (item) {
            .string => |s| s,
            else => {
                allocator.free(attendees);
                return null;
            },
        };
        attendees[i] = .{
            .emailAddress = .{ .address = email },
            .type = attendee_type,
        };
    }

    return attendees;
}

/// Serialize any Zig struct as JSON, write it to the writer, then flush.
/// Uses std.json.Stringify to automatically convert structs to JSON —
/// no manual format strings needed.
fn sendJsonResponse(writer: *Writer, response: anytype) void {
    std.json.Stringify.value(response, .{}, writer) catch return;
    writer.writeAll("\n") catch return;
    writer.flush() catch return;
}

/// Build a JSON Schema "property" object: {"type": "...", "description": "..."}
/// Used to describe a single parameter in a tool's inputSchema.
/// Returns a std.json.Value that can be inserted into a properties object.
fn schemaProperty(prop_type: []const u8, description: []const u8) std.json.Value {
    // Build a JSON object with "type" and "description" keys.
    // We use raw pointers to static strings, so no allocation needed.
    var obj = std.json.ObjectMap.init(std.heap.page_allocator);
    obj.put("type", .{ .string = prop_type }) catch {};
    obj.put("description", .{ .string = description }) catch {};
    return .{ .object = obj };
}

/// Build a JSON Schema object for a tool with no parameters.
/// Returns: {"type": "object"}
fn emptySchema() std.json.Value {
    var obj = std.json.ObjectMap.init(std.heap.page_allocator);
    obj.put("type", .{ .string = "object" }) catch {};
    return .{ .object = obj };
}

/// Build a complete JSON Schema object for a tool with parameters.
/// `properties` is an already-built ObjectMap of property names → schema objects.
/// `required` is a list of required property names.
/// Returns: {"type": "object", "properties": {...}, "required": [...]}
fn buildSchema(properties: std.json.ObjectMap, required: []const []const u8) std.json.Value {
    var obj = std.json.ObjectMap.init(std.heap.page_allocator);
    obj.put("type", .{ .string = "object" }) catch {};
    obj.put("properties", .{ .object = properties }) catch {};

    // Build the "required" array from the string slice.
    var req_array = std.json.Array.init(std.heap.page_allocator);
    for (required) |name| {
        req_array.append(.{ .string = name }) catch {};
    }
    obj.put("required", .{ .array = req_array }) catch {};

    return .{ .object = obj };
}

/// URL-encode a string for use in query parameters.
/// Replaces spaces with %20 and other unsafe characters with %XX.
/// Returns an allocated string — caller must free it.
fn urlEncode(allocator: Allocator, input: []const u8) ![]u8 {
    // Count how many bytes we need — each unsafe char becomes 3 bytes (%XX).
    var len: usize = 0;
    for (input) |c| {
        len += if (needsEncoding(c)) @as(usize, 3) else @as(usize, 1);
    }

    const buf = try allocator.alloc(u8, len);
    var i: usize = 0;
    for (input) |c| {
        if (needsEncoding(c)) {
            // Write %XX where XX is the hex representation of the byte.
            buf[i] = '%';
            buf[i + 1] = hexDigit(c >> 4);
            buf[i + 2] = hexDigit(c & 0x0f);
            i += 3;
        } else {
            buf[i] = c;
            i += 1;
        }
    }
    return buf;
}

/// Check if a character needs URL-encoding.
/// Letters, digits, and a few safe punctuation marks can appear as-is.
fn needsEncoding(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => false,
        else => true,
    };
}

/// Convert a 4-bit value (0-15) to its hex character ('0'-'9', 'A'-'F').
fn hexDigit(val: u8) u8 {
    return if (val < 10) '0' + val else 'A' + (val - 10);
}

/// Convert a local time string to UTC by subtracting the UTC offset.
/// `utc_offset` is negative for west of UTC (e.g. -5 for EST, -8 for PST).
///
/// Input:  "2026-02-24T09:00:00", offset=-5 → "2026-02-24T14:00:00Z"
/// Input:  "2026-02-24T21:00:00", offset=-5 → "2026-02-25T02:00:00Z"
///
/// Handles day/month/year rollover in both directions.
/// NOTE: Uses standard time offsets only — does not account for DST.
fn localToUtc(allocator: Allocator, local: []const u8, utc_offset: i8) ![]u8 {
    // If already has a Z suffix, it's already UTC — just dupe it.
    if (local.len > 0 and local[local.len - 1] == 'Z') {
        return allocator.dupe(u8, local);
    }

    // Expected format: "YYYY-MM-DDTHH:MM:SS" (at least 19 chars).
    if (local.len < 19) return error.InvalidFormat;

    // Parse the date/time components from fixed positions.
    // "2026-02-24T09:00:00"
    //  0123456789012345678
    var year = std.fmt.parseInt(i32, local[0..4], 10) catch return error.InvalidFormat;
    var month = std.fmt.parseInt(u8, local[5..7], 10) catch return error.InvalidFormat;
    var day = std.fmt.parseInt(u8, local[8..10], 10) catch return error.InvalidFormat;
    var hour_i: i16 = std.fmt.parseInt(i16, local[11..13], 10) catch return error.InvalidFormat;
    const min = local[14..16];
    const sec = local[17..19];

    // Subtract the UTC offset to convert local → UTC.
    // e.g. EST is -5, so local 9:00 - (-5) = 14:00 UTC.
    // e.g. Tokyo is +9, so local 9:00 - 9 = 00:00 UTC.
    hour_i -= utc_offset;

    // Handle forward day rollover (hour >= 24).
    if (hour_i >= 24) {
        hour_i -= 24;
        day += 1;

        const days_in_month: u8 = switch (month) {
            1, 3, 5, 7, 8, 10, 12 => 31,
            4, 6, 9, 11 => 30,
            2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
            else => 31,
        };

        if (day > days_in_month) {
            day = 1;
            month += 1;
            if (month > 12) {
                month = 1;
                year += 1;
            }
        }
    }

    // Handle backward day rollover (hour < 0).
    // e.g. Tokyo 02:00 - 9 = -7 → previous day 17:00 UTC.
    if (hour_i < 0) {
        hour_i += 24;
        if (day > 1) {
            day -= 1;
        } else {
            // Roll back to the previous month.
            if (month > 1) {
                month -= 1;
            } else {
                month = 12;
                year -= 1;
            }
            // Day becomes the last day of the previous month.
            day = switch (month) {
                1, 3, 5, 7, 8, 10, 12 => 31,
                4, 6, 9, 11 => 30,
                2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
                else => 31,
            };
        }
    }

    const hour: u8 = @intCast(hour_i);

    // Format back to ISO 8601 with Z suffix.
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{s}:{s}Z", .{
        year, month, day, hour, min, sec,
    });
}

/// Map IANA timezone names to Microsoft timezone names + UTC offsets.
/// Microsoft Graph API uses its own names (e.g. "Eastern Standard Time").
/// macOS reports IANA format (e.g. "America/New_York").
/// `utc_offset` is the standard time offset in hours (negative = west of UTC).
/// NOTE: Does not account for daylight saving — worst case, one hour off.
const TimezoneEntry = struct {
    iana: []const u8,
    microsoft: []const u8,
    utc_offset: i8, // hours from UTC (standard time)
};

const timezone_table = [_]TimezoneEntry{
    .{ .iana = "America/New_York", .microsoft = "Eastern Standard Time", .utc_offset = -5 },
    .{ .iana = "America/Chicago", .microsoft = "Central Standard Time", .utc_offset = -6 },
    .{ .iana = "America/Denver", .microsoft = "Mountain Standard Time", .utc_offset = -7 },
    .{ .iana = "America/Los_Angeles", .microsoft = "Pacific Standard Time", .utc_offset = -8 },
    .{ .iana = "America/Anchorage", .microsoft = "Alaskan Standard Time", .utc_offset = -9 },
    .{ .iana = "Pacific/Honolulu", .microsoft = "Hawaiian Standard Time", .utc_offset = -10 },
    .{ .iana = "America/Phoenix", .microsoft = "US Mountain Standard Time", .utc_offset = -7 },
    .{ .iana = "America/Toronto", .microsoft = "Eastern Standard Time", .utc_offset = -5 },
    .{ .iana = "America/Vancouver", .microsoft = "Pacific Standard Time", .utc_offset = -8 },
    .{ .iana = "Europe/London", .microsoft = "GMT Standard Time", .utc_offset = 0 },
    .{ .iana = "Europe/Paris", .microsoft = "Romance Standard Time", .utc_offset = 1 },
    .{ .iana = "Europe/Berlin", .microsoft = "W. Europe Standard Time", .utc_offset = 1 },
    .{ .iana = "Asia/Tokyo", .microsoft = "Tokyo Standard Time", .utc_offset = 9 },
    .{ .iana = "Asia/Shanghai", .microsoft = "China Standard Time", .utc_offset = 8 },
    .{ .iana = "Asia/Kolkata", .microsoft = "India Standard Time", .utc_offset = 5 },
    .{ .iana = "Australia/Sydney", .microsoft = "AUS Eastern Standard Time", .utc_offset = 10 },
    .{ .iana = "UTC", .microsoft = "UTC", .utc_offset = 0 },
};

/// Look up a Microsoft timezone name from an IANA timezone name.
/// Returns null if the IANA name isn't in our table.
fn ianaToWindows(iana: []const u8) ?[]const u8 {
    for (&timezone_table) |entry| {
        if (std.mem.eql(u8, entry.iana, iana)) return entry.microsoft;
    }
    return null;
}

/// Look up the UTC offset (in hours) for a Microsoft timezone name.
/// Returns null if the timezone isn't in our table.
fn getUtcOffset(ms_tz: []const u8) ?i8 {
    for (&timezone_table) |entry| {
        if (std.mem.eql(u8, entry.microsoft, ms_tz)) return entry.utc_offset;
    }
    return null;
}

/// Read the system timezone from macOS /etc/localtime symlink.
/// Returns the IANA timezone name (e.g. "America/New_York").
/// The returned slice points into the `buf` parameter — no allocation needed.
fn getSystemTimezone(buf: []u8) ?[]const u8 {
    // On macOS, /etc/localtime is a symlink to /var/db/timezone/zoneinfo/America/New_York (or similar).
    // std.c.readlink reads the symlink target into buf and returns the length.
    // Returns -1 on error (file not found, not a symlink, etc.).
    const len = std.c.readlink("/etc/localtime", buf.ptr, buf.len);
    if (len < 0) return null;
    const link = buf[0..@intCast(len)];

    // Find "zoneinfo/" in the path and take everything after it.
    const marker = "zoneinfo/";
    if (std.mem.indexOf(u8, link, marker)) |idx| {
        return link[idx + marker.len ..];
    }
    return null;
}

/// Build a single member JSON object for the create-chat API.
/// Template string because the field names have @ characters
/// that can't be Zig struct field names.
/// `identifier` can be a user ID (GUID) or email address —
/// the Graph API accepts both in the users('...') binding.
fn buildMemberJson(allocator: Allocator, identifier: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"@odata.type":"#microsoft.graph.aadUserConversationMember","roles":["owner"],"user@odata.bind":"https://graph.microsoft.com/v1.0/users('{s}')"}}
    , .{identifier});
}

/// Check if the user is logged in. If yes, returns the access token.
/// If the token is expired, silently refreshes it using the refresh token.
/// If not logged in at all, sends an error response to the client and returns null.
/// Every tool that needs Graph API access calls this first.
fn requireAuth(state: *State, allocator: Allocator, io: std.Io, client_id: []const u8, tenant_id: []const u8, writer: *Writer, request_id: i64) ?[]const u8 {
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
    sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
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
fn checkTimezone(state: *State, allocator: Allocator, io: std.Io, token: []const u8, writer: *Writer, request_id: i64) bool {
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
    sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = request_id,
        .result = .{ .content = content },
    });
    return false;
}

/// Server state that persists across tool calls within a session.
/// We need this because the login flow is split across two tool calls:
///   1. "login" gets the device code and stashes it here
///   2. "verify-login" reads it from here and polls for the token
const State = struct {
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

/// Reads JSON-RPC messages from the reader one line at a time,
/// parses them, and dispatches by method name.
fn runMessageLoop(allocator: Allocator, io: std.Io, reader: *Reader, writer: *Writer, client_id: []const u8, tenant_id: []const u8, saved_token: ?auth.SavedToken) void {
    // Mutable state that lives for the entire session.
    // If we loaded a token from disk, use it. Otherwise start empty.
    var state = State{};
    if (saved_token) |t| {
        state.access_token = t.access_token;
        state.refresh_token = t.refresh_token;
        state.expires_at = t.expires_at;
        std.debug.print("ms-mcp: using saved token (expires_at={d})\n", .{t.expires_at});
    }

    // Detect timezone from the system clock (/etc/localtime on macOS).
    // This runs once at startup so all calendar operations use the right timezone.
    var tz_buf: [256]u8 = undefined;
    if (getSystemTimezone(&tz_buf)) |iana_tz| {
        if (ianaToWindows(iana_tz)) |ms_tz| {
            state.timezone = ms_tz;
            std.debug.print("ms-mcp: detected timezone: {s} → {s}\n", .{ iana_tz, ms_tz });
        } else {
            std.debug.print("ms-mcp: unknown timezone: {s}, defaulting to UTC\n", .{iana_tz});
        }
    } else {
        std.debug.print("ms-mcp: could not detect system timezone, defaulting to UTC\n", .{});
    }

    while (true) {
        const line = reader.takeDelimiter('\n') catch |err| {
            std.debug.print("ms-mcp: read error: {}\n", .{err});
            return;
        } orelse {
            std.debug.print("ms-mcp: stdin closed, shutting down\n", .{});
            return;
        };

        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{},
        ) catch {
            std.debug.print("ms-mcp: invalid JSON\n", .{});
            continue;
        };
        defer parsed.deinit();

        // Extract the method string from the JSON-RPC message.
        const method = switch (parsed.value) {
            .object => |obj| if (obj.get("method")) |v| switch (v) {
                .string => |s| s,
                else => null,
            } else null,
            else => null,
        };

        if (method) |m| {
            std.debug.print("ms-mcp: method={s}\n", .{m});

            if (std.mem.eql(u8, m, "initialize")) {
                // Respond with server info and capabilities.
                // All fields use defaults from the struct definitions in types.zig.
                sendJsonResponse(writer, types.JsonRpcResponse(types.InitializeResult){
                    .id = getRequestId(parsed.value),
                    .result = .{},
                });
            } else if (std.mem.eql(u8, m, "ping")) {
                // MCP health check — client pings to verify the server is alive.
                // Must respond promptly with an empty result or the client will
                // consider the connection stale and drop our tools.
                const EmptyResult = struct {};
                sendJsonResponse(writer, types.JsonRpcResponse(EmptyResult){
                    .id = getRequestId(parsed.value),
                    .result = .{},
                });
            } else if (std.mem.eql(u8, m, "tools/call")) {
                if (getToolName(parsed.value)) |name| {
                    std.debug.print("ms-mcp: tool call: {s}\n", .{name});

                    if (std.mem.eql(u8, name, "login")) {
                        // Start the OAuth device code flow — ask Microsoft for a code.
                        const dc = auth.requestDeviceCode(allocator, io, client_id, tenant_id) catch |err| {
                            // Print the actual error so we can debug.
                            std.debug.print("ms-mcp: device code request failed: {}\n", .{err});

                            // Tell the client the login failed.
                            // Explicit type annotation so Zig knows this is []const TextContent.
                            const error_content: []const types.TextContent = &.{
                                .{ .text = "Failed to start login flow" },
                            };
                            const error_result = types.ToolCallResult{ .content = error_content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = error_result,
                            });
                            continue;
                        };

                        // Stash the device code in state so verify-login can use it.
                        // Don't free dc strings here — state now owns them.
                        state.pending_device_code = dc;

                        // Build a message telling the user where to go and what code to enter.
                        const msg = std.fmt.allocPrint(
                            allocator,
                            "Go to {s} and enter code: {s}\nImmediately call the verify-login tool now. It will poll and wait for the user to complete sign-in.",
                            .{ dc.verification_uri, dc.user_code },
                        ) catch continue;
                        defer allocator.free(msg);

                        // Send the message back to the client.
                        const content: []const types.TextContent = &.{
                            .{ .text = msg },
                        };
                        const result = types.ToolCallResult{ .content = content };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = result,
                        });
                    } else if (std.mem.eql(u8, name, "verify-login")) {
                        // Check that login was called first —
                        // we need the device code from the login step.
                        const dc = state.pending_device_code orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "No pending login. Call login first." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // Poll Microsoft's token endpoint until the user completes login.
                        // This blocks until success or the device code expires.
                        const token = auth.pollForToken(
                            allocator, io, client_id, tenant_id,
                            dc.device_code, dc.expires_in, dc.interval,
                        ) catch |err| {
                            std.debug.print("ms-mcp: token poll failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Login failed or timed out. Try login again." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };
                        // Save tokens to disk so we can re-use them next session.
                        auth.saveToken(allocator, io, token.access_token, token.refresh_token, token.expires_in) catch |err| {
                            std.debug.print("ms-mcp: failed to save token: {}\n", .{err});
                        };

                        // Store all token info in state for future Graph API calls
                        // and silent refresh when the access token expires.
                        state.access_token = token.access_token;
                        state.refresh_token = token.refresh_token;
                        const now_secs = std.Io.Timestamp.now(io, .real).toSeconds();
                        state.expires_at = now_secs + token.expires_in;

                        // Clean up the pending device code — login is complete.
                        // These strings were allocated in requestDeviceCode.
                        allocator.free(dc.user_code);
                        allocator.free(dc.device_code);
                        allocator.free(dc.verification_uri);
                        state.pending_device_code = null;

                        const content: []const types.TextContent = &.{
                            .{ .text = "Login successful!" },
                        };
                        const result = types.ToolCallResult{ .content = content };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = result,
                        });
                    } else if (std.mem.eql(u8, name, "get-mailbox-settings")) {
                        // Check that the user is logged in.
                        const token = requireAuth(&state, allocator, io, client_id, tenant_id, writer, getRequestId(parsed.value)) orelse continue;

                        // GET /me/mailboxSettings — returns timezone, locale, date/time formats.
                        const response_body = graph.get(allocator, io, token, "/me/mailboxSettings") catch |err| {
                            std.debug.print("ms-mcp: get-mailbox-settings failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to fetch mailbox settings." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };
                        defer allocator.free(response_body);

                        // Return the raw JSON — includes timeZone, language, dateFormat, etc.
                        const content: []const types.TextContent = &.{
                            .{ .text = response_body },
                        };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = .{ .content = content },
                        });
                    } else if (std.mem.eql(u8, name, "sync-timezone")) {
                        // Check that the user is logged in.
                        const token = requireAuth(&state, allocator, io, client_id, tenant_id, writer, getRequestId(parsed.value)) orelse continue;

                        // Step 1: Read the system timezone (IANA format from macOS).
                        var sync_tz_buf: [256]u8 = undefined;
                        const iana_tz = getSystemTimezone(&sync_tz_buf) orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Could not detect system timezone from /etc/localtime." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // Step 2: Map IANA → Windows timezone name.
                        const windows_tz = ianaToWindows(iana_tz) orelse {
                            // Unknown IANA timezone — tell the user what we found.
                            const msg = std.fmt.allocPrint(
                                allocator,
                                "Unknown timezone: {s}. Add it to the IANA-to-Windows mapping table.",
                                .{iana_tz},
                            ) catch continue;
                            defer allocator.free(msg);
                            const content: []const types.TextContent = &.{
                                .{ .text = msg },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // Step 3: PATCH /me/mailboxSettings to update the timezone.
                        const patch_body = std.fmt.allocPrint(
                            allocator,
                            "{{\"timeZone\":\"{s}\"}}",
                            .{windows_tz},
                        ) catch continue;
                        defer allocator.free(patch_body);

                        const response_body = graph.patch(allocator, io, token, "/me/mailboxSettings", patch_body) catch |err| {
                            std.debug.print("ms-mcp: sync-timezone PATCH failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to update mailbox timezone." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };
                        defer allocator.free(response_body);

                        // Step 4: Update our in-memory state so all subsequent
                        // calendar operations use the new timezone.
                        state.timezone = windows_tz;
                        state.timezone_checked = true;
                        std.debug.print("ms-mcp: timezone synced to {s} ({s})\n", .{ windows_tz, iana_tz });

                        // Return a confirmation message.
                        const msg = std.fmt.allocPrint(
                            allocator,
                            "Timezone synced: {s} → {s}",
                            .{ iana_tz, windows_tz },
                        ) catch continue;
                        defer allocator.free(msg);
                        const content: []const types.TextContent = &.{
                            .{ .text = msg },
                        };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = .{ .content = content },
                        });
                    } else if (std.mem.eql(u8, name, "list-emails")) {
                        // Check that the user is logged in.
                        const token = requireAuth(&state, allocator, io, client_id, tenant_id, writer, getRequestId(parsed.value)) orelse continue;

                        // Call Graph API to list recent emails.
                        // $top=10 — only get the 10 most recent
                        // $select — only fetch the fields we need (saves bandwidth)
                        // $orderby — newest first
                        // %20 is a URL-encoded space for "receivedDateTime desc"
                        const response_body = graph.get(
                            allocator, io, token,
                            "/me/messages?$top=10&$select=id,subject,from,receivedDateTime,bodyPreview&$orderby=receivedDateTime%20desc",
                        ) catch |err| {
                            std.debug.print("ms-mcp: list-emails failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to fetch emails." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };
                        defer allocator.free(response_body);

                        // Return the raw JSON to the LLM.
                        // The LLM can parse and summarize it for the user.
                        const content: []const types.TextContent = &.{
                            .{ .text = response_body },
                        };
                        const result = types.ToolCallResult{ .content = content };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = result,
                        });
                    } else if (std.mem.eql(u8, name, "read-email")) {
                        // Check that the user is logged in.
                        const token = requireAuth(&state, allocator, io, client_id, tenant_id, writer, getRequestId(parsed.value)) orelse continue;

                        // Get tool arguments — emailId is required.
                        const args = getToolArgs(parsed.value) orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing arguments. Provide emailId." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // "emailId" — the ID of the email to read (from list-emails results).
                        const email_id = getStringArg(args, "emailId") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'emailId' argument." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // Build the path: /me/messages/{emailId}
                        // $select limits to the fields we need — includes full body,
                        // all recipients (to, cc), and read status.
                        const path = std.fmt.allocPrint(
                            allocator,
                            "/me/messages/{s}?$select=id,subject,from,toRecipients,ccRecipients,receivedDateTime,body,isRead",
                            .{email_id},
                        ) catch continue;
                        defer allocator.free(path);

                        // GET the email.
                        const response_body = graph.get(allocator, io, token, path) catch |err| {
                            std.debug.print("ms-mcp: read-email failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to fetch email." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };
                        defer allocator.free(response_body);

                        // Return the raw JSON — includes full body content, recipients, etc.
                        const content: []const types.TextContent = &.{
                            .{ .text = response_body },
                        };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = .{ .content = content },
                        });
                    } else if (std.mem.eql(u8, name, "send-email")) {
                        // Check that the user is logged in.
                        const token = requireAuth(&state, allocator, io, client_id, tenant_id, writer, getRequestId(parsed.value)) orelse continue;

                        // Extract the arguments: to, subject, body.
                        const args = getToolArgs(parsed.value) orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing arguments. Provide to, subject, and body." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // Parse "to" — required, must be a JSON array of email strings.
                        const to_recipients = parseRecipients(allocator, args, "to") catch continue orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'to' argument (array of email addresses)." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };
                        defer allocator.free(to_recipients);

                        // Parse "cc" — optional array of email addresses.
                        const cc_recipients = parseRecipients(allocator, args, "cc") catch continue;
                        defer if (cc_recipients) |cc| allocator.free(cc);

                        // Parse "bcc" — optional array of email addresses.
                        const bcc_recipients = parseRecipients(allocator, args, "bcc") catch continue;
                        defer if (bcc_recipients) |bcc| allocator.free(bcc);

                        const subject = getStringArg(args, "subject") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'subject' argument." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };
                        const body_text = getStringArg(args, "body") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'body' argument." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // Build the Graph API request body for POST /me/sendMail.
                        // Using a typed struct instead of a raw format string —
                        // Stringify handles JSON formatting, escaping quotes, etc.
                        const mail_request = types.SendMailRequest{
                            .message = .{
                                .subject = subject,
                                .body = .{ .content = body_text },
                                .toRecipients = to_recipients,
                                .ccRecipients = cc_recipients,
                                .bccRecipients = bcc_recipients,
                            },
                        };

                        // Serialize the struct to a JSON string.
                        // Allocating writer grows a buffer as Stringify writes into it.
                        var json_buf: std.Io.Writer.Allocating = .init(allocator);
                        defer json_buf.deinit();
                        // emit_null_optional_fields=false omits null cc/bcc fields
                        // instead of sending "ccRecipients":null which Graph rejects.
                        std.json.Stringify.value(mail_request, .{ .emit_null_optional_fields = false }, &json_buf.writer) catch continue;

                        // .written() returns the JSON bytes written so far as a slice.
                        const json_body = json_buf.written();

                        // Send the email via Graph API.
                        _ = graph.post(allocator, io, token, "/me/sendMail", json_body) catch |err| {
                            std.debug.print("ms-mcp: send-email failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to send email." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // Success!
                        const content: []const types.TextContent = &.{
                            .{ .text = "Email sent successfully." },
                        };
                        const result = types.ToolCallResult{ .content = content };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = result,
                        });
                    } else if (std.mem.eql(u8, name, "list-chat-messages")) {
                        // Check that the user is logged in.
                        const token = requireAuth(&state, allocator, io, client_id, tenant_id, writer, getRequestId(parsed.value)) orelse continue;

                        // Get the tool arguments — we need "chatId".
                        const args = getToolArgs(parsed.value) orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing arguments. Provide chatId." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // "chatId" — the ID of the chat to read messages from.
                        // The LLM gets this from the list-chats results.
                        const chat_id = getStringArg(args, "chatId") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'chatId' argument." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // Build the path with the chatId baked in.
                        // $top=20 — get the 20 most recent messages
                        const path = std.fmt.allocPrint(
                            allocator,
                            "/me/chats/{s}/messages?$top=20",
                            .{chat_id},
                        ) catch continue;
                        defer allocator.free(path);

                        // GET the messages.
                        const response_body = graph.get(allocator, io, token, path) catch |err| {
                            std.debug.print("ms-mcp: list-chat-messages failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to fetch chat messages." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };
                        defer allocator.free(response_body);

                        // Return the raw JSON — the LLM will summarize it.
                        const content: []const types.TextContent = &.{
                            .{ .text = response_body },
                        };
                        const result = types.ToolCallResult{ .content = content };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = result,
                        });
                    } else if (std.mem.eql(u8, name, "search-users")) {
                        // Check that the user is logged in.
                        const token = requireAuth(&state, allocator, io, client_id, tenant_id, writer, getRequestId(parsed.value)) orelse continue;

                        // Get tool arguments — query is required.
                        const args = getToolArgs(parsed.value) orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing arguments. Provide query (name to search for)." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // "query" — the person's name to search for.
                        const query = getStringArg(args, "query") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'query' argument." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // URL-encode the query so spaces and special characters
                        // don't break the URL. e.g. "Berry Cheung" → "Berry%20Cheung".
                        const encoded_query = urlEncode(allocator, query) catch continue;
                        defer allocator.free(encoded_query);

                        // Build the path: /me/people?$search=%22query%22&$top=5&$select=...
                        // The People API searches contacts and colleagues by name.
                        // $search requires quotes around the query string.
                        // %22 is the URL-encoded double-quote — $search requires
                        // quoted strings per the Graph API spec.
                        // scoredEmailAddresses contains the person's email(s).
                        const path = std.fmt.allocPrint(
                            allocator,
                            "/me/people?$search=%22{s}%22&$top=5&$select=displayName,scoredEmailAddresses,userPrincipalName",
                            .{encoded_query},
                        ) catch continue;
                        defer allocator.free(path);

                        // GET the search results.
                        const response_body = graph.get(allocator, io, token, path) catch |err| {
                            std.debug.print("ms-mcp: search-users failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to search users." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };
                        defer allocator.free(response_body);

                        // Return raw JSON — small response, LLM can pick the right person.
                        const content: []const types.TextContent = &.{
                            .{ .text = response_body },
                        };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = .{ .content = content },
                        });
                    } else if (std.mem.eql(u8, name, "get-profile")) {
                        // Check that the user is logged in.
                        const token = requireAuth(&state, allocator, io, client_id, tenant_id, writer, getRequestId(parsed.value)) orelse continue;

                        // GET /me — returns the logged-in user's profile.
                        // $select limits to just the fields we care about.
                        const response_body = graph.get(
                            allocator, io, token,
                            "/me?$select=id,displayName,mail,userPrincipalName",
                        ) catch |err| {
                            std.debug.print("ms-mcp: get-profile failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to fetch profile." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };
                        defer allocator.free(response_body);

                        // Return raw JSON — it's small, just a few fields.
                        const content: []const types.TextContent = &.{
                            .{ .text = response_body },
                        };
                        const result = types.ToolCallResult{ .content = content };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = result,
                        });
                    } else if (std.mem.eql(u8, name, "list-chats")) {
                        // Check that the user is logged in.
                        const token = requireAuth(&state, allocator, io, client_id, tenant_id, writer, getRequestId(parsed.value)) orelse continue;

                        // Call Graph API to list the user's Teams chats.
                        // $expand=members includes participant names in the response.
                        const response_body = graph.get(
                            allocator, io, token,
                            "/me/chats?$top=20&$select=id,topic,chatType,lastUpdatedDateTime&$expand=members",
                        ) catch |err| {
                            std.debug.print("ms-mcp: list-chats failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to fetch chats." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };
                        defer allocator.free(response_body);

                        // Parse the raw JSON so we can build a condensed summary.
                        // The raw response with $expand=members is ~135k tokens —
                        // way too much for the LLM's context window.
                        const chats_parsed = std.json.parseFromSlice(
                            std.json.Value, allocator, response_body, .{},
                        ) catch {
                            const content: []const types.TextContent = &.{
                                .{ .text = response_body },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };
                        defer chats_parsed.deinit();

                        // Build a condensed plain-text summary.
                        // One line per chat: "[type] Topic — Members — id: ..."
                        var summary_buf: std.Io.Writer.Allocating = .init(allocator);
                        defer summary_buf.deinit();
                        const sw = &summary_buf.writer;

                        // Get the "value" array from the response — that's the list of chats.
                        const chats_root = switch (chats_parsed.value) {
                            .object => |o| o,
                            else => continue,
                        };
                        const chats_array = switch (chats_root.get("value") orelse continue) {
                            .array => |a| a,
                            else => continue,
                        };

                        // Loop through each chat and extract the key fields.
                        for (chats_array.items) |chat_val| {
                            const chat = switch (chat_val) {
                                .object => |o| o,
                                else => continue,
                            };

                            // Chat type: oneOnOne, group, or meeting.
                            const chat_type = switch (chat.get("chatType") orelse continue) {
                                .string => |s| s,
                                else => "unknown",
                            };

                            // Topic — may be null for 1:1 chats.
                            const topic = switch (chat.get("topic") orelse .null) {
                                .string => |s| s,
                                .null => "(no topic)",
                                else => "(no topic)",
                            };

                            // Chat ID — needed to send messages or read history.
                            const chat_id = switch (chat.get("id") orelse continue) {
                                .string => |s| s,
                                else => continue,
                            };

                            // Write the chat type and topic.
                            sw.print("[{s}] {s}", .{ chat_type, topic }) catch continue;

                            // Extract member display names from the expanded members array.
                            if (chat.get("members")) |members_val| {
                                const members = switch (members_val) {
                                    .array => |a| a,
                                    else => null,
                                };
                                if (members) |member_list| {
                                    sw.writeAll(" — ") catch continue;
                                    for (member_list.items, 0..) |member_val, i| {
                                        const member = switch (member_val) {
                                            .object => |o| o,
                                            else => continue,
                                        };
                                        // "displayName" is the human-readable name.
                                        const display_name = switch (member.get("displayName") orelse continue) {
                                            .string => |s| s,
                                            else => continue,
                                        };
                                        if (i > 0) sw.writeAll(", ") catch continue;
                                        sw.writeAll(display_name) catch continue;
                                    }
                                }
                            }

                            // Write the chat ID last — the LLM needs this to send messages.
                            sw.print(" — id: {s}\n", .{chat_id}) catch continue;
                        }

                        // Return the condensed summary.
                        const summary = summary_buf.written();
                        const content: []const types.TextContent = &.{
                            .{ .text = if (summary.len > 0) summary else "No chats found." },
                        };
                        const result = types.ToolCallResult{ .content = content };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = result,
                        });
                    } else if (std.mem.eql(u8, name, "send-chat-message")) {
                        // Check that the user is logged in.
                        const token = requireAuth(&state, allocator, io, client_id, tenant_id, writer, getRequestId(parsed.value)) orelse continue;

                        // Get the tool arguments — we need "chatId" and "message".
                        const args = getToolArgs(parsed.value) orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing arguments. Provide chatId and message." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // "chatId" — which chat to send the message to.
                        const chat_id = getStringArg(args, "chatId") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'chatId' argument." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // "message" — the text to send.
                        const message = getStringArg(args, "message") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'message' argument." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // Build the path: /me/chats/{chatId}/messages
                        const path = std.fmt.allocPrint(
                            allocator,
                            "/me/chats/{s}/messages",
                            .{chat_id},
                        ) catch continue;
                        defer allocator.free(path);

                        // Build the request body using a typed struct.
                        // Stringify handles escaping quotes in the message text.
                        const chat_msg = types.ChatMessageRequest{
                            .body = .{ .content = message },
                        };

                        // Serialize the struct to JSON.
                        var json_buf: std.Io.Writer.Allocating = .init(allocator);
                        defer json_buf.deinit();
                        std.json.Stringify.value(chat_msg, .{}, &json_buf.writer) catch continue;
                        const json_body = json_buf.written();

                        // POST the message.
                        _ = graph.post(allocator, io, token, path, json_body) catch |err| {
                            std.debug.print("ms-mcp: send-chat-message failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to send chat message." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // Success!
                        const content: []const types.TextContent = &.{
                            .{ .text = "Chat message sent." },
                        };
                        const result = types.ToolCallResult{ .content = content };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = result,
                        });
                    } else if (std.mem.eql(u8, name, "get-calendar-event")) {
                        // Check that the user is logged in.
                        const token = requireAuth(&state, allocator, io, client_id, tenant_id, writer, getRequestId(parsed.value)) orelse continue;
                        // One-time timezone check — warns user if mailbox tz ≠ system tz.
                        if (!checkTimezone(&state, allocator, io, token, writer, getRequestId(parsed.value))) continue;

                        // Get tool arguments — eventId is required.
                        const args = getToolArgs(parsed.value) orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing arguments. Provide eventId." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // "eventId" — the ID of the event to fetch (from list-calendar-events).
                        const event_id = getStringArg(args, "eventId") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'eventId' argument." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // Build the path: /me/events/{eventId}
                        // $select includes body and attendees — the full details you'd want
                        // when drilling into a specific event.
                        const path = std.fmt.allocPrint(
                            allocator,
                            "/me/events/{s}?$select=id,subject,start,end,location,body,attendees,organizer,isAllDay",
                            .{event_id},
                        ) catch continue;
                        defer allocator.free(path);

                        // GET the event details.
                        const response_body = graph.get(allocator, io, token, path) catch |err| {
                            std.debug.print("ms-mcp: get-calendar-event failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to fetch calendar event." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };
                        defer allocator.free(response_body);

                        // Return raw JSON — it's a single event, reasonably sized.
                        const content: []const types.TextContent = &.{
                            .{ .text = response_body },
                        };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = .{ .content = content },
                        });
                    } else if (std.mem.eql(u8, name, "update-calendar-event")) {
                        // Check that the user is logged in.
                        const token = requireAuth(&state, allocator, io, client_id, tenant_id, writer, getRequestId(parsed.value)) orelse continue;
                        if (!checkTimezone(&state, allocator, io, token, writer, getRequestId(parsed.value))) continue;

                        // Get tool arguments — eventId is required, everything else is optional.
                        const args = getToolArgs(parsed.value) orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing arguments. Provide eventId and fields to update." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // "eventId" — the ID of the event to update (required).
                        const event_id = getStringArg(args, "eventId") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'eventId' argument." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // All fields are optional for update — only provided ones get sent.
                        // We build JSON manually using ObjectMap because CreateEventRequest
                        // has required fields (subject, start, end) that would always be sent.
                        // For PATCH, we only want to include fields the user actually provided.
                        var update_obj = std.json.ObjectMap.init(allocator);
                        defer update_obj.deinit();

                        // Add each field only if the LLM provided it.
                        if (getStringArg(args, "subject")) |s| {
                            update_obj.put("subject", .{ .string = s }) catch continue;
                        }
                        if (getStringArg(args, "startDateTime")) |s| {
                            // Build the nested {"dateTime": "...", "timeZone": "..."} object.
                            var start_obj = std.json.ObjectMap.init(allocator);
                            start_obj.put("dateTime", .{ .string = s }) catch continue;
                            start_obj.put("timeZone", .{ .string = state.timezone }) catch continue;
                            update_obj.put("start", .{ .object = start_obj }) catch continue;
                        }
                        if (getStringArg(args, "endDateTime")) |e| {
                            var end_obj = std.json.ObjectMap.init(allocator);
                            end_obj.put("dateTime", .{ .string = e }) catch continue;
                            end_obj.put("timeZone", .{ .string = state.timezone }) catch continue;
                            update_obj.put("end", .{ .object = end_obj }) catch continue;
                        }
                        if (getStringArg(args, "body")) |b| {
                            var body_obj = std.json.ObjectMap.init(allocator);
                            body_obj.put("contentType", .{ .string = "Text" }) catch continue;
                            body_obj.put("content", .{ .string = b }) catch continue;
                            update_obj.put("body", .{ .object = body_obj }) catch continue;
                        }
                        if (getStringArg(args, "location")) |l| {
                            var loc_obj = std.json.ObjectMap.init(allocator);
                            loc_obj.put("displayName", .{ .string = l }) catch continue;
                            update_obj.put("location", .{ .object = loc_obj }) catch continue;
                        }

                        // Serialize the update object to JSON.
                        var json_buf: std.Io.Writer.Allocating = .init(allocator);
                        defer json_buf.deinit();
                        std.json.Stringify.value(std.json.Value{ .object = update_obj }, .{}, &json_buf.writer) catch continue;
                        const json_body = json_buf.written();

                        // Build the path: /me/events/{eventId}
                        const path = std.fmt.allocPrint(
                            allocator,
                            "/me/events/{s}",
                            .{event_id},
                        ) catch continue;
                        defer allocator.free(path);

                        // PATCH /me/events/{eventId} — updates the event.
                        const response_body = graph.patch(allocator, io, token, path, json_body) catch |err| {
                            std.debug.print("ms-mcp: update-calendar-event failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to update calendar event." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };
                        defer allocator.free(response_body);

                        // Return the updated event details.
                        const content: []const types.TextContent = &.{
                            .{ .text = response_body },
                        };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = .{ .content = content },
                        });
                    } else if (std.mem.eql(u8, name, "delete-calendar-event")) {
                        // Check that the user is logged in.
                        const token = requireAuth(&state, allocator, io, client_id, tenant_id, writer, getRequestId(parsed.value)) orelse continue;
                        if (!checkTimezone(&state, allocator, io, token, writer, getRequestId(parsed.value))) continue;

                        // Get tool arguments — eventId is required.
                        const args = getToolArgs(parsed.value) orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing arguments. Provide eventId." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // "eventId" — the ID of the event to delete (from list-calendar-events).
                        const event_id = getStringArg(args, "eventId") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'eventId' argument." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // Build the path: /me/events/{eventId}
                        const path = std.fmt.allocPrint(
                            allocator,
                            "/me/events/{s}",
                            .{event_id},
                        ) catch continue;
                        defer allocator.free(path);

                        // DELETE the event. Returns void on success (204 No Content).
                        graph.delete(allocator, io, token, path) catch |err| {
                            std.debug.print("ms-mcp: delete-calendar-event failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to delete calendar event." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // Success.
                        const content: []const types.TextContent = &.{
                            .{ .text = "Calendar event deleted." },
                        };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = .{ .content = content },
                        });
                    } else if (std.mem.eql(u8, name, "create-calendar-event")) {
                        // Check that the user is logged in.
                        const token = requireAuth(&state, allocator, io, client_id, tenant_id, writer, getRequestId(parsed.value)) orelse continue;
                        if (!checkTimezone(&state, allocator, io, token, writer, getRequestId(parsed.value))) continue;

                        // Get tool arguments.
                        const args = getToolArgs(parsed.value) orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing arguments. Provide subject, startDateTime, and endDateTime." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // "subject" — the event title (required).
                        const subject = getStringArg(args, "subject") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'subject' argument." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // "startDateTime" — ISO 8601, e.g. "2026-02-24T09:00:00" (required).
                        const start_dt = getStringArg(args, "startDateTime") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'startDateTime' argument (ISO 8601 format)." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // "endDateTime" — ISO 8601, e.g. "2026-02-24T10:00:00" (required).
                        const end_dt = getStringArg(args, "endDateTime") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'endDateTime' argument (ISO 8601 format)." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // Optional fields — null if not provided.
                        const body_text = getStringArg(args, "body");
                        const location_name = getStringArg(args, "location");

                        // Parse "attendees" — required attendees (optional field).
                        const required_attendees = parseAttendees(allocator, args, "attendees", "required") catch continue;
                        defer if (required_attendees) |a| allocator.free(a);

                        // Parse "optionalAttendees" — optional attendees (optional field).
                        const optional_attendees = parseAttendees(allocator, args, "optionalAttendees", "optional") catch continue;
                        defer if (optional_attendees) |a| allocator.free(a);

                        // Merge required + optional attendees into one slice.
                        // Graph API uses a single "attendees" array with a "type" field on each.
                        const req_len = if (required_attendees) |a| a.len else 0;
                        const opt_len = if (optional_attendees) |a| a.len else 0;
                        const total_len = req_len + opt_len;

                        // Only build the merged array if there are any attendees.
                        const all_attendees: ?[]const types.CreateEventRequest.Attendee = if (total_len > 0) blk: {
                            const merged = allocator.alloc(types.CreateEventRequest.Attendee, total_len) catch continue;
                            var idx: usize = 0;
                            if (required_attendees) |a| {
                                for (a) |att| {
                                    merged[idx] = att;
                                    idx += 1;
                                }
                            }
                            if (optional_attendees) |a| {
                                for (a) |att| {
                                    merged[idx] = att;
                                    idx += 1;
                                }
                            }
                            break :blk merged;
                        } else null;
                        defer if (all_attendees) |a| allocator.free(a);

                        // Build the event request struct.
                        // Optional fields are null if not provided — Stringify omits them.
                        const event_request = types.CreateEventRequest{
                            .subject = subject,
                            .start = .{ .dateTime = start_dt, .timeZone = state.timezone },
                            .end = .{ .dateTime = end_dt, .timeZone = state.timezone },
                            .body = if (body_text) |b| .{ .content = b } else null,
                            .location = if (location_name) |l| .{ .displayName = l } else null,
                            .attendees = all_attendees,
                        };

                        // Serialize the struct to JSON.
                        var json_buf: std.Io.Writer.Allocating = .init(allocator);
                        defer json_buf.deinit();
                        // emit_null_optional_fields=false tells Stringify to skip
                        // null optional fields instead of writing "field":null.
                        // The Graph API rejects null values for fields like body,
                        // location, attendees — it wants them omitted entirely.
                        std.json.Stringify.value(event_request, .{ .emit_null_optional_fields = false }, &json_buf.writer) catch continue;
                        const json_body = json_buf.written();

                        // POST /me/events — creates the calendar event.
                        const response_body = graph.post(allocator, io, token, "/me/events", json_body) catch |err| {
                            std.debug.print("ms-mcp: create-calendar-event failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to create calendar event." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };
                        defer allocator.free(response_body);

                        // Return the response — includes the new event ID and details.
                        const content: []const types.TextContent = &.{
                            .{ .text = response_body },
                        };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = .{ .content = content },
                        });
                    } else if (std.mem.eql(u8, name, "list-calendar-events")) {
                        // Check that the user is logged in.
                        const token = requireAuth(&state, allocator, io, client_id, tenant_id, writer, getRequestId(parsed.value)) orelse continue;
                        if (!checkTimezone(&state, allocator, io, token, writer, getRequestId(parsed.value))) continue;

                        // Get tool arguments — startDateTime and endDateTime are required.
                        const args = getToolArgs(parsed.value) orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing arguments. Provide startDateTime and endDateTime." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // "startDateTime" — ISO 8601 format, e.g. "2026-02-23T00:00:00Z"
                        const start = getStringArg(args, "startDateTime") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'startDateTime' argument (ISO 8601 format)." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // "endDateTime" — ISO 8601 format, e.g. "2026-02-24T00:00:00Z"
                        const end = getStringArg(args, "endDateTime") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'endDateTime' argument (ISO 8601 format)." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };

                        // Convert local times to UTC for the query parameters.
                        // Graph API always interprets startDateTime/endDateTime as UTC,
                        // regardless of the Prefer: outlook.timezone header.
                        // So we convert here so the LLM can just pass local times.
                        const utc_offset = getUtcOffset(state.timezone) orelse 0;
                        const start_utc = localToUtc(allocator, start, utc_offset) catch {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Invalid startDateTime format. Use ISO 8601 (e.g. 2026-02-24T00:00:00)." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };
                        defer allocator.free(start_utc);

                        const end_utc = localToUtc(allocator, end, utc_offset) catch {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Invalid endDateTime format. Use ISO 8601 (e.g. 2026-02-25T00:00:00)." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };
                        defer allocator.free(end_utc);

                        // Build the calendarView URL with date range and field selection.
                        // calendarView (not /events) expands recurring events into instances.
                        // $select limits to just the fields we need.
                        // $orderby sorts by start time ascending.
                        // $top=25 limits to 25 events.
                        const path = std.fmt.allocPrint(
                            allocator,
                            "/me/calendarView?startDateTime={s}&endDateTime={s}&$top=25&$select=id,subject,start,end,location,organizer,isAllDay&$orderby=start/dateTime",
                            .{ start_utc, end_utc },
                        ) catch continue;
                        defer allocator.free(path);

                        // GET the calendar events with Prefer header for timezone.
                        // The Prefer header makes the API return times in the user's timezone —
                        // but does NOT affect how query params are interpreted (always UTC).
                        // That's why we converted to UTC above.
                        const prefer_header = std.fmt.allocPrint(
                            allocator,
                            "outlook.timezone=\"{s}\"",
                            .{state.timezone},
                        ) catch continue;
                        defer allocator.free(prefer_header);
                        const response_body = graph.getWithPrefer(allocator, io, token, path, prefer_header) catch |err| {
                            std.debug.print("ms-mcp: list-calendar-events failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to fetch calendar events." },
                            };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = .{ .content = content },
                            });
                            continue;
                        };
                        defer allocator.free(response_body);

                        // Return the raw JSON — the LLM will summarize it for the user.
                        const content: []const types.TextContent = &.{
                            .{ .text = response_body },
                        };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = .{ .content = content },
                        });
                    } else if (std.mem.eql(u8, name, "create-chat")) {
                        // Check that the user is logged in.
                        const token = requireAuth(&state, allocator, io, client_id, tenant_id, writer, getRequestId(parsed.value)) orelse continue;

                        // Get the two email addresses.
                        const args = getToolArgs(parsed.value) orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing arguments. Provide emailOne and emailTwo." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // "emailOne" — first member's email (use search-users to find it).
                        const email_one = getStringArg(args, "emailOne") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'emailOne' argument." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // "emailTwo" — second member's email.
                        const email_two = getStringArg(args, "emailTwo") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'emailTwo' argument." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // Build the two member JSON objects using the helper.
                        // buildMemberJson accepts both emails and GUIDs —
                        // the Graph API users('...') binding works with either.
                        const member1 = buildMemberJson(allocator, email_one) catch continue;
                        defer allocator.free(member1);
                        const member2 = buildMemberJson(allocator, email_two) catch continue;
                        defer allocator.free(member2);

                        // Assemble the full request body.
                        // chatType is "oneOnOne", members is the two member objects.
                        const json_body = std.fmt.allocPrint(allocator,
                            \\{{"chatType":"oneOnOne","members":[{s},{s}]}}
                        , .{ member1, member2 }) catch continue;
                        defer allocator.free(json_body);

                        // POST /me/chats — creates the chat or returns existing one.
                        const response_body = graph.post(allocator, io, token, "/me/chats", json_body) catch |err| {
                            std.debug.print("ms-mcp: create-chat failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to create chat." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };
                        defer allocator.free(response_body);

                        // Return the response — includes the chat ID.
                        const content: []const types.TextContent = &.{
                            .{ .text = response_body },
                        };
                        const result = types.ToolCallResult{ .content = content };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = result,
                        });
                    }
                }
            } else if (std.mem.eql(u8, m, "tools/list")) {
                // Build the tool definitions with proper JSON Schema inputSchemas.
                // We build these at runtime because std.json.Value can't be
                // created in comptime struct literals.

                // --- send-email schema ---
                // Build properties: to, subject, body, cc, bcc
                var send_email_props = std.json.ObjectMap.init(allocator);
                defer send_email_props.deinit();
                send_email_props.put("to", schemaProperty("array", "Array of recipient email addresses")) catch continue;
                send_email_props.put("subject", schemaProperty("string", "Email subject line")) catch continue;
                send_email_props.put("body", schemaProperty("string", "Email body text")) catch continue;
                send_email_props.put("cc", schemaProperty("array", "Optional array of CC email addresses")) catch continue;
                send_email_props.put("bcc", schemaProperty("array", "Optional array of BCC email addresses")) catch continue;

                // --- list-chat-messages schema ---
                var chat_msgs_props = std.json.ObjectMap.init(allocator);
                defer chat_msgs_props.deinit();
                chat_msgs_props.put("chatId", schemaProperty("string", "The ID of the chat to read messages from")) catch continue;

                // --- search-users schema ---
                var search_users_props = std.json.ObjectMap.init(allocator);
                defer search_users_props.deinit();
                search_users_props.put("query", schemaProperty("string", "Person's name to search for (e.g. 'Berry Cheung')")) catch continue;

                // --- create-chat schema ---
                var create_chat_props = std.json.ObjectMap.init(allocator);
                defer create_chat_props.deinit();
                create_chat_props.put("emailOne", schemaProperty("string", "First member's email address (use search-users to find it)")) catch continue;
                create_chat_props.put("emailTwo", schemaProperty("string", "Second member's email address")) catch continue;

                // --- update-calendar-event schema ---
                var cal_update_props = std.json.ObjectMap.init(allocator);
                defer cal_update_props.deinit();
                cal_update_props.put("eventId", schemaProperty("string", "The ID of the event to update (from list-calendar-events)")) catch continue;
                cal_update_props.put("subject", schemaProperty("string", "New event title/subject")) catch continue;
                cal_update_props.put("startDateTime", schemaProperty("string", "New start time in ISO 8601 format")) catch continue;
                cal_update_props.put("endDateTime", schemaProperty("string", "New end time in ISO 8601 format")) catch continue;
                cal_update_props.put("body", schemaProperty("string", "New event body/description text")) catch continue;
                cal_update_props.put("location", schemaProperty("string", "New location name")) catch continue;

                // --- delete-calendar-event schema ---
                var cal_delete_props = std.json.ObjectMap.init(allocator);
                defer cal_delete_props.deinit();
                cal_delete_props.put("eventId", schemaProperty("string", "The ID of the event to delete (from list-calendar-events)")) catch continue;

                // --- create-calendar-event schema ---
                var cal_create_props = std.json.ObjectMap.init(allocator);
                defer cal_create_props.deinit();
                cal_create_props.put("subject", schemaProperty("string", "Event title/subject")) catch continue;
                cal_create_props.put("startDateTime", schemaProperty("string", "Start time in ISO 8601 format (e.g. 2026-02-24T09:00:00)")) catch continue;
                cal_create_props.put("endDateTime", schemaProperty("string", "End time in ISO 8601 format (e.g. 2026-02-24T10:00:00)")) catch continue;
                cal_create_props.put("body", schemaProperty("string", "Optional event body/description text")) catch continue;
                cal_create_props.put("location", schemaProperty("string", "Optional location name")) catch continue;
                cal_create_props.put("attendees", schemaProperty("array", "Optional array of required attendee email addresses")) catch continue;
                cal_create_props.put("optionalAttendees", schemaProperty("array", "Optional array of optional attendee email addresses")) catch continue;

                // --- get-calendar-event schema ---
                var cal_get_props = std.json.ObjectMap.init(allocator);
                defer cal_get_props.deinit();
                cal_get_props.put("eventId", schemaProperty("string", "The ID of the calendar event to fetch (from list-calendar-events)")) catch continue;

                // --- list-calendar-events schema ---
                var cal_list_props = std.json.ObjectMap.init(allocator);
                defer cal_list_props.deinit();
                cal_list_props.put("startDateTime", schemaProperty("string", "Start of date range in local time, ISO 8601 format (e.g. 2026-02-23T00:00:00)")) catch continue;
                cal_list_props.put("endDateTime", schemaProperty("string", "End of date range in local time, ISO 8601 format (e.g. 2026-02-24T00:00:00)")) catch continue;

                // --- read-email schema ---
                var read_email_props = std.json.ObjectMap.init(allocator);
                defer read_email_props.deinit();
                read_email_props.put("emailId", schemaProperty("string", "The ID of the email to read (from list-emails results)")) catch continue;

                // --- send-chat-message schema ---
                var send_chat_props = std.json.ObjectMap.init(allocator);
                defer send_chat_props.deinit();
                send_chat_props.put("chatId", schemaProperty("string", "The ID of the chat to send the message to")) catch continue;
                send_chat_props.put("message", schemaProperty("string", "The message text to send")) catch continue;

                // Build the tools array.
                // Grouped by category: calendar, email, chat, then utility.
                // Most-used tools first within each group.
                const tools = &[_]types.ToolDefinition{
                    // --- Calendar ---
                    .{
                        .name = "create-calendar-event",
                        .description = "Create a calendar event or meeting on Microsoft 365 / Teams / Outlook. Pass times in local time — the server handles timezone automatically. Supports subject, start/end times, body, location, required attendees, and optional attendees.",
                        .inputSchema = buildSchema(cal_create_props, &.{ "subject", "startDateTime", "endDateTime" }),
                    },
                    .{
                        .name = "list-calendar-events",
                        .description = "List calendar events and meetings from Microsoft 365 / Teams / Outlook in a date range. Use this to check what's on the calendar. Pass startDateTime and endDateTime in local time (e.g. 2026-02-24T00:00:00 to 2026-02-25T00:00:00 for a full day). Expands recurring events. Results are in the user's local timezone.",
                        .inputSchema = buildSchema(cal_list_props, &.{ "startDateTime", "endDateTime" }),
                    },
                    .{
                        .name = "get-calendar-event",
                        .description = "Get full details of a calendar event or meeting by ID. Returns subject, start/end, location, body, attendees, and organizer.",
                        .inputSchema = buildSchema(cal_get_props, &.{"eventId"}),
                    },
                    .{
                        .name = "update-calendar-event",
                        .description = "Update a calendar event or meeting. Only provide the fields you want to change. Pass times in local time — the server handles timezone automatically.",
                        .inputSchema = buildSchema(cal_update_props, &.{"eventId"}),
                    },
                    .{
                        .name = "delete-calendar-event",
                        .description = "Delete a calendar event or meeting by ID.",
                        .inputSchema = buildSchema(cal_delete_props, &.{"eventId"}),
                    },
                    // --- Email ---
                    .{
                        .name = "list-emails",
                        .description = "List recent emails from Microsoft 365 Outlook inbox. Returns subject, sender, date, and preview for the 10 most recent messages.",
                        .inputSchema = emptySchema(),
                    },
                    .{
                        .name = "read-email",
                        .description = "Read the full content of an email by ID. Returns subject, sender, recipients, CC, date, full body, and read status. Use list-emails first to get the email ID.",
                        .inputSchema = buildSchema(read_email_props, &.{"emailId"}),
                    },
                    .{
                        .name = "send-email",
                        .description = "Send an email via Microsoft 365 Outlook. Supports multiple recipients, CC, and BCC.",
                        .inputSchema = buildSchema(send_email_props, &.{ "to", "subject", "body" }),
                    },
                    // --- Teams Chat ---
                    .{
                        .name = "list-chats",
                        .description = "List recent Microsoft Teams chats including 1:1 conversations, group chats, and meeting chats.",
                        .inputSchema = emptySchema(),
                    },
                    .{
                        .name = "list-chat-messages",
                        .description = "List recent messages in a Microsoft Teams chat by chat ID.",
                        .inputSchema = buildSchema(chat_msgs_props, &.{"chatId"}),
                    },
                    .{
                        .name = "send-chat-message",
                        .description = "Send a message in a Microsoft Teams chat.",
                        .inputSchema = buildSchema(send_chat_props, &.{ "chatId", "message" }),
                    },
                    .{
                        .name = "create-chat",
                        .description = "Create or find an existing 1:1 Microsoft Teams chat between two users by email address.",
                        .inputSchema = buildSchema(create_chat_props, &.{ "emailOne", "emailTwo" }),
                    },
                    // --- Utility ---
                    .{
                        .name = "search-users",
                        .description = "Search for people in your Microsoft 365 organization by name. Returns display names and email addresses. Use this to find someone's email address.",
                        .inputSchema = buildSchema(search_users_props, &.{"query"}),
                    },
                    .{
                        .name = "get-profile",
                        .description = "Get the logged-in user's Microsoft 365 profile including display name and email.",
                        .inputSchema = emptySchema(),
                    },
                    .{
                        .name = "login",
                        .description = "Log in to Microsoft 365. Starts the OAuth device code authentication flow. Returns a code to enter at the Microsoft login page.",
                        .inputSchema = emptySchema(),
                    },
                    .{
                        .name = "verify-login",
                        .description = "Complete the Microsoft 365 login. Polls for authentication after the user enters the device code. Call login first.",
                        .inputSchema = emptySchema(),
                    },
                    .{
                        .name = "get-mailbox-settings",
                        .description = "Get the user's Microsoft 365 mailbox settings including timezone, language, and date format.",
                        .inputSchema = emptySchema(),
                    },
                    .{
                        .name = "sync-timezone",
                        .description = "Sync the Microsoft 365 mailbox timezone to match this computer's system timezone. Run after traveling to a new timezone.",
                        .inputSchema = emptySchema(),
                    },
                };

                sendJsonResponse(writer, types.JsonRpcResponse(types.ToolsListResult){
                    .id = getRequestId(parsed.value),
                    .result = .{ .tools = tools },
                });
            } else {
                // Unknown method — if it has an id (a request), return a
                // JSON-RPC "method not found" error. Notifications (no id) are
                // silently ignored per the JSON-RPC spec.
                const request_id = getRequestId(parsed.value);
                if (request_id != 0) {
                    const JsonRpcError = struct {
                        jsonrpc: []const u8 = "2.0",
                        id: i64,
                        @"error": ErrorBody,

                        const ErrorBody = struct {
                            code: i64 = -32601,
                            message: []const u8 = "Method not found",
                        };
                    };
                    sendJsonResponse(writer, JsonRpcError{
                        .id = request_id,
                        .@"error" = .{},
                    });
                }
            }
        }
    }
}
