# CLAUDE.md — ms-mcp project philosophy

This file tells Claude Code (and any human reading the repo) what we care about
when we write Zig here. Read it before opening a PR.

## What this project is

A Model Context Protocol (MCP) server that exposes Microsoft 365 (Outlook
mail + calendar, Teams chat + channels, SharePoint, OneDrive) to an LLM agent
as a set of tools. It speaks JSON-RPC over stdin/stdout and talks to Microsoft
Graph over HTTPS. Written in Zig 0.16.0.

## Core stance

**Zig is new to us.** We're learning it here, at production quality, on a real
product. We take nothing for granted. We write everything from the bedrock up.
Nothing in this codebase is assumed to be secure, performant, or correct unless
*we* made it so and *we* can point to the test that proves it.

**We assume the reader does not know Zig.** A competent TypeScript or Python
developer should be able to read any file in this repo top-to-bottom and
understand what it does, because every unusual Zig idiom will have a short
comment next to it mapping to a language they already know.

**Clarity over cleverness, every time.** If a line is clever but a
TypeScript-first reader would stumble on it, rewrite or annotate until they
don't. If a module is getting dense, extract sooner than later. "Is this
clear?" is a better question than "is this idiomatic Zig?"

## Rules

### 1. Comment the things that would surprise a TypeScript reader

We don't paper the code in comments. We do explain any Zig idiom a TS/Python
reader would likely see for the first time. One line is usually enough.

```zig
// parseFromSlice is like JSON.parse — returns a Parsed(T) that owns an arena.
// Calling parsed.deinit() frees the arena and invalidates borrowed strings.
const parsed = try std.json.parseFromSlice(Value, allocator, body, .{});
defer parsed.deinit();
```

```zig
// orelse is Zig's version of ??. If requireAuth returns null we short-circuit
// out of this handler — the error response was already sent to the client.
const token = ctx.requireAuth() orelse return;
```

Things almost always worth a brief comment on first use in a file:

- `?T` optionals, `!T` error unions, `orelse`, `catch`, `try`
- `defer` and `errdefer`
- Allocator passing and explicit lifetime (no GC)
- `std.Io.Writer.Allocating`, `toOwnedSlice`
- `@as`, `@intFromEnum`, `@enumFromInt`, and other builtins
- `std.http.Client.fetch` and the HTTP response model
- Pattern syntax like `if (x) |val| { ... }` and `switch (tagged) |v| { ... }`
- `comptime`, `anytype`, and generic parameter forms

We don't re-explain the same concept four times in the same file. Once per
file near the first occurrence is plenty.

### 2. Every allocation has a visible free

No hidden lifetimes. If we allocate, the free lives **on the very next line**
where possible, or on a clearly matching scope-end `defer`. When ownership
transfers out of a function (e.g. `toOwnedSlice`, `allocator.dupe`), add a
doc comment on the function saying "caller owns the returned slice and must
free it."

```zig
const path = try std.fmt.allocPrint(alloc, "/me/messages/{s}", .{id});
defer alloc.free(path);

const response = graph.get(alloc, io, token, path) catch |err| {
    ctx.sendGraphError(err);
    return;
};
defer alloc.free(response);
```

If there's a legitimate case where we don't free (e.g. the result is handed
to the client and freed at a different layer), say so with a comment.

### 3. Triple-slash doc comments on every `pub fn`

One or two sentences. What it does, and any non-obvious shape detail
(ownership, nullability, side effects). No `@param` / `@return` — the types
are explicit in the signature.

```zig
/// Build and return the complete list of tool definitions for the "tools/list"
/// response. Returns null if any allocation fails. The returned slice is
/// heap-allocated; the caller owns it.
pub fn allDefinitions(allocator: std.mem.Allocator) ?[]const types.ToolDefinition {
    // ...
}
```

### 4. Modularity

- Tool handlers belong under `src/tools/<domain>.zig` (one file per Graph
  surface area: email, calendar, sharepoint, onedrive, ...).
- Tool schemas (MCP `inputSchema`) belong in `src/tools/registry.zig`,
  declared as data. Adding a tool means adding one entry to the data table
  plus one handler function — not hunting across multiple files.
- Dispatch (tool name → handler) belongs in `src/main.zig`, as a single
  compile-time `std.StaticStringMap`.
