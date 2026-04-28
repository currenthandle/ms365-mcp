// tools/calendar.zig — Calendar event tools.

const std = @import("std");
const types = @import("../types.zig");
const graph = @import("../graph.zig");
const json_rpc = @import("../json_rpc.zig");
const state_mod = @import("../state.zig");
const tz = @import("../timezone.zig");
const date_util = @import("../date_util.zig");
const ToolContext = @import("context.zig").ToolContext;
const formatter = @import("../formatter.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

// Fields surfaced from calendarView (list) and /me/events/{id} (get).
// start + end in Graph are {dateTime, timeZone} objects — we pull the
// .dateTime string from each. Location is {displayName}.
const list_event_fields = [_]formatter.FieldSpec{
    .{ .path = "subject", .label = "subject" },
    .{ .path = "start.dateTime", .label = "start", .is_date = true },
    .{ .path = "end.dateTime", .label = "end", .is_date = true },
    .{ .path = "location.displayName", .label = "location" },
    .{ .path = "organizer.emailAddress.name", .label = "organizer" },
};

const get_event_fields = [_]formatter.FieldSpec{
    .{ .path = "subject", .label = "subject" },
    .{ .path = "start.dateTime", .label = "start", .is_date = true },
    .{ .path = "end.dateTime", .label = "end", .is_date = true },
    .{ .path = "location.displayName", .label = "location" },
    .{ .path = "organizer.emailAddress.name", .label = "organizer" },
    .{ .path = "body.content", .label = "body", .newline_after = true },
};

/// Convert a JSON array of email strings into a slice of Attendee structs.
fn parseAttendees(
    allocator: Allocator,
    args: ObjectMap,
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

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    if (formatter.summarizeObject(ctx.allocator, response, &get_event_fields)) |summary| {
        defer ctx.allocator.free(summary);
        ctx.sendResult(summary);
    } else {
        ctx.sendResult("Event not found.");
    }
}

/// Update a calendar event's subject, times, body, or location.
pub fn handleUpdateCalendarEvent(ctx: ToolContext) void {
    const token = authAndTimezone(ctx) orelse return;
    const args = ctx.getArgs("Missing arguments. Provide eventId and fields to update.") orelse return;
    const event_id = ctx.getPathArg(args, "eventId", "Missing 'eventId' argument.") orelse return;

    // Build PATCH body with only provided fields.
    var update_obj: ObjectMap = .empty;
    defer update_obj.deinit(ctx.allocator);

    ctx.putStringIfPresent(&update_obj, args, "subject");

    if (json_rpc.getStringArg(args, "startDateTime")) |s| {
        var obj: ObjectMap = .empty;
        obj.put(ctx.allocator, "dateTime", .{ .string = s }) catch return;
        obj.put(ctx.allocator, "timeZone", .{ .string = ctx.state.timezone }) catch return;
        update_obj.put(ctx.allocator, "start", .{ .object = obj }) catch return;
    }
    if (json_rpc.getStringArg(args, "endDateTime")) |e| {
        var obj: ObjectMap = .empty;
        obj.put(ctx.allocator, "dateTime", .{ .string = e }) catch return;
        obj.put(ctx.allocator, "timeZone", .{ .string = ctx.state.timezone }) catch return;
        update_obj.put(ctx.allocator, "end", .{ .object = obj }) catch return;
    }
    if (json_rpc.getStringArg(args, "body")) |b| {
        var obj: ObjectMap = .empty;
        obj.put(ctx.allocator, "contentType", .{ .string = "Text" }) catch return;
        obj.put(ctx.allocator, "content", .{ .string = b }) catch return;
        update_obj.put(ctx.allocator, "body", .{ .object = obj }) catch return;
    }
    if (json_rpc.getStringArg(args, "location")) |l| {
        var obj: ObjectMap = .empty;
        obj.put(ctx.allocator, "displayName", .{ .string = l }) catch return;
        update_obj.put(ctx.allocator, "location", .{ .object = obj }) catch return;
    }

    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(Value{ .object = update_obj }, .{}, &json_buf.writer) catch return;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/events/{s}", .{event_id}) catch return;
    defer ctx.allocator.free(path);

    const response = graph.patch(ctx.allocator, ctx.io, token, path, json_buf.written()) catch |err| {
        ctx.sendGraphError(err);
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

    graph.delete(ctx.allocator, ctx.io, token, path) catch |err| {
        ctx.sendGraphError(err);
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

    const response = graph.post(ctx.allocator, ctx.io, token, "/me/events", json_buf.written()) catch |err| {
        ctx.sendGraphError(err);
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

    const response = graph.getWithPrefer(ctx.allocator, ctx.io, token, path, prefer) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    if (formatter.summarizeArray(ctx.allocator, response, &list_event_fields)) |summary| {
        defer ctx.allocator.free(summary);
        ctx.sendResult(summary);
    } else {
        ctx.sendResult("No events in that range.");
    }
}

// --- Scheduling tools (Phase 6) ---

/// Walk an ObjectMap via a list of key segments, returning the string at
/// the end of the path or "" if any step isn't an object or the final
/// value isn't a string. Like JS `obj?.a?.b?.c ?? ""`.
fn dottedString(root: ObjectMap, segments: []const []const u8) []const u8 {
    var cur: Value = .{ .object = root };
    for (segments) |seg| {
        const m = switch (cur) {
            .object => |o| o,
            else => return "",
        };
        cur = m.get(seg) orelse return "";
    }
    return switch (cur) {
        .string => |s| s,
        else => "",
    };
}


const find_times_suggestion_fields = [_]formatter.FieldSpec{
    .{ .path = "confidence", .label = "confidence" },
    .{ .path = "meetingTimeSlot.start.dateTime", .label = "start", .is_date = true },
    .{ .path = "meetingTimeSlot.end.dateTime", .label = "end", .is_date = true },
};

const get_schedule_slot_fields = [_]formatter.FieldSpec{
    .{ .path = "scheduleId", .label = "scheduleId" },
    .{ .path = "availabilityView", .label = "availability", .newline_after = true },
};

/// Find meeting times that work for a set of attendees.
/// Graph: POST /me/findMeetingTimes
///   body: {
///     "attendees": [{"emailAddress":{"address":"x"}, "type":"required"}],
///     "timeConstraint": {"timeslots":[{"start":{dateTime,timeZone}, "end":{...}}]},
///     "meetingDuration": "PT30M"
///   }
///
/// Microsoft's API returns this one as a single object with a
/// "meetingTimeSuggestions" array — we unwrap that before handing to the
/// formatter.
pub fn handleFindMeetingTimes(ctx: ToolContext) void {
    const token = authAndTimezone(ctx) orelse return;
    const args = ctx.getArgs("Missing arguments. Provide attendees, start, end, durationMinutes.") orelse return;

    const start = ctx.getStringArg(args, "start", "Missing 'start' (ISO 8601 local time, e.g. 2026-04-23T09:00:00).") orelse return;
    const end = ctx.getStringArg(args, "end", "Missing 'end' (ISO 8601 local time).") orelse return;

    // durationMinutes defaults to 30 if not provided or not an integer.
    const duration_min: i64 = if (args.get("durationMinutes")) |v| switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 30,
    } else 30;

    const required = parseAttendees(ctx.allocator, args, "attendees", "required") catch return;
    defer if (required) |a| ctx.allocator.free(a);
    if (required == null or required.?.len == 0) {
        ctx.sendResult("Missing 'attendees' — at least one required attendee email.");
        return;
    }

    // Build JSON body. Uses ObjectMap for attendees + timeConstraint, then
    // Stringify — no raw format-string injection of user fields.
    var body: ObjectMap = .empty;
    defer body.deinit(ctx.allocator);

    // attendees array
    var attendees_arr = std.json.Array.initCapacity(ctx.allocator, required.?.len) catch return;
    for (required.?) |att| {
        var email_obj: ObjectMap = .empty;
        email_obj.put(ctx.allocator, "address", .{ .string = att.emailAddress.address }) catch return;
        var att_obj: ObjectMap = .empty;
        att_obj.put(ctx.allocator, "emailAddress", .{ .object = email_obj }) catch return;
        att_obj.put(ctx.allocator, "type", .{ .string = "required" }) catch return;
        attendees_arr.appendAssumeCapacity(.{ .object = att_obj });
    }
    body.put(ctx.allocator, "attendees", .{ .array = attendees_arr }) catch return;

    // timeConstraint = { timeslots: [{start, end}] }, each a {dateTime, timeZone}.
    var start_obj: ObjectMap = .empty;
    start_obj.put(ctx.allocator, "dateTime", .{ .string = start }) catch return;
    start_obj.put(ctx.allocator, "timeZone", .{ .string = ctx.state.timezone }) catch return;
    var end_obj: ObjectMap = .empty;
    end_obj.put(ctx.allocator, "dateTime", .{ .string = end }) catch return;
    end_obj.put(ctx.allocator, "timeZone", .{ .string = ctx.state.timezone }) catch return;
    var slot_obj: ObjectMap = .empty;
    slot_obj.put(ctx.allocator, "start", .{ .object = start_obj }) catch return;
    slot_obj.put(ctx.allocator, "end", .{ .object = end_obj }) catch return;
    var slots_arr = std.json.Array.initCapacity(ctx.allocator, 1) catch return;
    slots_arr.appendAssumeCapacity(.{ .object = slot_obj });
    var tc_obj: ObjectMap = .empty;
    tc_obj.put(ctx.allocator, "timeslots", .{ .array = slots_arr }) catch return;
    body.put(ctx.allocator, "timeConstraint", .{ .object = tc_obj }) catch return;

    // meetingDuration: "PT<N>M" ISO 8601 duration.
    const duration_iso = std.fmt.allocPrint(ctx.allocator, "PT{d}M", .{duration_min}) catch return;
    defer ctx.allocator.free(duration_iso);
    body.put(ctx.allocator, "meetingDuration", .{ .string = duration_iso }) catch return;

    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(Value{ .object = body }, .{}, &json_buf.writer) catch return;

    const response = graph.post(ctx.allocator, ctx.io, token, "/me/findMeetingTimes", json_buf.written()) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    // Response shape: { "meetingTimeSuggestions": [...], ... }. Parse, find
    // the array, format each suggestion by hand — the formatter's dotted-path
    // walker handles nested fields but expects a top-level "value" array,
    // which this endpoint doesn't give us.
    const parsed = std.json.parseFromSlice(Value, ctx.allocator, response, .{}) catch {
        ctx.sendResult(response);
        return;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) { .object => |o| o, else => {
        ctx.sendResult("Unexpected response shape from findMeetingTimes.");
        return;
    } };
    const suggestions = switch (root.get("meetingTimeSuggestions") orelse .null) {
        .array => |a| a.items,
        else => {
            ctx.sendResult("No meeting time suggestions returned.");
            return;
        },
    };
    if (suggestions.len == 0) {
        ctx.sendResult("No meeting time suggestions found for that window.");
        return;
    }

    // Build output one line per suggestion. Same shape as formatter output
    // but hand-rolled because the parent-array shape doesn't fit formatter.
    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer buf.deinit();
    const w = &buf.writer;
    for (suggestions) |item| {
        const obj = switch (item) { .object => |o| o, else => continue };
        // confidence is a number; print whatever Zig's default formatting
        // gives us for the Value (null/int/float all handled by formatValue).
        if (obj.get("confidence")) |c| {
            w.writeAll("confidence: ") catch continue;
            std.json.Stringify.value(c, .{}, w) catch continue;
            w.writeAll(" | ") catch continue;
        }
        const start_dt = dottedString(obj, &.{ "meetingTimeSlot", "start", "dateTime" });
        const end_dt = dottedString(obj, &.{ "meetingTimeSlot", "end", "dateTime" });
        // Pre-compute weekday (Mon/Tue/...) so the agent doesn't have to.
        // LLMs are unreliable on day-of-week math more than a few days
        // out — without this label, find-meeting-times → narration was
        // saying "Sunday" for Monday slots.
        const start_wd = date_util.weekdayFromIso(start_dt);
        const end_wd = date_util.weekdayFromIso(end_dt);
        w.writeAll("start: ") catch continue;
        w.writeAll(start_dt) catch continue;
        if (start_wd) |wd| w.print(" ({s})", .{wd}) catch continue;
        w.writeAll(" | end: ") catch continue;
        w.writeAll(end_dt) catch continue;
        if (end_wd) |wd| w.print(" ({s})", .{wd}) catch continue;
        w.writeAll("\n") catch continue;
    }
    const out = buf.toOwnedSlice() catch return;
    defer ctx.allocator.free(out);
    ctx.sendResult(out);
}

/// Look up free/busy windows for one or more schedules (people or rooms).
/// Graph: POST /me/calendar/getSchedule
///   body: { "schedules": ["email1", "email2"], "startTime": {...}, "endTime": {...}, "availabilityViewInterval": 60 }
///
/// Response has `.value[]` with `scheduleId` + `availabilityView` (one
/// character per interval: 0 free, 1 tentative, 2 busy, 3 oof, 4 workingElsewhere).
pub fn handleGetSchedule(ctx: ToolContext) void {
    const token = authAndTimezone(ctx) orelse return;
    const args = ctx.getArgs("Missing arguments. Provide schedules (array of emails), start, end.") orelse return;

    const start = ctx.getStringArg(args, "start", "Missing 'start' (ISO 8601 local time).") orelse return;
    const end = ctx.getStringArg(args, "end", "Missing 'end' (ISO 8601 local time).") orelse return;

    // `schedules` is an array of strings; extract without going through
    // parseAttendees since the shape is flatter.
    const schedules_val = args.get("schedules") orelse {
        ctx.sendResult("Missing 'schedules' (array of email addresses).");
        return;
    };
    const schedules_items = switch (schedules_val) {
        .array => |a| a.items,
        else => {
            ctx.sendResult("'schedules' must be an array of email addresses.");
            return;
        },
    };
    if (schedules_items.len == 0) {
        ctx.sendResult("'schedules' must contain at least one email address.");
        return;
    }

    // interval = minutes-per-cell in availabilityView (default 60).
    const interval_min: i64 = if (args.get("availabilityViewInterval")) |v| switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 60,
    } else 60;

    var body: ObjectMap = .empty;
    defer body.deinit(ctx.allocator);

    // schedules array
    var scheds_arr = std.json.Array.initCapacity(ctx.allocator, schedules_items.len) catch return;
    for (schedules_items) |item| {
        switch (item) {
            .string => |s| scheds_arr.appendAssumeCapacity(.{ .string = s }),
            else => {}, // silently drop non-strings
        }
    }
    body.put(ctx.allocator, "schedules", .{ .array = scheds_arr }) catch return;

    var start_obj: ObjectMap = .empty;
    start_obj.put(ctx.allocator, "dateTime", .{ .string = start }) catch return;
    start_obj.put(ctx.allocator, "timeZone", .{ .string = ctx.state.timezone }) catch return;
    body.put(ctx.allocator, "startTime", .{ .object = start_obj }) catch return;

    var end_obj: ObjectMap = .empty;
    end_obj.put(ctx.allocator, "dateTime", .{ .string = end }) catch return;
    end_obj.put(ctx.allocator, "timeZone", .{ .string = ctx.state.timezone }) catch return;
    body.put(ctx.allocator, "endTime", .{ .object = end_obj }) catch return;

    body.put(ctx.allocator, "availabilityViewInterval", .{ .integer = interval_min }) catch return;

    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(Value{ .object = body }, .{}, &json_buf.writer) catch return;

    const response = graph.post(ctx.allocator, ctx.io, token, "/me/calendar/getSchedule", json_buf.written()) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    if (formatter.summarizeArray(ctx.allocator, response, &get_schedule_slot_fields)) |summary| {
        defer ctx.allocator.free(summary);
        ctx.sendResult(summary);
    } else {
        ctx.sendResult("No schedule data returned.");
    }
}

/// Accept / decline / tentatively accept an event invitation.
/// Graph: POST /me/events/{id}/{accept|decline|tentativelyAccept}
///   body: { "comment": "...", "sendResponse": bool }
pub fn handleRespondToEvent(ctx: ToolContext) void {
    const token = authAndTimezone(ctx) orelse return;
    const args = ctx.getArgs("Missing arguments. Provide eventId and action.") orelse return;
    const event_id = ctx.getPathArg(args, "eventId", "Missing 'eventId' argument.") orelse return;
    const action = ctx.getStringArg(args, "action", "Missing 'action' (accept, decline, or tentativelyAccept).") orelse return;

    // Whitelist action — prevents URL injection via a malicious action string.
    if (!std.mem.eql(u8, action, "accept") and
        !std.mem.eql(u8, action, "decline") and
        !std.mem.eql(u8, action, "tentativelyAccept"))
    {
        ctx.sendResult("Invalid 'action' — must be one of: accept, decline, tentativelyAccept.");
        return;
    }

    const comment = json_rpc.getStringArg(args, "comment") orelse "";
    const send_response: bool = if (args.get("sendResponse")) |v| switch (v) {
        .bool => |b| b,
        else => true,
    } else true;

    // Build body with std.json.Stringify — never raw-format the comment.
    var body: ObjectMap = .empty;
    defer body.deinit(ctx.allocator);
    body.put(ctx.allocator, "comment", .{ .string = comment }) catch return;
    body.put(ctx.allocator, "sendResponse", .{ .bool = send_response }) catch return;

    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(Value{ .object = body }, .{}, &json_buf.writer) catch return;

    const path = std.fmt.allocPrint(ctx.allocator, "/me/events/{s}/{s}", .{ event_id, action }) catch return;
    defer ctx.allocator.free(path);

    _ = graph.post(ctx.allocator, ctx.io, token, path, json_buf.written()) catch |err| {
        ctx.sendGraphError(err);
        return;
    };

    ctx.sendResult("Response sent.");
}
