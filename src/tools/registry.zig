// tools/registry.zig — Collects all tool definitions for the "tools/list" response.
//
// Each tool is described as data: its name, its human-readable description,
// its list of input properties, and which properties are required. The
// `allDefinitions` function walks that data and builds the JSON Schema
// ObjectMaps used by the MCP client.
//
// Adding or modifying a tool should almost always mean editing only this file.

const std = @import("std");
const types = @import("../types.zig");
const schema = @import("../schema.zig");

const PropSpec = schema.PropSpec;

/// A tool as declared at the top of the file — no JSON objects yet.
/// `allDefinitions` converts each of these into a `types.ToolDefinition`.
const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    /// Input properties. Empty means the tool takes no arguments.
    props: []const PropSpec = &.{},
    /// Names of required properties (must all appear in `props`).
    required: []const []const u8 = &.{},
};

// --- Shared property fragments ---
// Pulled out because multiple tools reuse the same pagination and path arguments.

const top_prop = PropSpec{
    .name = "top",
    .type = "string",
    .description = "Number of chats to return per page (1-50, default 50)",
};

const page_token_prop = PropSpec{
    .name = "pageToken",
    .type = "string",
    .description = "Pagination token — pass the nextLink value from a previous response to get the next page",
};

const team_id_prop = PropSpec{
    .name = "teamId",
    .type = "string",
    .description = "The ID of the team (from list-teams)",
};

const channel_id_prop = PropSpec{
    .name = "channelId",
    .type = "string",
    .description = "The ID of the channel (from list-channels)",
};

// --- Per-tool input specs ---
// Ordered to match the tools array below so the file reads top-down.

const send_email_props = [_]PropSpec{
    .{ .name = "to", .type = "array", .description = "Array of recipient email addresses" },
    .{ .name = "subject", .type = "string", .description = "Email subject line" },
    .{ .name = "body", .type = "string", .description = "Email body text" },
    .{ .name = "cc", .type = "array", .description = "Optional array of CC email addresses" },
    .{ .name = "bcc", .type = "array", .description = "Optional array of BCC email addresses" },
};

const read_email_props = [_]PropSpec{
    .{ .name = "emailId", .type = "string", .description = "The ID of the email to read (from list-emails results)" },
};

const delete_email_props = [_]PropSpec{
    .{ .name = "emailId", .type = "string", .description = "The ID of the email to delete (from list-emails or read-email)" },
};

// --- Email action props (reply / forward / search / folders / mark / move / attachments) ---

const reply_email_props = [_]PropSpec{
    .{ .name = "emailId", .type = "string", .description = "The ID of the email to reply to (from list-emails or search-emails)" },
    .{ .name = "comment", .type = "string", .description = "The reply text to send" },
    .{ .name = "to", .type = "array", .description = "Optional additional recipients. Omit to reply only to the original sender." },
};

const reply_all_email_props = [_]PropSpec{
    .{ .name = "emailId", .type = "string", .description = "The ID of the email to reply-all to" },
    .{ .name = "comment", .type = "string", .description = "The reply text to send to everyone on the thread" },
};

const forward_email_props = [_]PropSpec{
    .{ .name = "emailId", .type = "string", .description = "The ID of the email to forward" },
    .{ .name = "comment", .type = "string", .description = "Optional text to include above the forwarded content (use empty string for none)" },
    .{ .name = "to", .type = "array", .description = "Recipients to forward to — required, at least one" },
};

const search_emails_props = [_]PropSpec{
    .{ .name = "query", .type = "string", .description = "Keyword or phrase to search for (matches subject, body, sender, and recipient fields)" },
};

const mark_read_email_props = [_]PropSpec{
    .{ .name = "emailId", .type = "string", .description = "The ID of the email to mark" },
    .{ .name = "isRead", .type = "boolean", .description = "Optional — true to mark read (default), false to mark unread" },
};

const move_email_props = [_]PropSpec{
    .{ .name = "emailId", .type = "string", .description = "The ID of the email to move" },
    .{ .name = "destinationId", .type = "string", .description = "Folder ID to move the email into (from list-mail-folders) — NOT the folder name" },
};

const list_email_attachments_props = [_]PropSpec{
    .{ .name = "emailId", .type = "string", .description = "The ID of the email whose attachments you want to list" },
};

