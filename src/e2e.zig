// e2e.zig — End-to-end test client for ms-mcp.
//
// Spawns the MCP server as a child process, communicates over stdin/stdout
// using the JSON-RPC protocol, and runs real tests against the live
// Microsoft Graph API.
//
// Usage: zig build e2e
// Requires: MS365_CLIENT_ID and MS365_TENANT_ID environment variables.
// If not already authenticated, prompts the user to complete device code auth.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

// --- MCP Client ---

/// An MCP client that talks to the server over stdin/stdout pipes.
const McpClient = struct {
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
    fn init(allocator: Allocator, io: Io, exe_path: []const u8, environ_map: ?*const std.process.Environ.Map) !McpClient {
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
    fn call(self: *McpClient, method: []const u8, params_json: ?[]const u8) !std.json.Parsed(std.json.Value) {
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
    fn callTool(self: *McpClient, name: []const u8, args_json: ?[]const u8) !std.json.Parsed(std.json.Value) {
        var params_buf: [4096]u8 = undefined;
        const params = if (args_json) |a|
            try std.fmt.bufPrint(&params_buf, "{{\"name\":\"{s}\",\"arguments\":{s}}}", .{ name, a })
        else
            try std.fmt.bufPrint(&params_buf, "{{\"name\":\"{s}\"}}", .{name});

        return self.call("tools/call", params);
    }

    /// Extract the text content string from a tool call response.
    fn getResultText(parsed: std.json.Parsed(std.json.Value)) ?[]const u8 {
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
    fn deinit(self: *McpClient, io: Io) void {
        self.child.kill(io);
    }
};

// --- Test Runner ---

var tests_passed: u32 = 0;
var tests_failed: u32 = 0;

fn pass(name: []const u8) void {
    tests_passed += 1;
    std.debug.print("  \x1b[32m✓\x1b[0m {s}\n", .{name});
}

fn fail(name: []const u8, reason: []const u8) void {
    tests_failed += 1;
    std.debug.print("  \x1b[31m✗\x1b[0m {s}: {s}\n", .{ name, reason });
}

// --- Tests ---

/// Test: MCP initialize handshake.
fn testInitialize(client: *McpClient) !void {
    const parsed = try client.call("initialize", "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"e2e-test\",\"version\":\"0.1\"}}");
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse {
        fail("initialize", "no result in response");
        return;
    };
    const obj = switch (result) {
        .object => |o| o,
        else => {
            fail("initialize", "result is not an object");
            return;
        },
    };
    const proto = switch (obj.get("protocolVersion") orelse {
        fail("initialize", "no protocolVersion");
        return;
    }) {
        .string => |s| s,
        else => {
            fail("initialize", "protocolVersion not a string");
            return;
        },
    };
    if (std.mem.eql(u8, proto, "2024-11-05")) {
        pass("initialize");
    } else {
        fail("initialize", "wrong protocolVersion");
    }
}

/// Test: Check if we're already authenticated by calling get-profile.
/// If it returns a displayName, we have a valid token from a saved session.
/// Returns true if authenticated.
fn testCheckAuth(client: *McpClient) !bool {
    const parsed = try client.callTool("get-profile", null);
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        return false;
    };

    if (std.mem.indexOf(u8, text, "\"displayName\"") != null) {
        pass("auth (saved token valid)");
        return true;
    }
    std.debug.print("  ⓘ No valid saved token — will attempt login\n", .{});
    return false;
}

/// Test: Login via device code flow (interactive — requires user action).
fn testLogin(client: *McpClient) !bool {
    const parsed = try client.callTool("login", null);
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        fail("login", "no text in response");
        return false;
    };

    // Print the login instructions for the user.
    std.debug.print("\n  ┌─────────────────────────────────────────┐\n", .{});
    std.debug.print("  │  Please authenticate in your browser:   │\n", .{});
    std.debug.print("  └─────────────────────────────────────────┘\n", .{});
    std.debug.print("  {s}\n\n", .{text});
    std.debug.print("  Press ENTER after you've completed sign-in...", .{});

    // Wait for user to press enter.
    var enter_buf: [1]u8 = undefined;
    _ = std.posix.read(std.c.STDIN_FILENO, &enter_buf) catch {};

    // Verify login succeeded.
    const verify = try client.callTool("verify-login", null);
    defer verify.deinit();

    const verify_text = McpClient.getResultText(verify) orelse {
        fail("login", "verify-login returned no text");
        return false;
    };

    if (std.mem.indexOf(u8, verify_text, "Login successful") != null) {
        pass("login (device code flow)");
        return true;
    } else {
        // Could also be authenticated if the token was saved — check with get-profile.
        const profile = try client.callTool("get-profile", null);
        defer profile.deinit();
        const profile_text = McpClient.getResultText(profile) orelse {
            fail("login", "could not verify auth after login");
            return false;
        };
        if (std.mem.indexOf(u8, profile_text, "\"displayName\"") != null) {
            pass("login (authenticated via saved token)");
            return true;
        }
        fail("login", "still not authenticated after login");
        return false;
    }
}

/// Test: Email draft lifecycle — create, verify, delete.
fn testDraftLifecycle(client: *McpClient) !void {
    // Create a draft.
    // Use E2E_TEST_EMAIL env var for the draft recipient, fallback to a safe default.
    const test_email = if (std.c.getenv("E2E_TEST_EMAIL")) |ptr| std.mem.span(ptr) else "e2e-test@example.com";
    var draft_args_buf: [1024]u8 = undefined;
    const draft_args = std.fmt.bufPrint(&draft_args_buf, "{{\"to\":[\"{s}\"],\"subject\":\"[E2E TEST] Draft lifecycle test\",\"body\":\"This draft was created by the e2e test suite and should be deleted.\"}}", .{test_email}) catch {
        fail("create-draft", "failed to build args");
        return;
    };
    const create = try client.callTool("create-draft", draft_args);
    defer create.deinit();

    const create_text = McpClient.getResultText(create) orelse {
        fail("create-draft", "no text in response");
        return;
    };

    // The response is "Draft created successfully. Draft ID: <id>"
    const draft_id = extractAfterMarker(client.allocator, create_text, "Draft ID: ") orelse
        extractId(client.allocator, create_text) orelse {
        fail("create-draft", "could not extract draft id from response");
        return;
    };
    defer client.allocator.free(draft_id);
    pass("create-draft");

    // Delete the draft to clean up.
    var delete_args_buf: [512]u8 = undefined;
    const delete_args = std.fmt.bufPrint(&delete_args_buf, "{{\"draftId\":\"{s}\"}}", .{draft_id}) catch {
        fail("delete-draft", "failed to build args");
        return;
    };
    const delete = try client.callTool("delete-draft", delete_args);
    defer delete.deinit();

    const delete_text = McpClient.getResultText(delete) orelse {
        fail("delete-draft", "no text in response");
        return;
    };

    if (std.mem.indexOf(u8, delete_text, "deleted") != null or
        std.mem.indexOf(u8, delete_text, "Draft deleted") != null)
    {
        pass("delete-draft");
    } else {
        fail("delete-draft", delete_text);
    }
}

/// Test: Calendar event lifecycle — create, get, delete.
fn testCalendarLifecycle(client: *McpClient) !void {
    // Create an event.
    const create = try client.callTool("create-calendar-event", "{\"subject\":\"[E2E TEST] Calendar test\",\"startDateTime\":\"2099-01-01T10:00:00\",\"endDateTime\":\"2099-01-01T11:00:00\"}");
    defer create.deinit();

    const create_text = McpClient.getResultText(create) orelse {
        fail("create-calendar-event", "no text in response");
        return;
    };

    const event_id = extractId(client.allocator, create_text) orelse {
        const preview_len = @min(create_text.len, 200);
        std.debug.print("  DEBUG create-calendar-event response: {s}...\n", .{create_text[0..preview_len]});
        fail("create-calendar-event", "could not extract event id");
        return;
    };
    defer client.allocator.free(event_id);
    pass("create-calendar-event");

    // Get the event by ID.
    var get_args_buf: [512]u8 = undefined;
    const get_args = std.fmt.bufPrint(&get_args_buf, "{{\"eventId\":\"{s}\"}}", .{event_id}) catch {
        fail("get-calendar-event", "failed to build args");
        return;
    };
    const get = try client.callTool("get-calendar-event", get_args);
    defer get.deinit();

    const get_text = McpClient.getResultText(get) orelse {
        fail("get-calendar-event", "no text in response");
        return;
    };

    if (std.mem.indexOf(u8, get_text, "E2E TEST") != null) {
        pass("get-calendar-event");
    } else {
        fail("get-calendar-event", "event subject not found in response");
    }

    // Delete the event.
    var del_args_buf: [512]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_args_buf, "{{\"eventId\":\"{s}\"}}", .{event_id}) catch {
        fail("delete-calendar-event", "failed to build args");
        return;
    };
    const del = try client.callTool("delete-calendar-event", del_args);
    defer del.deinit();

    const del_text = McpClient.getResultText(del) orelse {
        fail("delete-calendar-event", "no text in response");
        return;
    };

    if (std.mem.indexOf(u8, del_text, "deleted") != null or
        std.mem.indexOf(u8, del_text, "Event deleted") != null)
    {
        pass("delete-calendar-event");
    } else {
        fail("delete-calendar-event", del_text);
    }
}

