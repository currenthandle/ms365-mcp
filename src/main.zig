const std = @import("std");
const types = @import("types.zig");
const http = @import("http.zig");
const auth = @import("auth.zig");
const graph = @import("graph.zig");

// Type aliases — keeps function signatures cleaner.
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

    var read_buf: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &read_buf);

    // Stdout writer — where we send JSON-RPC responses back to the client.
    var write_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &write_buf);

    // Try to load a saved token from a previous session.
    // If found, we can skip the login flow entirely.
    const saved_token = auth.loadToken(allocator, io);

    runMessageLoop(allocator, io, &stdin.interface, &stdout.interface, client_id, tenant_id, saved_token);
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

/// Extract the "arguments" object from a "tools/call" request.
/// Tool calls with parameters look like:
///   {"params": {"name": "send-email", "arguments": {"to": "...", "subject": "..."}}}
/// Returns the arguments as a JSON ObjectMap, or null if missing.
fn getToolArgs(value: std.json.Value) ?std.json.ObjectMap {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    const params = switch (obj.get("params") orelse return null) {
        .object => |o| o,
        else => return null,
    };

    // "arguments" contains the tool-specific parameters.
    return switch (params.get("arguments") orelse return null) {
        .object => |o| o,
        else => null,
    };
}

/// Helper to extract a string value from a JSON ObjectMap.
/// Returns null if the key is missing or the value isn't a string.
fn getStringArg(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = args.get(key) orelse return null;
    return switch (val) {
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

/// Server state that persists across tool calls within a session.
/// We need this because the login flow is split across two tool calls:
///   1. "login" gets the device code and stashes it here
///   2. "verify-login" reads it from here and polls for the token
const State = struct {
    pending_device_code: ?auth.DeviceCodeResponse = null,
    access_token: ?[]const u8 = null,
};

/// Reads JSON-RPC messages from the reader one line at a time,
/// parses them, and dispatches by method name.
fn runMessageLoop(allocator: Allocator, io: std.Io, reader: *Reader, writer: *Writer, client_id: []const u8, tenant_id: []const u8, saved_token: ?auth.SavedToken) void {
    // Mutable state that lives for the entire session.
    // If we loaded a token from disk, use it. Otherwise start empty.
    var state = State{};
    if (saved_token) |t| {
        state.access_token = t.access_token;
        std.debug.print("ms-mcp: using saved token (expires_at={d})\n", .{t.expires_at});
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
                        // Start the OAuth device code flow — ask Microsoft for a code.
                        const dc = auth.requestDeviceCode(allocator, io, client_id, tenant_id) catch |err| {
                            // Print the actual error so we can debug.
                            std.debug.print("ms-mcp: device code request failed: {}\n", .{err});

                            // Tell the client the login failed.
                            // Explicit type annotation so Zig knows this is []const TextContent.
                            const error_content: []const types.TextContent = &.{
                                .{ .text = "Failed to start login flow" },
                            };
                            const error_result = types.ToolCallResult{ .content = error_content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = error_result,
                            });
                            continue;
                        };

                        // Stash the device code in state so verify-login can use it.
                        // Don't free dc strings here — state now owns them.
                        state.pending_device_code = dc;

                        // Build a message telling the user where to go and what code to enter.
                        const msg = std.fmt.allocPrint(
                            allocator,
                            "Go to {s} and enter code: {s}\nImmediately call the verify-login tool now. It will poll and wait for the user to complete sign-in.",
                            .{ dc.verification_uri, dc.user_code },
                        ) catch continue;
                        defer allocator.free(msg);

                        // Send the message back to the client.
                        const content: []const types.TextContent = &.{
                            .{ .text = msg },
                        };
                        const result = types.ToolCallResult{ .content = content };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = result,
                        });
                    } else if (std.mem.eql(u8, name, "verify-login")) {
                        // Check that login was called first —
                        // we need the device code from the login step.
                        const dc = state.pending_device_code orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "No pending login. Call login first." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // Poll Microsoft's token endpoint until the user completes login.
                        // This blocks until success or the device code expires.
                        const token = auth.pollForToken(
                            allocator, io, client_id, tenant_id,
                            dc.device_code, dc.expires_in, dc.interval,
                        ) catch |err| {
                            std.debug.print("ms-mcp: token poll failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Login failed or timed out. Try login again." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };
                        // Save tokens to disk so we can re-use them next session.
                        auth.saveToken(allocator, io, token.access_token, token.refresh_token, token.expires_in) catch |err| {
                            std.debug.print("ms-mcp: failed to save token: {}\n", .{err});
                        };
                        defer allocator.free(token.refresh_token);

                        // Store the access token in state for future Graph API calls.
                        state.access_token = token.access_token;

                        // Clean up the pending device code — login is complete.
                        // These strings were allocated in requestDeviceCode.
                        allocator.free(dc.user_code);
                        allocator.free(dc.device_code);
                        allocator.free(dc.verification_uri);
                        state.pending_device_code = null;

                        const content: []const types.TextContent = &.{
                            .{ .text = "Login successful!" },
                        };
                        const result = types.ToolCallResult{ .content = content };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = result,
                        });
                    } else if (std.mem.eql(u8, name, "list-emails")) {
                        // Check that we have an access token — user must be logged in.
                        const token = state.access_token orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Not logged in. Call login first." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // Call Graph API to list recent emails.
                        // $top=10 — only get the 10 most recent
                        // $select — only fetch the fields we need (saves bandwidth)
                        // $orderby — newest first
                        // %20 is a URL-encoded space for "receivedDateTime desc"
                        const response_body = graph.get(
                            allocator, io, token,
                            "/me/messages?$top=10&$select=subject,from,receivedDateTime,bodyPreview&$orderby=receivedDateTime%20desc",
                        ) catch |err| {
                            std.debug.print("ms-mcp: list-emails failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to fetch emails." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };
                        defer allocator.free(response_body);

                        // Return the raw JSON to the LLM.
                        // The LLM can parse and summarize it for the user.
                        const content: []const types.TextContent = &.{
                            .{ .text = response_body },
                        };
                        const result = types.ToolCallResult{ .content = content };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = result,
                        });
                    } else if (std.mem.eql(u8, name, "send-email")) {
                        // Check that we have an access token.
                        const token = state.access_token orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Not logged in. Call login first." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // Extract the arguments: to, subject, body.
                        const args = getToolArgs(parsed.value) orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing arguments. Provide to, subject, and body." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // Get each required string argument.
                        const to = getStringArg(args, "to") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'to' argument (email address)." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };
                        const subject = getStringArg(args, "subject") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'subject' argument." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };
                        const body_text = getStringArg(args, "body") orelse {
                            const content: []const types.TextContent = &.{
                                .{ .text = "Missing 'body' argument." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // Build the Graph API request body for POST /me/sendMail.
                        // The format Microsoft expects:
                        // {"message":{"subject":"...","body":{"contentType":"Text","content":"..."},
                        //   "toRecipients":[{"emailAddress":{"address":"..."}}]}}
                        const json_body = std.fmt.allocPrint(
                            allocator,
                            "{{\"message\":{{\"subject\":\"{s}\",\"body\":{{\"contentType\":\"Text\",\"content\":\"{s}\"}},\"toRecipients\":[{{\"emailAddress\":{{\"address\":\"{s}\"}}}}]}}}}",
                            .{ subject, body_text, to },
                        ) catch continue;
                        defer allocator.free(json_body);

                        // Send the email via Graph API.
                        _ = graph.post(allocator, io, token, "/me/sendMail", json_body) catch |err| {
                            std.debug.print("ms-mcp: send-email failed: {}\n", .{err});
                            const content: []const types.TextContent = &.{
                                .{ .text = "Failed to send email." },
                            };
                            const result = types.ToolCallResult{ .content = content };
                            sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                                .id = getRequestId(parsed.value),
                                .result = result,
                            });
                            continue;
                        };

                        // Success!
                        const msg = std.fmt.allocPrint(
                            allocator,
                            "Email sent to {s}.",
                            .{to},
                        ) catch continue;
                        defer allocator.free(msg);

                        const content: []const types.TextContent = &.{
                            .{ .text = msg },
                        };
                        const result = types.ToolCallResult{ .content = content };
                        sendJsonResponse(writer, types.JsonRpcResponse(types.ToolCallResult){
                            .id = getRequestId(parsed.value),
                            .result = result,
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
                    .{
                        .name = "verify-login",
                        .description = "Complete the login flow after entering the device code in the browser. Call login first.",
                        .inputSchema = .{},
                    },
                    .{
                        .name = "list-emails",
                        .description = "List the 10 most recent emails from your Microsoft 365 inbox.",
                        .inputSchema = .{},
                    },
                    .{
                        .name = "send-email",
                        .description = "Send an email. Required arguments: to (email address), subject, body.",
                        .inputSchema = .{},
                    },
                } },
                });
            }
        }
    }
}
