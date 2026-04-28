// e2e/client.zig — MCP client that spawns the server as a child process
// and exchanges JSON-RPC messages over stdin/stdout pipes.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Default per-call timeout. If the server doesn't produce a response line
/// within this many milliseconds the call fails with error.ServerHung, we
/// kill the child, and the test exits with a clear diagnostic. Prior to
/// this timeout, a hung server would wedge the whole e2e run indefinitely.
///
/// 30 seconds is generous — most calls finish in <1s — but Graph's
/// /search endpoints, SharePoint site search, and tools that walk many
/// Graph round-trips (search-channels across 10+ teams) legitimately
/// take 5-15 seconds on slow days. A tighter cap surfaces those as
/// hangs and produces noisy false negatives. Genuine deadlocks still
/// trip the timeout — they just take 30s to declare instead of 10s.
pub const default_timeout_ms: i32 = 30_000;

pub const CallError = error{
    ServerHung,
    ServerClosed,
    WriteFailed,
    ReadFailed,
    OutOfMemory,
    UnexpectedPoll,
    Overflow,
};

/// An MCP client that talks to the server over stdin/stdout pipes.
pub const McpClient = struct {
    child: std.process.Child,
    // File-level reader/writer — their `.interface` field gives us the
    // std.Io.Reader / std.Io.Writer that the JSON-RPC protocol uses.
    file_reader: std.Io.File.Reader,
    file_writer: std.Io.File.Writer,
    allocator: Allocator,
    /// The Io context the client was initialized with — tests may need it
    /// (e.g. to read files verifying a binary-safe download worked).
    io: Io,
    next_id: i64 = 1,
    /// Per-call timeout. Individual calls can override via callWithTimeout.
    timeout_ms: i32 = default_timeout_ms,
    /// Set once the server has become unresponsive — subsequent calls short
    /// circuit with ServerHung instead of hanging the whole run.
    dead: bool = false,

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
            .io = io,
        };

        // Create buffered reader/writer from the child's pipes.
        client.file_reader = client.child.stdout.?.reader(io, &client.read_buf);
        client.file_writer = client.child.stdin.?.writer(io, &client.write_buf);

        return client;
    }

    /// Send a JSON-RPC message and return the parsed response.
    /// Caller owns the returned Parsed value and must call .deinit().
    ///
    /// Times out after `self.timeout_ms`. On timeout, sets `self.dead = true`
    /// and returns error.ServerHung; the caller should stop issuing further
    /// calls and the outer runner should kill the child. This is what makes
    /// server-side panics/hangs surface as test failures instead of wedging
    /// the whole e2e run.
    pub fn call(self: *McpClient, method: []const u8, params_json: ?[]const u8) !std.json.Parsed(std.json.Value) {
        if (self.dead) return error.ServerHung;

        const id = self.next_id;
        self.next_id += 1;
        const writer = &self.file_writer.interface;

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

        try self.waitReadable();

        const reader = &self.file_reader.interface;
        const line = (reader.takeDelimiter('\n') catch return error.ReadFailed) orelse return error.ServerClosed;

        return std.json.parseFromSlice(std.json.Value, self.allocator, line, .{});
    }

    /// Block until the server's stdout has a byte ready or the timeout
    /// fires. Uses std.posix.poll on the child's stdout fd. On timeout
    /// marks the client dead so follow-up calls fail fast instead of
    /// each hanging for another full timeout.
    fn waitReadable(self: *McpClient) !void {
        const fd = self.child.stdout.?.handle;
        var fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const n = std.posix.poll(&fds, self.timeout_ms) catch return error.UnexpectedPoll;
        if (n == 0) {
            self.dead = true;
            return error.ServerHung;
        }
    }

    /// True if the server has responded to our most recent calls.
    /// Liveness check — send a no-op tools/list and verify a response
    /// comes back within the timeout. If it doesn't, the server has
    /// hung or crashed since the last test and the outer runner should
    /// abort rather than run remaining tests against a dead process.
    pub fn isAlive(self: *McpClient) bool {
        if (self.dead) return false;
        const parsed = self.call("tools/list", null) catch return false;
        parsed.deinit();
        return true;
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
