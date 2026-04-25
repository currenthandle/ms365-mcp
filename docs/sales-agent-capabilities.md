# Sales Agent — what it does for you

`ms-mcp` is the bridge between your AI assistant and Microsoft 365. With it,
the model can **read your inbox, schedule your meetings, and share your
files** — safely, with your existing credentials, under your approval.

---

## The three things it actually changes

### 1. Inbox triage stops being your first hour of the day
You say _"summarize yesterday's sales inbox and draft replies to the top
three."_ The agent returns in under a minute with a one-line summary of
every overnight email, three drafts ready in your Drafts folder addressed
correctly with the right SharePoint attachments, and a list of what it
ignored and why. **~45 minutes/day saved.**

### 2. Scheduling stops being a three-person email chain
You say _"find a 30-minute slot next week with Priya, Marcus, and the
solution architect on their team."_ The agent checks everyone's free/busy,
picks the highest-confidence slot, creates the event with attendees, and
returns the Teams link. **~10 minutes/meeting saved.**

### 3. Document sharing stops being "I'll find it and send it over"
You say _"send Sarah the latest pricing deck from the Sales site."_ The
agent searches SharePoint, finds the file, and either emails it or shares
a Teams link. Works the same for OneDrive. Files over 4 MB auto-chunk so a
200 MB video uploads as cleanly as a 40 KB Word doc. **~3 minutes/share
saved.**

---

## What it can touch

- **Email** — read, search across all folders, reply, reply-all, forward,
  mark read, move to folders, attach and download files (PDFs, decks,
  videos all download cleanly).
- **Calendar** — see the calendar, find mutually-free times for a group,
  create events with required and optional attendees, look up free/busy,
  accept or decline invites.
- **Microsoft Teams** — read 1:1 chats and channel threads, **search across
  all chat history** (not just recent), send messages, post with @mentions.
- **SharePoint + OneDrive** — search sites, browse libraries, upload and
  download files of any size, create folders, delete.

If you can do it in Outlook, Teams, or SharePoint through the web UI, the
agent can do it on your behalf.

---

## What changed since March

The first version of this tool worked, but it had rough edges that showed
up the moment a real workflow chained more than two tool calls. The work
since March has been about making the agent *trustable* end-to-end.

### New capabilities
- **Email action suite (9 new tools)** — reply, reply-all, forward, search
  across the full mailbox, list folders, mark read, move between folders,
  list and download attachments. The previous version could only read and
  send; now the agent can run a full triage workflow.
- **Calendar scheduling (3 new tools)** — `find-meeting-times` returns
  ranked time slots for a group, `get-schedule` returns free/busy, and
  `respond-to-event` accepts/declines on your behalf. The agent can now
  *propose* meetings, not just create them.
- **OneDrive (5 new tools)** — same upload/download/list/delete surface
  as SharePoint, but for your personal drive. Auto-chunks files over 4 MB.
- **Search across Teams chat history** — `search-chat-messages` hits the
  Microsoft Search index directly, so the agent can find a message from
  three months ago instead of being limited to the last few weeks the
  chat-list endpoint actually returns.
- **Batch operations** — `batch-delete-emails` lets the agent clean up a
  search result set in one call instead of N. Less chatter, faster work.
- **PDFs, images, and videos download cleanly.** Before, asking the agent
  to grab a real binary file (a signed contract PDF, a deck, a screen
  recording) would either corrupt the file or dump megabytes of unreadable
  characters into the chat — sometimes crashing it. Now the file is saved
  to your disk, and the agent gets back just the path. The chat stays
  clean and the file is intact, exactly the way "Save As" works in your
  browser.

### Quiet wins
- **10× smaller responses to the model.** Every list/get response now goes
  through a formatter that strips `@odata.*` metadata before the model
  sees it. A `list-emails` call dropped from ~20 KB of JSON to ~2 KB of
  scannable summary. The agent can hold a full day of triage in its head
  without drowning in metadata.
- **Errors the agent can act on.** When a token expires the agent sees
  _"Run the `login` tool and then `verify-login` to refresh"_ — not
  "something went wrong." It knows the next step. You don't get paged.
- **No more silent hangs.** A real bug last week showed up as the MCP
  server wedging mid-call when deleting a chat message. The fix and the
  test that catches it both shipped: every Graph endpoint that returns
  204 No Content now uses a non-keep-alive client, and the e2e harness
  has a 10-second per-call timeout that hard-fails on any future hang.
