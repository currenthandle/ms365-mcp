// e2e/cases/readonly.zig — Read-only smoke tests, one per simple endpoint.
//
// These don't mutate any state; they exist to verify auth + basic
// formatter output for the lowest-cost endpoints.

const std = @import("std");

const client_mod = @import("../client.zig");
const runner = @import("../runner.zig");

const McpClient = client_mod.McpClient;
const pass = runner.pass;
const fail = runner.fail;

/// Test: List emails (read-only, no cleanup needed).
pub fn testListEmails(client: *McpClient) !void {
    const parsed = try client.callTool("list-emails", null);
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        fail("list-emails", "no text in response");
        return;
    };

    // Formatter now returns "subject: ... | from: ... | ... | id: ..." per email.
    if (std.mem.indexOf(u8, text, "id:") != null or
        std.mem.indexOf(u8, text, "No emails") != null)
    {
        pass("list-emails");
    } else {
        fail("list-emails", "response does not look like a formatted email list");
    }
}

/// Test: List chats (read-only).
pub fn testListChats(client: *McpClient) !void {
    const parsed = try client.callTool("list-chats", null);
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        fail("list-chats", "no text in response");
        return;
    };

    if (text.len > 0) {
        pass("list-chats");
    } else {
        fail("list-chats", "empty response");
    }
}

/// Test: List teams (read-only).
pub fn testListTeams(client: *McpClient) !void {
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
pub fn testGetProfile(client: *McpClient) !void {
    const parsed = try client.callTool("get-profile", null);
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        fail("get-profile", "no text in response");
        return;
    };

    if (std.mem.indexOf(u8, text, "name:") != null and
        std.mem.indexOf(u8, text, "mail:") != null)
    {
        pass("get-profile");
    } else {
        fail("get-profile", "response doesn't look like a profile");
    }
}

/// Test: Search users (read-only).
pub fn testSearchUsers(client: *McpClient) !void {
    const parsed = try client.callTool("search-users", "{\"query\":\"test\"}");
    defer parsed.deinit();

    const text = McpClient.getResultText(parsed) orelse {
        fail("search-users", "no text in response");
        return;
    };

    if (std.mem.indexOf(u8, text, "id:") != null or
        std.mem.indexOf(u8, text, "No users") != null)
    {
        pass("search-users");
    } else {
        fail("search-users", "response does not look like a formatted user list");
    }
}

/// Test: get-mailbox-settings — verify the response includes timezone or language.
pub fn testGetMailboxSettings(client: *McpClient) !void {
    const parsed = try client.callTool("get-mailbox-settings", null);
    defer parsed.deinit();
    const text = McpClient.getResultText(parsed) orelse {
        fail("get-mailbox-settings", "no text");
        return;
    };
    if (std.mem.indexOf(u8, text, "timeZone") != null or
        std.mem.indexOf(u8, text, "language") != null)
    {
        pass("get-mailbox-settings");
    } else {
        fail("get-mailbox-settings", "response doesn't look like mailbox settings");
    }
}

/// Test: Sync timezone.
pub fn testSyncTimezone(client: *McpClient) !void {
    const parsed = try client.callTool("sync-timezone", null);
    defer parsed.deinit();
    const text = McpClient.getResultText(parsed) orelse {
        fail("sync-timezone", "no text");
        return;
    };
    // Should report either "synced" or an error about unknown timezone.
    if (std.mem.indexOf(u8, text, "synced") != null or
        std.mem.indexOf(u8, text, "Timezone") != null or
        std.mem.indexOf(u8, text, "timezone") != null)
    {
        pass("sync-timezone");
    } else {
        fail("sync-timezone", text);
    }
}