const read_email_attachment_props = [_]PropSpec{
    .{ .name = "emailId", .type = "string", .description = "The ID of the email containing the attachment" },
    .{ .name = "attachmentId", .type = "string", .description = "The ID of the attachment (from list-email-attachments)" },
};

const send_draft_props = [_]PropSpec{
    .{ .name = "draftId", .type = "string", .description = "The ID of the draft to send (from create-draft)" },
};

const update_draft_props = [_]PropSpec{
    .{ .name = "draftId", .type = "string", .description = "The ID of the draft to update (from create-draft)" },
    .{ .name = "subject", .type = "string", .description = "New email subject line" },
    .{ .name = "body", .type = "string", .description = "New email body text" },
    .{ .name = "to", .type = "array", .description = "New array of recipient email addresses" },
    .{ .name = "cc", .type = "array", .description = "New array of CC email addresses" },
    .{ .name = "bcc", .type = "array", .description = "New array of BCC email addresses" },
};

const delete_draft_props = [_]PropSpec{
    .{ .name = "draftId", .type = "string", .description = "The ID of the draft to delete (from create-draft)" },
};

const add_attach_props = [_]PropSpec{
    .{ .name = "draftId", .type = "string", .description = "The ID of the draft to attach to (from create-draft)" },
    .{ .name = "filePath", .type = "string", .description = "Absolute path to the file on disk (e.g. '/Users/casey/report.pdf')" },
    .{ .name = "name", .type = "string", .description = "Optional display name override (defaults to filename from path)" },
    .{ .name = "contentType", .type = "string", .description = "Optional MIME type override (auto-detected from file extension)" },
    .{ .name = "isInline", .type = "boolean", .description = "Set to true for inline/embedded images referenced in HTML body via cid:" },
    .{ .name = "contentId", .type = "string", .description = "Content ID for inline images — referenced in HTML body as <img src=\"cid:THIS_VALUE\">" },
};

const list_attach_props = [_]PropSpec{
    .{ .name = "draftId", .type = "string", .description = "The ID of the draft to list attachments for" },
};

const remove_attach_props = [_]PropSpec{
    .{ .name = "draftId", .type = "string", .description = "The ID of the draft containing the attachment" },
    .{ .name = "attachmentId", .type = "string", .description = "The ID of the attachment to remove (from list-attachments)" },
};

const list_chats_props = [_]PropSpec{ top_prop, page_token_prop };

const chat_msgs_props = [_]PropSpec{
    .{ .name = "chatId", .type = "string", .description = "The ID of the chat to read messages from" },
    .{ .name = "top", .type = "string", .description = "Number of messages to return per page (1-50, default 50)" },
    page_token_prop,
};

const search_users_props = [_]PropSpec{
    .{ .name = "query", .type = "string", .description = "Person's name to search for (e.g. 'Berry Cheung')" },
};

const create_chat_props = [_]PropSpec{
    .{ .name = "emailOne", .type = "string", .description = "First member's email address (use search-users to find it)" },
    .{ .name = "emailTwo", .type = "string", .description = "Second member's email address" },
};

const list_channels_props = [_]PropSpec{team_id_prop};

const list_chan_msgs_props = [_]PropSpec{
    team_id_prop,
    channel_id_prop,
    .{ .name = "top", .type = "string", .description = "Number of messages to return per page (1-50, default 50)" },
    page_token_prop,
};

const chan_replies_props = [_]PropSpec{
    team_id_prop,
    channel_id_prop,
    .{ .name = "messageId", .type = "string", .description = "The ID of the top-level message/post (from list-channel-messages)" },
    .{ .name = "top", .type = "string", .description = "Number of replies to return per page (1-50, default 50)" },
    page_token_prop,
};

const mentions_desc = "Optional comma-separated mention list: 'DisplayName|userId,Name2|userId2'. The userId is the Azure AD user ID found in from.user.id of channel messages. Each @Name in the message text will become a clickable Teams mention.";

const post_chan_props = [_]PropSpec{
    team_id_prop,
    channel_id_prop,
    .{ .name = "message", .type = "string", .description = "The message text to post. Use @Name for mentions (requires mentions parameter)." },
    .{ .name = "subject", .type = "string", .description = "Optional subject/title for the channel post" },
    .{ .name = "mentions", .type = "string", .description = mentions_desc },
};

