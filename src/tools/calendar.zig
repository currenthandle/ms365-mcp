// tools/calendar.zig — Calendar event tools.

const std = @import("std");
const types = @import("../types.zig");
const graph = @import("../graph.zig");
const json_rpc = @import("../json_rpc.zig");
const state_mod = @import("../state.zig");
const tz = @import("../timezone.zig");
const ToolContext = @import("context.zig").ToolContext;

// Type aliases — keeps function signatures cleaner.
const Allocator = std.mem.Allocator;

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

/// Get full details of a calendar event by ID.
pub fn handleGetCalendarEvent(ctx: ToolContext) void {
    // Check that the user is logged in.
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;
    // One-time timezone check — warns user if mailbox tz ≠ system tz.
    if (!state_mod.checkTimezone(ctx.state, ctx.allocator, ctx.io, token, ctx.writer, json_rpc.getRequestId(ctx.parsed))) return;

    // Get tool arguments — eventId is required.
    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing arguments. Provide eventId." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // "eventId" — the ID of the event to fetch (from list-calendar-events).
    const event_id = json_rpc.getPathArg(args, "eventId") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'eventId' argument." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // Build the path: /me/events/{eventId}
    // $select includes body and attendees — the full details you'd want
    // when drilling into a specific event.
    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/me/events/{s}?$select=id,subject,start,end,location,body,attendees,organizer,isAllDay",
        .{event_id},
    ) catch return;
    defer ctx.allocator.free(path);

    // GET the event details.
    const response_body = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        std.debug.print("ms-mcp: get-calendar-event failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to fetch calendar event." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };
    defer ctx.allocator.free(response_body);

    // Return raw JSON — it's a single event, reasonably sized.
    const content: []const types.TextContent = &.{
        .{ .text = response_body },
    };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = .{ .content = content },
    });
}

/// Update a calendar event's subject, times, body, or location.
pub fn handleUpdateCalendarEvent(ctx: ToolContext) void {
    // Check that the user is logged in.
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;
    if (!state_mod.checkTimezone(ctx.state, ctx.allocator, ctx.io, token, ctx.writer, json_rpc.getRequestId(ctx.parsed))) return;

    // Get tool arguments — eventId is required, everything else is optional.
    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing arguments. Provide eventId and fields to update." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // "eventId" — the ID of the event to update (required).
    const event_id = json_rpc.getPathArg(args, "eventId") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'eventId' argument." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // All fields are optional for update — only provided ones get sent.
    // We build JSON manually using ObjectMap because CreateEventRequest
    // has required fields (subject, start, end) that would always be sent.
    // For PATCH, we only want to include fields the user actually provided.
    var update_obj = std.json.ObjectMap.init(ctx.allocator);
    defer update_obj.deinit();

    // Add each field only if the LLM provided it.
    if (json_rpc.getStringArg(args, "subject")) |s| {
        update_obj.put("subject", .{ .string = s }) catch return;
    }
    if (json_rpc.getStringArg(args, "startDateTime")) |s| {
        // Build the nested {"dateTime": "...", "timeZone": "..."} object.
        var start_obj = std.json.ObjectMap.init(ctx.allocator);
        start_obj.put("dateTime", .{ .string = s }) catch return;
        start_obj.put("timeZone", .{ .string = ctx.state.timezone }) catch return;
        update_obj.put("start", .{ .object = start_obj }) catch return;
    }
    if (json_rpc.getStringArg(args, "endDateTime")) |e| {
        var end_obj = std.json.ObjectMap.init(ctx.allocator);
        end_obj.put("dateTime", .{ .string = e }) catch return;
        end_obj.put("timeZone", .{ .string = ctx.state.timezone }) catch return;
        update_obj.put("end", .{ .object = end_obj }) catch return;
    }
    if (json_rpc.getStringArg(args, "body")) |b| {
        var body_obj = std.json.ObjectMap.init(ctx.allocator);
        body_obj.put("contentType", .{ .string = "Text" }) catch return;
        body_obj.put("content", .{ .string = b }) catch return;
        update_obj.put("body", .{ .object = body_obj }) catch return;
    }
    if (json_rpc.getStringArg(args, "location")) |l| {
        var loc_obj = std.json.ObjectMap.init(ctx.allocator);
        loc_obj.put("displayName", .{ .string = l }) catch return;
        update_obj.put("location", .{ .object = loc_obj }) catch return;
    }

    // Serialize the update object to JSON.
    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(std.json.Value{ .object = update_obj }, .{}, &json_buf.writer) catch return;
    const json_body = json_buf.written();

    // Build the path: /me/events/{eventId}
    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/me/events/{s}",
        .{event_id},
    ) catch return;
    defer ctx.allocator.free(path);

    // PATCH /me/events/{eventId} — updates the event.
    const response_body = graph.patch(ctx.allocator, ctx.io, token, path, json_body) catch |err| {
        std.debug.print("ms-mcp: update-calendar-event failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to update calendar event." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };
    defer ctx.allocator.free(response_body);

    // Return the updated event details.
    const content: []const types.TextContent = &.{
        .{ .text = response_body },
    };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = .{ .content = content },
    });
}

