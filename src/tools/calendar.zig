// tools/calendar.zig — Calendar event tools.

const std = @import("std");
const types = @import("../types.zig");
const graph = @import("../graph.zig");
const json_rpc = @import("../json_rpc.zig");
const state_mod = @import("../state.zig");
const tz = @import("../timezone.zig");
const ToolContext = @import("context.zig").ToolContext;

const Allocator = std.mem.Allocator;

/// Convert a JSON array of email strings into a slice of Attendee structs.
fn parseAttendees(
    allocator: Allocator,
    args: std.json.ObjectMap,
    key: []const u8,
    attendee_type: []const u8,
) !?[]const types.CreateEventRequest.Attendee {
    const val = args.get(key) orelse return null;
    const arr = switch (val) {
        .array => |a| a,
        else => return null,
    };
    const attendees = try allocator.alloc(types.CreateEventRequest.Attendee, arr.items.len);
    for (arr.items, 0..) |item, i| {
        const email = switch (item) {
            .string => |s| s,
            else => {
                allocator.free(attendees);
                return null;
            },
        };
        attendees[i] = .{ .emailAddress = .{ .address = email }, .type = attendee_type };
    }
    return attendees;
}

/// Check auth + one-time timezone check. Returns token or null.
fn authAndTimezone(ctx: ToolContext) ?[]const u8 {
    const token = ctx.requireAuth() orelse return null;
    if (!state_mod.checkTimezone(ctx.state, ctx.allocator, ctx.io, token, ctx.writer, ctx.requestId())) return null;
    return token;
}

