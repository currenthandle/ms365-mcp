// e2e/cases/protocol.zig — Protocol handshake + auth tests.

const std = @import("std");

const client_mod = @import("../client.zig");
const runner = @import("../runner.zig");

const McpClient = client_mod.McpClient;
const pass = runner.pass;
const fail = runner.fail;

/// Test: MCP initialize handshake.
pub fn testInitialize(client: *McpClient) !void {
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
pub fn testCheckAuth(client: *McpClient) !bool {
    const parsed = try client.callTool("get-profile", null);
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        return false;
    };

    // get-profile now goes through the formatter, so the output is
    // "name: ... | mail: ... | upn: ... | id: ...", not raw JSON with
    // "displayName". If we see our own name: label plus the mail: label
    // (which only the formatter produces), the token is good.
    if (std.mem.indexOf(u8, text, "name:") != null and
        std.mem.indexOf(u8, text, "mail:") != null)
    {
        pass("auth (saved token valid)");
        return true;
    }
    std.debug.print("  ⓘ No valid saved token — will attempt login\n", .{});
    return false;
}

/// Test: Login via device code flow (interactive — requires user action).
pub fn testLogin(client: *McpClient) !bool {
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
        if (std.mem.indexOf(u8, profile_text, "name:") != null and
            std.mem.indexOf(u8, profile_text, "mail:") != null)
        {
            pass("login (authenticated via saved token)");
            return true;
        }
        fail("login", "still not authenticated after login");
        return false;
    }
}