/// Delete a calendar event by ID.
pub fn handleDeleteCalendarEvent(ctx: ToolContext) void {
    // Check that the user is logged in.
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;
    if (!state_mod.checkTimezone(ctx.state, ctx.allocator, ctx.io, token, ctx.writer, json_rpc.getRequestId(ctx.parsed))) return;

    // Get tool arguments — eventId is required.
    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing arguments. Provide eventId." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // "eventId" — the ID of the event to delete (from list-calendar-events).
    const event_id = json_rpc.getPathArg(args, "eventId") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'eventId' argument." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // Build the path: /me/events/{eventId}
    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/me/events/{s}",
        .{event_id},
    ) catch return;
    defer ctx.allocator.free(path);

    // DELETE the event. Returns void on success (204 No Content).
    graph.delete(ctx.allocator, ctx.io, token, path) catch |err| {
        std.debug.print("ms-mcp: delete-calendar-event failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to delete calendar event." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // Success.
    const content: []const types.TextContent = &.{
        .{ .text = "Calendar event deleted." },
    };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = .{ .content = content },
    });
}

/// Create a new calendar event with optional attendees.
pub fn handleCreateCalendarEvent(ctx: ToolContext) void {
    // Check that the user is logged in.
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;
    if (!state_mod.checkTimezone(ctx.state, ctx.allocator, ctx.io, token, ctx.writer, json_rpc.getRequestId(ctx.parsed))) return;

    // Get tool arguments.
    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing arguments. Provide subject, startDateTime, and endDateTime." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // "subject" — the event title (required).
    const subject = json_rpc.getStringArg(args, "subject") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'subject' argument." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // "startDateTime" — ISO 8601, e.g. "2026-02-24T09:00:00" (required).
    const start_dt = json_rpc.getStringArg(args, "startDateTime") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'startDateTime' argument (ISO 8601 format)." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // "endDateTime" — ISO 8601, e.g. "2026-02-24T10:00:00" (required).
    const end_dt = json_rpc.getStringArg(args, "endDateTime") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'endDateTime' argument (ISO 8601 format)." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // Optional fields — null if not provided.
    const body_text = json_rpc.getStringArg(args, "body");
    const location_name = json_rpc.getStringArg(args, "location");

    // Parse "attendees" — required attendees (optional field).
    const required_attendees = parseAttendees(ctx.allocator, args, "attendees", "required") catch return;
    defer if (required_attendees) |a| ctx.allocator.free(a);

    // Parse "optionalAttendees" — optional attendees (optional field).
    const optional_attendees = parseAttendees(ctx.allocator, args, "optionalAttendees", "optional") catch return;
    defer if (optional_attendees) |a| ctx.allocator.free(a);

    // Merge required + optional attendees into one slice.
    // Graph API uses a single "attendees" array with a "type" field on each.
    const req_len = if (required_attendees) |a| a.len else 0;
    const opt_len = if (optional_attendees) |a| a.len else 0;
    const total_len = req_len + opt_len;

    // Only build the merged array if there are any attendees.
    const all_attendees: ?[]const types.CreateEventRequest.Attendee = if (total_len > 0) blk: {
        const merged = ctx.allocator.alloc(types.CreateEventRequest.Attendee, total_len) catch return;
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
    defer if (all_attendees) |a| ctx.allocator.free(a);

    // Build the event request struct.
    // Optional fields are null if not provided — Stringify omits them.
    const event_request = types.CreateEventRequest{
        .subject = subject,
        .start = .{ .dateTime = start_dt, .timeZone = ctx.state.timezone },
        .end = .{ .dateTime = end_dt, .timeZone = ctx.state.timezone },
        .body = if (body_text) |b| .{ .content = b } else null,
        .location = if (location_name) |l| .{ .displayName = l } else null,
        .attendees = all_attendees,
    };

    // Serialize the struct to JSON.
    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    // emit_null_optional_fields=false tells Stringify to skip
    // null optional fields instead of writing "field":null.
    // The Graph API rejects null values for fields like body,
    // location, attendees — it wants them omitted entirely.
    std.json.Stringify.value(event_request, .{ .emit_null_optional_fields = false }, &json_buf.writer) catch return;
    const json_body = json_buf.written();

    // POST /me/events — creates the calendar event.
    const response_body = graph.post(ctx.allocator, ctx.io, token, "/me/events", json_body) catch |err| {
        std.debug.print("ms-mcp: create-calendar-event failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to create calendar event." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };
    defer ctx.allocator.free(response_body);

    // Return the response — includes the new event ID and details.
    const content: []const types.TextContent = &.{
        .{ .text = response_body },
    };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = .{ .content = content },
    });
}