/// Test: List emails (read-only, no cleanup needed).
fn testListEmails(client: *McpClient) !void {
    const parsed = try client.callTool("list-emails", null);
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        fail("list-emails", "no text in response");
        return;
    };

    // Should return JSON with a "value" array.
    if (std.mem.indexOf(u8, text, "\"value\"") != null) {
        pass("list-emails");
    } else {
        fail("list-emails", "response doesn't contain value array");
    }
}

/// Test: List chats (read-only).
fn testListChats(client: *McpClient) !void {
    const parsed = try client.callTool("list-chats", null);
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        fail("list-chats", "no text in response");
        return;
    };

    // Should return chat summaries or "No chats found."
    if (text.len > 0) {
        pass("list-chats");
    } else {
        fail("list-chats", "empty response");
    }
}

/// Test: List teams (read-only).
fn testListTeams(client: *McpClient) !void {
    const parsed = try client.callTool("list-teams", null);
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        fail("list-teams", "no text in response");
        return;
    };

    if (text.len > 0) {
        pass("list-teams");
    } else {
        fail("list-teams", "empty response");
    }
}

/// Test: Get user profile (read-only).
fn testGetProfile(client: *McpClient) !void {
    const parsed = try client.callTool("get-profile", null);
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        fail("get-profile", "no text in response");
        return;
    };

    if (std.mem.indexOf(u8, text, "\"displayName\"") != null or
        std.mem.indexOf(u8, text, "\"mail\"") != null)
    {
        pass("get-profile");
    } else {
        fail("get-profile", "response doesn't look like a profile");
    }
}

