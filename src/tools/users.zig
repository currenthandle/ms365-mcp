// tools/users.zig — User lookup and profile tools.

const std = @import("std");
const graph = @import("../graph.zig");
const url = @import("../url.zig");
const ToolContext = @import("context.zig").ToolContext;

/// Search for people in the Microsoft 365 organization by name.
pub fn handleSearchUsers(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide query (name to search for).") orelse return;
    const query = ctx.getStringArg(args, "query", "Missing 'query' argument.") orelse return;

    // URL-encode the query so spaces and special characters don't break the URL.
    const encoded_query = url.encode(ctx.allocator, query) catch return;
    defer ctx.allocator.free(encoded_query);

    // People API: $search requires %22-quoted strings per Graph API spec.
    const path = std.fmt.allocPrint(
        ctx.allocator,
        "/me/people?$search=%22{s}%22&$top=5&$select=displayName,scoredEmailAddresses,userPrincipalName",
        .{encoded_query},
    ) catch return;
    defer ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch {
        ctx.sendResult("Failed to search users.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}

/// Get the logged-in user's Microsoft 365 profile.
pub fn handleGetProfile(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;

    const response = graph.get(
        ctx.allocator, ctx.io, token,
        "/me?$select=id,displayName,mail,userPrincipalName",
    ) catch {
        ctx.sendResult("Failed to fetch profile.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}
