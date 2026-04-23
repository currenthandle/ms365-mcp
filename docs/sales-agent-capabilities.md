# What the Sales Agent can do with ms-mcp

A one-page map of everything the Sales Agent gets when `ms-mcp` is plugged
in. If you are in sales, marketing, or leadership, this is for you.

---

## Four pillars

**Email.** Read, search, reply, reply-all, forward, draft with attachments,
mark read/unread, move to folders, delete. Your agent sees the same inbox
you do and can act on it.

**Calendar.** See the calendar, find mutually-free times for a group of
people, create and update events with required and optional attendees,
look up anyone's free/busy windows, and accept or decline invitations on
your behalf.

**Microsoft Teams.** Read chat conversations and channel threads, send
chat messages, post to channels with @mentions, reply to message threads,
soft-delete messages the agent sent by mistake.

**SharePoint + OneDrive.** Search sites, browse document libraries,
upload files of any size (videos, decks, PDFs), create folders, download
files to local disk, and clean up. Files larger than 4 MiB auto-chunk.

---

## What that means in practice

### Scenario 1 — "Summarize my inbox and draft three replies"

The agent calls `list-emails` → picks the three that need a human
response → calls `read-email` on each to read the full body → calls
`create-draft` for each reply with the drafted text → asks you to review.
Nothing is sent without your approval.

Tools used: `list-emails`, `read-email`, `create-draft`, `add-attachment`
(if the reply needs a file).

### Scenario 2 — "Schedule a 30-minute intro with three prospects next week"

The agent calls `search-users` to resolve the three names to emails →
calls `find-meeting-times` with those attendees and a window of
Monday-Friday 9am-5pm → picks the highest-confidence slot → calls
`create-calendar-event` with subject, attendees, and the chosen time.
The prospects get the invite automatically.

Tools used: `search-users`, `find-meeting-times`, `create-calendar-event`.

### Scenario 3 — "Find last quarter's sales deck and share it with the new AE"

The agent calls `search-sharepoint-sites` for "Sales" → `list-sharepoint-drives`
on the matching site → `list-sharepoint-items` in the "Decks" folder →
calls `download-sharepoint-file` to pull the Q4 deck → calls `create-chat`
with the new AE → `send-chat-message` with a link (or uploads the deck
directly with `add-attachment` on a draft email). Works the same for
personal OneDrive files via the `*-onedrive-*` family.

Tools used: `search-sharepoint-sites`, `list-sharepoint-drives`,
`list-sharepoint-items`, `download-sharepoint-file`, `create-chat`,
`send-chat-message`.

---

## How the agent experience feels

Tool responses are summarized before the model sees them. Instead of
returning 20 KB of raw Microsoft Graph metadata per call, we return one
clean line per item with the ID and the webUrl at the end — so the model
can refer to the item in its next action without us burning its context
window on metadata noise.

When a tool fails because your session is stale, the error message tells
you exactly what to do: "Run the `login` tool and then `verify-login` to
refresh." No generic "something went wrong" strings.

Binary downloads go to a local temp file, not into the chat. A 20 MB
video or a PDF is returned as a path like
`/tmp/ms-mcp-12345-0/report.pdf`, not as kilobytes of garbled bytes in
the response window.

---

## Why Zig (short version for technical skeptics)

Written in Zig 0.16. One static binary, no runtime dependencies, no
garbage collector, memory-safe under the same guarantees as modern
systems languages. We audit our own allocation sites and every file has
an explicit memory model in comments, so new engineers can read the
codebase top-to-bottom without needing to know Zig first — every unusual
idiom has a TypeScript or Python analogy one line away.

---

## Safety and privacy

- Your Microsoft 365 OAuth token stays on your machine in
  `~/.ms365-zig-mcp-token.json` with 0600 permissions. It never leaves
  your device.
- File downloads land in `/tmp/ms-mcp-<pid>-<n>/...` with sanitized
  filenames. The OS cleans `/tmp` on reboot.
- No telemetry. No phone-home. The server has exactly two network
  destinations: `login.microsoftonline.com` for OAuth and
  `graph.microsoft.com` for everything else.

---

## Tool inventory (61 total as of Phase 8)

- **Auth & session** (4): login, verify-login, get-mailbox-settings, sync-timezone
- **Email** (13): list-emails, read-email, send-email, reply-email,
  reply-all-email, forward-email, search-emails, list-mail-folders,
  mark-read-email, move-email, list-email-attachments,
  read-email-attachment, download-email-attachment, delete-email
- **Drafts** (7): create-draft, send-draft, update-draft, delete-draft,
  add-attachment, list-attachments, remove-attachment
- **Calendar** (8): create-calendar-event, list-calendar-events,
  get-calendar-event, update-calendar-event, delete-calendar-event,
  find-meeting-times, get-schedule, respond-to-event
- **Chat** (5): list-chats, list-chat-messages, send-chat-message,
  create-chat, delete-chat-message
- **Channels** (8): list-teams, list-channels, list-channel-messages,
  get-channel-message-replies, post-channel-message,
  reply-to-channel-message, delete-channel-message, delete-channel-reply
- **SharePoint** (8): search-sharepoint-sites, list-sharepoint-drives,
  list-sharepoint-items, upload-sharepoint-file, upload-sharepoint-content,
  create-sharepoint-folder, delete-sharepoint-item, download-sharepoint-file
- **OneDrive** (5): list-onedrive-items, upload-onedrive-file,
  upload-onedrive-content, download-onedrive-file, delete-onedrive-item
- **Utility** (3): search-users, get-profile, (mailbox-settings / sync already counted above)
