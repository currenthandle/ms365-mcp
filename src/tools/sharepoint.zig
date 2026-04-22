// tools/sharepoint.zig — SharePoint site + drive + file tools.
//
// Surface covers the three discovery endpoints (find a site, list its doc
// libraries, list items in a folder) and five write endpoints (upload file,
// upload content, create folder, delete, download). Upload auto-chunks for
// files larger than 4 MB via Graph's createUploadSession flow.
//
// A quick vocab refresher:
//   site   — a SharePoint site collection, e.g. "Sales Team Site"
//   drive  — a document library inside a site (usually "Documents")
//   item   — any file or folder within a drive
//   path   — slash-separated path relative to the drive root, e.g.
//            "2026/Q1/report.pdf". Must NOT start with a leading slash.

const std = @import("std");
const graph = @import("../graph.zig");
const url_util = @import("../url.zig");
const json_rpc = @import("../json_rpc.zig");
const mime = @import("../mime.zig");
const ToolContext = @import("context.zig").ToolContext;

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

// --- Upload size tuning ---

/// Files at or below this size use the single-shot PUT endpoint.
/// Graph's documented limit for simple uploads is 4 MiB.
const SIMPLE_UPLOAD_LIMIT: usize = 4 * 1024 * 1024;

/// Each chunk in a resumable upload must be a multiple of 320 KiB (except
/// the final one). 10 MiB is a common, fast default.
const CHUNK_SIZE: usize = 10 * 1024 * 1024;

// --- Path helpers ---

/// Reject path traversal + validate shape.
/// Returns false if the path contains "..", is empty, or starts with "/".
fn isPathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return false;
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    return true;
}

/// Percent-encode a SharePoint path for embedding in a Graph URL.
/// Slashes are preserved (they separate folder segments); every other
/// reserved character is escaped per-segment.
///
/// Returns an allocated slice — caller must free.
fn escapePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var it = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (it.next()) |segment| {
        if (!first) try out.writer.writeAll("/");
        first = false;
        const encoded = try url_util.encode(allocator, segment);
        defer allocator.free(encoded);
        try out.writer.writeAll(encoded);
    }
    return out.toOwnedSlice();
}

// --- Read tools ---

