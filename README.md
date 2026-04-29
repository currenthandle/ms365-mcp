# ms365-mcp

A Microsoft 365 MCP server that's small enough you forget it's running. 67 tools across Teams, Outlook, Calendar, SharePoint, and OneDrive. Built in Zig — no Node, no Python, no runtime dependencies. Statically linked.

**The numbers that matter** (measured, not estimated):

| Metric | Value |
|---|---|
| Cold-start RAM | **1.3 MB peak** / 1.9 MB resident |
| Cold-start time | **~120 ms** |
| Binary size | **5.9 MB** statically linked |
| `list-emails` payload to the model | **4.2 KB** vs **31 KB** raw Graph (**~87% smaller**) |
| Tokens per `list-emails` call | **~1,050** vs ~7,800 raw |
| End-to-end test count, against live Graph | **94** (no mocks) |

The context savings are the lever. On a 200K-token model, ms365-mcp lets the agent hold ~50 inbox snapshots in working memory instead of ~6. That's the difference between "the agent forgot what it was doing" and "the agent finishes the task."

**Non-technical readers:** see [docs/sales-agent-capabilities.md](docs/sales-agent-capabilities.md) for a one-page tour of what the tool unlocks.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/currenthandle/ms365-mcp/main/install.sh | sh
```

Downloads the right binary for your platform (macOS/Linux, ARM64/x86_64) to `~/.local/bin/ms365-mcp`.

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

**Email** (15) — list-emails, read-email, send-email, reply-email, reply-all-email, forward-email, search-emails, list-mail-folders, mark-read-email, move-email, list-email-attachments, read-email-attachment, download-email-attachment, delete-email, batch-delete-emails

**Drafts** (7) — create-draft, send-draft, update-draft, delete-draft, add-attachment, list-attachments, remove-attachment

**Calendar** (8) — list-calendar-events, get-calendar-event, create-calendar-event, update-calendar-event, delete-calendar-event, find-meeting-times, get-schedule, respond-to-event

**Teams Chat** (7) — list-chats, search-chats, list-chat-messages, search-chat-messages, send-chat-message, create-chat, delete-chat-message

**Teams Channels** (9) — list-teams, list-channels, search-channels, list-channel-messages, get-channel-message-replies, post-channel-message, reply-to-channel-message, delete-channel-message, delete-channel-reply

**SharePoint** (9) — search-sharepoint-sites, list-sharepoint-drives, list-sharepoint-items, search-sharepoint-files, upload-sharepoint-file, upload-sharepoint-content, create-sharepoint-folder, delete-sharepoint-item, download-sharepoint-file

**OneDrive** (6) — list-onedrive-items, search-onedrive-files, upload-onedrive-file, upload-onedrive-content, download-onedrive-file, delete-onedrive-item

**Auth & utility** (6) — login, verify-login, get-mailbox-settings, sync-timezone, search-users, get-profile

## Build from source

Requires [Zig](https://ziglang.org/) `0.16.0`.

```sh
zig build -Doptimize=ReleaseSafe
```

Run unit tests:

```sh
zig build test
```

Run the live-Graph end-to-end suite (85 tests; needs `MS365_CLIENT_ID` / `MS365_TENANT_ID` configured plus the `E2E_*` variables in `.env`):

```sh
zig build e2e
```

The e2e harness exercises every tool against real Graph endpoints — including 6 cross-tool user journeys (search a person → open a chat → send → search index → delete → verify gone).
