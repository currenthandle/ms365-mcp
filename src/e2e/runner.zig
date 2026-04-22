// e2e/runner.zig — Test counters shared by every test case.
//
// Each `fn test<Name>(...)` in cases.zig calls `pass()` or `fail()` to
// report its outcome. Main reads `tests_passed` / `tests_failed` at the end
// to print the summary and set the exit code.

const std = @import("std");

pub var tests_passed: u32 = 0;
pub var tests_failed: u32 = 0;

pub fn pass(name: []const u8) void {
    tests_passed += 1;
    std.debug.print("  \x1b[32m✓\x1b[0m {s}\n", .{name});
}

pub fn fail(name: []const u8, reason: []const u8) void {
    tests_failed += 1;
    std.debug.print("  \x1b[31m✗\x1b[0m {s}: {s}\n", .{ name, reason });
}
