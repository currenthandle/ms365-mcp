# ms-mcp

A lightweight Microsoft 365 MCP server written in Zig. ~4.6k lines of code, ~5.7MB binary, no runtime dependencies.

Exposes Microsoft Graph API functionality — Teams, Outlook, and Calendar — as MCP tools for use with LLM agents.

## Tools

**Email** — list-emails, read-email, send-email, create-draft, send-draft, update-draft, delete-draft, add-attachment, list-attachments, remove-attachment

**Calendar** — list-calendar-events, get-calendar-event, create-calendar-event, update-calendar-event, delete-calendar-event

**Teams Chat** — list-chats, list-chat-messages, send-chat-message, create-chat

**Teams Channels** — list-teams, list-channels, list-channel-messages, get-channel-message-replies, reply-to-channel-message

**Users** — search-users, get-profile, get-mailbox-settings

**Auth** — login, verify-login, sync-timezone

## Setup

Requires a Microsoft Entra app registration with delegated permissions for the Graph API scopes you need.

Set environment variables:

```sh
export MS365_CLIENT_ID="your-client-id"
export MS365_TENANT_ID="your-tenant-id"
```

## Build

Requires [Zig](https://ziglang.org/) `0.16.0-dev.2736+3b515fbed` (nightly).

```sh
zig build
```

Binary outputs to `zig-out/bin/ms-mcp`.

## Usage

Add to your MCP client config:

```json
{
  "mcpServers": {
    "ms365": {
      "command": "/path/to/ms-mcp",
      "env": {
        "MS365_CLIENT_ID": "your-client-id",
        "MS365_TENANT_ID": "your-tenant-id"
      }
    }
  }
}
```

The server authenticates via OAuth device code flow — the LLM will call `login` and prompt you to visit a URL.
