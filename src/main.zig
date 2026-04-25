// main.zig — Entry point and message loop for the ms-mcp MCP server.
//
// Reading guide for engineers new to Zig (coming from TypeScript / similar):
//
// 1. The message loop reads JSON-RPC lines from stdin, dispatches them to a
//    tool handler, and writes responses to stdout. Nothing fancy — same shape
//    as a Node stdio server using a while(true) loop.
//
// 2. `try expr` propagates errors from `expr`; `expr catch |err| { ... }` is
//    a try/catch. The return type `!void` means "void or error". Think
//    `Promise<void>`-but-synchronous.
//
// 3. `?T` is an optional (like `T | null`). Unwrap with `x orelse default` or
//    `if (x) |v| { ... }`. `x.?` is a force-unwrap that panics on null.
//
// 4. `defer x` runs `x` when the enclosing scope exits — Zig's equivalent of
//    a `finally` block but per-scope and cumulative.
//
// 5. Allocators are passed explicitly. There is no GC; every heap allocation
//    has a corresponding free, typically via `defer allocator.free(x)`.
//
// 6. Tool handlers live under src/tools/. Each one takes a ToolContext and
//    returns void — they report success/failure via ctx.sendResult(). The
//    dispatch table `tool_handlers` below maps tool name → handler.

const std = @import("std");
const types = @import("types.zig");
const auth = @import("auth.zig");
const json_rpc = @import("json_rpc.zig");
const registry = @import("tools/registry.zig");
const tz = @import("timezone.zig");
const state_mod = @import("state.zig");
const auth_tools = @import("tools/auth_tools.zig");
const email_tools = @import("tools/email.zig");
const draft_tools = @import("tools/drafts.zig");
const calendar_tools = @import("tools/calendar.zig");
const chat_tools = @import("tools/chat.zig");
const channel_tools = @import("tools/channels.zig");
const sharepoint_tools = @import("tools/sharepoint.zig");
const onedrive_tools = @import("tools/onedrive.zig");
const user_tools = @import("tools/users.zig");
const ToolContext = @import("tools/context.zig").ToolContext;

// Type aliases — keeps function signatures cleaner.
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

/// Tool handler signature — every handler takes a ToolContext and returns void.
/// Errors and results are signaled via `ctx.sendResult()`.
const Handler = *const fn (ToolContext) void;

