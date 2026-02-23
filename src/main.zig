const std = @import("std");
const types = @import("types.zig");
const http = @import("http.zig");
const auth = @import("auth.zig");

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

/// Extract the tool name from a "tools/call" request.
/// In JSON-RPC, tool calls look like: {"params": {"name": "login", ...}}
/// Returns null if missing or malformed.
fn getToolName(value: std.json.Value) ?[]const u8 {
    // Same pattern as getRequestId — unwrap one layer at a time.
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    // "params" contains the tool call details.
    const params = switch (obj.get("params") orelse return null) {
        .object => |o| o,
        else => return null,
    };

    // "name" is which tool the client wants to invoke.
    return switch (params.get("name") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Serialize any Zig struct as JSON, write it to the writer, then flush.
/// Uses std.json.Stringify to automatically convert structs to JSON —
/// no manual format strings needed.
fn sendJsonResponse(writer: *Writer, response: anytype) void {
    std.json.Stringify.value(response, .{}, writer) catch return;
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
                // Respond with server info and capabilities.
                // All fields use defaults from the struct definitions in types.zig.
                sendJsonResponse(writer, types.JsonRpcResponse(types.InitializeResult){
                    .id = getRequestId(parsed.value),
                    .result = .{},
                });
            } else if (std.mem.eql(u8, m, "tools/call")) {
                if (getToolName(parsed.value)) |name| {
                    std.debug.print("ms-mcp: tool call: {s}\n", .{name});

                    if (std.mem.eql(u8, name, "login")) {
                        // Placeholder — will implement OAuth device code flow
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = .{ .content = &.{
                                .{ .text = "login not yet implemented" },
                            } },
                        });
                    }
                }
            } else if (std.mem.eql(u8, m, "tools/list")) {
                // Respond with the list of tools this server offers. Empty for now.
                sendJsonResponse(writer, types.JsonRpcResponse(types.ToolsListResult){
                    .id = getRequestId(parsed.value),
                    .result = .{ .tools = &.{
                    .{
                        .name = "login",
                        .description = "Start Microsoft 365 login flow. Returns a device code to enter at the verification URL.",
                        .inputSchema = .{},
                    },
                } },
                });
            }
        }
    }
}
