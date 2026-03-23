// timezone.zig — Timezone conversion between IANA, Microsoft, and UTC.

const std = @import("std");

/// A single entry in the timezone lookup table.
/// Maps an IANA name to its Microsoft equivalent and UTC offset.
pub const TimezoneEntry = struct {
    iana: []const u8,
    microsoft: []const u8,
    utc_offset: i8, // hours from UTC (standard time)
};

/// Map IANA timezone names to Microsoft timezone names + UTC offsets.
/// Microsoft Graph API uses its own names (e.g. "Eastern Standard Time").
/// macOS reports IANA format (e.g. "America/New_York").
/// `utc_offset` is the standard time offset in hours (negative = west of UTC).
/// NOTE: Does not account for daylight saving — worst case, one hour off.
pub const timezone_table = [_]TimezoneEntry{
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
pub fn ianaToWindows(iana: []const u8) ?[]const u8 {
    for (&timezone_table) |entry| {
        if (std.mem.eql(u8, entry.iana, iana)) return entry.microsoft;
    }
    return null;
}

/// Look up the UTC offset (in hours) for a Microsoft timezone name.
/// Returns null if the timezone isn't in our table.
pub fn getUtcOffset(ms_tz: []const u8) ?i8 {
    for (&timezone_table) |entry| {
        if (std.mem.eql(u8, entry.microsoft, ms_tz)) return entry.utc_offset;
    }
    return null;
}

/// Read the system timezone from macOS /etc/localtime symlink.
/// Returns the IANA timezone name (e.g. "America/New_York").
/// The returned slice points into the `buf` parameter — no allocation needed.
pub fn getSystemTimezone(buf: []u8) ?[]const u8 {
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

/// Convert a local time string to UTC by subtracting the UTC offset.
/// `utc_offset` is negative for west of UTC (e.g. -5 for EST, -8 for PST).
///
/// Input:  "2026-02-24T09:00:00", offset=-5 → "2026-02-24T14:00:00Z"
/// Input:  "2026-02-24T21:00:00", offset=-5 → "2026-02-25T02:00:00Z"
///
/// Handles day/month/year rollover in both directions.
/// NOTE: Uses standard time offsets only — does not account for DST.
pub fn localToUtc(allocator: std.mem.Allocator, local: []const u8, utc_offset: i8) ![]u8 {
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

// --- Tests ---

const testing = std.testing;

test "ianaToWindows known timezone" {
    try testing.expectEqualStrings("Eastern Standard Time", ianaToWindows("America/New_York").?);
}

test "ianaToWindows UTC" {
    try testing.expectEqualStrings("UTC", ianaToWindows("UTC").?);
}

test "ianaToWindows unknown returns null" {
    try testing.expect(ianaToWindows("Mars/Olympus") == null);
}

test "getUtcOffset Eastern" {
    try testing.expectEqual(@as(i8, -5), getUtcOffset("Eastern Standard Time").?);
}

test "getUtcOffset Tokyo" {
    try testing.expectEqual(@as(i8, 9), getUtcOffset("Tokyo Standard Time").?);
}

test "getUtcOffset unknown returns null" {
    try testing.expect(getUtcOffset("Fake Time") == null);
}

test "localToUtc basic conversion" {
    const result = try localToUtc(testing.allocator, "2026-02-24T09:00:00", -5);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("2026-02-24T14:00:00Z", result);
}

test "localToUtc forward day rollover" {
    const result = try localToUtc(testing.allocator, "2026-02-24T21:00:00", -5);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("2026-02-25T02:00:00Z", result);
}

test "localToUtc backward day rollover" {
    const result = try localToUtc(testing.allocator, "2026-02-24T02:00:00", 9);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("2026-02-23T17:00:00Z", result);
}

test "localToUtc month rollover" {
    const result = try localToUtc(testing.allocator, "2026-01-31T22:00:00", -5);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("2026-02-01T03:00:00Z", result);
}

test "localToUtc year rollover" {
    const result = try localToUtc(testing.allocator, "2026-12-31T22:00:00", -5);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("2027-01-01T03:00:00Z", result);
}

test "localToUtc already UTC passthrough" {
    const result = try localToUtc(testing.allocator, "2026-02-24T14:00:00Z", -5);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("2026-02-24T14:00:00Z", result);
}

test "localToUtc leap year Feb 28 rollover" {
    const result = try localToUtc(testing.allocator, "2028-02-28T22:00:00", -5);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("2028-02-29T03:00:00Z", result);
}

test "localToUtc invalid format" {
    const result = localToUtc(testing.allocator, "bad", 0);
    try testing.expectError(error.InvalidFormat, result);
}