/// Maps a tool name (as sent by the MCP client) to its handler function.
/// Built at compile time from the list of tools registered in tools/registry.zig.
/// This replaces what would otherwise be a long chain of `if/else if` comparisons.
const tool_handlers = std.StaticStringMap(Handler).initComptime(.{
    // --- Auth & session ---
    .{ "login", auth_tools.handleLogin },
    .{ "verify-login", auth_tools.handleVerifyLogin },
    .{ "get-mailbox-settings", auth_tools.handleGetMailboxSettings },
    .{ "sync-timezone", auth_tools.handleSyncTimezone },
    // --- Email ---
    .{ "list-emails", email_tools.handleListEmails },
    .{ "read-email", email_tools.handleReadEmail },
    .{ "send-email", email_tools.handleSendEmail },
    .{ "delete-email", email_tools.handleDeleteEmail },
    .{ "batch-delete-emails", email_tools.handleBatchDeleteEmails },
    .{ "reply-email", email_tools.handleReplyEmail },
    .{ "reply-all-email", email_tools.handleReplyAllEmail },
    .{ "forward-email", email_tools.handleForwardEmail },
    .{ "search-emails", email_tools.handleSearchEmails },
    .{ "list-mail-folders", email_tools.handleListMailFolders },
    .{ "mark-read-email", email_tools.handleMarkReadEmail },
    .{ "move-email", email_tools.handleMoveEmail },
    .{ "list-email-attachments", email_tools.handleListEmailAttachments },
    .{ "read-email-attachment", email_tools.handleReadEmailAttachment },
    .{ "download-email-attachment", email_tools.handleDownloadEmailAttachment },
    // --- Drafts ---
    .{ "create-draft", draft_tools.handleCreateDraft },
    .{ "send-draft", draft_tools.handleSendDraft },
    .{ "update-draft", draft_tools.handleUpdateDraft },
    .{ "delete-draft", draft_tools.handleDeleteDraft },
    .{ "add-attachment", draft_tools.handleAddAttachment },
    .{ "list-attachments", draft_tools.handleListAttachments },
    .{ "remove-attachment", draft_tools.handleRemoveAttachment },
    // --- Chat ---
    .{ "list-chats", chat_tools.handleListChats },
    .{ "list-chat-messages", chat_tools.handleListChatMessages },
    .{ "send-chat-message", chat_tools.handleSendChatMessage },
    .{ "create-chat", chat_tools.handleCreateChat },
    .{ "search-chat-messages", chat_tools.handleSearchChatMessages },
    .{ "delete-chat-message", chat_tools.handleDeleteChatMessage },
    // --- Calendar ---
    .{ "get-calendar-event", calendar_tools.handleGetCalendarEvent },
    .{ "list-calendar-events", calendar_tools.handleListCalendarEvents },
    .{ "create-calendar-event", calendar_tools.handleCreateCalendarEvent },
    .{ "update-calendar-event", calendar_tools.handleUpdateCalendarEvent },
    .{ "delete-calendar-event", calendar_tools.handleDeleteCalendarEvent },
    .{ "find-meeting-times", calendar_tools.handleFindMeetingTimes },
    .{ "get-schedule", calendar_tools.handleGetSchedule },
    .{ "respond-to-event", calendar_tools.handleRespondToEvent },
    // --- Teams channels ---
    .{ "list-teams", channel_tools.handleListTeams },
    .{ "list-channels", channel_tools.handleListChannels },
    .{ "list-channel-messages", channel_tools.handleListChannelMessages },
    .{ "get-channel-message-replies", channel_tools.handleGetChannelMessageReplies },
    .{ "post-channel-message", channel_tools.handlePostChannelMessage },
    .{ "reply-to-channel-message", channel_tools.handleReplyToChannelMessage },
    .{ "delete-channel-message", channel_tools.handleDeleteChannelMessage },
    .{ "delete-channel-reply", channel_tools.handleDeleteChannelReply },
    // --- SharePoint ---
    .{ "search-sharepoint-sites", sharepoint_tools.handleSearchSites },
    .{ "list-sharepoint-drives", sharepoint_tools.handleListDrives },
    .{ "list-sharepoint-items", sharepoint_tools.handleListItems },
    .{ "upload-sharepoint-file", sharepoint_tools.handleUploadFile },
    .{ "upload-sharepoint-content", sharepoint_tools.handleUploadContent },
    .{ "create-sharepoint-folder", sharepoint_tools.handleCreateFolder },
    .{ "delete-sharepoint-item", sharepoint_tools.handleDeleteItem },
    .{ "download-sharepoint-file", sharepoint_tools.handleDownloadFile },
    // --- OneDrive (personal) ---
    .{ "list-onedrive-items", onedrive_tools.handleListItems },
    .{ "upload-onedrive-file", onedrive_tools.handleUploadFile },
    .{ "upload-onedrive-content", onedrive_tools.handleUploadContent },
    .{ "download-onedrive-file", onedrive_tools.handleDownloadFile },
    .{ "delete-onedrive-item", onedrive_tools.handleDeleteItem },
    // --- Utility ---
    .{ "search-users", user_tools.handleSearchUsers },
    .{ "get-profile", user_tools.handleGetProfile },
});

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("ms-mcp: server starting\n", .{});

    // Read Microsoft OAuth config from environment variables.
    // These are set in the MCP server config (.mcp.json).
    // std.c.getenv calls the C library's getenv() — returns a pointer to the
    // value string, or null if the variable isn't set.
    // mem.span() converts the null-terminated C string to a Zig slice.
    const client_id: []const u8 = if (std.c.getenv("MS365_CLIENT_ID")) |ptr|
        std.mem.span(ptr)
    else {
        std.debug.print("ms-mcp: MS365_CLIENT_ID not set\n", .{});
        return;
    };

    const tenant_id: []const u8 = if (std.c.getenv("MS365_TENANT_ID")) |ptr|
        std.mem.span(ptr)
    else {
        std.debug.print("ms-mcp: MS365_TENANT_ID not set\n", .{});
        return;
    };

    // Create a full I/O context with networking support.
    // Threaded.init() sets up an Io that can do real network operations (TCP, TLS).
    // debug_io (what we used before) only supports file I/O, not networking.
    // We use this for both stdin/stdout and HTTP requests.
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    const io = threaded_io.io();

    // 32 MiB stdin read buffer, heap-allocated (too large for the 8 MiB
    // default stack on macOS). MCP tools/call requests for file uploads via
    // upload-sharepoint-content can carry multi-megabyte payloads in the
    // arguments; a smaller buffer would cause takeDelimiter() to fail on any
    // request line larger than the buffer.
    const read_buf = allocator.alloc(u8, 32 * 1024 * 1024) catch |err| {
        std.debug.print("ms-mcp: failed to allocate read buffer: {}\n", .{err});
        return;
    };
    defer allocator.free(read_buf);
    var stdin = std.Io.File.stdin().reader(io, read_buf);

    // Stdout writer — where we send JSON-RPC responses back to the client.
    // 64 KiB buffer: the tools/list response with all 26 tool schemas is large.
    var write_buf: [65536]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &write_buf);

    // Try to load a saved token from a previous session.
    // If found, we can skip the login flow entirely.
    const saved_token = auth.loadToken(allocator, io);
    // Free the saved token strings when we're done.
    defer if (saved_token) |t| {
        allocator.free(t.access_token);
        allocator.free(t.refresh_token);
    };

    runMessageLoop(allocator, io, &stdin.interface, &stdout.interface, client_id, tenant_id, saved_token);
}


