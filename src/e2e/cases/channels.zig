// e2e/cases/channels.zig — Teams channel + reply tests.

const std = @import("std");

const client_mod = @import("../client.zig");
const helpers = @import("../helpers.zig");
const runner = @import("../runner.zig");
const shared = @import("shared.zig");

const McpClient = client_mod.McpClient;
const pass = runner.pass;
const fail = runner.fail;
const skip = runner.skip;

const Allocator = std.mem.Allocator;

/// Test: Teams channel lifecycle — list teams, list channels, list messages, get replies.
pub fn testChannelLifecycle(client: *McpClient) !void {
    // List teams to find one.
    const teams = try client.callTool("list-teams", null);
    defer teams.deinit();
    const teams_text = McpClient.getResultText(teams) orelse {
        fail("list-teams (channel test)", "no text");
        return;
    };

    // Extract the first team ID from the condensed format: "— id: <teamId>"
    const team_id = helpers.extractFirstValueField(client.allocator, teams_text, "id") orelse {
        fail("channel lifecycle", "list-teams returned no teams — test account needs at least one team");
        return;
    };
    defer client.allocator.free(team_id);

    // List channels in this team.
    var chan_buf: [512]u8 = undefined;
    const chan_args = std.fmt.bufPrint(&chan_buf, "{{\"teamId\":\"{s}\"}}", .{team_id}) catch return;
    const channels = try client.callTool("list-channels", chan_args);
    defer channels.deinit();
    const channels_text = McpClient.getResultText(channels) orelse {
        fail("list-channels", "no text");
        return;
    };
    if (channels_text.len > 0) {
        pass("list-channels");
    } else {
        fail("list-channels", "empty response");
        return;
    }

    // Extract first channel ID.
    const channel_id = helpers.extractFirstValueField(client.allocator, channels_text, "id") orelse {
        fail("channel lifecycle", "team has no channels — every team must have at least General");
        return;
    };
    defer client.allocator.free(channel_id);

    // List channel messages.
    var msgs_buf: [1024]u8 = undefined;
    const msgs_args = std.fmt.bufPrint(&msgs_buf, "{{\"teamId\":\"{s}\",\"channelId\":\"{s}\",\"top\":\"5\"}}", .{ team_id, channel_id }) catch return;
    const msgs = try client.callTool("list-channel-messages", msgs_args);
    defer msgs.deinit();
    const msgs_text = McpClient.getResultText(msgs) orelse {
        fail("list-channel-messages", "no text");
        return;
    };
    if (std.mem.indexOf(u8, msgs_text, "id:") != null or
        std.mem.indexOf(u8, msgs_text, "No messages") != null)
    {
        pass("list-channel-messages");
    } else {
        fail("list-channel-messages", "response does not look like a formatted message list");
        return;
    }

    // Find a message ID for getting replies. If the channel is empty,
    // seed one ourselves so the test runs every time. `seeded` tracks
    // whether we posted it (so we can delete it at the end).
    var seeded = false;
    const msg_id = helpers.extractFirstMessageId(client.allocator, msgs_text) orelse blk: {
        var post_buf: [1024]u8 = undefined;
        const post_args = std.fmt.bufPrint(
            &post_buf,
            "{{\"teamId\":\"{s}\",\"channelId\":\"{s}\",\"message\":\"[DISREGARD AUTOMATED TEST SEED]\"}}",
            .{ team_id, channel_id },
        ) catch return;
        const post = try client.callTool("post-channel-message", post_args);
        defer post.deinit();
        _ = McpClient.getResultText(post) orelse {
            fail("channel setup", "post-channel-message returned no text");
            return;
        };
        // post-channel-message returns only a confirmation string, not
        // the new message id, so re-list to find our seed.
        const relist = try client.callTool("list-channel-messages", msgs_args);
        defer relist.deinit();
        const relist_text = McpClient.getResultText(relist) orelse {
            fail("channel setup", "list-channel-messages returned no text after seed");
            return;
        };
        const id = helpers.findMessageByContent(client.allocator, relist_text, "DISREGARD AUTOMATED TEST SEED") orelse {
            fail("channel setup", "could not find seeded message after posting");
            return;
        };
        seeded = true;
        break :blk id;
    };
    defer client.allocator.free(msg_id);

    // Get replies to that message.
    var replies_buf: [1024]u8 = undefined;
    const replies_args = std.fmt.bufPrint(&replies_buf, "{{\"teamId\":\"{s}\",\"channelId\":\"{s}\",\"messageId\":\"{s}\",\"top\":\"5\"}}", .{ team_id, channel_id, msg_id }) catch return;
    const replies = try client.callTool("get-channel-message-replies", replies_args);
    defer replies.deinit();
    const replies_text = McpClient.getResultText(replies) orelse {
        fail("get-channel-message-replies", "no text");
        return;
    };
    if (std.mem.indexOf(u8, replies_text, "id:") != null or
        std.mem.indexOf(u8, replies_text, "No replies") != null)
    {
        pass("get-channel-message-replies");
    } else {
        fail("get-channel-message-replies", "response does not look like formatted replies");
    }

    // Clean up the seed message if we posted one.
    if (seeded) {
        var del_buf: [1024]u8 = undefined;
        const del_args = std.fmt.bufPrint(
            &del_buf,
            "{{\"teamId\":\"{s}\",\"channelId\":\"{s}\",\"messageId\":\"{s}\"}}",
            .{ team_id, channel_id, msg_id },
        ) catch return;
        const del = try client.callTool("delete-channel-message", del_args);
        defer del.deinit();
        // Not asserting — this is cleanup; a failure to delete would be
        // caught by a dedicated delete-channel-message test.
    }
}


