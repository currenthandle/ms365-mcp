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

/// Returns true if the given category should run.
/// If E2E_ONLY is set in the environment, only categories matching its value
/// run; otherwise every category runs. Comma-separated values allow multiple
/// categories (e.g. E2E_ONLY=sharepoint,channels).
fn shouldRun(category: []const u8) bool {
    const only_raw = std.c.getenv("E2E_ONLY") orelse return true;
    const only = std.mem.span(only_raw);
    if (only.len == 0) return true;
    var it = std.mem.splitScalar(u8, only, ',');
    while (it.next()) |token| {
        if (std.mem.eql(u8, std.mem.trim(u8, token, " "), category)) return true;
    }
    return false;
}

/// Every env var the suite needs to run a real journey against live Graph.
/// Missing any of these used to produce silent skips; now the run aborts
/// with a clear list so tests can't pass by not running.
const required_env = [_][]const u8{
    "E2E_TEST_EMAIL",
    "E2E_ATTENDEE_REQUIRED",
    "E2E_ATTENDEE_OPTIONAL",
    "E2E_SHAREPOINT_SITE_NAME",
};

/// Verify all required env vars are set. Prints a list of any missing ones
/// and returns false so the run can abort cleanly.
fn checkRequiredEnv() bool {
    var missing = false;
    for (required_env) |name| {
        const name_z = std.heap.page_allocator.dupeZ(u8, name) catch continue;
        defer std.heap.page_allocator.free(name_z);
        if (std.c.getenv(name_z.ptr) == null) {
            if (!missing) {
                std.debug.print("\n\x1b[31mMissing required env vars:\x1b[0m\n", .{});
                missing = true;
            }
            std.debug.print("  - {s}\n", .{name});
        }
    }
    if (missing) {
        std.debug.print("\nAdd them to .env and re-run.\n\n", .{});
        return false;
    }
    return true;
}

/// Call after a test category to confirm the server is still responsive.
/// If a previous test crashed or hung the process, stop the run immediately
/// rather than watch every remaining test fail with cascading errors.
fn assertAlive(client: *client_mod.McpClient, label: []const u8) void {
    if (!client.isAlive()) {
        std.debug.print("\n\x1b[31m✗ Server unresponsive after {s} — aborting run.\x1b[0m\n", .{label});
        std.debug.print("  The most recent tool call likely crashed or hung the MCP server.\n", .{});
        std.process.exit(1);
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create threaded I/O context (required for process spawning + networking).
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    const io = threaded_io.io();

    // Load .env file (won't overwrite existing env vars).
    env.loadDotEnv(allocator, io);

    // All test recipients / sites must be configured up front. A missing
    // var used to silently skip the relevant journey; now it aborts.
    if (!checkRequiredEnv()) return;

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
    if (shouldRun("readonly")) {
        std.debug.print("\n\x1b[1mRead-only:\x1b[0m\n", .{});
        try cases.testGetProfile(&client);
        try cases.testListEmails(&client);
        try cases.testListChats(&client);
        try cases.testListTeams(&client);
        try cases.testSearchUsers(&client);
        try cases.testGetMailboxSettings(&client);
        try cases.testSyncTimezone(&client);
    }

    // --- Lifecycle tests (create → verify → delete) ---
    if (shouldRun("drafts")) {
        std.debug.print("\n\x1b[1mLifecycle — Drafts:\x1b[0m\n", .{});
        try cases.testDraftLifecycle(&client);
        try cases.testUpdateDraftLifecycle(&client);
        try cases.testSendDraftLifecycle(&client);
        try cases.testAttachmentLifecycle(&client);
        try cases.testRemoveAttachmentLifecycle(&client);
    }

    if (shouldRun("calendar")) {
        std.debug.print("\n\x1b[1mLifecycle — Calendar:\x1b[0m\n", .{});
        try cases.testCalendarLifecycle(&client);
        try cases.testCalendarWithAttendees(&client);
        try cases.testCalendarListAndUpdate(&client);
    }

    if (shouldRun("email")) {
        std.debug.print("\n\x1b[1mLifecycle — Email:\x1b[0m\n", .{});
        try cases.testSendEmailLifecycle(&client);
        try cases.testEmailReplyLifecycle(&client);
        try cases.testEmailForwardLifecycle(&client);
        try cases.testEmailSearch(&client);
        try cases.testListMailFolders(&client);
        try cases.testMarkReadLifecycle(&client);
        try cases.testMoveEmailLifecycle(&client);
        try cases.testEmailAttachmentDownload(&client);
    }

    if (shouldRun("calendar-schedule")) {
        std.debug.print("\n\x1b[1mLifecycle — Calendar Scheduling:\x1b[0m\n", .{});
        try cases.testGetSchedule(&client);
        try cases.testFindMeetingTimes(&client);
        try cases.testRespondToEvent(&client);
    }

    if (shouldRun("onedrive")) {
        std.debug.print("\n\x1b[1mLifecycle — OneDrive:\x1b[0m\n", .{});
        try cases.testOneDriveLifecycle(&client);
    }

    if (shouldRun("chat")) {
        std.debug.print("\n\x1b[1mLifecycle — Chat:\x1b[0m\n", .{});
        try cases.testChatMessageLifecycle(&client);
        assertAlive(&client, "chat lifecycle");
    }

    if (shouldRun("channels")) {
        std.debug.print("\n\x1b[1mLifecycle — Channels:\x1b[0m\n", .{});
        try cases.testChannelLifecycle(&client);
        try cases.testReplyToChannelMessage(&client);
        assertAlive(&client, "channels lifecycle");
    }

    if (shouldRun("sharepoint")) {
        std.debug.print("\n\x1b[1mLifecycle — SharePoint:\x1b[0m\n", .{});
        try cases.testSharePointLifecycle(&client);
        try cases.testSharePointFileUpload(&client);
        try cases.testSharePointLargeUpload(&client);
        try cases.testSharePointItemIdTargeting(&client);
        try cases.testSharePointPathValidation(&client);
    }

    // --- Summary ---
    const total = runner.tests_passed + runner.tests_failed;
    std.debug.print("\n\x1b[1m── Results: {d}/{d} passed ──\x1b[0m\n\n", .{ runner.tests_passed, total });

    if (runner.tests_failed > 0) {
        std.process.exit(1);
    }
}