/// Reads JSON-RPC messages from the reader one line at a time,
/// parses them, and dispatches by method name.
fn runMessageLoop(allocator: Allocator, io: std.Io, reader: *Reader, writer: *Writer, client_id: []const u8, tenant_id: []const u8, saved_token: ?auth.SavedToken) void {
    // Mutable state that lives for the entire session.
    // If we loaded a token from disk, use it. Otherwise start empty.
    var state = state_mod.State{};
    if (saved_token) |t| {
        state.access_token = t.access_token;
        state.refresh_token = t.refresh_token;
        state.expires_at = t.expires_at;
        std.debug.print("ms-mcp: using saved token (expires_at={d})\n", .{t.expires_at});
    }

    // Detect timezone from the system clock (/etc/localtime on macOS).
    // This runs once at startup so all calendar operations use the right timezone.
    var tz_buf: [256]u8 = undefined;
    if (tz.getSystemTimezone(&tz_buf)) |iana_tz| {
        if (tz.ianaToWindows(iana_tz)) |ms_tz| {
            state.timezone = ms_tz;
            std.debug.print("ms-mcp: detected timezone: {s} → {s}\n", .{ iana_tz, ms_tz });
        } else {
            std.debug.print("ms-mcp: unknown timezone: {s}, defaulting to UTC\n", .{iana_tz});
        }
    } else {
        std.debug.print("ms-mcp: could not detect system timezone, defaulting to UTC\n", .{});
    }

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
                json_rpc.sendJsonResponse(writer, types.JsonRpcResponse(types.InitializeResult){
                    .id = json_rpc.getRequestId(parsed.value),
                    .result = .{},
                });
            } else if (std.mem.eql(u8, m, "ping")) {
                // MCP health check — client pings to verify the server is alive.
                // Must respond promptly with an empty result or the client will
                // consider the connection stale and drop our tools.
                const EmptyResult = struct {};
                json_rpc.sendJsonResponse(writer, types.JsonRpcResponse(EmptyResult){
                    .id = json_rpc.getRequestId(parsed.value),
                    .result = .{},
                });
            } else if (std.mem.eql(u8, m, "tools/call")) {
                if (json_rpc.getToolName(parsed.value)) |name| {
                    std.debug.print("ms-mcp: tool call: {s}\n", .{name});

                    // Build the shared context that all tool handlers receive.
                    const ctx = ToolContext{
                        .allocator = allocator,
                        .io = io,
                        .writer = writer,
                        .state = &state,
                        .client_id = client_id,
                        .tenant_id = tenant_id,
                        .parsed = parsed.value,
                    };

                    // Look up the handler by tool name. Unknown tools are silently
                    // ignored, matching previous behavior (the if/else chain had no else).
                    if (tool_handlers.get(name)) |handler| handler(ctx);
                }
            } else if (std.mem.eql(u8, m, "tools/list")) {
                // Return the full list of tool definitions with JSON Schema inputSchemas.
                // All schema construction is in tools/registry.zig.
                const tools = registry.allDefinitions(allocator) orelse continue;
                json_rpc.sendJsonResponse(writer, types.JsonRpcResponse(types.ToolsListResult){
                    .id = json_rpc.getRequestId(parsed.value),
                    .result = .{ .tools = tools },
                });
            } else {
                // Unknown method — if it has an id (a request), return a
                // JSON-RPC "method not found" error. Notifications (no id) are
                // silently ignored per the JSON-RPC spec.
                const request_id = json_rpc.getRequestId(parsed.value);
                if (request_id != 0) {
                    const JsonRpcError = struct {
                        jsonrpc: []const u8 = "2.0",
                        id: i64,
                        @"error": ErrorBody,

                        const ErrorBody = struct {
                            code: i64 = -32601,
                            message: []const u8 = "Method not found",
                        };
                    };
                    json_rpc.sendJsonResponse(writer, JsonRpcError{
                        .id = request_id,
                        .@"error" = .{},
                    });
                }
            }
        }
    }
}