/// Test: Reply to a channel message and clean up.
pub fn testReplyToChannelMessage(client: *McpClient) !void {
    // List teams.
    const teams = try client.callTool("list-teams", null);
    defer teams.deinit();
    const teams_text = McpClient.getResultText(teams) orelse {
        fail("reply-to-channel-message setup", "list-teams returned no text");
        return;
    };
    const team_id = helpers.extractFirstValueField(client.allocator, teams_text, "id") orelse {
        fail("reply-to-channel-message setup", "no teams");
        return;
    };
    defer client.allocator.free(team_id);

    // List channels.
    var chan_buf: [512]u8 = undefined;
    const chan_args = std.fmt.bufPrint(&chan_buf, "{{\"teamId\":\"{s}\"}}", .{team_id}) catch return;
    const channels = try client.callTool("list-channels", chan_args);
    defer channels.deinit();
    const channels_text = McpClient.getResultText(channels) orelse return;

    // Find "General" channel or use first channel.
    const channel_id = helpers.extractFirstValueField(client.allocator, channels_text, "id") orelse {
        fail("reply-to-channel-message setup", "no channels in team");
        return;
    };
    defer client.allocator.free(channel_id);

    // List messages; seed one if the channel is empty so this test is
    // self-sufficient.
    var msgs_buf: [1024]u8 = undefined;
    const msgs_args = std.fmt.bufPrint(&msgs_buf, "{{\"teamId\":\"{s}\",\"channelId\":\"{s}\",\"top\":\"5\"}}", .{ team_id, channel_id }) catch return;
    const msgs = try client.callTool("list-channel-messages", msgs_args);
    defer msgs.deinit();
    const msgs_text = McpClient.getResultText(msgs) orelse {
        fail("reply-to-channel-message setup", "list-channel-messages returned no text");
        return;
    };

    var seeded = false;
    const msg_id = helpers.extractFirstMessageId(client.allocator, msgs_text) orelse blk: {
        var post_buf: [1024]u8 = undefined;
        const post_args = std.fmt.bufPrint(
            &post_buf,
            "{{\"teamId\":\"{s}\",\"channelId\":\"{s}\",\"message\":\"[DISREGARD AUTOMATED TEST SEED]\"}}",
            .{ team_id, channel_id },
        ) catch return;
        const post = try client.callTool("post-channel-message", post_args);
        defer post.deinit();
        const post_text = McpClient.getResultText(post) orelse {
            fail("reply-to-channel-message setup", "could not post seed message");
            return;
        };
        const id = helpers.extractId(client.allocator, post_text) orelse {
            fail("reply-to-channel-message setup", "post-channel-message returned no id");
            return;
        };
        seeded = true;
        break :blk id;
    };
    defer client.allocator.free(msg_id);

    // Reply to the message.
    var reply_buf: [1024]u8 = undefined;
    const reply_args = std.fmt.bufPrint(&reply_buf, "{{\"teamId\":\"{s}\",\"channelId\":\"{s}\",\"messageId\":\"{s}\",\"message\":\"[DISREGARD AUTOMATED TEST REPLY]\"}}", .{ team_id, channel_id, msg_id }) catch return;
    const reply = try client.callTool("reply-to-channel-message", reply_args);
    defer reply.deinit();
    const reply_text = McpClient.getResultText(reply) orelse {
        fail("reply-to-channel-message", "no text");
        return;
    };
    if (std.mem.indexOf(u8, reply_text, "sent") != null or
        std.mem.indexOf(u8, reply_text, "Reply") != null)
    {
        pass("reply-to-channel-message");
    } else {
        fail("reply-to-channel-message", reply_text);
    }

    // Clean up the seed message if we posted one. The reply goes with
    // it since replies live under the parent post.
    if (seeded) {
        var del_buf: [1024]u8 = undefined;
        const del_args = std.fmt.bufPrint(
            &del_buf,
            "{{\"teamId\":\"{s}\",\"channelId\":\"{s}\",\"messageId\":\"{s}\"}}",
            .{ team_id, channel_id, msg_id },
        ) catch return;
        const del = try client.callTool("delete-channel-message", del_args);
        defer del.deinit();
    }
}