const chan_reply_props = [_]PropSpec{
    team_id_prop,
    channel_id_prop,
    .{ .name = "messageId", .type = "string", .description = "The ID of the top-level message/post to reply to (from list-channel-messages)" },
    .{ .name = "message", .type = "string", .description = "The reply text with @Name for each person to mention (e.g. 'Hey @Rohit check this out')" },
    .{ .name = "mentions", .type = "string", .description = mentions_desc },
};

const delete_chat_msg_props = [_]PropSpec{
    .{ .name = "chatId", .type = "string", .description = "The ID of the chat containing the message" },
    .{ .name = "messageId", .type = "string", .description = "The ID of the message to delete" },
};

const delete_chan_msg_props = [_]PropSpec{
    .{ .name = "teamId", .type = "string", .description = "The ID of the team" },
    .{ .name = "channelId", .type = "string", .description = "The ID of the channel" },
    .{ .name = "messageId", .type = "string", .description = "The ID of the message to delete" },
};

const delete_chan_reply_props = [_]PropSpec{
    .{ .name = "teamId", .type = "string", .description = "The ID of the team" },
    .{ .name = "channelId", .type = "string", .description = "The ID of the channel" },
    .{ .name = "messageId", .type = "string", .description = "The ID of the parent message" },
    .{ .name = "replyId", .type = "string", .description = "The ID of the reply to delete" },
};

const cal_update_props = [_]PropSpec{
    .{ .name = "eventId", .type = "string", .description = "The ID of the event to update (from list-calendar-events)" },
    .{ .name = "subject", .type = "string", .description = "New event title/subject" },
    .{ .name = "startDateTime", .type = "string", .description = "New start time in ISO 8601 format" },
    .{ .name = "endDateTime", .type = "string", .description = "New end time in ISO 8601 format" },
    .{ .name = "body", .type = "string", .description = "New event body/description text" },
    .{ .name = "location", .type = "string", .description = "New location name" },
};

const cal_delete_props = [_]PropSpec{
    .{ .name = "eventId", .type = "string", .description = "The ID of the event to delete (from list-calendar-events)" },
};

const cal_create_props = [_]PropSpec{
    .{ .name = "subject", .type = "string", .description = "Event title/subject" },
    .{ .name = "startDateTime", .type = "string", .description = "Start time in ISO 8601 format (e.g. 2026-02-24T09:00:00)" },
    .{ .name = "endDateTime", .type = "string", .description = "End time in ISO 8601 format (e.g. 2026-02-24T10:00:00)" },
    .{ .name = "body", .type = "string", .description = "Optional event body/description text" },
    .{ .name = "location", .type = "string", .description = "Optional location name" },
    .{ .name = "attendees", .type = "array", .description = "Optional array of required attendee email addresses" },
    .{ .name = "optionalAttendees", .type = "array", .description = "Optional array of optional attendee email addresses" },
};

const cal_get_props = [_]PropSpec{
    .{ .name = "eventId", .type = "string", .description = "The ID of the calendar event to fetch (from list-calendar-events)" },
};

const cal_list_props = [_]PropSpec{
    .{ .name = "startDateTime", .type = "string", .description = "Start of date range in local time, ISO 8601 format (e.g. 2026-02-23T00:00:00)" },
    .{ .name = "endDateTime", .type = "string", .description = "End of date range in local time, ISO 8601 format (e.g. 2026-02-24T00:00:00)" },
};

const send_chat_props = [_]PropSpec{
    .{ .name = "chatId", .type = "string", .description = "The ID of the chat to send the message to" },
    .{ .name = "message", .type = "string", .description = "The message text to send" },
};

// --- SharePoint props ---

const sp_site_id_prop = PropSpec{
    .name = "siteId",
    .type = "string",
    .description = "The ID of the SharePoint site (from search-sharepoint-sites)",
};

const sp_drive_id_prop = PropSpec{
    .name = "driveId",
    .type = "string",
    .description = "The ID of the document library (from list-sharepoint-drives)",
};

const sp_search_sites_props = [_]PropSpec{
    .{ .name = "query", .type = "string", .description = "Site name or keyword to search for" },
};

const sp_list_drives_props = [_]PropSpec{sp_site_id_prop};