/// List calendar events in a date range (expands recurring events).
pub fn handleListCalendarEvents(ctx: ToolContext) void {
    // Check that the user is logged in.
    const token = state_mod.requireAuth(ctx.state, ctx.allocator, ctx.io, ctx.client_id, ctx.tenant_id, ctx.writer, json_rpc.getRequestId(ctx.parsed)) orelse return;
    if (!state_mod.checkTimezone(ctx.state, ctx.allocator, ctx.io, token, ctx.writer, json_rpc.getRequestId(ctx.parsed))) return;

    // Get tool arguments — startDateTime and endDateTime are required.
    const args = json_rpc.getToolArgs(ctx.parsed) orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing arguments. Provide startDateTime and endDateTime." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // "startDateTime" — ISO 8601 format, e.g. "2026-02-23T00:00:00Z"
    const start = json_rpc.getStringArg(args, "startDateTime") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'startDateTime' argument (ISO 8601 format)." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // "endDateTime" — ISO 8601 format, e.g. "2026-02-24T00:00:00Z"
    const end = json_rpc.getStringArg(args, "endDateTime") orelse {
        const content: []const types.TextContent = &.{
            .{ .text = "Missing 'endDateTime' argument (ISO 8601 format)." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };

    // Convert local times to UTC for the query parameters.
    // Graph API always interprets startDateTime/endDateTime as UTC,
    // regardless of the Prefer: outlook.timezone header.
    // So we convert here so the LLM can just pass local times.
    const utc_offset = tz.getUtcOffset(ctx.state.timezone) orelse 0;
    const start_utc = tz.localToUtc(ctx.allocator, start, utc_offset) catch {
        const content: []const types.TextContent = &.{
            .{ .text = "Invalid startDateTime format. Use ISO 8601 (e.g. 2026-02-24T00:00:00)." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };
    defer ctx.allocator.free(start_utc);

    const end_utc = tz.localToUtc(ctx.allocator, end, utc_offset) catch {
        const content: []const types.TextContent = &.{
            .{ .text = "Invalid endDateTime format. Use ISO 8601 (e.g. 2026-02-25T00:00:00)." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };
    defer ctx.allocator.free(end_utc);

    // Build the calendarView URL with date range and field selection.
    // calendarView (not /events) expands recurring events into instances.
    // $select limits to just the fields we need.
    // $orderby sorts by start time ascending.
    // $top=25 limits to 25 events.
    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/me/calendarView?startDateTime={s}&endDateTime={s}&$top=25&$select=id,subject,start,end,location,organizer,isAllDay&$orderby=start/dateTime",
        .{ start_utc, end_utc },
    ) catch return;
    defer ctx.allocator.free(path);

    // GET the calendar events with Prefer header for timezone.
    // The Prefer header makes the API return times in the user's timezone —
    // but does NOT affect how query params are interpreted (always UTC).
    // That's why we converted to UTC above.
    const prefer_header = std.fmt.allocPrint(
        ctx.allocator,
        "outlook.timezone=\"{s}\"",
        .{ctx.state.timezone},
    ) catch return;
    defer ctx.allocator.free(prefer_header);
    const response_body = graph.getWithPrefer(ctx.allocator, ctx.io, token, path, prefer_header) catch |err| {
        std.debug.print("ms-mcp: list-calendar-events failed: {}\n", .{err});
        const content: []const types.TextContent = &.{
            .{ .text = "Failed to fetch calendar events." },
        };
        json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
            .id = json_rpc.getRequestId(ctx.parsed),
            .result = .{ .content = content },
        });
        return;
    };
    defer ctx.allocator.free(response_body);

    // Return the raw JSON — the LLM will summarize it for the user.
    const content: []const types.TextContent = &.{
        .{ .text = response_body },
    };
    json_rpc.sendJsonResponse(ctx.writer, types.JsonRpcResponse(types.ToolCallResult){
        .id = json_rpc.getRequestId(ctx.parsed),
        .result = .{ .content = content },
    });
}