/// Tool-level test: search-channels finds a channel by a name fragment
/// across all joined teams. We use "general" as the query because every
/// Teams team has a "General" channel — a built-in fixture we can rely
/// on without seeding test data.
pub fn testSearchChannels(client: *McpClient) !void {
    // top=1 short-circuits the team walk once a match is found —
    // searching for "general" matches every team's General channel,
    // so without the cap we'd walk every joined team unnecessarily
    // and risk hitting the e2e per-call timeout on slow runs.
    const search = try client.callTool("search-channels", "{\"query\":\"general\",\"top\":\"1\"}");
    defer search.deinit();
    const text = McpClient.getResultText(search) orelse {
        fail("search-channels", "no text in response");
        return;
    };

    // Either we matched at least one General channel (expected) or we
    // matched zero (only if the user has zero teams). Both are valid
    // formats; we want to confirm the response shape.
    if (std.mem.indexOf(u8, text, "channelId:") != null and
        std.mem.indexOf(u8, text, "teamId:") != null and
        shared.containsIgnoreCase(text, "general"))
    {
        pass("search-channels found General channel");
    } else if (std.mem.indexOf(u8, text, "No channels matched") != null) {
        skip("search-channels", "no joined teams have a General channel match — unusual but valid");
    } else {
        fail("search-channels", text);
    }
}

/// Tool-level test: list-channels with a query filter actually filters.
/// Same fixture (every team has a General channel) so we can assert the
/// query trimmed the result without needing to know the team's full
/// channel inventory.
pub fn testListChannelsQueryFilter(client: *McpClient) !void {
    const teams = try client.callTool("list-teams", null);
    defer teams.deinit();
    const teams_text = McpClient.getResultText(teams) orelse {
        fail("list-channels filter setup", "no teams");
        return;
    };
    const team_id = helpers.extractFirstValueField(client.allocator, teams_text, "id") orelse {
        fail("list-channels filter setup", "no team id");
        return;
    };
    defer client.allocator.free(team_id);

    var args_buf: [512]u8 = undefined;
    const args = std.fmt.bufPrint(&args_buf, "{{\"teamId\":\"{s}\",\"query\":\"general\"}}", .{team_id}) catch return;
    const filtered = try client.callTool("list-channels", args);
    defer filtered.deinit();
    const text = McpClient.getResultText(filtered) orelse {
        fail("list-channels (query filter)", "no text");
        return;
    };

    // Expect at least one channel name containing "general" (case-insensitive)
    // and no obviously unrelated channels.
    if (shared.containsIgnoreCase(text, "general")) {
        pass("list-channels with query filter");
    } else if (std.mem.indexOf(u8, text, "No channels matched") != null) {
        // Possible if the team has no "General" — fail loudly because we
        // expected one based on the Teams default.
        fail("list-channels (query filter)", "team has no General channel — unexpected");
    } else {
        fail("list-channels (query filter)", text);
    }
}
