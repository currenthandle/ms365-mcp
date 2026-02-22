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

    // Get a buffered reader for stdin.
    // In Zig 0.16, readers need an Io context (handles blocking/async I/O)
    // and a stack-allocated buffer for internal buffering.
    var read_buf: [4096]u8 = undefined;
    const io = std.Options.debug_io; // the default blocking I/O context
    // `var` because reading mutates the reader's internal buffer position.
    var stdin = std.Io.File.stdin().reader(io, &read_buf);

    // Read one line from stdin (up to the '\n' delimiter, which is excluded).
    // Returns a slice into the reader's internal buffer — no allocation needed.
    // Returns error.EndOfStream if stdin is closed before a newline arrives.
    // File.Reader wraps an Io.Reader — access it via .interface field.
    // Io.Reader has the high-level methods like takeDelimiterExclusive.
    const line = stdin.interface.takeDelimiterExclusive('\n') catch |err| {
        std.debug.print("ms-mcp: read error: {}\n", .{err});
        return;
    };

    std.debug.print("ms-mcp: got {d} bytes: {s}\n", .{ line.len, line });
}
