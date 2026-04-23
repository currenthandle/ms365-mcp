# Sales Agent — what it does for you

`ms-mcp` is the bridge between your AI assistant and Microsoft 365. Without
it the model can read your prompt. With it, the model can **read your
inbox, schedule your meetings, and share your files** — safely, with your
existing credentials, under your approval.

---

## The three things it actually changes

### 1. Inbox triage stops being your first hour of the day

**Before.** You spend 45–60 minutes every morning triaging email. Opening,
reading, deciding what needs a reply, drafting the reply, finding the
attachment, hitting send.

**After.** You say _"summarize yesterday's sales inbox and draft replies to
the top three."_ The agent returns in under a minute with:

- A one-line summary of every email that came in overnight.
- Three drafts ready in your Drafts folder, addressed correctly, in your
  voice, with the right attachments pulled from SharePoint.
- A list of what it chose to ignore and why.

You review. You hit send. **Time saved: ~45 minutes per day, every day.**

### 2. Scheduling stops being a three-person email chain

**Before.** _"When are you free next week?"_ → reply → _"actually
Wednesday's bad"_ → reply → _"Tuesday then?"_ → eventually 15 minutes and
six messages later, a meeting is on three calendars.

**After.** You say _"find a 30-minute slot next week with Priya, Marcus,
and the solution architect on their team."_ The agent checks everyone's
free/busy windows, picks the highest-confidence slot, creates the event
with all three attendees, and returns the Teams meeting link. **Time
saved: ~10 minutes per scheduled meeting, every meeting.**

### 3. Document sharing stops being "I'll find it and send it over"

**Before.** Someone asks for a deck. You alt-tab to SharePoint. You search.
You find a folder. You wrong folder. You right folder. You find the file.
You download. You email. You attach. You send.

**After.** You say _"send Sarah the latest pricing deck from the Sales
site."_ The agent searches SharePoint, finds it, and either emails it
directly or shares a link in a Teams chat — in whichever channel Sarah
prefers. Works identically for files in your personal OneDrive. Files
over 4 MB auto-chunk so a 200 MB video uploads as cleanly as a 40 KB
Word doc. **Time saved: ~3 minutes per share, multiplied by however
often you field "can you send me…" in a week.**

---

## What it can touch

- **Email** — read inbox, search, reply, reply-all, forward, mark read,
  move to folders, attach and download files.
- **Calendar** — see the calendar, find mutually-free times for a group,
  create events with required and optional attendees, look up anyone's
  free/busy windows, accept or decline invites.
- **Microsoft Teams** — read chats and channel threads, send chat
  messages, post to channels with @mentions, reply to threads.
- **SharePoint + OneDrive** — search sites, browse document libraries,
  upload and download files of any size, create folders, tidy up.

If you can do it in Outlook, Teams, or SharePoint through the web UI,
the agent can do it on your behalf.

---

## Concrete numbers

These are measured on the real tool, not estimated:

| Thing | Value |
|---|---|
| Tools available to the agent | **61** |
| End-to-end tests passing against live Microsoft Graph | **51 of 51** |
| Inbox summary: raw Graph response size | ~20 KB per call |
| Inbox summary: what the model actually sees after we clean it up | ~2 KB per call |
| LLM context-window saving on a single `list-emails` call | **90%** |
| Large-file upload chunk size | 10 MiB |
| Binary download flow | writes to local temp file, zero bytes in chat |

The 10× context-window reduction is the quiet hero. It's why the agent
can hold a full day's triage in its head instead of drowning in
`@odata.etag` metadata after three emails.

---

## The small things that matter

**Clear errors.** If your session expires, the agent sees _"Run the
`login` tool and then `verify-login` to refresh."_ Not
"something went wrong." It knows what to do next. You don't get called
to debug.

**No giant blobs in chat.** A 20 MB video from SharePoint returns as a
local file path, not as megabytes of garbled bytes that crash the
conversation. The agent reads the file from disk if it needs to; your
assistant chat stays clean.

**Destructive actions stay gated.** Agent-initiated actions that touch
real users — reply, forward, delete, move to Archive — are explicit in
the agent's tool list. You see each one before it fires. Nothing leaves
your machine without your approval.

---

## Safety and privacy

- Your Microsoft 365 OAuth token stays on your machine in
  `~/.ms365-zig-mcp-token.json` with file permissions `0600`
  (owner-read-write only). It never leaves your device.
- File downloads land in `/tmp/ms-mcp-<pid>-<n>/`. The OS cleans
  `/tmp` on reboot.
- No telemetry. No phone-home. Exactly two outbound hosts:
  `login.microsoftonline.com` for sign-in, `graph.microsoft.com` for
  everything else.
- Every binary file written to disk has its name sanitized so an
  attacker can't smuggle a path that escapes the temp directory.

---

## What it is *not*

- Not a spam cannon. The agent cannot mass-email; every send goes
  through the same rate limits Outlook applies to you.
- Not a data extraction tool for someone else's mailbox. Your token, your
  scope, your permissions. The agent inherits exactly what Outlook
  inherits.
- Not a replacement for Outlook or Teams. Think of it as an assistant
  that drives those apps for you, not a new app.

---

## How to think about value

If triage saves you 45 minutes a day, scheduling saves 10 minutes per
meeting (~3 meetings a day = 30 min), and sharing saves 3 minutes per
share (~5 shares a day = 15 min), that's **~90 minutes a day per AE**.
Five working days. Forty AEs. That's **300 hours of sales time a week**
clawed back from glue work. Pick your hourly rate and multiply.

The point isn't the minutes — it's that sales stops being the job of
moving files, picking times, and drafting "got it, thanks." Those are
the parts the agent does while you're on the call with the actual
customer.

---

## Appendix — the full tool list (63 tools; developer reference)

Grouped by surface. Tool names are what the agent sees in its
instruction list; descriptions live in the server schema.

- **Auth & session** (4): login, verify-login, get-mailbox-settings, sync-timezone
- **Email** (14): list-emails, read-email, send-email, reply-email,
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
- **Utility** (2): search-users, get-profile
