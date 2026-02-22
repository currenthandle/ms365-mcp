const std = @import("std");

// Type aliases — keeps function signatures cleaner.
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("ms-mcp: server starting\n", .{});

    var read_buf: [4096]u8 = undefined;
    const io = std.Options.debug_io;
    var stdin = std.Io.File.stdin().reader(io, &read_buf);

    runMessageLoop(allocator, &stdin.interface);
}

/// Reads JSON-RPC messages from the reader one line at a time,
/// parses them, and dispatches by method name.
fn runMessageLoop(allocator: Allocator, reader: *Reader) void {
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
