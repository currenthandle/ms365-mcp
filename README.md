# ms365-mcp

A lightweight Microsoft 365 MCP server written in Zig. ~4.6k lines of code, ~5.7MB binary, no runtime dependencies.

Exposes Microsoft Graph API functionality — Teams, Outlook, Calendar, SharePoint, and OneDrive — as MCP tools for use with LLM agents.

**Non-technical readers:** see [docs/sales-agent-capabilities.md](docs/sales-agent-capabilities.md) for a one-page tour of what the tool unlocks for sales workflows.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/currenthandle/ms365-mcp/main/install.sh | sh
```

This downloads the right binary for your platform (macOS/Linux, ARM64/x86_64) to `~/.local/bin/ms365-mcp`.

## Setup

1. Create a [Microsoft Entra app registration](https://entra.microsoft.com/) with delegated permissions for the Graph API scopes you need.

2. Add to your MCP client config (`.mcp.json`, Claude Desktop, etc.):

```json
{
  "mcpServers": {
    "ms365": {
      "command": "$HOME/.local/bin/ms365-mcp",
      "env": {
        "MS365_CLIENT_ID": "your-client-id",
        "MS365_TENANT_ID": "your-tenant-id"
      }
    }
  }
}
```

3. The server authenticates via OAuth device code flow — the LLM will call `login` and prompt you to visit a URL.

## Tools

**Email** — list-emails, read-email, send-email, delete-email, create-draft, send-draft, update-draft, delete-draft, add-attachment, list-attachments, remove-attachment

**Calendar** — list-calendar-events, get-calendar-event, create-calendar-event, update-calendar-event, delete-calendar-event

**Teams Chat** — list-chats, list-chat-messages, send-chat-message, create-chat, delete-chat-message

**Teams Channels** — list-teams, list-channels, list-channel-messages, get-channel-message-replies, reply-to-channel-message, delete-channel-message, delete-channel-reply

**Users** — search-users, get-profile, get-mailbox-settings

**Auth** — login, verify-login, sync-timezone

## Build from source

Requires [Zig](https://ziglang.org/) `0.16.0-dev.2736+3b515fbed` (nightly).

```sh
zig build -Doptimize=ReleaseSafe
```

Run tests:

```sh
zig build test
```