- **Real e2e tests against live Graph.** 85 tests run end-to-end against
  Microsoft's actual API on every change, including six cross-tool user
  journeys (search a person → open a chat → send → search index → delete →
  verify gone) — the workflow shape an agent actually uses. Skips count
  as failures. No more "test passed because it didn't run."

### What the new pieces unlock
- Search across chat history + the email action suite means the agent can
  finally answer "what did Marcus say about pricing in February?" — pulling
  from email *and* Teams in one step.
- `find-meeting-times` + `respond-to-event` mean the agent can run an
  entire scheduling thread for you: find the slot, send the invite, accept
  the counter-proposal when it comes back.
- OneDrive parity with SharePoint means a personal-files workflow no
  longer falls off a cliff at the org boundary.
- Clean file downloads plus the smaller responses together mean the
  agent can do multi-step research workflows (search → list → download
  → summarize) without filling its short-term memory with junk or
  corrupting the chat.

---

## Concrete numbers

| Thing | Value |
|---|---|
| Tools available to the agent | **63** (was 30 in March) |
| End-to-end tests passing against live Graph | **85 of 85** (was 51) |
| Cross-tool user journeys covered | **6** (was 0) |
| LLM context-window saving on a `list-emails` call | **~90%** |
| Large-file upload chunk size | 10 MiB |
| File download flow | saved to disk, only the path goes through chat |

---

## Safety and privacy

- Your OAuth token stays on your machine in `~/.ms365-zig-mcp-token.json`
  with `0600` permissions. Never leaves your device.
- File downloads land in `/tmp/ms-mcp-<pid>-<n>/`. The OS cleans `/tmp`
  on reboot.
- No telemetry. Two outbound hosts only: `login.microsoftonline.com` for
  sign-in, `graph.microsoft.com` for everything else.
- Every binary file written has its name sanitized — no path traversal.
- Destructive actions (reply, forward, delete, move) appear in the agent's
  tool list explicitly. Nothing fires without your approval.

---

## What it is *not*

- Not a spam cannon. Every send goes through the same Outlook rate limits
  you're already subject to.
- Not a way into someone else's mailbox. Your token, your scope, your
  permissions. The agent inherits exactly what Outlook inherits.
- Not a replacement for Outlook or Teams. It's an assistant that drives
  those apps for you, not a new app.

---

## Value math

If triage saves 45 min/day, scheduling 10 min × 3 meetings = 30 min, and
sharing 3 min × 5 shares = 15 min, that's **~90 minutes a day per AE**.
Forty AEs × five days = **300 hours of sales time a week** clawed back
from glue work. Pick your hourly rate and multiply.

The point isn't the minutes — it's that sales stops being the job of
moving files, picking times, and drafting "got it, thanks." Those are the
parts the agent does while you're on the call with the actual customer.

---

## Appendix — the full tool list (63 tools; developer reference)

- **Auth & session** (4): login, verify-login, get-mailbox-settings, sync-timezone
- **Email** (15): list-emails, read-email, send-email, reply-email,
  reply-all-email, forward-email, search-emails, list-mail-folders,
  mark-read-email, move-email, list-email-attachments,
  read-email-attachment, download-email-attachment, delete-email,
  batch-delete-emails
- **Drafts** (7): create-draft, send-draft, update-draft, delete-draft,
  add-attachment, list-attachments, remove-attachment
- **Calendar** (8): create-calendar-event, list-calendar-events,
  get-calendar-event, update-calendar-event, delete-calendar-event,
  find-meeting-times, get-schedule, respond-to-event
- **Chat** (6): list-chats, list-chat-messages, search-chat-messages,
  send-chat-message, create-chat, delete-chat-message
- **Channels** (8): list-teams, list-channels, list-channel-messages,
  get-channel-message-replies, post-channel-message,
  reply-to-channel-message, delete-channel-message, delete-channel-reply
- **SharePoint** (8): search-sharepoint-sites, list-sharepoint-drives,
  list-sharepoint-items, upload-sharepoint-file, upload-sharepoint-content,
  create-sharepoint-folder, delete-sharepoint-item, download-sharepoint-file
- **OneDrive** (5): list-onedrive-items, upload-onedrive-file,
  upload-onedrive-content, download-onedrive-file, delete-onedrive-item
- **Utility** (2): search-users, get-profile
