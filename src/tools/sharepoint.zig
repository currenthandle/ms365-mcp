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
const ToolContext = @import("context.zig").ToolContext;

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

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
