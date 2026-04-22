// e2e.zig — End-to-end test runner for ms-mcp.
//
// Spawns the MCP server as a child process, communicates over stdin/stdout
// using the JSON-RPC protocol, and runs real tests against the live
// Microsoft Graph API.
//
// The heavy lifting lives in sub-modules:
//   e2e/client.zig  — MCP client wrapper around the child process pipes
//   e2e/runner.zig  — pass/fail counters shared by every test
//   e2e/helpers.zig — response-parsing helpers (extract ID, find email, etc.)
//   e2e/env.zig     — .mcp.json and .env loading
//   e2e/cases.zig   — the actual test functions
//
// Usage: zig build e2e
// Requires: MS365_CLIENT_ID and MS365_TENANT_ID environment variables.
// If not already authenticated, prompts the user to complete device code auth.

const std = @import("std");

const client_mod = @import("e2e/client.zig");
const runner = @import("e2e/runner.zig");
const cases = @import("e2e/cases.zig");
const env = @import("e2e/env.zig");

const McpClient = client_mod.McpClient;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create threaded I/O context (required for process spawning + networking).
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    const io = threaded_io.io();

    // Load .env file (won't overwrite existing env vars).
    env.loadDotEnv(allocator, io);

    // Load env vars from .mcp.json to pass to the child server process.
    var env_map = env.loadMcpConfig(allocator, io) catch {
        std.debug.print("Error: could not read .mcp.json for MS365_CLIENT_ID/MS365_TENANT_ID.\n", .{});
        return;
    };
    defer env_map.deinit();

    // Build the absolute path to the MCP server binary.
    const exe_path = "zig-out/bin/ms365-mcp";

    std.debug.print("\n\x1b[1m── ms-mcp End-to-End Tests ──\x1b[0m\n\n", .{});

    // Spawn the server with the env vars.
    var client = McpClient.init(allocator, io, exe_path, &env_map) catch |err| {
        std.debug.print("Failed to spawn server: {}\n", .{err});
        return err;
    };
    defer client.deinit(io);

    // --- Protocol handshake ---
    std.debug.print("\x1b[1mProtocol:\x1b[0m\n", .{});
    try cases.testInitialize(&client);

    // --- Authentication ---
    std.debug.print("\n\x1b[1mAuthentication:\x1b[0m\n", .{});
    var authenticated = try cases.testCheckAuth(&client);
    if (!authenticated) {
        authenticated = try cases.testLogin(&client);
    }
    if (!authenticated) {
        std.debug.print("\n\x1b[31mCannot continue without authentication.\x1b[0m\n", .{});
        return;
    }

    // --- Read-only tests (no cleanup needed) ---
    std.debug.print("\n\x1b[1mRead-only:\x1b[0m\n", .{});
    try cases.testGetProfile(&client);
    try cases.testListEmails(&client);
    try cases.testListChats(&client);
    try cases.testListTeams(&client);
    try cases.testSearchUsers(&client);
    try cases.testGetMailboxSettings(&client);
    try cases.testSyncTimezone(&client);

    // --- Lifecycle tests (create → verify → delete) ---
    std.debug.print("\n\x1b[1mLifecycle — Drafts:\x1b[0m\n", .{});
    try cases.testDraftLifecycle(&client);
    try cases.testUpdateDraftLifecycle(&client);
    try cases.testSendDraftLifecycle(&client);
    try cases.testAttachmentLifecycle(&client);
    try cases.testRemoveAttachmentLifecycle(&client);

    std.debug.print("\n\x1b[1mLifecycle — Calendar:\x1b[0m\n", .{});
    try cases.testCalendarLifecycle(&client);
    try cases.testCalendarWithAttendees(&client);
    try cases.testCalendarListAndUpdate(&client);

    std.debug.print("\n\x1b[1mLifecycle — Email:\x1b[0m\n", .{});
    try cases.testSendEmailLifecycle(&client);

    std.debug.print("\n\x1b[1mLifecycle — Chat:\x1b[0m\n", .{});
    try cases.testChatMessageLifecycle(&client);

    std.debug.print("\n\x1b[1mLifecycle — Channels:\x1b[0m\n", .{});
    try cases.testChannelLifecycle(&client);
    try cases.testReplyToChannelMessage(&client);

    // --- Summary ---
    const total = runner.tests_passed + runner.tests_failed;
    std.debug.print("\n\x1b[1m── Results: {d}/{d} passed ──\x1b[0m\n\n", .{ runner.tests_passed, total });

    if (runner.tests_failed > 0) {
        std.process.exit(1);
    }
}