const sp_list_items_props = [_]PropSpec{
    sp_site_id_prop,
    sp_drive_id_prop,
    .{ .name = "folderPath", .type = "string", .description = "Optional folder path relative to drive root (e.g. '2026/Q1'). Omit to list root." },
};

const sp_upload_file_props = [_]PropSpec{
    sp_site_id_prop,
    sp_drive_id_prop,
    .{ .name = "path", .type = "string", .description = "Destination path in the drive (e.g. '2026/Q1/report.pdf'). Must not start with '/' or contain '..'." },
    .{ .name = "filePath", .type = "string", .description = "Local absolute path to the file to upload (e.g. '/Users/casey/report.pdf')." },
    .{ .name = "contentType", .type = "string", .description = "Optional MIME type override. Auto-detected from extension if omitted." },
};

const sp_upload_content_props = [_]PropSpec{
    sp_site_id_prop,
    sp_drive_id_prop,
    .{ .name = "path", .type = "string", .description = "Destination path in the drive (e.g. 'notes/meeting.md'). Must not start with '/' or contain '..'." },
    .{ .name = "content", .type = "string", .description = "Raw content to upload (markdown, text, JSON, etc.)." },
    .{ .name = "contentType", .type = "string", .description = "Optional MIME type override. Auto-detected from the path's extension if omitted." },
};

const sp_create_folder_props = [_]PropSpec{
    sp_site_id_prop,
    sp_drive_id_prop,
    .{ .name = "path", .type = "string", .description = "Path of the new folder relative to drive root (e.g. '2026/Q1'). Parent folders must already exist." },
};

const sp_delete_item_props = [_]PropSpec{
    sp_site_id_prop,
    sp_drive_id_prop,
    .{ .name = "path", .type = "string", .description = "Path of the item to delete (e.g. '2026/Q1/report.pdf'). Provide either this OR itemId." },
    .{ .name = "itemId", .type = "string", .description = "Drive item ID (from list-sharepoint-items). Provide either this OR path." },
};

const sp_download_file_props = [_]PropSpec{
    sp_site_id_prop,
    sp_drive_id_prop,
    .{ .name = "path", .type = "string", .description = "Path of the file to download (e.g. '2026/Q1/report.pdf'). Provide either this OR itemId." },
    .{ .name = "itemId", .type = "string", .description = "Drive item ID (from list-sharepoint-items). Provide either this OR path." },
};

// --- Full list of tools, in the order they appear in tools/list output. ---
// Grouped by category. Do not reorder without checking client-side expectations.

