// tools/context.zig — Shared context passed to every tool handler.

const std = @import("std");
const json_rpc = @import("../json_rpc.zig");
const state_mod = @import("../state.zig");

/// Bundles the 7 parameters every tool handler needs into one struct.
/// Constructed once per tools/call in main.zig's message loop.
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *json_rpc.Writer,
    state: *state_mod.State,
    client_id: []const u8,
    tenant_id: []const u8,
    /// Borrows data from main.zig's message loop — valid for one handler call only.
    parsed: std.json.Value,
};