/// Search for SharePoint sites by name.
pub fn handleSearchSites(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide query.") orelse return;
    const query = ctx.getStringArg(args, "query", "Missing 'query' argument.") orelse return;

    const encoded_query = url_util.encode(ctx.allocator, query) catch return;
    defer ctx.allocator.free(encoded_query);

    const path = std.fmt.allocPrint(ctx.allocator, "/sites?search={s}&$select=id,name,displayName,webUrl", .{encoded_query}) catch return;
    defer ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch {
        ctx.sendResult("Failed to search SharePoint sites.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}

/// List document libraries (drives) in a SharePoint site.
pub fn handleListDrives(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide siteId.") orelse return;
    const site_id = ctx.getPathArg(args, "siteId", "Missing 'siteId' argument.") orelse return;

    const path = std.fmt.allocPrint(ctx.allocator, "/sites/{s}/drives?$select=id,name,webUrl,driveType", .{site_id}) catch return;
    defer ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch {
        ctx.sendResult("Failed to list SharePoint drives.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}

/// List items (files + folders) at a path inside a drive.
pub fn handleListItems(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide siteId and driveId.") orelse return;
    const site_id = ctx.getPathArg(args, "siteId", "Missing 'siteId' argument.") orelse return;
    const drive_id = ctx.getPathArg(args, "driveId", "Missing 'driveId' argument.") orelse return;
    const folder_path = json_rpc.getStringArg(args, "folderPath");

    const path = if (folder_path) |fp| blk: {
        if (!isPathSafe(fp)) {
            ctx.sendResult("Invalid folderPath — must not start with '/' or contain '..'.");
            return;
        }
        const escaped = escapePath(ctx.allocator, fp) catch return;
        defer ctx.allocator.free(escaped);
        break :blk std.fmt.allocPrint(ctx.allocator, "/sites/{s}/drives/{s}/root:/{s}:/children", .{ site_id, drive_id, escaped }) catch return;
    } else std.fmt.allocPrint(ctx.allocator, "/sites/{s}/drives/{s}/root/children", .{ site_id, drive_id }) catch return;
    defer ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch {
        ctx.sendResult("Failed to list SharePoint items.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}

// --- Upload tools ---

/// Upload a local file from disk into a SharePoint drive at the given path.
/// Auto-selects simple PUT for small files and createUploadSession + chunked
/// PUTs for anything over the simple-upload threshold.
pub fn handleUploadFile(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide siteId, driveId, path, and filePath.") orelse return;
    const site_id = ctx.getPathArg(args, "siteId", "Missing 'siteId' argument.") orelse return;
    const drive_id = ctx.getPathArg(args, "driveId", "Missing 'driveId' argument.") orelse return;
    const sp_path = ctx.getStringArg(args, "path", "Missing 'path' argument (destination path in drive).") orelse return;
    const file_path = ctx.getStringArg(args, "filePath", "Missing 'filePath' argument (local absolute path to the file).") orelse return;

    if (!isPathSafe(sp_path)) {
        ctx.sendResult("Invalid path — must not start with '/' or contain '..'.");
        return;
    }
    if (std.mem.indexOf(u8, file_path, "..") != null) {
        ctx.sendResult("Invalid filePath — '..' is not allowed.");
        return;
    }

    const file_data = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, file_path, ctx.allocator, .unlimited) catch {
        const err_msg = std.fmt.allocPrint(ctx.allocator, "Failed to read file: {s}", .{file_path}) catch return;
        defer ctx.allocator.free(err_msg);
        ctx.sendResult(err_msg);
        return;
    };
    defer ctx.allocator.free(file_data);

    const content_type = json_rpc.getStringArg(args, "contentType") orelse mime.fromPath(file_path);

    uploadToSharePoint(ctx, token, site_id, drive_id, sp_path, file_data, content_type);
}

/// Upload a raw string (markdown, text, JSON, etc.) into a SharePoint drive.
pub fn handleUploadContent(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide siteId, driveId, path, and content.") orelse return;
    const site_id = ctx.getPathArg(args, "siteId", "Missing 'siteId' argument.") orelse return;
    const drive_id = ctx.getPathArg(args, "driveId", "Missing 'driveId' argument.") orelse return;
    const sp_path = ctx.getStringArg(args, "path", "Missing 'path' argument (destination path in drive).") orelse return;
    const content = ctx.getStringArg(args, "content", "Missing 'content' argument (string to upload).") orelse return;

    if (!isPathSafe(sp_path)) {
        ctx.sendResult("Invalid path — must not start with '/' or contain '..'.");
        return;
    }

    const content_type = json_rpc.getStringArg(args, "contentType") orelse mime.fromPath(sp_path);

    uploadToSharePoint(ctx, token, site_id, drive_id, sp_path, content, content_type);
}

// --- Upload implementation ---

/// Shared core for both upload handlers. Dispatches to simple PUT or chunked
/// upload based on payload size. Sends the tool response directly.
fn uploadToSharePoint(
    ctx: ToolContext,
    token: []const u8,
    site_id: []const u8,
    drive_id: []const u8,
    sp_path: []const u8,
    data: []const u8,
    content_type: []const u8,
) void {
    if (data.len <= SIMPLE_UPLOAD_LIMIT) {
        uploadSimple(ctx, token, site_id, drive_id, sp_path, data, content_type);
    } else {
        uploadChunked(ctx, token, site_id, drive_id, sp_path, data);
    }
}

/// Single-shot PUT for files up to SIMPLE_UPLOAD_LIMIT.
fn uploadSimple(
    ctx: ToolContext,
    token: []const u8,
    site_id: []const u8,
    drive_id: []const u8,
    sp_path: []const u8,
    data: []const u8,
    content_type: []const u8,
) void {
    const escaped = escapePath(ctx.allocator, sp_path) catch return;
    defer ctx.allocator.free(escaped);

    const path = std.fmt.allocPrint(ctx.allocator, "/sites/{s}/drives/{s}/root:/{s}:/content", .{ site_id, drive_id, escaped }) catch return;
    defer ctx.allocator.free(path);

    const response = graph.put(ctx.allocator, ctx.io, token, path, data, content_type) catch {
        ctx.sendResult("Failed to upload file to SharePoint.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}

/// Resumable upload for files larger than SIMPLE_UPLOAD_LIMIT.
/// 1. POST createUploadSession → pre-signed upload URL
/// 2. PUT each CHUNK_SIZE block with Content-Range: bytes START-END/TOTAL
/// 3. The final chunk's response contains the full DriveItem JSON.
fn uploadChunked(
    ctx: ToolContext,
    token: []const u8,
    site_id: []const u8,
    drive_id: []const u8,
    sp_path: []const u8,
    data: []const u8,
) void {
    const escaped = escapePath(ctx.allocator, sp_path) catch return;
    defer ctx.allocator.free(escaped);

    // Step 1: createUploadSession.
    const session_path = std.fmt.allocPrint(
        ctx.allocator,
        "/sites/{s}/drives/{s}/root:/{s}:/createUploadSession",
        .{ site_id, drive_id, escaped },
    ) catch return;
    defer ctx.allocator.free(session_path);

    // Include conflictBehavior=replace so repeat uploads overwrite.
    const session_body =
        \\{"item":{"@microsoft.graph.conflictBehavior":"replace"}}
    ;

    const session_resp = graph.post(ctx.allocator, ctx.io, token, session_path, session_body) catch {
        ctx.sendResult("Failed to create SharePoint upload session.");
        return;
    };
    defer ctx.allocator.free(session_resp);

    const upload_url = extractStringField(ctx.allocator, session_resp, "uploadUrl") orelse {
        const err_msg = std.fmt.allocPrint(ctx.allocator, "Upload session response missing uploadUrl: {s}", .{session_resp}) catch return;
        defer ctx.allocator.free(err_msg);
        ctx.sendResult(err_msg);
        return;
    };
    defer ctx.allocator.free(upload_url);

    // Step 2: PUT each chunk.
    const total = data.len;
    var offset: usize = 0;
    var last_response: ?[]u8 = null;
    defer if (last_response) |r| ctx.allocator.free(r);

    while (offset < total) {
        const remaining = total - offset;
        const this_chunk_len = @min(CHUNK_SIZE, remaining);
        const chunk = data[offset .. offset + this_chunk_len];
        const chunk_end = offset + this_chunk_len - 1;

        const range = std.fmt.allocPrint(
            ctx.allocator,
            "bytes {d}-{d}/{d}",
            .{ offset, chunk_end, total },
        ) catch return;
        defer ctx.allocator.free(range);

        const chunk_resp = graph.putChunk(ctx.allocator, ctx.io, upload_url, chunk, range) catch {
            ctx.sendResult("Failed to upload chunk to SharePoint.");
            return;
        };
        // Replace last_response each iteration — only the final chunk's
        // response contains the finished DriveItem JSON.
        if (last_response) |r| ctx.allocator.free(r);
        last_response = chunk_resp;

        offset += this_chunk_len;
    }

    ctx.sendResult(last_response orelse "Upload completed, but no response body was returned.");
}

// --- Folder / delete / download ---

/// Create a folder at the given path inside a drive.
/// The path is the full path of the new folder relative to drive root;
/// the parent must already exist.
pub fn handleCreateFolder(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide siteId, driveId, and path.") orelse return;
    const site_id = ctx.getPathArg(args, "siteId", "Missing 'siteId' argument.") orelse return;
    const drive_id = ctx.getPathArg(args, "driveId", "Missing 'driveId' argument.") orelse return;
    const sp_path = ctx.getStringArg(args, "path", "Missing 'path' argument (new folder path).") orelse return;

    if (!isPathSafe(sp_path)) {
        ctx.sendResult("Invalid path — must not start with '/' or contain '..'.");
        return;
    }

    // Split path into parent + leaf. Parent may be empty (folder at root).
    const last_slash = std.mem.lastIndexOfScalar(u8, sp_path, '/');
    const parent_path: []const u8 = if (last_slash) |i| sp_path[0..i] else "";
    const folder_name: []const u8 = if (last_slash) |i| sp_path[i + 1 ..] else sp_path;

    if (folder_name.len == 0) {
        ctx.sendResult("Invalid path — folder name is empty.");
        return;
    }

    const endpoint = if (parent_path.len == 0)
        std.fmt.allocPrint(ctx.allocator, "/sites/{s}/drives/{s}/root/children", .{ site_id, drive_id }) catch return
    else blk: {
        const escaped = escapePath(ctx.allocator, parent_path) catch return;
        defer ctx.allocator.free(escaped);
        break :blk std.fmt.allocPrint(ctx.allocator, "/sites/{s}/drives/{s}/root:/{s}:/children", .{ site_id, drive_id, escaped }) catch return;
    };
    defer ctx.allocator.free(endpoint);

    // Build JSON body: {"name":"...", "folder":{}, "@microsoft.graph.conflictBehavior":"rename"}
    var body: ObjectMap = .empty;
    defer body.deinit(ctx.allocator);
    body.put(ctx.allocator, "name", .{ .string = folder_name }) catch return;
    const folder_obj: ObjectMap = .empty;
    body.put(ctx.allocator, "folder", .{ .object = folder_obj }) catch return;
    body.put(ctx.allocator, "@microsoft.graph.conflictBehavior", .{ .string = "rename" }) catch return;

    var json_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer json_buf.deinit();
    std.json.Stringify.value(Value{ .object = body }, .{}, &json_buf.writer) catch return;

    const response = graph.post(ctx.allocator, ctx.io, token, endpoint, json_buf.written()) catch {
        ctx.sendResult("Failed to create SharePoint folder.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}

/// Delete an item (file or folder) by path OR by itemId.
/// Exactly one of the two must be provided.
pub fn handleDeleteItem(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide siteId, driveId, and either path or itemId.") orelse return;
    const site_id = ctx.getPathArg(args, "siteId", "Missing 'siteId' argument.") orelse return;
    const drive_id = ctx.getPathArg(args, "driveId", "Missing 'driveId' argument.") orelse return;

    const sp_path = json_rpc.getStringArg(args, "path");
    const item_id = json_rpc.getStringArg(args, "itemId");

    if (sp_path == null and item_id == null) {
        ctx.sendResult("Must provide either 'path' or 'itemId'.");
        return;
    }
    if (sp_path != null and item_id != null) {
        ctx.sendResult("Provide either 'path' OR 'itemId', not both.");
        return;
    }

    const endpoint = if (item_id) |id|
        std.fmt.allocPrint(ctx.allocator, "/sites/{s}/drives/{s}/items/{s}", .{ site_id, drive_id, id }) catch return
    else blk: {
        const p = sp_path.?;
        if (!isPathSafe(p)) {
            ctx.sendResult("Invalid path — must not start with '/' or contain '..'.");
            return;
        }
        const escaped = escapePath(ctx.allocator, p) catch return;
        defer ctx.allocator.free(escaped);
        break :blk std.fmt.allocPrint(ctx.allocator, "/sites/{s}/drives/{s}/root:/{s}", .{ site_id, drive_id, escaped }) catch return;
    };
    defer ctx.allocator.free(endpoint);

    graph.delete(ctx.allocator, ctx.io, token, endpoint) catch {
        ctx.sendResult("Failed to delete SharePoint item.");
        return;
    };

    ctx.sendResult("SharePoint item deleted.");
}

/// Download a file's contents by path OR itemId.
/// The response text is the raw file body (the client can save it or parse it).
/// For binary files, the bytes are returned as-is inside the MCP text result.
pub fn handleDownloadFile(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide siteId, driveId, and either path or itemId.") orelse return;
    const site_id = ctx.getPathArg(args, "siteId", "Missing 'siteId' argument.") orelse return;
    const drive_id = ctx.getPathArg(args, "driveId", "Missing 'driveId' argument.") orelse return;

    const sp_path = json_rpc.getStringArg(args, "path");
    const item_id = json_rpc.getStringArg(args, "itemId");

    if (sp_path == null and item_id == null) {
        ctx.sendResult("Must provide either 'path' or 'itemId'.");
        return;
    }
    if (sp_path != null and item_id != null) {
        ctx.sendResult("Provide either 'path' OR 'itemId', not both.");
        return;
    }

    const endpoint = if (item_id) |id|
        std.fmt.allocPrint(ctx.allocator, "/sites/{s}/drives/{s}/items/{s}/content", .{ site_id, drive_id, id }) catch return
    else blk: {
        const p = sp_path.?;
        if (!isPathSafe(p)) {
            ctx.sendResult("Invalid path — must not start with '/' or contain '..'.");
            return;
        }
        const escaped = escapePath(ctx.allocator, p) catch return;
        defer ctx.allocator.free(escaped);
        break :blk std.fmt.allocPrint(ctx.allocator, "/sites/{s}/drives/{s}/root:/{s}:/content", .{ site_id, drive_id, escaped }) catch return;
    };
    defer ctx.allocator.free(endpoint);

    const response = graph.get(ctx.allocator, ctx.io, token, endpoint) catch {
        ctx.sendResult("Failed to download SharePoint file.");
        return;
    };
    defer ctx.allocator.free(response);

    ctx.sendResult(response);
}

/// Extract a top-level string field from a JSON response body.
/// Returns a newly-allocated copy (or null on any parse / shape failure) —
/// caller owns the result.
fn extractStringField(allocator: std.mem.Allocator, json_text: []const u8, key: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const val = obj.get(key) orelse return null;
    const s = switch (val) {
        .string => |str| str,
        else => return null,
    };
    return allocator.dupe(u8, s) catch null;
}
