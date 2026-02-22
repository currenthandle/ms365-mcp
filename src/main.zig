const std = @import("std");

pub fn main() !void {
    // Zig has no garbage collector. Every allocation goes through an Allocator.
    // GeneralPurposeAllocator (GPA) is the standard choice — in debug mode
    // it detects memory leaks and double-frees for us.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator(); // we'll need this for JSON parsing

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

    // Main message loop: read lines until stdin closes.
    // Each line is one JSON-RPC message from the MCP client.
    while (true) {
        // takeDelimiter advances past the '\n'. Returns null at end of stream.
        const line = stdin.interface.takeDelimiter('\n') catch |err| {
            std.debug.print("ms-mcp: read error: {}\n", .{err});
            return;
        } orelse {
            // null = end of stream = stdin closed. Normal shutdown.
            std.debug.print("ms-mcp: stdin closed, shutting down\n", .{});
            return;
        };

        // Skip empty lines (some clients send trailing newlines).
        if (line.len == 0) continue;

        // Parse the line as dynamic JSON. Value can hold any JSON structure.
        // parseFromSlice returns a Parsed wrapper; .deinit() frees all memory.
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

        // JSON-RPC messages have a "method" field (e.g. "initialize", "tools/list").
        const method = switch (parsed.value) {
            .object => |obj| if (obj.get("method")) |v| switch (v) {
                .string => |s| s,
                else => "(non-string method)",
            } else "(no method)",
            else => "(not an object)",
        };
        std.debug.print("ms-mcp: method={s}\n", .{method});
    }
}