/// Test: Search users (read-only).
fn testSearchUsers(client: *McpClient) !void {
    const parsed = try client.callTool("search-users", "{\"query\":\"test\"}");
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        fail("search-users", "no text in response");
        return;
    };

    // Should return JSON with "value" array (might be empty, that's ok).
    if (std.mem.indexOf(u8, text, "\"value\"") != null) {
        pass("search-users");
    } else {
        fail("search-users", "response doesn't contain value array");
    }
}

// --- Helpers ---

/// Extract a value that appears after a text marker, ending at newline or end of string.
/// e.g. extractAfterMarker("Draft ID: ABC123\n", "Draft ID: ") => "ABC123"
fn extractAfterMarker(allocator: Allocator, text: []const u8, marker: []const u8) ?[]u8 {
    const start_idx = std.mem.indexOf(u8, text, marker) orelse return null;
    const val_start = start_idx + marker.len;
    const val_end = std.mem.indexOfPos(u8, text, val_start, "\n") orelse text.len;
    if (val_start >= val_end) return null;
    return allocator.dupe(u8, text[val_start..val_end]) catch return null;
}

/// Extract the top-level "id" field from a JSON response body string.
/// Parses the JSON properly to avoid matching "parentFolderId" etc.
fn extractId(allocator: Allocator, json_text: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const id_val = obj.get("id") orelse return null;
    const id_str = switch (id_val) {
        .string => |s| s,
        else => return null,
    };
    return allocator.dupe(u8, id_str) catch return null;
}

