// tools/registry.zig — Collects all tool definitions for the "tools/list" response.

const std = @import("std");
const types = @import("../types.zig");
const schema = @import("../schema.zig");

/// Build and return the complete list of tool definitions for all MCP tools.
/// Returns null if any allocation fails during schema construction.
/// `catch return null` is used throughout because ObjectMap.put can fail on OOM.
pub fn allDefinitions(allocator: std.mem.Allocator) ?[]const types.ToolDefinition {

    // --- send-email schema ---
    var send_email_props = std.json.ObjectMap.init(allocator);
    send_email_props.put("to", schema.schemaProperty("array", "Array of recipient email addresses")) catch return null;
    send_email_props.put("subject", schema.schemaProperty("string", "Email subject line")) catch return null;
    send_email_props.put("body", schema.schemaProperty("string", "Email body text")) catch return null;
    send_email_props.put("cc", schema.schemaProperty("array", "Optional array of CC email addresses")) catch return null;
    send_email_props.put("bcc", schema.schemaProperty("array", "Optional array of BCC email addresses")) catch return null;

    // --- send-draft schema ---
    var send_draft_props = std.json.ObjectMap.init(allocator);
    send_draft_props.put("draftId", schema.schemaProperty("string", "The ID of the draft to send (from create-draft)")) catch return null;

    // --- update-draft schema ---
    var update_draft_props = std.json.ObjectMap.init(allocator);
    update_draft_props.put("draftId", schema.schemaProperty("string", "The ID of the draft to update (from create-draft)")) catch return null;
    update_draft_props.put("subject", schema.schemaProperty("string", "New email subject line")) catch return null;
    update_draft_props.put("body", schema.schemaProperty("string", "New email body text")) catch return null;
    update_draft_props.put("to", schema.schemaProperty("array", "New array of recipient email addresses")) catch return null;
    update_draft_props.put("cc", schema.schemaProperty("array", "New array of CC email addresses")) catch return null;
    update_draft_props.put("bcc", schema.schemaProperty("array", "New array of BCC email addresses")) catch return null;

    // --- delete-draft schema ---
    var delete_draft_props = std.json.ObjectMap.init(allocator);
    delete_draft_props.put("draftId", schema.schemaProperty("string", "The ID of the draft to delete (from create-draft)")) catch return null;

    // --- add-attachment schema ---
    var add_attach_props = std.json.ObjectMap.init(allocator);
    add_attach_props.put("draftId", schema.schemaProperty("string", "The ID of the draft to attach to (from create-draft)")) catch return null;
    add_attach_props.put("filePath", schema.schemaProperty("string", "Absolute path to the file on disk (e.g. '/Users/casey/report.pdf')")) catch return null;
    add_attach_props.put("name", schema.schemaProperty("string", "Optional display name override (defaults to filename from path)")) catch return null;
    add_attach_props.put("contentType", schema.schemaProperty("string", "Optional MIME type override (auto-detected from file extension)")) catch return null;
    add_attach_props.put("isInline", schema.schemaProperty("boolean", "Set to true for inline/embedded images referenced in HTML body via cid:")) catch return null;
    add_attach_props.put("contentId", schema.schemaProperty("string", "Content ID for inline images — referenced in HTML body as <img src=\"cid:THIS_VALUE\">")) catch return null;

    // --- list-attachments schema ---
    var list_attach_props = std.json.ObjectMap.init(allocator);
    list_attach_props.put("draftId", schema.schemaProperty("string", "The ID of the draft to list attachments for")) catch return null;

    // --- remove-attachment schema ---
    var remove_attach_props = std.json.ObjectMap.init(allocator);
    remove_attach_props.put("draftId", schema.schemaProperty("string", "The ID of the draft containing the attachment")) catch return null;
    remove_attach_props.put("attachmentId", schema.schemaProperty("string", "The ID of the attachment to remove (from list-attachments)")) catch return null;

    // --- list-chat-messages schema ---
    var chat_msgs_props = std.json.ObjectMap.init(allocator);
    chat_msgs_props.put("chatId", schema.schemaProperty("string", "The ID of the chat to read messages from")) catch return null;

    // --- search-users schema ---
    var search_users_props = std.json.ObjectMap.init(allocator);
    search_users_props.put("query", schema.schemaProperty("string", "Person's name to search for (e.g. 'Berry Cheung')")) catch return null;

    // --- create-chat schema ---
    var create_chat_props = std.json.ObjectMap.init(allocator);
    create_chat_props.put("emailOne", schema.schemaProperty("string", "First member's email address (use search-users to find it)")) catch return null;
    create_chat_props.put("emailTwo", schema.schemaProperty("string", "Second member's email address")) catch return null;

    // --- list-channels schema ---
    var list_channels_props = std.json.ObjectMap.init(allocator);
    list_channels_props.put("teamId", schema.schemaProperty("string", "The ID of the team (from list-teams)")) catch return null;

    // --- list-channel-messages schema ---
    var list_chan_msgs_props = std.json.ObjectMap.init(allocator);
    list_chan_msgs_props.put("teamId", schema.schemaProperty("string", "The ID of the team (from list-teams)")) catch return null;
    list_chan_msgs_props.put("channelId", schema.schemaProperty("string", "The ID of the channel (from list-channels)")) catch return null;

    // --- get-channel-message-replies schema ---
    var chan_replies_props = std.json.ObjectMap.init(allocator);
    chan_replies_props.put("teamId", schema.schemaProperty("string", "The ID of the team (from list-teams)")) catch return null;
    chan_replies_props.put("channelId", schema.schemaProperty("string", "The ID of the channel (from list-channels)")) catch return null;
    chan_replies_props.put("messageId", schema.schemaProperty("string", "The ID of the top-level message/post (from list-channel-messages)")) catch return null;

    // --- update-calendar-event schema ---
    var cal_update_props = std.json.ObjectMap.init(allocator);
    cal_update_props.put("eventId", schema.schemaProperty("string", "The ID of the event to update (from list-calendar-events)")) catch return null;
    cal_update_props.put("subject", schema.schemaProperty("string", "New event title/subject")) catch return null;
    cal_update_props.put("startDateTime", schema.schemaProperty("string", "New start time in ISO 8601 format")) catch return null;
    cal_update_props.put("endDateTime", schema.schemaProperty("string", "New end time in ISO 8601 format")) catch return null;
    cal_update_props.put("body", schema.schemaProperty("string", "New event body/description text")) catch return null;
    cal_update_props.put("location", schema.schemaProperty("string", "New location name")) catch return null;

    // --- delete-calendar-event schema ---
    var cal_delete_props = std.json.ObjectMap.init(allocator);
    cal_delete_props.put("eventId", schema.schemaProperty("string", "The ID of the event to delete (from list-calendar-events)")) catch return null;

    // --- create-calendar-event schema ---
    var cal_create_props = std.json.ObjectMap.init(allocator);
    cal_create_props.put("subject", schema.schemaProperty("string", "Event title/subject")) catch return null;
    cal_create_props.put("startDateTime", schema.schemaProperty("string", "Start time in ISO 8601 format (e.g. 2026-02-24T09:00:00)")) catch return null;
    cal_create_props.put("endDateTime", schema.schemaProperty("string", "End time in ISO 8601 format (e.g. 2026-02-24T10:00:00)")) catch return null;
    cal_create_props.put("body", schema.schemaProperty("string", "Optional event body/description text")) catch return null;
    cal_create_props.put("location", schema.schemaProperty("string", "Optional location name")) catch return null;
    cal_create_props.put("attendees", schema.schemaProperty("array", "Optional array of required attendee email addresses")) catch return null;
    cal_create_props.put("optionalAttendees", schema.schemaProperty("array", "Optional array of optional attendee email addresses")) catch return null;

    // --- get-calendar-event schema ---
    var cal_get_props = std.json.ObjectMap.init(allocator);
    cal_get_props.put("eventId", schema.schemaProperty("string", "The ID of the calendar event to fetch (from list-calendar-events)")) catch return null;

    // --- list-calendar-events schema ---
    var cal_list_props = std.json.ObjectMap.init(allocator);
    cal_list_props.put("startDateTime", schema.schemaProperty("string", "Start of date range in local time, ISO 8601 format (e.g. 2026-02-23T00:00:00)")) catch return null;
    cal_list_props.put("endDateTime", schema.schemaProperty("string", "End of date range in local time, ISO 8601 format (e.g. 2026-02-24T00:00:00)")) catch return null;

    // --- read-email schema ---
    var read_email_props = std.json.ObjectMap.init(allocator);
    read_email_props.put("emailId", schema.schemaProperty("string", "The ID of the email to read (from list-emails results)")) catch return null;

    // --- send-chat-message schema ---
    var send_chat_props = std.json.ObjectMap.init(allocator);
    send_chat_props.put("chatId", schema.schemaProperty("string", "The ID of the chat to send the message to")) catch return null;
    send_chat_props.put("message", schema.schemaProperty("string", "The message text to send")) catch return null;

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
            .description = "List recent Microsoft Teams chats including 1:1 conversations, group chats, and meeting chats.",
            .inputSchema = schema.emptySchema(),
        },
        .{
            .name = "list-chat-messages",
            .description = "List recent messages in a Microsoft Teams chat by chat ID.",
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
            .description = "List recent messages (posts) in a Microsoft Teams channel. These are channel conversations, not 1:1 chats. Use list-teams then list-channels to get the IDs. Each message has an 'id' field you can use with get-channel-message-replies to read the thread.",
            .inputSchema = schema.buildSchema(list_chan_msgs_props, &.{ "teamId", "channelId" }),
        },
        .{
            .name = "get-channel-message-replies",
            .description = "Get replies to a specific message thread in a Microsoft Teams channel. Use list-channel-messages first to find the messageId of the post you want replies for.",
            .inputSchema = schema.buildSchema(chan_replies_props, &.{ "teamId", "channelId", "messageId" }),
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