const all_tools = [_]ToolSpec{
    // --- Calendar ---
    .{
        .name = "create-calendar-event",
        .description = "Create a calendar event or meeting on Microsoft 365 / Teams / Outlook. Pass times in local time \u{2014} the server handles timezone automatically. Supports subject, start/end times, body, location, required attendees, and optional attendees.",
        .props = &cal_create_props,
        .required = &.{ "subject", "startDateTime", "endDateTime" },
    },
    .{
        .name = "list-calendar-events",
        .description = "List calendar events and meetings from Microsoft 365 / Teams / Outlook in a date range. Use this to check what's on the calendar. Pass startDateTime and endDateTime in local time (e.g. 2026-02-24T00:00:00 to 2026-02-25T00:00:00 for a full day). Expands recurring events. Results are in the user's local timezone.",
        .props = &cal_list_props,
        .required = &.{ "startDateTime", "endDateTime" },
    },
    .{
        .name = "get-calendar-event",
        .description = "Get full details of a calendar event or meeting by ID. Returns subject, start/end, location, body, attendees, and organizer.",
        .props = &cal_get_props,
        .required = &.{"eventId"},
    },
    .{
        .name = "update-calendar-event",
        .description = "Update a calendar event or meeting. Only provide the fields you want to change. Pass times in local time \u{2014} the server handles timezone automatically.",
        .props = &cal_update_props,
        .required = &.{"eventId"},
    },
    .{
        .name = "delete-calendar-event",
        .description = "Delete a calendar event or meeting by ID.",
        .props = &cal_delete_props,
        .required = &.{"eventId"},
    },
    // --- Email ---
    .{
        .name = "list-emails",
        .description = "List recent emails from Microsoft 365 Outlook inbox. Returns subject, sender, date, and preview for the 10 most recent messages.",
    },
    .{
        .name = "read-email",
        .description = "Read the full content of an email by ID. Returns subject, sender, recipients, CC, date, full body, and read status. Use list-emails first to get the email ID.",
        .props = &read_email_props,
        .required = &.{"emailId"},
    },
    .{
        .name = "send-email",
        .description = "Send an email via Microsoft 365 Outlook. Supports multiple recipients, CC, and BCC.",
        .props = &send_email_props,
        .required = &.{ "to", "subject", "body" },
    },
    .{
        .name = "reply-email",
        .description = "Reply to an email. By default, the reply goes only to the original sender; pass 'to' to add more recipients. Use 'comment' for the reply text.",
        .props = &reply_email_props,
        .required = &.{ "emailId", "comment" },
    },
    .{
        .name = "reply-all-email",
        .description = "Reply to everyone on the original email thread (original sender plus every to/cc recipient).",
        .props = &reply_all_email_props,
        .required = &.{ "emailId", "comment" },
    },
    .{
        .name = "forward-email",
        .description = "Forward an email to one or more new recipients. 'to' is required. Use 'comment' for text that appears above the forwarded content (pass an empty string to omit).",
        .props = &forward_email_props,
        .required = &.{ "emailId", "comment", "to" },
    },
    .{
        .name = "search-emails",
        .description = "Search the user's mailbox for emails matching a keyword. Matches subject, body, sender, and recipient fields. Returns up to 25 matches.",
        .props = &search_emails_props,
        .required = &.{"query"},
    },
    .{
        .name = "list-mail-folders",
        .description = "List the user's mail folders (Inbox, Sent, Drafts, Archive, plus any custom folders). Needed for move-email, which takes a folder ID, not a folder name.",
    },
    .{
        .name = "mark-read-email",
        .description = "Mark an email as read (default) or unread. Pass isRead=false to mark unread.",
        .props = &mark_read_email_props,
        .required = &.{"emailId"},
    },
    .{
        .name = "move-email",
        .description = "Move an email to a different folder. Use list-mail-folders first to get the destination folder ID — 'destinationId' is an ID, not a folder name.",
        .props = &move_email_props,
        .required = &.{ "emailId", "destinationId" },
    },
    .{
        .name = "list-email-attachments",
        .description = "List attachments on a received email. Returns each attachment's name, MIME type, size, and ID.",
        .props = &list_email_attachments_props,
        .required = &.{"emailId"},
    },
    .{
        .name = "read-email-attachment",
        .description = "Fetch an email attachment's metadata plus its base64-encoded bytes. Suitable for small text attachments. For binary files (PDFs, images, etc.) use download-email-attachment instead.",
        .props = &read_email_attachment_props,
        .required = &.{ "emailId", "attachmentId" },
    },
    .{
        .name = "download-email-attachment",
        .description = "Download a binary email attachment to a local temp file and return its absolute path. Use this for PDFs, images, videos — any file where returning raw bytes inline would corrupt the JSON-RPC channel. Returns the temp path for a follow-up tool call to read.",
        .props = &read_email_attachment_props,
        .required = &.{ "emailId", "attachmentId" },
    },
    .{
        .name = "create-draft",
        .description = "Create a draft email in Microsoft 365 Outlook. Saves to Drafts folder without sending. Supports multiple recipients, CC, and BCC.",
        .props = &send_email_props,
        .required = &.{ "to", "subject", "body" },
    },
    .{
        .name = "send-draft",
        .description = "Send a previously created draft email by its ID.",
        .props = &send_draft_props,
        .required = &.{"draftId"},
    },
    .{
        .name = "update-draft",
        .description = "Update a draft email. Only provide the fields you want to change (subject, body, to, cc, bcc).",
        .props = &update_draft_props,
        .required = &.{"draftId"},
    },
    .{
        .name = "delete-draft",
        .description = "Delete a draft email by its ID.",
        .props = &delete_draft_props,
        .required = &.{"draftId"},
    },
    .{
        .name = "add-attachment",
        .description = "Add a file attachment to a draft email. Reads the file from disk \u{2014} just provide the file path. Name and MIME type are auto-detected.",
        .props = &add_attach_props,
        .required = &.{ "draftId", "filePath" },
    },
    .{
        .name = "list-attachments",
        .description = "List attachments on a draft email. Returns attachment IDs, names, and sizes.",
        .props = &list_attach_props,
        .required = &.{"draftId"},
    },
    .{
        .name = "remove-attachment",
        .description = "Remove an attachment from a draft email by its attachment ID.",
        .props = &remove_attach_props,
        .required = &.{ "draftId", "attachmentId" },
    },
    // --- Teams Chat ---
    .{
        .name = "list-chats",
        .description = "List Microsoft Teams chats including 1:1 conversations, group chats, and meeting chats. Supports pagination — pass the nextLink from the response as pageToken to get the next page. Use 'top' to control page size (1-50, default 50).",
        .props = &list_chats_props,
    },
    .{
        .name = "list-chat-messages",
        .description = "List messages in a Microsoft Teams chat by chat ID. Supports pagination — pass the nextLink from the response as pageToken to get the next page. Use 'top' to control page size (1-50, default 50).",
        .props = &chat_msgs_props,
        .required = &.{"chatId"},
    },
    .{
        .name = "send-chat-message",
        .description = "Send a message in a Microsoft Teams chat.",
        .props = &send_chat_props,
        .required = &.{ "chatId", "message" },
    },
    .{
        .name = "create-chat",
        .description = "Create or find an existing 1:1 Microsoft Teams chat between two users by email address.",
        .props = &create_chat_props,
        .required = &.{ "emailOne", "emailTwo" },
    },
    // --- Teams Channels ---
    .{
        .name = "list-teams",
        .description = "List Microsoft Teams teams you are a member of. Returns team names and IDs. Use this to find a team before listing its channels.",
    },
    .{
        .name = "list-channels",
        .description = "List channels in a Microsoft Teams team. Returns channel names and IDs. Use list-teams first to get the teamId.",
        .props = &list_channels_props,
        .required = &.{"teamId"},
    },
    .{
        .name = "list-channel-messages",
        .description = "List top-level posts in a Microsoft Teams channel. Returns posts only, NOT replies — use get-channel-message-replies to read replies to a specific post. Supports pagination via pageToken. Use 'top' to control page size (1-50, default 50).",
        .props = &list_chan_msgs_props,
        .required = &.{ "teamId", "channelId" },
    },
    .{
        .name = "get-channel-message-replies",
        .description = "Get replies to a specific post in a Microsoft Teams channel. Use this when checking if someone has replied to a post. Supports pagination via pageToken. Use list-channel-messages first to find the messageId.",
        .props = &chan_replies_props,
        .required = &.{ "teamId", "channelId", "messageId" },
    },
    .{
        .name = "post-channel-message",
        .description = "Post a new message to a Microsoft Teams channel. Supports @mentions and an optional subject line. Use list-teams then list-channels to get the IDs.",
        .props = &post_chan_props,
        .required = &.{ "teamId", "channelId", "message" },
    },
    .{
        .name = "reply-to-channel-message",
        .description = "Reply to a message thread in a Microsoft Teams channel. Supports @mentions — pass the mentions parameter with 'DisplayName|userId' pairs and use @Name in the message text. Get user IDs from the from.user.id field in channel message replies.",
        .props = &chan_reply_props,
        .required = &.{ "teamId", "channelId", "messageId", "message" },
    },
    // --- Delete / Cleanup ---
    .{
        .name = "delete-email",
        .description = "Delete an email by ID. Moves the email to the Deleted Items folder.",
        .props = &delete_email_props,
        .required = &.{"emailId"},
    },
    .{
        .name = "delete-chat-message",
        .description = "Soft-delete a message in a Teams chat. The message will show as 'This message has been deleted'.",
        .props = &delete_chat_msg_props,
        .required = &.{ "chatId", "messageId" },
    },
    .{
        .name = "delete-channel-message",
        .description = "Soft-delete a message in a Teams channel. The message will show as 'This message has been deleted'.",
        .props = &delete_chan_msg_props,
        .required = &.{ "teamId", "channelId", "messageId" },
    },
    .{
        .name = "delete-channel-reply",
        .description = "Soft-delete a reply to a message in a Teams channel.",
        .props = &delete_chan_reply_props,
        .required = &.{ "teamId", "channelId", "messageId", "replyId" },
    },
    // --- SharePoint ---
    .{
        .name = "search-sharepoint-sites",
        .description = "Search SharePoint sites by name or keyword. Returns site IDs, display names, and web URLs. Use this first to find the site you want to interact with.",
        .props = &sp_search_sites_props,
        .required = &.{"query"},
    },
    .{
        .name = "list-sharepoint-drives",
        .description = "List document libraries (drives) in a SharePoint site. Every site has at least one drive (usually 'Documents'). Use search-sharepoint-sites first to get the siteId.",
        .props = &sp_list_drives_props,
        .required = &.{"siteId"},
    },
    .{
        .name = "list-sharepoint-items",
        .description = "List files and folders inside a SharePoint drive. Omit folderPath to list the drive root, or pass a path like '2026/Q1' to list a sub-folder. Returns item IDs, names, sizes, and types.",
        .props = &sp_list_items_props,
        .required = &.{ "siteId", "driveId" },
    },
    .{
        .name = "upload-sharepoint-file",
        .description = "Upload a local file from disk to a SharePoint drive at the given path. Auto-chunks files larger than 4 MB. Overwrites any existing file at the destination.",
        .props = &sp_upload_file_props,
        .required = &.{ "siteId", "driveId", "path", "filePath" },
    },
    .{
        .name = "upload-sharepoint-content",
        .description = "Upload a raw string (markdown, text, JSON, etc.) to a SharePoint drive at the given path. Auto-chunks content larger than 4 MB. Overwrites any existing file at the destination.",
        .props = &sp_upload_content_props,
        .required = &.{ "siteId", "driveId", "path", "content" },
    },
    .{
        .name = "create-sharepoint-folder",
        .description = "Create a new folder at the given path in a SharePoint drive. Parent folders must already exist. If a folder with the same name exists, the new folder is renamed (e.g. 'Q1 1').",
        .props = &sp_create_folder_props,
        .required = &.{ "siteId", "driveId", "path" },
    },
    .{
        .name = "delete-sharepoint-item",
        .description = "Delete a file or folder from a SharePoint drive. Identify the item by either 'path' (human-readable) or 'itemId' (from list-sharepoint-items). Provide exactly one.",
        .props = &sp_delete_item_props,
        .required = &.{ "siteId", "driveId" },
    },
    .{
        .name = "download-sharepoint-file",
        .description = "Download a file's contents from a SharePoint drive. Identify the file by either 'path' or 'itemId'. Provide exactly one. Returns the raw file bytes.",
        .props = &sp_download_file_props,
        .required = &.{ "siteId", "driveId" },
    },
    // --- Utility ---
    .{
        .name = "search-users",
        .description = "Search for people in your Microsoft 365 organization by name. Returns display names and email addresses. Use this to find someone's email address.",
        .props = &search_users_props,
        .required = &.{"query"},
    },
    .{
        .name = "get-profile",
        .description = "Get the logged-in user's Microsoft 365 profile including display name and email.",
    },
    .{
        .name = "login",
        .description = "Log in to Microsoft 365. Starts the OAuth device code authentication flow. Returns a code to enter at the Microsoft login page.",
    },
    .{
        .name = "verify-login",
        .description = "Complete the Microsoft 365 login. Polls for authentication after the user enters the device code. Call login first.",
    },
    .{
        .name = "get-mailbox-settings",
        .description = "Get the user's Microsoft 365 mailbox settings including timezone, language, and date format.",
    },
    .{
        .name = "sync-timezone",
        .description = "Sync the Microsoft 365 mailbox timezone to match this computer's system timezone. Run after traveling to a new timezone.",
    },
};

/// Build and return the complete list of tool definitions for the "tools/list" response.
///
/// Returns null if any allocation fails during schema construction. The returned
/// slice is heap-allocated (via `allocator.dupe`) because the tool array contains
/// runtime-built ObjectMaps; it cannot be returned as a static constant.
pub fn allDefinitions(allocator: std.mem.Allocator) ?[]const types.ToolDefinition {
    const defs = allocator.alloc(types.ToolDefinition, all_tools.len) catch return null;
    for (all_tools, 0..) |spec, i| {
        const input_schema = if (spec.props.len == 0)
            schema.emptySchema()
        else blk: {
            const props = schema.buildProps(allocator, spec.props) orelse return null;
            break :blk schema.buildSchema(props, spec.required);
        };
        defs[i] = .{
            .name = spec.name,
            .description = spec.description,
            .inputSchema = input_schema,
        };
    }
    return defs;
}