// --- Main ---

/// Read the .mcp.json config file and build an Environ.Map with
/// MS365_CLIENT_ID and MS365_TENANT_ID for the child process.
fn loadMcpConfig(allocator: Allocator, io: Io) !std.process.Environ.Map {
    const data = std.Io.Dir.readFileAlloc(.cwd(), io, ".mcp.json", allocator, .unlimited) catch {
        return error.NoMcpConfig;
    };
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    // Navigate: mcpServers -> ms365 -> env -> MS365_CLIENT_ID / MS365_TENANT_ID
    const servers = switch (parsed.value.object.get("mcpServers") orelse return error.InvalidConfig) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };
    const ms365 = switch (servers.get("ms365") orelse return error.InvalidConfig) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };
    const env_obj = switch (ms365.get("env") orelse return error.InvalidConfig) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };

    const client_id = switch (env_obj.get("MS365_CLIENT_ID") orelse return error.InvalidConfig) {
        .string => |s| s,
        else => return error.InvalidConfig,
    };
    const tenant_id = switch (env_obj.get("MS365_TENANT_ID") orelse return error.InvalidConfig) {
        .string => |s| s,
        else => return error.InvalidConfig,
    };

    // Build an Environ.Map with just these two vars + HOME (needed for token file).
    var env_map = std.process.Environ.Map.init(allocator);
    try env_map.put("MS365_CLIENT_ID", client_id);
    try env_map.put("MS365_TENANT_ID", tenant_id);
    // Pass HOME so the server can find/save the token file.
    if (std.c.getenv("HOME")) |home| {
        try env_map.put("HOME", std.mem.span(home));
    }
    return env_map;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create threaded I/O context (required for process spawning + networking).
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    const io = threaded_io.io();

    // Load env vars from .mcp.json to pass to the child server process.
    var env_map = loadMcpConfig(allocator, io) catch {
        std.debug.print("Error: could not read .mcp.json for MS365_CLIENT_ID/MS365_TENANT_ID.\n", .{});
        return;
    };
    defer env_map.deinit();

    // Build the absolute path to the MCP server binary.
    const exe_path = "zig-out/bin/ms-mcp";

    std.debug.print("\n\x1b[1m── ms-mcp End-to-End Tests ──\x1b[0m\n\n", .{});

    // Spawn the server with the env vars.
    var client = McpClient.init(allocator, io, exe_path, &env_map) catch |err| {
        std.debug.print("Failed to spawn server: {}\n", .{err});
        return err;
    };
    defer client.deinit(io);

    // --- Protocol handshake ---
    std.debug.print("\x1b[1mProtocol:\x1b[0m\n", .{});
    try testInitialize(&client);

    // --- Authentication ---
    std.debug.print("\n\x1b[1mAuthentication:\x1b[0m\n", .{});
    var authenticated = try testCheckAuth(&client);
    if (!authenticated) {
        authenticated = try testLogin(&client);
    }
    if (!authenticated) {
        std.debug.print("\n\x1b[31mCannot continue without authentication.\x1b[0m\n", .{});
        return;
    }

    // --- Read-only tests (no cleanup needed) ---
    std.debug.print("\n\x1b[1mRead-only:\x1b[0m\n", .{});
    try testGetProfile(&client);
    try testListEmails(&client);
    try testListChats(&client);
    try testListTeams(&client);
    try testSearchUsers(&client);

    // --- Lifecycle tests (create → verify → delete) ---
    std.debug.print("\n\x1b[1mLifecycle:\x1b[0m\n", .{});
    try testDraftLifecycle(&client);
    try testCalendarLifecycle(&client);

    // --- Summary ---
    const total = tests_passed + tests_failed;
    std.debug.print("\n\x1b[1m── Results: {d}/{d} passed ──\x1b[0m\n\n", .{ tests_passed, total });

    if (tests_failed > 0) {
        std.process.exit(1);
    }
}