/// Get full details of a calendar event by ID.
pub fn handleGetCalendarEvent(ctx: ToolContext) void {
    const token = authAndTimezone(ctx) orelse return;
    const args = ctx.getArgs("Missing arguments. Provide eventId.") orelse return;
    const event_id = ctx.getPathArg(args, "eventId", "Missing 'eventId' argument.") orelse return;

    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/me/events/{s}?$select=id,subject,start,end,location,body,attendees,organizer,isAllDay",
        .{event_id},
    ) catch return;
    defer ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch {
        ctx.sendResult("Failed to fetch calendar event.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}

/// Update a calendar event's subject, times, body, or location.
pub fn handleUpdateCalendarEvent(ctx: ToolContext) void {
    const token = authAndTimezone(ctx) orelse return;
    const args = ctx.getArgs("Missing arguments. Provide eventId and fields to update.") orelse return;
    const event_id = ctx.getPathArg(args, "eventId", "Missing 'eventId' argument.") orelse return;

    // Build PATCH body with only provided fields.
    var update_obj = std.json.ObjectMap.init(ctx.allocator);
    defer update_obj.deinit();

    if (json_rpc.getStringArg(args, "subject")) |s|
        update_obj.put("subject", .{ .string = s }) catch return;

    if (json_rpc.getStringArg(args, "startDateTime")) |s| {
        var obj = std.json.ObjectMap.init(ctx.allocator);
        obj.put("dateTime", .{ .string = s }) catch return;
        obj.put("timeZone", .{ .string = ctx.state.timezone }) catch return;
        update_obj.put("start", .{ .object = obj }) catch return;
    }
    if (json_rpc.getStringArg(args, "endDateTime")) |e| {
        var obj = std.json.ObjectMap.init(ctx.allocator);
        obj.put("dateTime", .{ .string = e }) catch return;
        obj.put("timeZone", .{ .string = ctx.state.timezone }) catch return;
        update_obj.put("end", .{ .object = obj }) catch return;
    }
    if (json_rpc.getStringArg(args, "body")) |b| {
        var obj = std.json.ObjectMap.init(ctx.allocator);
        obj.put("contentType", .{ .string = "Text" }) catch return;
        obj.put("content", .{ .string = b }) catch return;
        update_obj.put("body", .{ .object = obj }) catch return;
    }
    if (json_rpc.getStringArg(args, "location")) |l| {
        var obj = std.json.ObjectMap.init(ctx.allocator);
        obj.put("displayName", .{ .string = l }) catch return;
        update_obj.put("location", .{ .object = obj }) catch return;
    }

    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(std.json.Value{ .object = update_obj }, .{}, &json_buf.writer) catch return;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/events/{s}", .{event_id}) catch return;
    defer ctx.allocator.free(path);

    const response = graph.patch(ctx.allocator, ctx.io, token, path, json_buf.written()) catch {
        ctx.sendResult("Failed to update calendar event.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}

/// Delete a calendar event by ID.
pub fn handleDeleteCalendarEvent(ctx: ToolContext) void {
    const token = authAndTimezone(ctx) orelse return;
    const args = ctx.getArgs("Missing arguments. Provide eventId.") orelse return;
    const event_id = ctx.getPathArg(args, "eventId", "Missing 'eventId' argument.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/events/{s}", .{event_id}) catch return;
    defer ctx.allocator.free(path);

    graph.delete(ctx.allocator, ctx.io, token, path) catch {
        ctx.sendResult("Failed to delete calendar event.");
        return;
    };

    ctx.sendResult("Calendar event deleted.");
}

/// Create a new calendar event with optional attendees.
pub fn handleCreateCalendarEvent(ctx: ToolContext) void {
    const token = authAndTimezone(ctx) orelse return;
    const args = ctx.getArgs("Missing arguments. Provide subject, startDateTime, and endDateTime.") orelse return;

    const subject = ctx.getStringArg(args, "subject", "Missing 'subject' argument.") orelse return;
    const start_dt = ctx.getStringArg(args, "startDateTime", "Missing 'startDateTime' argument (ISO 8601 format).") orelse return;
    const end_dt = ctx.getStringArg(args, "endDateTime", "Missing 'endDateTime' argument (ISO 8601 format).") orelse return;
    const body_text = json_rpc.getStringArg(args, "body");
    const location_name = json_rpc.getStringArg(args, "location");

    // Parse attendees (both optional).
    const required = parseAttendees(ctx.allocator, args, "attendees", "required") catch return;
    defer if (required) |a| ctx.allocator.free(a);
    const optional = parseAttendees(ctx.allocator, args, "optionalAttendees", "optional") catch return;
    defer if (optional) |a| ctx.allocator.free(a);

    // Merge required + optional into one slice.
    const req_len = if (required) |a| a.len else 0;
    const opt_len = if (optional) |a| a.len else 0;
    const all_attendees: ?[]const types.CreateEventRequest.Attendee = if (req_len + opt_len > 0) blk: {
        const merged = ctx.allocator.alloc(types.CreateEventRequest.Attendee, req_len + opt_len) catch return;
        var idx: usize = 0;
        if (required) |a| for (a) |att| {
            merged[idx] = att;
            idx += 1;
        };
        if (optional) |a| for (a) |att| {
            merged[idx] = att;
            idx += 1;
        };
        break :blk merged;
    } else null;
    defer if (all_attendees) |a| ctx.allocator.free(a);

    const event_request = types.CreateEventRequest{
        .subject = subject,
        .start = .{ .dateTime = start_dt, .timeZone = ctx.state.timezone },
        .end = .{ .dateTime = end_dt, .timeZone = ctx.state.timezone },
        .body = if (body_text) |b| .{ .content = b } else null,
        .location = if (location_name) |l| .{ .displayName = l } else null,
        .attendees = all_attendees,
    };

    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(event_request, .{ .emit_null_optional_fields = false }, &json_buf.writer) catch return;

    const response = graph.post(ctx.allocator, ctx.io, token, "/me/events", json_buf.written()) catch {
        ctx.sendResult("Failed to create calendar event.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}

/// List calendar events in a date range (expands recurring events).
pub fn handleListCalendarEvents(ctx: ToolContext) void {
    const token = authAndTimezone(ctx) orelse return;
    const args = ctx.getArgs("Missing arguments. Provide startDateTime and endDateTime.") orelse return;
    const start = ctx.getStringArg(args, "startDateTime", "Missing 'startDateTime' argument (ISO 8601 format).") orelse return;
    const end = ctx.getStringArg(args, "endDateTime", "Missing 'endDateTime' argument (ISO 8601 format).") orelse return;

    // Convert local times to UTC for query parameters.
    const utc_offset = tz.getUtcOffset(ctx.state.timezone) orelse 0;
    const start_utc = tz.localToUtc(ctx.allocator, start, utc_offset) catch {
        ctx.sendResult("Invalid startDateTime format. Use ISO 8601 (e.g. 2026-02-24T00:00:00).");
        return;
    };
    defer ctx.allocator.free(start_utc);
    const end_utc = tz.localToUtc(ctx.allocator, end, utc_offset) catch {
        ctx.sendResult("Invalid endDateTime format. Use ISO 8601 (e.g. 2026-02-25T00:00:00).");
        return;
    };
    defer ctx.allocator.free(end_utc);

    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/me/calendarView?startDateTime={s}&endDateTime={s}&$top=25&$select=id,subject,start,end,location,organizer,isAllDay&$orderby=start/dateTime",
        .{ start_utc, end_utc },
    ) catch return;
    defer ctx.allocator.free(path);

    // Prefer header makes API return times in the user's timezone.
    const prefer = std.fmt.allocPrint(ctx.allocator, "outlook.timezone=\"{s}\"", .{ctx.state.timezone}) catch return;
    defer ctx.allocator.free(prefer);

    const response = graph.getWithPrefer(ctx.allocator, ctx.io, token, path, prefer) catch {
        ctx.sendResult("Failed to fetch calendar events.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}
