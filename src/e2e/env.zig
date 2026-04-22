// e2e/env.zig — Environment loading helpers.
//
// The e2e binary needs MS365_CLIENT_ID and MS365_TENANT_ID to pass to the
// child server, plus optional E2E_* variables for which recipients to use
// in lifecycle tests. This module reads .mcp.json (for the MS365 vars) and
// .env (for everything else).

const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
});

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Read the .mcp.json config file and build an Environ.Map with
/// MS365_CLIENT_ID and MS365_TENANT_ID for the child process.
pub fn loadMcpConfig(allocator: Allocator, io: Io) !std.process.Environ.Map {
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

/// Load a .env file and set each KEY=VALUE as an environment variable.
/// Uses a page allocator for the dupeZ strings since they must outlive
/// the GPA (setenv holds pointers to them for the process lifetime).
pub fn loadDotEnv(allocator: Allocator, io: Io) void {
    const data = std.Io.Dir.readFileAlloc(.cwd(), io, ".env", allocator, .unlimited) catch return;
    defer allocator.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const eq_idx = std.mem.indexOf(u8, line, "=") orelse continue;
        const key = line[0..eq_idx];
        const value = line[eq_idx + 1 ..];
        // page_allocator because C setenv holds these pointers for the process lifetime.
        const key_z = std.heap.page_allocator.dupeZ(u8, key) catch continue;
        const val_z = std.heap.page_allocator.dupeZ(u8, value) catch continue;
        _ = c.setenv(key_z.ptr, val_z.ptr, 0);
    }
}
