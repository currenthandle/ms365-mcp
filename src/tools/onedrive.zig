// tools/onedrive.zig — OneDrive personal drive tools.
//
// Mirror of the sharepoint.zig surface, but against /me/drive instead of
// /sites/{s}/drives/{d}. The Graph shape is identical — only the URL
// prefix differs — so the handlers here are small on purpose. If we ever
// add a third drive-style surface (shared drives, group drives), pull the
// shared logic into a drive_common module. Today, intentional duplication
// is cheaper than the abstraction.
//
// Scope requirement: Files.ReadWrite (delegated). Sites.ReadWrite.All
// does NOT cover /me/drive — they're distinct surfaces in Graph's
// permission model.
//
// Reading guide for TS/Python-first readers: this file reuses the same
// helpers as sharepoint.zig — isPathSafe, escapePath, mime inference,
// and binary_download.saveToTempFile for file reads. Every new allocation
// has a visible free on the next line or an explicit errdefer/defer.

const std = @import("std");
const graph = @import("../graph.zig");
const url_util = @import("../url.zig");
const json_rpc = @import("../json_rpc.zig");
const mime = @import("../mime.zig");
const formatter = @import("../formatter.zig");
const json_util = @import("../json_util.zig");
const binary_download = @import("../binary_download.zig");
const ToolContext = @import("context.zig").ToolContext;

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

// Upload thresholds — identical to SharePoint. Files at or below
// SIMPLE_UPLOAD_LIMIT use the single-shot PUT. Anything bigger flows
// through createUploadSession + chunked PUTs.
const SIMPLE_UPLOAD_LIMIT: usize = 4 * 1024 * 1024;
const CHUNK_SIZE: usize = 10 * 1024 * 1024;

const od_item_fields = [_]formatter.FieldSpec{
    .{ .path = "name", .label = "name" },
    .{ .path = "lastModifiedDateTime", .label = "modified" },
};

// --- Path helpers (duplicated from sharepoint.zig on purpose — see top comment) ---

fn isPathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return false;
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    return true;
}

/// Percent-encode each path segment; keep `/` separators.
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

// --- Read ---

/// List items at the drive root or at an optional folder path.
pub fn handleListItems(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Optional folderPath argument.") orelse ObjectMap.empty;
    const folder_path = json_rpc.getStringArg(args, "folderPath");

    const path = if (folder_path) |fp| blk: {
        if (!isPathSafe(fp)) {
            ctx.sendResult("Invalid folderPath — must not start with '/' or contain '..'.");
            return;
        }
        const escaped = escapePath(ctx.allocator, fp) catch return;
        defer ctx.allocator.free(escaped);
        break :blk std.fmt.allocPrint(ctx.allocator, "/me/drive/root:/{s}:/children", .{escaped}) catch return;
    } else std.fmt.allocPrint(ctx.allocator, "/me/drive/root/children", .{}) catch return;
    defer ctx.allocator.free(path);

    const response = graph.get(ctx.allocator, ctx.io, token, path) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    if (formatter.summarizeArray(ctx.allocator, response, &od_item_fields)) |summary| {
        defer ctx.allocator.free(summary);
        ctx.sendResult(summary);
    } else {
        ctx.sendResult("Folder is empty.");
    }
}

// --- Upload ---

pub fn handleUploadFile(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide path and filePath.") orelse return;
    const od_path = ctx.getStringArg(args, "path", "Missing 'path' argument (destination path in OneDrive).") orelse return;
    const file_path = ctx.getStringArg(args, "filePath", "Missing 'filePath' argument (local absolute path).") orelse return;

    if (!isPathSafe(od_path)) {
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
    uploadToOneDrive(ctx, token, od_path, file_data, content_type);
}

pub fn handleUploadContent(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide path and content.") orelse return;
    const od_path = ctx.getStringArg(args, "path", "Missing 'path' argument.") orelse return;
    const content = ctx.getStringArg(args, "content", "Missing 'content' argument.") orelse return;

    if (!isPathSafe(od_path)) {
        ctx.sendResult("Invalid path — must not start with '/' or contain '..'.");
        return;
    }
    const content_type = json_rpc.getStringArg(args, "contentType") orelse mime.fromPath(od_path);
    uploadToOneDrive(ctx, token, od_path, content, content_type);
}

fn uploadToOneDrive(
    ctx: ToolContext,
    token: []const u8,
    od_path: []const u8,
    data: []const u8,
    content_type: []const u8,
) void {
    if (data.len <= SIMPLE_UPLOAD_LIMIT) {
        uploadSimple(ctx, token, od_path, data, content_type);
    } else {
        uploadChunked(ctx, token, od_path, data);
    }
}

fn uploadSimple(
    ctx: ToolContext,
    token: []const u8,
    od_path: []const u8,
    data: []const u8,
    content_type: []const u8,
) void {
    const escaped = escapePath(ctx.allocator, od_path) catch return;
    defer ctx.allocator.free(escaped);
    const path = std.fmt.allocPrint(ctx.allocator, "/me/drive/root:/{s}:/content", .{escaped}) catch return;
    defer ctx.allocator.free(path);

    const response = graph.put(ctx.allocator, ctx.io, token, path, data, content_type) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);
    ctx.sendResult(response);
}

