const std = @import("std");

// Type aliases — keeps function signatures cleaner.
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("ms-mcp: server starting\n", .{});

    var read_buf: [4096]u8 = undefined;
    const io = std.Options.debug_io;
    var stdin = std.Io.File.stdin().reader(io, &read_buf);

    // Stdout writer — where we send JSON-RPC responses back to the client.
    var write_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &write_buf);

    runMessageLoop(allocator, &stdin.interface, &stdout.interface);
}

/// Extract the integer "id" field from a JSON-RPC message object.
/// JSON-RPC clients assign an id to each request so they can match our response.
/// Returns 0 if missing or not an integer.
fn getRequestId(value: std.json.Value) i64 {
    // We can only look up "id" if the value is a JSON object.
    const obj = switch (value) {
        .object => |o| o,
        else => return 0,
    };

    const id = obj.get("id") orelse return 0;

    return switch (id) {
        .integer => |n| n,
        else => 0,
    };
}

/// Write a complete JSON-RPC response line to the writer and flush.
/// `comptime fmt` means the format string must be known at compile time —
/// this lets Zig validate the format specifiers against the args tuple.
fn sendResponse(writer: *Writer, comptime fmt: []const u8, args: anytype) void {
    writer.print(fmt, args) catch return;
    writer.writeAll("\n") catch return; // MCP messages are newline-delimited
    writer.flush() catch return; // flush so the client sees it immediately
}

/// Reads JSON-RPC messages from the reader one line at a time,
/// parses them, and dispatches by method name.
fn runMessageLoop(allocator: Allocator, reader: *Reader, writer: *Writer) void {
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

        // Extract the method string from the JSON-RPC message.
        const method = switch (parsed.value) {
            .object => |obj| if (obj.get("method")) |v| switch (v) {
                .string => |s| s,
                else => null,
            } else null,
            else => null,
        };

        if (method) |m| {
            std.debug.print("ms-mcp: method={s}\n", .{m});

            if (std.mem.eql(u8, m, "initialize")) {
                sendResponse(writer,
                    \\{{"jsonrpc":"2.0","id":{d},"result":{{"protocolVersion":"2024-11-05","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"ms-mcp","version":"0.1.0"}}}}}}
                , .{getRequestId(parsed.value)});
            }
        }
    }
}
