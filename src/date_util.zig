// date_util.zig — Date helpers used to enrich Graph timestamps with
// human-readable weekday labels.
//
// Why this exists: Graph returns ISO 8601 timestamps like
//   "2026-04-27T15:00:00"
// and LLMs are unreliable at computing the day-of-week from a raw date,
// especially more than a few days out. find-meeting-times → narration
// would say "Sunday" when the date was actually a Monday. We compute
// the weekday programmatically (Zeller's congruence) and append it
// in the formatter so the model never has to do calendar math.

const std = @import("std");

/// Three-letter weekday abbreviations, indexed 0-6 with Monday=0.
/// (Matches Python's datetime.weekday() and ISO-style intuition;
/// internal index choice doesn't matter, we just need to round-trip.)
const weekday_abbrev = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };

/// Compute the weekday for a Gregorian date using Zeller's congruence.
/// Returns 0=Mon, 1=Tue, ..., 6=Sun. Inputs:
///   year  — full 4-digit year, e.g. 2026
///   month — 1-12
///   day   — 1-31
///
/// Unchecked: the caller is expected to pass a valid Gregorian date.
/// We don't validate because the only callers parse from ISO strings
/// that Graph itself produced — Graph won't hand us "Feb 30".
pub fn weekdayIndex(year: i32, month: u8, day: u8) u3 {
    // Zeller's congruence for the Gregorian calendar.
    // Treat Jan/Feb as months 13/14 of the previous year.
    var y: i32 = year;
    var m: i32 = month;
    if (m < 3) {
        m += 12;
        y -= 1;
    }
    const k: i32 = @mod(y, 100);
    const j: i32 = @divFloor(y, 100);
    // h: 0=Sat, 1=Sun, 2=Mon, ..., 6=Fri.
    const h: i32 = @mod(@as(i32, day) + @divFloor(13 * (m + 1), 5) + k + @divFloor(k, 4) + @divFloor(j, 4) + 5 * j, 7);
    // Convert h's Saturday-anchored index to Monday-anchored 0-6.
    // h: 0(Sat) 1(Sun) 2(Mon) 3(Tue) 4(Wed) 5(Thu) 6(Fri)
    // we want:   5    6    0    1    2    3    4
    const monday_anchored = @mod(h + 5, 7);
    return @intCast(monday_anchored);
}

/// Return "Mon"/"Tue"/.../"Sun" for the given date.
pub fn weekdayAbbrev(year: i32, month: u8, day: u8) []const u8 {
    return weekday_abbrev[weekdayIndex(year, month, day)];
}

/// Try to parse the date prefix (YYYY-MM-DD) of an ISO 8601 timestamp
/// and return its weekday abbreviation, or null if the string doesn't
/// start with what looks like an ISO date. Robust against any suffix —
/// "2026-04-27", "2026-04-27T15:00:00", "2026-04-27T15:00:00Z",
/// "2026-04-27T15:00:00+00:00", "2026-04-27T15:00:00.0000000" all work.
pub fn weekdayFromIso(s: []const u8) ?[]const u8 {
    // Need at least YYYY-MM-DD = 10 chars.
    if (s.len < 10) return null;
    // Quick shape check: digits at 0-3, '-' at 4, digits at 5-6, '-' at 7, digits at 8-9.
    if (s[4] != '-' or s[7] != '-') return null;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9 }) |i| {
        if (!std.ascii.isDigit(s[i])) return null;
    }

    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    return weekdayAbbrev(year, month, day);
}

// --- Tests --------------------------------------------------------

test "weekdayAbbrev: known dates" {
    const T = std.testing;
    // April 27, 2026 = Monday (the date that motivated this whole helper).
    try T.expectEqualStrings("Mon", weekdayAbbrev(2026, 4, 27));
    // April 26, 2026 = Sunday.
    try T.expectEqualStrings("Sun", weekdayAbbrev(2026, 4, 26));
    // 1900-01-01 = Monday (per Wikipedia, sanity check at a leap-century).
    try T.expectEqualStrings("Mon", weekdayAbbrev(1900, 1, 1));
    // 2000-02-29 = Tuesday (leap year sanity).
    try T.expectEqualStrings("Tue", weekdayAbbrev(2000, 2, 29));
    // 2024-12-25 = Wednesday (recent everyday date).
    try T.expectEqualStrings("Wed", weekdayAbbrev(2024, 12, 25));
}

test "weekdayFromIso: typical Graph timestamps" {
    const T = std.testing;
    try T.expectEqualStrings("Mon", weekdayFromIso("2026-04-27").?);
    try T.expectEqualStrings("Mon", weekdayFromIso("2026-04-27T15:00:00").?);
    try T.expectEqualStrings("Mon", weekdayFromIso("2026-04-27T15:00:00Z").?);
    try T.expectEqualStrings("Mon", weekdayFromIso("2026-04-27T15:00:00.0000000").?);
    try T.expectEqualStrings("Mon", weekdayFromIso("2026-04-27T15:00:00+00:00").?);
}

test "weekdayFromIso: invalid input returns null" {
    const T = std.testing;
    try T.expect(weekdayFromIso("") == null);
    try T.expect(weekdayFromIso("not a date") == null);
    try T.expect(weekdayFromIso("20260427") == null); // missing dashes
    try T.expect(weekdayFromIso("2026/04/27") == null); // wrong separator
    try T.expect(weekdayFromIso("2026-13-01") == null); // bad month
    try T.expect(weekdayFromIso("2026-04-32") == null); // bad day
}
