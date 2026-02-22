const std = @import("std");

pub fn main() !void {
    // Zig has no garbage collector. Every allocation goes through an Allocator.
    // GeneralPurposeAllocator (GPA) is the standard choice — in debug mode
    // it detects memory leaks and double-frees for us.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit(); // runs when main() exits — checks for leaks

    // std.debug.print writes to stderr — safe because MCP only uses stdin/stdout.
    // It takes a comptime format string and an args tuple. .{} = empty args.
    std.debug.print("ms-mcp: server starting\n", .{});
}