- Helpers shared across tool domains belong in either `src/tools/context.zig`
  (if they need a `ToolContext`) or a new top-level module in `src/` (if
  they're pure utilities).
- When a helper gets copy-pasted across two or more files, *extract it*.
  The refactor is always smaller than the future bug.

### 5. No raw Graph JSON to the LLM

Read tools do **not** return raw Microsoft Graph JSON to the client. They
route through `src/formatter.zig`, which produces a compact, LLM-friendly
summary and always surfaces `id:` and `webUrl:` at end-of-line so the agent
can reference items in the next tool call.

This rule exists because raw Graph responses are typically 10–30 KB of
`@odata.*` metadata per list call. Burning the LLM's context window on
`@odata.etag` strings is waste.

Exception: `download-sharepoint-file` and `download-email-attachment` return
file *bytes*, not JSON. Those go through `src/binary_download.zig`, which
writes the bytes to a temp file and returns a path instead.

### 6. Errors that tell the user what to do

HTTP errors from Graph get mapped to typed Zig errors in `src/graph.zig`
(see `src/graph_errors.zig` for the set). Handlers catch them via
`ctx.sendGraphError(err)`, which produces a human-readable message.

`401` and `403` in particular must tell the user exactly what to do — usually
"run the `login` tool to refresh your session," or "ask an admin to grant
the scope." Generic "Failed to …" messages are not acceptable.

### 7. Ship one logical area at a time

Each PR is one phase of work. A phase finishes with:

1. `zig build test` exits 0.
2. `zig build e2e` green, at least for the new test category (ideally the
   full suite; the e2e runner supports `E2E_ONLY=<category>` filtering).
3. `DebugAllocator` reports no leaks across a full e2e run.
4. `tools/list` baseline at `/tmp/sp-baseline/tools_list.json` either matches
   or is intentionally refreshed in the same PR, with a note in the PR body.
5. Every new `pub fn` has `///` doc comment.
6. Every allocation has a visible free within ~5 lines, or a comment
   explaining ownership transfer.
7. Every unusual stdlib call has a one-line TS/Python analogy comment.

Don't mix phases. If you discover a refactor is needed mid-phase, land it as
its own preceding PR.

## Zig cheat sheet (for TS/Python readers)

- `?T` — optional. TS equivalent: `T | null`. Unwrap with `orelse` (`??`), or
  `if (x) |v| { ... }` (capture syntax, no TS/JS equivalent).
- `!T` — error union. Function returns either `T` or an error. `try expr`
  propagates errors up; `expr catch |err| { ... }` handles them. Different
  from TS exceptions: errors are values, always typed, always explicit.
- `defer` — runs at end of current scope. Like a scope-local `finally`.
  Multiple `defer`s run in reverse order. `errdefer` only runs if the scope
  exits via an error.
- `orelse` — null coalescing. `x orelse "default"` == `x ?? "default"`.
  `x orelse return` is early-exit.
- `allocator` — passed explicitly; no GC. Every heap allocation has a
  corresponding free, usually via `defer alloc.free(x)`. If you don't see a
  free near an alloc, the function is either buggy or transferring ownership.
- `@as(T, x)` — explicit cast. No implicit numeric conversions in Zig.
- `comptime` — evaluated at compile time. `std.StaticStringMap(...).initComptime(...)`
  is how our tool dispatch table is built.
- `anytype` — generic parameter, resolved at compile time. Like TypeScript
  generics but structural and duck-typed.
- `pub const X = @import("y.zig")` — module import. The module *is* its
  file's top-level scope; there's no `export` statement.

## Memory model (key thing to internalize)

Zig has no garbage collector. Any function that returns `[]u8` or `[]const u8`
or similar is telling you: **"I allocated this for you; you need to free it."**
The doc comment should say so; if it doesn't, that's a bug we should fix.

Conversely, any `[]const u8` parameter is borrowed for the duration of the
call. Don't store the pointer past the function return unless you `dupe()`
it first.

When you see `parsed.deinit()` run via defer, understand that every string
slice you pulled out of that parsed value is now invalid. If you need one
past the deinit, `allocator.dupe(u8, slice)` first.

Memory model questions we ask ourselves constantly:

- Who owns this slice?
- When does its backing memory get freed?
- Is the free path reachable on every error return?
- If this function fails partway through, are there leaked allocations?

When the answers aren't obvious from reading the code, we add a comment.

## What this is *not*

- Not a blog about how cool Zig is.
- Not a benchmark shoot-out.
- Not the place to explore `comptime` meta-programming for its own sake.
- Not a project where "clever" code survives a code review.

It's a production MCP server that a real Sales Agent relies on. Every decision
should be explainable in one sentence to a new engineer joining the team.
