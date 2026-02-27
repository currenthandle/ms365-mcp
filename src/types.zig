// types.zig — JSON-RPC and MCP protocol types.
//
// These structs mirror the JSON shapes the MCP protocol expects.
// std.json.Stringify can automatically serialize any Zig struct to JSON,
// so defining these types is all we need — no manual JSON building.

const std = @import("std");

/// A JSON-RPC 2.0 response wrapper. Generic over the result type
/// so we can reuse it for different response shapes.
///
/// This is a "comptime generic" — a function that returns a *type*.
/// In Zig, types are values at compile time. Instead of TypeScript's
/// `JsonRpcResponse<T>`, you write `JsonRpcResponse(InitializeResult)`
/// and Zig generates a struct with that result type baked in.
pub fn JsonRpcResponse(comptime ResultType: type) type {
    return struct {
        jsonrpc: []const u8 = "2.0",
        id: i64,
        result: ResultType,
    };
}

/// The result of an "initialize" response.
/// Tells the client what protocol version we speak and what we can do.
pub const InitializeResult = struct {
    protocolVersion: []const u8 = "2024-11-05",
    capabilities: Capabilities = .{},
    serverInfo: ServerInfo = .{},
};

/// What this server supports. For now, just tools.
pub const Capabilities = struct {
    tools: struct {} = .{}, // empty object — no special tool capabilities
};

/// Identifies this server to the client.
pub const ServerInfo = struct {
    name: []const u8 = "ms-mcp",
    version: []const u8 = "0.1.0",
};

/// The result of a "tools/list" response.
pub const ToolsListResult = struct {
    tools: []const ToolDefinition,
};

/// Describes a single tool the server offers.
/// The client uses this to know what tools are available and how to call them.
/// inputSchema is std.json.Value because JSON Schema is dynamic —
/// each tool has different properties, and Zig structs are fixed at compile time.
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: std.json.Value,
};

/// The result of a "tools/call" response.
/// MCP tool results are a list of content blocks (text, images, etc).
pub const ToolCallResult = struct {
    content: []const TextContent,
};

/// A text content block returned by a tool.
/// The "type" field tells the client how to render it.
pub const TextContent = struct {
    type: []const u8 = "text",
    text: []const u8,
};

/// Microsoft Graph API request body for POST /me/events.
/// Creates a calendar event with subject, start/end times, and optional attendees.
pub const CreateEventRequest = struct {
    subject: []const u8,
    start: DateTimeTimeZone,
    end: DateTimeTimeZone,
    /// Optional body content for the event.
    body: ?Body = null,
    /// Optional location name.
    location: ?Location = null,
    /// Optional list of attendees (both required and optional).
    attendees: ?[]const Attendee = null,
    /// Whether this is an all-day event.
    isAllDay: ?bool = null,

    /// A date-time with its time zone.
    /// Graph API expects: {"dateTime": "2026-02-24T09:00:00", "timeZone": "UTC"}
    pub const DateTimeTimeZone = struct {
        dateTime: []const u8,
        timeZone: []const u8 = "UTC",
    };

    pub const Body = struct {
        contentType: []const u8 = "Text",
        content: []const u8,
    };

    pub const Location = struct {
        displayName: []const u8,
    };

    /// A meeting attendee — has an email and a type ("required" or "optional").
    pub const Attendee = struct {
        emailAddress: EmailAddress,
        type: []const u8 = "required",

        pub const EmailAddress = struct {
            address: []const u8,
        };
    };
};

/// Microsoft Graph API request body for POST /me/chats/{chatId}/messages.
/// Simple structure: {"body": {"content": "message text"}}
pub const ChatMessageRequest = struct {
    body: Body,

    pub const Body = struct {
        content: []const u8,
    };
};

/// Microsoft Graph API request body for POST /me/sendMail.
/// Nested structs mirror the JSON shape Microsoft expects:
///   {"message":{"subject":"...","body":{...},"toRecipients":[{...}]}}
///
/// std.json.Stringify will serialize this to JSON automatically —
/// no manual format strings or escaped braces needed.
pub const SendMailRequest = struct {
    message: Message,

    pub const Message = struct {
        subject: []const u8,
        body: Body,
        toRecipients: []const Recipient,
        /// Optional CC recipients — omitted from JSON when null.
        ccRecipients: ?[]const Recipient = null,
        /// Optional BCC recipients — omitted from JSON when null.
        bccRecipients: ?[]const Recipient = null,

        /// The email body — has a content type (Text or HTML) and the actual content.
        pub const Body = struct {
            contentType: []const u8 = "Text",
            content: []const u8,
        };

        /// A single email recipient — wraps an EmailAddress.
        /// Graph API nests it: {"emailAddress": {"address": "foo@bar.com"}}
        pub const Recipient = struct {
            emailAddress: EmailAddress,

            pub const EmailAddress = struct {
                address: []const u8,
            };
        };
    };
};

/// Request body for POST /me/messages (creates a draft without sending).
/// Same shape as SendMailRequest.Message but used as a top-level payload.
pub const DraftMailRequest = struct {
    subject: []const u8,
    body: SendMailRequest.Message.Body,
    toRecipients: []const SendMailRequest.Message.Recipient,
    /// Optional CC recipients — omitted from JSON when null.
    ccRecipients: ?[]const SendMailRequest.Message.Recipient = null,
    /// Optional BCC recipients — omitted from JSON when null.
    bccRecipients: ?[]const SendMailRequest.Message.Recipient = null,
};
