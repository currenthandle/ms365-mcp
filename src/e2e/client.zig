// e2e/client.zig — MCP client that spawns the server as a child process
// and exchanges JSON-RPC messages over stdin/stdout pipes.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// An MCP client that talks to the server over stdin/stdout pipes.
pub const McpClient = struct {
    child: std.process.Child,
    // File-level reader/writer — their `.interface` field gives us the
    // std.Io.Reader / std.Io.Writer that the JSON-RPC protocol uses.
    file_reader: std.Io.File.Reader,
    file_writer: std.Io.File.Writer,
    allocator: Allocator,
    next_id: i64 = 1,

    // Buffers must live as long as the client — stored here.
    read_buf: [65536]u8 = undefined,
    write_buf: [65536]u8 = undefined,

    /// Spawn the MCP server and set up pipes.
    pub fn init(allocator: Allocator, io: Io, exe_path: []const u8, environ_map: ?*const std.process.Environ.Map) !McpClient {
        var client: McpClient = .{
            .child = try std.process.spawn(io, .{
                .argv = &.{exe_path},
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit, // Let server stderr pass through for debug logging.
                .environ_map = environ_map,
            }),
            .file_reader = undefined,
            .file_writer = undefined,
            .allocator = allocator,
        };

        // Create buffered reader/writer from the child's pipes.
        client.file_reader = client.child.stdout.?.reader(io, &client.read_buf);
        client.file_writer = client.child.stdin.?.writer(io, &client.write_buf);

        return client;
    }

    /// Send a JSON-RPC message and return the parsed response.
    /// Caller owns the returned Parsed value and must call .deinit().
    pub fn call(self: *McpClient, method: []const u8, params_json: ?[]const u8) !std.json.Parsed(std.json.Value) {
        const id = self.next_id;
        self.next_id += 1;
        const writer = &self.file_writer.interface;
        const reader = &self.file_reader.interface;

        // Build the request JSON manually — simpler than struct serialization
        // for dynamic params.
        if (params_json) |p| {
            const req = try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, p });
            defer self.allocator.free(req);
            writer.writeAll(req) catch return error.WriteFailed;
        } else {
            const req = try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\"}}", .{ id, method });
            defer self.allocator.free(req);
            writer.writeAll(req) catch return error.WriteFailed;
        }
        writer.writeAll("\n") catch return error.WriteFailed;
        writer.flush() catch return error.WriteFailed;

        // Read the response line.
        const line = (reader.takeDelimiter('\n') catch return error.ReadFailed) orelse return error.ServerClosed;

        return std.json.parseFromSlice(std.json.Value, self.allocator, line, .{});
    }

    /// Call a tool and return the text content from the response.
    /// Caller owns the returned Parsed value.
    ///
    /// The params JSON is heap-allocated so we can handle arguments larger
    /// than any fixed stack buffer (e.g. multi-megabyte upload payloads).
    pub fn callTool(self: *McpClient, name: []const u8, args_json: ?[]const u8) !std.json.Parsed(std.json.Value) {
        const params = if (args_json) |a|
            try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\",\"arguments\":{s}}}", .{ name, a })
        else
            try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\"}}", .{name});
        defer self.allocator.free(params);

        return self.call("tools/call", params);
    }

    /// Extract the text content string from a tool call response.
    pub fn getResultText(parsed: std.json.Parsed(std.json.Value)) ?[]const u8 {
        const result = parsed.value.object.get("result") orelse return null;
        const content = switch (result) {
            .object => |o| o.get("content") orelse return null,
            else => return null,
        };
        const arr = switch (content) {
            .array => |a| a,
            else => return null,
        };
        if (arr.items.len == 0) return null;
        const first = switch (arr.items[0]) {
            .object => |o| o,
            else => return null,
        };
        const text = first.get("text") orelse return null;
        return switch (text) {
            .string => |s| s,
            else => null,
        };
    }

    /// Kill the server and clean up.
    pub fn deinit(self: *McpClient, io: Io) void {
        self.child.kill(io);
    }
};
