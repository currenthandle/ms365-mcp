// tools/registry.zig — Collects all tool definitions for the "tools/list" response.

const std = @import("std");
const types = @import("../types.zig");
const schema = @import("../schema.zig");

const ObjectMap = std.json.ObjectMap;

/// Build and return the complete list of tool definitions for all MCP tools.
/// Returns null if any allocation fails during schema construction.
/// `catch return null` is used throughout because ObjectMap.put can fail on OOM.
pub fn allDefinitions(allocator: std.mem.Allocator) ?[]const types.ToolDefinition {

    // --- send-email schema ---
    var send_email_props = @as(ObjectMap, .empty);
    send_email_props.put(allocator, "to", schema.schemaProperty("array", "Array of recipient email addresses")) catch return null;
    send_email_props.put(allocator, "subject", schema.schemaProperty("string", "Email subject line")) catch return null;
    send_email_props.put(allocator, "body", schema.schemaProperty("string", "Email body text")) catch return null;
    send_email_props.put(allocator, "cc", schema.schemaProperty("array", "Optional array of CC email addresses")) catch return null;
    send_email_props.put(allocator, "bcc", schema.schemaProperty("array", "Optional array of BCC email addresses")) catch return null;

    // --- send-draft schema ---
    var send_draft_props = @as(ObjectMap, .empty);
    send_draft_props.put(allocator, "draftId", schema.schemaProperty("string", "The ID of the draft to send (from create-draft)")) catch return null;

    // --- update-draft schema ---
    var update_draft_props = @as(ObjectMap, .empty);
    update_draft_props.put(allocator, "draftId", schema.schemaProperty("string", "The ID of the draft to update (from create-draft)")) catch return null;
    update_draft_props.put(allocator, "subject", schema.schemaProperty("string", "New email subject line")) catch return null;
    update_draft_props.put(allocator, "body", schema.schemaProperty("string", "New email body text")) catch return null;
    update_draft_props.put(allocator, "to", schema.schemaProperty("array", "New array of recipient email addresses")) catch return null;
    update_draft_props.put(allocator, "cc", schema.schemaProperty("array", "New array of CC email addresses")) catch return null;
    update_draft_props.put(allocator, "bcc", schema.schemaProperty("array", "New array of BCC email addresses")) catch return null;

    // --- delete-draft schema ---
    var delete_draft_props = @as(ObjectMap, .empty);
    delete_draft_props.put(allocator, "draftId", schema.schemaProperty("string", "The ID of the draft to delete (from create-draft)")) catch return null;

    // --- add-attachment schema ---
    var add_attach_props = @as(ObjectMap, .empty);
    add_attach_props.put(allocator, "draftId", schema.schemaProperty("string", "The ID of the draft to attach to (from create-draft)")) catch return null;
    add_attach_props.put(allocator, "filePath", schema.schemaProperty("string", "Absolute path to the file on disk (e.g. '/Users/casey/report.pdf')")) catch return null;
    add_attach_props.put(allocator, "name", schema.schemaProperty("string", "Optional display name override (defaults to filename from path)")) catch return null;
    add_attach_props.put(allocator, "contentType", schema.schemaProperty("string", "Optional MIME type override (auto-detected from file extension)")) catch return null;
    add_attach_props.put(allocator, "isInline", schema.schemaProperty("boolean", "Set to true for inline/embedded images referenced in HTML body via cid:")) catch return null;
    add_attach_props.put(allocator, "contentId", schema.schemaProperty("string", "Content ID for inline images — referenced in HTML body as <img src=\"cid:THIS_VALUE\">")) catch return null;

    // --- list-attachments schema ---
    var list_attach_props = @as(ObjectMap, .empty);
    list_attach_props.put(allocator, "draftId", schema.schemaProperty("string", "The ID of the draft to list attachments for")) catch return null;

    // --- remove-attachment schema ---
    var remove_attach_props = @as(ObjectMap, .empty);
    remove_attach_props.put(allocator, "draftId", schema.schemaProperty("string", "The ID of the draft containing the attachment")) catch return null;
    remove_attach_props.put(allocator, "attachmentId", schema.schemaProperty("string", "The ID of the attachment to remove (from list-attachments)")) catch return null;

    // --- list-chats schema ---
    var list_chats_props = @as(ObjectMap, .empty);
    list_chats_props.put(allocator, "top", schema.schemaProperty("string", "Number of chats to return per page (1-50, default 50)")) catch return null;
    list_chats_props.put(allocator, "pageToken", schema.schemaProperty("string", "Pagination token — pass the nextLink value from a previous response to get the next page")) catch return null;

    // --- list-chat-messages schema ---
    var chat_msgs_props = @as(ObjectMap, .empty);
    chat_msgs_props.put(allocator, "chatId", schema.schemaProperty("string", "The ID of the chat to read messages from")) catch return null;
    chat_msgs_props.put(allocator, "top", schema.schemaProperty("string", "Number of messages to return per page (1-50, default 50)")) catch return null;
    chat_msgs_props.put(allocator, "pageToken", schema.schemaProperty("string", "Pagination token — pass the nextLink value from a previous response to get the next page")) catch return null;

    // --- search-users schema ---
    var search_users_props = @as(ObjectMap, .empty);
    search_users_props.put(allocator, "query", schema.schemaProperty("string", "Person's name to search for (e.g. 'Berry Cheung')")) catch return null;

    // --- create-chat schema ---
    var create_chat_props = @as(ObjectMap, .empty);
    create_chat_props.put(allocator, "emailOne", schema.schemaProperty("string", "First member's email address (use search-users to find it)")) catch return null;
    create_chat_props.put(allocator, "emailTwo", schema.schemaProperty("string", "Second member's email address")) catch return null;

    // --- list-channels schema ---
    var list_channels_props = @as(ObjectMap, .empty);
    list_channels_props.put(allocator, "teamId", schema.schemaProperty("string", "The ID of the team (from list-teams)")) catch return null;

    // --- list-channel-messages schema ---
    var list_chan_msgs_props = @as(ObjectMap, .empty);
    list_chan_msgs_props.put(allocator, "teamId", schema.schemaProperty("string", "The ID of the team (from list-teams)")) catch return null;
    list_chan_msgs_props.put(allocator, "channelId", schema.schemaProperty("string", "The ID of the channel (from list-channels)")) catch return null;
    list_chan_msgs_props.put(allocator, "top", schema.schemaProperty("string", "Number of messages to return per page (1-50, default 50)")) catch return null;
    list_chan_msgs_props.put(allocator, "pageToken", schema.schemaProperty("string", "Pagination token — pass the nextLink value from a previous response to get the next page")) catch return null;

    // --- get-channel-message-replies schema ---
    var chan_replies_props = @as(ObjectMap, .empty);
    chan_replies_props.put(allocator, "teamId", schema.schemaProperty("string", "The ID of the team (from list-teams)")) catch return null;
    chan_replies_props.put(allocator, "channelId", schema.schemaProperty("string", "The ID of the channel (from list-channels)")) catch return null;
    chan_replies_props.put(allocator, "messageId", schema.schemaProperty("string", "The ID of the top-level message/post (from list-channel-messages)")) catch return null;
    chan_replies_props.put(allocator, "top", schema.schemaProperty("string", "Number of replies to return per page (1-50, default 50)")) catch return null;
    chan_replies_props.put(allocator, "pageToken", schema.schemaProperty("string", "Pagination token — pass the nextLink value from a previous response to get the next page")) catch return null;

    // --- post-channel-message schema ---
    var post_chan_props = @as(ObjectMap, .empty);
    post_chan_props.put(allocator, "teamId", schema.schemaProperty("string", "The ID of the team (from list-teams)")) catch return null;
    post_chan_props.put(allocator, "channelId", schema.schemaProperty("string", "The ID of the channel (from list-channels)")) catch return null;
    post_chan_props.put(allocator, "message", schema.schemaProperty("string", "The message text to post. Use @Name for mentions (requires mentions parameter).")) catch return null;
    post_chan_props.put(allocator, "subject", schema.schemaProperty("string", "Optional subject/title for the channel post")) catch return null;
    post_chan_props.put(allocator, "mentions", schema.schemaProperty("string", "Optional comma-separated mention list: 'DisplayName|userId,Name2|userId2'. The userId is the Azure AD user ID found in from.user.id of channel messages. Each @Name in the message text will become a clickable Teams mention.")) catch return null;

    // --- reply-to-channel-message schema ---
    var chan_reply_props = @as(ObjectMap, .empty);
    chan_reply_props.put(allocator, "teamId", schema.schemaProperty("string", "The ID of the team (from list-teams)")) catch return null;
    chan_reply_props.put(allocator, "channelId", schema.schemaProperty("string", "The ID of the channel (from list-channels)")) catch return null;
    chan_reply_props.put(allocator, "messageId", schema.schemaProperty("string", "The ID of the top-level message/post to reply to (from list-channel-messages)")) catch return null;
    chan_reply_props.put(allocator, "message", schema.schemaProperty("string", "The reply text with @Name for each person to mention (e.g. 'Hey @Rohit check this out')")) catch return null;
    chan_reply_props.put(allocator, "mentions", schema.schemaProperty("string", "Optional comma-separated mention list: 'DisplayName|userId,Name2|userId2'. The userId is the Azure AD user ID found in from.user.id of channel messages. Each @Name in the message text will become a clickable Teams mention.")) catch return null;

    // --- delete-email schema ---
    var delete_email_props = @as(ObjectMap, .empty);
    delete_email_props.put(allocator, "emailId", schema.schemaProperty("string", "The ID of the email to delete (from list-emails or read-email)")) catch return null;

    // --- delete-chat-message schema ---
    var delete_chat_msg_props = @as(ObjectMap, .empty);
    delete_chat_msg_props.put(allocator, "chatId", schema.schemaProperty("string", "The ID of the chat containing the message")) catch return null;
    delete_chat_msg_props.put(allocator, "messageId", schema.schemaProperty("string", "The ID of the message to delete")) catch return null;

    // --- delete-channel-message schema ---
    var delete_chan_msg_props = @as(ObjectMap, .empty);
    delete_chan_msg_props.put(allocator, "teamId", schema.schemaProperty("string", "The ID of the team")) catch return null;
    delete_chan_msg_props.put(allocator, "channelId", schema.schemaProperty("string", "The ID of the channel")) catch return null;
    delete_chan_msg_props.put(allocator, "messageId", schema.schemaProperty("string", "The ID of the message to delete")) catch return null;

    // --- delete-channel-reply schema ---
    var delete_chan_reply_props = @as(ObjectMap, .empty);
    delete_chan_reply_props.put(allocator, "teamId", schema.schemaProperty("string", "The ID of the team")) catch return null;
    delete_chan_reply_props.put(allocator, "channelId", schema.schemaProperty("string", "The ID of the channel")) catch return null;
    delete_chan_reply_props.put(allocator, "messageId", schema.schemaProperty("string", "The ID of the parent message")) catch return null;
    delete_chan_reply_props.put(allocator, "replyId", schema.schemaProperty("string", "The ID of the reply to delete")) catch return null;

    // --- update-calendar-event schema ---
    var cal_update_props = @as(ObjectMap, .empty);
    cal_update_props.put(allocator, "eventId", schema.schemaProperty("string", "The ID of the event to update (from list-calendar-events)")) catch return null;
    cal_update_props.put(allocator, "subject", schema.schemaProperty("string", "New event title/subject")) catch return null;
    cal_update_props.put(allocator, "startDateTime", schema.schemaProperty("string", "New start time in ISO 8601 format")) catch return null;
    cal_update_props.put(allocator, "endDateTime", schema.schemaProperty("string", "New end time in ISO 8601 format")) catch return null;
    cal_update_props.put(allocator, "body", schema.schemaProperty("string", "New event body/description text")) catch return null;
    cal_update_props.put(allocator, "location", schema.schemaProperty("string", "New location name")) catch return null;

    // --- delete-calendar-event schema ---
    var cal_delete_props = @as(ObjectMap, .empty);
    cal_delete_props.put(allocator, "eventId", schema.schemaProperty("string", "The ID of the event to delete (from list-calendar-events)")) catch return null;

    // --- create-calendar-event schema ---
    var cal_create_props = @as(ObjectMap, .empty);
    cal_create_props.put(allocator, "subject", schema.schemaProperty("string", "Event title/subject")) catch return null;
    cal_create_props.put(allocator, "startDateTime", schema.schemaProperty("string", "Start time in ISO 8601 format (e.g. 2026-02-24T09:00:00)")) catch return null;
    cal_create_props.put(allocator, "endDateTime", schema.schemaProperty("string", "End time in ISO 8601 format (e.g. 2026-02-24T10:00:00)")) catch return null;
    cal_create_props.put(allocator, "body", schema.schemaProperty("string", "Optional event body/description text")) catch return null;
    cal_create_props.put(allocator, "location", schema.schemaProperty("string", "Optional location name")) catch return null;
    cal_create_props.put(allocator, "attendees", schema.schemaProperty("array", "Optional array of required attendee email addresses")) catch return null;
    cal_create_props.put(allocator, "optionalAttendees", schema.schemaProperty("array", "Optional array of optional attendee email addresses")) catch return null;

    // --- get-calendar-event schema ---
    var cal_get_props = @as(ObjectMap, .empty);
    cal_get_props.put(allocator, "eventId", schema.schemaProperty("string", "The ID of the calendar event to fetch (from list-calendar-events)")) catch return null;

    // --- list-calendar-events schema ---
    var cal_list_props = @as(ObjectMap, .empty);
    cal_list_props.put(allocator, "startDateTime", schema.schemaProperty("string", "Start of date range in local time, ISO 8601 format (e.g. 2026-02-23T00:00:00)")) catch return null;
    cal_list_props.put(allocator, "endDateTime", schema.schemaProperty("string", "End of date range in local time, ISO 8601 format (e.g. 2026-02-24T00:00:00)")) catch return null;

    // --- read-email schema ---
    var read_email_props = @as(ObjectMap, .empty);
    read_email_props.put(allocator, "emailId", schema.schemaProperty("string", "The ID of the email to read (from list-emails results)")) catch return null;

    // --- send-chat-message schema ---
    var send_chat_props = @as(ObjectMap, .empty);
    send_chat_props.put(allocator, "chatId", schema.schemaProperty("string", "The ID of the chat to send the message to")) catch return null;
    send_chat_props.put(allocator, "message", schema.schemaProperty("string", "The message text to send")) catch return null;

    // ---------------------------------------------------------------
    // Assemble the full tools array.
    // Grouped by category: Calendar, Email, Teams Chat, then Utility.
    // Most-used tools first within each group.
    // ---------------------------------------------------------------
    // Build the array as a local constant, then dupe it onto the heap.
    // We can't return &local_array because the inputSchema fields contain
    // runtime-allocated ObjectMaps, which prevents Zig from placing the
    // array in static memory — it would live on the stack and become a
    // dangling pointer after this function returns.
    const local_tools = [_]types.ToolDefinition{
        // --- Calendar ---
        .{
            .name = "create-calendar-event",
            .description = "Create a calendar event or meeting on Microsoft 365 / Teams / Outlook. Pass times in local time \u{2014} the server handles timezone automatically. Supports subject, start/end times, body, location, required attendees, and optional attendees.",
            .inputSchema = schema.buildSchema(cal_create_props, &.{ "subject", "startDateTime", "endDateTime" }),
        },
        .{
            .name = "list-calendar-events",
            .description = "List calendar events and meetings from Microsoft 365 / Teams / Outlook in a date range. Use this to check what's on the calendar. Pass startDateTime and endDateTime in local time (e.g. 2026-02-24T00:00:00 to 2026-02-25T00:00:00 for a full day). Expands recurring events. Results are in the user's local timezone.",
            .inputSchema = schema.buildSchema(cal_list_props, &.{ "startDateTime", "endDateTime" }),
        },
        .{
            .name = "get-calendar-event",
            .description = "Get full details of a calendar event or meeting by ID. Returns subject, start/end, location, body, attendees, and organizer.",
            .inputSchema = schema.buildSchema(cal_get_props, &.{"eventId"}),
        },
        .{
            .name = "update-calendar-event",
            .description = "Update a calendar event or meeting. Only provide the fields you want to change. Pass times in local time \u{2014} the server handles timezone automatically.",
            .inputSchema = schema.buildSchema(cal_update_props, &.{"eventId"}),
        },
        .{
            .name = "delete-calendar-event",
            .description = "Delete a calendar event or meeting by ID.",
            .inputSchema = schema.buildSchema(cal_delete_props, &.{"eventId"}),
        },
        // --- Email ---
        .{
            .name = "list-emails",
            .description = "List recent emails from Microsoft 365 Outlook inbox. Returns subject, sender, date, and preview for the 10 most recent messages.",
            .inputSchema = schema.emptySchema(),
        },
        .{
            .name = "read-email",
            .description = "Read the full content of an email by ID. Returns subject, sender, recipients, CC, date, full body, and read status. Use list-emails first to get the email ID.",
            .inputSchema = schema.buildSchema(read_email_props, &.{"emailId"}),
        },
        .{
            .name = "send-email",
            .description = "Send an email via Microsoft 365 Outlook. Supports multiple recipients, CC, and BCC.",
            .inputSchema = schema.buildSchema(send_email_props, &.{ "to", "subject", "body" }),
        },
        .{
            .name = "create-draft",
            .description = "Create a draft email in Microsoft 365 Outlook. Saves to Drafts folder without sending. Supports multiple recipients, CC, and BCC.",
            .inputSchema = schema.buildSchema(send_email_props, &.{ "to", "subject", "body" }),
        },
        .{
            .name = "send-draft",
            .description = "Send a previously created draft email by its ID.",
            .inputSchema = schema.buildSchema(send_draft_props, &.{"draftId"}),
        },
        .{
            .name = "update-draft",
            .description = "Update a draft email. Only provide the fields you want to change (subject, body, to, cc, bcc).",
            .inputSchema = schema.buildSchema(update_draft_props, &.{"draftId"}),
        },
        .{
            .name = "delete-draft",
            .description = "Delete a draft email by its ID.",
            .inputSchema = schema.buildSchema(delete_draft_props, &.{"draftId"}),
        },
        .{
            .name = "add-attachment",
            .description = "Add a file attachment to a draft email. Reads the file from disk \u{2014} just provide the file path. Name and MIME type are auto-detected.",
            .inputSchema = schema.buildSchema(add_attach_props, &.{ "draftId", "filePath" }),
        },
        .{
            .name = "list-attachments",
            .description = "List attachments on a draft email. Returns attachment IDs, names, and sizes.",
            .inputSchema = schema.buildSchema(list_attach_props, &.{"draftId"}),
        },
        .{
            .name = "remove-attachment",
            .description = "Remove an attachment from a draft email by its attachment ID.",
            .inputSchema = schema.buildSchema(remove_attach_props, &.{ "draftId", "attachmentId" }),
        },
        // --- Teams Chat ---
        .{
            .name = "list-chats",
            .description = "List Microsoft Teams chats including 1:1 conversations, group chats, and meeting chats. Supports pagination — pass the nextLink from the response as pageToken to get the next page. Use 'top' to control page size (1-50, default 50).",
            .inputSchema = schema.buildSchema(list_chats_props, &.{}),
        },
        .{
            .name = "list-chat-messages",
            .description = "List messages in a Microsoft Teams chat by chat ID. Supports pagination — pass the nextLink from the response as pageToken to get the next page. Use 'top' to control page size (1-50, default 50).",
            .inputSchema = schema.buildSchema(chat_msgs_props, &.{"chatId"}),
        },
        .{
            .name = "send-chat-message",
            .description = "Send a message in a Microsoft Teams chat.",
            .inputSchema = schema.buildSchema(send_chat_props, &.{ "chatId", "message" }),
        },
        .{
            .name = "create-chat",
            .description = "Create or find an existing 1:1 Microsoft Teams chat between two users by email address.",
            .inputSchema = schema.buildSchema(create_chat_props, &.{ "emailOne", "emailTwo" }),
        },
        // --- Teams Channels ---
        .{
            .name = "list-teams",
            .description = "List Microsoft Teams teams you are a member of. Returns team names and IDs. Use this to find a team before listing its channels.",
            .inputSchema = schema.emptySchema(),
        },
        .{
            .name = "list-channels",
            .description = "List channels in a Microsoft Teams team. Returns channel names and IDs. Use list-teams first to get the teamId.",
            .inputSchema = schema.buildSchema(list_channels_props, &.{"teamId"}),
        },
        .{
            .name = "list-channel-messages",
            .description = "List top-level posts in a Microsoft Teams channel. Returns posts only, NOT replies — use get-channel-message-replies to read replies to a specific post. Supports pagination via pageToken. Use 'top' to control page size (1-50, default 50).",
            .inputSchema = schema.buildSchema(list_chan_msgs_props, &.{ "teamId", "channelId" }),
        },
        .{
            .name = "get-channel-message-replies",
            .description = "Get replies to a specific post in a Microsoft Teams channel. Use this when checking if someone has replied to a post. Supports pagination via pageToken. Use list-channel-messages first to find the messageId.",
            .inputSchema = schema.buildSchema(chan_replies_props, &.{ "teamId", "channelId", "messageId" }),
        },
        .{
            .name = "post-channel-message",
            .description = "Post a new message to a Microsoft Teams channel. Supports @mentions and an optional subject line. Use list-teams then list-channels to get the IDs.",
            .inputSchema = schema.buildSchema(post_chan_props, &.{ "teamId", "channelId", "message" }),
        },
        .{
            .name = "reply-to-channel-message",
            .description = "Reply to a message thread in a Microsoft Teams channel. Supports @mentions — pass the mentions parameter with 'DisplayName|userId' pairs and use @Name in the message text. Get user IDs from the from.user.id field in channel message replies.",
            .inputSchema = schema.buildSchema(chan_reply_props, &.{ "teamId", "channelId", "messageId", "message" }),
        },
        // --- Delete / Cleanup ---
        .{
            .name = "delete-email",
            .description = "Delete an email by ID. Moves the email to the Deleted Items folder.",
            .inputSchema = schema.buildSchema(delete_email_props, &.{"emailId"}),
        },
        .{
            .name = "delete-chat-message",
            .description = "Soft-delete a message in a Teams chat. The message will show as 'This message has been deleted'.",
            .inputSchema = schema.buildSchema(delete_chat_msg_props, &.{ "chatId", "messageId" }),
        },
        .{
            .name = "delete-channel-message",
            .description = "Soft-delete a message in a Teams channel. The message will show as 'This message has been deleted'.",
            .inputSchema = schema.buildSchema(delete_chan_msg_props, &.{ "teamId", "channelId", "messageId" }),
        },
        .{
            .name = "delete-channel-reply",
            .description = "Soft-delete a reply to a message in a Teams channel.",
            .inputSchema = schema.buildSchema(delete_chan_reply_props, &.{ "teamId", "channelId", "messageId", "replyId" }),
        },
        // --- Utility ---
        .{
            .name = "search-users",
            .description = "Search for people in your Microsoft 365 organization by name. Returns display names and email addresses. Use this to find someone's email address.",
            .inputSchema = schema.buildSchema(search_users_props, &.{"query"}),
        },
        .{
            .name = "get-profile",
            .description = "Get the logged-in user's Microsoft 365 profile including display name and email.",
            .inputSchema = schema.emptySchema(),
        },
        .{
            .name = "login",
            .description = "Log in to Microsoft 365. Starts the OAuth device code authentication flow. Returns a code to enter at the Microsoft login page.",
            .inputSchema = schema.emptySchema(),
        },
        .{
            .name = "verify-login",
            .description = "Complete the Microsoft 365 login. Polls for authentication after the user enters the device code. Call login first.",
            .inputSchema = schema.emptySchema(),
        },
        .{
            .name = "get-mailbox-settings",
            .description = "Get the user's Microsoft 365 mailbox settings including timezone, language, and date format.",
            .inputSchema = schema.emptySchema(),
        },
        .{
            .name = "sync-timezone",
            .description = "Sync the Microsoft 365 mailbox timezone to match this computer's system timezone. Run after traveling to a new timezone.",
            .inputSchema = schema.emptySchema(),
        },
    };

    return allocator.dupe(types.ToolDefinition, &local_tools) catch return null;
}