fn uploadChunked(
    ctx: ToolContext,
    token: []const u8,
    od_path: []const u8,
    data: []const u8,
) void {
    const escaped = escapePath(ctx.allocator, od_path) catch return;
    defer ctx.allocator.free(escaped);

    const session_path = std.fmt.allocPrint(
        ctx.allocator,
        "/me/drive/root:/{s}:/createUploadSession",
        .{escaped},
    ) catch return;
    defer ctx.allocator.free(session_path);

    const session_body =
        \\{"item":{"@microsoft.graph.conflictBehavior":"replace"}}
    ;
    const session_resp = graph.post(ctx.allocator, ctx.io, token, session_path, session_body) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(session_resp);

    const upload_url = json_util.extractString(ctx.allocator, session_resp, "uploadUrl") orelse {
        ctx.sendResult("Upload session response missing uploadUrl.");
        return;
    };
    defer ctx.allocator.free(upload_url);

    const total = data.len;
    var offset: usize = 0;
    var last_response: ?[]u8 = null;
    defer if (last_response) |r| ctx.allocator.free(r);

    while (offset < total) {
        const remaining = total - offset;
        const this_len = @min(CHUNK_SIZE, remaining);
        const chunk = data[offset .. offset + this_len];
        const chunk_end = offset + this_len - 1;
        const range = std.fmt.allocPrint(ctx.allocator, "bytes {d}-{d}/{d}", .{ offset, chunk_end, total }) catch return;
        defer ctx.allocator.free(range);

        const chunk_resp = graph.putChunk(ctx.allocator, ctx.io, upload_url, chunk, range) catch |err| {
            ctx.sendGraphError(err);
            return;
        };
        if (last_response) |r| ctx.allocator.free(r);
        last_response = chunk_resp;
        offset += this_len;
    }

    ctx.sendResult(last_response orelse "Upload completed, but no response body was returned.");
}

// --- Download (binary-safe) ---

pub fn handleDownloadFile(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide path or itemId.") orelse return;

    const od_path = json_rpc.getStringArg(args, "path");
    const item_id = json_rpc.getStringArg(args, "itemId");

    if (od_path == null and item_id == null) {
        ctx.sendResult("Must provide either 'path' or 'itemId'.");
        return;
    }
    if (od_path != null and item_id != null) {
        ctx.sendResult("Provide either 'path' OR 'itemId', not both.");
        return;
    }

    const endpoint = if (item_id) |id|
        std.fmt.allocPrint(ctx.allocator, "/me/drive/items/{s}/content", .{id}) catch return
    else blk: {
        const p = od_path.?;
        if (!isPathSafe(p)) {
            ctx.sendResult("Invalid path — must not start with '/' or contain '..'.");
            return;
        }
        const escaped = escapePath(ctx.allocator, p) catch return;
        defer ctx.allocator.free(escaped);
        break :blk std.fmt.allocPrint(ctx.allocator, "/me/drive/root:/{s}:/content", .{escaped}) catch return;
    };
    defer ctx.allocator.free(endpoint);

    const response = graph.get(ctx.allocator, ctx.io, token, endpoint) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    defer ctx.allocator.free(response);

    const suggested = if (od_path) |p| blk: {
        if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| break :blk p[i + 1 ..];
        break :blk p;
    } else "";

    const local_path = binary_download.saveToTempFile(ctx.allocator, ctx.io, suggested, response) catch {
        ctx.sendResult("Failed to write downloaded file to a temp path.");
        return;
    };
    defer ctx.allocator.free(local_path);

    const msg = std.fmt.allocPrint(
        ctx.allocator,
        "Downloaded {d} bytes | local_path: {s}",
        .{ response.len, local_path },
    ) catch return;
    defer ctx.allocator.free(msg);
    ctx.sendResult(msg);
}

// --- Delete ---

pub fn handleDeleteItem(ctx: ToolContext) void {
    const token = ctx.requireAuth() orelse return;
    const args = ctx.getArgs("Missing arguments. Provide path or itemId.") orelse return;

    const od_path = json_rpc.getStringArg(args, "path");
    const item_id = json_rpc.getStringArg(args, "itemId");

    if (od_path == null and item_id == null) {
        ctx.sendResult("Must provide either 'path' or 'itemId'.");
        return;
    }
    if (od_path != null and item_id != null) {
        ctx.sendResult("Provide either 'path' OR 'itemId', not both.");
        return;
    }

    const endpoint = if (item_id) |id|
        std.fmt.allocPrint(ctx.allocator, "/me/drive/items/{s}", .{id}) catch return
    else blk: {
        const p = od_path.?;
        if (!isPathSafe(p)) {
            ctx.sendResult("Invalid path — must not start with '/' or contain '..'.");
            return;
        }
        const escaped = escapePath(ctx.allocator, p) catch return;
        defer ctx.allocator.free(escaped);
        break :blk std.fmt.allocPrint(ctx.allocator, "/me/drive/root:/{s}", .{escaped}) catch return;
    };
    defer ctx.allocator.free(endpoint);

    graph.delete(ctx.allocator, ctx.io, token, endpoint) catch |err| {
        ctx.sendGraphError(err);
        return;
    };
    ctx.sendResult("OneDrive item deleted.");
}
